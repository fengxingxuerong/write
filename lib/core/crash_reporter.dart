import 'dart:convert';
import 'dart:io';

/// 崩溃日志远程上报。
///
/// 配置持久化在 `<应用支持目录>/crash_report_config.json`：
/// ```json
/// { "uploadUrl": "https://example.com/api/crash" }
/// ```
/// 上传时 POST JSON 到 uploadUrl，5 秒超时，失败静默（不阻塞主流程）。
class CrashReporterConfig {
  /// 构造配置。
  const CrashReporterConfig({this.uploadUrl = ''});

  /// 崩溃上报 URL（空 = 不上报）。
  final String uploadUrl;

  /// 是否已配置合法上报地址（远程诊断只允许 HTTPS）。
  bool get enabled => isValidUploadUrl(uploadUrl);

  /// 校验上报 URL：只允许 HTTPS、合法主机，且拒绝凭据/查询/片段。
  static bool isValidUploadUrl(String raw) {
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty) return false;
    if (uri.scheme.toLowerCase() != 'https') return false;
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return false;
    return true;
  }

  /// 从 JSON 解析（容错：缺字段/坏 JSON 回退空配置）。
  factory CrashReporterConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const CrashReporterConfig();
    return CrashReporterConfig(
      uploadUrl: (json['uploadUrl'] as String?) ?? '',
    );
  }

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{'uploadUrl': uploadUrl};

  /// 复制。
  CrashReporterConfig copyWith({String? uploadUrl}) =>
      CrashReporterConfig(uploadUrl: uploadUrl ?? this.uploadUrl);
}

/// 读取上报配置（文件不存在/损坏时返回空配置）。
Future<CrashReporterConfig> loadCrashReporterConfig(
  Directory supportDir,
) async {
  try {
    final File file = File(
      '${supportDir.path}${Platform.pathSeparator}crash_report_config.json',
    );
    if (!await file.exists()) return const CrashReporterConfig();
    final String raw = await file.readAsString();
    final dynamic decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return CrashReporterConfig.fromJson(decoded);
    }
  } catch (_) {}
  return const CrashReporterConfig();
}

/// 保存上报配置（写失败静默）。
Future<void> saveCrashReporterConfig(
  Directory supportDir,
  CrashReporterConfig config,
) async {
  try {
    final File file = File(
      '${supportDir.path}${Platform.pathSeparator}crash_report_config.json',
    );
    await file.writeAsString(
      jsonEncode(config.toJson()),
      flush: true,
    );
  } catch (_) {}
}

/// 同步版读取上报配置（供 Widget 测试 / 弹窗内使用，避免 FakeAsync 挂起）。
CrashReporterConfig loadCrashReporterConfigSync(Directory supportDir) {
  try {
    final File file = File(
      '${supportDir.path}${Platform.pathSeparator}crash_report_config.json',
    );
    if (!file.existsSync()) return const CrashReporterConfig();
    final dynamic decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      return CrashReporterConfig.fromJson(decoded);
    }
  } catch (_) {}
  return const CrashReporterConfig();
}

/// 同步版保存上报配置（写失败静默）。
void saveCrashReporterConfigSync(
  Directory supportDir,
  CrashReporterConfig config,
) {
  try {
    final File file = File(
      '${supportDir.path}${Platform.pathSeparator}crash_report_config.json',
    );
    file.writeAsStringSync(
      jsonEncode(config.toJson()),
      flush: true,
    );
  } catch (_) {}
}

/// 上报前脱敏崩溃内容：去掉设备标识、API Key、Bearer Token 和常见密码字段。
///
/// 本地日志仍保留原始内容，方便用户自行排查；只有远程上报使用脱敏副本。
String sanitizeCrashContent(String content) {
  String sanitized = content;
  // 先处理 Bearer，避免字段规则只吃掉 Bearer 而留下后面的 token。
  sanitized = sanitized.replaceAll(
    RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    'Bearer [redacted]',
  );
  sanitized = sanitized.replaceAllMapped(
    RegExp(
      r'''(["']?(api[_-]?key|authorization|token|password|secret)["']?\s*[:=]\s*["']?)([^"',\s}]+)''',
      caseSensitive: false,
    ),
    (Match match) => '${match.group(1)}[redacted]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'\b(sk|pk)-[A-Za-z0-9_-]{8,}\b', caseSensitive: false),
    '[redacted-key]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'^(\s*machineId\s*:\s*).*$', multiLine: true),
    r'$1[redacted]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'([a-z]:\\users\\)[^\\\r\n]+', caseSensitive: false),
    r'$1[redacted]',
  );
  return sanitized;
}

