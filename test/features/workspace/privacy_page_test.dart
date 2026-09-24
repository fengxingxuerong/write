import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:novel_writer/features/workspace/privacy_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrapPrivacyPage() => MaterialApp.router(
        routerConfig: GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const PrivacyPage(),
            ),
          ],
        ),
      );

  // 页面为 ListView 懒加载：调大视口让全部卡片/按钮进入构建范围，
  // 否则视口外的内容不会被 find 命中。
  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrapPrivacyPage());
    await tester.pumpAndSettle();
  }

  group('PrivacyPage privacy policy', () {
    testWidgets('shows hero section', (tester) async {
      await pumpPage(tester);
      expect(find.text('墨匠隐私守则'), findsOneWidget);
      expect(find.text('您的故事，只属于您。'), findsOneWidget);
    });

    testWidgets('shows all five principle cards', (tester) async {
      await pumpPage(tester);
      expect(find.text('文稿归作者所有'), findsOneWidget);
      expect(find.text('可选的云端调用'), findsOneWidget);
      expect(find.text('不用于模型训练'), findsOneWidget);
      expect(find.text('本地数据自主'), findsOneWidget);
      expect(find.text('符合法规要求'), findsOneWidget);
    });

    testWidgets('shows clear data button', (tester) async {
      await pumpPage(tester);
      expect(find.text('清除所有本地数据'), findsOneWidget);
    });

    testWidgets('clear button opens confirm dialog', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('清除所有本地数据'));
      await tester.pumpAndSettle();
      expect(find.text('确认清除？'), findsOneWidget);
      expect(find.textContaining('此操作将删除'), findsOneWidget);
    });

    testWidgets('confirm dialog has cancel option', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('清除所有本地数据'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      // Confirm dialog closed, back to privacy page
      expect(find.text('确认清除？'), findsNothing);
      expect(find.text('墨匠隐私守则'), findsOneWidget);
    });

  testWidgets('clear data text describes the destructive scope', (tester) async {
    await pumpPage(tester);
    expect(find.textContaining('项目、流水线、快照、设置和诊断数据'), findsOneWidget);
  });

  });
}
