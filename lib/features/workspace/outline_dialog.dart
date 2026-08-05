import 'package:flutter/material.dart';

/// 章节大纲编辑对话框。
///
/// 允许编辑单章大纲（要点列表，每行一个要点），返回编辑后的字符串。
/// 返回 `null` 表示取消；返回字符串（可为空）表示保存。
Future<String?> showOutlineDialog(
  BuildContext context, {
  required String chapterTitle,
  String initial = '',
}) {
  final TextEditingController controller =
      TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: Text('章节大纲：$chapterTitle'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 12,
          decoration: const InputDecoration(
            hintText: '本章要点，每行一个。\n例：\n主角到达天玄城\n遇到神秘老者\n获得修炼功法\n',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('保存'),
        ),
      ],
    ),
  ).whenComplete(() {
    controller.dispose();
  });
}
