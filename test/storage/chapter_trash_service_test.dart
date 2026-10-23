import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/storage/chapter_trash_service.dart';
import 'package:novel_writer/storage/novel_repository.dart';
import 'package:novel_writer/storage/trash_service.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late NovelRepository repo;
  late ChapterRepository chapterRepo;
  late ChapterTrashService trash;
  late String novelId;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('chapter_trash_');
    db = AppDatabase.initForTest(tempDir.path);
    repo = NovelRepository(db);
    trash = ChapterTrashService(db);
    chapterRepo = ChapterRepository(db, chapterTrash: trash);
    final Novel novel = await repo.createNovel(
      title: '章节回收测试',
      genre: 'xuanhuan',
      tone: '热血',
    );
    novelId = novel.id;
    for (int i = 0; i < 3; i++) {
      final Chapter c = await chapterRepo.addChapter(novelId);
      await chapterRepo.updateChapter(
        novelId,
        c.copyWith(
          title: '第${i + 1}章',
          content: '这是第${i + 1}章的正文。',
          outline: '第${i + 1}章大纲',
        ),
      );
    }
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('删除章节会写入章节回收站并重排剩余章节', () async {
    final List<Chapter> before = await chapterRepo.listChapters(novelId);
    final Chapter middle = before[1];

    await chapterRepo.deleteChapter(novelId, middle.id);

    final List<Chapter> after = await chapterRepo.listChapters(novelId);
    expect(after, hasLength(2));
    expect(after.map((c) => c.title), <String>['第1章', '第3章']);
    expect(after.map((c) => c.order), <int>[0, 1]);

    final List<ChapterTrashEntry> entries = await trash.list(novelId);
    expect(entries, hasLength(1));
    expect(entries.single.chapterId, middle.id);
    expect(entries.single.title, '第2章');
    expect(entries.single.content, contains('第2章的正文'));
    expect(entries.single.outline, '第2章大纲');
    expect(entries.single.order, 1);
  });

  test('恢复章节会放回原位置并还原正文/大纲', () async {
    final Chapter middle = (await chapterRepo.listChapters(novelId))[1];
    await chapterRepo.deleteChapter(novelId, middle.id);
    final ChapterTrashEntry entry = (await trash.list(novelId)).single;

    final Chapter restored = await trash.restore(entry);

    expect(restored.id, middle.id);
    expect(restored.order, 1);
    expect(restored.content, contains('第2章的正文'));
    expect(restored.outline, '第2章大纲');
    final List<Chapter> all = await chapterRepo.listChapters(novelId);
    expect(all.map((c) => c.title), <String>['第1章', '第2章', '第3章']);
    expect(all.map((c) => c.order), <int>[0, 1, 2]);
    expect(await trash.list(novelId), isEmpty);
    final List<NovelSummary> shelf = await repo.listNovels();
    expect(shelf.single.chapterCount, 3);
  });

  test('永久删除与清空章节回收站', () async {
    final List<Chapter> before = await chapterRepo.listChapters(novelId);
    await chapterRepo.deleteChapter(novelId, before[0].id);
    await chapterRepo.deleteChapter(novelId, before[1].id);
    final List<ChapterTrashEntry> entries = await trash.list(novelId);
    expect(entries, hasLength(2));

    await trash.purge(entries.first);
    expect(await trash.list(novelId), hasLength(1));

    await trash.purgeAll(novelId);
    expect(await trash.list(novelId), isEmpty);
  });

  test('超过 30 天的章节记录会自动清理', () async {
    final Chapter first = (await chapterRepo.listChapters(novelId)).first;
    await chapterRepo.deleteChapter(novelId, first.id);
    expect(await trash.list(novelId), hasLength(1));

    await trash.purgeExpired(
      novelId,
      now: DateTime.now().add(
        const Duration(days: ChapterTrashService.retentionDays + 1),
      ),
    );

    expect(await trash.list(novelId), isEmpty);
  });

  test('章节仍在时拒绝重复恢复', () async {
    final Chapter middle = (await chapterRepo.listChapters(novelId))[1];
    await chapterRepo.deleteChapter(novelId, middle.id);
    final ChapterTrashEntry entry = (await trash.list(novelId)).single;
    await trash.restore(entry);

    await expectLater(trash.restore(entry), throwsA(isA<StorageException>()));
  });

  test('永久删除作品时会连带清理它的章节回收站', () async {
    final Chapter first = (await chapterRepo.listChapters(novelId)).first;
    await chapterRepo.deleteChapter(novelId, first.id);
    expect(await trash.list(novelId), hasLength(1));

    await repo.deleteNovel(novelId);
    final TrashService projectTrash = TrashService(db);
    final TrashEntry projectEntry = (await projectTrash.list()).single;
    await projectTrash.purge(projectEntry);

    expect(await trash.list(novelId), isEmpty);
    expect(await Directory(trash.directoryFor(novelId).path).exists(), isFalse);
  });

  test('删除章节的回收站写入失败时删除中止，章节仍在', () async {
    final List<Chapter> before = await chapterRepo.listChapters(novelId);
    final Chapter target = before.first;
    final ChapterRepository failingRepo = ChapterRepository(
      db,
      chapterTrash: _FailingChapterTrash(),
    );
    await expectLater(
      failingRepo.deleteChapter(novelId, target.id),
      throwsA(isA<StorageException>()),
    );
    final List<Chapter> after = await chapterRepo.listChapters(novelId);
    expect(after.map((c) => c.id), contains(target.id));
  });
}

class _FailingChapterTrash implements ChapterTrashService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw const StorageException('磁盘只读');
  }
}
