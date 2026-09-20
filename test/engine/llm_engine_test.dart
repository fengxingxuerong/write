import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/llm_engine.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/models/world_setting.dart';

/// LlmEngine 单元测试：本地 loopback HttpServer 模拟 LLM 端点（零外部依赖）。
///
/// 覆盖：未配置即抛 / OpenAI SSE 流式拼接与进度 / reasoning 思考链 /
/// 429 退避重试 / 401 不重试 / 共享 HttpClient 复用 /
/// Ollama 分支 / 大纲扩写失败回退。

/// OpenAI SSE 单行（delta）。
String _sse(String content, {String? reasoning}) {
  final Map<String, dynamic> delta = <String, dynamic>{
    if (content.isNotEmpty) 'content': content,
    if (reasoning != null) 'reasoning_content': reasoning,
  };
  return 'data: ${jsonEncode(<String, dynamic>{
    'choices': <Map<String, dynamic>>[
      <String, dynamic>{'delta': delta},
    ],
  })}\n\n';
}

LlmConfig _openAiCfg(int port) => LlmConfig(
      provider: LlmProvider.openaiCompatible,
      model: 'fake-model',
      apiKey: 'sk-test',
      baseUrl: 'http://127.0.0.1:$port/v1',
    );

LlmConfig _ollamaCfg(int port) => LlmConfig(
      provider: LlmProvider.ollama,
      model: 'qwen2.5:7b',
      baseUrl: 'http://127.0.0.1:$port',
    );

GenerationConfig _genCfg({bool expandOutline = false}) => GenerationConfig(
      genre: 'xuanhuan',
      tone: '热血',
      targetWords: 2000,
      expandOutline: expandOutline,
      constraints: const GenerationConstraints(maxWordsPerChapter: 20000),
    );

ContextBundle _ctx({String outline = ''}) => ContextBundle(
      characters: const <Character>[],
      worldSettings: const <WorldSetting>[],
      genrePreset: GenrePresets.get('xuanhuan'),
      plotSkeleton: PlotSkeleton.forGenre('xuanhuan'),
      outline: outline,
    );

