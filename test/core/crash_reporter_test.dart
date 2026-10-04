import 'dart:convert';
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
      final CrashReporterConfig config = CrashReporterConfig.fromJson(
        <String, dynamic>{},
      );
      expect(config.uploadUrl, isEmpty);
      expect(config.enabled, isFalse);
    });

    test('fromJson null 回退', () {
      final CrashReporterConfig config = CrashReporterConfig.fromJson(null);
      expect(config.uploadUrl, isEmpty);
    });

    test('toJson / fromJson 往返', () {
      const CrashReporterConfig config = CrashReporterConfig(
        uploadUrl: 'https://example.com/api/crash',
      );
      final CrashReporterConfig restored = CrashReporterConfig.fromJson(
        config.toJson(),
      );
      expect(restored.uploadUrl, 'https://example.com/api/crash');
      expect(restored.enabled, isTrue);
    });

    test('copyWith', () {
      const CrashReporterConfig config = CrashReporterConfig();
      final CrashReporterConfig next = config.copyWith(
        uploadUrl: 'https://x.com/crash',
      );
      expect(next.uploadUrl, 'https://x.com/crash');
      expect(next.enabled, isTrue);
      expect(config.uploadUrl, isEmpty); // 原对象不变
    });

    test('非 HTTPS 旧配置不会启用上报', () {
      const CrashReporterConfig config = CrashReporterConfig(
        uploadUrl: 'http://example.com/crash',
      );
      expect(config.enabled, isFalse);
    });
  });

  group('配置读写', () {
    test('无配置文件时返回空配置', () async {
      final CrashReporterConfig config = await loadCrashReporterConfig(
        supportDir,
      );
      expect(config.enabled, isFalse);
    });

    test('save + load 往返', () async {
      const CrashReporterConfig config = CrashReporterConfig(
        uploadUrl: 'https://s.example.com/crash',
      );
      await saveCrashReporterConfig(supportDir, config);
      final CrashReporterConfig loaded = await loadCrashReporterConfig(
        supportDir,
      );
      expect(loaded.uploadUrl, 'https://s.example.com/crash');
    });

    test('损坏 JSON 回退空配置', () async {
      File(
        '${supportDir.path}/crash_report_config.json',
      ).writeAsStringSync('not json {{{');
      final CrashReporterConfig loaded = await loadCrashReporterConfig(
        supportDir,
      );
      expect(loaded.enabled, isFalse);
    });
  });

  group('同步配置读写', () {
    test('文件不存在时同步读取返回空配置', () {
      final CrashReporterConfig config = loadCrashReporterConfigSync(
        supportDir,
      );
      expect(config.enabled, isFalse);
      expect(config.uploadUrl, isEmpty);
    });

    test('同步 save/load 往返一致', () {
      saveCrashReporterConfigSync(
        supportDir,
        const CrashReporterConfig(uploadUrl: 'https://sync.example.com/crash'),
      );
      final CrashReporterConfig loaded = loadCrashReporterConfigSync(
        supportDir,
      );
      expect(loaded.uploadUrl, 'https://sync.example.com/crash');
      expect(loaded.enabled, isTrue);
    });

    test('同步读取坏 JSON 或非对象时回退空配置', () {
      final File file = File('${supportDir.path}/crash_report_config.json');
      file.writeAsStringSync('not json {{');
      expect(loadCrashReporterConfigSync(supportDir).enabled, isFalse);

      file.writeAsStringSync('[1,2,3]');
      expect(loadCrashReporterConfigSync(supportDir).enabled, isFalse);
    });
  });

  group('崩溃上报脱敏', () {
    test('去掉设备标识、密钥、Bearer 和用户路径', () {
      const String raw = '''
machineId: machine-123456789
apiKey: sk-super-secret
Authorization: Bearer top-secret-token
path=C:\\Users\\Alice\\secret-project
''';
      final String safe = sanitizeCrashContent(raw);
      expect(safe, isNot(contains('machine-123456789')));
      expect(safe, isNot(contains('sk-super-secret')));
      expect(safe, isNot(contains('top-secret-token')));
      expect(safe, isNot(contains('Alice')));
      expect(safe, contains('[redacted]'));
    });
  });

  group('uploadCrashLog', () {
    test('未配置 URL 抛异常', () async {
      File('${crashDir.path}/crash-x.log').writeAsStringSync('test');
      await expectLater(
        uploadCrashLog(
          crashDir: crashDir,
          fileName: 'crash-x.log',
          config: const CrashReporterConfig(),
          machineId: 'abc',
        ),
        throwsA(
          isA<CrashReportException>().having(
            (CrashReportException e) => e.message,
            'message',
            contains('未配置上报 URL'),
          ),
        ),
      );
    });

    test('HTTP 地址被拒绝（不发送请求）', () async {
      // 守住「远程诊断只允许 HTTPS」这条安全约束：本机 HTTP 服务器必须
      // 收不到任何请求。注意本用例**测不到 500/2xx 处理**——
      // 状态码判定由 crashUploadFailureFor 的分项用例直接覆盖。
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
      await expectLater(
        uploadCrashLog(
          crashDir: crashDir,
          fileName: 'crash-http.log',
          config: CrashReporterConfig(
            uploadUrl: 'http://127.0.0.1:$port/api/crash',
          ),
          machineId: 'machine-123',
        ),
        throwsA(
          isA<CrashReportException>().having(
            (CrashReportException e) => e.message,
            'message',
            contains('仅允许 HTTPS'),
          ),
        ),
      );
      expect(received, isFalse, reason: 'HTTP 地址必须一个请求都不发');
    });

    test('非 HTTPS 协议被拒绝', () {
      expect(
        const CrashReporterConfig(uploadUrl: 'file:///tmp/crash').enabled,
        isFalse,
      );
      expect(
        const CrashReporterConfig(
          uploadUrl: 'https://example.com/crash?token=x',
        ).enabled,
        isFalse,
      );
    });

    test('HTTP 地址被拒绝：抛 HTTPS 约束异常（测不到 500 分支）', () async {
      // ⚠ **用例名已改名**（2026-10-03）：原名「服务器返回 500 抛异常」名不副实——
      // enabled 只允许 HTTPS，传 HTTP 会在第一道 `if (!config.enabled)` 抛异常，
      // 「500 处理」一行都没跑到，却绿着（典型假绿）。
      //
      // 现在：
      //  - 用例名如实描述它测的东西（HTTP 被拒）；
      //  - 异常消息断言到「仅允许 HTTPS」，防止将来有人放宽校验后此用例
      //    悄悄变成「别的异常也通过」；
      //  - 500/404 等状态码判定改由 crashUploadFailureFor 分项覆盖，
      //    不再依赖「起一个 HTTPS 服务器」这种做不到的事。
      final HttpServer server = await HttpServer.bind('127.0.0.1', 0);
      final int port = server.port;
      bool received = false;
      server.listen((HttpRequest req) async {
        received = true;
        req.response.statusCode = 500;
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));

      File('${crashDir.path}/crash-z.log').writeAsStringSync('test');
      await expectLater(
        uploadCrashLog(
          crashDir: crashDir,
          fileName: 'crash-z.log',
          config: CrashReporterConfig(
            uploadUrl: 'http://127.0.0.1:$port/api/crash',
          ),
          machineId: 'm',
        ),
        throwsA(
          isA<CrashReportException>().having(
            (CrashReportException e) => e.message,
            'message',
            contains('仅允许 HTTPS'),
          ),
        ),
      );
      expect(received, isFalse,
          reason: 'HTTP 地址必须一个请求都不发');
    });

    test('日志文件不存在抛异常', () async {
      // ⚠ 这里**必须用 HTTPS 地址**：uploadCrashLog 的判断顺序是
      // 「先校验 enabled，再检查文件是否存在」。若传 HTTP，会在第一道
      // 就抛「仅允许 HTTPS」，本用例声称的「文件不存在」分支根本没跑到
      // ——历史上正是这么写的（一个测不到目标分支的假绿用例）。
      //
      // 用不可路由的 HTTPS 主机即可：文件检查在发起连接**之前**，
      // 因此不会真的发请求，也不需要任何服务器。
      await expectLater(
        uploadCrashLog(
          crashDir: crashDir,
          fileName: 'nope.log',
          config: const CrashReporterConfig(
            uploadUrl: 'https://127.0.0.1:1/api/crash',
          ),
          machineId: 'm',
        ),
        throwsA(
          isA<CrashReportException>().having(
            (CrashReportException e) => e.message,
            'message',
            contains('日志文件不存在'),
          ),
        ),
      );
    });
  });
  // 2026-10-03 新增：把上传主体的**纯逻辑**从 HTTPS 传输里剥出来单独测。
  // 动机见 buildCrashPayload 的文档：uploadCrashLog 只允许 HTTPS，而测试起
  // HTTPS 服务需证书 + HttpOverrides，导致这段逻辑长期零覆盖，
  // 连带出现「用 HTTP 假装测了 500 处理」的假绿。
  group('buildCrashPayload（上报载荷）', () {
    test('machineId 一律脱敏，不回传设备标识', () {
      final Map<String, dynamic> payload = buildCrashPayload(
        machineId: 'machine-abc-0123456789',
        version: '0.1.0',
        fileName: 'crash-x.log',
        content: 'boom',
        uploadedAt: DateTime.utc(2026, 10, 3, 12),
      );
      expect(payload['machineId'], '[redacted]');
      expect(jsonEncode(payload), isNot(contains('machine-abc-0123456789')),
          reason: '设备标识不得出现在上报载荷里');
    });

    test('内容经脱敏后才进载荷（密钥/令牌/路径都不外泄）', () {
      final Map<String, dynamic> payload = buildCrashPayload(
        machineId: 'm',
        version: '0.1.0',
        fileName: 'c.log',
        content: 'apiKey: sk-abcdefgh12345678\n'
            'Authorization: Bearer tok-xyz-987\n'
            r'path=C:\Users\Alice\proj',
        uploadedAt: DateTime.utc(2026, 10, 3),
      );
      final String content = payload['content'] as String;
      expect(content, isNot(contains('sk-abcdefgh12345678')));
      expect(content, isNot(contains('tok-xyz-987')));
      expect(content, isNot(contains('Alice')));
      expect(content, contains('[redacted]'));
    });

    test('uploadedAt 为 ISO8601，可注入以便断言', () {
      final Map<String, dynamic> payload = buildCrashPayload(
        machineId: 'm',
        version: '9.9.9',
        fileName: 'c.log',
        content: 'x',
        uploadedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );
      expect(payload['uploadedAt'], '2026-01-02T03:04:05.000Z');
      expect(payload['version'], '9.9.9');
      expect(payload['file'], 'c.log');
    });

    test('不注入 uploadedAt 时自动取当前时间（不为空且可解析）', () {
      final Map<String, dynamic> payload = buildCrashPayload(
        machineId: 'm',
        version: '1',
        fileName: 'c.log',
        content: 'x',
      );
      final String stamp = payload['uploadedAt'] as String;
      expect(stamp, isNotEmpty);
      expect(DateTime.tryParse(stamp), isNotNull);
    });

    test('载荷可 JSON 序列化（上报走 jsonEncode）', () {
      final Map<String, dynamic> payload = buildCrashPayload(
        machineId: 'm',
        version: '1',
        fileName: 'c.log',
        content: '换行\n与"引号"',
        uploadedAt: DateTime.utc(2026, 10, 3),
      );
      final String encoded = jsonEncode(payload);
      final Map<String, dynamic> back =
          jsonDecode(encoded) as Map<String, dynamic>;
      expect(back['content'], '换行\n与"引号"');
    });
  });

  group('crashUploadFailureFor（状态码判定）', () {
    test('2xx 视为成功（返回 null）', () {
      for (final int code in <int>[200, 201, 202, 204, 299]) {
        expect(crashUploadFailureFor(code), isNull, reason: '$code 应视为成功');
      }
    });

    test('非 2xx 返回带状态码的失败消息', () {
      expect(crashUploadFailureFor(400), contains('400'));
      expect(crashUploadFailureFor(404), contains('404'));
      expect(crashUploadFailureFor(500), contains('500'));
      expect(crashUploadFailureFor(503), contains('503'));
    });

    test('边界：199 / 300 不算成功', () {
      expect(crashUploadFailureFor(199), isNotNull);
      expect(crashUploadFailureFor(300), isNotNull);
    });

    test('反向对照：判定确实依赖入参（非常量返回）', () {
      // 防「return null」这类恒真实现：同样条件下 200/500 必须给出不同结论。
      expect(crashUploadFailureFor(200), crashUploadFailureFor(201));
      expect(crashUploadFailureFor(200), isNot(crashUploadFailureFor(500)));
    });
  });

  group('CrashReportException', () {
    test('toString 含类型名与消息', () {
      const CrashReportException e =
          CrashReportException('服务器返回 HTTP 500');
      expect(e.toString(), contains('CrashReportException'));
      expect(e.toString(), contains('500'));
    });
  });
}