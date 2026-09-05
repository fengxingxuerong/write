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

  group('PrivacyPage privacy policy', () {
    testWidgets('shows hero section', (tester) async {
      await tester.pumpWidget(wrapPrivacyPage());
      await tester.pumpAndSettle();
      expect(find.text('墨匠隐私守则'), findsOneWidget);
      expect(find.text('您的故事，只属于您。'), findsOneWidget);
    });

    testWidgets('shows all five principle cards', (tester) async {
      await tester.pumpWidget(wrapPrivacyPage());
      await tester.pumpAndSettle();
      expect(find.text('文稿归作者所有'), findsOneWidget);
      expect(find.text('可选的云端调用'), findsOneWidget);
      expect(find.text('不用于模型训练'), findsOneWidget);
      expect(find.text('本地数据自主'), findsOneWidget);
      expect(find.text('符合法规要求'), findsOneWidget);
    });

    testWidgets('shows clear data button', (tester) async {
      await tester.pumpWidget(wrapPrivacyPage());
      await tester.pumpAndSettle();
      expect(find.text('清除所有本地数据'), findsOneWidget);
    });

    testWidgets('clear button opens confirm dialog', (tester) async {
      await tester.pumpWidget(wrapPrivacyPage());
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除所有本地数据'));
      await tester.pumpAndSettle();
      expect(find.text('确认清除？'), findsOneWidget);
      expect(find.textContaining('此操作将删除'), findsOneWidget);
    });

    testWidgets('confirm dialog has cancel option', (tester) async {
      await tester.pumpWidget(wrapPrivacyPage());
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除所有本地数据'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      // Confirm dialog closed, back to privacy page
      expect(find.text('确认清除？'), findsNothing);
      expect(find.text('墨匠隐私守则'), findsOneWidget);
    });
  });
}
