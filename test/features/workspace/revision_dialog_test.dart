import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/workspace/revision_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Builder(builder: (_) => child),
      );

  group('RevisionDialog diff view', () {
    testWidgets('shows both original and revised columns', (tester) async {
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => RevisionDialog.show(
                ctx,
                original: '原始文本',
                revised: '修改后文本',
              ),
              child: const Text('open'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('原文'), findsOneWidget);
      expect(find.text('AI 修订版'), findsOneWidget);
      expect(find.text('原始文本'), findsOneWidget);
      expect(find.text('修改后文本'), findsOneWidget);
    });

    testWidgets('accept buttons exist', (tester) async {
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => RevisionDialog.show(
                ctx,
                original: 'a',
                revised: 'b',
              ),
              child: const Text('open'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('保留原文'), findsOneWidget);
      expect(find.text('采用修订版'), findsOneWidget);
    });

    testWidgets('cancel closes dialog', (tester) async {
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => RevisionDialog.show(
                ctx,
                original: 'a',
                revised: 'b',
              ),
              child: const Text('open'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('AI 修订版'), findsNothing);
    });
  });
}
