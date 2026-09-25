import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/engine/llm_engine.dart';
import 'package:novel_writer/engine/template_engine.dart';
import 'package:novel_writer/models/reader_settings.dart';
import 'package:novel_writer/storage/app_database.dart';

/// DI 容器装配测试（providers.dart）。
///
/// 覆盖：默认主题、未注入数据库的防误用护栏、各仓库/服务构造、
/// 引擎随 useLlm 开关切换、阅读设置落盘-回读、两个 ViewModel 构造。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('providers_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  /// 构造注入了临时目录数据库的容器（替代 main() 里的启动注入）。
  ProviderContainer makeContainer() {
    final ProviderContainer c = ProviderContainer(overrides: <Override>[
      appDatabaseProvider.overrideWithValue(
        AppDatabase.initForTest(tempDir.path),
      ),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  group('全局基础 provider', () {
    test('themeModeProvider 默认跟随系统', () {
      final ProviderContainer c = makeContainer();
      expect(c.read(themeModeProvider), ThemeMode.system);
    });

    test('appDatabaseProvider 未注入时抛 UnimplementedError（防误用护栏）', () {
      final ProviderContainer c = ProviderContainer();
      addTearDown(c.dispose);
      expect(() => c.read(appDatabaseProvider), throwsUnimplementedError);
    });
  });

  group('仓库与服务装配', () {
    test('注入数据库后各仓库/服务均可构造', () {
      final ProviderContainer c = makeContainer();
      expect(c.read(novelRepositoryProvider), isNotNull);
      expect(c.read(chapterRepositoryProvider), isNotNull);
      expect(c.read(settingRepositoryProvider), isNotNull);
      expect(c.read(goalRepositoryProvider), isNotNull);
      expect(c.read(chapterSnapshotServiceProvider), isNotNull);
      expect(c.read(sensitiveWordsProvider), isNotNull);
    });
  });

  /// 各 Controller 构造时都会异步 `_load()` 一次（读旧配置）；
  /// 变更前先等这一拍落定，否则随后的写入会被初始加载覆盖。
  Future<void> settleInitialLoad() =>
      Future<void>.delayed(const Duration(milliseconds: 150));

  group('引擎切换', () {
    test('默认模板引擎，useLlm 打开后切到 LlmEngine', () async {
      final ProviderContainer c = makeContainer();
      expect(c.read(generationEngineProvider), isA<TemplateEngine>());
      expect(c.read(useLlmProvider), isFalse);
      await settleInitialLoad();

      await c.read(llmSettingsProvider.notifier).setUseLlm(true);

      expect(c.read(useLlmProvider), isTrue);
      expect(c.read(generationEngineProvider), isA<LlmEngine>());

      await c.read(llmSettingsProvider.notifier).setUseLlm(false);
      expect(c.read(generationEngineProvider), isA<TemplateEngine>());
    });
  });

  group('阅读设置', () {
    test('默认值为兜底常量，update 后状态即变', () async {
      final ProviderContainer c = makeContainer();
      final ReaderSettings before = c.read(readerSettingsProvider);
      expect(before.fontSize, 18);
      await settleInitialLoad();

      await c
          .read(readerSettingsProvider.notifier)
          .update(before.copyWith(fontSize: 22));
      expect(c.read(readerSettingsProvider).fontSize, 22);
    });

    test('落盘后新容器可回读（load/save 回环）', () async {
      final ProviderContainer c1 = makeContainer();
      c1.read(readerSettingsProvider); // 触发控制器创建
      await settleInitialLoad();
      await c1
          .read(readerSettingsProvider.notifier)
          .update(c1.read(readerSettingsProvider).copyWith(fontSize: 23));

      final ProviderContainer c2 = makeContainer();
      // _load 是构造函数里的异步拉取：轮询等待读到落盘值。
      for (int i = 0; i < 40; i++) {
        if (c2.read(readerSettingsProvider).fontSize == 23) return;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      fail('新容器 1s 内未加载到落盘的阅读设置');
    });

    test('应用主题切换后新容器可回读', () async {
      final ProviderContainer c1 = makeContainer();
      c1.read(themeModeProvider);
      await settleInitialLoad();
      await c1
          .read(readerSettingsProvider.notifier)
          .setAppTheme(AppThemeMode.dark);

      final ProviderContainer c2 = makeContainer();
      for (int i = 0; i < 40; i++) {
        if (c2.read(themeModeProvider) == ThemeMode.dark) return;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      fail('新容器 1s 内未加载到落盘的应用主题');
    });
  });

  group('ViewModel 装配', () {
    test('projectListViewModelProvider / generateViewModelProvider 可构造', () {
      final ProviderContainer c = makeContainer();
      expect(c.read(projectListViewModelProvider), isNotNull);
      expect(c.read(generateViewModelProvider('n1')), isNotNull);
    });
  });
}
