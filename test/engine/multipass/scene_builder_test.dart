import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/multipass/scene_builder.dart';
import 'package:novel_writer/engine/multipass/scene_plan.dart';
import 'package:novel_writer/models/llm_config.dart';

/// SceneBuilder（章纲 → 场景列表的真实规划器）本地假端点测试。
///
/// 覆盖：```json 围栏剥离、上一场景摘要/故事上下文注入、非法响应与
/// 端点不可用时的「起承转合」四场景兜底（保证主流程不阻塞）。
void main() {
  /// 启动假端点：记录收到的请求体，按 [response] 作为 message.content 返回。
  Future<HttpServer> startServer(
    String response, {
    List<String>? captured,
  }) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest req) async {
      final String body = await utf8.decoder.bind(req).join();
      captured?.add(body);
      final String resp = jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{'content': response},
          },
        ],
      });
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(resp);
      await req.response.close();
    });
    return server;
  }

  LlmConfig cfgFor(int port) => LlmConfig(
        provider: LlmProvider.openaiCompatible,
        model: 'fake',
        baseUrl: 'http://127.0.0.1:$port/v1',
      );

  Future<List<ScenePlan>> buildFrom(
    HttpServer server, {
    String? prev,
    String story = '',
    int targetWords = 2400,
  }) =>
      SceneBuilder(config: cfgFor(server.port)).build(
        '第一章章纲：主角在宗门大比中觉醒。',
        chapterTargetWords: targetWords,
        genre: '玄幻',
        tone: '热血',
        prevSceneSummary: prev,
        storyContext: story,
      );

  test('```json 围栏响应：剥离围栏后可解析出场景', () async {
    final HttpServer server = await startServer(
      '```json\n{"scenes":['
      '{"index":0,"stage":"起","goal":"开场","beats":["节拍1"],"targetWords":800},'
      '{"index":1,"stage":"合","goal":"收束留钩","beats":["钩子"],"targetWords":1600}'
      ']}\n```',
    );
    try {
      final List<ScenePlan> scenes = await buildFrom(server);
      expect(scenes.length, 2);
      expect(scenes.first.stage, '起');
      expect(scenes.first.targetWords, 800);
      expect(scenes.last.isEnding, isTrue);
      expect(scenes.last.targetWords, 1600);
    } finally {
      await server.close(force: true);
    }
  });

  test('上一场景摘要与故事上下文注入提示词', () async {
    final List<String> captured = <String>[];
    final HttpServer server = await startServer(
      '{"scenes":[{"index":0,"stage":"起","goal":"开场","targetWords":900}]}',
      captured: captured,
    );
    try {
      await buildFrom(
        server,
        prev: '上一场景结尾：他攥紧了那枚令牌。',
        story: '既有设定：灵气复苏三百年。',
      );
      final String prompt = captured.join('\n');
      expect(prompt, contains('上一场景结尾：他攥紧了那枚令牌。'));
      expect(prompt, contains('既有设定：灵气复苏三百年。'));
      expect(prompt, contains('第一章章纲'));
    } finally {
      await server.close(force: true);
    }
  });

  test('非法响应（无 JSON 结构）→ 回退「起承转合」四场景骨架', () async {
    final HttpServer server = await startServer('模型今天不输出 JSON。');
    try {
      final List<ScenePlan> scenes = await buildFrom(server);
      expect(scenes.length, 4);
      expect(scenes.map((ScenePlan s) => s.stage).toList(),
          <String>['起', '承', '转', '合']);
      expect(scenes.first.targetWords, 600); // 2400 / 4
      expect(scenes.last.isEnding, isTrue);
      expect(scenes.first.beats, isNotEmpty);
    } finally {
      await server.close(force: true);
    }
  });

  test('端点不可用（连接被拒）→ 回退骨架且不抛错', () async {
    // 先绑端口拿到号再关闭，确保该端口无人监听。
    final HttpServer probe = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int deadPort = probe.port;
    await probe.close(force: true);

    final List<ScenePlan> scenes = await SceneBuilder(config: cfgFor(deadPort))
        .build(
      '章纲：主角被逐出师门。',
      chapterTargetWords: 3000,
      genre: '仙侠',
      tone: '悲壮',
    );
    expect(scenes.length, 4);
    expect(scenes.first.targetWords, 750); // 3000 / 4
  });
}
