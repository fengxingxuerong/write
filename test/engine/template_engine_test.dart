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
  });
}
