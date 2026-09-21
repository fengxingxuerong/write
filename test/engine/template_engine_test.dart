import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/template_engine.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/world_setting.dart';

/// TemplateEngine 单元测试（纯逻辑，运行在 Isolate 中，无 UI 依赖）
///
/// 覆盖：产出非空、含段落、字数不超上限、>20000 被 clamp、
/// 同配置可复现、空 context 兜底、进度回报、以及「逼近目标字数」修复验证。
///
/// 历史：2026-07-31 修复前 run() 仅跑一个情节骨架（约数百字）即停，远未逼近目标；
/// 修复后 run() 在未达 target 前循环拼接承/转发展段，故对 target≤20000 必有
/// actualWords ≥ target。该保证为确定性（仅依赖种子化 rng 序列与字数阈值），
/// 因此「实际字数 ≥ 目标」是可稳定断言的回归护栏，而非 brittle 断言。

ContextBundle _buildContext({
  List<Character> characters = const [],
  List<WorldSetting> worldSettings = const [],
  String genre = 'xuanhuan',
}) {
  return ContextBundle(
    characters: characters,
    worldSettings: worldSettings,
    genrePreset: GenrePresets.get(genre),
    plotSkeleton: PlotSkeleton.forGenre(genre),
  );
}

GenerationConfig _buildConfig({
  String genre = 'xuanhuan',
  String tone = '热血',
  int targetWords = 2000,
  double randomLevel = 0.3,
  int maxWords = 20000,
}) {
  return GenerationConfig(
    genre: genre,
    tone: tone,
    targetWords: targetWords,
    randomLevel: randomLevel,
    constraints: GenerationConstraints(maxWordsPerChapter: maxWords),
  );
}

