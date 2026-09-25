import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/chapter_draft.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/novel_backup_service.dart';
import 'package:novel_writer/storage/novel_repository.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late NovelRepository repository;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('novel_backup_test_');
    db = AppDatabase.initForTest(tempDir.path);
    repository = NovelRepository(db);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('导入会复制内容、重写所有关联 ID，且不覆盖原项目', () async {
    final original = Novel(
      id: 'original-id',
      title: '备份作品',
      genre: 'xuanhuan',
      tone: '热血',
      targetWordsPerChapter: 2000,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
      chapters: <Chapter>[
        Chapter(
          id: 'chapter-1',
          novelId: 'original-id',
          title: '第一章',
          order: 0,
          content: '正文',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      ],
      characters: const <Character>[
        Character(
          id: 'character-1',
          novelId: 'original-id',
          name: '林舟',
          role: '主角',
          traits: '谨慎',
          background: '',
          relationships: '',
        ),
      ],
      worldSettings: const <WorldSetting>[
        WorldSetting(
          id: 'world-1',
          novelId: 'original-id',
          title: '城市',
          category: '地理',
          content: '旧城',
        ),
      ],
      drafts: <ChapterDraft>[
        ChapterDraft(
          id: 'draft-1',
          novelId: 'original-id',
          title: '备用稿',
          content: '草稿',
          createdAt: DateTime(2026, 1, 1),
        ),
      ],
    );
    await repository.saveNovel(original);
    final backup = File('${tempDir.path}/backup.json');
    await backup.writeAsString('﻿${jsonEncode(original.toJson())}');

    final imported = await NovelBackupService(repository).importFile(backup);

    expect(imported.id, isNot('original-id'));
    expect(imported.title, '备份作品');
    expect(imported.chapters.single.novelId, imported.id);
    expect(imported.characters.single.novelId, imported.id);
    expect(imported.worldSettings.single.novelId, imported.id);
    expect(imported.drafts.single.novelId, imported.id);
    expect(imported.chapters.single.id, isNot('chapter-1'));
    expect(imported.characters.single.id, isNot('character-1'));
    expect(imported.worldSettings.single.id, isNot('world-1'));
    expect(imported.drafts.single.id, isNot('draft-1'));
    expect(await repository.getNovel('original-id'), isNotNull);
    expect(await repository.getNovel(imported.id), isNotNull);
  });

  test('拒绝无效 JSON 且不创建项目', () async {
    final backup = File('${tempDir.path}/bad.json');
    await backup.writeAsString('not json');

    await expectLater(
      NovelBackupService(repository).importFile(backup),
      throwsA(isA<Exception>()),
    );
    expect(await repository.listNovels(), isEmpty);
  });
}
