import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/theme/app_theme.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/features/editor/editor_toolbar.dart';

/// 编辑器工具栏视觉回归。
///
/// 为什么挑这一屏：它是全应用**元素密度最高**的一条，而且是横向滚动的——
/// 「加了点东西把后面的按钮挤出视口」这类事故只有截图/溢出断言能抓到
/// （窄视口下 `tester.tap` 会直接抓，宽视口下就得靠 golden 看观感）。
///
/// 两类检查：
/// 1. **版式体检**（任何环境）：关键动作在位、宽窄视口都不溢出。
/// 2. **截图对比**（仅本地，`INK_GOLDEN=1`）：亮/暗 × 宽视口。
void main() {
  final bool record = Platform.environment.containsKey('INK_GOLDEN');

  setUpAll(() async {
    await _loadCjkFonts();
  });

  for (final (String tone, ThemeData theme) in <(String, ThemeData)>[
    ('light', AppTheme.light),
    ('dark', AppTheme.dark),
  ]) {
    testWidgets('工具栏版式体检 · $tone', (WidgetTester tester) async {
      await _pumpBar(tester, theme: theme, width: 1280);
      expect(find.text('第一章 除名'), findsOneWidget);
      expect(find.text('2380 字'), findsOneWidget);
      // 第一动作必须还在（solid 淡底的那个）。
      expect(find.text('AI 续写'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('工具栏窄视口不溢出 · $tone', (WidgetTester tester) async {
      await _pumpBar(tester, theme: theme, width: 800);
      // 横向滚动条能兜住，但绝不该出现 RenderFlex overflow。
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('golden：工具栏亮/暗截图对比（仅本地）', (WidgetTester tester) async {
    if (!record) return;
    for (final (String tone, ThemeData theme) in <(String, ThemeData)>[
      ('light', AppTheme.light),
      ('dark', AppTheme.dark),
    ]) {
      await _pumpBar(tester, theme: theme, width: 1280);
      await expectLater(
        find.byType(EditorToolbar),
        matchesGoldenFile('goldens/editor_toolbar_$tone.png'),
      );
    }
  }, skip: !record);
}

Future<void> _pumpBar(
  WidgetTester tester, {
  required ThemeData theme,
  required double width,
}) async {
  tester.view.physicalSize = Size(width * 2, 160 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[_bar()],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

EditorToolbar _bar() => EditorToolbar(
      title: '第一章 除名',
      wordCount: 2380,
      searchOpen: false,
      fontSize: 16,
      lineHeight: 1.6,
      pomodoroRemainNotifier: ValueNotifier<int>(0),
      pomodoroRunningNotifier: ValueNotifier<bool>(false),
      check: null,
      saved: true,
      onToggleSearch: () {},
      onDecreaseFont: () {},
      onIncreaseFont: () {},
      onCycleLineHeight: () {},
      onTogglePomodoro: () {},
      onShowCheck: () {},
      onShowStats: () {},
      onSplitChapter: () {},
      onContinueWrite: () {},
      onRewriteSelected: () {},
      onProofread: () {},
      onSaveDraft: () {},
      onShowHistory: () {},
    );

/// 加载系统中文字体，注册为 [AppFonts] 声明的家族名。
Future<void> _loadCjkFonts() async {
  const List<String> candidates = <String>[
    r'C:\Windows\Fonts\simhei.ttf',
    r'C:\Windows\Fonts\NotoSansSC-VF.ttf',
  ];
  File? font;
  for (final String path in candidates) {
    if (File(path).existsSync()) {
      font = File(path);
      break;
    }
  }
  if (font == null) return; // 非 Windows：跳过加载，版式断言仍然有效。
  final ByteData data = ByteData.sublistView(await font.readAsBytes());
  for (final String family in <String>[
    AppFonts.ui,
    AppFonts.serif,
    AppFonts.mono,
  ]) {
    final FontLoader loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(data));
    await loader.load();
  }
}