void main() {
  group('TemplateEngine 生成质量', () {
    test('产出非空且字数大于 0', () async {
      const engine = TemplateEngine();
      final result = await engine.generate(_buildConfig(), _buildContext());
      expect(result.content, isNotEmpty);
      expect(result.actualWords, greaterThan(0));
    });

    test('产出含多个段落（空行分隔）', () async {
      const engine = TemplateEngine();
      final result = await engine.generate(
        _buildConfig(targetWords: 2000),
        _buildContext(),
      );
      final blocks = result.content
          .split(RegExp(r'\n+'))
          .where((s) => s.trim().isNotEmpty)
          .toList();
      expect(blocks.length, greaterThanOrEqualTo(2));
    });

    test('实际字数不超过约束上限', () async {
      const engine = TemplateEngine();
      final result = await engine.generate(
        _buildConfig(targetWords: 2000),
        _buildContext(),
      );
      expect(result.actualWords, lessThanOrEqualTo(20000));
    });

    test('目标字数超过 20000 时被 clamp 到上限内', () async {
      const engine = TemplateEngine();
      final result = await engine.generate(
        _buildConfig(targetWords: 50000, maxWords: 20000),
        _buildContext(),
      );
      expect(result.actualWords, lessThanOrEqualTo(20000));
    });

    test('maxWords 配置过小（< 200）时不抛 ArgumentError，按 200 下限生成', () async {
      const engine = TemplateEngine();
      final result = await engine.generate(
        _buildConfig(targetWords: 100, maxWords: 150),
        _buildContext(),
      );
      // 修复前 clamp(200, 150) 直接抛 ArgumentError；修复后不崩溃且产出非空。
      expect(result.content, isNotEmpty);
      expect(result.actualWords, greaterThan(0));
    });

    test('同配置可复现（相同种子 -> 相同正文）', () async {
      const engine = TemplateEngine();
      final cfg = _buildConfig(targetWords: 2000, randomLevel: 0.3);
      final ctx = _buildContext();
      final r1 = await engine.generate(cfg, ctx);
      final r2 = await engine.generate(cfg, ctx);
      expect(r1.content, equals(r2.content));
      expect(r1.actualWords, equals(r2.actualWords));
    });

    test('空 context（无角色/世界观）不崩溃并产出正文', () async {
      const engine = TemplateEngine();
      final ctx = _buildContext(characters: const [], worldSettings: const []);
      final result = await engine.generate(_buildConfig(), ctx);
      expect(result.content, isNotEmpty);
    });

    test('回报进度回调且进度比例在 [0,1]', () async {
      const engine = TemplateEngine();
      final progress = <GenerationProgress>[];
      await engine.generate(
        _buildConfig(),
        _buildContext(),
        onProgress: progress.add,
      );
      expect(progress, isNotEmpty);
      for (final p in progress) {
        expect(p.progress, inInclusiveRange(0.0, 1.0));
      }
    });

    test('同一句内不会出现「A 塞给 A」式自指（槽位互斥回归护栏）', () async {
      const engine = TemplateEngine();
      final StringBuffer all = StringBuffer();
      for (int i = 0; i < 3; i++) {
        final result = await engine.generate(
          _buildConfig(targetWords: 1200, randomLevel: 0.2 + i * 0.3),
          _buildContext(),
        );
        all.write(result.content);
      }
      final RegExp selfGive = RegExp(r'(\S{2,4})塞给\1|(\S{2,4})递给\1');
      expect(selfGive.allMatches(all.toString()), isEmpty);
    });

    test('说话人不会在引号里喊自己（句首主语自指回归护栏）', () async {
      const engine = TemplateEngine();
      final StringBuffer all = StringBuffer();
      for (int i = 0; i < 3; i++) {
        final result = await engine.generate(
          _buildConfig(targetWords: 1200, randomLevel: 0.2 + i * 0.3),
          _buildContext(),
        );
        all.write(result.content);
      }
      // 「陆沉摇头：「陆沉…」」式自指：句首主语名 + 引号内同名。
      final RegExp selfTalk = RegExp(r'陆沉[^。\n「」]{0,6}「[^」]*陆沉');
      expect(selfTalk.allMatches(all.toString()), isEmpty);
    });

    test('首屏保底：首段含对白且含冲突信号（番茄闸门口径）', () async {
      const engine = TemplateEngine();
      // 闸门冲突标记词表（fanqie_gate_checker._conflict 的子集）。
      const List<String> conflictMarks = <String>[
        '吼', '骂', '砸', '押', '欠', '逐', '抢', '抓', '审', '封门', '退婚',
        '断', '碎', '伤', '血', '死', '遗物', '最后', '偿命', '让位', '除名',
        '罚', '跪', '赔', '欠条', '警告', '期限', '当场', '拉走', '抬走',
      ];
      for (final double level in <double>[0.1, 0.4, 0.7, 0.95]) {
        final result = await engine.generate(
          _buildConfig(targetWords: 1500, randomLevel: level),
          _buildContext(),
        );
        final String head = result.content.substring(
          0,
          result.content.length < 300 ? result.content.length : 300,
        );
        expect(head, contains('「'), reason: 'randomLevel=$level：首屏缺对白');
        expect(
          conflictMarks.any(head.contains),
          isTrue,
          reason: 'randomLevel=$level：首屏无冲突信号 -> $head',
        );
      }
    });

    test('对白占比保底：引号内字数占比达标（≥18%）', () async {
      const engine = TemplateEngine();
      for (final double level in <double>[0.2, 0.5, 0.8]) {
        final result = await engine.generate(
          _buildConfig(targetWords: 2000, randomLevel: level),
          _buildContext(),
        );
        final String text = result.content;
        final RegExp quote = RegExp(r'[“"「『]([^”"」』]{1,200})[”"」』]');
        final StringBuffer inner = StringBuffer();
        for (final RegExpMatch m in quote.allMatches(text)) {
          inner.write(m.group(1));
        }
        int han(String s) => RegExp(r'[\u4e00-\u9fff]').allMatches(s).length;
        final int total = han(text);
        final double ratio = total == 0 ? 0 : han(inner.toString()) / total;
        expect(ratio, greaterThanOrEqualTo(0.18),
            reason: 'randomLevel=$level：对白字数占比 ${ratio.toStringAsFixed(3)}');
      }
    });

    test('跨章查重种子：续写章不复用上一章结尾的原句', () async {
      const engine = TemplateEngine();
      final GenerationResult first = await engine.generate(
        _buildConfig(targetWords: 1500, randomLevel: 0.35),
        _buildContext(),
      );
      final String tail = first.content.length > 300
          ? first.content.substring(first.content.length - 300)
          : first.content;
      final GenerationResult second = await engine.generate(
        _buildConfig(targetWords: 1500, randomLevel: 0.35)
            .copyWith(continuation: tail),
        _buildContext(),
      );
      final Iterable<String> tailSentences = tail
          .split(RegExp(r'[。！？…\n]+'))
          .map((String s) => s.trim())
          .where((String s) => s.length >= 10);
      for (final String s in tailSentences) {
        expect(second.content.contains(s), isFalse,
            reason: '续写章复用了上一章结尾句：$s');
      }
    });

    test('段落引导语高度分散（单一开头占比受控）', () async {
      const engine = TemplateEngine();
      final result = await engine.generate(
        _buildConfig(targetWords: 2000, randomLevel: 0.5),
        _buildContext(),
      );
      final List<String> paragraphs = result.content
          .split(RegExp(r'\n+'))
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
      expect(paragraphs.length, greaterThanOrEqualTo(5));
      // 统计段落开头 4 字前缀的出现频率：25 条引导语 + 分池去重，
      // 不允许单一开头吃掉超过 1/3 的段落。
      final Map<String, int> prefixCount = <String, int>{};
      for (final String p in paragraphs) {
        final String prefix =
            p.length >= 4 ? p.substring(0, 4) : p.padRight(4);
        prefixCount[prefix] = (prefixCount[prefix] ?? 0) + 1;
      }
      final int maxFreq =
          prefixCount.values.reduce((int a, int b) => a > b ? a : b);
      expect(maxFreq * 3, lessThanOrEqualTo(paragraphs.length + 2),
          reason: '单一开头频率过高：$prefixCount');
    });

    test('小型目标产出为正且不超限（引擎容量内的稳健断言）', () async {
      const engine = TemplateEngine();
      final result = await engine.generate(
        _buildConfig(targetWords: 300),
        _buildContext(),
      );
      expect(result.actualWords, greaterThan(0));
      expect(result.actualWords, lessThanOrEqualTo(20000));
    });

    test('修复验证：循环拼接使产出逼近目标（实际字数 ≥ 目标）', () async {
      // 2026-07-31 修复前 run() 仅跑一个骨架（约数百字）即停，远未逼近目标；
      // 修复后 run() 在未达 target 前循环拼接承/转发展段，current 严格单调递增，
      // 故实际字数必 ≥ 目标。该断言同时作为回归护栏：若改回单骨架逻辑，产出
      // 将远低于目标而失败。target=800 远小于旧单骨架上限，却明确高于「约数百字」。
      const engine = TemplateEngine();
      const int target = 800;
      final result = await engine.generate(
        _buildConfig(targetWords: target),
        _buildContext(),
      );
      expect(result.actualWords, greaterThanOrEqualTo(target));
      expect(result.actualWords, lessThanOrEqualTo(20000));
    });

    test('多章连写：不同 continuation 产生不同正文（换皮回归护栏）', () async {
      // _deriveSeed 必须把 continuation 混入种子：否则多章连写的每一章
      // 拿同一随机序列，生成节奏/句式/人物出场完全同构的「换皮章节」。
      const engine = TemplateEngine();
      final r1 = await engine.generate(
        _buildConfig(targetWords: 500)
            .copyWith(continuation: '上一章结尾：他握紧了手中的剑。'),
        _buildContext(),
      );
      final r2 = await engine.generate(
        _buildConfig(targetWords: 500)
            .copyWith(continuation: '上一章结尾：她转身走进了雨里。'),
        _buildContext(),
      );
      expect(r1.content, isNot(equals(r2.content)));
    });

    test('骨架提示词不得泄漏进正文（番茄闸门口径）', () async {
      // 节拍描述词是抽象规划语言，原样落进正文会被闸门判「泄漏」。
      // 回归护栏：一旦 _writeStageParagraph 重新把 hint 织进正文即失败。
      const engine = TemplateEngine();
      final result = await engine.generate(
        _buildConfig(targetWords: 800),
        _buildContext(),
      );
      const List<String> skeletonHints = <String>[
        '一次奇遇让主角获得机缘',
        '遭遇强敌或瓶颈',
        '心境蜕变',
        '本场景任务',
        '必须完成的节拍',
      ];
      for (final String hint in skeletonHints) {
        expect(
          result.content.contains(hint),
          isFalse,
          reason: '骨架提示词「$hint」泄漏进正文',
        );
      }
    });
  });
}
