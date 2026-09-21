import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/engine/corpus/beat_corpus.dart';
import 'package:novel_writer/engine/random/seeded_random.dart';

/// BeatCorpus 节拍语料单元测试。
///
/// 覆盖：默认语料 10 个功能组规模与去重（重复率治理护栏）、取样器可复现、
/// groupsForStage 四阶段权重映射与默认回退、groupOf 组名解析与未知回退。
void main() {
  const BeatCorpus corpus = defaultBeatCorpus;

  group('默认语料规模与卫生', () {
    test('10 个功能组每组 >= 12 条（头注释承诺的规模）', () {
      expect(corpus.all.length, 10);
      for (final MapEntry<String, List<String>> e in corpus.all.entries) {
        expect(e.value.length, greaterThanOrEqualTo(12),
            reason: '功能组 ${e.key} 只有 ${e.value.length} 条');
      }
    });

    test('各组模板池内部无重复条目（重复率治理护栏）', () {
      for (final MapEntry<String, List<String>> e in corpus.all.entries) {
        final Set<String> dedup = e.value.toSet();
        expect(dedup.length, e.value.length,
            reason: '功能组 ${e.key} 存在重复模板，会抬高整句重复率');
      }
    });

    test('对白攻防池 >= 48 条（承诺：单章用量内模板不耗尽复用）', () {
      expect(corpus.dialoguePairs.length, greaterThanOrEqualTo(48));
    });
  });

  group('取样器', () {
    test('同种子取样序列可复现', () {
      final SeededRandom a = SeededRandom(seed: 42);
      final SeededRandom b = SeededRandom(seed: 42);
      for (int i = 0; i < 20; i++) {
        expect(a.pick(corpus.hooks), b.pick(corpus.hooks));
      }
    });

    test('十个取样方法均从对应池取件', () {
      final SeededRandom rng = SeededRandom(seed: 7);
      expect(corpus.openers, contains(corpus.opener(rng)));
      expect(corpus.development, contains(corpus.developmentBeat(rng)));
      expect(corpus.tension, contains(corpus.tensionBeat(rng)));
      expect(corpus.climax, contains(corpus.climaxBeat(rng)));
      expect(corpus.twist, contains(corpus.twistBeat(rng)));
      expect(corpus.resolution, contains(corpus.resolutionBeat(rng)));
      expect(corpus.hooks, contains(corpus.hook(rng)));
      expect(corpus.sensory, contains(corpus.sensoryLine(rng)));
      expect(corpus.dialoguePairs, contains(corpus.dialoguePair(rng)));
      expect(corpus.innerThoughts, contains(corpus.innerThought(rng)));
    });
  });

  group('groupsForStage 阶段权重映射', () {
    test('起：开篇为主、首屏有对白（闸门硬指标）', () {
      final Map<String, int> g = BeatCorpus.groupsForStage('起');
      expect(g.keys, containsAll(<String>[
        'openers',
        'sensory',
        'development',
        'dialoguePairs',
        'innerThoughts',
      ]));
      expect(g['openers'], 4);
    });

    test('承：推进与对话并重（对话权重最高）', () {
      final Map<String, int> g = BeatCorpus.groupsForStage('承');
      expect(g['dialoguePairs'], 5);
      expect(g['development'], 4);
    });

    test('转：张力/高潮/转折为主', () {
      final Map<String, int> g = BeatCorpus.groupsForStage('转');
      expect(g.keys, containsAll(<String>[
        'tension',
        'climax',
        'twist',
        'dialoguePairs',
      ]));
      expect(g.containsKey('openers'), isFalse);
    });

    test('合：收束为主', () {
      final Map<String, int> g = BeatCorpus.groupsForStage('合');
      expect(g['resolution'], 5);
    });

    test('未知阶段回退到「承」的映射', () {
      final Map<String, int> unknown = BeatCorpus.groupsForStage('不存在');
      final Map<String, int> cheng = BeatCorpus.groupsForStage('承');
      expect(unknown, cheng);
    });
  });

  group('groupOf 组名解析', () {
    test('全部组名解析到对应池', () {
      expect(corpus.groupOf('openers'), same(corpus.openers));
      expect(corpus.groupOf('development'), same(corpus.development));
      expect(corpus.groupOf('tension'), same(corpus.tension));
      expect(corpus.groupOf('climax'), same(corpus.climax));
      expect(corpus.groupOf('twist'), same(corpus.twist));
      expect(corpus.groupOf('resolution'), same(corpus.resolution));
      expect(corpus.groupOf('hooks'), same(corpus.hooks));
      expect(corpus.groupOf('sensory'), same(corpus.sensory));
      expect(corpus.groupOf('dialoguePairs'), same(corpus.dialoguePairs));
      expect(corpus.groupOf('innerThoughts'), same(corpus.innerThoughts));
    });

    test('未知组名回退到推进组', () {
      expect(corpus.groupOf('???'), same(corpus.development));
    });
  });
}
