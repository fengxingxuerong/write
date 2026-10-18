// 端到端离线长文写作验证：5 章 × 2000 字 ≈ 1 万字连写（零网络、零 API 费）。
//
// 与 tool/write_demo_novel.dart 同一条链路（TemplateEngine + NovelQualityChecker
// + FanqieGateChecker），但验证目标不同：demo 是「三章能成书」的 CI 冒烟，
// 本工具看的是 **1 万字量级下的连贯性与质量稳定性**——跨章承接是否会漂移、
// 重复率/节奏失衡是否随章节数恶化、番茄闸门是否逐章稳定达线。
//
// ⚠️ 与 write_demo_novel.dart 相同：**不能用 `dart run`**（生成链路传递依赖
// package:flutter -> dart:ui，纯 Dart VM 必然报错），必须由
// test/smoke/write_long_novel_test.dart 以 `flutter test` 驱动。
// 详见 write_demo_novel.dart 文件头的完整说明。
//
// 产物：verify-logs/long_novel_10k.txt（正文）+ long_novel_10k_qa.txt（质检报告）
import 'dart:io';

import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/quality/fanqie_gate_checker.dart';
import 'package:novel_writer/engine/quality/novel_quality_checker.dart';
import 'package:novel_writer/engine/template_engine.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/world_setting.dart';

/// 书名：与三章 demo 同一本书，本工具把「三年之约」写到第一卷收卷。
const String _bookTitle = '开局退婚：我以剑魂镇九霄';

/// 大纲主角名。
const String _protagonist = '陆沉';

/// 题材 key（玄幻）。
const String _genre = 'xuanhuan';

/// 五章卷纲：前三章与 demo 逐字一致（同一本书的延伸），后两章把冲突升级到
/// 「内门暗算 → 下山打脸」，检验引擎在更长篇幅下的钩子密度是否衰减。
const List<String> _volumeOutline = <String>[
  '宗门大比当场被退婚羞辱，濒死之际觉醒沉睡的上古剑魂，立誓三年后踏碎云阙宗大门',
  '进入藏书阁顶层寻得残缺剑诀，遭同门师兄栽赃陷害，绝境中以剑魂初露锋芒反杀立威',
  '黑衣人夜袭宗门，主角以剑魂护住同门少年，被隐世长老看破根骨收为亲传，身世伏笔初现',
  '亲传身份引内门世家嫉妒，寒潭秘境试炼遭暗算围杀，剑魂二度觉醒助主角筑基反杀',
  '三年之约临近，主角领队下山历练首战，当众打脸昔日退婚家族执事，大钩收卷',
];

/// 报告里的汉字数（与质检器口径一致：只数 CJK）。
int hanCount(String s) => RegExp(r'[一-鿿]').allMatches(s).length;

/// 截取上一章结尾作为续写承接（与 GenerateViewModel 同口径：取尾部并裁到句首）。
String _tailForContinuation(String content, {int tailChars = 300}) {
  if (content.length <= tailChars) return content;
  final String tail = content.substring(content.length - tailChars);
  final RegExpMatch? m = RegExp(r'[。！？…]').firstMatch(tail);
  if (m == null) return tail;
  return tail.substring(m.end);
}

/// 一万字连写结果：交给测试断言。
class LongWriteResult {
  /// 逐章正文。
  final List<String> chapters;

  /// 质检报告全文。
  final String qaReport;

  /// 全书汉字总数（CJK 口径，与质检器一致）。
  final int totalHanWords;

  /// 构造结果。
  const LongWriteResult({
    required this.chapters,
    required this.qaReport,
    required this.totalHanWords,
  });
}

