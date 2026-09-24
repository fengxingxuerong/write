import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/crash_reporter.dart';

void main() {

  late Directory tempDir;
  late Directory supportDir;
  late Directory crashDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crash-reporter-');
    supportDir = Directory('${tempDir.path}/support');
    supportDir.createSync(recursive: true);
    crashDir = Directory('${supportDir.path}/crash_logs');
    crashDir.createSync(recursive: true);
  });

  tearDown(() async {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('CrashReporterConfig', () {
    test('默认禁用', () {
      const CrashReporterConfig config = CrashReporterConfig();
      expect(config.enabled, isFalse);
      expect(config.uploadUrl, isEmpty);
    });

    test('fromJson 容错缺字段', () {
      final CrashReporterConfig config =
          CrashReporterConfig.fromJson(<String, dynamic>{});
      expect(config.uploadUrl, isEmpty);
      expect(config.enabled, isFalse);
    });

    test('fromJson null 回退', () {
      final CrashReporterConfig config = CrashReporterConfig.fromJson(null);
      expect(config.uploadUrl, isEmpty);
    });

    test('toJson / fromJson 往返', () {
      const CrashReporterConfig config =
          CrashReporterConfig(uploadUrl: 'https://example.com/api/crash');
      final CrashReporterConfig restored =
          CrashReporterConfig.fromJson(config.toJson());
      expect(restored.uploadUrl, 'https://example.com/api/crash');
      expect(restored.enabled, isTrue);
    });

    test('copyWith', () {
      const CrashReporterConfig config = CrashReporterConfig();
      final CrashReporterConfig next =
          config.copyWith(uploadUrl: 'https://x.com/crash');
      expect(next.uploadUrl, 'https://x.com/crash');
      expect(next.enabled, isTrue);
      expect(config.uploadUrl, isEmpty); // 原对象不变
    });

    test('非 HTTPS 旧配置不会启用上报', () {
      const CrashReporterConfig config =
          CrashReporterConfig(uploadUrl: 'http://example.com/crash');
      expect(config.enabled, isFalse);
    });
  });

  group('配置读写', () {
    test('无配置文件时返回空配置', () async {
      final CrashReporterConfig config =
          await loadCrashReporterConfig(supportDir);
      expect(config.enabled, isFalse);
    });

    test('save + load 往返', () async {
      const CrashReporterConfig config =
          CrashReporterConfig(uploadUrl: 'https://s.example.com/crash');
      await saveCrashReporterConfig(supportDir, config);
      final CrashReporterConfig loaded =
          await loadCrashReporterConfig(supportDir);
      expect(loaded.uploadUrl, 'https://s.example.com/crash');
    });

    test('损坏 JSON 回退空配置', () async {
      File('${supportDir.path}/crash_report_config.json')
          .writeAsStringSync('not json {{{');
      final CrashReporterConfig loaded =
          await loadCrashReporterConfig(supportDir);
      expect(loaded.enabled, isFalse);
    });
  });

  group('uploadCrashLog', () {
    test('未配置 URL 抛异常', () async {
      File('${crashDir.path}/crash-x.log').writeAsStringSync('test');
      expect(
        uploadCrashLog(
          crashDir: crashDir,
          fileName: 'crash-x.log',
          config: const CrashReporterConfig(),
          machineId: 'abc',
        ),
        throwsA(isA<CrashReportException>()),
      );
    });

    test('HTTP 地址被拒绝（不发送请求）', () async {
      // HTTP 不能用于远程诊断，即使目标是本机假服务器。
      final HttpServer server = await HttpServer.bind('127.0.0.1', 0);
      final int port = server.port;
      bool received = false;
      server.listen((HttpRequest req) async {
        received = true;
        req.response.statusCode = 200;
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));

      File('${crashDir.path}/crash-http.log').writeAsStringSync('boom');
      expect(
        uploadCrashLog(
          crashDir: crashDir,
          fileName: 'crash-http.log',
          config: CrashReporterConfig(
            uploadUrl: 'http://127.0.0.1:$port/api/crash',
          ),
          machineId: 'machine-123',
        ),
        throwsA(isA<CrashReportException>()),
      );
      expect(received, isFalse);
    });

    test('非 HTTPS 协议被拒绝', () {
      expect(
        const CrashReporterConfig(
          uploadUrl: 'file:///tmp/crash',
        ).enabled,
        isFalse,
      );
      expect(
        const CrashReporterConfig(
          uploadUrl: 'https://example.com/crash?token=x',
        ).enabled,
        isFalse,
      );
    });

    test('服务器返回 500 抛异常', () async {
      final HttpServer server = await HttpServer.bind('127.0.0.1', 0);
      final int port = server.port;
      server.listen((HttpRequest req) async {
        req.response.statusCode = 500;
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));

      File('${crashDir.path}/crash-z.log').writeAsStringSync('test');
      expect(
        uploadCrashLog(
          crashDir: crashDir,
          fileName: 'crash-z.log',
          config: CrashReporterConfig(
            uploadUrl: 'http://127.0.0.1:$port/api/crash',
          ),
          machineId: 'm',
        ),
        throwsA(isA<CrashReportException>()),
      );
    });

    test('日志文件不存在抛异常', () async {
      expect(
        uploadCrashLog(
          crashDir: crashDir,
          fileName: 'nope.log',
          config: const CrashReporterConfig(uploadUrl: 'http://127.0.0.1:1/x'),
          machineId: 'm',
        ),
        throwsA(isA<CrashReportException>()),
      );
    });
  });
}
