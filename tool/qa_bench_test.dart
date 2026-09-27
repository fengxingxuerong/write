// ignore_for_file: avoid_print
// 说明：本脚本是耗时基准工具而非产品代码，需要把每轮原始数据直接打到
// --reporter expanded 的标准输出上，故压制该 lint（与 tool/ 下其他工具同例）。
// 20 万字级「全书体检」耗时基准（BookQaService 热路径探针）
//
// 测量对象与生产路径完全一致：
//   BookQaService.check() = 逐章 NovelQualityChecker.check（文笔卫生：AI 囷痕 /
//                           相邻段落相似度 / 节奏 / 五感 / 对话占比）
//                         + FanqieGateChecker.check（过审闸门：12 维 + 术语 +
//                           intraRepeat 段落两两比对）
//                         + PipelineQa 商业指标（钩子 / 爽点 / 异动 / 重复 …）
//   入口：workspace「全书体检」弹窗（BookQaReportDialog）
//
// 运行：flutter test tool/qa_bench_test.dart --reporter expanded
// 产物：verify-logs/qa_bench_raw.txt（每轮原始耗时 + 分维度拆分）
//
// 输入文本完全由固定词表按下标推导（不用 Random），因此不同代码版本、不同
// 机器上的两轮数据可直接对比；文本里刻意放了 1 组高相似段落对与若干 AI 囷痕
// 关键词，确保 intraRepeat / 相似度这两条最贵的分支真的被走到而不是空转。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/ai_pipeline/services/book_qa_service.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/engine/quality/fanqie_gate_checker.dart';
import 'package:novel_writer/engine/quality/novel_quality_checker.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';

/// 压测项目 id。
const String _id = 'qa-bench-200k';

/// 章节数（与 save_stress_test 的 20 万字口径一致）。
const int _chapterCount = 100;

/// 每章段落数。
///
/// 45 段 × 约 44 字/段 ≈ 2000 字，与 `targetWordsPerChapter` 一致；
/// 原值 26 只生成约 1150 字/章（全书 11.5 万字），够不到本文件自设的
/// 「输入必须达到 15 万字级」门槛，基准必然自失败，故按 20 万字口径回正。
const int _paragraphsPerChapter = 45;

const List<String> _who = <String>[
  '陈默', '周扬', '老韩', '柳莺', '沈青', '那个瞎眼的琴师',
];
const List<String> _where = <String>[
  '擂台', '崖径', '石室', '雪谷', '夜市的尽头', '废弃的渡口水闸',
];
const List<String> _act = <String>[
  '把灵力压进指节，一寸一寸顶开对方的钳制',
  '听见瓦片在屋脊上碎开，碎屑落进领口里冰凉',
  '闻到焦苦的药味混着铁锈，从门缝里漫出来',
  '盯着地上那串湿脚印，呼吸不由自主地放轻',
  '伸手掀开木匣的油布，里头只余半截断刃',
  '皱着眉把符纸按在裂开的石面上，指腹被割出一道血线',
];
const List<String> _turn = <String>[
  '就在这时，台下忽然传来一阵急促的脚步',
  '他忽然明白，对方真正要的不是这件东西',
  '话音未落，远处传来三声长号，所有人都变了脸色',
  '可那琴弦的声音一响，他忽然僵在原地',
];

/// 生成第 [order] 章正文（约 1800~2100 字）。
String chapterText(int order) {
  final StringBuffer b = StringBuffer();
  final String dup = '第$order章的这一段会被原样复制到本章靠后的位置，'
      '用来确保 intraRepeat 的段落两两比对分支真的被执行到而不是空转。';
  for (int p = 0; p < _paragraphsPerChapter; p++) {
    if (p == 12) {
      b.writeln(dup);
      continue;
    }
    if (p == 20) {
      // 与第 12 段高度相似（仅尾部改动），触发相似度阈值分支。
      b.writeln('$dup只是末尾多出一句：他没有回头。');
      continue;
    }
    final String who = _who[(p + order) % _who.length];
    final String where = _where[(p * 3 + order) % _where.length];
    final StringBuffer para = StringBuffer()
      ..write('$who在$where')
      ..write(_act[(p * 5 + order) % _act.length])
      ..write('。');
    if (p % 4 == 0) {
      para
        ..write(who)
        ..write('低声道：“再往前一步，今日就没人有台阶可下了。”');
    }
    if (p % 7 == 3) {
      para.write('他的嘴角勾起一抹极淡的弧度，眼底闪过一丝冷意。');
    }
    if (p % 9 == 5) {
      para
        ..write(_turn[(p + order) % _turn.length])
        ..write('——来的人，竟然是他。');
    }
    b.writeln(para.toString());
  }
  return b.toString();
}

