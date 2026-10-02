import 'package:flutter/material.dart';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/widgets/app_card.dart';
import 'package:novel_writer/widgets/common.dart';

/// 流水线质量面板 —— 把结构化质量记录渲染成作者能直接读懂的结论。
///
/// **这块面板存在的理由**：Python 端 CLI 已有的质量闭环产物（评审六维分 /
/// 打勾✅❌ / 结构打回轨迹 / 回收清单）在桌面端此前**完全看不到**，作者只能
/// 去翻 jsonl 或日志文本。本面板是那套闭环的 GUI 落点。
///
/// 三条刻意的设计纪律：
/// 1. **「未核查」与「核查通过」分开显示**——[ChapterFactCheck.ok] 为 false 时
///    显示警示色「未核查」，绝不用 0 命中的绿色「通过 ✅」冒充，否则一次静默
///    失效会被读成一次通过（Python 端门禁第 16 项的核心教训）。
/// 2. **评分不存在 ≠ 评了 0 分**——[ChapterQualityReview.scored] 为 false 时显示
///    「未评分」，不用 0 填充版面。
/// 3. **数据从任务记录读，不重新调用 LLM**——面板是纯展示，打开零成本、可离线。
class PipelineQualityPanel extends StatelessWidget {
  /// 构造面板。
  const PipelineQualityPanel({super.key, required this.task});

  /// 流水线任务。
  final AiPipelineTask task;

  @override
  Widget build(BuildContext context) {
    final List<PipelineChapter> chapters = List<PipelineChapter>.from(
      task.chapters,
    )..sort((PipelineChapter a, PipelineChapter b) => a.idx.compareTo(b.idx));
    if (chapters.isEmpty) {
      return const EmptyState(
        message: '还没有章节',
        icon: Icons.menu_book_outlined,
        hint: '流水线跑出第一章后，这里会显示逐章的五维评分、编造核查与阻断项。',
      );
    }
    final QualitySummary s = summarize(
      chapters,
      ledger: task.ledger,
      lastIdx: chapters.map((PipelineChapter c) => c.idx).fold<int>(
            0,
            (int a, int b) => a > b ? a : b,
          ),
    );
    return ListView(
      padding: const EdgeInsets.all(AppTokens.s3),
      children: <Widget>[
        _ChiefCard(task: task),
        const SizedBox(height: AppTokens.s3),
        _SummaryBar(summary: s),
        const SizedBox(height: AppTokens.s3),
        for (final PipelineChapter c in chapters)
          _ChapterQualityCard(chapter: c),
      ],
    );
  }
}

/// 全书质量汇总。
class QualitySummary {
  /// 构造汇总。
  const QualitySummary({
    required this.scoredCount,
    required this.passCount,
    required this.notChecked,
    required this.residualFabrications,
    this.openForeshadows = 0,
    this.staleForeshadows = 0,
    this.promiseFulfilled = 0,
    this.promiseUnfulfilled = 0,
    this.promiseCheckFailed = 0,
  });

  /// 实际评过分的章数。
  final int scoredCount;

  /// 达线章数（综合分 >= 78）。
  final int passCount;

  /// 未核查 / 核查未跑成的章数。
  final int notChecked;

  /// 残留编造命中总数（定点修复检后仍存在的）。
  final int residualFabrications;

  /// 未回收伏笔数（台账 open）。
  final int openForeshadows;

  /// 超时不收伏笔数（埋设 N 章以上仍 open，终审会判「伏笔悬空」硬伤）。
  final int staleForeshadows;

  /// 已兑现的伏笔打勾总数（全书记账）。
  final int promiseFulfilled;

  /// 未兑现的打勾总数（需人工处理）。
  final int promiseUnfulfilled;

  /// 打勾环节失败次数（验收没跑成——**不等于**「都没兑现」）。
  final int promiseCheckFailed;
}

