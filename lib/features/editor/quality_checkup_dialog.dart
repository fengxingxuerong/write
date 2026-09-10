import 'package:flutter/material.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';

/// 单项体检结果。
class CheckupMetric {
  /// 构造。
  const CheckupMetric({
    required this.label,
    required this.valueText,
    required this.ok,
    this.detail,
  });

  /// 指标名（如「AI 腔浓度」）。
  final String label;

  /// 展示值（如「3.2/百字（低）」）。
  final String valueText;

  /// 是否达标（绿）。
  final bool ok;

  /// 补充说明（问题列表/建议）。
  final String? detail;
}

/// 章节质量体检：纯本地启发式检测，不调用 AI、不上传内容。
///
/// 检测维度对应网文编辑常见的退稿理由（AI 味/段落节奏/对话占比），
/// 结果只做参考：分数低不代表写得差，只提示「编辑可能盯这些点」。
abstract final class QualityCheckup {
  /// AI 高频起手词 / 万能连接词（整段以这些词开头时显著拉高 AI 嫌疑）。
  static const List<String> aiOpeners = <String>[
    '突然', '瞬间', '似乎', '仿佛', '显然', '事实上', '然而', '与此同时',
    '于是', '随后', '紧接着', '不知不觉', '一瞬间', '那一刻', '竟然', '居然',
  ];

  /// 万能形容词（堆叠时拉高 AI 嫌疑）。
  static const List<String> aiFillers = <String>[
    '无法言喻', '难以形容', '说不出', '某种', '一丝', '一抹', '深深地',
    '缓缓地', '静静地', '默默地', '淡淡地', '轻轻地',
  ];

  /// 长段落阈值：超过该字符数的段落建议拆分。
  static const int longParagraphLimit = 200;

  /// 检测正文，返回分数（10~100）与各维度结果。
  static (int score, List<CheckupMetric> metrics) analyze(String content) {
    final String text = content.trim();
    if (text.isEmpty) {
      return (
        100,
        <CheckupMetric>[
          const CheckupMetric(
            label: '空章节',
            valueText: '—',
            ok: true,
            detail: '暂无内容可检测。',
          ),
        ],
      );
    }

    // ---- 分段（空行/单换行都算段落边界） ----
    final List<String> paragraphs = text
        .split(RegExp(r'\n\s*\n|\n'))
        .map((String p) => p.trim())
        .where((String p) => p.isNotEmpty)
        .toList();
    final int paraCount = paragraphs.length;

    // ---- 1. AI 腔：起手词 + 万能形容词 ----
    int openerHits = 0;
    final List<String> openerSamples = <String>[];
    for (final String p in paragraphs) {
      for (final String w in aiOpeners) {
        if (p.startsWith(w)) {
          openerHits++;
          if (openerSamples.length < 3) {
            final int end = p.length.clamp(0, 18);
            openerSamples.add('「${p.substring(0, end)}…」');
          }
          break;
        }
      }
    }
    int fillerHits = 0;
    for (final String w in aiFillers) {
      fillerHits += w.allMatches(text).length;
    }
    final double per100 = text.length / 100;
    final double aiDensity =
        (openerHits * 2.0 + fillerHits) / (per100 == 0 ? 1 : per100);
    final bool aiOk = aiDensity < 1.2;

    // ---- 2. 段落节奏 ----
    final double avgLen = paraCount == 0 ? 0 : text.length / paraCount;
    final int longParas = paragraphs
        .where((String p) => p.length > longParagraphLimit)
        .length;
    final bool rhythmOk = longParas == 0 && avgLen < 120;

    // ---- 3. 连续段落同起手 ----
    int dupPairs = 0;
    final List<String> dupSamples = <String>[];
    for (int i = 1; i < paragraphs.length; i++) {
      final String a = paragraphs[i - 1];
      final String b = paragraphs[i];
      const int n = 2;
      if (a.length >= n &&
          b.length >= n &&
          a.substring(0, n) == b.substring(0, n)) {
        dupPairs++;
        if (dupSamples.length < 3) dupSamples.add('「${b.substring(0, n)}…」');
      }
    }
    final bool dupOk = dupPairs <= 1;

    // ---- 4. 对话占比 ----
    final String dialogueOnly = text
        .split('\n')
        .where((String l) =>
            l.trim().startsWith('「') || l.trim().startsWith('"'))
        .join('');
    final double dialogueRate =
        text.isEmpty ? 0 : dialogueOnly.length / text.length;
    final bool dialogueOk = dialogueRate >= 0.10 && dialogueRate <= 0.60;

    // ---- 打分（扣分制） ----
    int score = 100;
    if (!aiOk) score -= 30;
    if (!rhythmOk) score -= 25;
    if (!dupOk) score -= 20;
    if (!dialogueOk) score -= 15;
    score = score.clamp(10, 100);

    final List<CheckupMetric> metrics = <CheckupMetric>[
      CheckupMetric(
        label: 'AI 腔浓度',
        valueText:
            '${aiDensity.toStringAsFixed(1)}/百字（${aiOk ? "低" : "偏高"}）',
        ok: aiOk,
        detail: aiOk
            ? null
            : <String>[
                if (openerHits > 0)
                  '起手词命中 $openerHits 段：${openerSamples.join("、")}',
                if (fillerHits > 0)
                  '万能形容（一丝/仿佛/无法言喻类）出现 $fillerHits 次',
                '建议：把「突然/似乎」类开头改为动作或对话直入',
              ].join('\n'),
      ),
      CheckupMetric(
        label: '段落节奏',
        valueText:
            '平均 ${avgLen.toStringAsFixed(0)} 字/段 · 长段（>$longParagraphLimit 字）$longParas 个',
        ok: rhythmOk,
        detail: rhythmOk
            ? null
            : '长段会被判定「信息密度低」，建议在转折处拆段（目标 ≤ $longParagraphLimit 字/段）。',
      ),
      CheckupMetric(
        label: '重复句式',
        valueText: dupPairs == 0
            ? '未见连续段落同起手'
            : '$dupPairs 处：${dupSamples.join("、")}',
        ok: dupOk,
        detail: dupOk ? null : '连续段落用同一个词开头是明显模板痕迹，建议改写其中一段的起句。',
      ),
      CheckupMetric(
        label: '对话占比',
        valueText:
            '${(dialogueRate * 100).toStringAsFixed(0)}%（${dialogueOk ? "适中" : dialogueRate < 0.10 ? "偏少" : "偏多"}）',
        ok: dialogueOk,
        detail: dialogueOk
            ? null
            : dialogueRate < 0.10
                ? '对话过少会让章节「讲述多、展示少」，建议补人物交锋。'
                : '对话占比过高会稀释场景描写，建议补环境与动作细节。',
      ),
    ];
    return (score, metrics);
  }
}

