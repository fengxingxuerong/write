import 'package:flutter/material.dart';

/// 应用主题（Material 3）。
///
/// 提供浅色与深色两套主题，种子色统一为紫色，跟随系统明暗模式。
class AppTheme {
  /// 私有构造，禁止实例化。
  const AppTheme._();

  /// 主题种子色（M3 primary seed）。
  static const Color _seed = Color(0xFF6750A4);

  /// 浅色主题。
  static final ThemeData light = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.light,
    ),
    appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );

  /// 深色主题。
  static final ThemeData dark = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    ),
    appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
