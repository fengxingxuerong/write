import 'package:flutter/material.dart';

/// 分支节点：一个抉择点对后续情节的影响。
class BranchNode {
  final String label;
  final String description;
  final String impact;
  bool isSelected;

  BranchNode({
    required this.label,
    required this.description,
    required this.impact,
    this.isSelected = false,
  });
}

/// 多结局分支弹窗：在关键抉择点展示不同走向，选择后重新生成下游大纲。
class BranchTreeDialog {
  static Future<BranchNode?> show(
    BuildContext context, {
    required String chapterTitle,
    required List<BranchNode> options,
  }) {
    return showDialog<BranchNode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.account_tree, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text('分支抉择：$chapterTitle',
                  style: const TextStyle(fontSize: 16)),
            ),
          ],
        ),
        content: SizedBox(
          width: 500,
          height: 350,
          child: ListView.builder(
            itemCount: options.length,
            itemBuilder: (context, index) {
              final opt = options[index];
              final isSelected = opt.isSelected;
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                color: isSelected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                child: InkWell(
                  onTap: () {
                    // 单选
                    for (final o in options) {
                      o.isSelected = false;
                    }
                    opt.isSelected = true;
                    // 触发重建（简化版：使用 StatefulBuilder 不足以跨 widget，这里直接关闭）
                    Navigator.pop(ctx, opt);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              isSelected
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 18,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              opt.label,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(opt.description,
                            style: const TextStyle(fontSize: 13)),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.trending_up,
                                  size: 14, color: Colors.amber),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '后续影响：${opt.impact}',
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.black87),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}
