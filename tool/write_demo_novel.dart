// 端到端离线写作演示：用 TemplateEngine（零网络、零 API）一键生成三章正文，
// 并用工程内置的 NovelQualityChecker + FanqieGateChecker 出质检报告。
// 用法：dart run tool/write_demo_novel.dart
// 产物：verify-logs/demo_novel.txt（正文）+ verify-logs/demo_novel_qa.txt（质检报告）
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

/// 书名（番茄风：冲突前置 + 金手指明示）。
const String _bookTitle = '开局退婚：我以剑魂镇九霄';

/// 大纲主角名。
const String _protagonist = '陆沉';

/// 题材 key（玄幻）。
const String _genre = 'xuanhuan';

/// 三章卷纲：按番茄「黄金三章」节奏设计，每章一个「危机→反转→埋钩」闭环。
const List<String> _volumeOutline = <String>[
  '宗门大比当场被退婚羞辱，濒死之际觉醒沉睡的上古剑魂，立誓三年后踏碎云阙宗大门',
  '进入藏书阁顶层寻得残缺剑诀，遭同门师兄栽赃陷害，绝境中以剑魂初露锋芒反杀立威',
  '黑衣人夜袭宗门，主角以剑魂护住同门少年，被隐世长老看破根骨收为亲传，身世伏笔初现',
];

/// 截取上一章结尾作为续写承接（与 GenerateViewModel 同口径：取尾部并裁到句首）。
String _tailForContinuation(String content, {int tailChars = 300}) {
  if (content.length <= tailChars) return content;
  final String tail = content.substring(content.length - tailChars);
  final RegExpMatch? m = RegExp(r'[。！？…]').firstMatch(tail);
  if (m == null) return tail;
  return tail.substring(m.end);
}

Future<void> main() async {
  final Directory logDir = Directory('verify-logs')
    ..createSync(recursive: true);

  // 与 UI 默认等价的生成配置：2000 字/章、精炼短句节奏、现代网文质感。
  // 随机度可用环境变量 DEMO_RANDOM_LEVEL 覆盖（0~1），便于抽样验证
  // 不同种子下的质检稳定性；缺省 0.65。
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
    // 从第 2 章起承接上一章结尾（多章连写的关键：剧情不断裂）。
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
    ..writeln('==== 《$_bookTitle》三章质检报告 ====')
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
  qa
    ..writeln('全书均分：文笔 ${(overallSum / contents.length).toStringAsFixed(1)} / 100，'
        '番茄闸门 ${(gateSum / contents.length).toStringAsFixed(1)} / 100')
    ..writeln();

  final File novelFile =
      File('${logDir.path}${Platform.pathSeparator}demo_novel.txt');
  final File qaFile =
      File('${logDir.path}${Platform.pathSeparator}demo_novel_qa.txt');
  await novelFile.writeAsString(book.toString(), flush: true);
  await qaFile.writeAsString(qa.toString(), flush: true);

  stdout.writeln();
  stdout.writeln(qa.toString());
  stdout.writeln('[产物] 正文：${novelFile.path}');
  stdout.writeln('[产物] 质检：${qaFile.path}');
}
