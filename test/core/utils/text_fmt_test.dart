import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/utils/text_fmt.dart';

void main() {
  final DateTime now = DateTime(2026, 9, 9, 14, 30);

  group('relativeTime', () {
    test('45 秒内算刚刚', () {
      expect(TextFmt.relativeTime(now.subtract(const Duration(seconds: 45)), now: now),
          '刚刚');
    });

    test('未来时间不写出「-3 分钟前」', () {
      expect(TextFmt.relativeTime(now.add(const Duration(minutes: 3)), now: now),
          '刚刚');
    });

    test('分钟 / 小时 / 天 的档位边界', () {
      expect(TextFmt.relativeTime(now.subtract(const Duration(minutes: 1)), now: now),
          '1 分钟前');
      expect(TextFmt.relativeTime(now.subtract(const Duration(minutes: 59, seconds: 59)), now: now),
          '59 分钟前');
      expect(TextFmt.relativeTime(now.subtract(const Duration(hours: 23, minutes: 59)), now: now),
          '23 小时前');
      expect(TextFmt.relativeTime(now.subtract(const Duration(days: 1)), now: now), '昨天');
      expect(TextFmt.relativeTime(now.subtract(const Duration(days: 2)), now: now), '前天');
      expect(TextFmt.relativeTime(now.subtract(const Duration(days: 7)), now: now), '7 天前');
      expect(TextFmt.relativeTime(now.subtract(const Duration(days: 8)), now: now),
          contains('月'));
    });

    test('跨年才带年份', () {
      expect(TextFmt.relativeTime(DateTime(2026, 1, 2), now: now), contains('1 月 2 日'));
      expect(TextFmt.relativeTime(DateTime(2025, 12, 31), now: now), contains('2025'));
    });
  });

  group('words', () {
    test('一万以内给精确值', () {
      expect(TextFmt.words(0), '0');
      expect(TextFmt.words(9999), '9999');
    });

    test('万以上用「万」并去掉多余的 0', () {
      expect(TextFmt.words(10000), '1 万');
      expect(TextFmt.words(12000), '1.2 万');
      expect(TextFmt.words(128400), '12.8 万');
      expect(TextFmt.words(45200), '4.52 万');
      expect(TextFmt.words(1200000), '120 万');
    });
  });

  group('数字与百分比', () {
    test('group 千分位', () {
      expect(TextFmt.group(0), '0');
      expect(TextFmt.group(999), '999');
      expect(TextFmt.group(1234567), '1,234,567');
      expect(TextFmt.group(-4321), '-4,321');
    });

    test('percent 四舍五入到整数，signed 才加正号', () {
      expect(TextFmt.percent(0.391), '39%');
      expect(TextFmt.percent(0.999), '100%');
      expect(TextFmt.percent(0.04), '4%');
      expect(TextFmt.percent(0.2, signed: true), '+20%');
      expect(TextFmt.percent(-0.2, signed: true), '-20%');
    });
  });

  group('duration', () {
    test('秒 / 分秒 / 时分 三档', () {
      expect(TextFmt.duration(const Duration(seconds: 5)), '5s');
      expect(TextFmt.duration(const Duration(seconds: 59)), '59s');
      expect(TextFmt.duration(const Duration(seconds: 65)), '1m05s');
      expect(TextFmt.duration(const Duration(seconds: 3725)), '1h02m');
    });
  });

  test('dateTime 固定补零', () {
    expect(TextFmt.dateTime(DateTime(2026, 3, 5, 7, 8)), '2026-03-05 07:08');
  });
}
