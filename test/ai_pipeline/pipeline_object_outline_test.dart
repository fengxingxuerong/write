// 回归测试：规划官按提示词契约返回「对象型」大纲字段时，流水线不得崩溃。
//
// 背景：真实模型（DeepSeek-V4-Flash）会返回
//   "world": {"continent": ..., "power_system": ..., "faction": ...}
// 而旧代码在场景规划前写死 `outlineMap['world'] as String?`，直接抛
// 「type '_Map<String, dynamic>' is not a subtype of type 'String?'」，
// 整本任务失败。本测试用本地假端点复现该返回并断言能正常成稿。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/ai_pipeline_service.dart';
import 'package:novel_writer/ai_pipeline/services/llm_router.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/security/secret_store.dart';
import 'package:novel_writer/engine/llm_retry.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 章节正文假稿（足够长以满足字数门槛）。
final String _prose =
    '林舟把半枚铜钥匙按进锁孔，指腹被铜锈磨得发烫。'
        '门缝里透出的风带着铁腥气，像有人在极深的地方呼吸。'
        '他没有回头，只把肩抵住门板，听着那些细碎的响动一寸寸逼近。'
        '潮水退到脚踝以下时，锁芯忽然自己转了半圈。' *
    8;

void main() {
  test(
    '大纲 world/protagonist 为对象时流水线照样跑完（不再类型崩溃）',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));

      server.listen((HttpRequest req) async {
        final Map<String, dynamic> payload =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final List<dynamic> messages = payload['messages'] as List<dynamic>;
        final String user =
            (messages.last as Map<String, dynamic>)['content'] as String;
        late String content;
        if (user.contains('chapter_outlines')) {
          // 关键：world / protagonist 都是对象，与提示词契约一致。
          content = jsonEncode(<String, dynamic>{
            'title': '铜钥',
            'protagonist': <String, dynamic>{'name': '林舟', 'trait': '谨慎'},
            'world': <String, dynamic>{
              'continent': '九霄大陆',
              'power_system': '炼气/筑基',
              'faction': '剑宗',
            },
            'hook': '钥匙为何只剩半枚',
            'chapter_outlines': <Map<String, dynamic>>[
              <String, dynamic>{
                'idx': 1,
                'title': '第1章 半枚铜钥',
                'goal': '闯入旧城，爽点=收获；钩子=门后有呼吸声',
                'target': 600,
              },
            ],
          });
        } else if (user.contains('"scenes"')) {
          content = jsonEncode(<String, dynamic>{
            'scenes': <Map<String, dynamic>>[
              <String, dynamic>{
                'stage': '起',
                'goal': '按钥匙开门',
                'beats': <String>['抵门', '听声'],
                'targetWords': 500,
              },
              <String, dynamic>{
                'stage': '合',
                'goal': '门后仍是门',
                'beats': <String>['锁芯自转'],
                'targetWords': 400,
              },
            ],
          });
        } else {
          content = _prose;
        }
        req.response
          ..headers.contentType = ContentType(
            'application',
            'json',
            charset: 'utf-8',
          )
          ..add(
            utf8.encode(
              jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'message': <String, dynamic>{'content': content},
                  },
                ],
              }),
            ),
          );
        await req.response.close();
      });

      final LlmConfig endpoint = LlmConfig(
        provider: LlmProvider.openaiCompatible,
        model: 'fake-object-outline',
        apiKey: 'sk-local-test',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        maxTokens: 4096,
      );
      final AiPipelineConfig config = AiPipelineConfig(
        totalWords: 600,
        maxChapters: 1,
        genre: '玄幻',
        protagonist: '林舟',
        useEditor: false,
        useVerifier: false,
        useQualityReview: false,
        autoRewriteLowScore: false,
        useStateTrack: false,
        roles: <AiRole, AiRoleConfig>{
          for (final AiRole r in AiRole.values)
            r: AiRoleConfig(role: r, llm: endpoint),
        },
      );

      final Directory dir = Directory.systemTemp.createTempSync(
        'pipeline_obj_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final AiPipelineTask task = AiPipelineTask(
        id: 't1',
        config: config,
        createdAt: DateTime.now(),
      );
      await AiPipelineService(
        PipelineStorage(dir.path, secretStore: InMemorySecretStore()),
        router: ChainLlmRouter(
          retry: const RetryPolicy(maxAttempts: 1, baseBackoff: Duration.zero),
          timeout: const Duration(seconds: 20),
        ),
      ).run(task, isCancelled: () => false, onProgress: () {});

      expect(
        task.status,
        PipelineTaskStatus.done,
        reason: '任务日志：\n${task.log.join('\n')}',
      );
      expect(task.title, '铜钥');
      expect(task.chapters, hasLength(1));
      // 对象型 world 被拍平成文本并注入后续提示词，正文照常产出。
      expect(task.chapters.first.content, contains('铜钥匙'));
      expect(task.totalWords, greaterThanOrEqualTo(300));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
