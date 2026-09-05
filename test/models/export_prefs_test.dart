import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/models/export_prefs.dart';

/// ExportPrefs 模型单元测试
///
/// 覆盖：默认值、序列化/反序列化、copyWith、null 容错。

void main() {
  group('ExportPrefs 默认值', () {
    test('默认 includeSettings 为 true，lastFormat 为 null', () {
      const prefs = ExportPrefs();
      expect(prefs.includeSettings, isTrue);
      expect(prefs.lastFormat, isNull);
    });
  });

  group('ExportPrefs 序列化', () {
    test('toJson 包含 includeSettings', () {
      const prefs = ExportPrefs(includeSettings: false, lastFormat: 'epub');
      final json = prefs.toJson();
      expect(json['includeSettings'], false);
      expect(json['lastFormat'], 'epub');
    });

    test('toJson 不包含 null 的 lastFormat', () {
      const prefs = ExportPrefs(lastFormat: null);
      final json = prefs.toJson();
      expect(json.containsKey('lastFormat'), isFalse);
    });

    test('fromJson 完整字段', () {
      final json = {'includeSettings': false, 'lastFormat': 'docx'};
      final prefs = ExportPrefs.fromJson(json);
      expect(prefs.includeSettings, isFalse);
      expect(prefs.lastFormat, 'docx');
    });

    test('fromJson 缺失字段使用默认值', () {
      final prefs = ExportPrefs.fromJson(<String, dynamic>{});
      expect(prefs.includeSettings, isTrue);
      expect(prefs.lastFormat, isNull);
    });

    test('fromJson null 返回默认', () {
      final prefs = ExportPrefs.fromJson(null);
      expect(prefs.includeSettings, isTrue);
      expect(prefs.lastFormat, isNull);
    });

    test('toJson/fromJson 往返一致', () {
      const original = ExportPrefs(includeSettings: false, lastFormat: 'pdf');
      final restored = ExportPrefs.fromJson(original.toJson());
      expect(restored.includeSettings, original.includeSettings);
      expect(restored.lastFormat, original.lastFormat);
    });
  });

  group('ExportPrefs.copyWith', () {
    test('未传参返回等价副本', () {
      const original = ExportPrefs(lastFormat: 'epub');
      final copy = original.copyWith();
      expect(copy.includeSettings, original.includeSettings);
      expect(copy.lastFormat, original.lastFormat);
    });

    test('仅修改指定字段', () {
      const original = ExportPrefs();
      final copy = original.copyWith(includeSettings: false);
      expect(copy.includeSettings, isFalse);
      expect(copy.lastFormat, original.lastFormat);
    });
  });
}
