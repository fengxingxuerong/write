// 真实写作能力回归护栏：断言「引擎真实产出的小说」达到质量下限。
//
// 与相邻测试的分工（避免重复覆盖）：
//   - template_engine_test：引擎**契约**（非空/字数/可复现/提示词不泄漏）；
//   - 各质检器单测：质检器**本身**用手造样本测（含负样本）；
//   - full_novel_e2e_test：全链路**通路**（存储/导出/敏感词），分数只入报告不设限；
//   - 本文件：把「引擎产出 + 质检打分」这条链的**分数下限**钉死——即产品对外承诺的
//     「能写出达标小说」这件事本身。
//
// 为什么需要它：此前没有任何一条测试断言过质量分数。质检器与生成引擎各测各的，
// 一旦引擎退化为「非空、字数够、无红线」的平庸产出，全量测试仍会全绿——那是
// 「测试全绿但产品能力塌了」的典型假阳性。
//
// 阈值来源：全部取自 2026-10-02 实测基线（verify-logs/e2e_report.txt 五题材
// targetWords=1600 × randomLevel 0.35~0.95；verify-logs/demo_novel_qa.txt 三章
// targetWords=2000 × randomLevel=0.65），往下留余量，只拦「能力塌陷」级退化：
//   文笔 90（封顶 90）| AI味 0.00~0.10% | 重复率 2.1~4.5%
//   番茄闸门 96~100（demo）/ 均分 90.0~92.0（e2e）| 对白 42%~54% | 红线 0
//   一致性 人名 0~2、世界观 0、剧情 0 | 敏感词 干净
//
// 同时带**负样本对照**（末尾 group）：把真实产出退化成注水/AI 味文本后，分数必须
// 实打实掉下来。没有这组对照，分数断言可能退化成「质检器坏了也照样绿」的恒真命题。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/quality/fanqie_gate_checker.dart';
import 'package:novel_writer/engine/quality/novel_consistency_checker.dart';
import 'package:novel_writer/engine/quality/novel_quality_checker.dart';
import 'package:novel_writer/engine/template_engine.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/services/sensitive_words.dart';

/// 能力下限（阈值来源见文件头）。
abstract final class AbilityFloor {
  /// 番茄闸门分数线：与 `FanqieGateReport.pass` 同口径（>= 80 且无阻断项且无否决）。
  static const double gatePassScore = 80;

  /// 单章文笔卫生分下限（实测恒 90，封顶 90；留 15 分余量）。
  static const double minProseScore = 75;

  /// AI 囧痕密度上限（%；实测 <= 0.10，留 5 倍余量）。
  static const double maxAiEcho = 0.5;

  /// 相邻段落重复率上限（实测 <= 0.053，留近一倍余量）。
  static const double maxRepetition = 0.10;

  /// 对白占比下限（实测 0.42~0.54；取比 0.18 硬伤线更稳的 0.15）。
  static const double minDialogueRatio = 0.15;

  /// 跨章人名不一致上限（实测 0~2）。
  static const int maxNameIssues = 2;

  /// 单章正文汉字数下限（成章下限，也是闸门 <1500 阻断项的安全垫）。
  static const int minChapterWords = 1200;
}

/// 题材 × 主角 × 卷纲（每行一章），覆盖 5 大题材。
class _BookSpec {
  const _BookSpec(this.key, this.protagonist, this.outline);

  final String key;
  final String protagonist;
  final List<String> outline;
}

const List<_BookSpec> _specs = <_BookSpec>[
  _BookSpec('xuanhuan', '陆沉', <String>[
    '宗门大比被退婚羞辱，濒死觉醒上古剑魂，立誓三年后踏碎宗门大门',
    '藏书阁寻得残缺剑诀，遭师兄栽赃陷害，绝境反杀立威',
  ]),
  _BookSpec('dushi', '陈越', <String>[
    '重生回到高中毕业夜，用未来记忆盘下街角便利店并定下三年规划',
    '连锁化遇资金链危机，靠预判一场行业风口拿到关键投资',
  ]),
  _BookSpec('kehuan', '林晚舟', <String>[
    '深空中继站截获规律脉冲，主角破译出以质数排列的坐标',
    '抵达坐标发现废弃戴森云碎片，带回的数据里藏着太阳系的倒计时',
  ]),
  _BookSpec('yanqing', '苏念', <String>[
    '转学生苏念误闯天台撞见学霸校草偷偷练歌，被拉进地下乐队救场',
    '乐队首演爆红，两人被拍到同框，约定高考结束前只做默契搭档',
  ]),
  _BookSpec('xuanyi', '程野', <String>[
    '旧案重审，六名证人证词严丝合缝，主角却发现第七份笔录被人抽走',
    '第七位证人浮出水面当晚坠楼，主角在遗物里找到第二把相同的钥匙',
  ]),
];

