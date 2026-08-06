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

  /// 是否已配置上报。
  bool get enabled => uploadUrl.trim().isNotEmpty;

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
    throw const CrashReportException('未配置上报 URL');
  }
  final File file = File('${crashDir.path}${Platform.pathSeparator}$fileName');
  if (!await file.exists()) {
    throw const CrashReportException('日志文件不存在');
  }
  final String content = await file.readAsString();
  final HttpClient client = HttpClient()..connectionTimeout =
      const Duration(seconds: 5);
  try {
    final HttpClientRequest request = await client
        .postUrl(Uri.parse(config.uploadUrl))
        .timeout(const Duration(seconds: 5));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.userAgentHeader, 'MojiangInkSmith/0.1');
    request.write(
      jsonEncode(<String, dynamic>{
        'machineId': machineId,
        'version': '0.1.0',
        'file': fileName,
        'content': content,
        'uploadedAt': DateTime.now().toIso8601String(),
      }),
    );
    final HttpClientResponse response = await request.close()
        .timeout(const Duration(seconds: 5));
    final int status = response.statusCode;
    // 读完响应体再判断，避免连接泄漏。
    await response.drain<void>().timeout(const Duration(seconds: 5));
    if (status >= 200 && status < 300) return true;
    throw CrashReportException('服务器返回 HTTP $status');
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