/// 启动本地伪端点；请求体已解析为 [body] 传入（勿重复读取请求流）。
Future<HttpServer> _startServer(
  Future<void> Function(HttpRequest req, Map<String, dynamic> body) handler,
) async {
  final HttpServer server =
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((HttpRequest req) async {
    try {
      final String raw = await utf8.decoder.bind(req).join();
      final Map<String, dynamic> body = raw.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
      await handler(req, body);
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  });
  return server;
}

/// SSE 输出若干正文增量并收尾。
Future<void> _writeSse(HttpRequest req, List<String> pieces) async {
  req.response.headers.contentType =
      ContentType('text', 'event-stream', charset: 'utf-8');
  for (final String p in pieces) {
    req.response.write(_sse(p));
    await req.response.flush();
  }
  req.response.write('data: [DONE]\n\n');
  await req.response.close();
}

void main() {
  test('未配置 → 立即抛 EngineException，不发请求', () async {
    final LlmEngine engine = LlmEngine(config: const LlmConfig());
    await expectLater(
      engine.generate(_genCfg(), _ctx()),
      throwsA(isA<EngineException>()),
    );
  });

  test('OpenAI SSE 流式：正文拼接 + 进度回报 + 请求体/鉴权校验', () async {
    final HttpServer server = await _startServer((req, body) async {
      expect(req.uri.path, '/v1/chat/completions');
      expect(req.headers.value('authorization'), 'Bearer sk-test');
      expect(body['model'], 'fake-model');
      expect(body['stream'], isTrue);
      expect((body['max_tokens'] as num).toInt(), greaterThan(0));
      expect(
        (body['chat_template_kwargs'] as Map<String, dynamic>)['enable_thinking'],
        isFalse,
      );
      final List<dynamic> messages = body['messages'] as List<dynamic>;
      expect(messages.first['role'], 'system');
      expect(messages.last['role'], 'user');
      await _writeSse(req, <String>['雨点敲打', '着窗棂，', '陆沉握紧了剑。']);
    });
    try {
      final LlmEngine engine = LlmEngine(
        config: _openAiCfg(server.port),
        maxRetries: 0,
      );
      final List<GenerationProgress> progress = <GenerationProgress>[];
      final GenerationResult r =
          await engine.generate(_genCfg(), _ctx(), onProgress: progress.add);
      expect(r.content, contains('雨点敲打'));
      expect(r.content, contains('窗棂'));
      expect(r.content, contains('陆沉握紧了剑'));
      expect(r.actualWords, greaterThan(0));
      expect(progress, isNotEmpty);
      expect(
        progress.last.charsWritten,
        greaterThanOrEqualTo(progress.first.charsWritten),
      );
      expect(progress.first.previewText, isNotNull);
    } finally {
      await server.close(force: true);
    }
  });

  test('reasoning_content 进思考链收集，不混入正文', () async {
    final HttpServer server = await _startServer((req, body) async {
      expect(body['stream'], isTrue);
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      req.response.write(_sse('', reasoning: '先想一下结构'));
      req.response.write(_sse('正文第一句。'));
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
    });
    try {
      final LlmEngine engine = LlmEngine(
        config: _openAiCfg(server.port),
        maxRetries: 0,
      );
      final GenerationResult r = await engine.generate(_genCfg(), _ctx());
      expect(r.content, '正文第一句。');
      expect(r.reasoningTokens, <String>['先想一下结构']);
    } finally {
      await server.close(force: true);
    }
  });

  test('429 限流 → 退避重试后成功（第二次请求）', () async {
    int hits = 0;
    final HttpServer server = await _startServer((req, body) async {
      expect(body['stream'], isTrue);
      hits++;
      if (hits == 1) {
        req.response.statusCode = 429;
        await req.response.close();
        return;
      }
      await _writeSse(req, <String>['重试成功。']);
    });
    try {
      final LlmEngine engine = LlmEngine(
        config: _openAiCfg(server.port),
        maxRetries: 2,
        baseBackoffMs: 1,
        sleep: (_) async {}, // 退避即时，不真等。
      );
      final GenerationResult r = await engine.generate(_genCfg(), _ctx());
      expect(r.content, '重试成功。');
      expect(hits, 2, reason: '第一次 429，重试第二次成功');
    } finally {
      await server.close(force: true);
    }
  });

  test('401 密钥无效 → 不重试（单次请求即抛）', () async {
    int hits = 0;
    final List<Duration> waits = <Duration>[];
    final HttpServer server = await _startServer((req, body) async {
      hits++;
      req.response.statusCode = 401;
      await req.response.close();
    });
    try {
      final LlmEngine engine = LlmEngine(
        config: _openAiCfg(server.port),
        maxRetries: 2,
        baseBackoffMs: 1,
        sleep: (Duration d) async => waits.add(d),
      );
      await expectLater(
        engine.generate(_genCfg(), _ctx()),
        throwsA(isA<LlmTransportException>()),
      );
      expect(hits, 1, reason: '401 不可重试');
      expect(waits, isEmpty);
    } finally {
      await server.close(force: true);
    }
  });

  test('共享 HttpClient 复用：两次生成只建一次连接', () async {
    final HttpServer server = await _startServer((req, body) async {
      await _writeSse(req, <String>['第一章。']);
    });
    int creations = 0;
    try {
      final LlmEngine engine = LlmEngine(
        config: _openAiCfg(server.port),
        maxRetries: 0,
        clientFactory: () {
          creations++;
          return HttpClient();
        },
      );
      await engine.generate(_genCfg(), _ctx());
      await engine.generate(_genCfg(), _ctx());
      expect(creations, 1, reason: '连接应被复用，而不是每次请求重建');
    } finally {
      await server.close(force: true);
    }
  });

  test('Ollama 分支：/api/chat + 行式 JSON message.content + 免鉴权', () async {
    String? authHeader;
    final HttpServer server = await _startServer((req, body) async {
      expect(req.uri.path, '/api/chat');
      authHeader = req.headers.value('authorization');
      expect(body['stream'], isTrue);
      expect(
        (body['options'] as Map<String, dynamic>)['num_predict'],
        greaterThan(0),
      );
      expect(body['max_tokens'], isNull, reason: 'Ollama 走 options.num_predict');
      req.response.headers.contentType = ContentType.json;
      req.response.write('${jsonEncode(<String, dynamic>{
            'message': <String, dynamic>{'content': '夜色'},
          })}\n');
      req.response.write('${jsonEncode(<String, dynamic>{
            'message': <String, dynamic>{'content': '如水。'},
          })}\n');
      req.response.write('${jsonEncode(<String, dynamic>{'done': true})}\n');
      await req.response.close();
    });
    try {
      final LlmEngine engine = LlmEngine(
        config: _ollamaCfg(server.port),
        maxRetries: 0,
      );
      final GenerationResult r = await engine.generate(_genCfg(), _ctx());
      expect(r.content, '夜色如水。');
      expect(authHeader, isNull, reason: '本地 Ollama 不应带 Authorization');
    } finally {
      await server.close(force: true);
    }
  });

  test('大纲扩写无效 → 回退原大纲，正文仍带原始大纲生成', () async {
    final List<String> userMsgs = <String>[];
    const String rawOutline = '一、主角在宗门大比落败；二、觉醒剑魂。';
    final HttpServer server = await _startServer((req, body) async {
      final List<dynamic> messages = body['messages'] as List<dynamic>;
      final String user = messages.last['content'] as String;
      userMsgs.add(user);
      if (user.contains('请扩写成场景序列')) {
        // 扩写请求：返回比原大纲更短的无效结果 → 引擎应回退。
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{'content': '太短'},
            },
          ],
        }));
        await req.response.close();
        return;
      }
      await _writeSse(req, <String>['按原大纲写。']);
    });
    try {
      final LlmEngine engine = LlmEngine(
        config: _openAiCfg(server.port),
        maxRetries: 0,
      );
      final GenerationResult r = await engine.generate(
        _genCfg(expandOutline: true),
        _ctx(outline: rawOutline),
      );
      expect(r.content, '按原大纲写。');
      expect(userMsgs.last, contains('宗门大比落败'), reason: '正文简报应保留原始大纲');
      expect(userMsgs.length, 2, reason: '扩写 + 正文共两次请求');
    } finally {
      await server.close(force: true);
    }
  });
}
