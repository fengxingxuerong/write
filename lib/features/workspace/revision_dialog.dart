import 'package:flutter/material.dart';

/// 修订模式弹窗：对比原文与AI修订版，接受或拒绝修订。
class RevisionDialog {
  /// 打开修订弹窗。[original] 为选中的片段，[revised] 为 AI 修订版。
  static Future<String?> show(
    BuildContext context, {
    required String original,
    required String revised,
  }) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.difference_outlined),
            SizedBox(width: 8),
            Text('AI 修订'),
          ],
        ),
        content: SizedBox(
          width: 600,
          height: 400,
          child: Row(
            children: [
              // 原文
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      color: Colors.red.withValues(alpha: 0.1),
                      child: const Text('原文',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: SelectableText(original,
                            style: const TextStyle(fontSize: 13, height: 1.5)),
                      ),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              // 修订版
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      color: Colors.green.withValues(alpha: 0.1),
                      child: const Text('AI 修订版',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: SelectableText(revised,
                            style: const TextStyle(fontSize: 13, height: 1.5)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.undo, size: 16),
            label: const Text('保留原文'),
            onPressed: () => Navigator.pop(ctx, original),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.check, size: 16),
            label: const Text('采用修订版'),
            onPressed: () => Navigator.pop(ctx, revised),
          ),
        ],
      ),
    );
  }
}
