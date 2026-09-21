import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/workspace/book_qa_report_dialog.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';

/// 全书体检报告弹窗 widget 测试。
///
/// BookQaService 为纯本地规则（零 LLM/零网络），直接构造 Novel 驱动弹窗。
/// 覆盖：空书空态与按钮禁用、自动体检出总分卡、不达标章默认展开、
/// 点击收起/展开、复制定点修指令 toast、重新体检。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final DateTime t = DateTime(2026, 1, 1);

  Novel novel({List<Chapter> chapters = const <Chapter>[]}) => Novel(
        id: 'n1',
        title: '体检书',
        genre: 'xuanhuan',
        tone: '热血',
        targetWordsPerChapter: 2000,
        createdAt: t,
        updatedAt: t,
        chapters: chapters,
        characters: const <Character>[],
        worldSettings: const <WorldSetting>[],
      );

  Chapter chapter(int order, String content) => Chapter(
        id: 'c$order',
        novelId: 'n1',
        title: '第$order章',
        order: order,
        content: content,
        createdAt: t,
        updatedAt: t,
      );

  /// 达标长文（与 book_qa_service_test 同口径：score≈88.5、pass、无红线）。
  String passText() {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 30; i++) {
      b.writeln('第$i回合，陈默怒吼道：「这一局，我不会再退，输的只会是你！」');
      b.writeln('擂台四周的看客尽皆目瞪口呆，却谁也不敢上前。');
      b.writeln('丹田里的灵力忽然温热流转，仿佛一层暖流涌遍全身。');
      b.writeln('周扬在远处说道：「陈默，这一战之后，没人敢再小看你。」');
    }
    b.write('就在这时，台下忽然传来一阵急促的脚步——来的那个人，竟然是他。');
    return b.toString();
  }

  /// 短文本：无钩子无爽点 → 不达标且 fixPrompt 非空。
  String hooklessText() => '他走在路上，风很大。';

  Future<void> openDialog(WidgetTester tester, Novel n) async {
    // 弹窗固定 720x640，放大测试画布避免溢出。
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => TextButton(
              onPressed: () => showBookQaReportDialog(ctx, n),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('空章节书：空态提示 + 重新体检禁用，关闭按钮可退出', (tester) async {
    await openDialog(tester, novel());
    expect(find.text('全书体检 · 体检书'), findsOneWidget);
    expect(find.text('这本书还没有章节，先写或生成一章再体检'), findsOneWidget);

    final TextButton rerun =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '重新体检'));
    expect(rerun.onPressed, isNull, reason: '无章节时重新体检应禁用');

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('全书体检 · 体检书'), findsNothing);
  });

  testWidgets('有章节：自动体检出总分卡与章节明细，首个不达标章默认展开', (tester) async {
    await openDialog(tester, novel(chapters: <Chapter>[
      chapter(1, passText()),
      chapter(2, hooklessText()),
    ]));

    expect(find.text('全书平均分'), findsOneWidget);
    expect(find.text('达线章节'), findsOneWidget);
    expect(find.text('合规红线'), findsOneWidget);
    expect(find.textContaining('共 2 章'), findsOneWidget);
    expect(find.textContaining('第 1 章'), findsOneWidget);
    expect(find.textContaining('第 2 章'), findsOneWidget);
    // 第 2 章不达标 → 默认展开，定点修按钮直接可见。
    expect(find.text('复制定点修指令'), findsOneWidget);
  });

  testWidgets('点击章节卡片收起/展开问题明细', (tester) async {
    await openDialog(tester, novel(chapters: <Chapter>[
      chapter(1, passText()),
      chapter(2, hooklessText()),
    ]));
    expect(find.text('复制定点修指令'), findsOneWidget);

    // 收起默认展开的第 2 章。
    await tester.tap(find.textContaining('第 2 章'));
    await tester.pumpAndSettle();
    expect(find.text('复制定点修指令'), findsNothing);

    // 再点重新展开。
    await tester.tap(find.textContaining('第 2 章'));
    await tester.pumpAndSettle();
    expect(find.text('复制定点修指令'), findsOneWidget);
  });

  testWidgets('复制定点修指令 → 弹出成功提示', (tester) async {
    await openDialog(tester, novel(chapters: <Chapter>[
      chapter(2, hooklessText()),
    ]));
    await tester.tap(find.text('复制定点修指令'));
    await tester.pump(); // 让 SnackBar 进场
    expect(find.text('定点修指令已复制，可粘贴给编辑器 AI'), findsOneWidget);
    await tester.pumpAndSettle(); // 收掉 SnackBar 计时器，避免悬挂 Timer
  });

  testWidgets('重新体检：有章节时可用，点击后报告重出', (tester) async {
    await openDialog(tester, novel(chapters: <Chapter>[chapter(1, passText())]));
    expect(find.text('全书平均分'), findsOneWidget);

    final TextButton rerun =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '重新体检'));
    expect(rerun.onPressed, isNotNull, reason: '有章节时重新体检应可用');

    await tester.tap(find.text('重新体检'));
    await tester.pumpAndSettle();
    expect(find.text('全书平均分'), findsOneWidget);
  });
}
