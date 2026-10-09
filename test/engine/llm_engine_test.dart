import 'dart:async';
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

import '../support/fake_http.dart';

/// LlmEngine 单元测试：本地 loopback HttpServer 模拟 LLM 端点（零外部依赖），
/// 外加 `test/support/fake_http.dart` 的假 HTTP 栈（TLS/流错误/超时等
/// 真实网络难以稳定复现的分支）。
///
/// 覆盖：未配置即抛 / OpenAI SSE 流式拼接与进度 / reasoning 思考链 /
/// 429 退避重试 / 401 不重试 / 共享 HttpClient 复用 /
/// Ollama 分支 / 大纲扩写成功与失败回退 / 取消 / 整体超时 /
/// 流中途错误分类 / 端点规范化 / 思考链抑制开关。

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

ContextBundle _ctx({
  String outline = '',
  List<Character> characters = const <Character>[],
  String plotSummary = '',
}) =>
    ContextBundle(
      characters: characters,
      worldSettings: const <WorldSetting>[],
      genrePreset: GenrePresets.get('xuanhuan'),
      plotSkeleton: PlotSkeleton.forGenre('xuanhuan'),
      outline: outline,
      plotSummary: plotSummary,
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

  group('取消 / 超时 / 流中途错误（假 HTTP 栈）', () {
    test('生成前已取消 → 抛 GenerationCancelledException 且一个请求都不发', () async {
      final FakeHttpClient client = FakeHttpClient(
        respond: (FakeHttpRequest request, Uri url) async => FakeHttpResponse(),
      );
      final LlmEngine engine = LlmEngine(
        config: _openAiCfg(1),
        clientFactory: () => client,
      );
      // 带大纲 + expandOutline：验证「取消签名先注册、扩写被跳过」这条路径
      // （旧实现的注册在扩写之后，取消要等 30s 扩写超时才生效）。
      final CancelToken token = CancelToken()..cancel();
      await expectLater(
        engine.generate(
          _genCfg(expandOutline: true),
          _ctx(outline: '一、主角在宗门大比落败。'),
          cancelToken: token,
        ),
        throwsA(isA<GenerationCancelledException>()),
      );
      expect(client.requestUrls, isEmpty, reason: '已取消不应发出任何请求');
    });

    test('整体超时：中断底层连接并抛带时长的 EngineException', () async {
      final StreamController<List<int>> hanging = StreamController<List<int>>();
      final FakeHttpClient client = FakeHttpClient(
        respond: (FakeHttpRequest request, Uri url) async =>
            FakeHttpResponse(rawStream: hanging.stream),
      );
      final LlmEngine engine = LlmEngine(
        config: _openAiCfg(1),
        timeout: const Duration(milliseconds: 120),
        maxRetries: 0,
        clientFactory: () => client,
      );
      await expectLater(
        engine.generate(_genCfg(), _ctx()),
        throwsA(
          isA<EngineException>().having(
            (EngineException e) => e.message,
            'message',
            contains('AI 生成超时'),
          ),
        ),
      );
      expect(client.closed, isTrue,
          reason: '超时必须强断底层连接，否则请求悬挂、连接泄漏');
      expect(engine.config.isConfigured, isTrue);
      await hanging.close();
    });

    /// 让响应流以 [error] 结束，断言被分类成的异常满足 [matcher]。
    Future<void> expectClassified(Object error, Matcher matcher) async {
      final FakeHttpClient client = FakeHttpClient(
        respond: (FakeHttpRequest request, Uri url) async =>
            FakeHttpResponse(streamError: error),
      );
      final LlmEngine engine = LlmEngine(
        config: _openAiCfg(1),
        maxRetries: 0,
        clientFactory: () => client,
      );
      await expectLater(engine.generate(_genCfg(), _ctx()), throwsA(matcher));
    }

    test('流中途错误分类：超时 / TLS / 401 / 403 / 429 / 500', () async {
      await expectClassified(
        Exception('TimeoutException: 请求超时'),
        isA<EngineException>().having((EngineException e) => e.message, 'message',
            contains('AI 请求超时')),
      );
      await expectClassified(
        Exception('HandshakeException: certificate verify failed'),
        isA<EngineException>().having((EngineException e) => e.message, 'message',
            contains('TLS 证书验证失败')),
      );
      await expectClassified(
        Exception('HTTP 401 Unauthorized'),
        isA<EngineException>().having((EngineException e) => e.message, 'message',
            contains('API 密钥无效（401）')),
      );
      await expectClassified(
        Exception('HTTP 403 Forbidden'),
        isA<EngineException>().having((EngineException e) => e.message, 'message',
            contains('访问被拒绝（403）')),
      );
      await expectClassified(
        Exception('HTTP 429 rate limit exceeded'),
        isA<EngineException>().having((EngineException e) => e.message, 'message',
            contains('请求频率过高（429）')),
      );
      await expectClassified(
        Exception('HTTP 503 Service Unavailable'),
        isA<EngineException>().having((EngineException e) => e.message, 'message',
            contains('AI 服务暂时不可用')),
      );
    });

    test('流中途错误分类：传输异常透传原因 / 取消原样抛 / 未知错误兜底', () async {
      const LlmTransportException transport =
          LlmTransportException('自定义传输错误', cause: 'raw');
      await expectClassified(
        transport,
        isA<EngineException>()
            .having((EngineException e) => e.message, 'message', '自定义传输错误')
            .having((EngineException e) => e.cause, 'cause', 'raw'),
      );
      await expectClassified(
        const GenerationCancelledException(),
        isA<GenerationCancelledException>(),
      );
      await expectClassified(
        Exception('boom'),
        isA<EngineException>().having((EngineException e) => e.message, 'message',
            startsWith('LLM 服务异常')),
      );
    });
  });

  group('大纲扩写', () {
    test('扩写成功：扩写文本替换正文大纲，主角/角色/前情进入扩写请求', () async {
      const String rawOutline = '一、主角在宗门大比落败；二、觉醒剑魂。';
      final String expanded = List<String>.filled(
              6, '场景 N：擂台落败\n- 地点：宗门擂台\n- 事件：当众受辱')
          .join('\n');
      final List<String> expandUsers = <String>[];
      final List<String> mainUsers = <String>[];
      final HttpServer server = await _startServer((req, body) async {
        final List<dynamic> messages = body['messages'] as List<dynamic>;
        final String user = messages.last['content'] as String;
        if (user.contains('请扩写成场景序列')) {
          expandUsers.add(user);
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': expanded},
              },
            ],
          }));
          await req.response.close();
          return;
        }
        mainUsers.add(user);
        await _writeSse(req, <String>['按扩写好的场景写。']);
      });
      try {
        final LlmEngine engine = LlmEngine(
          config: _openAiCfg(server.port),
          maxRetries: 0,
        );
        const Character chen = Character(
          id: 'c1',
          novelId: 'n1',
          name: '陈渊',
          role: '主角',
          traits: '隐忍',
          background: '',
          relationships: '',
        );
        final GenerationResult r = await engine.generate(
          const GenerationConfig(
            genre: '玄幻',
            tone: '热血',
            targetWords: 2000,
            protagonistName: '陈渊',
            expandOutline: true,
            constraints: GenerationConstraints(maxWordsPerChapter: 20000),
          ),
          _ctx(
            outline: rawOutline,
            characters: const <Character>[chen],
            plotSummary: '上一章：陈渊被逐出家门。',
          ),
        );
        expect(r.content, '按扩写好的场景写。');
        expect(expandUsers, hasLength(1));
        expect(expandUsers.single, contains('【主角】陈渊'));
        expect(expandUsers.single, contains('【主要角色】'));
        expect(expandUsers.single, contains('陈渊（主角）：隐忍'));
        expect(expandUsers.single, contains('【前情提要】'));
        expect(expandUsers.single, contains('陈渊被逐出家门'));
        expect(mainUsers, hasLength(1));
        expect(mainUsers.single, contains('场景 N：擂台落败'),
            reason: '扩写结果应替换正文简报里的大纲');
        expect(mainUsers.single, isNot(contains('一、主角在宗门大比落败')),
            reason: '扩写成功时不应再注入原始大纲');
      } finally {
        await server.close(force: true);
      }
    });

    test('扩写返回时用户已取消 → 回退原大纲并抛取消，不再发正文请求', () async {
      const String rawOutline = '一、主角落败；二、觉醒。';
      final Completer<void> expandSeen = Completer<void>();
      final Completer<void> releaseExpand = Completer<void>();
      int mainRequests = 0;
      final HttpServer server = await _startServer((req, body) async {
        final List<dynamic> messages = body['messages'] as List<dynamic>;
        final String user = messages.last['content'] as String;
        if (user.contains('请扩写成场景序列')) {
          if (!expandSeen.isCompleted) expandSeen.complete();
          await releaseExpand.future;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content':
                      List<String>.filled(8, '场景 1：长文本扩写内容').join('\n'),
                },
              },
            ],
          }));
          await req.response.close();
          return;
        }
        mainRequests++;
        await _writeSse(req, <String>['不应到达。']);
      });
      try {
        final LlmEngine engine = LlmEngine(
          config: _openAiCfg(server.port),
          maxRetries: 0,
        );
        final CancelToken token = CancelToken();
        final Future<GenerationResult> pending = engine.generate(
          _genCfg(expandOutline: true),
          _ctx(outline: rawOutline),
          cancelToken: token,
        );
        await expandSeen.future;
        token.cancel();
        releaseExpand.complete();
        await expectLater(pending, throwsA(isA<GenerationCancelledException>()));
        expect(mainRequests, 0, reason: '取消后不得再发正文请求');
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('重试进度与端点规范化', () {
    test('退避重试时向 UI 回报等待时长（onRetry → 进度阶段）', () async {
      int hits = 0;
      final FakeHttpClient client = FakeHttpClient(
        respond: (FakeHttpRequest request, Uri url) async {
          hits++;
          if (hits == 1) return FakeHttpResponse(statusCode: 503);
          return FakeHttpResponse(
            body: utf8.encode('${_sse('重试后正文。')}data: [DONE]\n\n'),
          );
        },
      );
      final LlmEngine engine = LlmEngine(
        config: _openAiCfg(1),
        maxRetries: 1,
        baseBackoffMs: 1,
        sleep: (Duration d) async {},
        clientFactory: () => client,
      );
      final List<GenerationProgress> progress = <GenerationProgress>[];
      final GenerationResult r =
          await engine.generate(_genCfg(), _ctx(), onProgress: progress.add);
      expect(r.content, '重试后正文。');
      expect(hits, 2);
      expect(
        progress.map((GenerationProgress p) => p.stage).join('|'),
        contains('重试'),
        reason: '重试等待应回报给 UI，否则用户只看到卡住',
      );
    });

    test('端点末尾斜杠被规范化；SensNova 类模型附带 options.Thinking=false', () async {
      final HttpServer server = await _startServer((req, body) async {
        expect(req.uri.path, '/v1/chat/completions',
            reason: 'baseUrl 末尾斜杠不应产生 //chat/completions');
        expect(
          (body['options'] as Map<String, dynamic>)['Thinking'],
          isFalse,
          reason: '需双层关闭思考链的模型必须带 options.Thinking',
        );
        expect(
          (body['chat_template_kwargs'] as Map<String, dynamic>)[
              'enable_thinking'],
          isFalse,
        );
        await _writeSse(req, <String>['正文。']);
      });
      try {
        final LlmEngine engine = LlmEngine(
          config: LlmConfig(
            provider: LlmProvider.openaiCompatible,
            model: 'SenseNova-V6',
            apiKey: 'sk-test',
            baseUrl: 'http://127.0.0.1:${server.port}/v1/',
          ),
          maxRetries: 0,
        );
        final GenerationResult r = await engine.generate(_genCfg(), _ctx());
        expect(r.content, '正文。');
      } finally {
        await server.close(force: true);
      }
    });
  });
}
