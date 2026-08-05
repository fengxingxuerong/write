import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/editor/writing_stats_dialog.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/storage/novel_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('computeWritingStats', () {
    test('统计字数/段落/句子/平均句长', () {
      const String text = '第一段。第二句！\n\n第二段？第三段…\n第三行没有标点';
      final WritingStats s = computeWritingStats(text);
      expect(s.wordCount, greaterThan(0));
      expect(s.paragraphCount, 3);
      expect(s.sentenceCount, 4); // 。！？…
      expect(s.avgSentenceLength, greaterThan(0));
    });

    test('sessionAdded 取 initialWords 差值且不为负', () {
      final WritingStats s =
          computeWritingStats('今天写了三十个字的内容。', initialWords: 10);
      expect(s.sessionAdded, greaterThan(0));
      final WritingStats s2 =
          computeWritingStats('删掉了', initialWords: 100);
      expect(s2.sessionAdded, 0); // 负值归 0
    });

    test('空文本统计为 0', () {
      final WritingStats s = computeWritingStats('');
      expect(s.wordCount, 0);
      expect(s.paragraphCount, 0);
      expect(s.sentenceCount, 0);
      expect(s.avgSentenceLength, 0);
    });
  });

  group('ChapterRepository.splitChapter', () {
    late AppDatabase db;
    late ChapterRepository repo;
    late String novelId;

    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('split_test');
      db = AppDatabase.initForTest(tempDir.path);
      repo = ChapterRepository(db);
      final Novel novel = await NovelRepository(db).createNovel(
        title: '测试书',
        genre: 'test',
        tone: 'test',
      );
      novelId = novel.id;
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('按段落拆分为多章并重新索引 order', () async {
      final Chapter c1 = await repo.addChapter(novelId, title: '第一章');
      await repo.updateChapterContent(novelId, c1.id, '第一段内容。\n\n第二段内容。\n\n第三段内容。');

      final List<Chapter> chapters =
          await repo.splitChapter(novelId, c1.id, <String>[
        '第一段内容。',
        '第二段内容。',
        '第三段内容。',
      ]);

      expect(chapters.length, 3);
      expect(chapters[0].id, c1.id);
      expect(chapters[0].content, '第一段内容。');
      expect(chapters[1].content, '第二段内容。');
      expect(chapters[2].content, '第三段内容。');
      // order 重新索引连续。
      expect(chapters.map((c) => c.order).toList(), <int>[0, 1, 2]);
      // 标题：原章节保留，新章节自动编号。
      expect(chapters[1].title, '第2章');
      expect(chapters[2].title, '第3章');
    });

    test('空 parts 不改变任何内容', () async {
      final Chapter c1 = await repo.addChapter(novelId, title: '第一章');
      final List<Chapter> chapters =
          await repo.splitChapter(novelId, c1.id, <String>[]);
      expect(chapters.length, 1);
      expect(chapters[0].id, c1.id);
    });

    test('分割后原章节后追加的章节顺序正确', () async {
      await repo.addChapter(novelId, title: '第一章');
      final Chapter c2 = await repo.addChapter(novelId, title: '第二章');
      final List<Chapter> chapters =
          await repo.splitChapter(novelId, c2.id, <String>['块1', '块2']);
      expect(chapters.length, 3);
      expect(chapters[1].id, c2.id);
      expect(chapters[2].content, '块2');
      expect(chapters.map((c) => c.order).toList(), <int>[0, 1, 2]);
    });
  });
}
