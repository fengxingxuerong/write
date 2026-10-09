import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/llm_http_errors.dart';

/// LlmHttpErrors 单元测试：HTTP 状态码 → 面向作者的中文文案、可重试标记
/// 与 Retry-After 解析；连接层错误的三分支分类。
///
/// 为什么值得钉住：这些文案会直接出现在 UI（SnackBar / 错误面板），
/// 「可重试」标记还会决定引擎是否退避重试——文案退化成「HTTP 500」
/// 或重试标记翻面，都是用户可感知的行为变化。
void main() {
  group('fromStatus：状态码文案', () {
    test('400 请求格式错误，带服务端正文摘要', () {
      final LlmTransportException e =
          LlmHttpErrors.fromStatus(400, '{"error":"bad request"}');
      expect(e.statusCode, 400);
      expect(e.retryable, isFalse);
      expect(e.message, contains('请求格式错误（400）'));
      expect(e.message, contains('bad request'));
    });

    test('401 密钥无效：不可重试，且不泄露服务端正文', () {
      final LlmTransportException e =
          LlmHttpErrors.fromStatus(401, 'secret gateway detail');
      expect(e.retryable, isFalse);
      expect(e.message, contains('API 密钥无效（401）'));
      expect(e.message, isNot(contains('secret gateway detail')));
    });

    test('403 权限/配额：带正文摘要，不可重试', () {
      final LlmTransportException e =
          LlmHttpErrors.fromStatus(403, 'quota exceeded');
      expect(e.retryable, isFalse);
      expect(e.message, contains('访问被拒绝（403）'));
      expect(e.message, contains('quota exceeded'));
    });

    test('404 地址不存在：不附带正文（提示看设置页）', () {
      final LlmTransportException e =
          LlmHttpErrors.fromStatus(404, 'nginx 404 page');
      expect(e.message, contains('API 地址不存在（404）'));
      expect(e.message, isNot(contains('nginx 404 page')));
    });

    test('408 超时：可重试', () {
      final LlmTransportException e = LlmHttpErrors.fromStatus(408, '');
      expect(e.retryable, isTrue);
      expect(e.message, contains('响应超时（408）'));
    });

    test('413 请求过长：不可重试（重试也是同样结果）', () {
      final LlmTransportException e = LlmHttpErrors.fromStatus(413, '');
      expect(e.retryable, isFalse);
      expect(e.message, contains('请求内容过长（413）'));
    });

    test('422 内容不被接受：不可重试', () {
      final LlmTransportException e =
          LlmHttpErrors.fromStatus(422, 'unprocessable');
      expect(e.retryable, isFalse);
      expect(e.message, contains('请求内容不被接受（422）'));
      expect(e.message, contains('unprocessable'));
    });

    test('429 并发已满：可重试 + Retry-After 秒数被解析', () {
      final LlmTransportException e = LlmHttpErrors.fromStatus(
        429,
        'model_concurrency_rate_limit_exceeded',
        retryAfterHeader: '3',
      );
      expect(e.retryable, isTrue);
      expect(e.message, contains('并发已满（429）'));
      expect(e.message, contains('model_concurrency_rate_limit_exceeded'));
      expect(e.retryAfter, const Duration(seconds: 3));
    });

    test('429 Retry-After 支持 HTTP-date（远期时间 → 正时长）', () {
      final LlmTransportException e = LlmHttpErrors.fromStatus(
        429,
        '',
        retryAfterHeader: 'Wed, 21 Oct 2099 07:28:00 GMT',
      );
      expect(e.retryAfter, isNotNull);
      expect(e.retryAfter!, greaterThan(Duration.zero));
    });

    test('500 / 502 / 503 / 504 各有关键文案且全部可重试', () {
      final Map<int, String> expectations = <int, String>{
        500: 'AI 服务暂时不可用（500）',
        502: '网关回源失败（502）',
        503: 'AI 服务过载（503）',
        504: '网关超时（504）',
      };
      expectations.forEach((int code, String fragment) {
        final LlmTransportException e = LlmHttpErrors.fromStatus(code, '');
        expect(e.statusCode, code);
        expect(e.retryable, isTrue, reason: '$code 应可重试');
        expect(e.message, contains(fragment));
      });
    });

    test('未枚举状态码回退为「HTTP <code>」，5xx 之外不可重试', () {
      final LlmTransportException e =
          LlmHttpErrors.fromStatus(418, 'I am a teapot');
      expect(e.statusCode, 418);
      expect(e.retryable, isFalse);
      expect(e.message, startsWith('HTTP 418'));
      expect(e.message, contains('I am a teapot'));
    });

    test('空正文不产生「：」悬空提示', () {
      expect(LlmHttpErrors.fromStatus(400, '').message, '请求格式错误（400）');
      expect(
          LlmHttpErrors.fromStatus(400, '   \n ').message, '请求格式错误（400）');
    });

    test('超长正文截断到 160 字并带省略号（不整页灌给作者）', () {
      final String long = 'x' * 400;
      final LlmTransportException e = LlmHttpErrors.fromStatus(422, long);
      expect(e.message, contains('${'x' * 160}…'));
      expect(e.message, isNot(contains('x' * 161)));
    });

    test('正文空白折叠为单空格（多行错误页压成一行）', () {
      final LlmTransportException e =
          LlmHttpErrors.fromStatus(400, 'line1\n\n  line2\tline3');
      expect(e.message, contains('line1 line2 line3'));
    });
  });

  group('transport：连接层错误分类', () {
    test('TLS/证书错误 → 证书提示（不可重试）', () {
      final LlmTransportException e = LlmHttpErrors.transport(
        const SocketException('HandshakeException: certificate verify failed'),
      );
      expect(e.message, contains('TLS 证书验证失败'));
      expect(e.retryable, isFalse);
      expect(e.statusCode, isNull);
      expect(e.cause, isNotNull);
    });

    test('域名解析失败 → 提示检查地址（可重试，不挂 cause 泄密）', () {
      final LlmTransportException e = LlmHttpErrors.transport(
        const SocketException('Failed host lookup: api.example.com'),
      );
      expect(e.message, contains('域名解析失败'));
      expect(e.retryable, isTrue);
      expect(e.cause, isNull);
    });

    test('其它连接错误 → 统一包装为可重试传输异常并保留 cause', () {
      const Object raw = SocketException('Connection refused');
      final LlmTransportException e = LlmHttpErrors.transport(raw);
      expect(e.message, startsWith('无法连接 AI 服务'));
      expect(e.retryable, isTrue);
      expect(e.cause, same(raw));
    });
  });

  group('retryable 谓词', () {
    test('仅 LlmTransportException 且 retryable=true 才算可重试', () {
      expect(
        LlmHttpErrors.retryable(
            const LlmTransportException('x', retryable: true)),
        isTrue,
      );
      expect(
        LlmHttpErrors.retryable(
            const LlmTransportException('x', retryable: false)),
        isFalse,
      );
      expect(LlmHttpErrors.retryable(const EngineException('bare')), isFalse);
      expect(LlmHttpErrors.retryable(StateError('boom')), isFalse);
    });
  });
}
