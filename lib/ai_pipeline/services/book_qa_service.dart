import 'dart:io';

import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/engine/quality/fanqie_gate_checker.dart';
import 'package:novel_writer/engine/quality/novel_quality_checker.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';

/// 全书体检 —— 把三套本地质检合并为一次全书扫描。
///
/// 纯本地零成本（零 LLM、零网络）：`NovelQualityChecker`（文笔卫生）+
/// `FanqieGateChecker`（过审闸门）+ `PipelineQa`（商业向指标）。
///
/// 章分口径（与 `CompositeQualityGate` 一致）：
/// - 综合章分 = 文笔卫生 50% + 过审分 50%；
/// - 命中一票否决红线 → 封顶 60；
/// - 达线 = 无红线且章分 ≥ 78（对齐 Python 端 `--review-pass 78`）。
class BookQaService {
  /// 构造服务。
  const BookQaService();

  /// 达线阈值（与 Python `novel_pipeline.py --review-pass` 默认一致）。
  static const double passThreshold = 78;

  /// 对整本 [novel] 执行体检。
  ///
  /// 同步计算；10 万字级别约数秒，UI 侧可先弹「体检中」再 await。
  BookQaReport check(Novel novel) {
    final Character? protagonist = _detectProtagonist(novel.characters);
    final List<String> worldTerms = novel.worldSettings
        .map((WorldSetting w) => w.title.trim())
        .where((String t) => t.isNotEmpty && t.length >= 2)
        .toList();

    final FanqieGateChecker checker = FanqieGateChecker(
      genre: novel.genre,
      protagonist: protagonist?.name ?? '',
      worldTerms: worldTerms,
    );

    final List<Chapter> chapters = <Chapter>[...novel.chapters]
      ..sort((Chapter a, Chapter b) => a.order.compareTo(b.order));

    final List<BookChapterQa> rows = <BookChapterQa>[];
    String prevContent = '';
    for (final Chapter c in chapters) {
      final String text = c.content.trim();
      if (text.isEmpty) {
        rows.add(BookChapterQa.empty(c));
        prevContent = '';
        continue;
      }
      final QualityReport novelReport = NovelQualityChecker.check(text);
      final FanqieGateReport gate = checker.check(
        text,
        prevContent: prevContent,
        chapterIndex: c.order,
      );

      // 商业向指标告警（与 PipelineQa.chapterIssues 同口径）。
      final List<String> extra = <String>[];
      if (!PipelineQa.hasEndingHook(text)) {
        extra.add('章末 200 字未检测到钩子信号（直白突变/威胁窥伺/身份伏笔）');
      }
      if (c.wordCount() > 1500 &&
          PipelineQa.thrillPerThousand(text) < 0.5 &&
          PipelineQa.surgePerThousand(text) < 1.0) {
        extra.add('爽点过淡（直白爽点 <0.5 且变强异动 <1.0/千字）');
      }

      rows.add(_rowFor(c, text, novelReport, gate, extra));
      prevContent = text;
    }

    return _aggregate(novel, rows);
  }
}

/// 组装单章明细。
BookChapterQa _rowFor(
  Chapter c,
  String text,
  QualityReport novelReport,
  FanqieGateReport gate,
  List<String> extra,
) {
  double score = novelReport.overallScore * 0.5 + gate.score * 0.5;
  if (gate.hasVeto) score = score > 60 ? 60 : score;
  return BookChapterQa(
    chapter: c,
    score: score,
    pass: !gate.hasVeto && score >= BookQaService.passThreshold,
    hasVeto: gate.hasVeto,
    words: c.wordCount(),
    aiEcho: PipelineQa.aiEchoPct(text),
    repetition: PipelineQa.adjacentRepetition(text),
    rhythm: PipelineQa.rhythmScore(text),
    dialogueRatio: gate.dialogueRatio,
    fillerRatio: gate.fillerRatio,
    hasHook: PipelineQa.hasEndingHook(text),
    thrill: PipelineQa.thrillPerThousand(text),
    surge: PipelineQa.surgePerThousand(text),
    novelIssues: novelReport.hardViolations
        .map((QualityViolation v) => '[${v.type.name}] ${v.description}')
        .toList(),
    gateIssues: gate.issues.map((FanqieGateIssue e) => e.toString()).toList(),
    gateSummary: gate.summary,
    fixPrompt: gate.fixPrompt,
    extraIssues: extra,
  );
}

/// 聚合全书指标。
BookQaReport _aggregate(Novel novel, List<BookChapterQa> rows) {
  final List<BookChapterQa> withText =
      rows.where((BookChapterQa r) => r.words > 0).toList();
  final double avg = withText.isEmpty
      ? 0
      : withText.fold<double>(0, (double a, BookChapterQa r) => a + r.score) /
          withText.length;
  final int passed = rows.where((BookChapterQa r) => r.pass).length;
  final int vetoes = rows.where((BookChapterQa r) => r.hasVeto).length;
  return BookQaReport(
    novel: novel,
    rows: rows,
    avgScore: avg,
    passCount: passed,
    totalChapters: rows.length,
    vetoCount: vetoes,
    totalWords: novel.wordCount(),
    generatedAt: DateTime.now(),
  );
}

