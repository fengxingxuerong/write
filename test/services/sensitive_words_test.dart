import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/services/sensitive_words.dart';

void main() {
  group('SensitiveWordsService 内置词库', () {
    test('命中内置暴力词并给出上下文', () {
      const String text = '他冷冷地说：别逼我动手，否则把你碎尸万段。';
      final SensitiveCheckResult r =
          SensitiveWordsService(customPath: null).check(text);
      expect(r.clean, isFalse);
      expect(r.hits.any((h) => h.word == '碎尸'), isTrue);
      expect(r.hits.first.context, contains('碎尸'));
    });

    test('干净文本无命中', () {
      const String text = '清晨的阳光洒在窗台上，他端起茶杯，开始新的一天。';
      final SensitiveCheckResult r =
          SensitiveWordsService(customPath: null).check(text);
      expect(r.clean, isTrue);
      expect(r.count, 0);
    });

    test('按分类统计', () {
      const String text = '他骂了句傻逼，又拿出炸药。';
      final SensitiveCheckResult r =
          SensitiveWordsService(customPath: null).check(text);
      expect(r.byCategory.containsKey('脏话辱骂'), isTrue);
      expect(r.byCategory.containsKey('违法违规'), isTrue);
    });
  });

  group('SensitiveWordsService 自定义词', () {
    test('添加自定义词后检测命中', () async {
      final SensitiveWordsService svc = SensitiveWordsService(customPath: null);
      await svc.addCustomWord('深渊巨兽');
      final SensitiveCheckResult r = svc.check('深渊巨兽从海底升起。');
      expect(r.clean, isFalse);
      expect(r.hits.first.category, '自定义');
    });

    test('移除自定义词后不再命中', () async {
      final SensitiveWordsService svc = SensitiveWordsService(customPath: null);
      await svc.addCustomWord('魔导炮');
      expect(svc.check('魔导炮蓄能中。').clean, isFalse);
      await svc.removeCustomWord('魔导炮');
      expect(svc.check('魔导炮蓄能中。').clean, isTrue);
    });
  });

  group('SensitiveWordsService 边界', () {
    test('空文本直接干净', () {
      final SensitiveCheckResult r =
          SensitiveWordsService(customPath: null).check('');
      expect(r.clean, isTrue);
    });

    test('同一词多处命中都记录', () {
      const String text = '他骂了句傻逼，又骂了句傻逼。';
      final SensitiveCheckResult r =
          SensitiveWordsService(customPath: null).check(text);
      final int n = r.hits.where((h) => h.word == '傻逼').length;
      expect(n, 2);
    });
  });

  group('SensitiveWordsService 命中统计', () {
    test('recordStats 累计历史命中次数', () {
      final SensitiveWordsService svc =
          SensitiveWordsService(customPath: null, statsPath: null);
      expect(svc.hitStats, isEmpty);
      svc.recordStats(svc.check('他骂了句傻逼，又拿出炸药。'));
      expect(svc.hitStats['傻逼'], 1);
      expect(svc.hitStats['炸药'], 1);
      svc.recordStats(svc.check('他又骂了句傻逼。'));
      expect(svc.hitStats['傻逼'], 2);
    });

    test('statsPath 持久化：重载后统计仍在', () async {
      final Directory d =
          await Directory.systemTemp.createTemp('sens_stats_');
      final String statsPath =
          '${d.path}${Platform.pathSeparator}stats.json';
      try {
        final SensitiveWordsService svc =
            SensitiveWordsService(statsPath: statsPath);
        svc.recordStats(svc.check('炸弹炸药都在。'));
        // 等待异步落盘。
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final SensitiveWordsService svc2 =
            SensitiveWordsService(statsPath: statsPath);
        expect(svc2.hitStats['炸弹'], 1);
        expect(svc2.hitStats['炸药'], 1);
      } finally {
        try {
          await d.delete(recursive: true);
        } catch (_) {}
      }
    });
  });

  group('SensitiveWordsService 归一化匹配', () {
    test('全角字母命中内置 ASCII 词（vx:）', () {
      // 内置词「vx:」以小写半角存储；文本用全角大写形式也应命中。
      final SensitiveCheckResult r =
          SensitiveWordsService(customPath: null).check('加ＶＸ：领取福利');
      expect(r.clean, isFalse);
      expect(r.hits.any((h) => h.word == 'vx:'), isTrue);
    });

    test('大写英文命中小写存储词（加QQ）', () {
      final SensitiveCheckResult r =
          SensitiveWordsService(customPath: null).check('请加ＱＱ群：123456');
      expect(r.hits.any((h) => h.word == '加qq'), isTrue);
    });

    test('全角标点不影响字符索引：上下文取自原文', () {
      const String text = "他说：'ＶＸ：123'，别被骗了。";
      final SensitiveCheckResult r =
          SensitiveWordsService(customPath: null).check(text);
      SensitiveHit? hit;
      for (final SensitiveHit h in r.hits) {
        if (h.word == 'vx:') {
          hit = h;
          break;
        }
      }
      expect(hit, isNotNull);
      // 命中位置按原文索引，上下文含原文中的全角字符。
      expect(text.substring(hit!.start, hit.start + 3), 'ＶＸ：');
    });

    test('存储原文不被改写：添加保留原始写法且按归一化去重', () async {
      final Directory d =
          await Directory.systemTemp.createTemp('sens_custom_');
      final String customPath =
          '${d.path}${Platform.pathSeparator}custom.json';
      try {
        final SensitiveWordsService svc =
            SensitiveWordsService(customPath: customPath);
        // 添加时保留用户原始写法（大写+全角）。
        await svc.addCustomWord('ＶＩＰ');
        // 归一化去重：不同写法不再重复入库。
        await svc.addCustomWord('vip');
        await svc.addCustomWord('ＶｉＰ');
        // 落盘文件保留原文写法，且只有「ＶＩＰ」这一条。
        final String persisted = File(customPath).readAsStringSync();
        final List<dynamic> saved = jsonDecode(persisted) as List<dynamic>;
        expect(saved, hasLength(1));
        expect(saved.single, 'ＶＩＰ');
        // 归一化匹配：小写半角写法也能命中。
        expect(svc.check('这里的 vip 通道').clean, isFalse);
      } finally {
        try {
          await d.delete(recursive: true);
        } catch (_) {}
      }
    });
  });
}
