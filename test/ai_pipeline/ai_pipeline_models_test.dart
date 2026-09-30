import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/prompts/pipeline_prompts.dart';
import 'package:novel_writer/ai_pipeline/services/ai_pipeline_service.dart';
import 'package:novel_writer/models/llm_config.dart';

void main() {
  group('AiPipelineConfig', () {
    test('默认角色温度正确', () {
      expect(AiRole.planner.defaultTemperature, 1.0);
      expect(AiRole.writer.defaultTemperature, 0.8);
      expect(AiRole.editor.defaultTemperature, 1.0);
      expect(AiRole.titler.defaultTemperature, 0.8);
      expect(AiRole.verifier.defaultTemperature, 1.0);
    });

    test('roleOf 缺失时返回默认启用配置', () {
      const AiPipelineConfig config = AiPipelineConfig();
      final AiRoleConfig cfg = config.roleOf(AiRole.writer);
      expect(cfg.enabled, isTrue);
      expect(cfg.llm.temperature, 0.8);
    });

    test('序列化往返一致', () {
      const AiPipelineConfig config = AiPipelineConfig(
        totalWords: 50000,
        maxChapters: 20,
        genre: '悬疑',
        protagonist: '沈度',
        useEditor: false,
        roles: <AiRole, AiRoleConfig>{
          AiRole.writer: AiRoleConfig(
            role: AiRole.writer,
            llm: LlmConfig(
              provider: LlmProvider.openaiCompatible,
              model: 'deepseek-v4-flash',
              apiKey: 'sk-test',
              baseUrl: 'https://example.com/v1/chat/completions',
              temperature: 0.8,
            ),
          ),
        },
      );
      final AiPipelineConfig restored =
          AiPipelineConfig.fromJson(config.toJson());
      expect(restored.totalWords, 50000);
      expect(restored.genre, '悬疑');
      expect(restored.useEditor, isFalse);
      expect(restored.roleOf(AiRole.writer).llm.model, 'deepseek-v4-flash');
      expect(restored.roleOf(AiRole.writer).llm.apiKey, 'sk-test');
    });
  });

  group('AiPipelineTask', () {
    test('序列化往返一致（含章节与日志）', () {
      final AiPipelineTask task = AiPipelineTask(
        id: '123',
        config: const AiPipelineConfig(totalWords: 10000),
        createdAt: DateTime(2026, 9, 5),
      )
        ..addLog('测试日志')
        ..chapters.add(const PipelineChapter(
          idx: 1,
          title: '第一章',
          content: '正文内容',
          rawWords: 3,
          words: 4,
          issues: <String>['冲突1'],
        ))
        ..totalWords = 4;
      final AiPipelineTask restored = AiPipelineTask.fromJson(task.toJson());
      expect(restored.id, '123');
      expect(restored.chapterCount, 1);
      expect(restored.chapters.first.title, '第一章');
      expect(restored.chapters.first.issues, contains('冲突1'));
      expect(restored.log.first, contains('测试日志'));
      expect(restored.totalWords, 4);
    });

    test('日志超过上限裁剪', () {
      final AiPipelineTask task = AiPipelineTask(
        id: '1',
        config: const AiPipelineConfig(),
        createdAt: DateTime.now(),
      );
      for (int i = 0; i < 500; i++) {
        task.addLog('log-$i');
      }
      expect(task.log.length, lessThanOrEqualTo(400));
    });
  });

  group('AiPipelineService.missingRoles', () {
    test('全部未配置时返回缺失角色', () {
      const AiPipelineConfig config = AiPipelineConfig();
      final List<AiRole> missing = AiPipelineService.missingRoles(config);
      expect(missing, isNotEmpty);
    });

    test('关闭编辑/审校后不再要求其配置', () {
      const AiPipelineConfig config = AiPipelineConfig(
        useEditor: false,
        useVerifier: false,
        roles: <AiRole, AiRoleConfig>{
          AiRole.planner: AiRoleConfig(
            role: AiRole.planner,
            llm: LlmConfig(
              provider: LlmProvider.openaiCompatible,
              model: 'glm-5.2',
              apiKey: 'k',
              baseUrl: 'https://example.com/v1/chat/completions',
            ),
          ),
          AiRole.writer: AiRoleConfig(
            role: AiRole.writer,
            llm: LlmConfig(
              provider: LlmProvider.openaiCompatible,
              model: 'dsf',
              apiKey: 'k',
              baseUrl: 'https://example.com/v1/chat/completions',
            ),
          ),
          AiRole.titler: AiRoleConfig(
            role: AiRole.titler,
            llm: LlmConfig(
              provider: LlmProvider.openaiCompatible,
              model: 'lite',
              apiKey: 'k',
              baseUrl: 'https://example.com/v1/chat/completions',
            ),
          ),
        },
      );
      final List<AiRole> missing = AiPipelineService.missingRoles(config);
      expect(missing, isEmpty);
    });
  });

  group('defaultScenePlan', () {
    test('返回起承转合四场景且字数合计约等于目标', () {
      final List<Map<String, dynamic>> scenes = defaultScenePlan(3000);
      expect(scenes.length, 4);
      expect(scenes.map((s) => s['stage']).join(','), '起,承,转,合');
      final int total = scenes.fold<int>(
        0,
        (int sum, s) => sum + (s['targetWords'] as int),
      );
      expect(total, greaterThanOrEqualTo(2800));
      expect(total, lessThanOrEqualTo(3300));
    });
  });

  // ================================================================
  // PipelineChapter 场景残缺记账（2026-09-30 可观测性）
  //
  // 事故：真机第 4 章 4 个场景有 2 个因端点全链失败返回空，被静默丢弃，
  // 成书只剩 1.5 个场景内容（章纲「禁地借刀」却成文「暗巷杀机」），
  // 整章伪装成正常章节落库。现在必须能被记账、序列化、并算出残缺数。
  // ================================================================
  group('PipelineChapter 场景残缺记账', () {
    PipelineChapter make({int planned = 4, int written = 4}) => PipelineChapter(
          idx: 1,
          title: '残缺章',
          content: '正文',
          rawWords: 2000,
          words: 1900,
          scenesPlanned: planned,
          scenesWritten: written,
        );

    test('场景齐全时不判残缺', () {
      final PipelineChapter c = make();
      expect(c.hasLostScenes, isFalse);
      expect(c.lostScenes, 0);
    });

    test('有场景丢失时算出残缺数', () {
      final PipelineChapter c = make(planned: 4, written: 2);
      expect(c.hasLostScenes, isTrue);
      expect(c.lostScenes, 2);
    });

    test('written 超过 planned 时不出现负数残缺', () {
      // 防御：字段来自落盘数据，理论上可被外部改坏。
      final PipelineChapter c = make(planned: 2, written: 5);
      expect(c.lostScenes, 0);
    });

    test('序列化往返保留场景计数', () {
      final PipelineChapter c = make(planned: 4, written: 2);
      final PipelineChapter back =
          PipelineChapter.fromJson(c.toJson());
      expect(back.scenesPlanned, 4);
      expect(back.scenesWritten, 2);
      expect(back.hasLostScenes, isTrue);
    });

    test('读旧账本（无场景计数字段）默认为 0，不误判残缺', () {
      final PipelineChapter back = PipelineChapter.fromJson(<String, dynamic>{
        'idx': 1,
        'title': '旧章',
        'content': '正文',
        'rawWords': 2000,
        'words': 2000,
      });
      expect(back.scenesPlanned, 0);
      expect(back.scenesWritten, 0);
      // 两边都是 0 → 无残缺（0 < 0 为假），历史产物重跑不会凭空冒告警
      expect(back.hasLostScenes, isFalse);
    });
  });
}
