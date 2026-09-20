import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/llm_context_brief.dart';
import 'package:novel_writer/engine/llm_engine.dart';
import 'package:novel_writer/engine/multipass/multi_pass_chapter_engine.dart';
import 'package:novel_writer/engine/multipass/scene_builder.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/models/world_setting.dart';

const _config = GenerationConfig(
  genre: 'xuanyi',
  tone: '冷峻',
  targetWords: 2000,
  protagonistName: '林舟',
  continuation: '林舟在钟楼门口停下。',
  expandOutline: false,
  constraints: GenerationConstraints(),
);

ContextBundle _context() => ContextBundle(
  characters: const [
    Character(
      id: 'c',
      novelId: 'n',
      name: '林舟',
      role: '调查员',
      traits: '谨慎',
      background: '曾任钟楼守卫',
      relationships: '苏晚是林舟的姐姐',
      dialogueStyle: '短句，避免反问',
    ),
  ],
  worldSettings: const [
    WorldSetting(
      id: 'w',
      novelId: 'n',
      title: '钟楼规则',
      category: '规则',
      content: '午夜后钟楼只能出不能进',
    ),
  ],
  genrePreset: GenrePresets.get('xuanyi'),
  plotSkeleton: PlotSkeleton.forGenre('xuanyi'),
  outline: '调查钟楼，发现密室',
  plotSummary: '苏晚带走了钥匙。',
  foreshadowing: '失踪守卫的怀表尚未找到',
);

void _expectMemory(String prompt) {
  for (final text in [
    '苏晚是林舟的姐姐',
    '曾任钟楼守卫',
    '短句，避免反问',
    '午夜后钟楼只能出不能进',
    '苏晚带走了钥匙。',
    '失踪守卫的怀表尚未找到',
  ]) {
    expect(prompt, contains(text));
  }
}

void main() {
  test('共享上下文保留完整设定，可独立省略上一章结尾', () {
    final prompt = LlmContextBrief.contextBlock(_config, _context());
    _expectMemory(prompt);
    expect(prompt, contains(_config.continuation!));
    final later = LlmContextBrief.contextBlock(
      _config,
      _context(),
      includeContinuation: false,
    );
    _expectMemory(later);
    expect(later, isNot(contains(_config.continuation!)));
  });

  test('空上下文不生成空标题或 null 文本', () {
    final ctx = _context().copyWith(
      characters: [],
      worldSettings: [],
      plotSummary: '',
      foreshadowing: '',
    );
    expect(
      LlmContextBrief.contextBlock(_config, ctx, includeContinuation: false),
      isEmpty,
    );
    expect(LlmContextBrief.continuationBlock(null), isEmpty);
    expect(LlmContextBrief.continuationBlock('  \n'), isEmpty);
  });

  for (final multiPass in [false, true]) {
    test('${multiPass ? '多场景' : '单章'}实际请求包含完整上下文', () async {
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final payload =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final messages = payload['messages'] as List<dynamic>;
        final prompt =
            (messages.last as Map<String, dynamic>)['content'] as String;
        requests.add(prompt);
        if (payload['stream'] == true) {
          req.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          req.response.write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '林舟推开暗门。'},
                },
              ],
            })}\n\ndata: [DONE]\n\n',
          );
        } else {
          final planning = requests.length == 1;
          final content = planning
              ? jsonEncode({
                  'scenes': [
                    {
                      'index': 0,
                      'stage': '起',
                      'goal': '调查门锁',
                      'beats': ['检查门锁'],
                      'targetWords': 500,
                    },
                    {
                      'index': 1,
                      'stage': '合',
                      'goal': '发现密室',
                      'beats': ['找到密室'],
                      'targetWords': 500,
                    },
                  ],
                })
              : (requests.length == 2 ? '林舟取出铜片，撬开了锁。' : '门后还有一扇门。');
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': content},
                },
              ],
            }),
          );
        }
        await req.response.close();
      });
      final llm = LlmConfig(
        provider: LlmProvider.openaiCompatible,
        model: 'fake',
        apiKey: 'test-only',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
      );
      if (multiPass) {
        final engine = MultiPassChapterEngine(
          config: llm,
          sceneBuilder: SceneBuilder(config: llm),
        );
        final result = await engine.generate(_config, _context());
        expect(result.content, '林舟取出铜片，撬开了锁。\n\n门后还有一扇门。');
        expect(requests, hasLength(3));
        _expectMemory(requests.first);
        expect(requests.first, contains(_config.continuation!));
        for (final prompt in requests.skip(1)) {
          _expectMemory(prompt);
          expect(prompt, contains(_config.style.instruction));
          expect(prompt, contains(_config.proseStyle.instruction));
          expect(prompt, contains(_context().outline));
        }
        expect(requests[1], contains(_config.continuation!));
        expect(requests[2], contains('林舟取出铜片，撬开了锁。'));
        expect(requests[2], isNot(contains(_config.continuation!)));
      } else {
        final engine = LlmEngine(config: llm);
        addTearDown(engine.dispose);
        final result = await engine.generate(_config, _context());
        expect(result.content, '林舟推开暗门。');
        expect(requests, hasLength(1));
        _expectMemory(requests.single);
        expect(requests.single, contains(_config.continuation!));
      }
    });
  }
}
