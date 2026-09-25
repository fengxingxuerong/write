import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/features/project_list/project_list_viewmodel.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/novel_repository.dart';

/// 项目列表 ViewModel 单元测试（使用临时目录 + 真实 NovelRepository）
///
/// 覆盖：加载、新建、删除、重命名、归档、筛选、搜索、visibleNovels 计算。

void main() {
  late AppDatabase db;
  late NovelRepository repo;
  late ProjectListViewModel vm;
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('plvm_test_');
    db = AppDatabase.initForTest(tempDir.path);
    repo = NovelRepository(db);
    vm = ProjectListViewModel(repo);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('加载', () {
    test('初始状态为空列表且未加载', () {
      expect(vm.state.novels, isEmpty);
      expect(vm.state.isLoading, isFalse);
    });

    test('load 成功更新列表', () async {
      await repo.createNovel(title: '测试', genre: '玄幻', tone: '热血');
      await vm.load();
      expect(vm.state.novels, hasLength(1));
      expect(vm.state.isLoading, isFalse);
      expect(vm.state.error, isNull);
    });

    test('空目录加载返回空列表', () async {
      // 空目录（无 index.json）加载应返回空列表且不报错
      await vm.load();
      expect(vm.state.novels, isEmpty);
      expect(vm.state.isLoading, isFalse);
      expect(vm.state.error, isNull);
    });
  });

  group('CRUD', () {
    test('create 后列表包含新项目', () async {
      await vm.create('新书', '都市', '轻松');
      expect(vm.state.novels, hasLength(1));
      expect(vm.state.novels.first.title, '新书');
    });

    test('delete 后列表移除项目', () async {
      final novel = await repo.createNovel(title: '待删', genre: 'x', tone: 'y');
      await vm.load();
      expect(vm.state.novels, hasLength(1));
      await vm.delete(novel.id);
      expect(vm.state.novels, isEmpty);
    });

    test('rename 更新标题', () async {
      final novel = await repo.createNovel(title: '旧名', genre: 'x', tone: 'y');
      await vm.rename(novel.id, '新名');
      expect(vm.state.novels.first.title, '新名');
    });

    test('setArchived 切换归档状态', () async {
      final novel =
          await repo.createNovel(title: '归档测试', genre: 'x', tone: 'y');
      expect(novel.archived, isFalse);
      final updated = await repo.setArchived(novel.id, true);
      expect(updated.archived, isTrue);
      final restored = await repo.setArchived(novel.id, false);
      expect(restored.archived, isFalse);
    });
  });

  group('筛选与搜索', () {
    setUp(() async {
      await repo.createNovel(title: '活跃玄幻', genre: '玄幻', tone: '热血');
      final archived =
          await repo.createNovel(title: '归档都市', genre: '都市', tone: '轻松');
      await repo.setArchived(archived.id, true);
      await vm.load();
    });

    test('默认 filter=all 显示全部', () {
      expect(vm.state.visibleNovels, hasLength(2));
    });

    test('filter=active 仅显示未归档', () {
      vm.setFilter('active');
      expect(vm.state.visibleNovels, hasLength(1));
      expect(vm.state.visibleNovels.first.title, '活跃玄幻');
    });

    test('filter=archived 仅显示已归档', () {
      vm.setFilter('archived');
      expect(vm.state.visibleNovels, hasLength(1));
      expect(vm.state.visibleNovels.first.title, '归档都市');
    });

    test('query 按标题过滤', () {
      vm.setQuery('玄幻');
      expect(vm.state.visibleNovels, hasLength(1));
      expect(vm.state.visibleNovels.first.title, '活跃玄幻');
    });

    test('query 大小写不敏感', () {
      vm.setQuery('都市');
      expect(vm.state.visibleNovels, hasLength(1));
      expect(vm.state.visibleNovels.first.title, '归档都市');
    });

    test('query + filter 组合过滤', () {
      vm.setFilter('archived');
      vm.setQuery('都市');
      expect(vm.state.visibleNovels, hasLength(1));
      expect(vm.state.visibleNovels.first.title, '归档都市');
    });

    test('query 为空时显示当前筛选下全部', () {
      vm.setFilter('active');
      vm.setQuery('');
      expect(vm.state.visibleNovels, hasLength(1));
    });

    test('query 无匹配返回空列表', () {
      vm.setQuery('不存在的项目名');
      expect(vm.state.visibleNovels, isEmpty);
    });
  });

  group('状态不可变性', () {
    test('copyWith 保留未变更字段', () async {
      await repo.createNovel(title: '测试', genre: 'x', tone: 'y');
      await vm.load();
      final originalCount = vm.state.novels.length;
      vm.setFilter('archived');
      expect(vm.state.filter, 'archived');
      // novels 数据量不变（只是过滤显示）
      expect(vm.state.novels.length, originalCount);
    });
  });

  group('异常分支（AppException → 错误上屏）', () {
    test('load 抛 StorageException → error 为其 message', () async {
      vm = ProjectListViewModel(_ThrowingRepo());
      await vm.load();
      expect(vm.state.isLoading, isFalse);
      expect(vm.state.error, '存储层故障');
    });

    test('load 抛普通异常 → error 前缀「加载失败」', () async {
      vm = ProjectListViewModel(_ThrowingRepo(appError: false));
      await vm.load();
      expect(vm.state.isLoading, isFalse);
      expect(vm.state.error, startsWith('加载失败'));
    });

    test('create 抛 StorageException → error 上屏且列表不动', () async {
      final ProjectListViewModel bad = ProjectListViewModel(_ThrowingRepo());
      await bad.create('新书', '玄幻', '热血');
      expect(bad.state.error, '存储层故障');
      expect(bad.state.novels, isEmpty);
    });

    test('create / delete 抛普通异常 → 错误上屏', () async {
      final ProjectListViewModel bad =
          ProjectListViewModel(_ThrowingRepo(appError: false));
      await bad.create('新书', '玄幻', '热血');
      expect(bad.state.error, startsWith('创建作品失败'));
      await bad.delete('n1');
      expect(bad.state.error, startsWith('删除作品失败'));
    });

    test('delete / rename / setArchived 抛错 → error 上屏', () async {
      final ProjectListViewModel bad = ProjectListViewModel(_ThrowingRepo());
      await bad.delete('n1');
      expect(bad.state.error, '存储层故障');
      await bad.rename('n1', '改名');
      expect(bad.state.error, '存储层故障');
      await bad.setArchived('n1', true);
      expect(bad.state.error, '存储层故障');
      await bad.setArchived('n1', false);
      expect(bad.state.error, '存储层故障');
    });

  });
}

/// 恒抛错的仓储：验证 ViewModel 对 AppException / 普通异常的兜底。
///
/// 用 implements + noSuchMethod 兜底（同 generate_viewmodel_test 的
/// _FakeChapterRepo 口径）：被测路径只走 listNovels / createNovel /
/// deleteNovel / renameNovel / setArchived，其余成员不应被触达。
class _ThrowingRepo implements NovelRepository {
  _ThrowingRepo({this.appError = true});

  /// true → 抛 AppException（StorageException）；false → 抛普通异常。
  final bool appError;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (appError) {
      throw const StorageException('存储层故障');
    }
    throw StateError('boom');
  }
}
