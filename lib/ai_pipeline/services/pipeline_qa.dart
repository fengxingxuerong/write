import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';

/// 本地规则质检（零成本，不消耗 API）。
///
/// 移植自 `scripts/generate_novel.py` 的 `quality_check` 与演示脚本指标：
/// - AI 味密度：高频 AI 表达出现频率（越低越好）
/// - 相邻段落重复率：Jaccard 相似度均值
/// - 节奏失衡：超长/超短段落占比
/// - 世界观关键词冲突：同一关键词在不同章节「肯定/否定」表述相反
class PipelineQa {
  PipelineQa._();

  /// AI 高频表达（反 AI 腔词表）。
  static const List<String> aiClicheWords = <String>[
    '嘴角', '唇角', '眼底', '眼神', '目光', '仿佛', '似乎', '宛如',
    '空气', '心跳', '深吸', '命运', '轨迹', '万语', '舒了一口',
    '微微上扬', '闪过一丝', '勾起一抹', '空气凝固', '嘴角勾起', '眼底闪过',
  ];

  /// 世界观关键词（检测前后文冲突）。
  static const List<String> worldKeywords = <String>[
    '灵气', '斗气', '筑基', '金丹', '元婴', '灵石', '灵根', '灵脉',
  ];

  /// 否定词（前缀 6 字内出现则视为否定表述）。
  static const List<String> negations = <String>[
    '不', '没', '无', '没有', '并未', '不曾', '决不', '毫无',
  ];

  /// AI 味密度（%）：命中次数 / 总字数 * 100。
  static double aiEchoPct(String text) {
    final int words = AppConstants.countWords(text);
    if (words == 0) return 0.0;
    int hits = 0;
    for (final String w in aiClicheWords) {
      hits += _countOccurrences(text, w);
    }
    return (hits / words * 100).clamp(0.0, 100.0);
  }

  /// 相邻段落重复率：相邻段落二元组 Jaccard 相似度均值。
  static double adjacentRepetition(String text) {
    final List<String> paras = text
        .split('\n\n')
        .where((String p) => p.trim().length > 10)
        .toList();
    if (paras.length < 2) return 0.0;
    double sum = 0.0;
    for (int i = 1; i < paras.length; i++) {
      sum += _jaccard(paras[i - 1], paras[i]);
    }
    return sum / (paras.length - 1);
  }

  /// 节奏失衡：超长（>400 字）或超短（<30 字）段落占比。
  static double rhythmScore(String text) {
    final List<String> paras = text
        .split('\n\n')
        .where((String p) => p.trim().length > 10)
        .toList();
    if (paras.isEmpty) return 0.0;
    int bad = 0;
    for (final String p in paras) {
      final int w = AppConstants.countWords(p);
      if (w < 30 || w > 400) bad++;
    }
    return bad / paras.length;
  }

  /// 生成一章节的质检摘要（供 UI 报告展示）。
  static Map<String, dynamic> chapterReport(PipelineChapter chapter) {
    final double echo = aiEchoPct(chapter.content);
    final double rep = adjacentRepetition(chapter.content);
    final double rhy = rhythmScore(chapter.content);
    return <String, dynamic>{
      'idx': chapter.idx,
      'words': chapter.words,
      'aiEcho': echo.toStringAsFixed(2),
      'repetition': rep.toStringAsFixed(3),
      'rhythm': rhy.toStringAsFixed(3),
      'needsPolish': echo > 0.02 || rep > 0.10,
    };
  }

  /// 跨章世界观关键词冲突检测（对比已生成章节与新增章节）。
  ///
  /// 返回冲突描述列表。
  static List<String> worldConflicts(
    List<PipelineChapter> existing,
    PipelineChapter added,
  ) {
    final List<String> result = <String>[];
    for (final String kw in worldKeywords) {
      final int pos = added.content.indexOf(kw);
      if (pos < 0) continue;
      final bool addedNeg = _hasNegationBefore(added.content, pos);
      // 在既有章节里找同关键词的首现。
      for (final PipelineChapter ch in existing) {
        final int prevPos = ch.content.indexOf(kw);
        if (prevPos < 0) continue;
        final bool prevNeg = _hasNegationBefore(ch.content, prevPos);
        if (prevNeg != addedNeg) {
          result.add(
            '第 ${ch.idx} 章「$kw」(${prevNeg ? '否定' : '肯定'}) 与第 ${added.idx} 章'
            '（${addedNeg ? '否定' : '肯定'}）表述相反',
          );
        }
        break; // 只比对最早出现的一次
      }
    }
    return result;
  }

  // ---------------- 内部工具 ----------------

  /// 统计子串出现次数。
  static int _countOccurrences(String text, String needle) {
    if (needle.isEmpty) return 0;
    int count = 0;
    int idx = 0;
    while (true) {
      final int found = text.indexOf(needle, idx);
      if (found < 0) break;
      count++;
      idx = found + needle.length;
    }
    return count;
  }

  /// 两段文字的 Jaccard 相似度（基于 2 字以上中文词组）。
  static double _jaccard(String a, String b) {
    final Set<String> ta = _chineseBigrams(a);
    final Set<String> tb = _chineseBigrams(b);
    if (ta.isEmpty && tb.isEmpty) return 0.0;
    final int inter = ta.intersection(tb).length;
    final int union = ta.union(tb).length;
    return union == 0 ? 0.0 : inter / union;
  }

  /// 提取中文 2 字以上连续片段集合。
  static Set<String> _chineseBigrams(String text) {
    final Set<String> set = <String>{};
    final StringBuffer buf = StringBuffer();
    for (final int code in text.codeUnits) {
      final bool isCjk = code >= 0x4E00 && code <= 0x9FFF;
      if (isCjk) {
        buf.writeCharCode(code);
      } else if (buf.length >= 2) {
        set.add(buf.toString());
        buf.clear();
      } else {
        buf.clear();
      }
    }
    if (buf.length >= 2) set.add(buf.toString());
    return set;
  }

  /// 判断位置 [pos] 前 6 个字符内是否出现否定词。
  static bool _hasNegationBefore(String text, int pos) {
    final int start = pos - 6 < 0 ? 0 : pos - 6;
    final String prefix = text.substring(start, pos);
    for (final String n in negations) {
      if (prefix.contains(n)) return true;
    }
    return false;
  }
}
