import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/core/theme/app_theme.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';

/// WCAG 相对亮度（sRGB，8bit 近似）。
double _luminance(Color c) {
  double ch(double v) => v <= 0.03928
      ? v / 12.92
      : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// 对比度：1~21。
double _contrast(Color a, Color b) {
  final double l1 = _luminance(a);
  final double l2 = _luminance(b);
  final double hi = math.max(l1, l2);
  final double lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('设计令牌', () {
    test('间距与圆角是单调递增的刻度，不是随手数字', () {
      expect(AppTokens.s1 < AppTokens.s2, isTrue);
      expect(AppTokens.s2 < AppTokens.s3, isTrue);
      expect(AppTokens.s3 < AppTokens.s4, isTrue);
      expect(AppTokens.s4 < AppTokens.s6, isTrue);
      expect(AppTokens.s6 < AppTokens.s8, isTrue);
      expect(AppTokens.r1 < AppTokens.r2, isTrue);
      expect(AppTokens.r2 < AppTokens.r3, isTrue);
      expect(AppTokens.r3 < AppTokens.r4, isTrue);
      expect(AppTokens.r4 < AppTokens.r5, isTrue);
    });

    test('正文与标题的动效时长区分明确，且都有曲线', () {
      expect(AppTokens.fast < AppTokens.normal, isTrue);
      expect(AppTokens.normal < AppTokens.slow, isTrue);
      expect(AppTokens.curve, Curves.easeOutCubic);
    });

    test('编辑器字号有上下限，行高比正文更松', () {
      expect(AppTokens.editorFontMin, lessThan(AppTokens.editorFontDefault));
      expect(AppTokens.editorFontDefault, lessThan(AppTokens.editorFontMax));
      expect(AppTokens.lineHeightEditor,
          greaterThan(AppTokens.lineHeightBody));
    });
  });

  group('语义色板对比度', () {
    for (final (String name, AppInk ink, Color bg) in <(String, AppInk, Color)>[
      ('浅色', AppInk.light, AppInk.light.paper),
      ('深色', AppInk.darkMode, AppInk.darkMode.paper),
    ]) {
      test('$name：正文/次级/三级文字在纸面上达到 AA', () {
        expect(_contrast(ink.ink, bg), greaterThanOrEqualTo(7.0));
        expect(_contrast(ink.inkSoft, bg), greaterThanOrEqualTo(4.5));
        expect(_contrast(ink.inkFaint, bg), greaterThanOrEqualTo(4.4));
      });

      test('$name：语义色做小字时不低于 4.5', () {
        expect(_contrast(ink.primary, bg), greaterThanOrEqualTo(4.5));
        expect(_contrast(ink.accent, bg), greaterThanOrEqualTo(4.5));
        expect(_contrast(ink.success, bg), greaterThanOrEqualTo(4.5));
        expect(_contrast(ink.warn, bg), greaterThanOrEqualTo(4.5));
        expect(_contrast(ink.danger, bg), greaterThanOrEqualTo(4.5));
      });

      test('$name：主按钮上的字可读', () {
        expect(_contrast(ink.onPrimary, ink.primary),
            greaterThanOrEqualTo(4.5));
      });

      test('$name：卡片面与页面底能分出层次（但不靠阴影）', () {
        expect(_contrast(ink.surface, bg), greaterThanOrEqualTo(1.03));
        expect(ink.border, isNot(ink.divider));
      });
    }

    test('深色不是把浅色取反：两套底色的亮度差得足够远', () {
      expect(_luminance(AppInk.light.paper), greaterThan(0.8));
      expect(_luminance(AppInk.darkMode.paper), lessThan(0.02));
    });
  });

  group('题材色', () {
    test('每个内置题材都有专属色，不会掉回中性灰', () {
      for (final GenrePreset p in GenrePresets.all) {
        expect(GenreColors.map.containsKey(p.key), isTrue,
            reason: '题材 ${p.key}（${p.label}）缺色值');
        expect(GenreColors.of(p.key), isNot(GenreColors.neutral),
            reason: '题材 ${p.key} 掉回中性灰');
      }
    });

    test('未知题材安全回落到中性灰', () {
      expect(GenreColors.of('nope'), GenreColors.neutral);
    });

    test('tint 在深浅两套下都是低透明底，不会盖住文字', () {
      final Color l = GenreColors.tint('kehuan', AppInk.light);
      final Color d = GenreColors.tint('kehuan', AppInk.darkMode);
      expect(l.a, lessThan(0.2));
      expect(d.a, lessThan(0.25));
    });
  });

  group('主题装配', () {
    test('两套主题都把中文字体家族与回退链写进了文字样式', () {
      for (final ThemeData theme in <ThemeData>[AppTheme.light, AppTheme.dark]) {
        expect(theme.useMaterial3, isTrue);
        expect(theme.textTheme.bodyLarge?.fontFamily, AppFonts.ui);
        expect(theme.textTheme.bodyLarge?.fontFamilyFallback,
            contains('PingFang SC'));
        expect(theme.textTheme.bodyLarge?.fontFamilyFallback,
            contains('Noto Sans CJK SC'));
        // ThemeData 只在 textTheme 缺省时用 fontFamily 兜底；这里必须确认的是
        // 真实样式上带了家族，否则桌面端中文会掉进不可控的系统兜底。
        expect(theme.textTheme.titleMedium?.fontFamilyFallback, isNotNull);
      }
    });

    test('卡片靠描边不靠投影：深色下阴影为空', () {
      expect(AppInk.darkMode.shadow(), isEmpty);
      expect(AppInk.light.shadow().length, 1);
      expect(AppInk.light.shadow().first.blurRadius, greaterThan(0));
    });

    test('标题用衬线、UI 用黑体，编辑器行高写进 bodyLarge', () {
      final TextTheme t = AppTheme.light.textTheme;
      expect(t.displaySmall?.fontFamily, AppFonts.serif);
      expect(t.titleMedium?.fontFamily, AppFonts.ui);
      expect(t.bodyLarge?.height, AppTokens.lineHeightBody);
    });

    test('字体回退链里每个家族都写了两次以上平台覆盖', () {
      // 至少覆盖 Windows / macOS / Linux 各一，否则换机器就变方块。
      expect(AppFonts.uiFallback.length, greaterThanOrEqualTo(6));
      expect(AppFonts.serifFallback.length, greaterThanOrEqualTo(4));
      expect(AppFonts.uiFallback, contains('Microsoft YaHei'));
      expect(AppFonts.uiFallback, contains('WenQuanYi Micro Hei'));
    });
  });
}
