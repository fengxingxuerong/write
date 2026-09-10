import 'package:flutter/material.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/features/editor/sensitive_check_dialog.dart';
import 'package:novel_writer/services/sensitive_words.dart';
import 'package:novel_writer/widgets/app_card.dart';
import 'package:novel_writer/widgets/common.dart';
import 'package:novel_writer/widgets/page_shell.dart';

/// 编辑器顶部工具栏。
///
/// 纯展示组件：所有交互通过回调上抛，状态由 [EditorPage] 持有。
/// 排版类动作（字号/行距/字体）收进一个菜单——它们是低频但一开就要连调几次的；
/// AI 动作保持直给，因为「写不下去时点哪」不该需要思考。
class EditorToolbar extends StatelessWidget {
  /// 构造工具栏。
  const EditorToolbar({
    super.key,
    required this.title,
    required this.wordCount,
    required this.searchOpen,
    required this.fontSize,
    required this.lineHeight,
    required this.pomodoroRemainNotifier,
    required this.pomodoroRunningNotifier,
    required this.check,
    required this.saved,
    required this.onToggleSearch,
    required this.onDecreaseFont,
    required this.onIncreaseFont,
    required this.onCycleLineHeight,
    required this.onTogglePomodoro,
    required this.onShowCheck,
    required this.onShowStats,
    required this.onSplitChapter,
    required this.onContinueWrite,
    required this.onRewriteSelected,
    required this.onProofread,
    required this.onSaveDraft,
    required this.onShowHistory,
    this.serif = true,
    this.onToggleSerif,
    this.paragraphCount = 0,
  });

  /// 章节标题（无章节时显示占位）。
  final String title;

  /// 实时字数。
  final int wordCount;

  /// 查找条是否展开。
  final bool searchOpen;

  /// 当前字号。
  final double fontSize;

  /// 当前行距。
  final double lineHeight;

  /// 番茄钟剩余秒数通知器（ValueListenableBuilder 隔离重建）。
  final ValueNotifier<int> pomodoroRemainNotifier;

  /// 番茄钟运行状态通知器。
  final ValueNotifier<bool> pomodoroRunningNotifier;

  /// 敏感词检测结果（null 时不显示徽标）。
  final SensitiveCheckResult? check;

  /// 已保存状态。
  final bool saved;

  /// 切换查找条。
  final VoidCallback onToggleSearch;

  /// 减小字号。
  final VoidCallback onDecreaseFont;

  /// 增大字号。
  final VoidCallback onIncreaseFont;

  /// 循环切换行距。
  final VoidCallback onCycleLineHeight;

  /// 切换番茄钟。
  final VoidCallback onTogglePomodoro;

  /// 打开敏感词详情。
  final VoidCallback onShowCheck;

  /// 打开写作统计。
  final VoidCallback onShowStats;

  /// 自动章节分割。
  final VoidCallback onSplitChapter;

  /// AI 续写。
  final VoidCallback onContinueWrite;

  /// AI 修改选中内容。
  final VoidCallback onRewriteSelected;

  /// 全文 AI 校对。
  final VoidCallback onProofread;

  /// 把当前正文存入存稿箱。
  final VoidCallback onSaveDraft;

  /// 打开历史版本（回滚）。
  final VoidCallback onShowHistory;

  /// 正文是否用衬线字体。
  final bool serif;

  /// 切换衬线/黑体。
  final VoidCallback? onToggleSerif;

  /// 段落数（工具栏顺带报一下，省得开统计弹窗）。
  final int paragraphCount;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppTokens.s4, AppTokens.s2, AppTokens.s3, AppTokens.s2),
      decoration: BoxDecoration(
        color: ink.surface,
        border: Border(bottom: BorderSide(color: ink.divider)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220),
              child: Row(
                children: <Widget>[
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Text(
                      title,
                      style: AppFonts.text(ink.ink,
                          size: 14,
                          weight: FontWeight.w600,
                          height: 1.35,
                          serifFace: true),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppTokens.s3),
                  Tooltip(
                    message:
                        paragraphCount > 0 ? '$paragraphCount 个自然段' : '本章字数',
                    child: Text(
                      '$wordCount 字',
                      style: AppFonts.text(ink.inkFaint,
                          size: 12, height: 1.3, monoFace: true),
                    ),
                  ),
                ],
              ),
            ),
          // AI 动作：直给。
          ActionGroup(
            children: <Widget>[
              ToolButton(
                icon: Icons.auto_awesome,
                label: 'AI 续写',
                tone: ink.accent,
                showLabel: true,
                onPressed: onContinueWrite,
              ),
              ToolButton(
                icon: Icons.edit_note,
                label: 'AI 修改选中',
                tone: ink.accent,
                onPressed: onRewriteSelected,
              ),
              ToolButton(
                icon: Icons.fact_check_outlined,
                label: '全文 AI 校对',
                tone: ink.accent,
                onPressed: onProofread,
              ),
            ],
          ),
          const SizedBox(width: AppTokens.s2),
          ActionGroup(
            children: <Widget>[
              ToolButton(
                icon: searchOpen ? Icons.close : Icons.search,
                label: searchOpen ? '关闭查找' : '查找替换 (Ctrl+F)',
                active: searchOpen,
                onPressed: onToggleSearch,
              ),
              ToolButton(
                icon: Icons.query_stats,
                label: '写作统计',
                onPressed: onShowStats,
              ),
              _FormatMenu(
                fontSize: fontSize,
                lineHeight: lineHeight,
                serif: serif,
                onDecreaseFont: onDecreaseFont,
                onIncreaseFont: onIncreaseFont,
                onCycleLineHeight: onCycleLineHeight,
                onToggleSerif: onToggleSerif,
              ),
              _MoreMenu(
                onSplitChapter: onSplitChapter,
                onSaveDraft: onSaveDraft,
                onShowHistory: onShowHistory,
              ),
            ],
          ),
          const SizedBox(width: AppTokens.s2),
          // 番茄钟（ValueListenableBuilder 隔离重建范围，避免每秒重建整个工具栏）。
          ValueListenableBuilder<bool>(
            valueListenable: pomodoroRunningNotifier,
            builder: (BuildContext context, bool running, Widget? _) {
              return ValueListenableBuilder<int>(
                valueListenable: pomodoroRemainNotifier,
                builder: (BuildContext context, int remain, Widget? _) {
                  final String label = running
                      ? '${(remain ~/ 60).toString().padLeft(2, '0')}:'
                          '${(remain % 60).toString().padLeft(2, '0')}'
                      : '番茄钟';
                  return Hoverable(
                    onTap: onTogglePomodoro,
                    selected: running,
                    borderRadius: BorderRadius.circular(AppTokens.r2),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppTokens.s3, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            running ? Icons.timer_off : Icons.timer_outlined,
                            size: 15,
                            color: running ? ink.accent : ink.inkSoft,
                          ),
                          const SizedBox(width: AppTokens.s2 - 2),
                          Text(
                            label,
                            style: AppFonts.text(
                              running ? ink.accent : ink.inkSoft,
                              size: 12.5,
                              height: 1.3,
                              monoFace: running,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
          if (check != null) ...<Widget>[
            const SizedBox(width: AppTokens.s2),
            SensitiveBadge(check: check!, onTap: onShowCheck),
          ],
          const SizedBox(width: AppTokens.s2),
          saved
              ? const SavedBadge()
              : const TintBadge('编辑中', dense: true, tone: BadgeTone.warn),
          ],
        ),
      ),
    );
  }
}

