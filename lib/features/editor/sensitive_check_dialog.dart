import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/services/sensitive_words.dart';

/// 敏感词状态徽标。
class SensitiveBadge extends StatelessWidget {
  /// 构造徽标。
  const SensitiveBadge({super.key, required this.check, required this.onTap});

  /// 检测结果。
  final SensitiveCheckResult check;

  /// 点击回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool clean = check.clean;
    final Color color =
        clean ? AppInk.of(context).success : Theme.of(context).colorScheme.error;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.r4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppTokens.r4),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              clean ? Icons.verified_outlined : Icons.warning_amber_rounded,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              clean ? '内容安全' : '${check.count} 处需注意',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// 敏感词详情弹窗：分类统计 + 逐条命中（含上下文）+ 自定义词管理。
class SensitiveCheckDialog extends ConsumerStatefulWidget {
  /// 构造弹窗。
  const SensitiveCheckDialog({
    super.key,
    required this.result,
    required this.service,
  });

  /// 检测结果。
  final SensitiveCheckResult result;

  /// 服务（自定义词管理）。
  final SensitiveWordsService service;

  @override
  ConsumerState<SensitiveCheckDialog> createState() =>
      _SensitiveCheckDialogState();
}

class _SensitiveCheckDialogState extends ConsumerState<SensitiveCheckDialog> {
  final TextEditingController _wordCtrl = TextEditingController();

  @override
  void dispose() {
    _wordCtrl.dispose();
    super.dispose();
  }

  Future<void> _addWord() async {
    final String w = _wordCtrl.text.trim();
    if (w.isEmpty) return;
    try {
      await widget.service.addCustomWord(w);
      _wordCtrl.clear();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        _wordCtrl.clear();
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('添加失败：$e')));
      }
    }
  }

  /// 历史累计命中 TOP 统计区。
  Widget _buildStatsSection(BuildContext context) {
    final List<MapEntry<String, int>> top = widget.service.hitStats.entries
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final List<MapEntry<String, int>> top5 = top.take(5).toList();
    final int total = top.fold<int>(0, (int sum, e) => sum + e.value);
    return Padding(
      padding: const EdgeInsets.only(top: AppTokens.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '📊 历史累计命中 $total 次',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: top5
                .map((e) => Chip(
                      avatar: Icon(
                        Icons.trending_up,
                        size: 14,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      label: Text('${e.key} ×${e.value}'),
                      visualDensity: VisualDensity.compact,
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final SensitiveCheckResult r = widget.result;
    final Set<String> builtin =
        SensitiveWordsService.builtinWords.values.expand((l) => l).toSet();
    final List<String> customList = widget.service.allWords
        .where((w) => !builtin.contains(w))
        .toList();
    return AlertDialog(
      title: Text('内容安全检查（${r.count} 处命中）'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (r.byCategory.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: r.byCategory.entries
                    .map((e) => Chip(
                          label: Text('${e.key} ×${e.value}'),
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
            if (widget.service.hitStats.isNotEmpty) _buildStatsSection(context),
            const SizedBox(height: AppTokens.s3),
            if (r.hits.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('✓ 未发现敏感词')),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: r.hits.length > 50 ? 50 : r.hits.length,
                  separatorBuilder: (_, __) => const Divider(height: 8),
                  itemBuilder: (context, i) {
                    final SensitiveHit h = r.hits[i];
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .error
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(AppTokens.r1),
                          ),
                          child: Text(
                            h.word,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(h.context,
                                  style: Theme.of(context).textTheme.bodySmall),
                              Text(
                                h.category,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            const Divider(height: 24),
            Text('自定义词', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _wordCtrl,
                    decoration: const InputDecoration(
                      hintText: '添加自定义敏感词…',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _addWord(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '添加',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: _addWord,
                ),
              ],
            ),
            if (customList.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: customList
                    .map((w) => InputChip(
                          label: Text(w),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () async {
                              try {
                                await widget.service.removeCustomWord(w);
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context)
                                    ..hideCurrentSnackBar()
                                    ..showSnackBar(SnackBar(
                                        content: Text('删除「$w」失败：$e')));
                                }
                              }
                              if (mounted) setState(() {});
                            },
                        ))
                    .toList(),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
