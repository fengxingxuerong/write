import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/core/security/secret_store.dart';
import 'package:novel_writer/models/llm_config.dart';

/// PipelineStorage 断点持久化单元测试。
///
/// 覆盖：任务保存/读取回环、缺失返回 null、损坏抛 StorageException、
/// 索引去重与倒序列表、损坏索引容错为空、删除任务重建索引、
/// 最近配置的保存/读取/容错。
void main() {
  late Directory tempDir;
  late PipelineStorage storage;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pipeline_storage_test_');
    storage = PipelineStorage(tempDir.path, secretStore: InMemorySecretStore());
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  AiPipelineTask task(String id, DateTime createdAt) => AiPipelineTask(
    id: id,
    config: const AiPipelineConfig(totalWords: 10000),
    createdAt: createdAt,
  )..addLog('测试日志-$id');

  group('任务保存与读取', () {
    test('保存后可读取回环（含日志）', () async {
      await storage.saveTask(task('t1', DateTime(2026, 9, 1)));
      final AiPipelineTask? loaded = await storage.loadTask('t1');
      expect(loaded, isNotNull);
      expect(loaded!.id, 't1');
      expect(loaded.log.first, contains('测试日志-t1'));
    });

    test('保存后任务文件不包含明文 API Key', () async {
      final AiPipelineTask withSecret = AiPipelineTask(
        id: 'secret',
        config: const AiPipelineConfig(
          roles: <AiRole, AiRoleConfig>{
            AiRole.writer: AiRoleConfig(
              role: AiRole.writer,
              llm: LlmConfig(
                provider: LlmProvider.openaiCompatible,
                apiKey: 'sk-pipeline-plain',
                baseUrl: 'https://api.example.com/v1',
              ),
            ),
          },
        ),
        createdAt: DateTime(2026, 9, 1),
      );
      await storage.saveTask(withSecret);
      final String raw = storage.taskFile('secret').readAsStringSync();
      expect(raw, isNot(contains('sk-pipeline-plain')));
      expect(raw, contains('apiKeyEncrypted'));
    });

    test('旧版明文任务读取后迁移为受保护字段', () async {
      final Map<String, dynamic> legacy = task(
        'legacy',
        DateTime(2026, 9, 1),
      ).toJson();
      legacy['config'] = <String, dynamic>{
        ...(legacy['config']! as Map<String, dynamic>),
        'roles': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'writer',
            'enabled': true,
            'llm': <String, dynamic>{
              'provider': 'openaiCompatible',
              'model': 'legacy-model',
              'apiKey': 'sk-pipeline-legacy',
              'baseUrl': 'https://api.example.com/v1',
              'maxTokens': 4096,
              'temperature': 0.8,
            },
            'fallbacks': <Map<String, dynamic>>[],
          },
        ],
      };
      await storage.ensureDir();
      await storage.taskFile('legacy').writeAsString(jsonEncode(legacy));
      final AiPipelineTask? loaded = await storage.loadTask('legacy');
      expect(
        loaded!.config.roles[AiRole.writer]!.llm.apiKey,
        'sk-pipeline-legacy',
      );
      final String raw = storage.taskFile('legacy').readAsStringSync();
      expect(raw, isNot(contains('sk-pipeline-legacy')));
      expect(raw, contains('apiKeyEncrypted'));
    });

    test('读取不存在的任务返回 null', () async {
      expect(await storage.loadTask('不存在'), isNull);
    });

    test('任务文件损坏时抛 StorageException', () async {
      await storage.ensureDir();
      await storage.taskFile('bad').writeAsString('{{{不是 JSON');
      expect(() => storage.loadTask('bad'), throwsA(isA<StorageException>()));
    });

    test('任务主文件损坏时从 .bak 恢复上一版', () async {
      await storage.saveTask(task('backup', DateTime(2026, 9, 1)));
      await storage.saveTask(task('backup', DateTime(2026, 9, 2)));
      final File file = storage.taskFile('backup');
      await file.writeAsString('{损坏');
      final AiPipelineTask? recovered = await storage.loadTask('backup');
      expect(recovered, isNotNull);
      expect(recovered!.createdAt, DateTime(2026, 9, 1));
      expect(
        jsonDecode(await file.readAsString()),
        isA<Map<String, dynamic>>(),
      );
    });

    test('原子写不残留 .tmp 文件', () async {
      await storage.saveTask(task('t2', DateTime(2026, 9, 1)));
      expect(File('${storage.taskFile('t2')}.path.tmp').existsSync(), isFalse);
    });
  });

  group('任务列表与索引', () {
    test('无索引文件时返回空列表', () async {
      expect(await storage.listTasks(), isEmpty);
    });

    test('列表按创建时间倒序', () async {
      await storage.saveTask(task('old', DateTime(2026, 9, 1)));
      await storage.saveTask(task('new', DateTime(2026, 9, 10)));
      await storage.saveTask(task('mid', DateTime(2026, 9, 5)));
      final List<AiPipelineTask> all = await storage.listTasks();
      expect(all.map((AiPipelineTask t) => t.id), <String>[
        'new',
        'mid',
        'old',
      ]);
    });

    test('同一任务重复保存，索引去重', () async {
      await storage.saveTask(task('dup', DateTime(2026, 9, 1)));
      await storage.saveTask(task('dup', DateTime(2026, 9, 2)));
      final List<AiPipelineTask> all = await storage.listTasks();
      expect(all.length, 1);
      expect(all.single.createdAt, DateTime(2026, 9, 2));
    });

    test('索引文件损坏时仍从任务文件恢复列表', () async {
      await storage.saveTask(task('t3', DateTime(2026, 9, 1)));
      await storage.indexFile.writeAsString('损坏的索引');
      final all = await storage.listTasks();
      expect(all.map((AiPipelineTask t) => t.id), contains('t3'));
    });

    test('索引文件缺失时仍从任务文件恢复列表', () async {
      await storage.saveTask(task('orphan', DateTime(2026, 9, 1)));
      await storage.indexFile.delete();
      final all = await storage.listTasks();
      expect(all.single.id, 'orphan');
    });

    test('不同存储实例并发保存不丢索引', () async {
      final PipelineStorage other = PipelineStorage(
        tempDir.path,
        secretStore: InMemorySecretStore(),
      );
      await Future.wait(<Future<void>>[
        for (int i = 0; i < 30; i++)
          (i.isEven ? storage : other).saveTask(
            task('concurrent-$i', DateTime(2026, 9, i + 1)),
          ),
      ]);

      final List<AiPipelineTask> all = await storage.listTasks();
      expect(all.length, 30);
      expect(all.map((AiPipelineTask t) => t.id).toSet().length, 30);
    });

    test('删除任务：文件与索引记录一并移除', () async {
      await storage.saveTask(task('a', DateTime(2026, 9, 1)));
      await storage.saveTask(task('b', DateTime(2026, 9, 2)));
      await storage.deleteTask('a');
      expect(storage.taskFile('a').existsSync(), isFalse);
      final List<AiPipelineTask> all = await storage.listTasks();
      expect(all.map((AiPipelineTask t) => t.id), <String>['b']);
    });
  });

  group('最近配置', () {
    test('保存/读取回环', () async {
      const AiPipelineConfig config = AiPipelineConfig(
        totalWords: 50000,
        genre: '悬疑',
        protagonist: '沈度',
      );
      await storage.saveRecentConfig(config);
      final AiPipelineConfig? loaded = await storage.loadRecentConfig();
      expect(loaded, isNotNull);
      expect(loaded!.totalWords, 50000);
      expect(loaded.genre, '悬疑');
      expect(loaded.protagonist, '沈度');
    });

    test('无配置时返回 null', () async {
      expect(await storage.loadRecentConfig(), isNull);
    });

    test('最近配置读取旧版明文后迁移为受保护字段', () async {
      await storage.ensureDir();
      await storage.recentConfigFile.writeAsString(
        jsonEncode(<String, dynamic>{
          'totalWords': 50000,
          'maxChapters': 40,
          'genre': '悬疑',
          'protagonist': '沈度',
          'useEditor': true,
          'useVerifier': true,
          'useQualityReview': true,
          'qualityReviewEvery': 3,
          'autoRewriteLowScore': true,
          'rewriteThreshold': 55,
          'useStateTrack': true,
          'roles': <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'writer',
              'enabled': true,
              'llm': <String, dynamic>{
                'provider': 'openaiCompatible',
                'model': 'legacy-model',
                'apiKey': 'sk-recent-legacy',
                'baseUrl': 'https://api.example.com/v1',
                'maxTokens': 4096,
                'temperature': 0.8,
              },
              'fallbacks': <Map<String, dynamic>>[],
            },
          ],
        }),
      );
      final AiPipelineConfig? loaded = await storage.loadRecentConfig();
      expect(loaded!.roles[AiRole.writer]!.llm.apiKey, 'sk-recent-legacy');
      final String raw = storage.recentConfigFile.readAsStringSync();
      expect(raw, isNot(contains('sk-recent-legacy')));
      expect(raw, contains('apiKeyEncrypted'));
    });

    test('配置文件损坏时容错为 null', () async {
      await storage.ensureDir();
      await storage.recentConfigFile.writeAsString('{{{损坏');
      expect(await storage.loadRecentConfig(), isNull);
    });
  });
}
