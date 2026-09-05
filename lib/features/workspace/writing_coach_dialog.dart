import 'package:flutter/material.dart';

import 'package:novel_writer/core/constants/app_constants.dart';

/// 写作教练分析结果。
class WritingAnalysis {
  final String label;
  final String value;
  final String suggestion;
  final Color color;

  const WritingAnalysis({
    required this.label,
    required this.value,
    required this.suggestion,
    required this.color,
  });
}

/// 写作教练弹窗：分析正文给出"展示非陈述/AI回声/节奏"等建议。
class WritingCoachDialog {
  static Future<void> show(BuildContext context, String content) async {
    final analyses = _analyze(content);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.psychology_outlined),
            SizedBox(width: 8),
            Text('写作教练'),
          ],
        ),
        content: SizedBox(
          width: 500,
          height: 400,
          child: ListView(
            children: analyses.map((a) => _analysisCard(a)).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static Widget _analysisCard(WritingAnalysis a) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: a.color.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(a.label,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: a.color)),
                ),
                const Spacer(),
                Text(a.value,
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: a.color)),
              ],
            ),
            const SizedBox(height: 6),
            Text(a.suggestion, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }

  static List<WritingAnalysis> _analyze(String text) {
    final words = AppConstants.countWords(text);
    final results = <WritingAnalysis>[];

    // 1. AI 回声
    final aiEchoes = _countAiEcho(text);
    final echoRate = words > 0 ? (aiEchoes / words * 1000) : 0.0;
    results.add(WritingAnalysis(
      label: 'AI 回声',
      value: '${echoRate.toStringAsFixed(1)}/千字',
      suggestion: echoRate < 2
          ? '表现优秀，AI 痕迹极低。'
          : echoRate < 5
              ? '尚可，但可减少"仿佛/似乎/微微一笑"等套话。'
              : '套话密度偏高，建议改写 AI 味重的段落。',
      color: echoRate < 2 ? Colors.green : echoRate < 5 ? Colors.orange : Colors.red,
    ));

    // 2. 展示非陈述
    final telling = _countTelling(text);
    final showRatio = words > 0 ? (1 - telling / words) * 100 : 100.0;
    results.add(WritingAnalysis(
      label: '展示 vs 陈述',
      value: '${showRatio.toStringAsFixed(0)}% 展示',
      suggestion: showRatio > 60
          ? '良好，多数描写通过动作/细节外化情绪。'
          : '建议减少"他很愤怒/她很难过"式陈述，改为动作和表情。',
      color: showRatio > 60 ? Colors.green : Colors.orange,
    ));

    // 3. 对话密度
    final dialogue = _countDialogue(text);
    final dialRatio = words > 0 ? (dialogue / words * 100) : 0.0;
    results.add(WritingAnalysis(
      label: '对话密度',
      value: '${dialRatio.toStringAsFixed(1)}%',
      suggestion: dialRatio > 15
          ? '对话丰富，节奏活跃。'
          : dialRatio > 5
              ? '对话适中，可酌情增加对话推进情节。'
              : '对话偏少，考虑用对话替代部分旁白推进。',
      color: dialRatio > 15 ? Colors.green : dialRatio > 5 ? Colors.blue : Colors.orange,
    ));

    // 4. 句式节奏
    final rhythm = _analyzeRhythm(text);
    results.add(WritingAnalysis(
      label: '句式节奏',
      value: '${rhythm['avgLen']?.toStringAsFixed(0)} 字/句',
      suggestion: rhythm['score'] == 'good'
          ? '长短句交替良好，阅读节奏舒适。'
          : '句式趋于单一，建议增加短句营造紧张感或长句铺陈描写。',
      color: rhythm['score'] == 'good' ? Colors.green : Colors.orange,
    ));

    // 5. 词汇多样性
    final diversity = _vocabularyDiversity(text);
    results.add(WritingAnalysis(
      label: '词汇多样性',
      value: '${(diversity * 100).toStringAsFixed(0)}%',
      suggestion: diversity > 0.6
          ? '词汇丰富，重复率低。'
          : diversity > 0.4
              ? '可接受，部分高频词可替换为同义表达。'
              : '词汇重复偏高，注意替换高频动词和形容词。',
      color: diversity > 0.6 ? Colors.green : diversity > 0.4 ? Colors.orange : Colors.red,
    ));

    return results;
  }

  static int _countAiEcho(String text) {
    final patterns = [
      RegExp(r'仿佛|似乎|宛如'), // 限制使用
      RegExp(r'微微一笑|轻轻一笑'),
      RegExp(r'深吸一口气|呼出一口气'),
      RegExp(r'目光一沉|眼中闪过'),
      RegExp(r'刹那间|一瞬间|下一刻|紧接着'),
      RegExp(r'不禁|忍不住|不由自主'),
      RegExp(r'仿佛一切|似乎有什么'),
      RegExp(r'沉重的|无形的|莫名的'),
    ];
    int total = 0;
    for (final p in patterns) {
      total += p.allMatches(text).length;
    }
    return total;
  }

  static int _countTelling(String text) {
    final patterns = [
      RegExp(r'很[高兴愤怒紧张害怕委屈失望]'),
      RegExp(r'[感到觉得感觉]到?[莫名无限深深]'),
      RegExp(r'心中[充满涌起泛起]'),
    ];
    int total = 0;
    for (final p in patterns) {
      total += p.allMatches(text).length;
    }
    return total;
  }

  static int _countDialogue(String text) {
    return RegExp(r'「[^」]*」').allMatches(text).length;
  }

  static Map<String, dynamic> _analyzeRhythm(String text) {
    final sentences = text.split(RegExp(r'[。！？；\n]'));
    final lens = sentences
        .map((s) => s.trim().length)
        .where((l) => l > 0)
        .toList();
    if (lens.isEmpty) return {'avgLen': 0, 'score': 'good'};
    final avg = lens.reduce((a, b) => a + b) / lens.length;
    // 检查方差：有短有长才好
    final shortCount = lens.where((l) => l <= 10).length;
    final longCount = lens.where((l) => l >= 30).length;
    final score = (shortCount > lens.length * 0.2 && longCount > lens.length * 0.1) ? 'good' : 'mono';
    return {'avgLen': avg, 'score': score};
  }

  static double _vocabularyDiversity(String text) {
    // 用字符级 unique 率近似
    final chars = text.runes.toList();
    if (chars.isEmpty) return 0;
    final unique = chars.toSet().length;
    return unique / chars.length;
  }
}
