/// 终审官（chief review）纯辅助函数层。
///
/// 从 ai_pipeline_service.dart 抽出的**纯静态** helper：终审 prompt 组装、
/// 多维分/问题清单解析、多采样中位数合并。零实例状态依赖，只用本文件显式
/// import 的类型——独立成文件降低 1400+ 行服务类的维护成本，且可被终审相关
/// 单元测试单独覆盖。
library;

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';

String chiefChapterRows(AiPipelineTask task) {
  final List<PipelineChapter> chapters = List<PipelineChapter>.from(
    task.chapters,
  )..sort((PipelineChapter a, PipelineChapter b) => a.idx.compareTo(b.idx));
  final StringBuffer b = StringBuffer();
  for (final PipelineChapter c in chapters) {
    final ChapterQualityReview? r = c.review;
    final double echo = PipelineQa.aiEchoPct(c.content);
    b.writeln('第${c.idx}章《${c.title}》${c.words}字｜'
        '评审${r != null && r.scored ? r.overall : '-'}分｜'
        '钩子${PipelineQa.hasEndingHook(c.content) ? '有' : '无'}｜'
        'AI味${echo.toStringAsFixed(0)}%｜问题${c.issues.length}处');
  }
  return b.toString().trim();
}

String chiefOpenForeshadows(ForeshadowLedger ledger) {
  final StringBuffer b = StringBuffer();
  for (final ForeshadowEntry e in ledger.open.take(12)) {
    final String d = e.desc.length > 40 ? e.desc.substring(0, 40) : e.desc;
    b.writeln('第${e.planted}章埋：$d');
  }
  return b.toString().trim();
}

PipelineChapter? worstScoredChapter(AiPipelineTask task) {
  PipelineChapter? worst;
  int worstScore = 101;
  for (final PipelineChapter c in task.chapters) {
    final ChapterQualityReview? r = c.review;
    if (r == null || !r.scored) continue;
    if (r.overall < worstScore) {
      worstScore = r.overall;
      worst = c;
    }
  }
  return worst ??
      (task.chapters.isEmpty ? null : task.chapters.first);
}

Map<String, int> chiefDimensions(Map<String, dynamic> parsed) {
  final Map<String, int> out = <String, int>{};
  final Map<String, dynamic>? raw =
      parsed['dimensions'] as Map<String, dynamic>?;
  raw?.forEach((String k, dynamic v) {
    if (v is num) out[k] = v.toInt();
  });
  return out;
}

List<ChiefIssue> chiefIssues(Map<String, dynamic> parsed) {
  return (parsed['top_issues'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .map(ChiefIssue.fromJson)
      .where((ChiefIssue e) => e.issue.trim().isNotEmpty)
      .toList();
}

ChiefReview mergeChiefSamples(
  List<ChiefReview> samples,
  int round,
) {
  int median(List<int> xs) {
    final List<int> s = List<int>.from(xs)..sort();
    return s[s.length ~/ 2];
  }

  final Set<String> keys = <String>{};
  for (final ChiefReview r in samples) {
    keys.addAll(r.dimensions.keys);
  }
  final Map<String, int> dims = <String, int>{};
  for (final String k in keys) {
    final List<int> vs = samples
        .map((ChiefReview r) => r.dimensions[k])
        .where((int? v) => v != null && v >= 0)
        .map((int? v) => v!)
        .toList();
    if (vs.isNotEmpty) dims[k] = median(vs);
  }

  // 问题清单按「多轮共识」优先：多轮都点名的排前面。
  final Map<String, int> seen = <String, int>{};
  for (final ChiefReview r in samples) {
    for (final ChiefIssue e in r.topIssues) {
      final String k = '${e.chapter}|${e.issue}';
      seen[k] = (seen[k] ?? 0) + 1;
    }
  }
  final List<ChiefIssue> issues = <ChiefIssue>[];
  final List<ChiefReview> ordered = List<ChiefReview>.from(samples)
    ..sort((ChiefReview a, ChiefReview b) =>
        b.topIssues.length.compareTo(a.topIssues.length));
  for (final ChiefReview r in ordered) {
    for (final ChiefIssue e in r.topIssues) {
      final bool dup = issues.any((ChiefIssue x) =>
          x.chapter == e.chapter && x.issue == e.issue);
      if (!dup) issues.add(e);
    }
  }
  final List<String> fixes = <String>[];
  for (final ChiefReview r in samples) {
    for (final String f in r.fixPriority) {
      if (!fixes.contains(f)) fixes.add(f);
    }
  }
  final int overall =
      median(samples.map((ChiefReview r) => r.overall).toList());
  return ChiefReview(
    round: round,
    overall: overall,
    dimensions: dims,
    // 判档**本地按分数区间**判，模型判词只作参考——同分必同档。
    verdict: AiPipelineTask.verdictOf(overall),
    topIssues: issues.take(5).toList(),
    fixPriority: fixes.take(3).toList(),
    samples: samples.length,
  );
}
