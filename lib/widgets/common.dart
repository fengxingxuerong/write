import 'package:flutter/material.dart';

/// 通用空态组件。
class EmptyState extends StatelessWidget {
  /// 提示文案。
  final String message;

  /// 图标。
  final IconData icon;

  /// 构造空态。
  const EmptyState({
    super.key,
    this.message = '暂无内容',
    this.icon = Icons.inbox_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 48, color: theme.disabledColor),
          const SizedBox(height: 12),
          Text(
            message,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.disabledColor),
          ),
        ],
      ),
    );
  }
}

/// 「已保存」状态指示小标签。
class SavedBadge extends StatelessWidget {
  /// 构造标签。
  const SavedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return const Chip(
      avatar: Icon(Icons.check_circle_outline, size: 16),
      label: Text('已保存'),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// 带标题的分区卡片。
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
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (actions != null) ...actions!,
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// 通用确认对话框。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
}) async {
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
