import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/goal_repository.dart';
import 'package:novel_writer/widgets/app_card.dart';

/// 写作统计面板。
///
/// 纯展示：总字数、章节数、平均每章字数、最长章节、各章字数分布。
/// 若设置了写作目标，额外显示「今日已写 / 目标 / 连续打卡」。
class StatisticsPanel extends ConsumerWidget {
  /// 构造统计面板。
  const StatisticsPanel({super.key, required this.novel});

  /// 项目（提供章节列表）。
  final Novel novel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Chapter> chapters = novel.chapters;
    final int total = chapters
        .fold<int>(0, (int sum, Chapter c) => sum + c.wordCount());
    final int count = chapters.length;
    final int avg = count == 0 ? 0 : total ~/ count;
    final Chapter? longest = chapters.isEmpty
        ? null
        : chapters.reduce((a, b) => a.wordCount() >= b.wordCount() ? a : b);
    final AppInk ink = AppInk.of(context);

    return AppCard(
      title: '写作统计',
      icon: Icons.insights,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _statItem(context, '总字数', '$total'),
              _statItem(context, '章节', '$count'),
              _statItem(context, '平均/章', '$avg'),
            ],
          ),
          if (longest != null) ...<Widget>[
            const SizedBox(height: AppTokens.s2),
            Text(
              '最长章节：${longest.title}（${longest.wordCount()} 字）',
              style: AppFonts.text(ink.inkSoft, size: 12.5, height: 1.5),
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (chapters.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppTokens.s3),
            Text('各章字数',
                style: AppFonts.text(ink.inkFaint,
                    size: 11.5, weight: FontWeight.w600, height: 1.3)),
            const SizedBox(height: AppTokens.s2 - 2),
            ...chapters.asMap().entries.map((entry) {
              final int i = entry.key;
              final Chapter c = entry.value;
              final double ratio = total == 0 ? 0 : c.wordCount() / total;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 26,
                      child: Text(
                        '${i + 1}',
                        style: AppFonts.text(ink.inkFaint,
                            size: 11.5, height: 1.3, monoFace: true),
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 6,
                          backgroundColor: ink.divider,
                          color: ink.primary,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 54,
                      child: Text(
                        '${c.wordCount()}',
                        textAlign: TextAlign.right,
                        style: AppFonts.text(ink.inkSoft,
                            size: 11.5, height: 1.3, monoFace: true),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
          const SizedBox(height: AppTokens.s2),
          _GoalCard(novelId: novel.id, chapters: chapters),
        ],
      ),
    );
  }

  Widget _statItem(BuildContext context, String label, String value) {
    final AppInk ink = AppInk.of(context);
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(
            value,
            style: AppFonts.text(ink.ink,
                size: 15,
                weight: FontWeight.w700,
                height: 1.25,
                monoFace: true),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: AppFonts.text(ink.inkFaint, size: 11.5, height: 1.3)),
        ],
      ),
    );
  }
}

/// 写作目标卡片：今日已写 / 目标 / 连续打卡 + 设置目标。
class _GoalCard extends ConsumerStatefulWidget {
  /// 构造目标卡。
  const _GoalCard({required this.novelId, required this.chapters});

  /// 项目 id。
  final String novelId;

  /// 章节列表。
  final List<Chapter> chapters;

  @override
  ConsumerState<_GoalCard> createState() => _GoalCardState();
}

class _GoalCardState extends ConsumerState<_GoalCard> {
  WritingGoal? _goal;
  bool _loading = true;
  String _todayWords = '0';

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _dateKey(DateTime dt) {
    final String m = dt.month.toString().padLeft(2, '0');
    final String d = dt.day.toString().padLeft(2, '0');
    return '${dt.year}-$m-$d';
  }

  Future<void> _load() async {
    final GoalRepository repo = ref.read(goalRepositoryProvider);
    try {
      final WritingGoal raw = await repo.load();
      final Novel novel = await ref
          .read(novelRepositoryProvider)
          .getNovel(widget.novelId);
      final WritingGoal goal = await repo.refreshFromChapters(novel, raw);
      // 刷新后若有变化则保存。
      if (goal.streak != raw.streak ||
          goal.dailyLog.length != raw.dailyLog.length) {
        await repo.save(goal);
      }
      final DateTime now = DateTime.now();
      final String key = _dateKey(now);
      if (mounted) {
        setState(() {
          _goal = goal;
          _todayWords = '${goal.dailyLog[key] ?? 0}';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setGoal() async {
    final int current = _goal?.dailyGoal ?? 0;
    final TextEditingController ctrl =
        TextEditingController(text: current > 0 ? '$current' : '');
    final int? value = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('设置每日目标'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: '每日目标字数（如 2000）',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(int.tryParse(ctrl.text.trim()) ?? 0),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value == null) return;
    final GoalRepository repo = ref.read(goalRepositoryProvider);
    final WritingGoal currentGoal = _goal ??
        WritingGoal(startDate: DateTime.now());
    final WritingGoal updated =
        currentGoal.copyWith(dailyGoal: value < 0 ? 0 : value);
    await repo.save(updated);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppTokens.s2),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final WritingGoal? goal = _goal;
    final ThemeData theme = Theme.of(context);
    final int daily = goal?.dailyGoal ?? 0;
    final int today = int.tryParse(_todayWords) ?? 0;
    final int streak = goal?.streak ?? 0;
    final bool hasGoal = daily > 0;
    final double ratio = hasGoal ? (today / daily).clamp(0.0, 1.0) : 0.0;
    final bool done = hasGoal && today >= daily;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Divider(height: 16),
        Row(
          children: <Widget>[
            Icon(Icons.local_fire_department,
                size: 18,
                color: done
                    ? AppInk.of(context).accent
                    : theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text('写作目标', style: theme.textTheme.titleSmall),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: '设置每日目标',
              onPressed: _setGoal,
            ),
          ],
        ),
        if (!hasGoal)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '未设置每日目标，点击 ✎ 设定（如 2000 字/天）',
              style: theme.textTheme.bodySmall,
            ),
          )
        else ...<Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              _goalStat(context, '今日已写', '$today'),
              _goalStat(context, '目标', '$daily'),
              _goalStat(
                context,
                '连续打卡',
                '$streak 天',
                highlight: streak > 0,
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: ratio, minHeight: 8),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Text(
                done ? '🎉 今日目标已完成！' : '还差 ${daily - today} 字',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: done ? AppInk.of(context).accent : null,
                ),
              ),
              const Spacer(),
              Text(
                '${(ratio * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _goalStat(BuildContext context, String label, String value,
      {bool highlight = false}) {
    final AppInk ink = AppInk.of(context);
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(
            value,
            style: AppFonts.text(
              highlight ? ink.accent : ink.ink,
              size: 15,
              weight: FontWeight.w700,
              height: 1.25,
              monoFace: true,
            ),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: AppFonts.text(ink.inkFaint, size: 11.5, height: 1.3)),
        ],
      ),
    );
  }
}