/// 打开章节质量体检弹窗。
Future<void> showQualityCheckupDialog(
  BuildContext context, {
  required String title,
  required String content,
}) {
  final (int score, List<CheckupMetric> metrics) =
      QualityCheckup.analyze(content);
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => QualityCheckupDialog(
      title: title,
      score: score,
      metrics: metrics,
    ),
  );
}

/// 章节质量体检弹窗：总分环 + 四维度结果。
class QualityCheckupDialog extends StatelessWidget {
  /// 构造。
  const QualityCheckupDialog({
    super.key,
    required this.title,
    required this.score,
    required this.metrics,
  });

  /// 章节标题。
  final String title;

  /// 总分（10~100）。
  final int score;

  /// 各维度结果。
  final List<CheckupMetric> metrics;

  Color _scoreColor(BuildContext context) {
    if (score >= 85) return Colors.green;
    if (score >= 65) return Colors.orange;
    return Theme.of(context).colorScheme.error;
  }

  String _verdict() {
    if (score >= 85) return '状态良好，可放心投稿';
    if (score >= 65) return '有小瑕疵，建议按下方建议微调';
    return 'AI 痕迹偏重，建议重点改写';
  }

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Color sc = _scoreColor(context);
    return AlertDialog(
      title: Text('质量体检 · $title'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // ---- 总分环 ----
              Center(
                child: SizedBox(
                  width: 118,
                  height: 118,
                  child: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      SizedBox(
                        width: 118,
                        height: 118,
                        child: CircularProgressIndicator(
                          value: score / 100,
                          strokeWidth: 8,
                          color: sc,
                          backgroundColor: ink.divider,
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text('$score',
                              style: AppFonts.text(sc,
                                  size: 34, weight: FontWeight.w800)),
                          Text('分',
                              style:
                                  AppFonts.text(ink.inkFaint, size: 12)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(_verdict(),
                    style: AppFonts.text(ink.inkSoft, size: 13)),
              ),
              const SizedBox(height: AppTokens.s3),
              // ---- 各维度 ----
              for (final CheckupMetric m in metrics) ...<Widget>[
                Container(
                  padding: const EdgeInsets.all(AppTokens.s2),
                  decoration: BoxDecoration(
                    color: m.ok
                        ? Colors.green.withValues(alpha: 0.06)
                        : sc.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(AppTokens.r2),
                    border: Border.all(
                      color:
                          (m.ok ? Colors.green : sc).withValues(alpha: 0.35),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            m.ok
                                ? Icons.check_circle_outline
                                : Icons.warning_amber_rounded,
                            size: 15,
                            color: m.ok ? Colors.green : sc,
                          ),
                          const SizedBox(width: 6),
                          Text(m.label,
                              style: AppFonts.text(ink.ink,
                                  size: 13.5, weight: FontWeight.w700)),
                          const Spacer(),
                          Text(m.valueText,
                              style: AppFonts.text(m.ok ? ink.inkSoft : sc,
                                  size: 12.5, monoFace: true)),
                        ],
                      ),
                      if (m.detail != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(m.detail!,
                            style: AppFonts.text(ink.inkFaint,
                                size: 12, height: 1.55)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 6),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }
}