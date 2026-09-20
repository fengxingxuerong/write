import 'package:flutter/material.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';

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
      builder: (BuildContext ctx) {
        final AppInk ink = AppInk.of(ctx);
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.account_tree, size: 22, color: ink.primary),
              const SizedBox(width: AppTokens.s2),
              Expanded(
                child: Text('分支抉择：$chapterTitle',
                    style: AppFonts.text(ink.ink,
                        size: 16, weight: FontWeight.w600, height: 1.4)),
              ),
            ],
          ),
        content: SizedBox(
          width: 500,
          height: 350,
          child: ListView.builder(
            itemCount: options.length,
            itemBuilder: (BuildContext context, int index) {
              final BranchNode opt = options[index];
              final bool isSelected = opt.isSelected;
              return Card(
                margin: const EdgeInsets.only(bottom: AppTokens.s3),
                color: isSelected
                    ? ink.primary.withValues(alpha: ink.dark ? 0.20 : 0.10)
                    : null,
                child: InkWell(
                  onTap: () {
                    // 单选
                    for (final BranchNode o in options) {
                      o.isSelected = false;
                    }
                    opt.isSelected = true;
                    // 触发重建（简化版：使用 StatefulBuilder 不足以跨 widget，这里直接关闭）
                    Navigator.pop(ctx, opt);
                  },
                  borderRadius: AppTokens.radiusCard,
                  child: Padding(
                    padding: const EdgeInsets.all(AppTokens.s3),
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
                              color: isSelected ? ink.primary : ink.inkFaint,
                            ),
                            const SizedBox(width: AppTokens.s2),
                            Text(
                              opt.label,
                              style: AppFonts.text(ink.ink,
                                  size: 15,
                                  weight: FontWeight.w600,
                                  height: 1.4),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppTokens.s1),
                        Text(opt.description,
                            style: AppFonts.text(ink.inkSoft,
                                size: 13, height: 1.5)),
                        const SizedBox(height: AppTokens.s1 + 2),
                        Container(
                          padding: const EdgeInsets.all(AppTokens.s1 + 2),
                          decoration: BoxDecoration(
                            color: ink.warn
                                .withValues(alpha: ink.dark ? 0.16 : 0.10),
                            borderRadius:
                                BorderRadius.circular(AppTokens.r1),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.trending_up,
                                  size: 14, color: ink.warn),
                              const SizedBox(width: AppTokens.s1),
                              Expanded(
                                child: Text(
                                  '后续影响：${opt.impact}',
                                  style: AppFonts.text(ink.ink,
                                      size: 11, height: 1.4),
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
        );
      },
    );
  }
}
