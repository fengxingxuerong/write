import 'package:flutter/material.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/widgets/app_card.dart';

/// 通用空态组件。
///
/// 空态是产品最容易偷懒、也最容易被用户判「没做完」的地方：这里给图标底、
/// 主副文案与一个明确的下一步动作。
class EmptyState extends StatelessWidget {
  /// 提示文案。
  final String message;

  /// 图标。
  final IconData icon;

  /// 副文案（解释为什么空、下一步做什么）。
  final String? hint;

  /// 主行动按钮文案。
  final String? actionLabel;

  /// 主行动回调。
  final VoidCallback? onAction;

  /// 次要行动。
  final String? secondaryLabel;

  /// 次要行动回调。
  final VoidCallback? onSecondary;

  /// 构造空态。
  const EmptyState({
    super.key,
    this.message = '暂无内容',
    this.icon = Icons.inbox_outlined,
    this.hint,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: ink.primary.withValues(alpha: ink.dark ? 0.14 : 0.08),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: ink.primary.withValues(alpha: 0.18),
                  ),
                ),
                child: Icon(icon, size: 28, color: ink.primary),
              ),
              const SizedBox(height: AppTokens.s4),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppFonts.text(ink.ink,
                    size: 15.5, weight: FontWeight.w600, height: 1.5),
              ),
              if (hint != null) ...<Widget>[
                const SizedBox(height: AppTokens.s2),
                Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: AppFonts.text(ink.inkSoft, size: 13, height: 1.7),
                ),
              ],
              if (actionLabel != null && onAction != null) ...<Widget>[
                const SizedBox(height: AppTokens.s4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: onAction,
                      icon: const Icon(Icons.add, size: 16),
                      label: Text(actionLabel!),
                    ),
                    if (secondaryLabel != null && onSecondary != null)
                      Padding(
                        padding: const EdgeInsets.only(left: AppTokens.s2),
                        child: TextButton(
                            onPressed: onSecondary,
                            child: Text(secondaryLabel!)),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 「已保存」状态指示小标签。
class SavedBadge extends StatelessWidget {
  /// 构造标签。
  const SavedBadge({super.key, this.label = '已保存'});

  /// 文案（可传入「保存中…」等）。
  final String label;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final bool saved = label == '已保存';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.s2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: saved ? ink.success : ink.warn,
            ),
          ),
          const SizedBox(width: AppTokens.s2 - 2),
          Text(
            label,
            style: AppFonts.text(ink.inkFaint,
                size: 12, height: 1.3, monoFace: true),
          ),
        ],
      ),
    );
  }
}

/// 带标题的分区卡片（保留旧签名，样式统一走 [AppCard]）。
class SectionCard extends StatelessWidget {
  /// 标题。
  final String title;

  /// 内容。
  final List<Widget> children;

  /// 可选操作按钮。
  final List<Widget>? actions;

  /// 构造分区卡片。
  const SectionCard({
    super.key,
    required this.title,
    required this.children,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.s2),
      child: AppCard(
        title: title,
        actions: actions,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

/// 单行文本输入对话框（重命名等轻录入）。
///
/// 返回 `null` 代表取消；空串与纯空白会被当场拦下，不会把空标题丢给仓库。
Future<String?> showTextPromptDialog(
  BuildContext context, {
  required String title,
  required String label,
  String? initial,
  String confirmLabel = '保存',
  String? hint,
  String? Function(String value)? validate,
}) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext ctx) => _TextPromptDialog(
      title: title,
      label: label,
      initial: initial,
      confirmLabel: confirmLabel,
      hint: hint,
      validate: validate,
    ),
  );
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.confirmLabel,
    required this.hint,
    required this.validate,
  });

  final String title;
  final String label;
  final String? initial;
  final String confirmLabel;
  final String? hint;
  final String? Function(String value)? validate;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial ?? '');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _controller.text.trim();
    final String? err =
        value.isEmpty ? '不能为空' : widget.validate?.call(value);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _controller,
          autofocus: true,
          onSubmitted: (_) => _submit(),
          style: AppFonts.text(ink.ink, size: 14, height: 1.5),
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            errorText: _error,
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 通用确认对话框。
///
/// 破坏性操作（删除、覆盖）请传 [danger]，按钮换危险色并在文案前加图标，
/// 避免「确定」长得跟普通操作一样。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  bool danger = false,
  IconData? icon,
}) async {
  final AppInk ink = AppInk.of(context);
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      icon: Icon(
        icon ?? (danger ? Icons.delete_forever_outlined : Icons.help_outline),
        color: danger ? ink.danger : ink.primary,
      ),
      title: Text(title, textAlign: TextAlign.center),
      content: SingleChildScrollView(
        child: Text(
          content,
          style: Theme.of(ctx).textTheme.bodyMedium,
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          autofocus: true,
          style: danger
              ? FilledButton.styleFrom(backgroundColor: ink.danger)
              : null,
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
