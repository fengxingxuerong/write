import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/novel_importer.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/security/secret_store.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/novel_repository.dart';
import 'package:uuid/uuid.dart';

void main() {
  late Directory tmpDir;
  late PipelineStorage storage;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('pipeline_test_');
    storage = PipelineStorage(tmpDir.path, secretStore: InMemorySecretStore());
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  group('PipelineStorage 配置持久化', () {
    test('saveRecentConfig / loadRecentConfig 往返一致', () async {
      const AiPipelineConfig config = AiPipelineConfig(
        totalWords: 50000,
        maxChapters: 20,
        genre: '仙侠',
        protagonist: '陆沉',
        useEditor: false,
        roles: <AiRole, AiRoleConfig>{
          AiRole.writer: AiRoleConfig(
            role: AiRole.writer,
            llm: LlmConfig(
              provider: LlmProvider.openaiCompatible,
              model: 'deepseek-v4-flash',
              apiKey: 'k',
              baseUrl: 'https://x/v1',
            ),
          ),
        },
      );
      await storage.saveRecentConfig(config);
      final AiPipelineConfig? loaded = await storage.loadRecentConfig();
      expect(loaded, isNotNull);
      expect(loaded!.totalWords, 50000);
      expect(loaded.genre, '仙侠');
      expect(loaded.useEditor, isFalse);
      expect(loaded.roleOf(AiRole.writer).llm.model, 'deepseek-v4-flash');
    });

    test('无配置文件时返回 null', () async {
      expect(await storage.loadRecentConfig(), isNull);
    });
  });

  group('AiPipelineTask.importedNovelId', () {
    test('序列化往返保留导入 id', () async {
      final AiPipelineTask task = AiPipelineTask(
        id: 't1',
        config: const AiPipelineConfig(),
        createdAt: DateTime(2026),
        importedNovelId: 'novel-abc',
      );
      final AiPipelineTask restored = AiPipelineTask.fromJson(task.toJson());
      expect(restored.importedNovelId, 'novel-abc');
    });
  });

  group('NovelImporter', () {
    test('导入任务创建书架项目并写入章节（幂等）', () async {
      final AppDatabase db = AppDatabase.initForTest(
        '${tmpDir.path}${Platform.pathSeparator}db',
      );
      final NovelRepository repo = NovelRepository(db);
      final NovelImporter importer = NovelImporter(repo, db);

      final AiPipelineTask task = AiPipelineTask(
        id: 't2',
        config: const AiPipelineConfig(totalWords: 10000, genre: '玄幻'),
        outline: <String, dynamic>{'title': '测试之书'},
        chapters: <PipelineChapter>[
          const PipelineChapter(
            idx: 1,
            title: '第一章',
            content: '正文内容一',
            rawWords: 5,
            words: 5,
          ),
          const PipelineChapter(
            idx: 2,
            title: '第二章',
            content: '正文内容二',
            rawWords: 5,
            words: 5,
          ),
        ],
        totalWords: 10,
        createdAt: DateTime(2026),
      );

      // 同一任务 id 的并发导入共享结果，不能重复建书。
      final AiPipelineTask duplicateTask = AiPipelineTask.fromJson(
        task.toJson(),
      );
      final List<String> concurrentIds = await Future.wait(<Future<String>>[
        importer.importTask(task),
        importer.importTask(duplicateTask),
      ]);
      expect(concurrentIds, everyElement(concurrentIds.first));
      expect(task.importedNovelId, concurrentIds.first);
      expect(duplicateTask.importedNovelId, concurrentIds.first);

      // 调用方未及时回写 importedNovelId 时，重复调用仍返回同一 id。
      task.importedNovelId = null;
      final String id = await importer.importTask(task);
      expect(id, concurrentIds.first);
      task.importedNovelId = id;

      // 幂等：再次导入返回同一 id，不重复建书
      final String id2 = await importer.importTask(task);
      expect(id2, id);

      // 书架中只存在一个项目，且章节正确
      final novel = await repo.getNovel(id);
      expect(novel.title, '测试之书');
      expect(novel.genre, '玄幻');
      expect(novel.chapters.length, 2);
      expect(novel.chapters.first.title, '第一章');
      expect(novel.chapters.last.order, 2);

      // 索引摘要同步
      final summaries = await repo.listNovels();
      expect(summaries, hasLength(1));
      expect(summaries.first.id, id);
      expect(summaries.first.chapterCount, 2);
    });

    test('不同 NovelImporter 实例也能通过稳定 id 恢复幂等', () async {
      final AppDatabase db = AppDatabase.initForTest(
        '${tmpDir.path}${Platform.pathSeparator}db-cross-instance',
      );
      final NovelRepository repo = NovelRepository(db);
      final AiPipelineTask task = AiPipelineTask(
        id: 'cross-instance-task',
        config: const AiPipelineConfig(genre: '玄幻'),
        outline: const <String, dynamic>{'title': '跨实例测试'},
        chapters: const <PipelineChapter>[
          PipelineChapter(
            idx: 1,
            title: '第一章',
            content: '跨实例正文',
            rawWords: 5,
            words: 5,
          ),
        ],
        createdAt: DateTime(2026),
      );

      final String firstId = await NovelImporter(repo, db).importTask(task);
      final AiPipelineTask reloaded = AiPipelineTask.fromJson(task.toJson())
        ..importedNovelId = null;
      final String secondId = await NovelImporter(
        repo,
        db,
      ).importTask(reloaded);

      expect(secondId, firstId);
      expect(reloaded.importedNovelId, firstId);
      expect(await repo.listNovels(), hasLength(1));
      expect((await repo.getNovel(firstId)).chapters, hasLength(1));
    });

    test('空章节任务导入抛异常', () async {
      final AppDatabase db = AppDatabase.initForTest(
        '${tmpDir.path}${Platform.pathSeparator}db2',
      );
      final NovelImporter importer = NovelImporter(NovelRepository(db), db);
      final AiPipelineTask task = AiPipelineTask(
        id: 't3',
        config: const AiPipelineConfig(),
        createdAt: DateTime(2026),
      );
      expect(() => importer.importTask(task), throwsStateError);
    });
  });

    // ---- 2026-10-05：陈旧 id / 中断恢复 / isImported 的盲区补齐 ----

    test('importedNovelId 指向已删除作品 → 清旧 id 并按稳定 id 重建', () async {
      final AppDatabase db = AppDatabase.initForTest(
        '${tmpDir.path}${Platform.pathSeparator}db-stale',
      );
      final NovelRepository repo = NovelRepository(db);
      final NovelImporter importer = NovelImporter(repo, db);
      final AiPipelineTask task = AiPipelineTask(
        id: 'stale-task',
        config: const AiPipelineConfig(genre: '玄幻'),
        outline: const <String, dynamic>{'title': '旧指向之书'},
        chapters: const <PipelineChapter>[
          PipelineChapter(
              idx: 1, title: '第一章', content: '正文', rawWords: 2, words: 2),
        ],
        createdAt: DateTime(2026),
        importedNovelId: 'deleted-novel-id',
      );

      final String id = await importer.importTask(task);

      expect(id, isNot('deleted-novel-id'),
          reason: '不存在的旧 id 不能当成功结果返回');
      expect(task.importedNovelId, id);
      expect(await repo.listNovels(), hasLength(1));
      expect((await repo.getNovel(id)).chapters, hasLength(1));
    });

    test('作品被用户删除后再次导入：缓存失效并按稳定 id 恢复', () async {
      final AppDatabase db = AppDatabase.initForTest(
        '${tmpDir.path}${Platform.pathSeparator}db-evict',
      );
      final NovelRepository repo = NovelRepository(db);
      final NovelImporter importer = NovelImporter(repo, db);
      final AiPipelineTask task = AiPipelineTask(
        id: 'evict-task',
        config: const AiPipelineConfig(genre: '仙侠'),
        outline: const <String, dynamic>{'title': '恢复之书'},
        chapters: const <PipelineChapter>[
          PipelineChapter(
              idx: 1, title: '第一章', content: '正文A', rawWords: 2, words: 2),
        ],
        createdAt: DateTime(2026),
      );

      final String first = await importer.importTask(task);
      expect(task.importedNovelId, first);
      await repo.deleteNovel(first);
      expect(await repo.listNovels(), isEmpty);

      final String second = await importer.importTask(task);
      expect(second, first, reason: '缓存失效后仍应按稳定 id 恢复同一作品');
      expect(task.importedNovelId, first);
      expect(await repo.listNovels(), hasLength(1));
      expect((await repo.getNovel(first)).chapters, hasLength(1));
    });

    test('稳定 id 已存在但作品为空（上次导入中断）→ 补写章节，不覆盖标题', () async {
      final AppDatabase db = AppDatabase.initForTest(
        '${tmpDir.path}${Platform.pathSeparator}db-empty-recover',
      );
      final NovelRepository repo = NovelRepository(db);
      final NovelImporter importer = NovelImporter(repo, db);
      final AiPipelineTask task = AiPipelineTask(
        id: 'interrupted-task',
        config: const AiPipelineConfig(genre: '玄幻'),
        outline: const <String, dynamic>{'title': '中断续写'},
        chapters: const <PipelineChapter>[
          PipelineChapter(
              idx: 1, title: '第一章', content: '正文B', rawWords: 2, words: 2),
        ],
        createdAt: DateTime(2026),
      );
      final String stableId = const Uuid().v5(
        Namespace.url.value,
        'inksmith-pipeline:interrupted-task',
      );
      // 手工造一个「createNovel 成功但章节没写」的空壳作品。
      await repo.createNovel(
        id: stableId,
        title: '空壳标题',
        genre: '玄幻',
        tone: '玄幻',
      );
      expect((await repo.getNovel(stableId)).chapters, isEmpty);

      final String id = await importer.importTask(task);
      expect(id, stableId);
      final recovered = await repo.getNovel(stableId);
      expect(recovered.chapters, hasLength(1),
          reason: '空壳作品必须补写章节，而不是当作已导入返回');
      expect(recovered.title, '空壳标题', reason: '补章节不得覆盖已有标题');
      expect(await repo.listNovels(), hasLength(1));
    });

    test('isImported：任务回写 / 稳定 id 兜底 / 删除后回 false', () async {
      final AppDatabase db = AppDatabase.initForTest(
        '${tmpDir.path}${Platform.pathSeparator}db-is-imported',
      );
      final NovelRepository repo = NovelRepository(db);
      final NovelImporter importer = NovelImporter(repo, db);
      final AiPipelineTask task = AiPipelineTask(
        id: 'is-imported-task',
        config: const AiPipelineConfig(genre: '玄幻'),
        outline: const <String, dynamic>{'title': '查重之书'},
        chapters: const <PipelineChapter>[
          PipelineChapter(
              idx: 1, title: '第一章', content: '正文C', rawWords: 2, words: 2),
        ],
        createdAt: DateTime(2026),
      );

      expect(await importer.isImported(task), isFalse,
          reason: '未导入且书架无此书');

      final String id = await importer.importTask(task);
      expect(await importer.isImported(task), isTrue,
          reason: 'importedNovelId 已回写 → 直接判定');

      task.importedNovelId = null;
      expect(await importer.isImported(task), isTrue,
          reason: '状态未回写时按稳定 id 兜底判定');

      await repo.deleteNovel(id);
      expect(await importer.isImported(task), isFalse,
          reason: '作品删除后不得再判已导入');
    });

}