/// 汇总全书质量口径（供面板与测试共用）。
///
/// [ledger] 是结构化伏笔台账；超时不收的判定需要「截至第几章」，
/// 故由调用方传入 [lastIdx]（通常取最大章号）而不是在函数里猜——
/// 空书没有章号可猜，猜错会让「超时不收」静默恒为 0。
QualitySummary summarize(
  List<PipelineChapter> chapters, {
  ForeshadowLedger ledger = ForeshadowLedger.empty,
  int lastIdx = 0,
}) {
  final List<ChapterQualityReview> scored = chapters
      .map((PipelineChapter c) => c.review)
      .whereType<ChapterQualityReview>()
      .where((ChapterQualityReview r) => r.scored)
      .toList();
  int pass = 0;
  for (final ChapterQualityReview r in scored) {
    if (r.pass) pass++;
  }
  int notChecked = 0;
  int residual = 0;
  int fulfilled = 0;
  int unfulfilled = 0;
  int checkFailed = 0;
  for (final PipelineChapter c in chapters) {
    final ChapterFactCheck? f = c.factCheck;
    // 未核查与核查未跑成都归入「未核查」——两者都不构成「无编造」的证据。
    if (f == null || !f.ok) {
      notChecked++;
    } else {
      residual += f.count;
    }
    // 打勾：failed 单独计——「验收没跑成」与「都没兑现」是相反的结论，
    // 混进 unfulfilled 会让作者误以为正文有问题。
    for (final PromiseCheck r in c.promiseChecks ?? const <PromiseCheck>[]) {
      if (r.failed) {
        checkFailed++;
      } else if (r.fulfilled) {
        fulfilled++;
      } else {
        unfulfilled++;
      }
    }
  }
  return QualitySummary(
    scoredCount: scored.length,
    passCount: pass,
    notChecked: notChecked,
    residualFabrications: residual,
    openForeshadows: ledger.open.length,
    staleForeshadows: ledger.stale(lastIdx, staleAfter: 5).length,
    promiseFulfilled: fulfilled,
    promiseUnfulfilled: unfulfilled,
    promiseCheckFailed: checkFailed,
  );
}

/// 汇总条：四个数字一眼看清全书质量水位。
class _SummaryBar extends StatelessWidget {
  /// 构造汇总条。
  const _SummaryBar({required this.summary});

  /// 汇总数据。
  final QualitySummary summary;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return AppCard(
      title: '质量总览',
      child: Wrap(
        spacing: AppTokens.s6,
        runSpacing: AppTokens.s2,
        children: <Widget>[
          _Stat(
            label: '已评章',
            value: '${summary.scoredCount}',
            hint: '实际产出评分的章数',
          ),
          _Stat(
            label: '达线章',
            value: '${summary.passCount}',
            hint: '综合分 >= 78',
            color: summary.passCount == summary.scoredCount &&
                    summary.scoredCount > 0
                ? ink.success
                : ink.warn,
          ),
          _Stat(
            label: '未核查章',
            value: '${summary.notChecked}',
            hint: '未跑关卡5，或核查未跑成（不等于无编造）',
            color: summary.notChecked > 0 ? ink.warn : ink.success,
          ),
          _Stat(
            label: '残留编造',
            value: '${summary.residualFabrications}',
            hint: '定点修复检后仍存在的无据断言',
            color: summary.residualFabrications > 0 ? ink.danger : ink.success,
          ),
          _Stat(
            label: '打勾兑现',
            value: '${summary.promiseFulfilled}',
            hint: '回收清单验收通过（✅ 联动台账 closed）条数',
            color: summary.promiseFulfilled > 0 ? ink.success : ink.inkFaint,
          ),
          _Stat(
            label: '打勾未兑现',
            value: '${summary.promiseUnfulfilled}',
            hint: '验收发现未兑现（❌，需人工或补写）条数',
            color: summary.promiseUnfulfilled > 0 ? ink.warn : ink.success,
          ),
          _Stat(
            label: '打勾失败',
            value: '${summary.promiseCheckFailed}',
            hint: '验收环节没跑成——不等于「都没兑现」，需人工复核',
            color: summary.promiseCheckFailed > 0 ? ink.danger : ink.success,
          ),
          _Stat(
            label: '伏笔未收',
            value: '${summary.openForeshadows}',
            hint: '台账 open 条目（已埋设未回收）',
            color: summary.openForeshadows > 0 ? ink.ink : ink.success,
          ),
          _Stat(
            label: '伏笔超时',
            value: '${summary.staleForeshadows}',
            hint: '埋设超 5 章仍未回收——终审会判「伏笔悬空」硬伤',
            color: summary.staleForeshadows > 0 ? ink.danger : ink.success,
          ),
        ],
      ),
    );
  }
}

