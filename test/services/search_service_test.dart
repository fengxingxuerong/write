import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/services/search_service.dart';

/// 全文搜索服务单元测试。
///
/// 覆盖：空查询短路、无命中、按章节 order 升序、每章仅取首个命中、
/// 片段截断与换行归一、命中偏移正确、仅检索正文（大纲不参与）。
void main() {
  final SearchService service = SearchService();

  Chapter chapter({
    required String id,
    required int order,
    String title = '未命名',
    String content = '',
    String outline = '',
  }) =>
      Chapter(
        id: id,
        novelId: 'n1',
        title: title,
        order: order,
        content: content,
        outline: outline,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  Novel novelWith(List<Chapter> chapters) => Novel(
        id: 'n1',
        title: '测试书',
        genre: 'kehuan',
        tone: '冷峻',
        targetWordsPerChapter: 2000,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        chapters: chapters,
        characters: const <Character>[],
        worldSettings: const <WorldSetting>[],
      );

  group('SearchService.search', () {
    test('空查询与纯空白查询短路为空结果', () {
      final Novel novel =
          novelWith(<Chapter>[chapter(id: 'c1', order: 0, content: '星舰启航')]);
      expect(service.search(novel, ''), isEmpty);
      expect(service.search(novel, '   '), isEmpty);
    });

    test('无命中时返回空结果', () {
      final Novel novel = novelWith(
          <Chapter>[chapter(id: 'c1', order: 0, content: '星舰启航，目标半人马座')]);
      expect(service.search(novel, '魔法'), isEmpty);
    });

    test('结果按章节 order 升序，与传入顺序无关', () {
      final Novel novel = novelWith(<Chapter>[
        chapter(id: 'c3', order: 2, title: '第三章', content: '火光冲天'),
        chapter(id: 'c1', order: 0, title: '第一章', content: '火种被唤醒'),
        chapter(id: 'c2', order: 1, title: '第二章', content: '火势蔓延'),
      ]);

      final List<SearchHit> hits = service.search(novel, '火');

      expect(hits.map((SearchHit h) => h.chapter!.order).toList(), <int>[0, 1, 2]);
      expect(hits.first.chapter!.title, '第一章');
    });

    test('同一章多次出现只取首个命中，且偏移为首次出现位置', () {
      final Novel novel = novelWith(<Chapter>[
        chapter(id: 'c1', order: 0, content: '钥匙在桌上，另一把钥匙在抽屉里。'),
      ]);

      final List<SearchHit> hits = service.search(novel, '钥匙');

      expect(hits, hasLength(1));
      expect(hits.single.index, 0);
      expect(hits.single.snippet, contains('钥匙'));
    });

    test('片段：换行归一为空格，命中位置靠后时加省略号且长度受控', () {
      final String content =
          '${'前' * 30}关键词${'后' * 45}';
      final Novel novel = novelWith(
          <Chapter>[chapter(id: 'c1', order: 0, content: content)]);

      final SearchHit hit = service.search(novel, '关键词').single;

      expect(hit.index, 30);
      expect(hit.snippet, startsWith('…'));
      expect(hit.snippet, contains('关键词'));
      // start = 30-20 = 10；end = 30+3+40 = 73 → 片段长 = 1 + 63。
      expect(hit.snippet.length, 64);
      expect(hit.snippet, isNot(contains('\n')));
    });

    test('片段：命中靠前时不加省略号', () {
      final Novel novel = novelWith(
          <Chapter>[chapter(id: 'c1', order: 0, content: '火势渐起，后面又提到火。')]);

      final SearchHit hit = service.search(novel, '火').single;

      expect(hit.index, 0);
      expect(hit.snippet, isNot(startsWith('…')));
    });

    test('片段：正文中的换行被归一为空格', () {
      final Novel novel = novelWith(<Chapter>[
        chapter(id: 'c1', order: 0, content: '第一行\n第二行有线索\n第三行'),
      ]);

      final SearchHit hit = service.search(novel, '线索').single;

      expect(hit.snippet, contains('第二行有线索'));
      expect(hit.snippet, isNot(contains('\n')));
    });

    test('章节大纲参与检索并返回大纲来源', () {
      final Novel novel = novelWith(<Chapter>[
        chapter(
          id: 'c1',
          order: 0,
          content: '正文里没有那个词。',
          outline: '本章大纲：主角获得神器。',
        ),
      ]);

      final List<SearchHit> hits = service.search(novel, '神器');
      expect(hits, hasLength(1));
      expect(hits.single.scope, SearchScope.chapterOutline);
      expect(hits.single.chapter?.id, 'c1');
    });

    test('章节标题参与检索并返回标题来源', () {
      final Novel novel = novelWith(<Chapter>[
        chapter(id: 'c1', order: 0, title: '神器现世', content: '正文无关内容。'),
      ]);

      final List<SearchHit> hits = service.search(novel, '神器');
      expect(hits, hasLength(1));
      expect(hits.single.scope, SearchScope.chapterTitle);
      expect(hits.single.chapter?.id, 'c1');
    });

    test('角色与世界观参与检索', () {
      final Novel novel = Novel(
        id: 'n1',
        title: '测试书',
        genre: 'kehuan',
        tone: '冷峻',
        targetWordsPerChapter: 2000,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        chapters: const <Chapter>[],
        characters: const <Character>[
          Character(
            id: 'char-1',
            novelId: 'n1',
            name: '林舟',
            role: '主角',
            traits: '冷静',
            background: '来自玄天大陆',
            relationships: '与沈星同行',
          ),
        ],
        worldSettings: const <WorldSetting>[
          WorldSetting(
            id: 'world-1',
            novelId: 'n1',
            title: '玄天大陆',
            category: '地理',
            content: '大陆中央有一座星门。',
          ),
        ],
      );

      final List<SearchHit> characterHits = service.search(novel, '沈星');
      expect(characterHits.single.scope, SearchScope.character);
      expect(characterHits.single.sourceId, 'char-1');
      expect(characterHits.single.chapter, isNull);

      final List<SearchHit> worldHits = service.search(novel, '星门');
      expect(worldHits.single.scope, SearchScope.worldSetting);
      expect(worldHits.single.sourceId, 'world-1');
      expect(worldHits.single.chapter, isNull);
    });
  });
}