/// 跑一遍五章连写 + 双质检，返回结果供断言。
Future<LongWriteResult> runLongNovel() async {
  final Directory logDir = Directory('verify-logs')
    ..createSync(recursive: true);

  // 与 demo 同参：2000 字/章、精炼短句、现代网文质感；随机度可用
  // DEMO_RANDOM_LEVEL 覆盖（0~1），缺省 0.65。
  final double randomLevel =
      double.tryParse(Platform.environment['DEMO_RANDOM_LEVEL'] ?? '') ??
          0.65;
  final GenerationConfig base = GenerationConfig(
    genre: _genre,
    tone: GenrePresets.get(_genre).tones.first,
    targetWords: 2000,
    useExistingSettings: false,
    protagonistName: _protagonist,
    randomLevel: randomLevel,
    style: WritingStyle.crisp,
    proseStyle: ProseStyle.web,
    constraints: const GenerationConstraints(),
  );

  final ContextBundle baseCtx = ContextBundle(
    characters: const <Character>[],
    worldSettings: const <WorldSetting>[],
    genrePreset: GenrePresets.get(_genre),
    plotSkeleton: PlotSkeleton.forGenre(_genre),
  );

  const GenerationEngine engine = TemplateEngine();
  final StringBuffer book = StringBuffer()
    ..writeln('《$_bookTitle》')
    ..writeln();

  final List<String> contents = <String>[];
  for (int i = 0; i < _volumeOutline.length; i++) {
    stdout.writeln('[生成] 第 ${i + 1} 章：${_volumeOutline[i]}');
    // 从第 2 章起承接上一章结尾——1 万字连写的核心检验点：剧情不断裂。
    final GenerationConfig cfg = base.copyWith(
      continuation: i == 0 ? null : _tailForContinuation(contents.last),
    );
    final ContextBundle ctx = baseCtx.copyWith(outline: _volumeOutline[i]);
    final Stopwatch sw = Stopwatch()..start();
    final GenerationResult r = await engine.generate(
      cfg,
      ctx,
      onProgress: (GenerationProgress p) {
        stdout.write('\r  进度 ${(p.progress * 100).toStringAsFixed(0)}%'
            ' | ${p.stage}');
      },
    );
    sw.stop();
    stdout.writeln();
    stdout.writeln('  完成：${r.actualWords} 字，耗时 ${sw.elapsed}');
    contents.add(r.content);
    book
      ..writeln('第 ${i + 1} 章')
      ..writeln()
      ..writeln(r.content)
      ..writeln();
  }

  // ===== 质检：NovelQualityChecker（文笔卫生）+ FanqieGateChecker（过审口径）=====
  final StringBuffer qa = StringBuffer()
    ..writeln('==== 《$_bookTitle》五章（1 万字量级）质检报告 ====')
    ..writeln();
  double gateSum = 0;
  double overallSum = 0;
  for (int i = 0; i < contents.length; i++) {
    final QualityReport qr = NovelQualityChecker.check(contents[i]);
    final FanqieGateReport gr = const FanqieGateChecker(
      genre: _genre,
      protagonist: _protagonist,
    ).check(
      contents[i],
      // 跨章 8-gram 重合检查：把上一章内容传给闸门（与生产路径一致）。
      prevContent: i == 0 ? '' : contents[i - 1],
      chapterIndex: i + 1,
    );
    gateSum += gr.score;
    overallSum += qr.overallScore;
    qa
      ..writeln('第 ${i + 1} 章：'
          '${qr.totalWords} 字 | '
          '文笔 ${qr.overallScore.toStringAsFixed(0)}/100 | '
          'AI味 ${qr.aiEchoScore.toStringAsFixed(2)}% | '
          '重复率 ${(qr.repetitionScore * 100).toStringAsFixed(1)}% | '
          '节奏失衡 ${(qr.rhythmScore * 100).toStringAsFixed(1)}% | '
          '对白占比 ${(qr.dialogueRatio * 100).toStringAsFixed(0)}% | '
          '硬伤 ${qr.hardViolations.length} 处 | '
          '番茄闸门 ${gr.score.toStringAsFixed(1)} 分'
          '${gr.pass ? '（达线）' : '（未达线）'}')
      ..writeln('  摘要：${gr.summary}');
    for (final FanqieGateIssue e in gr.issues) {
      qa.writeln('    - $e');
    }
    for (final FanqieRedlineHit h in gr.redlines) {
      qa.writeln('    - 红线[${h.veto ? '否决' : '提示'}] ${h.category}：${h.word}');
    }
    if (qr.needsPolish) {
      qa.writeln('    - 建议：该章文笔指标触发润色阈值，建议走 LLM 润色');
    }
    qa.writeln();
  }
  final int totalHan =
      contents.fold<int>(0, (int s, String c) => s + hanCount(c));
  qa
    ..writeln('全书总字数：$totalHan 汉字（目标 ≥ 10000）')
    ..writeln('全书均分：文笔 ${(overallSum / contents.length).toStringAsFixed(1)} / 100，'
        '番茄闸门 ${(gateSum / contents.length).toStringAsFixed(1)} / 100')
    ..writeln();

  final File novelFile =
      File('${logDir.path}${Platform.pathSeparator}long_novel_10k.txt');
  final File qaFile =
      File('${logDir.path}${Platform.pathSeparator}long_novel_10k_qa.txt');
  await novelFile.writeAsString(book.toString(), flush: true);
  await qaFile.writeAsString(qa.toString(), flush: true);

  stdout.writeln();
  stdout.writeln(qa.toString());
  stdout.writeln('[产物] 正文：${novelFile.path}');
  stdout.writeln('[产物] 质检：${qaFile.path}');
  return LongWriteResult(
    chapters: contents,
    qaReport: qa.toString(),
    totalHanWords: totalHan,
  );
}
