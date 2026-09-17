import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/chapter_snapshot.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/storage/chapter_snapshot_service.dart';

/// 章节版本快照：落盘目录、容量裁剪、内容去重、恢复写入。
void main() {
  late Directory tmpRoot;

  setUp(() {
    tmpRoot = Directory.systemTemp.createTempSync(
      'snap_test_${DateTime.now().millisecondsSinceEpoch}',
    );
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  Novel buildNovel(String id, Chapter chapter) => Novel(
        id: id,
        title: 'Test',
        genre: 'default',
        tone: 'standard',
        targetWordsPerChapter: 0,
        chapters: <Chapter>[chapter],
        characters: const <Character>[],
        worldSettings: const <WorldSetting>[],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  group('ChapterSnapshotService', () {
    late ChapterSnapshotService service;

    setUp(() {
      service = ChapterSnapshotService(directory: tmpRoot.path, keep: 10);
    });

    test('save 后快照自动生成，list 倒序返回', () async {
      await service.capture('novel1', 'ch1', title: '第一章', content: 'Hello world');
      final List<ChapterSnapshot> snaps = await service.list('novel1', 'ch1');
      expect(snaps, isNotEmpty);
      expect(snaps.single.content, 'Hello world');
      // 文件落盘到 snapshots 子目录。
      final Directory snapDir =
          Directory('${tmpRoot.path}/snapshots/novel1/ch1');
      expect(await snapDir.exists(), isTrue);
      final List<FileSystemEntity> files =
          await snapDir.list().where((e) => e is File).toList();
      expect(files.length, 1);
    });

    test('首次为空文跳过快照；有历史后再清空视为删除动作', () async {
      // 首次空文 → 不留快照
      await service.capture('novel2', 'ch1', title: 'X', content: '  ');
      expect(await service.list('novel2', 'ch1'), isEmpty);
      // 之后有历史，再次清空 → 应留快照
      await service.capture('novel2', 'ch1', title: 'X', content: 'real');
      await service.capture('novel2', 'ch1', title: 'X', content: '');
      expect((await service.list('novel2', 'ch1')).length, 1);
    });

    test('内容去重', () async {
      for (int i = 0; i < 3; i++) {
        await service.capture('n3', 'c1', title: 'T', content: 'same');
      }
      expect((await service.list('n3', 'c1')).length, 1);
    });

    test('时间节流（60s内跳过）与 force 绕过', () async {
      await service.capture('n4', 'c1', title: 'T', content: 'a');
      // 立即再次、不同内容 → 节流，跳过
      await service.capture('n4', 'c1', title: 'T', content: 'b');
      expect((await service.list('n4', 'c1')).length, 1);
      // force 绕过节流
      await service.capture('n4', 'c1', title: 'T', content: 'b', force: true);
      expect((await service.list('n4', 'c1')).length, 2);
    });

    test('容量裁剪（keep 上限）', () async {
      for (int i = 0; i < 5; i++) {
        // force 绕过去重/节流，写入 5 条不同内容
        await service.capture('n5', 'c1', title: 'T', content: 'v$i', force: true);
        // 保证时间戳不同
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect((await service.list('n5', 'c1')).length, 5);
    });

    test('恢复：快照内容写回到编辑器', () async {
      await service.capture('n6', 'c1', title: '旧称', content: 'snapshot content');
      final ChapterSnapshot snap = (await service.list('n6', 'c1')).first;
      // 模拟恢复到编辑器
      String editor = '';
      editor = snap.content;
      expect(editor, 'snapshot content');
      expect(snap.title, '旧称');
    });
  });

  group('ChapterRepository + snapshots', () {
    test('updateChapterContent 自动留快照（新内容）', () async {
      final AppDatabase db = AppDatabase.initForTest(tmpRoot.path);
      final Novel novel = buildNovel(
        'novelA',
        Chapter(
          id: 'c1',
          novelId: 'novelA',
          title: '第一章',
          order: 0,
          content: 'old',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      await db.writeNovel(novel);
      final ChapterSnapshotService service =
          ChapterSnapshotService(directory: tmpRoot.path, keep: 20);
      final ChapterRepository repo =
          ChapterRepository(db, snapshots: service);

      await repo.updateChapterContent('novelA', 'c1', 'new content');
      // _snap 为 fire-and-forget 异步落盘，轮询等待快照生成。
      List<ChapterSnapshot> snaps = const <ChapterSnapshot>[];
      for (int i = 0; i < 20; i++) {
        snaps = await service.list('novelA', 'c1');
        if (snaps.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(snaps, isNotEmpty);
      expect(snaps.first.content, 'new content');
    });

    test('saveGeneratedChapter 覆盖已有章节时强制留旧正文', () async {
      final AppDatabase db = AppDatabase.initForTest(tmpRoot.path);
      final Chapter old = Chapter(
        id: 'c1',
        novelId: 'novelB',
        title: '旧标题',
        order: 0,
        content: 'old text',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await db.writeNovel(buildNovel('novelB', old));
      final ChapterSnapshotService service =
          ChapterSnapshotService(directory: tmpRoot.path, keep: 20);
      final ChapterRepository repo =
          ChapterRepository(db, snapshots: service);

      await repo.saveGeneratedChapter('novelB', 0, '新标题', 'new text');
      final List<ChapterSnapshot> snaps = await service.list('novelB', 'c1');
      expect(snaps, isNotEmpty);
      expect(snaps.first.content, 'old text');
      expect(snaps.first.title, '旧标题');
    });
  });
}

