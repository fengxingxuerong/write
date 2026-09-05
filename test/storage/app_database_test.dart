import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/storage/app_database.dart';

/// AppDatabase 单元测试
///
/// 覆盖：initForTest、novelFile/novelBackupFile/indexFile 路径生成、
///        withNovelLock 串行化、writeNovel/readNovel 原子写与自愈。

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('app_db_test_');
    db = AppDatabase.initForTest(tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('AppDatabase 路径生成', () {
    test('novelFile 路径格式正确', () {
      final file = db.novelFile('test-id');
      expect(file.path, endsWith('test-id.json'));
    });

    test('novelBackupFile 路径格式正确', () {
      final file = db.novelBackupFile('test-id');
      expect(file.path, endsWith('test-id.bak.json'));
    });

    test('indexFile 路径格式正确', () {
      expect(db.indexFile.path, endsWith('index.json'));
    });

    test('indexBackupFile 路径格式正确', () {
      expect(db.indexBackupFile.path, endsWith('index.bak.json'));
    });

    test('directory.path 为初始化时指定路径', () {
      expect(db.directory.path, tempDir.path);
    });
  });

  group('AppDatabase.initForTest', () {
    test('目录不存在时自动创建', () {
      final newDir = Directory('${tempDir.path}/sub/deep');
      expect(newDir.existsSync(), isFalse);
      AppDatabase.initForTest(newDir.path);
      expect(newDir.existsSync(), isTrue);
    });
  });

  group('withNovelLock 并发控制', () {
    test('同一 novelId 的 action 串行执行', () async {
      final List<int> order = <int>[];

      final Future<void> t1 = db.withNovelLock('novel-1', () async {
        order.add(1);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(order, [1]);
      });

      final Future<void> t2 = db.withNovelLock('novel-1', () async {
        order.add(2);
      });

      await Future.wait([t1, t2]);
      expect(order, [1, 2]);
    });

    test('不同 novelId 的 action 可并发', () async {
      final Stopwatch stopwatch = Stopwatch()..start();

      final Future<void> t1 = db.withNovelLock('novel-a', () async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });

      final Future<void> t2 = db.withNovelLock('novel-b', () async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });

      await Future.wait([t1, t2]);
      stopwatch.stop();

      // 并发执行总时间应该小于串行（160ms）
      expect(stopwatch.elapsedMilliseconds, lessThan(160));
    });

    test('action 抛出异常时锁正确释放', () async {
      await expectLater(
        db.withNovelLock('fail-id', () async {
          throw Exception('故意失败');
        }),
        throwsException,
      );

      // 锁已释放，新 action 应该正常执行
      final result = await db.withNovelLock('fail-id', () async => 'ok');
      expect(result, 'ok');
    });

    test('action 返回值正确传递', () async {
      final result = await db.withNovelLock('test', () async => 42);
      expect(result, 42);
    });
  });

  group('writeNovel / readNovel', () {
    test('写入后能正确读取', () async {
      final novel = _buildSampleNovel('小说1');
      await db.writeNovel(novel);
      final loaded = await db.readNovel(novel.id);
      expect(loaded.title, '小说1');
    });

    test('写入不残留 .tmp 文件', () async {
      final novel = _buildSampleNovel('测试');
      await db.writeNovel(novel);
      final tmpFile = File('${tempDir.path}/${novel.id}.json.tmp');
      expect(tmpFile.existsSync(), isFalse);
    });

    test('写入成功后生成备份文件', () async {
      final novel = _buildSampleNovel('备份测试');
      await db.writeNovel(novel);
      expect(db.novelBackupFile(novel.id).existsSync(), isTrue);
    });

    test('读取不存在的文件抛异常', () async {
      expect(
        () => db.readNovel('不存在'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('readIndex 容错', () {
    test('无索引文件时返回空列表', () async {
      final items = await db.readIndex();
      expect(items, isEmpty);
    });

    test('损坏的索引文件返回空列表', () async {
      await File('${tempDir.path}/index.json').writeAsString('非JSON内容');
      final items = await db.readIndex();
      expect(items, isEmpty);
    });
  });
}

/// 构建样本 Novel 对象。
Novel _buildSampleNovel(String title) {
  return Novel(
    id: 'test-${DateTime.now().microsecondsSinceEpoch}',
    title: title,
    genre: 'xuanhuan',
    tone: 'hot',
    targetWordsPerChapter: 3000,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    chapters: const <Chapter>[],
    characters: const <Character>[],
    worldSettings: const <WorldSetting>[],
  );
}