/// 排版菜单：字号 / 行距 / 字体（衬线↔黑体）。
class _FormatMenu extends StatelessWidget {
  const _FormatMenu({
    required this.fontSize,
    required this.lineHeight,
    required this.serif,
    required this.onDecreaseFont,
    required this.onIncreaseFont,
    required this.onCycleLineHeight,
    this.onToggleSerif,
  });

  final double fontSize;
  final double lineHeight;
  final bool serif;
  final VoidCallback onDecreaseFont;
  final VoidCallback onIncreaseFont;
  final VoidCallback onCycleLineHeight;
  final VoidCallback? onToggleSerif;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return PopupMenuButton<String>(
      tooltip: '排版（字号 / 行距 / 字体）',
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.s2),
      icon: Icon(Icons.text_format_outlined, size: 18, color: ink.inkSoft),
      onSelected: (String v) {
        switch (v) {
          case 'minus':
            onDecreaseFont();
          case 'plus':
            onIncreaseFont();
          case 'line':
            onCycleLineHeight();
          case 'serif':
            onToggleSerif?.call();
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          enabled: false,
          child: Row(
            children: <Widget>[
              const Icon(Icons.text_decrease, size: 15),
              const SizedBox(width: AppTokens.s2),
              Text('字号 ${fontSize.toStringAsFixed(0)}',
                  style: AppFonts.text(ink.inkFaint, size: 12.5)),
              const Spacer(),
              Text('${lineHeight.toStringAsFixed(1)} 倍行距',
                  style: AppFonts.text(ink.inkFaint, size: 12.5)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'minus',
          child: _Line(icon: Icons.remove, text: '减小字号'),
        ),
        const PopupMenuItem<String>(
          value: 'plus',
          child: _Line(icon: Icons.add, text: '增大字号'),
        ),
        const PopupMenuItem<String>(
          value: 'line',
          child: _Line(icon: Icons.format_line_spacing, text: '切换行距'),
        ),
        if (onToggleSerif != null)
          PopupMenuItem<String>(
            value: 'serif',
            child: _Line(
              icon: serif ? Icons.format_italic : Icons.title,
              text: serif ? '正文改用黑体' : '正文改用宋体（衬线）',
            ),
          ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 15),
        const SizedBox(width: AppTokens.s2 + 2),
        Text(text, style: AppFonts.text(AppInk.of(context).ink, size: 13)),
      ],
    );
  }
}

/// 低频动作收纳：章节分割 / 存稿箱 / 历史版本。
class _MoreMenu extends StatelessWidget {
  const _MoreMenu({
    required this.onSplitChapter,
    required this.onSaveDraft,
    required this.onShowHistory,
  });

  final VoidCallback onSplitChapter;
  final VoidCallback onSaveDraft;
  final VoidCallback onShowHistory;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return PopupMenuButton<String>(
      tooltip: '更多',
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.s2),
      icon: Icon(Icons.more_horiz, size: 18, color: ink.inkSoft),
      onSelected: (String v) {
        switch (v) {
          case 'split':
            onSplitChapter();
          case 'draft':
            onSaveDraft();
          case 'history':
            onShowHistory();
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(
          value: 'split',
          child: _Line(icon: Icons.content_cut, text: '自动章节分割'),
        ),
        const PopupMenuItem<String>(
          value: 'draft',
          child: _Line(icon: Icons.inventory_2_outlined, text: '存入存稿箱'),
        ),
        const PopupMenuItem<String>(
          value: 'history',
          child: _Line(icon: Icons.history, text: '历史版本 / 回滚'),
        ),
      ],
    );
  }
}
