import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/workspace/writing_coach_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Builder(builder: (_) => child),
      );

  group('WritingCoachDialog analysis', () {
    testWidgets('empty text shows 0 echo rate', (tester) async {
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => WritingCoachDialog.show(ctx, ''),
              child: const Text('analyze'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('analyze'));
      await tester.pumpAndSettle();
      expect(find.text('AI 回声'), findsOneWidget);
      expect(find.text('展示 vs 陈述'), findsOneWidget);
      expect(find.text('对话密度'), findsOneWidget);
      expect(find.text('句式节奏'), findsOneWidget);
      expect(find.text('词汇多样性'), findsOneWidget);
    });

    testWidgets('text without AI echoes shows good rating', (tester) async {
      const cleanText = '他拔剑冲出，剑光一闪，敌人倒下。剑锋所指，血溅五步。';
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => WritingCoachDialog.show(ctx, cleanText),
              child: const Text('analyze'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('analyze'));
      await tester.pumpAndSettle();
      // Should have "/千字" in echo display
      expect(find.textContaining('/千字'), findsOneWidget);
    });

    testWidgets('text with AI echoes detects patterns', (tester) async {
      const echoText = '他仿佛听到什么。她微微一笑。他深吸一口气。目光一沉，沉默了片刻。';
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => WritingCoachDialog.show(ctx, echoText),
              child: const Text('analyze'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('analyze'));
      await tester.pumpAndSettle();
      // Should detect some AI echoes (count > 0)
      expect(find.textContaining('/千字'), findsOneWidget);
    });

    testWidgets('dialog closes properly', (tester) async {
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => WritingCoachDialog.show(ctx, ''),
              child: const Text('analyze'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('analyze'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('写作教练'), findsNothing);
    });
  });
}
