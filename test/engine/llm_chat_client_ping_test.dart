import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/llm_chat_client.dart';
import 'package:novel_writer/engine/llm_retry.dart';
import 'package:novel_writer/models/llm_config.dart';

/// LlmChatClient.ping 连接自检测试：本地 HttpServer 模拟 LLM 端点。
void main() {
  /// 启动一个假端点，按 [statusCode]/[content] 响应对 /chat/completions 的请求。
  Future<HttpServer> startServer({
    required int statusCode,
    required String content,
  }) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest req) async {
      await utf8.decoder.bind(req).join(); // 读完整请求体再响应。
      final String resp = jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{'content': content},
          },
        ],
      });
      req.response
        ..statusCode = statusCode
        ..headers.contentType = ContentType.json
        ..write(resp);
      await req.response.close();
    });
    return server;
  }

  LlmConfig cfgFor(int port) => LlmConfig(
        provider: LlmProvider.openaiCompatible,
        model: 'fake',
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:$port/v1',
      );

  // 单次尝试、瞬时退避（ping 测试不重试太久）。
  const RetryPolicy instantSingle = RetryPolicy(
    maxAttempts: 1,
    baseBackoff: Duration.zero,
    sleep: _instant,
  );

  test('200 + 非空正文 → ok，提示连接成功', () async {
    final HttpServer server =
        await startServer(statusCode: 200, content: '正常');
    try {
      final LlmChatClient client =
          LlmChatClient(config: cfgFor(server.port), retry: instantSingle);
      final LlmPingResult r = await client.ping();
      expect(r.ok, isTrue);
      expect(r.message, contains('连接成功'));
    } finally {
      await server.close(force: true);
    }
  });

  test('200 + 空正文 → ok（服务端接受，但提示未返回正文）', () async {
    final HttpServer server = await startServer(statusCode: 200, content: '');
    try {
      final LlmChatClient client =
          LlmChatClient(config: cfgFor(server.port), retry: instantSingle);
      final LlmPingResult r = await client.ping();
      expect(r.ok, isTrue);
      expect(r.message, contains('未返回正文'));
    } finally {
      await server.close(force: true);
    }
  });

  test('401 → 失败，提示密钥问题', () async {
    final HttpServer server = await startServer(statusCode: 401, content: 'bad key');
    try {
      final LlmChatClient client =
          LlmChatClient(config: cfgFor(server.port), retry: instantSingle);
      final LlmPingResult r = await client.ping();
      expect(r.ok, isFalse);
      expect(r.message, contains('401'));
      expect(r.message, contains('密钥'));
    } finally {
      await server.close(force: true);
    }
  });

  test('连不上（端口关闭）→ 失败，提示无法连接', () async {
    // 先绑定拿到端口再关闭，确保端口无人监听。
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = server.port;
    await server.close(force: true);
    final LlmChatClient client = LlmChatClient(
      config: cfgFor(port),
      retry: instantSingle,
      timeout: const Duration(seconds: 5),
    );
    final LlmPingResult r = await client.ping(timeout: const Duration(seconds: 5));
    expect(r.ok, isFalse);
    expect(r.message, anyOf(contains('无法连接'), contains('超时')));
  });

  test('未配置 → 立即失败，不发起请求', () async {
    final LlmChatClient client = LlmChatClient(
      config: const LlmConfig(), // 默认 Ollama 空 baseUrl → 未配置。
      retry: instantSingle,
    );
    final LlmPingResult r = await client.ping();
    expect(r.ok, isFalse);
    expect(r.message, contains('未配置'));
  });
}

Future<void> _instant(Duration _) async {}