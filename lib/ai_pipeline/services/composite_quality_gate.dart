import 'dart:math' as math;

import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/engine/quality/fanqie_gate_checker.dart';
import 'package:novel_writer/engine/quality/novel_quality_checker.dart';
import 'package:novel_writer/engine/quality/quality_gate.dart';

/// 组合质检网关：把三套本地质检合并为一次统一检查。
///
/// 组合来源（全部零 LLM、零网络）：
/// 1. `NovelQualityChecker` —— 文笔卫生（AI 痕/重复/节奏），占综合分 50%；
/// 2. `FanqieGateChecker` —— 番茄过审闸门（红线/首屏/对白/水段），占 50%；
/// 3. `PipelineQa` —— 商业向指标（爽点/变强异动/章末钩子/统计层 AI 腔），
///    不直接计入分数，但超标以问题形式进入报告（与 `chapterIssues` 同口径）。
///
/// 分数口径：
/// - 基础分 = 文笔卫生分 × 0.5 + 过审分 × 0.5；
/// - 命中一票否决红线 → 综合分上限 60（必然不达线）；
/// - 无章末钩子 / 爽点双低 → 各再扣 5 分（下限 0）；
/// - 空正文直接 0 分。
class CompositeQualityGate implements QualityGate {
  /// 构造网关；参数透传给 [FanqieGateChecker]。
  const CompositeQualityGate({
    this.genre = '',
    this.protagonist = '',
    this.worldTerms = const <String>[],
  });

  /// 题材（红线降级判断）。
  final String genre;

  /// 主角名（主角漂移检测）。
  final String protagonist;

  /// 大纲世界观专名（一致性检测）。
  final List<String> worldTerms;

  @override
  QualityGateReport check(
    String text, {
    String prevContent = '',
    int chapterIndex = 1,
  }) {
    final QualityReport novel = NovelQualityChecker.check(text);
    final FanqieGateReport gate = FanqieGateChecker(
      genre: genre,
      protagonist: protagonist,
      worldTerms: worldTerms,
    ).check(text, prevContent: prevContent, chapterIndex: chapterIndex);
    final double echo = PipelineQa.aiEchoPct(text);
    final double rep = PipelineQa.adjacentRepetition(text);
    final double thrill = PipelineQa.thrillPerThousand(text);
    final double surge = PipelineQa.surgePerThousand(text);
    final bool hook = PipelineQa.hasEndingHook(text);
    final Map<String, dynamic> deep = PipelineQa.deepAiMetrics(text);
    final int deepLevel = deep['level'] as int? ?? 0;

    final List<QualityGateIssue> issues = <QualityGateIssue>[];

    // ---- 文笔卫生：硬伤（截前 10 条避免刷屏） ----
    for (final QualityViolation v in novel.hardViolations.take(10)) {
      issues.add(QualityGateIssue(
        source: QualitySource.novelHygiene,
        type: switch (v.type) {
          QualityViolationType.aiEcho => 'AI痕',
          QualityViolationType.repetition => '重复',
          QualityViolationType.formatting => '格式',
        },
        message: '${v.description}：「${v.matchedText}」',
        severity: QualitySeverity.warn,
      ));
    }

    // ---- 过审闸门：不达标项 + 红线 ----
    for (final FanqieGateIssue e in gate.issues) {
      issues.add(QualityGateIssue(
        source: QualitySource.fanqieGate,
        type: e.type,
        message: e.message,
        severity: switch (e.action) {
          FanqieGateAction.rewrite => QualitySeverity.blocking,
          FanqieGateAction.revise => QualitySeverity.warn,
          FanqieGateAction.note => QualitySeverity.note,
          _ => QualitySeverity.note,
        },
      ));
    }
    for (final FanqieRedlineHit h in gate.redlines) {
      issues.add(QualityGateIssue(
        source: QualitySource.fanqieGate,
        type: '红线',
        message: '「${h.word}」（${h.category}）：${h.context}',
        severity: h.veto ? QualitySeverity.veto : QualitySeverity.note,
      ));
    }

    // ---- 商业指标（与 PipelineQa.chapterIssues 同口径） ----
    if (novel.totalWords > 1500) {
      if (thrill < 0.5 && surge < 1.0) {
        issues.add(const QualityGateIssue(
          source: QualitySource.pipelineRules,
          type: '爽点',
          message: '爽点过淡（直白爽点 <0.5 且变强异动 <1.0/千字，'
              '建议安排打脸/升级/收获/揭露至少一处）',
          severity: QualitySeverity.warn,
        ));
      } else if (thrill < 0.5) {
        issues.add(const QualityGateIssue(
          source: QualitySource.pipelineRules,
          type: '爽点',
          message: '含蓄变强流（外显爽点偏少，直白爽点 <0.5/千字）',
          severity: QualitySeverity.note,
        ));
      }
    }
    if (!hook && novel.totalWords > 0) {
      issues.add(const QualityGateIssue(
        source: QualitySource.pipelineRules,
        type: '钩子',
        message: '章末 200 字未检测到钩子信号（直白突变/威胁窥伺/身份伏笔）',
        severity: QualitySeverity.warn,
      ));
    }
    if (deepLevel >= 3) {
      issues.add(QualityGateIssue(
        source: QualitySource.pipelineRules,
        type: 'AI腔',
        message: '统计层 AI 腔偏重（level=$deepLevel）：'
            '${PipelineQa.deepAiIssues(text).join('；')}',
        severity: QualitySeverity.warn,
      ));
    }

    // ---- 综合分 ----
    double score;
    if (novel.totalWords == 0) {
      score = 0;
    } else {
      score = novel.overallScore * 0.5 + gate.score * 0.5;
      if (gate.hasVeto) score = math.min(score, 60);
      if (!hook) score = math.max(0, score - 5);
      if (thrill < 0.5 && surge < 1.0) score = math.max(0, score - 5);
    }
    final bool pass = !gate.hasVeto && score >= 80;

    return QualityGateReport(
      totalWords: novel.totalWords,
      score: score,
      pass: pass,
      issues: issues,
      metrics: <String, double>{
        'novelOverall': novel.overallScore,
        'fanqieScore': gate.score,
        'aiEchoNovel': novel.aiEchoScore,
        'aiEchoPipeline': echo,
        'repetition': rep,
        'thrillPerK': thrill,
        'surgePerK': surge,
        'deepAiLevel': deepLevel.toDouble(),
        'dialogueRatio': gate.dialogueRatio,
        'fillerRatio': gate.fillerRatio,
      },
      summaries: <String>[novel.summary, gate.summary],
    );
  }
}