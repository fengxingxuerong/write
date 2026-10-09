import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/crash_reporter.dart';

import '../support/fake_http.dart';

/// uploadCrashLog **上传主体**测试（假 HTTP 栈：postUrl → write → close →
/// drain → 状态码判定 → 连接释放）。
///
/// 为什么单独成文件（2026-10-05）：此前整段主体因「只允许 HTTPS、测试环境
/// 起不了 HTTPS 服务」而零覆盖；假 HTTP 栈不放松 HTTPS 约束、不发真实请求
/// 即可全覆盖（`drained` / `client.closed` 断言证明真的跑过了主体）。
///
/// 与守卫的关系（scripts/test_fake_green_guard.py）：该守卫的判据是
/// 「用例名声称了**传 http:// 配置时**到不了的状态码分支」。本文件只用
/// https 配置 + 假栈，判据前提不成立，故按其文件级 skip 规则放行；
/// 「HTTP 地址被拒绝」类用例仍留在 crash_reporter_test.dart。
/// 守卫已扩展为扫描**所有**调用 uploadCrashLog 的测试文件——本文件在扫描
/// 范围内，不是被挪出视野。
void main() {
  late Directory tempDir;
  late Directory crashDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crash-upload-');
    crashDir = Directory('${tempDir.path}/crash_logs');
    crashDir.createSync(recursive: true);
  });

  tearDown(() async {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  const CrashReporterConfig config = CrashReporterConfig(
    uploadUrl: 'https://diagnostics.example.com/api/crash',
  );

  test('2xx：返回 true，载荷已脱敏，重定向关闭且连接被释放', () async {
    File('${crashDir.path}/crash-ok.log')
        .writeAsStringSync('apiKey: sk-abcdefgh12345678\nboom');
    bool drained = false;
    final FakeHttpClient client = FakeHttpClient(
      respond: (FakeHttpRequest request, Uri url) async =>
          FakeHttpResponse(onDrain: () => drained = true),
    );

    final bool ok = await withFakeHttpClient(
      client,
      () => uploadCrashLog(
        crashDir: crashDir,
        fileName: 'crash-ok.log',
        config: config,
        machineId: 'machine-xyz-123456789',
      ),
    );

    expect(ok, isTrue);
    expect(client.requestUrls.single.toString(),
        'https://diagnostics.example.com/api/crash');
    final FakeHttpRequest request = client.requests.single;
    expect(request.followRedirects, isFalse,
        reason: '禁止跟随重定向，防止把载荷带去其它主机');
    expect(request.headers.contentType?.mimeType, 'application/json');
    expect(request.headers.values['user-agent'], 'MojiangInkSmith/0.1');
    final Map<String, dynamic> payload =
        jsonDecode(request.bodyText) as Map<String, dynamic>;
    expect(payload['machineId'], '[redacted]');
    expect(payload['file'], 'crash-ok.log');
    expect(payload['version'], '0.1.0');
    expect(payload['content'], isNot(contains('sk-abcdefgh12345678')),
        reason: '上报内容必须脱敏后再发送');
    expect(drained, isTrue, reason: '必须先读完响应体再判状态码，避免连接泄漏');
    expect(client.closed, isTrue, reason: '上传结束后必须释放 client');
  });

  test('5xx：抛「服务器返回 HTTP 500」，且响应体已读完、连接已释放', () async {
    File('${crashDir.path}/crash-500.log').writeAsStringSync('boom');
    bool drained = false;
    final FakeHttpClient client = FakeHttpClient(
      respond: (FakeHttpRequest request, Uri url) async =>
          FakeHttpResponse(statusCode: 500, onDrain: () => drained = true),
    );

    await expectLater(
      withFakeHttpClient(
        client,
        () => uploadCrashLog(
          crashDir: crashDir,
          fileName: 'crash-500.log',
          config: config,
          machineId: 'm',
        ),
      ),
      throwsA(
        isA<CrashReportException>().having(
          (CrashReportException e) => e.message,
          'message',
          contains('HTTP 500'),
        ),
      ),
    );
    expect(drained, isTrue, reason: '失败响应体也要读完（连接可复用/释放）');
    expect(client.closed, isTrue);
  });

  test('连接层失败：包装为「上报失败」异常，且连接仍被释放', () async {
    File('${crashDir.path}/crash-net.log').writeAsStringSync('boom');
    final FakeHttpClient client = FakeHttpClient(
      respond: (FakeHttpRequest request, Uri url) async => FakeHttpResponse(),
      postError: const SocketException('Connection refused'),
    );

    await expectLater(
      withFakeHttpClient(
        client,
        () => uploadCrashLog(
          crashDir: crashDir,
          fileName: 'crash-net.log',
          config: config,
          machineId: 'm',
        ),
      ),
      throwsA(
        isA<CrashReportException>().having(
          (CrashReportException e) => e.message,
          'message',
          startsWith('上报失败'),
        ),
      ),
    );
    expect(client.closed, isTrue, reason: '发送失败也必须释放 client');
  });
}
