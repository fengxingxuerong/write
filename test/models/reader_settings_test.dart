import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/models/reader_settings.dart';

/// ReaderSettings 模型 + ReaderSettingsRepository 单元测试
///
/// 覆盖：序列化/反序列化、copyWith、默认值、原子读写。

void main() {
  group('ReaderSettings 默认值', () {
    test('默认值为浅色主题/18号字/1.9行距/无衬线', () {
      const settings = ReaderSettings();
      expect(settings.theme, ReaderTheme.light);
      expect(settings.fontSize, 18);
      expect(settings.lineHeight, 1.9);
      expect(settings.serif, isFalse);
    });
  });

  group('ReaderSettings.copyWith', () {
    test('未传参返回等价副本', () {
      const original = ReaderSettings(fontSize: 20);
      final copy = original.copyWith();
      expect(copy.fontSize, 20);
      expect(copy.theme, original.theme);
      expect(copy.lineHeight, original.lineHeight);
      expect(copy.serif, original.serif);
    });

    test('仅修改指定字段', () {
      const original = ReaderSettings();
      final copy = original.copyWith(fontSize: 24, theme: ReaderTheme.dark);
      expect(copy.fontSize, 24);
      expect(copy.theme, ReaderTheme.dark);
      expect(copy.lineHeight, 1.9);
      expect(copy.serif, isFalse);
    });
  });

  group('ReaderSettings 序列化', () {
    test('toJson 包含所有字段', () {
      const settings = ReaderSettings(
        theme: ReaderTheme.sepia,
        fontSize: 22,
        lineHeight: 2.0,
        serif: true,
      );
      final json = settings.toJson();
      expect(json['theme'], 'sepia');
      expect(json['fontSize'], 22);
      expect(json['lineHeight'], 2.0);
      expect(json['serif'], true);
    });

    test('fromJson 完整字段', () {
      final json = {
        'theme': 'dark',
        'fontSize': 28.0,
        'lineHeight': 2.2,
        'serif': true,
      };
      final settings = ReaderSettings.fromJson(json);
      expect(settings.theme, ReaderTheme.dark);
      expect(settings.fontSize, 28);
      expect(settings.lineHeight, 2.2);
      expect(settings.serif, isTrue);
    });

    test('fromJson 缺失字段使用默认值', () {
      final settings = ReaderSettings.fromJson(<String, dynamic>{});
      expect(settings.theme, ReaderTheme.light);
      expect(settings.fontSize, 18);
      expect(settings.lineHeight, 1.9);
      expect(settings.serif, isFalse);
    });

    test('fromJson 兼容未知 theme', () {
      final settings = ReaderSettings.fromJson({'theme': 'unknown_theme'});
      expect(settings.theme, ReaderTheme.light);
    });

    test('toJson/fromJson 往返一致', () {
      const original = ReaderSettings(
        theme: ReaderTheme.dark,
        fontSize: 32,
        lineHeight: 2.4,
        serif: true,
      );
      final restored = ReaderSettings.fromJson(original.toJson());
      expect(restored.theme, original.theme);
      expect(restored.fontSize, original.fontSize);
      expect(restored.lineHeight, original.lineHeight);
      expect(restored.serif, original.serif);
    });
  });

  group('ReaderTheme 枚举', () {
    test('三个枚举值均存在', () {
      expect(ReaderTheme.values, contains(ReaderTheme.light));
      expect(ReaderTheme.values, contains(ReaderTheme.sepia));
      expect(ReaderTheme.values, contains(ReaderTheme.dark));
    });

    test('枚举 name 序列化正确', () {
      expect(ReaderTheme.light.name, 'light');
      expect(ReaderTheme.sepia.name, 'sepia');
      expect(ReaderTheme.dark.name, 'dark');
    });
  });

  group('ReaderSettingsRepository', () {
    late Directory tempDir;
    late ReaderSettingsRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('reader_settings_test_');
      repo = ReaderSettingsRepository(tempDir.path);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('load 文件不存在返回默认配置', () async {
      final settings = await repo.load();
      expect(settings.theme, ReaderTheme.light);
      expect(settings.fontSize, 18);
      expect(settings.lineHeight, 1.9);
      expect(settings.serif, isFalse);
    });

    test('save/load 往返一致', () async {
      const original = ReaderSettings(
        theme: ReaderTheme.dark,
        fontSize: 28,
        lineHeight: 2.2,
        serif: true,
      );
      await repo.save(original);
      final loaded = await repo.load();
      expect(loaded.theme, original.theme);
      expect(loaded.fontSize, original.fontSize);
      expect(loaded.lineHeight, original.lineHeight);
      expect(loaded.serif, original.serif);
    });

    test('save 是原子写（无 .tmp 残留）', () async {
      await repo.save(const ReaderSettings());
      final tmpFile = File('${tempDir.path}/app_settings.json.tmp');
      expect(tmpFile.existsSync(), isFalse);
      final targetFile = File('${tempDir.path}/app_settings.json');
      expect(targetFile.existsSync(), isTrue);
    });

    test('覆盖保存更新内容', () async {
      await repo.save(const ReaderSettings(fontSize: 16));
      await repo.save(const ReaderSettings(fontSize: 24));
      final loaded = await repo.load();
      expect(loaded.fontSize, 24);
    });
  });
}