/// 单个统计数字（悬浮说明解释口径）。
class _Stat extends StatelessWidget {
  /// 构造统计项。
  const _Stat({
    required this.label,
    required this.value,
    required this.hint,
    this.color,
  });

  /// 名称。
  final String label;

  /// 数值文本。
  final String value;

  /// 悬浮说明。
  final String hint;

  /// 数值配色（不给则用主文本色）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return Tooltip(
      message: hint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: AppFonts.text(ink.inkFaint, size: 12)),
          const SizedBox(height: 2),
          Text(
            value,
            style: AppFonts.text(
              color ?? ink.ink,
              size: 22,
              weight: FontWeight.w600,
              monoFace: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// 单章质量卡：五维评分 + 编造核查 + 阻断项。
class _ChapterQualityCard extends StatelessWidget {
  /// 构造章节质量卡。
  const _ChapterQualityCard({required this.chapter});

  /// 章节记录。
  final PipelineChapter chapter;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.s2),
      child: AppCard(
        title: '第 ${chapter.idx} 章 ${chapter.title}',
        subtitle: '${chapter.words} 字',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _ReviewSection(review: chapter.review),
            const SizedBox(height: AppTokens.s2),
            _FactCheckSection(factCheck: chapter.factCheck),
            if (chapter.promiseChecks != null) ...<Widget>[
              const SizedBox(height: AppTokens.s2),
              _PromiseSection(checks: chapter.promiseChecks!),
            ],
            if (chapter.issues.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppTokens.s2),
              Text(
                '问题 / 阻断项（${chapter.issues.length}）',
                style: AppFonts.text(
                  ink.inkSoft,
                  size: 13,
                  weight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              for (final String i in chapter.issues)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '· $i',
                    style: AppFonts.text(ink.inkFaint, size: 12.5, height: 1.5),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 五维评分区（含「未评分」空态）。
class _ReviewSection extends StatelessWidget {
  /// 构造评分区。
  const _ReviewSection({required this.review});

  /// 评分记录（null = 未评分）。
  final ChapterQualityReview? review;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final ChapterQualityReview? r = review;
    if (r == null || !r.scored) {
      return const _HintLine(
        text: '本章未评分（评分按配置间隔触发，非每章都有）',
        icon: Icons.help_outline,
        kind: _HintKind.muted,
      );
    }
    final String weak = r.weakestDim;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '综合 ${r.overall} 分',
              style: AppFonts.text(
                r.pass ? ink.success : ink.warn,
                size: 15,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: AppTokens.s2),
            Text(
              r.pass ? '✅ 达线' : '⚠ 未达线（<78）',
              style: AppFonts.text(r.pass ? ink.success : ink.warn, size: 12.5),
            ),
            if (weak.isNotEmpty) ...<Widget>[
              const SizedBox(width: AppTokens.s2),
              Text(
                '短板：${ChapterQualityReview.dimLabel(weak)}',
                style: AppFonts.text(ink.inkFaint, size: 12),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        // 五维横条：一眼看出「哪一维塌了」，比读一串数字快得多。
        for (final MapEntry<String, int> e in r.dims.entries)
          _DimBar(label: ChapterQualityReview.dimLabel(e.key), value: e.value),
        if (r.comment.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            '点评：${r.comment}',
            style: AppFonts.text(ink.inkSoft, size: 12.5, height: 1.5),
          ),
        ],
      ],
    );
  }
}

/// 单维度横条（60 分告警线与流水线口径一致）。
class _DimBar extends StatelessWidget {
  /// 构造维度条。
  const _DimBar({required this.label, required this.value});

  /// 维度中文名。
  final String label;

  /// 分数（0~100）。
  final int value;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Color c = value >= 78
        ? ink.success
        : value >= 60
            ? ink.warn
            : ink.danger;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 34,
            child: Text(label, style: AppFonts.text(ink.inkFaint, size: 12)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTokens.r1),
              child: LinearProgressIndicator(
                value: (value / 100).clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: c.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation<Color>(c),
              ),
            ),
          ),
          const SizedBox(width: AppTokens.s2),
          SizedBox(
            width: 26,
            child: Text(
              '$value',
              textAlign: TextAlign.right,
              style: AppFonts.text(c, size: 12, monoFace: true),
            ),
          ),
        ],
      ),
    );
  }
}

