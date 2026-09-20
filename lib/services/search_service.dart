import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';

/// 全文搜索结果项。
class SearchHit {
  /// 构造命中项。
  const SearchHit({
    required this.chapter,
    required this.snippet,
    required this.index,
  });

  /// 命中的章节。
  final Chapter chapter;

  /// 命中片段（前后截断）。
  final String snippet;

  /// 命中位置（章节内偏移）。
  final int index;

  /// 片段起点（用于高亮定位）。
  int get snippetStart {
    final int s = index - 20;
    return s < 0 ? 0 : s;
  }
}

/// 全文搜索服务。
///
/// 零依赖本地搜索：在全部章节**正文**中查找关键词（大纲不参与检索），
/// 返回按章节顺序排列的命中项，每章取首个命中并附上下文片段。
class SearchService {
  /// 在整本 [Novel] 中搜索 [query]，返回命中列表。
  List<SearchHit> search(Novel novel, String query) {
    final String q = query.trim();
    if (q.isEmpty) return <SearchHit>[];
    final List<SearchHit> hits = <SearchHit>[];
    final List<Chapter> chapters = List<Chapter>.from(novel.chapters)
      ..sort((a, b) => a.order.compareTo(b.order));
    for (final Chapter c in chapters) {
      final int first = c.content.indexOf(q);
      if (first >= 0) {
        hits.add(SearchHit(
          chapter: c,
          snippet: _snippet(c.content, first, q.length),
          index: first,
        ));
      }
    }
    return hits;
  }

  /// 提取命中上下文片段（前 20 后 40，总长 ≤ 60）。
  String _snippet(String text, int index, int queryLen) {
    final int start = index - 20 < 0 ? 0 : index - 20;
    final int end = index + queryLen + 40;
    final int clampEnd = end > text.length ? text.length : end;
    final String raw = text.substring(start, clampEnd).replaceAll('\n', ' ');
    return start > 0 ? '…$raw' : raw;
  }
}
