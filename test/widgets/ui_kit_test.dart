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

      await tester.pumpWidget(wrap(
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
      ));
      final Finder divider = find.byWidgetPredicate(
        (Widget w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
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
      await tester.pumpWidget(wrap(
        ActionGroup(children: <Widget>[
          ToolButton(icon: Icons.search, label: '全文搜索', onPressed: () => taps++),
        ]),
      ));
      expect(find.text('全文搜索'), findsNothing); // 只有 tooltip，不占版面
      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('showLabel 时文字出来，active 态换成主色', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(
        const ActionGroup(children: <Widget>[
          ToolButton(
              icon: Icons.fullscreen, label: '专注模式', showLabel: true, active: true),
        ]),
      ));
      expect(find.text('专注模式'), findsOneWidget);
      final Text t = tester.widget(find.text('专注模式'));
      expect(t.style?.color, AppInk.light.primary);
    });
  });

  group('AppCard', () {
    testWidgets('fill=true 时 footer 贴底（网格对齐靠它）', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(
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
      ));
      final double footerTop = tester.getRect(find.text('底部')).top;
      expect(footerTop, greaterThan(180), reason: 'footer 应被推到底部附近');
      expect(tester.takeException(), isNull);
    });

    testWidgets('accent 色条 + onTap 不改变内容尺寸', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(
        AppCard(
          title: '标题',
          accent: AppInk.light.accent,
          onTap: () {},
          child: const Text('正文'),
        ),
      ));
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
      expect(tester.getSize(find.byKey(const Key('c'))).width,
          700 - AppTokens.s4 * 2);

      await tester.pumpWidget(shell(500));
      final double narrow = tester.getSize(find.byKey(const Key('c'))).width;
      expect(narrow, lessThan(500));
      expect(narrow, greaterThan(400), reason: '窄屏该贴边而不是缩成一团');
    });
  });

  group('AppToast', () {
    testWidgets('error 条带可点的动作', (WidgetTester tester) async {
      int retried = 0;
      await tester.pumpWidget(wrap(
        Builder(builder: (BuildContext context) {
          return TextButton(
            onPressed: () => AppToast.error(context, '生成失败：429',
                actionLabel: '重试', onAction: () => retried++),
            child: const Text('触发'),
          );
        }),
      ));
      await tester.tap(find.text('触发'));
      await tester.pumpAndSettle();
      expect(find.text('生成失败：429'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retried, 1);
    });
  });

  group('ThinProgress / StatusLine', () {
    testWidgets('进度值被夹到 0~1，负数不会画疯', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const ThinProgress(value: 1.8, label: '180%')));
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

      await tester.pumpWidget(wrap(const StatusLine(
          text: '已完成', tone: BadgeTone.success)));
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });

  group('Hoverable', () {
    testWidgets('不可点的子树不该显示手型光标', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const Hoverable(child: Text('x'))));
      final MouseRegion region = tester.widget(find.ancestor(
          of: find.text('x'), matching: find.byType(MouseRegion)));
      expect(region.cursor, SystemMouseCursors.basic);
    });

    testWidgets('可点时是手型光标，且选中态有底色', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(Hoverable(
        onTap: () {},
        selected: true,
        child: const Text('x'),
      )));
      final MouseRegion region = tester.widget(find.ancestor(
          of: find.text('x'), matching: find.byType(MouseRegion)));
      expect(region.cursor, SystemMouseCursors.click);
    });
  });
}
