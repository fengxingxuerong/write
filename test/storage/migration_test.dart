import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/storage/app_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late Directory newBase; // 模拟 %APPDATA%/InkSmith/墨匠
  late Directory newNovels; // 模拟新 novels 目录

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('migrate_test_');
    newBase = Directory('${tempRoot.path}/InkSmith/墨匠');
    newNovels =
        Directory('${newBase.path}/${AppConstants.novelsDirName}');
    await newNovels.create(recursive: true);
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<void> seedLegacy(String company, {int files = 3}) async {
    final legacy = Directory(
        '${tempRoot.path}/$company/novel_writer/${AppConstants.novelsDirName}');
    await legacy.create(recursive: true);
    for (var i = 0; i < files; i++) {
      await File('${legacy.path}/novel_$i.json').writeAsString('{"id":"$i"}');
    }
    await File('${legacy.path}/index.json')
        .writeAsString('{"index":true}');
  }

  test('旧 com.example 路径数据迁移到新品牌路径', () async {
    await seedLegacy('com.example');

    await AppDatabase.migrateLegacyData(newBase, newNovels);

    final migrated = await newNovels.list().toList();
    expect(migrated.length, 4); // 3 novels + index
    expect(await File('${newNovels.path}/novel_0.json').exists(), isTrue);
    expect(await File('${newNovels.path}/index.json').exists(), isTrue);

    // 旧目录应被删除
    final legacy = Directory(
        '${tempRoot.path}/com.example/novel_writer/${AppConstants.novelsDirName}');
    expect(await legacy.exists(), isFalse);
  });

  test('新路径已有数据时跳过迁移', () async {
    await seedLegacy('com.example');
    await File('${newNovels.path}/existing.json')
        .writeAsString('{"keep":true}');

    await AppDatabase.migrateLegacyData(newBase, newNovels);

    // 新路径保留原数据，不被覆盖
    expect(await File('${newNovels.path}/existing.json').exists(), isTrue);
    expect(await File('${newNovels.path}/novel_0.json').exists(), isFalse);
    // 旧路径仍保留（未迁移）
    expect(
        await Directory(
                '${tempRoot.path}/com.example/novel_writer/${AppConstants.novelsDirName}')
            .exists(),
        isTrue);
  });

  test('旧路径不存在时无操作', () async {
    await AppDatabase.migrateLegacyData(newBase, newNovels);
    expect(await newNovels.list().toList(), isEmpty);
  });

  test('无公司名旧路径（%APPDATA%/novel_writer）也迁移', () async {
    await seedLegacy(''); // 生成 tempRoot/novel_writer/novels
    await AppDatabase.migrateLegacyData(newBase, newNovels);
    expect(await File('${newNovels.path}/novel_0.json').exists(), isTrue);
    expect(
        await Directory('${tempRoot.path}/novel_writer/${AppConstants.novelsDirName}')
            .exists(),
        isFalse);
  });

  test('迁移后旧目录被删除，新目录文件完好', () async {
    await seedLegacy('com.example');
    await AppDatabase.migrateLegacyData(newBase, newNovels);

    final files = await newNovels
        .list()
        .map((e) => e.uri.pathSegments.last)
        .toList();
    expect(files, contains('novel_0.json'));
    expect(files, contains('novel_2.json'));
    expect(files, contains('index.json'));
    expect(files, hasLength(4));
    // 文件内容完好
    expect(await File('${newNovels.path}/novel_1.json').readAsString(),
        '{"id":"1"}');
  });

  test('旧目录含子目录时按结构递归迁入（不拍平、不互相覆盖）', () async {
    final legacy = Directory(
        '${tempRoot.path}/com.example/novel_writer/${AppConstants.novelsDirName}');
    await legacy.create(recursive: true);
    await File('${legacy.path}/novel_0.json').writeAsString('{"id":"0"}');
    final sub = Directory('${legacy.path}/extras');
    await sub.create(recursive: true);
    await File('${sub.path}/note.json').writeAsString('{"note":true}');
    // 嵌套子目录 + 与外层同名的文件：拍平拷贝会在这里互相覆盖。
    final nested = Directory('${sub.path}/deep');
    await nested.create(recursive: true);
    await File('${nested.path}/note.json').writeAsString('{"deep":true}');

    await AppDatabase.migrateLegacyData(newBase, newNovels);

    expect(await File('${newNovels.path}/novel_0.json').exists(), isTrue);
    expect(await File('${newNovels.path}/extras/note.json').exists(), isTrue,
        reason: '子目录必须按原结构迁入');
    expect(await File('${newNovels.path}/extras/deep/note.json').exists(), isTrue,
        reason: '嵌套子目录必须递归迁入');
    expect(
      await File('${newNovels.path}/extras/note.json').readAsString(),
      '{"note":true}',
      reason: '同名文件不得被嵌套副本覆盖',
    );
    expect(
      await File('${newNovels.path}/extras/deep/note.json').readAsString(),
      '{"deep":true}',
    );
    expect(await File('${newNovels.path}/note.json').exists(), isFalse,
        reason: '不得拍平到目标根目录');
    expect(await legacy.exists(), isFalse, reason: '迁完仍应清理旧目录');
  });
}
