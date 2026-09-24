import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';

/// 搜索命中来源。
enum SearchScope {
  /// 章节正文。
  chapterBody,

  /// 章节标题。
  chapterTitle,

  /// 章节大纲。
  chapterOutline,

  /// 角色档案。
  character,

  /// 世界观设定。
  worldSetting,
}

/// 全文搜索结果项。
class SearchHit {
  /// 构造命中项。
  const SearchHit({
    required this.sourceId,
    required this.sourceTitle,
    required this.scope,
    required this.snippet,
    required this.index,
    this.chapter,
  });

  /// 命中来源的稳定 id。
  final String sourceId;

  /// 命中来源的展示标题。
  final String sourceTitle;

  /// 命中来源类型。
  final SearchScope scope;

  /// 命中的章节；角色/世界观命中时为空。
  final Chapter? chapter;

  /// 命中片段（前后截断）。
  final String snippet;

  /// 命中位置（来源文本内偏移）。
  final int index;

  /// 搜索结果在弹窗中的位置标签。
  String get scopeLabel => switch (scope) {
        SearchScope.chapterBody => '正文',
        SearchScope.chapterTitle => '章节标题',
        SearchScope.chapterOutline => '章节大纲',
        SearchScope.character => '角色',
        SearchScope.worldSetting => '世界观',
      };

  /// 片段起点（用于高亮定位）。
  int get snippetStart {
    final int s = index - 20;
    return s < 0 ? 0 : s;
  }
}

/// 全文搜索服务。
///
/// 搜索正文、章节标题、章节大纲、角色档案和世界观设定，保持零依赖本地实现。
class SearchService {
  /// 在整本 [Novel] 中搜索 [query]，返回命中列表。
  List<SearchHit> search(Novel novel, String query) {
    final String q = query.trim();
    if (q.isEmpty) return <SearchHit>[];
    final List<SearchHit> hits = <SearchHit>[];

    final List<Chapter> chapters = List<Chapter>.from(novel.chapters)
      ..sort((a, b) => a.order.compareTo(b.order));
    for (final Chapter chapter in chapters) {
      _addTextHit(
        hits,
        text: chapter.content,
        query: q,
        sourceId: chapter.id,
        sourceTitle: chapter.title,
        scope: SearchScope.chapterBody,
        chapter: chapter,
      );
      _addTextHit(
        hits,
        text: chapter.title,
        query: q,
        sourceId: chapter.id,
        sourceTitle: chapter.title,
        scope: SearchScope.chapterTitle,
        chapter: chapter,
      );
      _addTextHit(
        hits,
        text: chapter.outline,
        query: q,
        sourceId: chapter.id,
        sourceTitle: chapter.title,
        scope: SearchScope.chapterOutline,
        chapter: chapter,
      );
    }

    for (final character in novel.characters) {
      _addCharacterHit(hits, character, q);
    }
    for (final setting in novel.worldSettings) {
      _addWorldSettingHit(hits, setting, q);
    }
    return hits;
  }

  void _addCharacterHit(
    List<SearchHit> hits,
    Character character,
    String query,
  ) {
    final List<({String label, String text})> fields = <({String label, String text})>[
      (label: '姓名', text: character.name),
      (label: '定位', text: character.role),
      (label: '性格', text: character.traits),
      (label: '背景', text: character.background),
      (label: '关系', text: character.relationships),
      (label: '说话风格', text: character.dialogueStyle),
    ];
    for (final field in fields) {
      final int index = field.text.indexOf(query);
      if (index < 0) continue;
      hits.add(SearchHit(
        sourceId: character.id,
        sourceTitle: '${character.name} · ${field.label}',
        scope: SearchScope.character,
        snippet: _snippet(field.text, index, query.length),
        index: index,
      ));
    }
  }

  void _addWorldSettingHit(
    List<SearchHit> hits,
    WorldSetting setting,
    String query,
  ) {
    final List<({String label, String text})> fields = <({String label, String text})>[
      (label: '标题', text: setting.title),
      (label: '分类', text: setting.category),
      (label: '内容', text: setting.content),
    ];
    for (final field in fields) {
      final int index = field.text.indexOf(query);
      if (index < 0) continue;
      hits.add(SearchHit(
        sourceId: setting.id,
        sourceTitle: '${setting.title} · ${field.label}',
        scope: SearchScope.worldSetting,
        snippet: _snippet(field.text, index, query.length),
        index: index,
      ));
    }
  }

  void _addTextHit(
    List<SearchHit> hits, {
    required String text,
    required String query,
    required String sourceId,
    required String sourceTitle,
    required SearchScope scope,
    Chapter? chapter,
  }) {
    final int index = text.indexOf(query);
    if (index < 0) return;
    hits.add(SearchHit(
      sourceId: sourceId,
      sourceTitle: sourceTitle,
      scope: scope,
      chapter: chapter,
      snippet: _snippet(text, index, query.length),
      index: index,
    ));
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
