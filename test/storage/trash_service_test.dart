import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/storage/novel_repository.dart';
import 'package:novel_writer/storage/trash_service.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late NovelRepository repo;
  late ChapterRepository chapterRepo;
  late TrashService trash;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('trash_service_');
    db = AppDatabase.initForTest(tempDir.path);
    repo = NovelRepository(db);
    chapterRepo = ChapterRepository(db);
    trash = TrashService(db);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Novel> seed({String title = '待删之书'}) async {
    final Novel novel = await repo.createNovel(
      title: title,
      genre: 'xuanhuan',
      tone: '热血',
    );
    final chapter = await chapterRepo.addChapter(novel.id, title: '第一章');
    await chapterRepo.updateChapterContent(
      novel.id,
      chapter.id,
      '这是会被一起带进回收站的正文。',
    );
    return novel;
  }

  test('删除作品后主文件与备份移入回收站，列表保留元信息', () async {
    final Novel novel = await seed();
    await repo.deleteNovel(novel.id);

    expect(await db.novelFile(novel.id).exists(), isFalse);
    expect(await db.novelBackupFile(novel.id).exists(), isFalse);
    final List<TrashEntry> entries = await trash.list();
    expect(entries, hasLength(1));
    expect(entries.single.id, novel.id);
    expect(entries.single.title, '待删之书');
    expect(entries.single.chapterCount, 1);
    expect(entries.single.wordCount, greaterThan(0));
    expect(await repo.listNovels(), isEmpty);
  });

  test('恢复作品会还原正文并重建书架索引', () async {
    final Novel novel = await seed();
    await repo.deleteNovel(novel.id);
    final TrashEntry entry = (await trash.list()).single;

    final Novel restored = await trash.restore(entry);

    expect(restored.id, novel.id);
    final Novel reread = await repo.getNovel(novel.id);
    expect(reread.chapters.single.content, contains('一起带进回收站'));
    final List<NovelSummary> shelf = await repo.listNovels();
    expect(shelf.map((NovelSummary n) => n.id), contains(novel.id));
    expect(await trash.list(), isEmpty);
  });

  test('永久删除回收站条目会移除所有文件', () async {
    final Novel novel = await seed();
    await repo.deleteNovel(novel.id);
    final TrashEntry entry = (await trash.list()).single;

    await trash.purge(entry);

    expect(await trash.list(), isEmpty);
    expect(await Directory(entry.folderPath).exists(), isFalse);
    expect(await db.novelFile(novel.id).exists(), isFalse);
  });

  test('清空回收站会删除全部条目', () async {
    final Novel a = await seed(title: '甲');
    final Novel b = await seed(title: '乙');
    await repo.deleteNovel(a.id);
    await repo.deleteNovel(b.id);
    expect(await trash.list(), hasLength(2));

    await trash.purgeAll();

    expect(await trash.list(), isEmpty);
  });

  test('超过 30 天的条目在列表时自动清理', () async {
    final Novel novel = await seed();
    await repo.deleteNovel(novel.id);
    expect(await trash.list(), hasLength(1));

    await trash.purgeExpired(
      now: DateTime.now().add(
        const Duration(days: TrashService.retentionDays + 1),
      ),
    );

    expect(await trash.list(), isEmpty);
    expect(await db.novelFile(novel.id).exists(), isFalse);
  });

  test('主文件丢失但备份还在时仍能恢复正文', () async {
    final Novel novel = await seed();
    await repo.deleteNovel(novel.id);
    final TrashEntry entry = (await trash.list()).single;
    final File main = File(
      '${entry.folderPath}${Platform.pathSeparator}${novel.id}.json',
    );
    await main.delete();

    final List<TrashEntry> entries = await trash.list();
    expect(entries, hasLength(1), reason: '只剩 .bak 时也不能把它从列表里藏掉');
    final Novel restored = await trash.restore(entries.single);
    expect(restored.id, novel.id);
    expect((await repo.getNovel(novel.id)).chapters, hasLength(1));
  });

  test('meta 损坏时仍能按目录名列出并恢复', () async {
    final Novel novel = await seed();
    await repo.deleteNovel(novel.id);
    final TrashEntry entry = (await trash.list()).single;
    final File meta = File(
      '${entry.folderPath}${Platform.pathSeparator}meta.json',
    );
    await meta.delete();

    final List<TrashEntry> entries = await trash.list();
    expect(entries, hasLength(1));
    expect(entries.single.id, novel.id);
    expect(entries.single.title, '未知作品');

    final Novel restored = await trash.restore(entries.single);
    expect(restored.id, novel.id);
    expect(await repo.listNovels(), hasLength(1));
  });

  test('恢复后再次删除仍会生成新的回收站记录', () async {
    final Novel novel = await seed();
    await repo.deleteNovel(novel.id);
    await trash.restore((await trash.list()).single);
    await repo.deleteNovel(novel.id);

    final List<TrashEntry> entries = await trash.list();
    expect(entries, hasLength(1));
    expect(entries.single.title, '待删之书');
    final Novel restoredAgain = await trash.restore(entries.single);
    expect(restoredAgain.id, novel.id);
  });
}
