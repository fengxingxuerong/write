import 'package:flutter/material.dart';

/// 自动章节分割弹窗：确认分割方案。
///
/// 按「空行分隔的段落块」将当前章节拆成多章，每块 >= [minChars] 才独立成章，
/// 其余并入前一块。返回分割后的段落列表；取消返回 null。
Future<List<String>?> showSplitChapterDialog(
  BuildContext context, {
  required String chapterTitle,
  required List<String> parts,
  required int minChars,
}) async {
  // 合并过短块：短块并入前一块，保证成章内容足够。
  final List<String> merged = <String>[];
  for (final String p in parts) {
    if (p.trim().length < minChars && merged.isNotEmpty) {
      merged[merged.length - 1] =
          '${merged[merged.length - 1]}\n\n${p.trim()}';
    } else {
      merged.add(p.trim());
    }
  }
  final List<String> finalParts =
      merged.where((p) => p.isNotEmpty).toList();
  if (finalParts.length <= 1) {
    return null; // 无需分割。
  }

  return showDialog<List<String>>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: const Text('✂️ 自动章节分割'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '「$chapterTitle」将拆分为 ${finalParts.length} 章：',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: finalParts.length,
                  itemBuilder: (BuildContext c, int i) {
                    final String preview = finalParts[i]
                        .replaceAll(RegExp(r'\s+'), ' ');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '第${i + 1}章',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              preview.length > 60
                                  ? '${preview.substring(0, 60)}…'
                                  : preview,
                              style: const TextStyle(fontSize: 13),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(finalParts),
          child: const Text('确认拆分'),
        ),
      ],
    ),
  );
}
