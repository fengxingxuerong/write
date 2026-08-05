import 'package:flutter/material.dart';

import 'package:novel_writer/models/chapter.dart';

/// 左栏：章节列表（选中 / 新增 / 删除 / 上移下移排序）。
class ChapterListPanel extends StatelessWidget {
  /// 构造章节列表面板。
  const ChapterListPanel({
    super.key,
    required this.chapters,
    required this.selectedChapterId,
    required this.onSelect,
    required this.onAdd,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onEditOutline,
    required this.onReorder,
  });

  /// 章节列表（有序）。
  final List<Chapter> chapters;

  /// 当前选中章节 id。
  final String? selectedChapterId;

  /// 选中章节回调。
  final void Function(String chapterId) onSelect;

  /// 新增章节回调。
  final VoidCallback onAdd;

  /// 删除章节回调。
  final void Function(String chapterId) onDelete;

  /// 上移回调（传入索引）。
  final void Function(int index) onMoveUp;

  /// 下移回调（传入索引）。
  final void Function(int index) onMoveDown;

  /// 编辑章节大纲回调。
  final void Function(Chapter chapter) onEditOutline;

  /// 拖拽重排回调（oldIndex → newIndex）。
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Column(
        children: <Widget>[
          ListTile(
            title: const Text('章节'),
            trailing: IconButton(
              icon: const Icon(Icons.add),
              tooltip: '新增章节',
              onPressed: onAdd,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: chapters.isEmpty
                ? const Center(child: Text('暂无章节'))
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: chapters.length,
                    onReorderItem: onReorder,
                    itemBuilder: (context, index) {
                      final Chapter c = chapters[index];
                      final bool selected = c.id == selectedChapterId;
                      return ListTile(
                        key: ValueKey<String>(c.id),
                        selected: selected,
                        dense: true,
                        title: Text(
                          '${index + 1}. ${c.title}',
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('${c.wordCount()} 字'),
                        onTap: () => onSelect(c.id),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              tooltip: c.outline.isEmpty
                                  ? '添加大纲'
                                  : '编辑大纲',
                              icon: Icon(
                                Icons.notes,
                                size: 18,
                                color: c.outline.isEmpty
                                    ? null
                                    : Theme.of(context).colorScheme.primary,
                              ),
                              onPressed: () => onEditOutline(c),
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_upward, size: 18),
                              onPressed: index > 0
                                  ? () => onMoveUp(index)
                                  : null,
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_downward, size: 18),
                              onPressed: index < chapters.length - 1
                                  ? () => onMoveDown(index)
                                  : null,
                            ),
                            const IconButton(
                              icon: Icon(Icons.drag_handle, size: 18),
                              tooltip: '拖拽排序',
                              onPressed: null,
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 18),
                              onPressed: () => onDelete(c.id),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
