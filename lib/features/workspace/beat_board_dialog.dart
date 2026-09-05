import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';

/// 节拍板弹窗：可视化章节场景结构，可切换骨架、重写单节拍。
class BeatBoardDialog extends ConsumerStatefulWidget {
  const BeatBoardDialog({
    super.key,
    required this.novel,
    required this.chapter,
  });

  final Novel novel;
  final Chapter chapter;

  static Future<void> show(BuildContext context, Novel novel, Chapter chapter) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 700,
          height: MediaQuery.of(context).size.height * 0.8,
          child: BeatBoardDialog(novel: novel, chapter: chapter),
        ),
      ),
    );
  }

  @override
  ConsumerState<BeatBoardDialog> createState() => _BeatBoardDialogState();
}

class _BeatBoardDialogState extends ConsumerState<BeatBoardDialog> {
  late List<PlotBeat> _beats;
  int _skeletonIdx = 0;
  bool _rewriting = false;

  @override
  void initState() {
    super.initState();
    _beats = _loadOrGenerateBeats();
  }

  int get _chapterIdx {
    // outline 中 idx 从 1 开始；order 从 0 开始。转换为 1-based。
    return widget.chapter.order + 1;
  }

  List<PlotBeat> _loadOrGenerateBeats() {
    // 如果章节有 instanceSkeleton，使用它；否则从 plot_skeleton 生成
    final skeleton = PlotSkeleton.forGenre(widget.novel.genre);
    if (skeleton.skeletons.isNotEmpty) {
      _skeletonIdx = _chapterIdx % skeleton.skeletons.length;
      return skeleton.skeletons[_skeletonIdx];
    }
    return const [
      PlotBeat('起', '起点与背景铺垫'),
      PlotBeat('承', '事件发展与推进'),
      PlotBeat('转', '冲突与转折'),
      PlotBeat('合', '收束与悬念'),
    ];
  }

  void _switchSkeleton(int idx) {
    final skeleton = PlotSkeleton.forGenre(widget.novel.genre);
    if (idx >= 0 && idx < skeleton.skeletons.length) {
      setState(() {
        _skeletonIdx = idx;
        _beats = List.from(skeleton.skeletons[idx]);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final skeleton = PlotSkeleton.forGenre(widget.novel.genre);
    return Column(
      children: [
        // 标题栏
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome_mosaic, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '第${widget.chapter.order + 1}章「${widget.chapter.title}」节拍板',
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('骨架 ${_skeletonIdx + 1}/${skeleton.skeletons.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 骨架切换器
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Text('切换骨架：', style: TextStyle(fontSize: 12)),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: List.generate(skeleton.skeletons.length, (i) {
                      final selected = i == _skeletonIdx;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text('${i + 1}', style: const TextStyle(fontSize: 11)),
                          selected: selected,
                          onSelected: (_) => _switchSkeleton(i),
                          visualDensity: VisualDensity.compact,
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ],
          ),
        ),
        // 节拍卡片列表（可拖拽重排序）
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: const Text('长按卡片可拖动排序',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            itemCount: _beats.length,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex -= 1;
                final item = _beats.removeAt(oldIndex);
                _beats.insert(newIndex, item);
              });
            },
            proxyDecorator: (child, index, animation) {
              return AnimatedBuilder(
                animation: animation,
                builder: (context, child) {
                  final double elevation = Tween<double>(begin: 0, end: 6)
                      .animate(CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeInOut,
                      ))
                      .value;
                  return Material(
                    elevation: elevation,
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: child,
                  );
                },
                child: child,
              );
            },
            itemBuilder: (context, index) {
              final beat = _beats[index];
              return Dismissible(
                key: ValueKey('beat-${beat.stage}-$index-${beat.hint.hashCode}'),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  color: Colors.red,
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (_) {
                  setState(() => _beats.removeAt(index));
                },
                child: _beatCard(index, beat),
              );
            },
          ),
        ),
        // 底部操作
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('随机切换骨架'),
                onPressed: () {
                  final newIdx = (_skeletonIdx + 1) % skeleton.skeletons.length;
                  _switchSkeleton(newIdx);
                },
              ),
              const Spacer(),
              if (_rewriting)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                FilledButton.icon(
                  icon: const Icon(Icons.brush, size: 16),
                  label: const Text('按此骨架重写本章'),
                  onPressed: _rewriteChapter,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _beatCard(int index, PlotBeat beat) {
    final colors = [
      Colors.lightBlue.shade100,
      Colors.lightGreen.shade100,
      Colors.amber.shade100,
      Colors.pink.shade100,
    ];
    final icons = [
      Icons.play_circle_outline,
      Icons.trending_up,
      Icons.sync_alt,
      Icons.flag_outlined,
    ];
    final color = colors[index % colors.length];
    final icon = icons[index % icons.length];

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: color,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(Icons.drag_handle, size: 18, color: Colors.grey),
              ),
            ),
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: Colors.black54),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '第${index + 1}拍 · ${beat.stage}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    beat.hint,
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit, size: 18),
              tooltip: '编辑节拍',
              onPressed: () => _editBeat(index),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editBeat(int index) async {
    final controller = TextEditingController(text: _beats[index].hint);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑「${_beats[index].stage}」节拍'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: '内容提示',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      setState(() {
        _beats[index] = PlotBeat(_beats[index].stage, result.trim());
      });
    }
    controller.dispose();
  }

  Future<void> _rewriteChapter() async {
    setState(() => _rewriting = true);
    try {
      final outline = _beats.map((b) => '${b.stage}：${b.hint}').join(' → ');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请前往一键生成页使用以下骨架：$outline')),
        );
        Navigator.of(context).pop(outline);
      }
    } finally {
      if (mounted) setState(() => _rewriting = false);
    }
  }
}
