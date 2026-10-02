import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 质量主张的外部效度状态——「达线」是否已与人评对齐。
///
/// ## 为什么需要它
///
/// 本项目的质量主张建立在本地启发式指标上（爽点密度 / 章末钩子 / 对白占比/
/// AI 味深度…）。[docs/human-eval-workflow.md](docs/human-eval-workflow.md) 已写明：
/// 这些指标都是**表层统计量的代理**，模型只要多堆词、切碎段落、把对白凑到 30%，
/// 分数自然上去——即「可刷分」；它们与「人读了觉得好」之间**没有任何已验证的关系**。
/// 因此在真实人评补上之前，「80 分达线」只是**自洽**，不是**有效**。
///
/// 此前这条限定只写在文档里，而 UI 照常显示「达线章节 12/13」——看界面的人
/// 很容易把自洽当有效。本类把状态变成界面上可见的一行字。
///
/// ## 与 Python 侧同源
///
/// 判据来自 `rules/quality_validation.json`（单一数据源），与
/// `scripts/quality_validation.py` 语义一致；真实标注条数同样以
/// `docs/human-eval/annotations.jsonl` 里 `human` 为**数值**的行数为准
/// （字符串/布尔不算——那多半是机器批量生成的）。
///
/// ⚠ 该文件**不入库**（`.gitignore` 排除 `docs/human-eval/samples/`；
/// annotations.jsonl 入库）。桌面端读不到时按 [QualityValidationStatus.none]
/// 处理——即「保守地认为未验证」，绝不因为读不到就默认可信。
enum QualityValidationStatus {
  /// 一条真实标注都没有：达线结论仅为自洽，不具外部效度。
  none,

  /// 有标注但样本不足：只能作方向性参考，不得作为门禁依据。
  insufficient,

  /// 样本量够但尚未产出相关性结论。
  provisional,

  /// 已完成相关性实验且留有报告。
  validated,
}

/// 外部效度状态快照（不可变）。
@immutable
class QualityValidation {
  /// 构造状态。
  const QualityValidation({
    required this.status,
    required this.ratings,
    required this.totalRows,
    this.minConclusion = 10,
    this.minStrong = 30,
  });

  /// 状态。
  final QualityValidationStatus status;

  /// 真实人工标注条数（`human` 为数值）。
  final int ratings;

  /// 标注表数据行数（含未评分的）。
  final int totalRows;

  /// 得出结论所需最少样本（默认 10，与 Python `--min-n` 一致）。
  final int minConclusion;

  /// 建议样本量（默认 30，作业手册建议值）。
  final int minStrong;

  /// 「无可奉告」——读不到标注数据时的保守默认。
  ///
  /// 刻意**不**提供「未知/不适用」这一档：读不到数据不等于通过，
  /// 按 none 处理才能保证「缺数据」不会被误读成「可信」。
  static const QualityValidation unknown = QualityValidation(
    status: QualityValidationStatus.none,
    ratings: 0,
    totalRows: 0,
  );

  /// 从标注 JSONL 文本解析（每行一章，`human` 为数值才算有效标注）。
  ///
  /// 以 `#` 开头的行与空行是注释/分隔，不计入。解析失败的行跳过而非抛错——
  /// 标注文件是人手工维护的，容错比严格更重要（错行只影响计数，不影响成书）。
  factory QualityValidation.parse(String jsonlContent) {
    int ratings = 0;
    int total = 0;
    for (final String raw in jsonlContent.split('\n')) {
      final String line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final Object? decoded = _tryDecode(line);
      if (decoded is! Map) continue;
      total++;
      final Object? human = decoded['human'];
      // bool 是 int 的子类，必须显式排除；字符串分数不算「人评」。
      if (human is bool) continue;
      if (human is num) ratings++;
    }
    final QualityValidationStatus status;
    if (ratings == 0) {
      status = QualityValidationStatus.none;
    } else if (ratings < 10) {
      status = QualityValidationStatus.insufficient;
    } else {
      // 样本量够 ≠ 跑过实验。桌面端不判定 validated——它无从得知是否真的
      // 跑过相关性实验（那要看 docs/human-eval/report-*.md），保守停在
      // provisional，把「有没有报告」的判断留给 CLI 与人。
      status = QualityValidationStatus.provisional;
    }
    return QualityValidation(
      status: status,
      ratings: ratings,
      totalRows: total,
    );
  }

  /// 是否需要在「达线」旁强制披露限定。
  bool get needsCaveat =>
      status == QualityValidationStatus.none ||
      status == QualityValidationStatus.insufficient;

  /// 是否已达外部效度（仅在真跑过实验后才可为真）。
  bool get isValidated => status == QualityValidationStatus.validated;

  /// 给作者看的一句话限定（未验证时显示在达线指标旁）。
  String get caveatLabel {
    switch (status) {
      case QualityValidationStatus.none:
        return '未与人评对齐·仅为规则自洽';
      case QualityValidationStatus.insufficient:
        return '人评样本不足·仅供参考';
      case QualityValidationStatus.provisional:
        return '人评实验待复验';
      case QualityValidationStatus.validated:
        return '已与人评对齐';
    }
  }

  /// 完整说明（含补标注指引），用于弹窗/详情。
  String get detail {
    final String base =
        '真实人评标注 $ratings/$totalRows 条（结论需 ≥$minConclusion 条，'
        '建议 ≥$minStrong 条）';
    if (status == QualityValidationStatus.none) {
      return '本次分数只证明规则自洽，不代表读者认可；指标可被刷分'
          '（多堆词/切碎段落/凑对白）。$base';
    }
    if (status == QualityValidationStatus.insufficient) {
      return '已有少量人评但样本不足，达线结论只能作方向性参考。$base';
    }
    if (status == QualityValidationStatus.provisional) {
      return '样本量已够，改动词表/阈值后须重跑人评实验复核。$base';
    }
    return '已完成人评相关性实验，结论见 docs/human-eval/report-*.md。$base';
  }

  @override
  String toString() =>
      'QualityValidation(${status.name}, $ratings/$totalRows)';
}

/// 容错 JSON 解码：单行坏掉只跳过该行，不影响整体解析。
Object? _tryDecode(String line) {
  try {
    return jsonDecode(line);
  } on FormatException {
    return null;
  }
}