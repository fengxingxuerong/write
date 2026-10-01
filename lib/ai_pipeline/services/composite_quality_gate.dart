import 'dart:math' as math;

import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/engine/quality/fanqie_gate_checker.dart';
import 'package:novel_writer/engine/quality/novel_quality_checker.dart';
import 'package:novel_writer/engine/quality/quality_gate.dart';
import 'package:novel_writer/engine/quality/quality_rules.g.dart';

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

  /// 全书级「外显爽点断供」汇总（组合门禁此前只有单章入口，跨章形态无处汇总）。
  ///
  /// 传入**全书各章**的度量（按章序、最新在末尾），返回断供带统计。口径与 Python
  /// `payoff_drought_zones` + `qa_scan_existing` 的签约硬伤一致：
  /// 连续 >=[minRun] 章 💥<[threshold] 且**无在场者反应**才算断供——侧面反响逃生
  /// 通道是第二十七节真机 A/B 补的（`THRILL_WORDS` 是 96 词闭合套话表，不写套话的
  /// 好稿天然 💥=0，误伤它等于逼模型去写套话）。
  ///
  /// [chaptersInZones] / [total] 供 UI 算比例；[spans] 供报告直接展示区间。
  static ({int chaptersInZones, int total, List<String> spans}) bookPayoffDrought(
    List<ChapterPayoff> history, {
    double threshold = QualityRules.droughtThrillPerK,
    double sideThreshold = QualityRules.droughtSidePerK,
    int minRun = QualityRules.droughtMinRun,
  }) {
    final List<String> spans = <String>[];
    int inZones = 0;
    int? start;
    for (int i = 0; i < history.length; i++) {
      final ChapterPayoff p = history[i];
      final bool flat =
          p.thrillPerK < threshold && p.sidePerK < sideThreshold;
      if (flat) {
        start ??= i;
      } else if (start != null) {
        if (i - start >= minRun) {
          inZones += i - start;
          spans.add('第${start + 1}-$i章(${i - start}章)');
        }
        start = null;
      }
    }
    if (start != null && history.length - start >= minRun) {
      inZones += history.length - start;
      spans.add('第${start + 1}-${history.length}章(${history.length - start}章)');
    }
    return (
      chaptersInZones: inZones,
      total: history.length,
      spans: spans,
    );
  }

  @override
  QualityGateReport check(
    String text, {
    String prevContent = '',
    int chapterIndex = 1,
    List<ChapterPayoff> payoffHistory = const <ChapterPayoff>[],
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
    final double sideReaction = PipelineQa.sideReactionPerThousand(text);

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
      // 回归护栏（12e7ffa 残留缺陷）：本检查原先被插进上面 else-if（thrill<0.5）
      // 块的内部，而条件要求 thrill>=0.5 → 永不可达，侧面反响告警在组合门禁里
      // 从未生效过；必须保持为与 if/else-if 平级的兄弟分支。
      if (thrill >= 0.5 && sideReaction < 0.3) {
        issues.add(const QualityGateIssue(
          source: QualitySource.pipelineRules,
          type: '侧面反响',
          message: '侧面反响偏弱（震惊链 <0.3/千字，建议补齐三视角震惊环：反派/路人/权威）',
          severity: QualitySeverity.note,
        ));
      }
      // 压抑释放结构（爽点落点）：先抑后扬是否成立（与 PipelineQa.chapterIssues
      // 同口径，n>=2 才有结构可言），note 级供人工复核、不扣分。
      final ({String verdict, int hits, double first, double last}) rel =
          PipelineQa.releaseProfile(text);
      if (rel.verdict == 'late_start') {
        issues.add(QualityGateIssue(
          source: QualitySource.pipelineRules,
          type: '落点',
          message: '压抑过长（首个爽点在全章 ${(rel.first * 100).round()}% 处才释放，'
              '先抑后扬要求压抑不超过 60%，建议把释放点前移或中段补一处小释放）',
          severity: QualitySeverity.note,
        ));
      } else if (rel.verdict == 'front_loaded') {
        issues.add(QualityGateIssue(
          source: QualitySource.pipelineRules,
          type: '落点',
          message: '爽点前置泄洪（末个爽点在全章 ${(rel.last * 100).round()}% 处，'
              '后半段零释放，建议后半章补一处打脸/收获落地）',
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
    final String triad = PipelineQa.endingTriad(text);
    if (triad.isNotEmpty) {
      issues.add(QualityGateIssue(
        source: QualitySource.pipelineRules,
        type: '收尾',
        message: '章末三件套收尾：命中「$triad」（规则20禁止身体异动/发光物件收束，AI味一眼假）',
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

    // ---- 外显爽点断供（跨章形态，note 级不扣分）----
    // 断供是**连续 N 章**没有外显兑现，单章入口天然看不到；此处与 [prevContent]
    // 同理——调用方有跨章上下文就传 payoffHistory，没有（默认空）则完全不判，
    // 行为与旧版一致。整书视角的汇总见 [bookPayoffDrought]。
    final int droughtLen = PipelineQa.trailingDroughtLen(payoffHistory);
    if (droughtLen >= 3 && thrill < 0.5 && sideReaction < 0.3) {
      issues.add(QualityGateIssue(
        source: QualitySource.pipelineRules,
        type: '爽点断供',
        message: '已连续 $droughtLen 章无外显爽点（直白爽点 <0.5 且无在场者反应，'
            '每千字），本章仍未补上——外显兑现是番茄追读引擎，'
            '含蓄异动不能替代，建议在章内补一处打脸/收获/揭露',
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
        'sideReactionPerK': sideReaction,
        'payoffDroughtLen': droughtLen.toDouble(),
        'dialogueRatio': gate.dialogueRatio,
        'fillerRatio': gate.fillerRatio,
      },
      summaries: <String>[novel.summary, gate.summary],
    );
  }
}