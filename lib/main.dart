import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/di/providers.dart';
import 'storage/app_database.dart';

/// 应用入口。
///
/// 在 [runApp] 之前完成本地存储目录的初始化（[AppDatabase.init]），
/// 并将其实例通过 [appDatabaseProvider] 注入 [ProviderScope]，
/// 保证 Repository 层在任意位置都能拿到已就绪的数据库句柄。
Future<void> main() async {
  // 绑定 Flutter 框架与底层平台通道，必须在异步操作前调用。
  WidgetsFlutterBinding.ensureInitialized();

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
}
