import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/di/providers.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

/// 应用根组件。
///
/// 挂载 [ProviderScope]（由 main.dart 提供）与 [GoRouter] 路由，
/// 统一使用 Material 3 主题，并跟随系统明暗模式。
class App extends ConsumerWidget {
  /// 构造根组件。
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GoRouter router = ref.watch(routerProvider);
    final ThemeMode themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: '墨匠 InkSmith',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
