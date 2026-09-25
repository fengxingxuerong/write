import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/llm_chat_client.dart';
import 'package:novel_writer/engine/llm_retry.dart';
import 'package:novel_writer/models/llm_config.dart';

/// LlmChatClient 非流式请求/响应分支测试（本地 loopback 假端点，零外呼）。
void main() {
  const RetryPolicy instantSingle = RetryPolicy(
    maxAttempts: 1,
    baseBackoff: Duration.zero,
    sleep: _instant,
  );

  Future<HttpServer> startServer(
    Future<void> Function(HttpRequest req, Map<String, dynamic> body) handler,
  ) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest req) async {
      final String raw = await utf8.decoder.bind(req).join();
      final Map<String, dynamic> body = raw.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
      await handler(req, body);
    });
    return server;
  }

  LlmConfig openAiConfig(
    int port, {
    String model = 'fake-standard',
    int maxTokens = 8192,
  }) => LlmConfig(
    provider: LlmProvider.openaiCompatible,
    model: model,
    apiKey: 'sk-test',
    baseUrl: 'http://127.0.0.1:$port/v1',
    maxTokens: maxTokens,
  );

  test('未配置时 chat 立即抛 EngineException，不发起请求', () async {
    final LlmChatClient client = LlmChatClient(
      config: const LlmConfig(),
      retry: instantSingle,
    );
    await expectLater(
      client.chat('system', 'user'),
      throwsA(isA<EngineException>()),
    );
  });

  test('请求等待期间取消会立即关闭连接并抛取消异常', () async {
    final Completer<void> requestStarted = Completer<void>();
    final HttpServer server = await startServer((req, body) async {
      requestStarted.complete();
      await Future<void>.delayed(const Duration(seconds: 10));
    });
    bool cancelled = false;
    try {
      final LlmChatClient client = LlmChatClient(
        config: openAiConfig(server.port),
        retry: instantSingle,
        timeout: const Duration(seconds: 5),
      );
      final Future<LlmChatResult> pending = client.chat(
        'system',
        'user',
        isCancelled: () => cancelled,
      );
      await requestStarted.future;
      cancelled = true;
      await expectLater(
        pending,
        throwsA(isA<GenerationCancelledException>()),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('OpenAI 请求体：messages/温度/思考链开关/maxTokens 覆盖', () async {
    Map<String, dynamic>? captured;
    final HttpServer server = await startServer((req, body) async {
      captured = body;
      req.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': '正文'},
              },
            ],
          }),
        );
      await req.response.close();
    });
    try {
      final LlmChatClient client = LlmChatClient(
        config: openAiConfig(server.port, model: 'sensenova-test'),
        retry: instantSingle,
      );
      final LlmChatResult result = await client.chat(
        '系统提示',
        '用户输入',
        temperature: 0.35,
        maxTokens: 400,
      );

      expect(result.content, '正文');
      expect(captured!['model'], 'sensenova-test');
      expect(captured!['stream'], isFalse);
      expect(captured!['temperature'], 0.35);
      expect(captured!['max_tokens'], 400);
      final List<dynamic> messages = captured!['messages'] as List<dynamic>;
      expect(messages.first['role'], 'system');
      expect(messages.first['content'], '系统提示');
      expect(messages.last['role'], 'user');
      expect(messages.last['content'], '用户输入');
      expect(
        (captured!['chat_template_kwargs']
            as Map<String, dynamic>)['enable_thinking'],
        isFalse,
      );
      expect(
        (captured!['options'] as Map<String, dynamic>)['Thinking'],
        isFalse,
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('Ollama 请求体走 options.num_predict，且不带 max_tokens', () async {
    Map<String, dynamic>? captured;
    String? path;
    final HttpServer server = await startServer((req, body) async {
      path = req.uri.path;
      captured = body;
      req.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'message': <String, dynamic>{'content': '夜色如水。'},
          }),
        );
      await req.response.close();
    });
    try {
      final LlmChatClient client = LlmChatClient(
        config: LlmConfig(
          provider: LlmProvider.ollama,
          model: 'qwen2.5:7b',
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
        retry: instantSingle,
      );
      final LlmChatResult result = await client.chat('', '你好');
      expect(path, '/api/chat');
      expect(result.content, '夜色如水。');
      expect(
        (captured!['options'] as Map<String, dynamic>)['num_predict'],
        greaterThan(0),
      );
      expect(captured!['max_tokens'], isNull);
    } finally {
      await server.close(force: true);
    }
  });

  test('200 但响应体无法解析 → 抛 LlmTransportException', () async {
    final HttpServer server = await startServer((req, body) async {
      req.response
        ..headers.contentType = ContentType.json
        ..write('not-json{{{');
      await req.response.close();
    });
    try {
      final LlmChatClient client = LlmChatClient(
        config: openAiConfig(server.port),
        retry: instantSingle,
      );
      await expectLater(
        client.chat('s', 'u'),
        throwsA(
          isA<LlmTransportException>().having(
            (LlmTransportException e) => e.message,
            'message',
            contains('无法解析'),
          ),
        ),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('reasoning_content 独立字段保留，正文不混入思考链', () async {
    final HttpServer server = await startServer((req, body) async {
      req.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': '正文第一句。',
                  'reasoning_content': '先想结构',
                },
              },
            ],
          }),
        );
      await req.response.close();
    });
    try {
      final LlmChatClient client = LlmChatClient(
        config: openAiConfig(server.port),
        retry: instantSingle,
      );
      final LlmChatResult result = await client.chat('s', 'u');
      expect(result.content, '正文第一句。');
      expect(result.reasoning, '先想结构');
    } finally {
      await server.close(force: true);
    }
  });

  group('stripThinkingFromContent', () {
    final LlmChatClient client = LlmChatClient(
      config: const LlmConfig(model: 'sensenova-test'),
      retry: instantSingle,
    );

    test('开头 Thinking Process：剥离英文思考，只留中文正文', () {
      const String raw =
          'Thinking Process:\nstep one\nstep two\n\n中文正文第一句。\n中文正文第二句。';
      expect(client.stripThinkingFromContent(raw), '中文正文第一句。\n中文正文第二句。');
    });

    test('中文「思考过程」出现在中间：保留它之前的正文', () {
      const String raw = '正文第一句。\n思考过程\n一些推理\n更多推理';
      expect(client.stripThinkingFromContent(raw), '正文第一句。');
    });

    test('无思考链时仅 trim，不改正文', () {
      expect(client.stripThinkingFromContent('  正常正文。  '), '正常正文。');
      expect(client.stripThinkingFromContent(''), '');
    });
  });
}

Future<void> _instant(Duration _) async {}
