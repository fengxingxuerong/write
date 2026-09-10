import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/editor/editor_toolbar.dart';
import 'package:novel_writer/features/editor/sensitive_check_dialog.dart';
import 'package:novel_writer/services/sensitive_words.dart';

void main() {
  // 测试环境说明：Flutter 3.44 的 flutter_tester 无法解码 Material 的
  // ink_sparkle.frag（runtime stages 版本 0≠2），点击按钮加载水波纹即抛异常。
  // 用 NoSplash 绕开 shader 加载，仅影响测试，不影响真机。
  Widget wrap(Widget child) => MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: child),
      );

  EditorToolbar buildToolbar({
    VoidCallback? onToggleSearch,
    VoidCallback? onContinueWrite,
    VoidCallback? onShowStats,
    VoidCallback? onSaveDraft,
    VoidCallback? onShowHistory,
    VoidCallback? onShowCheck,
    bool searchOpen = false,
    bool saved = false,
    bool pomodoroRunning = false,
    SensitiveCheckResult? check,
  }) {
    return EditorToolbar(
      title: '第一章 测试',
      wordCount: 1234,
      searchOpen: searchOpen,
      fontSize: 16,
      lineHeight: 1.6,
      pomodoroRemainNotifier: ValueNotifier<int>(pomodoroRunning ? 1499 : 0),
      pomodoroRunningNotifier: ValueNotifier<bool>(pomodoroRunning),
      check: check,
      saved: saved,
      onToggleSearch: onToggleSearch ?? () {},
      onDecreaseFont: () {},
      onIncreaseFont: () {},
      onCycleLineHeight: () {},
      onTogglePomodoro: () {},
      onShowCheck: onShowCheck ?? () {},
      onShowStats: onShowStats ?? () {},
      onSplitChapter: () {},
      onContinueWrite: onContinueWrite ?? () {},
      onRewriteSelected: () {},
      onProofread: () {},
      onSaveDraft: onSaveDraft ?? () {},
      onShowHistory: onShowHistory ?? () {},
    );
  }

  testWidgets('显示标题与字数', (tester) async {
    await tester.pumpWidget(wrap(buildToolbar()));
    expect(find.text('第一章 测试'), findsOneWidget);
    expect(find.text('1234 字'), findsOneWidget);
  });

  testWidgets('查找按钮切换图标（关闭→打开）', (tester) async {
    await tester.pumpWidget(wrap(buildToolbar()));
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('查找已打开时显示关闭图标', (tester) async {
    await tester.pumpWidget(wrap(buildToolbar(searchOpen: true)));
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byIcon(Icons.search), findsNothing);
  });

  testWidgets('点击查找按钮触发回调', (tester) async {
    var toggled = 0;
    await tester.pumpWidget(
      wrap(buildToolbar(onToggleSearch: () => toggled++)),
    );
    await tester.tap(find.byIcon(Icons.search));
    expect(toggled, 1);
  });

  testWidgets('点击 AI 续写按钮触发回调', (tester) async {
    var continued = 0;
    await tester.pumpWidget(
      wrap(buildToolbar(onContinueWrite: () => continued++)),
    );
    await tester.tap(find.byIcon(Icons.auto_awesome));
    expect(continued, 1);
  });

  testWidgets('点击写作统计按钮触发回调', (tester) async {
    var stats = 0;
    await tester.pumpWidget(
      wrap(buildToolbar(onShowStats: () => stats++)),
    );
    await tester.tap(find.byIcon(Icons.query_stats));
    expect(stats, 1);
  });

  testWidgets('存稿箱收在「更多」菜单里，点开可触发', (tester) async {
    var savedDraft = 0;
    await tester.pumpWidget(
      wrap(buildToolbar(onSaveDraft: () => savedDraft++)),
    );
    // 低频动作不再常驻一行图标，点一下菜单才能看到——这是设计决定，
    // 测试跟着改路径，但断言仍然是「点了真的会回调」。
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('存入存稿箱'), findsOneWidget);
    await tester.tap(find.text('存入存稿箱'));
    await tester.pumpAndSettle();
    expect(savedDraft, 1);
  });

  testWidgets('番茄钟运行中显示剩余时间', (tester) async {
    await tester.pumpWidget(wrap(buildToolbar(pomodoroRunning: true)));
    expect(find.text('24:59'), findsOneWidget);
    expect(find.byIcon(Icons.timer_off), findsOneWidget);
  });

  testWidgets('番茄钟未运行显示按钮文本', (tester) async {
    await tester.pumpWidget(wrap(buildToolbar()));
    expect(find.text('番茄钟'), findsOneWidget);
    expect(find.byIcon(Icons.timer_outlined), findsOneWidget);
  });

  testWidgets('保存状态显示已保存徽标', (tester) async {
    await tester.pumpWidget(wrap(buildToolbar(saved: true)));
    expect(find.text('已保存'), findsOneWidget);
  });

  testWidgets('未保存显示编辑中徽标', (tester) async {
    await tester.pumpWidget(wrap(buildToolbar()));
    expect(find.text('编辑中'), findsOneWidget);
  });

  testWidgets('敏感词命中显示徽标且可点击', (tester) async {
    var checkTapped = 0;
    const result = SensitiveCheckResult(
      <SensitiveHit>[
        SensitiveHit(
          word: '暴力',
          category: '暴力血腥',
          start: 0,
          context: '血腥暴力',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(buildToolbar(check: result, onShowCheck: () => checkTapped++)),
    );
    // 徽标渲染存在
    expect(find.byType(SensitiveBadge), findsOneWidget);
    // 点击徽标触发回调
    await tester.tap(find.byType(SensitiveBadge));
    expect(checkTapped, 1);
  });
}
