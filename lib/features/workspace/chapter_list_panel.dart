import 'package:flutter/material.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/core/utils/text_fmt.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/widgets/common.dart';
import 'package:novel_writer/widgets/app_card.dart';

/// 左栏：章节列表（选中 / 新增 / 删除 / 排序 / 编辑大纲）。
///
/// 行内动作默认收起，hover 才浮出来——写作软件里章节列表要看几百行，
/// 每行常驻 5 个图标会把视线全吃掉。
class ChapterListPanel extends StatefulWidget {
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
    this.targetWordsPerChapter = 0,
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

  /// 单章目标字数（>0 时每行显示达成度）。
  final int targetWordsPerChapter;

  @override
  State<ChapterListPanel> createState() => _ChapterListPanelState();
}

class _ChapterListPanelState extends State<ChapterListPanel> {
  int? _hoverIndex;

  int get _totalWords =>
      widget.chapters.fold<int>(0, (int a, Chapter c) => a + c.wordCount());

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return Column(
      children: <Widget>[
        _Header(
          ink: ink,
          count: widget.chapters.length,
          words: _totalWords,
          onAdd: widget.onAdd,
        ),
        Container(height: AppTokens.hairline, color: ink.divider),
        Expanded(
          child: widget.chapters.isEmpty
              ? EmptyState(
                  icon: Icons.list_alt_outlined,
                  message: '还没有章节',
                  hint: '加一章，或者直接用一键生成铺出大纲。',
                  actionLabel: '新增章节',
                  onAction: widget.onAdd,
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.symmetric(
                      vertical: AppTokens.s2, horizontal: AppTokens.s2),
                  itemCount: widget.chapters.length,
                  onReorderItem: widget.onReorder,
                  itemBuilder: (BuildContext context, int index) {
                    final Chapter c = widget.chapters[index];
                    return _ChapterRow(
                      key: ValueKey<String>(c.id),
                      index: index,
                      chapter: c,
                      ink: ink,
                      selected: c.id == widget.selectedChapterId,
                      hovered: _hoverIndex == index,
                      targetWords: widget.targetWordsPerChapter,
                      onSelect: () => widget.onSelect(c.id),
                      onHover: (bool h) => setState(() {
                        _hoverIndex = h ? index : null;
                      }),
                      onEditOutline: () => widget.onEditOutline(c),
                      onMoveUp: index > 0 ? () => widget.onMoveUp(index) : null,
                      onMoveDown: index < widget.chapters.length - 1
                          ? () => widget.onMoveDown(index)
                          : null,
                      onDelete: () => widget.onDelete(c.id),
                      dragIndex: index,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.ink,
    required this.count,
    required this.words,
    required this.onAdd,
  });

  final AppInk ink;
  final int count;
  final int words;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTokens.s3, AppTokens.s3, AppTokens.s2, AppTokens.s2),
      child: Row(
        children: <Widget>[
          Text(
            '章节',
            style: AppFonts.text(ink.ink,
                size: 13.5, weight: FontWeight.w700, height: 1.3),
          ),
          const SizedBox(width: AppTokens.s2),
          TintBadge('$count', dense: true),
          const Spacer(),
          Tooltip(
            message: words == 0 ? '暂无正文' : '全书 ${TextFmt.words(words)} 字',
            child: Text(
              TextFmt.words(words),
              style: AppFonts.text(ink.inkFaint,
                  size: 12, height: 1.3, monoFace: true),
            ),
          ),
          const SizedBox(width: AppTokens.s2 - 2),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            tooltip: '新增章节',
            visualDensity: VisualDensity.compact,
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    super.key,
    required this.index,
    required this.chapter,
    required this.ink,
    required this.selected,
    required this.hovered,
    required this.onSelect,
    required this.onHover,
    required this.onEditOutline,
    required this.onDelete,
    required this.dragIndex,
    this.onMoveUp,
    this.onMoveDown,
    this.targetWords = 0,
  });

  final int index;
  final Chapter chapter;
  final AppInk ink;
  final bool selected;
  final bool hovered;
  final VoidCallback onSelect;
  final ValueChanged<bool> onHover;
  final VoidCallback onEditOutline;
  final VoidCallback onDelete;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final int dragIndex;
  final int targetWords;

  @override
  Widget build(BuildContext context) {
    final int words = chapter.wordCount();
    final bool hasOutline = chapter.outline.trim().isNotEmpty;
    final double ratio =
        targetWords > 0 ? (words / targetWords).clamp(0.0, 1.0).toDouble() : 0;

    // 整行可点：以前 onSelect 只是传进来没接上，点章节是没反应的。
    return Hoverable(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(AppTokens.r2),
      child: MouseRegion(
        onEnter: (_) => onHover(true),
        onExit: (_) => onHover(false),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected ? ink.selectTint : null,
              borderRadius: BorderRadius.circular(AppTokens.r2),
              border: Border.all(
                color: selected
                    ? ink.primary.withValues(alpha: 0.35)
                    : Colors.transparent,
              ),
            ),
            child: Stack(
              children: <Widget>[
                if (selected)
                  PositionedDirectional(
                    start: 0,
                    top: 8,
                    bottom: 8,
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: ink.primary,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppTokens.s3, 6, AppTokens.s2, 6),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 22,
                        child: Text(
                          '${index + 1}',
                          style: AppFonts.text(
                            selected ? ink.primary : ink.inkFaint,
                            size: 12,
                            height: 1.4,
                            monoFace: true,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              chapter.title.isEmpty ? '未命名章节' : chapter.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppFonts.text(
                                ink.ink,
                                size: 13.5,
                                weight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Row(
                              children: <Widget>[
                                Text(
                                  TextFmt.words(words),
                                  style: AppFonts.text(ink.inkFaint,
                                      size: 11.5, height: 1.3, monoFace: true),
                                ),
                                if (!hasOutline) ...<Widget>[
                                  const SizedBox(width: AppTokens.s2 - 2),
                                  Icon(Icons.edit_outlined,
                                      size: 10, color: ink.warn),
                                ],
                                if (targetWords > 0 && ratio > 0) ...<Widget>[
                                  const SizedBox(width: AppTokens.s2 - 2),
                                  SizedBox(
                                    width: 34,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(2),
                                      child: LinearProgressIndicator(
                                        value: ratio,
                                        minHeight: 3,
                                        color: ratio >= 1
                                            ? ink.success
                                            : ink.primary,
                                        backgroundColor: ink.divider,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      // 行内快捷动作：hover 或选中时浮现。
                      if (!hovered) _menu(ink),
                      AnimatedOpacity(
                        duration: AppTokens.fast,
                        opacity: (hovered || selected) ? 1 : 0,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            _Mini(
                              icon: Icons.notes_outlined,
                              tooltip: hasOutline ? '编辑大纲' : '添加大纲',
                              onPressed: onEditOutline,
                              tinted: hasOutline,
                            ),
                            _Mini(
                              icon: Icons.drag_indicator,
                              tooltip: '拖拽排序',
                              dragHandle: true,
                              index: index,
                            ),
                            if (hovered) _menu(ink),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 章节菜单：未 hover 时它常驻行尾（触屏 / 键盘也走得通），
  /// hover 时站在浮现的动作组里。两处共用一个实现，不会分叉。
  Widget _menu(AppInk ink) {
    return PopupMenuButton<String>(
      tooltip: '章节操作',
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_horiz, size: 16, color: ink.inkFaint),
      onSelected: (String v) {
        switch (v) {
          case 'outline':
            onEditOutline();
          case 'up':
            onMoveUp?.call();
          case 'down':
            onMoveDown?.call();
          case 'delete':
            onDelete();
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(
          key: ValueKey<String>('chapter-menu-outline'),
          value: 'outline',
          child: _MenuItem(icon: Icons.notes_outlined, text: '编辑大纲'),
        ),
        if (onMoveUp != null)
          const PopupMenuItem<String>(
            value: 'up',
            child: _MenuItem(icon: Icons.arrow_upward, text: '上移'),
          ),
        if (onMoveDown != null)
          const PopupMenuItem<String>(
            value: 'down',
            child: _MenuItem(icon: Icons.arrow_downward, text: '下移'),
          ),
        PopupMenuItem<String>(
          key: const ValueKey<String>('chapter-menu-delete'),
          value: 'delete',
          child: _MenuItem(
              icon: Icons.delete_outline, text: '删除本章', color: ink.danger),
        ),
      ],
    );
  }
}

/// 菜单行（图标 + 文字）。
class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? AppInk.of(context).ink;
    return Row(
      children: <Widget>[
        Icon(icon, size: 15, color: c),
        const SizedBox(width: AppTokens.s2 + 2),
        Text(text, style: AppFonts.text(c, size: 13, height: 1.4)),
      ],
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.tinted = false,
    this.dragHandle = false,
    this.index = 0,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool tinted;
  final bool dragHandle;
  final int index;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Widget iconWidget = Icon(
      icon,
      size: 15,
      color: tinted ? ink.primary : ink.inkFaint,
    );
    if (dragHandle) {
      // 拖拽把手必须挂在 ReorderableDragStartListener 上，
      // 否则点行内其它图标会误触排序。
      return Tooltip(
        message: tooltip,
        child: ReorderableDragStartListener(
          index: index,
          child: Padding(
              padding: const EdgeInsets.all(AppTokens.s1 + 1),
              child: iconWidget),
        ),
      );
    }
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppTokens.r1),
        child: Padding(
            padding: const EdgeInsets.all(AppTokens.s1 + 1),
            child: iconWidget),
      ),
    );
  }
}