/// 回收清单打勾区：逐条 ✅/❌ + 证据句。
///
/// **证据句必须展示**——它是回收凭证。「已回收 ✅」配一句「是的我写了」，
/// 作者无从复核；配上正文原句才能判断验收官是不是在敷衍。
class _PromiseSection extends StatelessWidget {
  /// 构造打勾区。
  const _PromiseSection({required this.checks});

  /// 打勾结果。
  final List<PromiseCheck> checks;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    if (checks.isEmpty) {
      return const _HintLine(
        text: '本章无必兑现清单（没有埋设超时的伏笔）',
        icon: Icons.check_circle_outline,
        kind: _HintKind.muted,
      );
    }
    final bool failed = checks.any((PromiseCheck r) => r.failed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _HintLine(
          text: failed
              ? '☠ 回收清单打勾未执行（验收调用失败）——请人工复核伏笔兑现'
              : '回收清单打勾：${checks.where((PromiseCheck r) => r.fulfilled).length}'
                  '/${checks.length} 条兑现',
          icon: failed ? Icons.error_outline : Icons.checklist_rtl,
          kind: failed ? _HintKind.warn : _HintKind.muted,
        ),
        const SizedBox(height: 4),
        for (final PromiseCheck r in checks)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              '${r.mark} 清单${r.id > 0 ? r.id : '-'}：${r.evidence}',
              style: AppFonts.text(
                r.failed
                    ? ink.danger
                    : r.fulfilled
                        ? ink.success
                        : ink.warn,
                size: 12,
                height: 1.5,
              ),
            ),
          ),
      ],
    );
  }
}

/// 终审官卡片：签约判档 + 六维 + 问题清单 + 打回轨迹。
///
/// **打回轨迹必须展示**：作者需要看到「这本书被判回过一次、因为什么、改没改成」，
/// 而不只是最终分数。没有轨迹，打回权看起来像一次没发生过的事。
class _ChiefCard extends StatelessWidget {
  /// 构造终审卡。
  const _ChiefCard({required this.task});

  /// 流水线任务。
  final AiPipelineTask task;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final ChiefReview? chief = task.latestChiefReview;
    if (task.chiefReviews.isEmpty) {
      return AppCard(
        title: '终审官',
        child: const _HintLine(
          text: '尚未终审（生成完成后自动跑通读级总评）',
          icon: Icons.gavel_outlined,
          kind: _HintKind.muted,
        ),
      );
    }
    if (chief == null || !chief.ok) {
      return AppCard(
        title: '终审官',
        child: const _HintLine(
          text: '⚠ 终审本轮无结论（调用失败或解析失败）——不等于「0 分」',
          icon: Icons.error_outline,
          kind: _HintKind.warn,
        ),
      );
    }
    final Map<String, int> hard = chief.hardDimensions;
    final Color vc = chief.overall >= 80
        ? ink.success
        : chief.overall >= 60
            ? ink.warn
            : ink.danger;
    return AppCard(
      title: '终审官 · 第 ${chief.round} 轮${chief.round > 1 ? '（二审为准）' : ''}',
      subtitle: task.chiefRewrote ? '曾打回重写 ${task.chiefRewrites.length} 章' : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '综合 ${chief.overall} 分',
                style: AppFonts.text(vc,
                    size: 17, weight: FontWeight.w600),
              ),
              const SizedBox(width: AppTokens.s2),
              Text(
                chief.verdict,
                style: AppFonts.text(vc, size: 13.5),
              ),
              const SizedBox(width: AppTokens.s2),
              Text(
                '（${chief.samples} 次采样中位数）',
                style: AppFonts.text(ink.inkFaint, size: 11.5),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final MapEntry<String, int> e in chief.dimensions.entries)
            _ChiefDimBar(label: e.key, value: e.value),
          if (hard.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            _HintLine(
              text: '☠ 硬伤维度（≤40）：${hard.keys.join('、')}——'
                  '即使总分达标也必须人工复核',
              icon: Icons.report_outlined,
              kind: _HintKind.warn,
            ),
          ],
          if (chief.topIssues.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '问题清单',
              style: AppFonts.text(ink.inkSoft,
                  size: 13, weight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            for (final ChiefIssue i in chief.topIssues)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '⚠ ${i.chapter > 0 ? "第${i.chapter}章" : "全书"}：${i.issue}'
                  '${i.evidence.isEmpty ? "" : "（${i.evidence}）"}',
                  style: AppFonts.text(ink.inkFaint, size: 12, height: 1.5),
                ),
              ),
          ],
          if (task.chiefRewrites.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '打回重写轨迹',
              style: AppFonts.text(ink.inkSoft,
                  size: 13, weight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            for (final ChiefRewriteRecord r in task.chiefRewrites)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '${r.applied ? "✅" : "☠"} 第${r.chapterIdx}章：${r.reason}｜'
                  '${r.oldWords}→${r.newWords} 字'
                  '${r.applied ? "" : "（未过采纳闸，保留原文）"}',
                  style: AppFonts.text(
                    r.applied ? ink.success : ink.danger,
                    size: 12,
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 终审单维度横条。
class _ChiefDimBar extends StatelessWidget {
  /// 构造维度条。
  const _ChiefDimBar({required this.label, required this.value});

  /// 维度中文名。
  final String label;

  /// 分数（0~100）。
  final int value;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    // ≤40 是硬伤线（与 ChiefReview.hardDimensions 同口径）。
    final Color c = value >= 78
        ? ink.success
        : value > 40
            ? ink.warn
            : ink.danger;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 76,
            child: Text(label, style: AppFonts.text(ink.inkFaint, size: 12)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTokens.r1),
              child: LinearProgressIndicator(
                value: (value / 100).clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: c.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation<Color>(c),
              ),
            ),
          ),
          const SizedBox(width: AppTokens.s2),
          SizedBox(
            width: 26,
            child: Text(
              '$value',
              textAlign: TextAlign.right,
              style: AppFonts.text(c, size: 12, monoFace: true),
            ),
          ),
        ],
      ),
    );
  }
}

