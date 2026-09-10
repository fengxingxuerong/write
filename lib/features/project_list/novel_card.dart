import 'package:flutter/material.dart';

import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/core/utils/text_fmt.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/widgets/app_card.dart';

/// 首页作品卡：题材色封面块 + 三格统计 + 悬停反馈。
///
/// 不用 `Card + ListTile` 那种「设置页长相」：作品是主角，列表是书架。
class NovelCard extends StatelessWidget {
  /// 构造。
  const NovelCard({
    super.key,
    required this.novel,
    required this.onOpen,
    this.onQa,
    this.onRename,
    this.onArchive,
    this.onDelete,
    this.width = 296,
    this.height,
  });

  /// 项目摘要。
  final NovelSummary novel;

  /// 打开。
  final VoidCallback onOpen;

  /// 全书体检（本地规则质检）。
  final VoidCallback? onQa;

  /// 重命名。
  final VoidCallback? onRename;

  /// 归档 / 取消归档。
  final VoidCallback? onArchive;

  /// 删除。
  final VoidCallback? onDelete;

  /// 卡片宽度。
  final double width;

  /// 卡片高度（网格对齐用；为空时按内容自适应）。
  final double? height;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final GenrePreset preset = GenrePresets.get(novel.genre);
    final Color genreColor = GenreColors.of(novel.genre);

    return SizedBox(
      width: width,
      height: height,
      child: AppCard(
        onTap: onOpen,
        padding: EdgeInsets.zero,
        fill: height != null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _Cover(
              title: novel.title,
              genreLabel: preset.label,
              color: genreColor,
              tint: GenreColors.tint(novel.genre, ink),
              archived: novel.archived,
              dark: ink.dark,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTokens.s4, AppTokens.s3, AppTokens.s2, 0),
              child: Row(
                children: <Widget>[
                  _Mini(
                      label: '章',
                      value: novel.chapterCount.toString(),
                      ink: ink),
                  _Mini(
                      label: '字',
                      value: TextFmt.words(novel.wordCount),
                      ink: ink),
                  _Mini(
                      label: '更新',
                      value: TextFmt.relativeTime(novel.updatedAt),
                      ink: ink,
                      flex: 2),
                ],
              ),
            ),
            if (height != null) const Spacer(),
            const Divider(height: AppTokens.hairline, thickness: AppTokens.hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTokens.s3, 2, AppTokens.s2, 2),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextButton.icon(
                      onPressed: onOpen,
                      icon: Icon(
                        novel.archived
                            ? Icons.unarchive_outlined
                            : Icons.edit_note_outlined,
                        size: 16,
                      ),
                      label: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(novel.archived ? '打开查看' : '继续写作'),
                      ),
                      style: TextButton.styleFrom(
                        alignment: Alignment.centerLeft,
                      ),
                    ),
                  ),
                  if (onRename != null || onArchive != null || onDelete != null)
                    _CardMenu(
                      onQa: onQa,
                      onRename: onRename,
                      onArchive: onArchive,
                      onDelete: onDelete,
                      archived: novel.archived,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({
    required this.title,
    required this.genreLabel,
    required this.color,
    required this.tint,
    required this.archived,
    required this.dark,
  });

  final String title;
  final String genreLabel;
  final Color color;
  final Color tint;
  final bool archived;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 92,
      padding: const EdgeInsets.fromLTRB(
          AppTokens.s4, AppTokens.s3, AppTokens.s4, AppTokens.s3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            tint,
            color.withValues(alpha: dark ? 0.30 : 0.16),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.text(
                dark ? const Color(0xFFF2EEE6) : const Color(0xFF241F1B),
                size: 19,
                weight: FontWeight.w700,
                height: 1.35,
                serifFace: true,
              ),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: dark ? 0.30 : 0.16),
                  borderRadius: BorderRadius.circular(AppTokens.r1),
                  border: Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Text(
                  genreLabel,
                  style: AppFonts.text(color,
                      size: 11, weight: FontWeight.w600, height: 1.4),
                ),
              ),
              const Spacer(),
              if (archived)
                Icon(Icons.inventory_2_outlined, size: 15, color: color),
            ],
          ),
        ],
      ),
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini({
    required this.label,
    required this.value,
    required this.ink,
    this.flex = 1,
  });

  final String label;
  final String value;
  final AppInk ink;
  final int flex;
  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.only(right: AppTokens.s2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: AppFonts.text(ink.inkFaint, size: 11, height: 1.3),
            ),
            const SizedBox(height: 1),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.text(ink.ink,
                  size: 13.5, weight: FontWeight.w600, height: 1.35),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardMenu extends StatelessWidget {
  const _CardMenu({
    required this.onRename,
    required this.onArchive,
    required this.onDelete,
    required this.archived,
    this.onQa,
  });

  /// 全书体检。
  final VoidCallback? onQa;

  final VoidCallback? onRename;
  final VoidCallback? onArchive;
  final VoidCallback? onDelete;
  final bool archived;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '更多操作',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_horiz, size: 18),
      onSelected: (String v) {
        switch (v) {
          case 'qa':
            onQa?.call();
          case 'rename':
            onRename?.call();
          case 'archive':
            onArchive?.call();
          case 'delete':
            onDelete?.call();
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        if (onQa != null)
          const PopupMenuItem(
            value: 'qa',
            child: _MenuLine(
                icon: Icons.fact_check_outlined, text: '全书体检'),
          ),
        if (onRename != null)
          const PopupMenuItem(
            value: 'rename',
            child: _MenuLine(icon: Icons.drive_file_rename_outline, text: '重命名'),
          ),
        if (onArchive != null)
          PopupMenuItem(
            value: 'archive',
            child: _MenuLine(
                icon: archived ? Icons.unarchive_outlined : Icons.archive_outlined,
                text: archived ? '取消归档' : '归档'),
          ),
        if (onDelete != null)
          const PopupMenuItem(
            value: 'delete',
            child: _MenuLine(
                icon: Icons.delete_outline, text: '删除', danger: true),
          ),
      ],
    );
  }
}

class _MenuLine extends StatelessWidget {
  const _MenuLine(
      {required this.icon, required this.text, this.danger = false});

  final IconData icon;
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Color c = danger ? ink.danger : ink.ink;
    return Row(
      children: <Widget>[
        Icon(icon, size: 16, color: c),
        const SizedBox(width: AppTokens.s3),
        Text(text, style: AppFonts.text(c, size: 13.5, height: 1.4)),
      ],
    );
  }
}
