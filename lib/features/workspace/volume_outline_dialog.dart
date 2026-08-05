import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:novel_writer/models/chapter.dart';

/// 卷纲总览弹窗：汇总全书各章大纲，支持查看 / 复制卷纲文本。
///
/// [onEditOutline] 点击某章大纲时回调（由外部打开章纲编辑弹窗）。
Future<void> showVolumeOutlineDialog(
  BuildContext context, {
  required String novelTitle,
  required List<Chapter> chapters,
  required void Function(Chapter chapter) onEditOutline,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => _VolumeOutlineDialog(
      novelTitle: novelTitle,
      chapters: chapters,
      onEditOutline: onEditOutline,
    ),
  );
}

class _VolumeOutlineDialog extends StatefulWidget {
  const _VolumeOutlineDialog({
    required this.novelTitle,
    required this.chapters,
    required this.onEditOutline,
  });

  final String novelTitle;
  final List<Chapter> chapters;
  final void Function(Chapter chapter) onEditOutline;

  @override
  State<_VolumeOutlineDialog> createState() => _VolumeOutlineDialogState();
}

class _VolumeOutlineDialogState extends State<_VolumeOutlineDialog> {
  bool _showAll = false;

  /// 汇总卷纲文本：`第N章 标题：要点1；要点2`。
  String get _volumeText {
    final List<String> lines = <String>[];
    for (int i = 0; i < widget.chapters.length; i++) {
      final Chapter c = widget.chapters[i];
      final String outline = c.outline.trim();
      if (outline.isEmpty) {
        lines.add('第${i + 1}章 $c.title：');
      } else {
        // 多行要点合并为顿号分隔。
        final String merged = outline
            .split(RegExp(r'\n|\r'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .join('；');
        lines.add('第${i + 1}章 $c.title：$merged');
      }
    }
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final List<Chapter> chapters = widget.chapters;
    final int withOutline = chapters.where((c) => c.outline.trim().isNotEmpty).length;
    return AlertDialog(
      title: Text('📖 卷纲总览 · ${widget.novelTitle}'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '共 $chapters.length 章 · $withOutline 章已设置大纲',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: chapters.isEmpty
                  ? const Center(child: Text('暂无章节'))
                  : ListView.builder(
                      itemCount: chapters.length,
                      itemBuilder: (BuildContext c, int i) {
                        final Chapter ch = chapters[i];
                        final bool hasOutline =
                            ch.outline.trim().isNotEmpty;
                        return ListTile(
                          dense: true,
                          leading: Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(c).colorScheme.primary,
                            ),
                          ),
                          title: Text(
                            ch.title,
                            style: const TextStyle(fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: hasOutline
                              ? Text(
                                  ch.outline.trim(),
                                  maxLines: _showAll ? null : 2,
                                  overflow: _showAll
                                      ? TextOverflow.visible
                                      : TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                )
                              : Text(
                                  '未设置大纲',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontStyle: FontStyle.italic,
                                    color: Theme.of(c).colorScheme.outline,
                                  ),
                                ),
                          trailing: IconButton(
                            icon: const Icon(Icons.edit_note, size: 18),
                            tooltip: '编辑大纲',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => widget.onEditOutline(ch),
                          ),
                          onTap: () => widget.onEditOutline(ch),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: () => setState(() => _showAll = !_showAll),
                  icon: const Icon(Icons.unfold_more, size: 16),
                  label: Text(_showAll ? '收起要点' : '展开全部要点'),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: _volumeText),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('✅ 卷纲已复制，可直接粘贴到「多章连写」卷纲输入框'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制卷纲'),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('关闭'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