/// 取上一章结尾作为续写承接（与 GenerateViewModel 同口径）。
String _tailForContinuation(String content, {int tailChars = 300}) {
  if (content.length <= tailChars) return content;
  final String tail = content.substring(content.length - tailChars);
  final RegExpMatch? m = RegExp(r'[。！？…]').firstMatch(tail);
  if (m == null) return tail;
  return tail.substring(m.end);
}

/// 一章的质检切片，断言与落盘打印共用。
class _ChapterScore {
  const _ChapterScore({
    required this.words,
    required this.proseScore,
    required this.aiEcho,
    required this.repetition,
    required this.dialogueRatio,
    required this.gateScore,
    required this.gatePass,
    required this.vetoCount,
    required this.blockers,
  });

  final int words;
  final double proseScore;
  final double aiEcho;
  final double repetition;
  final double dialogueRatio;
  final double gateScore;
  final bool gatePass;
  final int vetoCount;
  final List<String> blockers;

  @override
  String toString() =>
      '$words 字 | 文笔 ${proseScore.toStringAsFixed(0)} | '
      'AI味 ${aiEcho.toStringAsFixed(2)}% | '
      '重复 ${(repetition * 100).toStringAsFixed(1)}% | '
      '对白 ${(dialogueRatio * 100).toStringAsFixed(0)}% | '
      '闸门 ${gateScore.toStringAsFixed(1)}${gatePass ? ' 达线' : ' 未达线'} | '
      '否决 $vetoCount | 阻断 $blockers';
}

/// 对 [content] 打分（跨章 8-gram 检查带 [prevContent]，与生产路径一致）。
_ChapterScore _scoreChapter(
  String content, {
  required String prevContent,
  required int chapterIndex,
  required String genre,
  required String protagonist,
}) {
  final QualityReport qr = NovelQualityChecker.check(content);
  final FanqieGateReport gr = FanqieGateChecker(
    genre: genre,
    protagonist: protagonist,
  ).check(content, prevContent: prevContent, chapterIndex: chapterIndex);
  return _ChapterScore(
    words: qr.totalWords,
    proseScore: qr.overallScore,
    aiEcho: qr.aiEchoScore,
    repetition: qr.repetitionScore,
    dialogueRatio: qr.dialogueRatio,
    gateScore: gr.score,
    gatePass: gr.pass,
    vetoCount: gr.redlines.where((FanqieRedlineHit h) => h.veto).length,
    blockers: gr.blockers,
  );
}

/// 生成 [spec] 这本书，返回逐章正文（第 2 章起承接上一章结尾）。
Future<List<String>> _writeBook(_BookSpec spec) async {
  final GenrePreset preset = GenrePresets.get(spec.key);
  const GenerationEngine engine = TemplateEngine();
  final List<String> contents = <String>[];
  for (int i = 0; i < spec.outline.length; i++) {
    final GenerationConfig cfg = GenerationConfig(
      genre: preset.key,
      tone: preset.tones.first,
      targetWords: 1800,
      useExistingSettings: true,
      protagonistName: spec.protagonist,
      randomLevel: 0.5 + i * 0.15,
      continuation: i == 0 ? null : _tailForContinuation(contents.last),
      constraints: const GenerationConstraints(),
    );
    final ContextBundle ctx = ContextBundle(
      characters: const <Character>[],
      worldSettings: const <WorldSetting>[],
      genrePreset: preset,
      plotSkeleton: PlotSkeleton.forGenre(spec.key),
      outline: spec.outline[i],
    );
    final GenerationResult r = await engine.generate(cfg, ctx);
    contents.add(r.content);
  }
  return contents;
}

