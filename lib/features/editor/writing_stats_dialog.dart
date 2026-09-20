import 'package:flutter/material.dart';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';

/// 写作统计数据。
class WritingStats {
  /// 当前章节总字数。
  final int wordCount;

  /// 段落数（按空行 / 换行分隔的非空块）。
  final int paragraphCount;

  /// 句子数（按。！？…分句）。
  final int sentenceCount;

  /// 本次会话新增字数（进入本章时的字数 vs 当前字数，负值归 0）。
  final int sessionAdded;

  /// 平均句长（字数 / 句数，无句时为 0）。
  final double avgSentenceLength;

  /// 构造统计。
  const WritingStats({
    required this.wordCount,
    required this.paragraphCount,
    required this.sentenceCount,
    required this.sessionAdded,
    required this.avgSentenceLength,
  });
}

/// 从正文计算写作统计。
WritingStats computeWritingStats(String text, {int initialWords = 0}) {
  final int words = AppConstants.countWords(text);
  final List<String> paragraphs = text
      .split(RegExp(r'\n\s*\n|\n'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  final int sentenceCount =
      RegExp(r'[。！？…]+|!|\?').allMatches(text).length;
  final int added = words - initialWords < 0 ? 0 : words - initialWords;
  return WritingStats(
    wordCount: words,
    paragraphCount: paragraphs.length,
    sentenceCount: sentenceCount,
    sessionAdded: added,
    avgSentenceLength: sentenceCount == 0
        ? 0
        : double.parse((words / sentenceCount).toStringAsFixed(1)),
  );
}

/// 写作统计弹窗：字数 / 段落 / 句子 / 本次新增 / 平均句长。
Future<void> showWritingStatsDialog(
  BuildContext context, {
  required WritingStats stats,
  required int targetWords,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) {
      final ThemeData theme = Theme.of(ctx);
      final int progress = stats.wordCount * 100 ~/ (targetWords <= 0 ? 1 : targetWords);
      final bool reached = targetWords > 0 && stats.wordCount >= targetWords;
      return AlertDialog(
        title: const Text('📊 写作统计'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 字数目标进度。
              Text(
                targetWords > 0
                    ? '字数目标：${stats.wordCount} / $targetWords 字'
                    : '字数：${stats.wordCount} 字',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: AppTokens.s2),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppTokens.r1),
                child: LinearProgressIndicator(
                  value: (progress / 100).clamp(0.0, 1.0),
                  minHeight: 8,
                  color: reached ? AppInk.of(ctx).success : null,
                ),
              ),
              const SizedBox(height: AppTokens.s1 + 2),
              Text(
                reached
                    ? '🎉 已达成本章字数目标！'
                    : '还差 ${targetWords - stats.wordCount} 字达标',
                style: TextStyle(
                  fontSize: 12,
                  color:
                      reached ? AppInk.of(ctx).success : theme.colorScheme.outline,
                ),
              ),
              const Divider(height: 24),
              _row(ctx, '当前字数', '${stats.wordCount} 字'),
              _row(ctx, '本次新增', '+${stats.sessionAdded} 字'),
              _row(ctx, '段落数', '${stats.paragraphCount} 段'),
              _row(ctx, '句子数', '${stats.sentenceCount} 句'),
              _row(ctx, '平均句长', '${stats.avgSentenceLength} 字/句'),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}

Widget _row(BuildContext context, String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
        Text(value, style: Theme.of(context).textTheme.bodyMedium),
      ],
    ),
  );
}