/// 上报请求的 JSON 载荷（公开以便单测直接断言，无需起 HTTPS 服务）。
///
/// 为什么要抽出来（2026-10-03）：
/// [uploadCrashLog] 只允许 HTTPS，而测试环境起 HTTPS 服务需要证书与
/// `HttpOverrides`，成本高且易脆。结果是整个上传主体（构造载荷、脱敏、
/// 状态码判定、异常转换）长期**零覆盖**，而 `crash_reporter_test.dart`
/// 里那个「服务器返回 500」的用例其实在 `!config.enabled` 处就抛异常了
/// ——它绿着，却一行都没跑到目标分支（典型的假绿）。
///
/// 把「与传输无关的纯逻辑」抽成可单测的函数，是让这段代码真正被测到的
/// 最小改动：不必起服务器，也不放松 HTTPS-only 的安全约束。
///
/// 本地日志保留原始内容，仅远程上报使用脱敏副本。
Map<String, dynamic> buildCrashPayload({
  required String machineId,
  required String version,
  required String fileName,
  required String content,
  DateTime? uploadedAt,
}) {
  return <String, dynamic>{
    // machineId 不回传：它用于本地聚合，上报无价值且是设备标识。
    'machineId': '[redacted]',
    'version': version,
    'file': fileName,
    'content': sanitizeCrashContent(content),
    'uploadedAt': (uploadedAt ?? DateTime.now()).toIso8601String(),
  };
}

/// 把 HTTP 状态码判定为「成功 / 失败消息」。
///
/// 2xx 视为已接受；其余一律失败并带上状态码，便于定位。
/// 返回 null 表示成功。
String? crashUploadFailureFor(int status) =>
    (status >= 200 && status < 300) ? null : '服务器返回 HTTP $status';

/// 上报一条崩溃日志。
///
/// 返回 true 表示服务器已接受（HTTP 2xx）；其它情况抛 [CrashReportException]。
/// 5 秒超时；任何网络/解析错误都转为异常，由调用方决定是否静默。
Future<bool> uploadCrashLog({
  required Directory crashDir,
  required String fileName,
  required CrashReporterConfig config,
  required String machineId,
}) async {
  if (!config.enabled) {
    throw CrashReportException(
      config.uploadUrl.trim().isEmpty
          ? '未配置上报 URL'
          : '崩溃上报仅允许 HTTPS URL',
    );
  }
  final Uri uploadUri = Uri.parse(config.uploadUrl.trim());
  final File file = File('${crashDir.path}${Platform.pathSeparator}$fileName');
  if (!await file.exists()) {
    throw const CrashReportException('日志文件不存在');
  }
  final String content = await file.readAsString();
  final HttpClient client = HttpClient()..connectionTimeout =
      const Duration(seconds: 5);
  try {
    final HttpClientRequest request = await client
        .postUrl(uploadUri)
        .timeout(const Duration(seconds: 5));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.userAgentHeader, 'MojiangInkSmith/0.1');
    request.write(
      jsonEncode(buildCrashPayload(
        machineId: machineId,
        version: '0.1.0',
        fileName: fileName,
        content: content,
      )),
    );
    final HttpClientResponse response = await request.close()
        .timeout(const Duration(seconds: 5));
    final int status = response.statusCode;
    // 读完响应体再判断，避免连接泄漏。
    await response.drain<void>().timeout(const Duration(seconds: 5));
    final String? failure = crashUploadFailureFor(status);
    if (failure == null) return true;
    throw CrashReportException(failure);
  } on CrashReportException {
    rethrow;
  } catch (e) {
    throw CrashReportException('上报失败：$e');
  } finally {
    client.close(force: true);
  }
}

/// 崩溃上报异常。
class CrashReportException implements Exception {
  /// 构造异常。
  const CrashReportException(this.message);

  /// 错误信息。
  final String message;

  @override
  String toString() => 'CrashReportException: $message';
}
