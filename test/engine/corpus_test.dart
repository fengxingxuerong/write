import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/corpus/corpus_manager.dart';
import 'package:novel_writer/engine/corpus/names_corpus.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/corpus/sentence_templates.dart';
import 'package:novel_writer/engine/random/seeded_random.dart';

/// 语料完整性单元测试
///
/// 覆盖：5 题材各自的 姓名≥30 / 地名≥20 / 句式模板≥40 / 情节骨架≥10；
/// 未知题材回退到玄幻；CorpusManager 聚合；SentenceTemplates.pick 可复现。
const List<String> _genres = ['xuanhuan', 'dushi', 'kehuan', 'yanqing', 'xuanyi'];

void main() {
  group('语料完整性（5 题材）', () {
    for (final g in _genres) {
      test('[$g] 姓名 >= 30', () {
        expect(NamesCorpus.forGenre(g).names.length, greaterThanOrEqualTo(30));
      });
      test('[$g] 地名 >= 20', () {
        expect(NamesCorpus.forGenre(g).places.length, greaterThanOrEqualTo(20));
      });
      test('[$g] 势力 >= 10', () {
        expect(NamesCorpus.forGenre(g).factions.length, greaterThanOrEqualTo(10));
      });
      test('[$g] 句式模板 >= 40', () {
        expect(
          SentenceTemplates.forGenre(g).templates.length,
          greaterThanOrEqualTo(40),
        );
      });
      test('[$g] 情节骨架 >= 10', () {
        expect(PlotSkeleton.forGenre(g).skeletons.length, greaterThanOrEqualTo(10));
      });
    }
  });

  group('语料兜底与聚合', () {
    test('未知题材回退到玄幻且不抛异常', () {
      expect(NamesCorpus.forGenre('unknown').names.length, greaterThanOrEqualTo(30));
      expect(PlotSkeleton.forGenre('unknown').skeletons.length, greaterThanOrEqualTo(10));
      expect(
        SentenceTemplates.forGenre('unknown').templates.length,
        greaterThanOrEqualTo(40),
      );
    });

    test('CorpusManager.loadPreset 按题材聚合三套语料', () {
      final corpus = CorpusManager.loadPreset('kehuan');
      expect(corpus.namesCorpus.names.length, greaterThanOrEqualTo(30));
      expect(corpus.sentenceTemplates.templates.length, greaterThanOrEqualTo(40));
      expect(corpus.plotSkeleton.skeletons.length, greaterThanOrEqualTo(10));
    });

    test('SentenceTemplates.pick 使用注入随机源且可复现', () {
      final t = SentenceTemplates.forGenre('xuanhuan');
      final a = SeededRandom(seed: 7);
      final b = SeededRandom(seed: 7);
      final pA = List<String>.generate(10, (_) => t.pick(a));
      final pB = List<String>.generate(10, (_) => t.pick(b));
      expect(pA, equals(pB));
      expect(t.pick(SeededRandom(seed: 1)), isNotEmpty);
    });

    test('PlotSkeleton 每个骨架含起承转合式节拍', () {
      final skeletons = PlotSkeleton.forGenre('xuanhuan').skeletons;
      for (final skeleton in skeletons) {
        expect(skeleton.length, greaterThanOrEqualTo(4));
        for (final beat in skeleton) {
          expect(beat.stage, isNotEmpty);
          expect(beat.hint, isNotEmpty);
        }
      }
    });
  });
}
