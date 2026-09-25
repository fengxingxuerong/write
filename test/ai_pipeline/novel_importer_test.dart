import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/novel_importer.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/security/secret_store.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/novel_repository.dart';

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
}
