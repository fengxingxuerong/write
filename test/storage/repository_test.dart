import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/storage/novel_repository.dart';
import 'package:novel_writer/storage/setting_repository.dart';

/// 存储层（AppDatabase + 三层 Repository）单元测试
///
/// 通过模拟 path_provider 的 MethodChannel 将其指向本地临时目录，从而在无真机/
/// 无网络环境下真实进行 JSON 文件的读写与原子重命名验证。
/// 覆盖：单 json 文件结构、index 索引、CRUD、排序/重排、原子写不残留 .tmp、
/// 缺文件抛 StorageException，以及「无任何网络调用」（纯本地文件）。

late Directory _testDir;
late AppDatabase db;
late NovelRepository novelRepo;
late ChapterRepository chapterRepo;
late SettingRepository settingRepo;

Future<void> _clean() async {
  final dir = db.directory;
  if (await dir.exists()) {
    await for (final entity in dir.list()) {
      if (entity is File) {
        await entity.delete();
      }
    }
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    _testDir = await Directory.systemTemp.createTemp('novel_writer_qa_');
    // 模拟 path_provider：返回本地临时目录（纯本地文件，无网络）。
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return _testDir.path;
      }
      return null;
    });
    db = await AppDatabase.init();
    novelRepo = NovelRepository(db);
    chapterRepo = ChapterRepository(db);
    settingRepo = SettingRepository(db);
  });

  setUp(() async {
    await _clean();
  });

  tearDownAll(() async {
    try {
      if (await db.directory.exists()) {
        await db.directory.delete(recursive: true);
      }
    } catch (_) {}
    try {
      await _testDir.delete();
    } catch (_) {}
  });

  group('AppDatabase 文件结构', () {
    test('writeNovel 落盘为单 json 且可被 readNovel 还原', () async {
      final novel = Novel(
        id: 'n-db',
        title: 'DB测试',
        genre: 'xuanhuan',
        tone: '热血',
        targetWordsPerChapter: 2000,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        chapters: const [],
        characters: const [],
        worldSettings: const [],
      );
      await db.writeNovel(novel);
      expect(await db.exists('n-db'), isTrue);
      final file = db.novelFile('n-db');
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json['id'], equals('n-db'));
      expect(json['title'], equals('DB测试'));
      expect(json['chapters'], isEmpty);
      final read = await db.readNovel('n-db');
      expect(read.title, equals('DB测试'));
    });

    test('原子写后不残留 .tmp 临时文件', () async {
      final novel = Novel(
        id: 'n-tmp',
        title: 'T',
        genre: 'xuanhuan',
        tone: '热血',
        targetWordsPerChapter: 2000,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        chapters: const [],
        characters: const [],
        worldSettings: const [],
      );
      await db.writeNovel(novel);
      final tmpFiles = await db.directory
          .list()
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(tmpFiles, isEmpty);
    });

    test('readNovel 不存在时抛 StorageException', () {
      expect(() => db.readNovel('n-missing'), throwsA(isA<StorageException>()));
    });

    test('index 读写往返', () async {
      final items = [
        NovelSummary(
          id: 'x',
          title: 'X',
          genre: 'dushi',
          updatedAt: DateTime(2026, 1, 1),
        ),
      ];
      await db.writeIndex(items);
      final back = await db.readIndex();
      expect(back.length, equals(1));
      expect(back.first.title, equals('X'));
    });

    test('readIndex 文件缺失时返回空列表', () async {
      expect(await db.readIndex(), isEmpty);
    });
  });

  group('NovelRepository CRUD', () {
    test('createNovel 写入单 json + 更新 index', () async {
      final novel = await novelRepo.createNovel(
        title: '新作',
        genre: 'kehuan',
        tone: '硬核',
      );
      expect(novel.id, isNotEmpty);
      expect(novel.title, equals('新作'));
      expect(novel.genre, equals('kehuan'));
      expect(
        novel.targetWordsPerChapter,
        equals(AppConstants.defaultMaxWordsPerChapter),
      );
      expect(novel.chapters, isEmpty);
      expect(await db.exists(novel.id), isTrue);
      final index = await db.readIndex();
      expect(index.any((e) => e.id == novel.id), isTrue);
    });

    test('createNovel 空标题回退「未命名作品」', () async {
      final novel = await novelRepo.createNovel(
        title: '   ',
        genre: 'xuanhuan',
        tone: '热血',
      );
      expect(novel.title, equals('未命名作品'));
    });

    test('getNovel 往返一致', () async {
      final novel = await novelRepo.createNovel(
        title: '往返',
        genre: 'xuanhuan',
        tone: '热血',
      );
      final read = await novelRepo.getNovel(novel.id);
      expect(read.id, equals(novel.id));
      expect(read.title, equals('往返'));
    });

    test('saveNovel 刷新 updatedAt 并落盘', () async {
      final novel = await novelRepo.createNovel(
        title: '保存',
        genre: 'xuanhuan',
        tone: '热血',
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final saved = await novelRepo.saveNovel(novel.copyWith(title: '保存2'));
      expect(saved.title, equals('保存2'));
      expect(
        saved.updatedAt.isAfter(novel.updatedAt) ||
            saved.updatedAt.isAtSameMomentAs(novel.updatedAt),
        isTrue,
      );
      final read = await novelRepo.getNovel(novel.id);
      expect(read.title, equals('保存2'));
    });

    test('renameNovel 修改标题', () async {
      final novel = await novelRepo.createNovel(
        title: '旧名',
        genre: 'xuanhuan',
        tone: '热血',
      );
      final renamed = await novelRepo.renameNovel(novel.id, '新名');
      expect(renamed.title, equals('新名'));
    });

    test('setArchived 归档/取消归档并同步索引', () async {
      final novel = await novelRepo.createNovel(
        title: '归档测试',
        genre: 'xuanhuan',
        tone: '热血',
      );
      // 归档：Novel 与索引摘要同步。
      final archived = await novelRepo.setArchived(novel.id, true);
      expect(archived.archived, isTrue);
      final read = await novelRepo.getNovel(novel.id);
      expect(read.archived, isTrue);
      final index = await db.readIndex();
      expect(index.firstWhere((e) => e.id == novel.id).archived, isTrue);
      // 取消归档。
      final restored = await novelRepo.setArchived(novel.id, false);
      expect(restored.archived, isFalse);
      final index2 = await db.readIndex();
      expect(index2.firstWhere((e) => e.id == novel.id).archived, isFalse);
    });

    test('deleteNovel 删除文件并从索引移除', () async {
      final novel = await novelRepo.createNovel(
        title: '待删',
        genre: 'xuanhuan',
        tone: '热血',
      );
      await novelRepo.deleteNovel(novel.id);
      expect(await db.exists(novel.id), isFalse);
      final index = await db.readIndex();
      expect(index.any((e) => e.id == novel.id), isFalse);
    });

    test('listNovels 按更新时间倒序', () async {
      final a = await novelRepo.createNovel(
        title: 'A',
        genre: 'xuanhuan',
        tone: '热血',
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = await novelRepo.createNovel(
        title: 'B',
        genre: 'xuanhuan',
        tone: '热血',
      );
      final list = await novelRepo.listNovels();
      expect(list.first.id, equals(b.id));
      expect(list.last.id, equals(a.id));
    });
  });

  group('ChapterRepository', () {
    late String novelId;
    setUp(() async {
      novelId = (await novelRepo.createNovel(
        title: '章节测试',
        genre: 'xuanhuan',
        tone: '热血',
      ))
          .id;
    });

    test('addChapter 追加到末尾并默认标题', () async {
      final ch = await chapterRepo.addChapter(novelId);
      expect(ch.order, equals(0));
      expect(ch.title, equals('第1章'));
      final list = await chapterRepo.listChapters(novelId);
      expect(list.length, equals(1));
    });

    test('listChapters 按 order 升序', () async {
      await chapterRepo.addChapter(novelId, title: '一');
      await chapterRepo.addChapter(novelId, title: '二');
      await chapterRepo.addChapter(novelId, title: '三');
      final list = await chapterRepo.listChapters(novelId);
      expect(list.map((c) => c.title).toList(), equals(['一', '二', '三']));
    });

    test('updateChapterContent 仅更新正文与时间', () async {
      final ch = await chapterRepo.addChapter(novelId);
      await chapterRepo.updateChapterContent(novelId, ch.id, '新的正文内容。');
      final read = await chapterRepo.getChapter(novelId, ch.id);
      expect(read.content, equals('新的正文内容。'));
    });

    test('saveGeneratedChapter 按 order 覆盖或新增', () async {
      final saved = await chapterRepo.saveGeneratedChapter(
        novelId,
        0,
        '生成章',
        '生成的正文。',
      );
      expect(saved.order, equals(0));
      expect(saved.title, equals('生成章'));
      final again = await chapterRepo.saveGeneratedChapter(
        novelId,
        0,
        '生成章2',
        '再次生成。',
      );
      expect(again.title, equals('生成章2'));
      final list = await chapterRepo.listChapters(novelId);
      expect(list.length, equals(1)); // 同一 order 覆盖而非新增
    });

    test('deleteChapter 重排 order 连续', () async {
      final c1 = await chapterRepo.addChapter(novelId, title: '一');
      final c2 = await chapterRepo.addChapter(novelId, title: '二');
      final c3 = await chapterRepo.addChapter(novelId, title: '三');
      await chapterRepo.deleteChapter(novelId, c2.id);
      final list = await chapterRepo.listChapters(novelId);
      expect(list.length, equals(2));
      expect(list.map((c) => c.order).toList(), equals([0, 1]));
      expect(list.any((c) => c.id == c1.id), isTrue);
      expect(list.any((c) => c.id == c3.id), isTrue);
    });

    test('reorderChapters 按给定顺序重排', () async {
      final c1 = await chapterRepo.addChapter(novelId, title: '一');
      final c2 = await chapterRepo.addChapter(novelId, title: '二');
      await chapterRepo.reorderChapters(novelId, [c2.id, c1.id]);
      final list = await chapterRepo.listChapters(novelId);
      expect(list.map((c) => c.id).toList(), equals([c2.id, c1.id]));
      expect(list.map((c) => c.order).toList(), equals([0, 1]));
    });

    test('addDraft/listDrafts 存稿箱新增与倒序列表', () async {
      final d1 = await chapterRepo.addDraft(
        novelId,
        title: '草稿一',
        content: '第一份草稿。',
      );
      await chapterRepo.addDraft(
        novelId,
        title: '',
        content: '第二份草稿。',
      );
      final list = await chapterRepo.listDrafts(novelId);
      expect(list.length, equals(2));
      // 空标题回退「未命名草稿」；列表按创建时间倒序。
      expect(list.first.title, equals('未命名草稿'));
      expect(list.any((d) => d.id == d1.id), isTrue);
    });

    test('promoteDraft 存稿转正式章节并移除存稿', () async {
      final draft = await chapterRepo.addDraft(
        novelId,
        title: '转正稿',
        content: '这段要变成正式章节。',
      );
      final ch = await chapterRepo.promoteDraft(novelId, draft.id);
      expect(ch.title, equals('转正稿'));
      expect(ch.order, equals(0));
      expect(ch.content, equals('这段要变成正式章节。'));
      final chapters = await chapterRepo.listChapters(novelId);
      expect(chapters.length, equals(1));
      final drafts = await chapterRepo.listDrafts(novelId);
      expect(drafts, isEmpty);
    });

    test('deleteDraft 删除存稿', () async {
      final draft = await chapterRepo.addDraft(
        novelId,
        title: '待删',
        content: '不要了。',
      );
      await chapterRepo.deleteDraft(novelId, draft.id);
      final drafts = await chapterRepo.listDrafts(novelId);
      expect(drafts, isEmpty);
    });
  });

  group('SettingRepository', () {
    late String novelId;
    setUp(() async {
      novelId = (await novelRepo.createNovel(
        title: '设定测试',
        genre: 'xuanhuan',
        tone: '热血',
      ))
          .id;
    });

    test('addCharacter / update / delete', () async {
      final ch = await settingRepo.addCharacter(
        novelId,
        name: '云澈',
        role: '男主',
      );
      expect(ch.name, equals('云澈'));
      final novel = await novelRepo.getNovel(novelId);
      expect(novel.characters.length, equals(1));
      await settingRepo.updateCharacter(novelId, ch.copyWith(name: '林玄'));
      final updated = await novelRepo.getNovel(novelId);
      expect(updated.characters.first.name, equals('林玄'));
      await settingRepo.deleteCharacter(novelId, ch.id);
      final after = await novelRepo.getNovel(novelId);
      expect(after.characters, isEmpty);
    });

    test('addWorldSetting / update / delete', () async {
      final w = await settingRepo.addWorldSetting(
        novelId,
        title: '修炼体系',
        category: '规则',
        content: '灵气。',
      );
      expect(w.title, equals('修炼体系'));
      final novel = await novelRepo.getNovel(novelId);
      expect(novel.worldSettings.length, equals(1));
      await settingRepo.updateWorldSetting(novelId, w.copyWith(content: '灵气充盈。'));
      final updated = await novelRepo.getNovel(novelId);
      expect(updated.worldSettings.first.content, equals('灵气充盈。'));
      await settingRepo.deleteWorldSetting(novelId, w.id);
      final after = await novelRepo.getNovel(novelId);
      expect(after.worldSettings, isEmpty);
    });
  });

  group('并发写不丢数据（per-novelId 锁）', () {
    test('自动保存 + AI 落库 + 加角色 并发：三份写入全部生效', () async {
      final novel = await novelRepo.createNovel(
        title: '并发',
        genre: 'xuanhuan',
        tone: '热血',
      );
      final ch1 = await chapterRepo.addChapter(novel.id, title: '第一章');
      final ch2 = await chapterRepo.addChapter(novel.id, title: '第二章');

      await Future.wait([
        chapterRepo.updateChapterContent(novel.id, ch1.id, '编辑器的正文：张三拔剑。'),
        chapterRepo.saveGeneratedChapter(novel.id, 1, 'AI 第二章', 'AI 生成的正文：李四收刀。'),
        settingRepo.addCharacter(novel.id, name: '王五'),
      ]);

      final saved = await novelRepo.getNovel(novel.id);
      expect(
        saved.chapters.firstWhere((c) => c.id == ch1.id).content,
        contains('张三拔剑'),
      );
      expect(
        saved.chapters.firstWhere((c) => c.id == ch2.id).content,
        contains('李四收刀'),
        reason: 'AI 落库不得被并发的自动保存用旧快照覆盖',
      );
      expect(saved.characters.map((c) => c.name), contains('王五'));
    });

    test('mutateNovel 只改元信息，不清掉并发写入的正文', () async {
      final novel = await novelRepo.createNovel(
        title: '偏好',
        genre: 'dushi',
        tone: '冷静',
      );
      final ch = await chapterRepo.addChapter(novel.id, title: '第一章');

      await Future.wait([
        novelRepo.mutateNovel(
          novel.id,
          (n) => n.copyWith(preferredStyle: 'jinliu'),
        ),
        chapterRepo.updateChapterContent(novel.id, ch.id, '生成中的正文内容。'),
      ]);

      final saved = await novelRepo.getNovel(novel.id);
      expect(saved.preferredStyle, equals('jinliu'));
      expect(saved.chapters.single.content, equals('生成中的正文内容。'));
    });

    test('并发新建项目不丢 index 条目', () async {
      final novels = await Future.wait([
        for (int i = 0; i < 4; i++)
          novelRepo.createNovel(title: '书$i', genre: 'xuanhuan', tone: '热血'),
      ]);
      final index = await novelRepo.listNovels();
      expect(index, hasLength(4));
      for (final n in novels) {
        expect(index.map((e) => e.id), contains(n.id));
      }
    });
  });

  group('零网络验证', () {
    test('存储层仅做本地文件读写（数据确实落在本地文件系统）', () {
      // 结构性保证见代码静态审查：lib/storage 与 lib/models 不 import 任何网络库。
      // 此处通过断言目录确为本地路径来佐证（非网络请求）。
      expect(db.directory.existsSync(), isTrue);
      expect(db.directory.path, contains(_testDir.path));
    });
  });

  group('章节写盘与首页索引同步', () {
    test('生成章节后 index.json 的章数/字数立即跟上', () async {
      final Novel novel = await novelRepo.createNovel(
        title: '索引同步',
        genre: 'xuanhuan',
        tone: '热血',
      );
      List<NovelSummary> index = await db.readIndex();
      expect(index.first.wordCount, 0, reason: '新建时首页应为 0 字');

      await chapterRepo.saveGeneratedChapter(
          novel.id, 1, '第一章', '甲' * 500);
      index = await db.readIndex();
      expect(index.first.chapterCount, 1);
      expect(index.first.wordCount, 500);

      await chapterRepo.saveGeneratedChapter(
          novel.id, 2, '第二章', '乙' * 300);
      index = await db.readIndex();
      expect(index.first.chapterCount, 2);
      expect(index.first.wordCount, 800, reason: '第二章写完后首页要看到 800 字');
    });

    test('编辑器自动保存改字数，首页不需要重开项目就更新', () async {
      final Novel novel = await novelRepo.createNovel(
        title: '自动保存',
        genre: 'dushi',
        tone: '轻松',
      );
      final Chapter ch = await chapterRepo.addChapter(novel.id);
      await chapterRepo.updateChapterContent(novel.id, ch.id, '写' * 120);
      List<NovelSummary> index = await db.readIndex();
      expect(index.first.wordCount, 120);

      await chapterRepo.updateChapterContent(novel.id, ch.id, '写' * 40);
      index = await db.readIndex();
      expect(index.first.wordCount, 40, reason: '删字也要如实反映，不能只增不减');
    });

    test('删章后索引章数归零，条目本身不丢', () async {
      final Novel novel = await novelRepo.createNovel(
        title: '删章',
        genre: 'lishi',
        tone: '恢弘',
      );
      final Chapter ch = await chapterRepo.addChapter(novel.id);
      await chapterRepo.deleteChapter(novel.id, ch.id);
      final List<NovelSummary> index = await db.readIndex();
      expect(index.length, 1);
      expect(index.first.chapterCount, 0);
      expect(index.first.wordCount, 0);
    });

    test('并发写两章不会互相抹掉索引条目', () async {
      final Novel novel = await novelRepo.createNovel(
        title: '并发',
        genre: 'xuanyi',
        tone: '暗黑',
      );
      await Future.wait(<Future<Object?>>[
        chapterRepo.saveGeneratedChapter(novel.id, 1, '甲', '一' * 200),
        chapterRepo.saveGeneratedChapter(novel.id, 2, '乙', '二' * 200),
        chapterRepo.saveGeneratedChapter(novel.id, 3, '丙', '三' * 200),
      ]);
      final List<NovelSummary> index = await db.readIndex();
      expect(index.length, 1, reason: '索引条目不能被并发写抹掉');
      expect(index.first.chapterCount, 3);
      expect(index.first.wordCount, 600);
      // 正文本身也要齐。
      final Novel reloaded = await novelRepo.getNovel(novel.id);
      expect(reloaded.chapters.length, 3);
    });

    test('重命名项目后索引标题同步（防止双实现漂移）', () async {
      final Novel novel = await novelRepo.createNovel(
        title: '旧名',
        genre: 'yanqing',
        tone: '甜宠',
      );
      await novelRepo.renameNovel(novel.id, '新名');
      final List<NovelSummary> index = await db.readIndex();
      expect(index.first.title, '新名');
    });
  });

  group('删除清理备份', () {
    test('deleteNovel 把主文件/备份/临时文件一并清掉（防止备份自愈复活已删项目）', () async {
      final Novel novel = await novelRepo.createNovel(
        title: '删除清理',
        genre: 'xuanhuan',
        tone: '热血',
      );
      // addChapter 触发 _write → 生成 .bak.json 备份。
      await chapterRepo.addChapter(novel.id);
      expect(await db.novelBackupFile(novel.id).exists(), isTrue);

      await novelRepo.deleteNovel(novel.id);

      expect(await db.novelFile(novel.id).exists(), isFalse);
      expect(await db.novelBackupFile(novel.id).exists(), isFalse,
          reason: '备份残留会让 readNovel 的自愈逻辑把已删项目"复活"');
      // 读取同样必须抛异常，而不是从备份返回数据。
      await expectLater(
        novelRepo.getNovel(novel.id),
        throwsA(isA<AppException>()),
      );
    });
  });

  group('自动保存跳过无变化写入', () {
    test('updateChapterContent 内容未变化时不落盘（updatedAt 不前移）', () async {
      final Novel novel = await novelRepo.createNovel(
        title: '无变化跳过',
        genre: 'xuanhuan',
        tone: '热血',
      );
      final Chapter ch = await chapterRepo.addChapter(novel.id);
      await chapterRepo.updateChapterContent(novel.id, ch.id, '正文内容');

      final Novel afterFirst = await novelRepo.getNovel(novel.id);
      final DateTime firstSavedAt = afterFirst.chapters.first.updatedAt;

      // 等一小段时间，保证旧实现「无脑重写」会得到更晚的 updatedAt。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await chapterRepo.updateChapterContent(novel.id, ch.id, '正文内容');

      final Novel afterSecond = await novelRepo.getNovel(novel.id);
      expect(afterSecond.chapters.first.updatedAt, firstSavedAt,
          reason: '内容相同不应触发整本重写（防抖/失焦保存可能空转）');
      expect(afterSecond.chapters.first.content, '正文内容');
    });
  });

}
