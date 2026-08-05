import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/storage/app_database.dart';

/// 数据可靠性加固测试：
/// 写后自动备份、主文件损坏自动从备份自愈、索引损坏容错返回空列表。
void main() {
  late Directory tmpDir;
  late AppDatabase db;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('novel_rel_');
    db = AppDatabase.initForTest(tmpDir.path);
  });

  tearDown(() {
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  });

  Novel makeNovel(String id, String title) => Novel(
        id: id,
        title: title,
        genre: 'xuanhuan',
        tone: '热血',
        targetWordsPerChapter: 2000,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        chapters: <Chapter>[],
        characters: const <Character>[],
        worldSettings: const <WorldSetting>[],
      );

  test('writeNovel 后生成 .bak 备份（内容与主文件一致）', () async {
    await db.writeNovel(makeNovel('n1', '备份测试'));
    final bak = db.novelBackupFile('n1');
    expect(await bak.exists(), isTrue);
    // 备份内容与主文件一致。
    final bakJson =
        jsonDecode(await bak.readAsString()) as Map<String, dynamic>;
    expect(Novel.fromJson(bakJson).title, equals('备份测试'));
  });

  test('写两次后破坏主文件，从备份恢复为最近一次写入', () async {
    // 第一次写入（主文件=v1，无备份）。
    await db.writeNovel(makeNovel('n2', '自愈v1'));
    // 第二次写入后备份为当前主文件（=v2），主文件再损坏时恢复为 v2。
    await db.writeNovel(makeNovel('n2', '自愈v2'));
    final file = db.novelFile('n2');
    await file.writeAsString('{broken!!!');
    final novel = await db.readNovel('n2');
    // 备份是最近一次成功写入的内容（v2）。
    expect(novel.title, equals('自愈v2'));
  });

  test('主文件损坏且无备份时抛 StorageException', () async {
    final file = db.novelFile('n3');
    await file.writeAsString('{broken');
    expect(
      () => db.readNovel('n3'),
      throwsA(isA<StorageException>()),
    );
  });

  test('索引损坏时从备份自愈', () async {
    // 先写一次正常索引，再写第二次（此时主=最新，备份=前一次）。
    await db.writeIndex(<NovelSummary>[]);
    await db.writeIndex(<NovelSummary>[
      NovelSummary(
        id: 'x1',
        title: '索引测试',
        genre: 'xuanhuan',
        updatedAt: DateTime(2026, 1, 1),
      ),
    ]);
    // 破坏主索引。
    await db.indexFile.writeAsString('[corrupted');
    final list = await db.readIndex();
    // 从备份恢复，读到第二次写入的数据。
    expect(list.length, equals(1));
    expect(list.first.id, equals('x1'));
  });

  test('索引损坏且无备份时返回空列表（不崩溃）', () async {
    await db.indexFile.writeAsString('{broken');
    final list = await db.readIndex();
    expect(list, isEmpty);
  });
}
