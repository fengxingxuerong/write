import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/theme/app_theme.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/widgets/app_card.dart';
import 'package:novel_writer/widgets/app_feedback.dart';
import 'package:novel_writer/widgets/page_shell.dart';

/// 新组件层的行为测试。
///
/// 为什么不测整页工作区：`testWidgets` 的 fake-async 环境里真实文件 IO 不推进，
/// 页面一加载就卡在 `CircularProgressIndicator` 上，`pumpAndSettle` 会耗到超时
/// （我试过一次，30 分钟换 3 个 timeout）。所以这里只测**不需要读盘**的组件契约，
/// 整页版式靠书架页那份 golden 体检（它有 provider 桩，能真正渲染完）。
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(body: child),
    builder: (BuildContext context, Widget? child) => AppInkTheme(
      brightness: Brightness.light,
      child: child ?? const SizedBox.shrink(),
    ),
  );

  group('ResizablePanes', () {
    testWidgets('宽屏渲染三栏，窄屏只留中栏', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600 * 2, 900 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      Widget panes(double width) => wrap(
        SizedBox(
          width: width,
          height: 600,
          child: const ResizablePanes(
            left: Text('左'),
            center: Text('中'),
            right: Text('右'),
          ),
        ),
      );

      await tester.pumpWidget(panes(1400));
      expect(find.text('左'), findsOneWidget);
      expect(find.text('中'), findsOneWidget);
      expect(find.text('右'), findsOneWidget);

      await tester.pumpWidget(panes(700));
      expect(find.text('左'), findsNothing, reason: '<900 不收三栏，挤不动');
      expect(find.text('中'), findsOneWidget);
    });

    testWidgets('拖分隔条会加宽左栏，并被 min/max 夹住', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600 * 2, 900 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrap(
          const SizedBox(
            width: 1400,
            height: 600,
            child: ResizablePanes(
              initialLeftWidth: 268,
              minPaneWidth: 200,
              maxPaneWidth: 460,
              left: Text('左'),
              center: Text('中'),
              right: Text('右'),
            ),
          ),
        ),
      );
      final Finder divider = find.byWidgetPredicate(
        (Widget w) =>
            w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
      );
      expect(divider, findsWidgets);

      double leftW() => tester.getSize(find.text('左')).width;
      final double before = leftW();
      await tester.drag(divider.first, const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(leftW(), moreOrLessEquals(before + 60, epsilon: 1.0));

      // 往死里拖也不能越过 maxPaneWidth。
      await tester.drag(divider.first, const Offset(2000, 0));
      await tester.pumpAndSettle();
      expect(leftW(), lessThanOrEqualTo(460.0 + 1.0));
    });
  });

  group('ActionGroup / ToolButton', () {
    testWidgets('不显示标签时仍有 tooltip，点击回调生效', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        wrap(
          ActionGroup(
            children: <Widget>[
              ToolButton(
                icon: Icons.search,
                label: '全文搜索',
                onPressed: () => taps++,
              ),
            ],
          ),
        ),
      );
      expect(find.text('全文搜索'), findsNothing); // 只有 tooltip，不占版面
      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('showLabel 时文字出来，active 态换成主色', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          const ActionGroup(
            children: <Widget>[
              ToolButton(
                icon: Icons.fullscreen,
                label: '专注模式',
                showLabel: true,
                active: true,
              ),
            ],
          ),
        ),
      );
      expect(find.text('专注模式'), findsOneWidget);
      final Text t = tester.widget(find.text('专注模式'));
      expect(t.style?.color, AppInk.light.primary);
    });
  });

  group('AppCard', () {
    testWidgets('fill=true 时 footer 贴底（网格对齐靠它）', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          const SizedBox(
            width: 300,
            height: 220,
            child: AppCard(
              fill: true,
              padding: EdgeInsets.zero,
              footer: Text('底部'),
              child: Text('内容'),
            ),
          ),
        ),
      );
      final double footerTop = tester.getRect(find.text('底部')).top;
      expect(footerTop, greaterThan(180), reason: 'footer 应被推到底部附近');
      expect(tester.takeException(), isNull);
    });

    testWidgets('accent 色条 + onTap 不改变内容尺寸', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          AppCard(
            title: '标题',
            accent: AppInk.light.accent,
            onTap: () {},
            child: const Text('正文'),
          ),
        ),
      );
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('PageShell', () {
    testWidgets('宽屏把内容夹到 maxWidth，窄屏贴边', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600 * 2, 900 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      Widget shell(double w) => wrap(
        SizedBox(
          width: w,
          child: const PageShell(
            maxWidth: 700,
            child: SizedBox(
              width: double.infinity,
              child: Text('内容', key: Key('c')),
            ),
          ),
        ),
      );

      await tester.pumpWidget(shell(1400));
      // maxWidth 是「盒子」宽，文字区还要减掉左右内边距。
      expect(
        tester.getSize(find.byKey(const Key('c'))).width,
        700 - AppTokens.s4 * 2,
      );

      await tester.pumpWidget(shell(500));
      final double narrow = tester.getSize(find.byKey(const Key('c'))).width;
      expect(narrow, lessThan(500));
      expect(narrow, greaterThan(400), reason: '窄屏该贴边而不是缩成一团');
    });
  });

  group('AppToast', () {
    testWidgets('error 条带可点的动作', (WidgetTester tester) async {
      int retried = 0;
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (BuildContext context) {
              return TextButton(
                onPressed: () => AppToast.error(
                  context,
                  '生成失败：429',
                  actionLabel: '重试',
                  onAction: () => retried++,
                ),
                child: const Text('触发'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('触发'));
      await tester.pumpAndSettle();
      expect(find.text('生成失败：429'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retried, 1);
    });
  });

  group('ThinProgress / StatusLine', () {
    testWidgets('indeterminate 模式不设 value，只显示不定进度', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        wrap(const ThinProgress(value: 0, indeterminate: true, label: '生成中')),
      );
      await tester.pump();

      expect(find.text('生成中'), findsOneWidget);
      final LinearProgressIndicator indicator = tester
          .widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          );
      expect(indicator.value, isNull);
    });

    testWidgets('进度值被夹到 0~1，负数不会画疯', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(const ThinProgress(value: 1.8, label: '180%')),
      );
      await tester.pumpAndSettle();
      expect(find.text('180%'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(wrap(const ThinProgress(value: -0.5)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('StatusLine 的 busy 态显示指示器而不是勾', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const StatusLine(text: '写作中', busy: true)));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpWidget(
        wrap(const StatusLine(text: '已完成', tone: BadgeTone.success)),
      );
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });

  group('AppCard', () {
    testWidgets('渲染标题/副标题/图标/操作/页脚，并区分普通卡与可点卡', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        wrap(
          SizedBox(
            width: 520,
            child: AppCard(
              title: '项目标题',
              subtitle: '项目副标题',
              icon: Icons.menu_book_outlined,
              actions: <Widget>[
                IconButton(
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () {},
                ),
              ],
              footer: const Text('底部操作区'),
              onTap: () => taps++,
              child: const Text('卡片正文'),
            ),
          ),
        ),
      );

      expect(find.text('项目标题'), findsOneWidget);
      expect(find.text('项目副标题'), findsOneWidget);
      expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
      expect(find.text('卡片正文'), findsOneWidget);
      expect(find.text('底部操作区'), findsOneWidget);
      expect(find.byType(Divider), findsOneWidget);
      expect(find.byType(Hoverable), findsOneWidget);

      await tester.tap(find.text('卡片正文'));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('选中态使用主色边框，accent 渲染左侧色条', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          const SizedBox(
            width: 420,
            child: AppCard(
              selected: true,
              accent: Colors.red,
              child: Text('状态卡'),
            ),
          ),
        ),
      );

      final Finder containers = find.descendant(
        of: find.byType(AppCard),
        matching: find.byWidgetPredicate(
          (Widget w) => w is Container && w.decoration is BoxDecoration,
        ),
      );
      final Iterable<Element> elements = containers.evaluate();
      bool sawSelectedBorder = false;
      bool sawAccent = false;
      for (final Element element in elements) {
        final Container container = tester.widget<Container>(
          find.byElementPredicate(
            (Element candidate) => identical(candidate, element),
          ),
        );
        final BoxDecoration decoration = container.decoration! as BoxDecoration;
        if (decoration.border?.top.width == 1.4) sawSelectedBorder = true;
        if (decoration.color == Colors.red) sawAccent = true;
      }
      expect(sawSelectedBorder, isTrue, reason: 'selected 应使用 1.4px 主色边框');
      expect(sawAccent, isTrue, reason: 'accent 应渲染独立色条 Container');
      expect(find.text('状态卡'), findsOneWidget);
      expect(
        find.byType(Hoverable),
        findsNothing,
        reason: '未传 onTap 时不应包一层可点 Hoverable',
      );
    });
  });

  group('AppToast 全部色调', () {
    testWidgets('warn 显示警告图标，info 无动作按钮', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (BuildContext context) => Column(
              children: <Widget>[
                TextButton(
                  onPressed: () => AppToast.warn(context, '额度不足'),
                  child: const Text('warn'),
                ),
                TextButton(
                  onPressed: () => AppToast.info(context, '已保存草稿'),
                  child: const Text('info'),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('warn'));
      await tester.pumpAndSettle();
      expect(find.text('额度不足'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

      await tester.tap(find.text('info'));
      await tester.pumpAndSettle();
      expect(find.text('已保存草稿'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
    });
  });

  group('SectionHeader', () {
    testWidgets('渲染标题、副标题、图标、动作，并按开关显示分隔线', (WidgetTester tester) async {
      int actionTaps = 0;
      await tester.pumpWidget(
        wrap(
          SectionHeader(
            title: '章节结构',
            subtitle: '按场景推进',
            icon: Icons.account_tree_outlined,
            actions: <Widget>[
              TextButton(
                onPressed: () => actionTaps++,
                child: const Text('编辑'),
              ),
            ],
          ),
        ),
      );

      expect(find.text('章节结构'), findsOneWidget);
      expect(find.text('按场景推进'), findsOneWidget);
      expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
      expect(find.byType(Divider), findsOneWidget);
      expect(find.text('内容'), findsNothing);

      await tester.tap(find.text('编辑'));
      await tester.pump();
      expect(actionTaps, 1);
    });

    testWidgets('divider=false 时不渲染底部分隔线', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(const SectionHeader(title: '无分隔线', divider: false)),
      );

      expect(find.text('无分隔线'), findsOneWidget);
      expect(find.byType(Divider), findsNothing);
      expect(find.byIcon(Icons.account_tree_outlined), findsNothing);
    });
  });

  group('StatTile', () {
    testWidgets('展示标签、数值、提示并可点击', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        wrap(
          SizedBox(
            width: 180,
            child: StatTile(
              label: '总字数',
              value: '12,345',
              hint: '较昨日 +800',
              icon: Icons.menu_book_outlined,
              tone: BadgeTone.success,
              onTap: () => taps++,
            ),
          ),
        ),
      );

      expect(find.text('总字数'), findsOneWidget);
      expect(find.text('12,345'), findsOneWidget);
      expect(find.text('较昨日 +800'), findsOneWidget);
      expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);
      expect(find.byType(Hoverable), findsOneWidget);

      await tester.tap(find.text('12,345'));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('无提示、无图标、不可点击时不产生多余子树', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const StatTile(label: '章节数', value: '12')));

      expect(find.text('章节数'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.byType(Hoverable), findsNothing);
      expect(find.byIcon(Icons.menu_book_outlined), findsNothing);
    });
  });

  group('ElapsedTicker', () {
    testWidgets('运行时每秒刷新并回调，分钟格式正确', (WidgetTester tester) async {
      final List<int> ticks = <int>[];
      await tester.pumpWidget(
        wrap(ElapsedTicker(running: true, onElapsed: ticks.add)),
      );
      expect(find.textContaining('已用'), findsNothing);

      for (int i = 0; i < 61; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('已用 1m01s'), findsOneWidget);
      expect(ticks.last, 61);
    });

    testWidgets('running=false 后取消计时，不再回调', (WidgetTester tester) async {
      final List<int> ticks = <int>[];
      bool running = true;
      late StateSetter setState;
      await tester.pumpWidget(
        wrap(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setter) {
              setState = setter;
              return ElapsedTicker(running: running, onElapsed: ticks.add);
            },
          ),
        ),
      );

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(ticks.length, 2);

      setState(() => running = false);
      await tester.pump();
      final int stoppedCount = ticks.length;
      await tester.pump(const Duration(seconds: 3));
      expect(ticks.length, stoppedCount, reason: '取消后不应继续计时');
    });
  });

  group('Hoverable', () {
    testWidgets('不可点的子树不该显示手型光标', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const Hoverable(child: Text('x'))));
      final MouseRegion region = tester.widget(
        find.ancestor(of: find.text('x'), matching: find.byType(MouseRegion)),
      );
      expect(region.cursor, SystemMouseCursors.basic);
    });

    testWidgets('可点时是手型光标，且选中态有底色', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(Hoverable(onTap: () {}, selected: true, child: const Text('x'))),
      );
      final MouseRegion region = tester.widget(
        find.ancestor(of: find.text('x'), matching: find.byType(MouseRegion)),
      );
      expect(region.cursor, SystemMouseCursors.click);
    });
  });
}
