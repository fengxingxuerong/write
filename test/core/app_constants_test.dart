import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/app_constants.dart';

/// AppConstants 单元测试
///
/// 覆盖：countWords（CJK 每字计 1、连续 ASCII 词计 1、标点不计）、
/// safeFileName、timestamp 格式、关键常量。
void main() {
  group('AppConstants.countWords', () {
    test('空串为 0', () {
      expect(AppConstants.countWords(''), equals(0));
    });
    test('CJK 每字计 1', () {
      expect(AppConstants.countWords('中文测试'), equals(4));
    });
    test('连续 ASCII 字母/数字串计 1', () {
      expect(AppConstants.countWords('hello'), equals(1));
      expect(AppConstants.countWords('12345'), equals(1));
    });
    test('标点与空白不计', () {
      expect(AppConstants.countWords('，。 '), equals(0));
    });
    test('混合文本（CJK + 英文单词）', () {
      // 4 个汉字 + 1 个英文单词 = 5
      expect(AppConstants.countWords('主角光环 hero'), equals(5));
    });
  });

  group('AppConstants.safeFileName', () {
    test('去除非法字符并合并空白', () {
      expect(AppConstants.safeFileName('我的/小说*?'), equals('我的_小说__'));
      expect(AppConstants.safeFileName('  a  b  '), equals('a_b'));
    });
  });

  group('AppConstants.timestamp', () {
    test('格式为 yyyyMMdd_HHmmss', () {
      final ts = AppConstants.timestamp(DateTime(2026, 7, 31, 9, 5, 3));
      expect(ts, equals('20260731_090503'));
    });
  });

  group('AppConstants 常量', () {
    test('单章上限默认 20000', () {
      expect(AppConstants.defaultMaxWordsPerChapter, equals(20000));
    });
    test('自动保存防抖 3000ms', () {
      expect(AppConstants.autosaveDebounceMs, equals(3000));
    });
  });
}
