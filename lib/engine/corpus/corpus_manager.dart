import 'package:novel_writer/engine/corpus/beat_corpus.dart';
import 'package:novel_writer/engine/corpus/names_corpus.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/corpus/sentence_templates.dart';

/// 语料管理器。
///
/// 按题材聚合 [SentenceTemplates] / [NamesCorpus] / [PlotSkeleton] /
/// [BeatCorpus]，供 [TemplateEngine] 在生成时取样。语料均为静态常量，
/// 因此在 Isolate 内也能通过 [loadPreset] 直接重建，无需跨隔离传递大数据。
class CorpusManager {
  /// 句式模板库。
  final SentenceTemplates sentenceTemplates;

  /// 姓名 / 地名 / 势力语料。
  final NamesCorpus namesCorpus;

  /// 情节骨架集合。
  final PlotSkeleton plotSkeleton;

  /// 叙事节拍语料库。
  final BeatCorpus beatCorpus;

  /// 构造管理器。
  const CorpusManager({
    required this.sentenceTemplates,
    required this.namesCorpus,
    required this.plotSkeleton,
    this.beatCorpus = defaultBeatCorpus,
  });

  /// 按题材加载语料（在 Isolate 内亦可调用，零网络）。
  static CorpusManager loadPreset(String genre) {
    return CorpusManager(
      sentenceTemplates: SentenceTemplates.forGenre(genre),
      namesCorpus: NamesCorpus.forGenre(genre),
      plotSkeleton: PlotSkeleton.forGenre(genre),
      beatCorpus: defaultBeatCorpus,
    );
  }
}
