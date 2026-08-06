import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/crash_reporter.dart';
import 'core/di/providers.dart';
import 'storage/app_database.dart';

/// 崩溃日志兜底。
///
/// 捕获三类错误（Zone 内未捕获异常 / 平台消息回调错误 / Flutter 渲染错误），
/// 追加写入 `<应用支持目录>/crash_logs/crash-YYYYMMDD-HHmmss.log`，
/// 便于发布后远程收集与本地排查。日志写失败时静默降级，不阻塞主流程。
///
/// 日志头部附带 machineId（设备标识）与应用版本，供远程崩溃聚合按设备/版本归类。
/// 若已配置上报 URL（crash_report_config.json），写日志后自动 POST 上报（失败静默）。
Future<void> main() async {
  // 绑定 Flutter 框架与底层平台通道，必须在异步操作前调用。
  WidgetsFlutterBinding.ensureInitialized();

  // 先准备日志目录（独立于 AppDatabase，避免数据库初始化失败时无日志可写）。
  final Directory supportDir = await AppDatabase.supportDirectory();
  final Directory crashDir = Directory(
    '${supportDir.path}${Platform.pathSeparator}crash_logs',
  );
  try {
    await crashDir.create(recursive: true);
  } catch (_) {
    // 目录创建失败时禁用崩溃日志（极罕见），不影响应用启动。
  }

  // 设备标识：首次运行生成并持久化到 <支持目录>/machine_id，之后复用。
  final String machineId = await _loadOrCreateMachineId(supportDir);

  // 上报配置（可能为空 = 不上报）。
  final CrashReporterConfig reporterConfig =
      await loadCrashReporterConfig(supportDir);

  runZonedGuarded(
    () async {
      try {
        // 初始化本地 JSON 存储目录（applicationSupportDirectory/novels）。
        final AppDatabase database = await AppDatabase.init();

        runApp(
          ProviderScope(
            overrides: [
              // appDatabaseProvider 在 providers.dart 中声明为「必须由外部注入」，
              // 此处用已初始化的实例覆盖默认值。
              appDatabaseProvider.overrideWithValue(database),
            ],
            child: const App(),
          ),
        );
      } catch (error, stack) {
        _writeCrashLog(
          crashDir,
          machineId,
          reporterConfig,
          '启动初始化',
          error,
          stack,
        );
        // 启动失败不直接退出，仍尝试进入 UI（数据库层有自愈/降级逻辑）。
        runApp(
          ProviderScope(
            overrides: [
              appDatabaseProvider.overrideWithValue(
                AppDatabase.fallback(),
              ),
            ],
            child: const App(),
          ),
        );
      }
    },
    // Zone 未捕获异常（异步错误兜底）。
    (error, stack) => _writeCrashLog(
      crashDir,
      machineId,
      reporterConfig,
      '异步异常',
      error,
      stack,
    ),
  );

  // 平台通道回调错误（如插件调用异常）。
  PlatformDispatcher.instance.onError = (error, stack) {
    _writeCrashLog(
      crashDir,
      machineId,
      reporterConfig,
      '平台回调',
      error,
      stack,
    );
    return true; // 已处理，不向 Flutter 上报崩溃
  };

  // Flutter 渲染/布局错误（ErrorWidget 替换前兜底）。
  FlutterError.onError = (FlutterErrorDetails details) {
    _writeCrashLog(
      crashDir,
      machineId,
      reporterConfig,
      'Flutter',
      details.exception,
      details.stack,
      details: details.toString(),
    );
  };
}

/// 读取或创建设备标识。
///
/// 文件：`<支持目录>/machine_id`，内容为 32 位十六进制随机串。
/// 读取失败/损坏时重新生成；写失败时返回内存随机值（不影响崩溃日志）。
Future<String> _loadOrCreateMachineId(Directory supportDir) async {
  final File file = File(
    '${supportDir.path}${Platform.pathSeparator}machine_id',
  );
  try {
    if (await file.exists()) {
      final String existing = (await file.readAsString()).trim();
      if (existing.length >= 16) return existing;
    }
  } catch (_) {
    // 读取失败则重新生成。
  }
  final String id = _randomHex(32);
  try {
    await file.writeAsString(id, flush: true);
  } catch (_) {
    // 写失败静默，改用内存值。
  }
  return id;
}

/// 生成 [length] 位十六进制随机串（基于 Random.secure）。
String _randomHex(int length) {
  final Random rng = Random.secure();
  final StringBuffer sb = StringBuffer();
  for (int i = 0; i < length; i++) {
    sb.write(rng.nextInt(16).toRadixString(16));
  }
  return sb.toString();
}

/// 追加写崩溃日志，单条日志 <= 64KB，写失败静默。
/// 写入成功后，若已配置上报 URL，异步触发远程上报（失败静默）。
void _writeCrashLog(
  Directory crashDir,
  String machineId,
  CrashReporterConfig reporterConfig,
  String kind,
  Object error,
  StackTrace? stack, {
  String? details,
}) {
  try {
    final DateTime now = DateTime.now();
    final String stamp = now
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final String fileName = 'crash-$stamp.log';
    final File file = File(
      '${crashDir.path}${Platform.pathSeparator}$fileName',
    );
    final StringBuffer sb = StringBuffer()
      ..writeln('===== 墨匠 InkSmith 崩溃日志 =====')
      ..writeln('time: $now')
      ..writeln('machineId: $machineId')
      ..writeln('kind: $kind')
      ..writeln('error: $error')
      ..writeln('stack:')
      ..writeln(stack?.toString() ?? '(no stack)');
    if (details != null) {
      sb
        ..writeln('details:')
        ..writeln(details);
    }
    // 防日志无限增长：超过 64KB 截断。
    final String content = sb.toString();
    file.writeAsStringSync(
      content.length > 65536 ? content.substring(0, 65536) : content,
      mode: FileMode.append,
      flush: true,
    );
    // 已配置上报 URL → 异步自动上报（失败静默，不阻塞）。
    if (reporterConfig.enabled) {
      unawaited(
        uploadCrashLog(
          crashDir: crashDir,
          fileName: fileName,
          config: reporterConfig,
          machineId: machineId,
        ).catchError((_) => false),
      );
    }
  } catch (_) {
    // 日志写失败静默降级。
  }
}