/// 构造 20 万字级压测书。
Novel buildBook({int chapterCount = _chapterCount}) {
  final DateTime t = DateTime(2026, 1, 1);
  final List<Chapter> chapters = <Chapter>[];
  for (int i = 1; i <= chapterCount; i++) {
    chapters.add(Chapter(
      id: 'c$i',
      novelId: _id,
      title: '第$i章 风起',
      order: i,
      content: chapterText(i),
      createdAt: t,
      updatedAt: t,
    ));
  }
  return Novel(
    id: _id,
    title: '基准之书',
    genre: '玄幻',
    tone: '热血',
    targetWordsPerChapter: 2000,
    createdAt: t,
    updatedAt: t,
    chapters: chapters,
    characters: <Character>[
      const Character(
        id: 'ch-1',
        novelId: _id,
        name: '陈默',
        role: '主角',
        traits: '冷静果断',
        background: '',
        relationships: '',
      ),
    ],
    worldSettings: <WorldSetting>[
      const WorldSetting(
        id: 'w-1',
        novelId: _id,
        title: '九幽宗',
        category: '势力',
        content: '九幽宗盘踞北境雪谷，以炼体术闻名，宗主人称铁面菩萨。',
      ),
    ],
  );
}

void main() {
  test('20 万字全书体检耗时基准（3 轮 + 分维度拆分）', () {
    const BookQaService service = BookQaService();
    final Novel book = buildBook();

    int chars = 0;
    for (final Chapter c in book.chapters) {
      chars += c.content.length;
    }
    expect(chars, greaterThan(150000), reason: '输入必须达到 15 万字级');

    // 分维度拆分：取前 20 章样本逐维度单独计时（调用序列与 check() 内一致）。
    final List<Chapter> sample = book.chapters.take(20).toList();
    final FanqieGateChecker gate = FanqieGateChecker(
      genre: book.genre,
      protagonist: '陈默',
      worldTerms: <String>['九幽宗'],
    );
    final Stopwatch novelSw = Stopwatch();
    final Stopwatch gateSw = Stopwatch();
    final Stopwatch bizSw = Stopwatch();
    for (final Chapter c in sample) {
      final String text = c.content.trim();
      novelSw.start();
      NovelQualityChecker.check(text);
      novelSw.stop();
      gateSw.start();
      gate.check(text, prevContent: '', chapterIndex: c.order);
      gateSw.stop();
      bizSw.start();
      PipelineQa.hasEndingHook(text);
      PipelineQa.thrillPerThousand(text);
      PipelineQa.surgePerThousand(text);
      PipelineQa.aiEchoPct(text);
      PipelineQa.adjacentRepetition(text);
      PipelineQa.rhythmScore(text);
      bizSw.stop();
    }

    final List<int> rounds = <int>[];
    double avg = 0;
    int passCount = 0;
    for (int r = 0; r < 3; r++) {
      final Stopwatch sw = Stopwatch()..start();
      final BookQaReport rep = service.check(book);
      sw.stop();
      rounds.add(sw.elapsedMilliseconds);
      avg = rep.avgScore;
      passCount = rep.passCount;
    }
    final int best = rounds.reduce((int a, int b) => a < b ? a : b);

    final String out = <String>[
      '输入：${book.chapters.length} 章 / $chars 字符（每章 $_paragraphsPerChapter 段）',
      'BookQaService.check 三轮：${rounds.join(" / ")} ms（最好 ${best}ms）',
      '分维度（20 章样本）：文笔卫生 ${novelSw.elapsedMilliseconds}ms / '
          '过审闸门 ${gateSw.elapsedMilliseconds}ms / 商业指标 '
          '${bizSw.elapsedMilliseconds}ms',
      '结果口径：平均分 ${avg.toStringAsFixed(1)}、达线 $passCount 章',
      '口径：以上为单线程同步耗时；生产中 >5000 字的书由 Isolate.run 承担，'
          'UI 线程不阻塞',
    ].join('\n');
    print(out);

    Directory('verify-logs').createSync(recursive: true);
    File('verify-logs/qa_bench_raw.txt').writeAsStringSync(
      '${DateTime.now().toIso8601String()}  qa_bench\n$out\n',
      mode: FileMode.append,
      flush: true,
    );
  }, timeout: const Timeout(Duration(minutes: 20)));
}