/// 提示行语义（决定配色）。
enum _HintKind {
  /// 中性说明（未评分、未核查这类「没有数据」）。
  muted,

  /// 成功（核查通过）。
  good,

  /// 警示（核查未跑成 / 有残留命中）。
  warn,
}

/// 编造核查区——重点区分「未核查」与「核查通过 0 命中」。
class _FactCheckSection extends StatelessWidget {
  /// 构造核查区。
  const _FactCheckSection({required this.factCheck});

  /// 核查记录（null = 未核查）。
  final ChapterFactCheck? factCheck;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final ChapterFactCheck? f = factCheck;
    if (f == null) {
      return const _HintLine(
        text: '未做编造核查（关卡5 未启用，或本章未留下核查记录）',
        icon: Icons.help_outline,
        kind: _HintKind.muted,
      );
    }
    if (!f.ok) {
      // 「没跑成」用警示色而非成功色：这是最容易骗过作者的一种状态。
      return const _HintLine(
        text: '⚠ 编造核查未跑成——不能据此认为本章无编造',
        icon: Icons.error_outline,
        kind: _HintKind.warn,
      );
    }
    if (f.count == 0) {
      return const _HintLine(
        text: '编造核查通过 ✅（0 处无据断言）',
        icon: Icons.verified_outlined,
        kind: _HintKind.good,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _HintLine(
          text: '⚠ 编造核查命中 ${f.count} 处'
              '${f.repaired ? '（首轮 ${f.firstRoundCount} 处，修复后降至 ${f.count} 处）' : ''}',
          icon: Icons.report_gmailerrorred_outlined,
          kind: f.repaired ? _HintKind.warn : _HintKind.warn,
        ),
        const SizedBox(height: 4),
        for (final Fabrication fb in f.fabrications)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              '· [${fb.typeLabel}] ${fb.claim}'
              '${fb.evidence.trim().isEmpty ? '' : '（依据：${fb.evidence}）'}',
              style: AppFonts.text(ink.inkFaint, size: 12, height: 1.5),
            ),
          ),
      ],
    );
  }
}

/// 带图标的一行提示（空态 / 成功 / 警示三态共用）。
class _HintLine extends StatelessWidget {
  /// 构造提示行。
  const _HintLine({
    required this.text,
    required this.icon,
    required this.kind,
  });

  /// 提示文本。
  final String text;

  /// 前置图标。
  final IconData icon;

  /// 语义（决定配色）。
  final _HintKind kind;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Color c = switch (kind) {
      _HintKind.good => ink.success,
      _HintKind.warn => ink.warn,
      _HintKind.muted => ink.inkFaint,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: AppFonts.text(c, size: 12.5, height: 1.5),
          ),
        ),
      ],
    );
  }
}
