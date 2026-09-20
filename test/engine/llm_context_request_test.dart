import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/llm_engine.dart';
import 'package:novel_writer/engine/multipass/multi_pass_chapter_engine.dart';
import 'package:novel_writer/engine/multipass/scene_builder.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/models/world_setting.dart';

void main() {
  test('真实请求携带单章人物关系及每个场景的世界观正文', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((request) async {
      final payload = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      final messages = payload['messages'] as List<dynamic>;
      final user = (messages.last as Map<String, dynamic>)['content'] as String;
      requests.add(user);
      request.response.headers.contentType = ContentType.json;
      if (payload['stream'] == true) {
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.add(utf8.encode(
          'data: ${jsonEncode({
            'choices': [
              {'delta': {'content': '林舟收起钥匙。'}},
            ],
          })}\n\ndata: [DONE]\n\n',
        ));
      } else {
        final planning = user.contains('请严格输出 JSON');
        final content = planning
            ? jsonEncode({'scenes': [
                {'index': 0, 'stage': '起', 'goal': '进入旧城',
                  'beats': ['寻找钥匙'], 'targetWords': 500},
                {'index': 1, 'stage': '合', 'goal': '找到城门',
                  'beats': ['发现封印'], 'targetWords': 500},
              ]})
            : '林舟走向城门，停在封印前。';
        request.response.write(jsonEncode({
          'choices': [{'message': {'content': content}}],
        }));
      }
      await request.response.close();
    });
    final llm = LlmConfig(
      provider: LlmProvider.openaiCompatible,
      model: 'fake', apiKey: 'test-only',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
    );
    const config = GenerationConfig(
      genre: 'xuanhuan', tone: '悬疑', targetWords: 1000,
      expandOutline: false, constraints: GenerationConstraints(),
    );
    final context = ContextBundle(
      characters: const [Character(
        id: 'c', novelId: 'n', name: '林舟', role: '主角',
        traits: '谨慎', background: '旧城守卫',
        relationships: '苏晚是林舟失散的姐姐', dialogueStyle: '短句，不说敬语',
      )],
      worldSettings: const [WorldSetting(
        id: 'w', novelId: 'n', title: '封印规则', category: '规则',
        content: '城门只有在退潮时才能开启，强开会失去记忆',
      )],
      genrePreset: GenrePresets.get('xuanhuan'),
      plotSkeleton: PlotSkeleton.forGenre('xuanhuan'),
      outline: '寻找钥匙后进入城门',
    );
    final engine = LlmEngine(config: llm);
    addTearDown(engine.dispose);
    final single = await engine.generate(config, context);
    final multi = await MultiPassChapterEngine(
      config: llm, sceneBuilder: SceneBuilder(config: llm),
    ).generate(config, context);

    expect(single.content, isNotEmpty);
    expect(multi.content, '林舟走向城门，停在封印前。\n\n林舟走向城门，停在封印前。');
    expect(requests, hasLength(4)); // 单章 + 规划 + 两个场景。
    expect(requests.first, contains(context.characters.single.relationships));
    for (final prompt in requests.skip(2)) {
      expect(prompt, contains(context.worldSettings.single.content));
      expect(prompt, contains(context.characters.single.relationships));
      expect(prompt, contains(context.characters.single.dialogueStyle));
    }
  });
}