/// 主角判定：role == '主角' 优先，否则第一个角色；无角色返回 null。
Character? _detectProtagonist(List<Character> characters) {
  if (characters.isEmpty) return null;
  return characters.firstWhere(
    (Character c) => c.role == '主角',
    orElse: () => characters.first,
  );
}

/// 全书体检报告。
class BookQaReport {
  /// 构造报告。
  const BookQaReport({
    required this.novel,
    required this.rows,
    required this.avgScore,
    required this.passCount,
    required this.totalChapters,
    required this.vetoCount,
    required this.totalWords,
    required this.generatedAt,
  });

  /// 被检项目。
  final Novel novel;

  /// 章节明细（按 order 升序）。
  final List<BookChapterQa> rows;

  /// 全书平均分（空章不计入）。
  final double avgScore;

  /// 达线章数。
  final int passCount;

  /// 总章数（含空章）。
  final int totalChapters;

  /// 命中一票否决红线的章数。
  final int vetoCount;

  /// 全书字数。
  final int totalWords;

  /// 生成时间。
  final DateTime generatedAt;

  /// 是否全书达线（无红线且全部章达线）。
  bool get allPass => vetoCount == 0 && passCount == totalChapters;

  /// 不达标章列表（含空章）。
  List<BookChapterQa> get failing =>
      rows.where((BookChapterQa r) => !r.pass).toList();

  /// 导出为 .txt 报告。
  Future<void> exportText(String path) async {
    final StringBuffer b = StringBuffer();
    b.writeln('《${novel.title}》全书体检报告');
    b.writeln('生成时间：${generatedAt.toIso8601String().substring(0, 19)}');
    b.writeln('题材：${novel.genre} ｜ 基调：${novel.tone}');
    b.writeln('章数：$totalChapters ｜ 字数：$totalWords');
    b.writeln('全书平均分：${avgScore.toStringAsFixed(0)} ｜ '
        '达线 $passCount/$totalChapters 章 ｜ 红线 $vetoCount 章');
    b.writeln();
    b.writeln('==================== 章节明细 ====================');
    for (final BookChapterQa r in rows) {
      b.writeln();
      b.writeln('第 ${r.chapter.order} 章 ${r.chapter.title} — '
          '${r.words} 字 — ${r.score.toStringAsFixed(0)} 分'
          '${r.pass ? ' ✅ 达线' : ' ⚠️ 不达标'}');
      for (final String i in r.allIssues.take(8)) {
        b.writeln('  · $i');
      }
      if (r.fixPrompt.isNotEmpty) {
        b.writeln('  [定点修建议]');
        for (final String line in r.fixPrompt.split('\n').take(6)) {
          b.writeln('    $line');
        }
      }
    }
    final File f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(b.toString(), flush: true);
  }
}

/// 单章体检明细。
class BookChapterQa {
  /// 构造明细。
  const BookChapterQa({
    required this.chapter,
    required this.score,
    required this.pass,
    required this.hasVeto,
    required this.words,
    required this.aiEcho,
    required this.repetition,
    required this.rhythm,
    required this.dialogueRatio,
    required this.fillerRatio,
    required this.hasHook,
    required this.thrill,
    required this.surge,
    required this.novelIssues,
    required this.gateIssues,
    required this.gateSummary,
    required this.fixPrompt,
    required this.extraIssues,
  });

  /// 空章（无正文，不参与平均分）。
  const BookChapterQa.empty(this.chapter)
      : score = 0,
        pass = false,
        hasVeto = false,
        words = 0,
        aiEcho = 0,
        repetition = 0,
        rhythm = 0,
        dialogueRatio = 0,
        fillerRatio = 100,
        hasHook = false,
        thrill = 0,
        surge = 0,
        novelIssues = const <String>['正文为空'],
        gateIssues = const <String>[],
        gateSummary = '正文为空',
        fixPrompt = '',
        extraIssues = const <String>[];

  /// 原章。
  final Chapter chapter;

  /// 综合章分（0~100）。
  final double score;

  /// 是否达线（无否决且 ≥ [BookQaService.passThreshold]）。
  final bool pass;

  /// 是否命中一票否决红线。
  final bool hasVeto;

  /// 章字数。
  final int words;

  /// AI 痕密度（每 100 字）。
  final double aiEcho;

  /// 相邻段落重复率（0~1）。
  final double repetition;

  /// 节奏失衡率（0~1）。
  final double rhythm;

  /// 对白占比（0~1）。
  final double dialogueRatio;

  /// 水段率（%）。
  final double fillerRatio;

  /// 章末是否有钩子。
  final bool hasHook;

  /// 直白爽点（每千字）。
  final double thrill;

  /// 变强异动（每千字）。
  final double surge;

  /// 文笔卫生问题（NovelQualityChecker）。
  final List<String> novelIssues;

  /// 过审闸门问题（FanqieGateChecker）。
  final List<String> gateIssues;

  /// 过审闸门一句话摘要。
  final String gateSummary;

  /// 定点修 prompt（不达标时非空，可直接喂给编辑器 AI）。
  final String fixPrompt;

  /// 商业向指标告警（爽点/钩子）。
  final List<String> extraIssues;

  /// 全部问题（文笔卫生 + 过审闸门 + 商业指标）。
  List<String> get allIssues =>
      <String>[...novelIssues, ...gateIssues, ...extraIssues];

  /// 展示状态。
  String get statusLabel => hasVeto ? '红线' : (pass ? '达线' : '不达标');
}