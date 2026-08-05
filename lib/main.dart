import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/di/providers.dart';
import 'storage/app_database.dart';

/// 崩溃日志兜底。
///
/// 捕获三类错误（Zone 内未捕获异常 / 平台消息回调错误 / Flutter 渲染错误），
/// 追加写入 `<应用支持目录>/crash_logs/crash-YYYYMMDD-HHmmss.log`，
/// 便于发布后远程收集与本地排查。日志写失败时静默降级，不阻塞主流程。
Future<void> main() async {
  // 绑定 Flutter 框架与底层平台通道，必须在异步操作前调用。
  WidgetsFlutterBinding.ensureInitialized();

  // 先准备日志目录（独立于 AppDatabase，避免数据库初始化失败时无日志可写）。
  final Directory supportDir =
      await AppDatabase.supportDirectory();
  final Directory crashDir = Directory(
    '${supportDir.path}${Platform.pathSeparator}crash_logs',
  );
  try {
    await crashDir.create(recursive: true);
  } catch (_) {
    // 目录创建失败时禁用崩溃日志（极罕见），不影响应用启动。
  }

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
        _writeCrashLog(crashDir, '启动初始化', error, stack);
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
    (error, stack) => _writeCrashLog(crashDir, '异步异常', error, stack),
  );

  // 平台通道回调错误（如插件调用异常）。
  PlatformDispatcher.instance.onError = (error, stack) {
    _writeCrashLog(crashDir, '平台回调', error, stack);
    return true; // 已处理，不向 Flutter 上报崩溃
  };

  // Flutter 渲染/布局错误（ErrorWidget 替换前兜底）。
  FlutterError.onError = (FlutterErrorDetails details) {
    _writeCrashLog(
      crashDir,
      'Flutter',
      details.exception,
      details.stack,
      details: details.toString(),
    );
  };
}

/// 追加写崩溃日志，单条日志 <= 64KB，写失败静默。
void _writeCrashLog(
  Directory crashDir,
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
    final File file = File(
      '${crashDir.path}${Platform.pathSeparator}crash-$stamp.log',
    );
    final StringBuffer sb = StringBuffer()
      ..writeln('===== 墨匠 InkSmith 崩溃日志 =====')
      ..writeln('time: $now')
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
  } catch (_) {
    // 日志写失败静默降级。
  }
}