void main() {
  group('真实成书能力下限（5 题材 × 2 章连写）', () {
    test('逐章：番茄闸门达线 + 文笔/AI味/重复/对白/字数全在能力线内', () async {
      final StringBuffer slices = StringBuffer();
      for (final _BookSpec spec in _specs) {
        final GenrePreset preset = GenrePresets.get(spec.key);
        final List<String> contents = await _writeBook(spec);

        for (int i = 0; i < contents.length; i++) {
          final _ChapterScore s = _scoreChapter(
            contents[i],
            prevContent: i == 0 ? '' : contents[i - 1],
            chapterIndex: i + 1,
            genre: preset.key,
            protagonist: spec.protagonist,
          );
          final String where = '${spec.key} 第 ${i + 1} 章';
          slices.writeln('  $where：$s');

          // ① 闸门达线：产品对外的「能不能过编辑初审」口径，最核心的能力断言。
          expect(s.gateScore, greaterThanOrEqualTo(AbilityFloor.gatePassScore),
              reason: '$where 番茄闸门 ${s.gateScore.toStringAsFixed(1)} 分未达 80 分线，'
                  '阻断=${s.blockers}，否决=${s.vetoCount}');
          expect(s.gatePass, isTrue,
              reason: '$where 闸门未判「达线」：阻断=${s.blockers}，'
                  '否决=${s.vetoCount}，分=${s.gateScore.toStringAsFixed(1)}');

          // ② 文笔卫生分（封顶 90，实测恒 90）。
          expect(s.proseScore, greaterThanOrEqualTo(AbilityFloor.minProseScore),
              reason: '$where 文笔卫生分 ${s.proseScore.toStringAsFixed(0)} '
                  '低于能力线 ${AbilityFloor.minProseScore}');

          // ③ AI 味与重复：模板拼贴稿最典型的两类退化。
          expect(s.aiEcho, lessThanOrEqualTo(AbilityFloor.maxAiEcho),
              reason: '$where AI 味密度 ${s.aiEcho}% 超上限');
          expect(s.repetition, lessThanOrEqualTo(AbilityFloor.maxRepetition),
              reason: '$where 相邻段落重复率 ${s.repetition} 超上限');

          // ④ 对白占比（移动端完读率硬指标，塌陷即能力退化）。
          expect(s.dialogueRatio,
              greaterThanOrEqualTo(AbilityFloor.minDialogueRatio),
              reason: '$where 对白占比 '
                  '${(s.dialogueRatio * 100).toStringAsFixed(0)}% 低于能力线');

          // ⑤ 成章字数：不能交差几百字。
          expect(s.words, greaterThanOrEqualTo(AbilityFloor.minChapterWords),
              reason: '$where 仅 ${s.words} 字，'
                  '未达 ${AbilityFloor.minChapterWords} 字成章线');

          // ⑥ 内容安全：否决级红线永远为零。
          expect(s.vetoCount, 0, reason: '$where 触达否决级红线');
        }
      }
      // 落盘目录必须自建：`verify-logs/` 是 gitignore 的，干净检出里并不存在。
      // 旧实现直接 writeAsString，靠「CI 里先跑过 demo 冒烟顺带建了目录」侥幸绿；
      // 而 `flutter test` 各测试文件是**并行**的，一旦本文件先跑（或单独跑）
      // 就 PathNotFoundException——2026-10-20 在干净 worktree 上复现并修掉。
      // 与 tool/qa_bench_test.dart 同款写法。
      Directory('verify-logs').createSync(recursive: true);
      await File(
              'verify-logs${Platform.pathSeparator}writing_ability_scores.txt')
          .writeAsString('==== 真实成书能力切片 ====\n$slices', flush: true);
      stdout.writeln(slices);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('全书：敏感词干净 + 跨章一致性无结构性矛盾 + 主角真实落地', () async {
      for (final _BookSpec spec in _specs) {
        final List<String> contents = await _writeBook(spec);
        final String fullText = contents.join('\n');

        // ① 敏感词（内置 100+ 词库）必须干净。
        final SensitiveCheckResult sr =
            SensitiveWordsService().check(fullText);
        expect(sr.clean, isTrue,
            reason: '${spec.key} 命中敏感词 ${sr.byCategory}');

        // ② 跨章一致性：世界观/剧情/主角连续性必须为 0（结构性能力）；
        //    人名不一致实测 0~2，给上限——细微人名抖动属可修范畴，非能力塌陷。
        final List<Chapter> chapters = <Chapter>[
          for (int i = 0; i < contents.length; i++)
            Chapter(
              id: '${spec.key}_$i',
              novelId: spec.key,
              title: '第${i + 1}章',
              order: i,
              content: contents[i],
              createdAt: DateTime(2026, 1, 1),
              updatedAt: DateTime(2026, 1, 1),
            ),
        ];
        final ConsistencyReport cr = NovelConsistencyChecker.check(chapters);
        expect(cr.worldIssues, isEmpty,
            reason: '${spec.key} 世界观冲突：${cr.worldIssues}');
        expect(cr.plotIssues, isEmpty,
            reason: '${spec.key} 剧情矛盾：${cr.plotIssues}');
        expect(cr.protagonistIssues, isEmpty,
            reason: '${spec.key} 主角连续性问题：${cr.protagonistIssues}');
        expect(cr.nameIssues.length,
            lessThanOrEqualTo(AbilityFloor.maxNameIssues),
            reason: '${spec.key} 人名不一致 ${cr.nameIssues.length} 处：'
                '${cr.nameIssues}');

        // ③ 主角必须真实出现在正文（整章跑题/主角消失是最严重的能力事故）。
        expect(fullText, contains(spec.protagonist),
            reason: '${spec.key} 主角「${spec.protagonist}」在全书正文一次都没出现');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  // ---- 负样本对照：证明上面的分数断言有「分辨力」，而不是恒真命题 ----
  // 没有这组对照，「分数 >= 阈值」可能因为质检器本身坏了（永远给满分）而永远通过，
  // 那样的能力测试是自欺的。这里把同一段真实产出退化，断言分数必须实打实掉下来。
  group('分数断言必须有分辨力（负样本对照）', () {
    test('对白塌陷的注水稿：对白与闸门必须双双跌破能力线', () async {
      // 先拿一段真实产出作对照基准。
      final List<String> real = await _writeBook(_specs.first);
      final String good = real.first;
      final _ChapterScore goodScore = _scoreChapter(
        good,
        prevContent: '',
        chapterIndex: 1,
        genre: 'xuanhuan',
        protagonist: '陆沉',
      );

      // 退化手法：删掉所有对白行，再用无推进的水段把篇幅撑回去（典型注水稿）。
      final String noDialogue = good
          .split('\n')
          .where((String line) => !line.contains('“') && !line.contains('「'))
          .join('\n');
      final String watered = <String>[
        noDialogue,
        for (int i = 0; i < 40; i++)
          '走廊尽头的灯还亮着，影子被拉得很长，风从窗户缝里钻进来，'
              '他站了一会儿，又坐了回去，桌上的茶已经凉了，'
              '院子里的树影晃了晃，没有人说话。',
      ].join('\n\n');

      final _ChapterScore badScore = _scoreChapter(
        watered,
        prevContent: '',
        chapterIndex: 1,
        genre: 'xuanhuan',
        protagonist: '陆沉',
      );

      // 分辨力断言：退化稿必须比真实稿差，且必须跌破能力线。
      expect(badScore.dialogueRatio, lessThan(goodScore.dialogueRatio),
          reason: '删光对白后对白占比竟然没降——对白指标无分辨力');
      expect(badScore.dialogueRatio,
          lessThan(AbilityFloor.minDialogueRatio),
          reason: '注水稿对白占比 '
              '${(badScore.dialogueRatio * 100).toStringAsFixed(0)}% '
              '仍高于能力线，对白断言形同虚设');
      expect(badScore.gateScore, lessThan(goodScore.gateScore),
          reason: '注水稿闸门分 ${badScore.gateScore} 未低于真实稿 '
              '${goodScore.gateScore}——闸门无分辨力');
      expect(badScore.gateScore, lessThan(AbilityFloor.gatePassScore),
          reason: '注水稿闸门 ${badScore.gateScore} 分仍达线，闸门放过注水稿');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('AI 味堆砌稿：文笔分必须跌破能力线且触发润色', () {
      // 典型 AI 万能句式堆砌（与 NovelQualityChecker 模式表同源）。
      final String aiSlop = List<String>.generate(
        60,
        (int i) => '他深吸一口气，嘴角勾起一抹笑意，眼底闪过一丝精光。'
            '空气仿佛凝固了，时间仿佛静止，心中涌起一股难以言喻的情绪。第 $i 次。',
      ).join('\n\n');

      final QualityReport r = NovelQualityChecker.check(aiSlop);
      expect(r.aiEchoScore, greaterThan(AbilityFloor.maxAiEcho),
          reason: 'AI 味堆砌稿密度 ${r.aiEchoScore}% 未超上限——AI 味指标无分辨力');
      expect(r.overallScore, lessThan(AbilityFloor.minProseScore),
          reason: 'AI 味堆砌稿文笔分 ${r.overallScore} 仍高于能力线——文笔断言形同虚设');
      expect(r.needsPolish, isTrue,
          reason: '满篇 AI 味仍未触发 needsPolish——润色判定失效');
    });
  });
}





