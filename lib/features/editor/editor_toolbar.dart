import 'package:flutter/material.dart';

import 'package:novel_writer/features/editor/sensitive_check_dialog.dart';
import 'package:novel_writer/services/sensitive_words.dart';
import 'package:novel_writer/widgets/common.dart';

/// 编辑器顶部工具栏。
///
/// 纯展示组件：所有交互通过回调上抛，状态由 [EditorPage] 持有。
class EditorToolbar extends StatelessWidget {
  /// 构造工具栏。
  const EditorToolbar({
    super.key,
    required this.title,
    required this.wordCount,
    required this.searchOpen,
    required this.fontSize,
    required this.lineHeight,
    required this.pomodoroRunning,
    required this.pomodoroLabel,
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

  /// 番茄钟运行中。
  final bool pomodoroRunning;

  /// 番茄钟剩余时间文本。
  final String pomodoroLabel;

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

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.3),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 实时字数（中文统计）。
          Text(
            '$wordCount 字',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(width: 12),
          // 查找替换（Ctrl+F）。
          IconButton(
            icon: Icon(
              searchOpen ? Icons.close : Icons.search,
              size: 18,
            ),
            tooltip: searchOpen ? '关闭查找' : '查找替换 (Ctrl+F)',
            visualDensity: VisualDensity.compact,
            onPressed: onToggleSearch,
          ),
          // 字体大小调节。
          IconButton(
            icon: const Icon(Icons.text_decrease, size: 18),
            tooltip: '减小字号',
            visualDensity: VisualDensity.compact,
            onPressed: onDecreaseFont,
          ),
          IconButton(
            icon: const Icon(Icons.text_increase, size: 18),
            tooltip: '增大字号',
            visualDensity: VisualDensity.compact,
            onPressed: onIncreaseFont,
          ),
          IconButton(
            icon: const Icon(Icons.format_line_spacing, size: 18),
            tooltip: '切换行距',
            visualDensity: VisualDensity.compact,
            onPressed: onCycleLineHeight,
          ),
          // 写作统计。
          IconButton(
            icon: const Icon(Icons.query_stats, size: 18),
            tooltip: '写作统计',
            visualDensity: VisualDensity.compact,
            onPressed: onShowStats,
          ),
          // 自动章节分割。
          IconButton(
            icon: const Icon(Icons.content_cut, size: 18),
            tooltip: '自动章节分割',
            visualDensity: VisualDensity.compact,
            onPressed: onSplitChapter,
          ),
          // AI 续写。
          IconButton(
            icon: const Icon(Icons.auto_awesome, size: 18),
            tooltip: 'AI 续写',
            visualDensity: VisualDensity.compact,
            onPressed: onContinueWrite,
          ),
          // AI 修改选中内容。
          IconButton(
            icon: const Icon(Icons.edit_note, size: 18),
            tooltip: 'AI 修改选中内容',
            visualDensity: VisualDensity.compact,
            onPressed: onRewriteSelected,
          ),
          // 全文 AI 校对。
          IconButton(
            icon: const Icon(Icons.fact_check_outlined, size: 18),
            tooltip: '全文 AI 校对',
            visualDensity: VisualDensity.compact,
            onPressed: onProofread,
          ),
          // 存入存稿箱。
          IconButton(
            icon: const Icon(Icons.inventory_2_outlined, size: 18),
            tooltip: '存入存稿箱',
            visualDensity: VisualDensity.compact,
            onPressed: onSaveDraft,
          ),
          // 番茄钟。
          TextButton.icon(
            onPressed: onTogglePomodoro,
            icon: Icon(
              pomodoroRunning ? Icons.timer_off : Icons.timer_outlined,
              size: 16,
            ),
            label: Text(pomodoroRunning ? pomodoroLabel : '番茄钟'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
          if (check != null)
            SensitiveBadge(check: check!, onTap: onShowCheck),
          const SizedBox(width: 8),
          if (saved) const SavedBadge() else const Chip(label: Text('编辑中')),
        ],
      ),
    );
  }
}
