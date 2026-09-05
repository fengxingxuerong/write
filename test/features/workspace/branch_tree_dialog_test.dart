import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/workspace/branch_tree_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => ProviderScope(
        child: MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Builder(builder: (_) => child),
        ),
      );

  group('BranchTreeDialog branch tree', () {
    late List<BranchNode> nodes;

    setUp(() {
      nodes = [
        BranchNode(
          label: '分支A',
          description: '选择宽容',
          impact: '后续与反派结盟',
        ),
        BranchNode(
          label: '分支B',
          description: '选择对抗',
          impact: '正邪大战爆发',
        ),
      ];
    });

    testWidgets('shows all branches', (tester) async {
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => BranchTreeDialog.show(
                ctx,
                chapterTitle: '第5章',
                options: nodes,
              ),
              child: const Text('open'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('分支A'), findsOneWidget);
      expect(find.text('分支B'), findsOneWidget);
      expect(find.text('选择宽容'), findsOneWidget);
      expect(find.text('选择对抗'), findsOneWidget);
    });

    testWidgets('tap selects branch and closes', (tester) async {
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => BranchTreeDialog.show(
                ctx,
                chapterTitle: '第5章',
                options: nodes,
              ),
              child: const Text('open'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择宽容'));
      await tester.pumpAndSettle();
      // After selection, dialog closes
      expect(find.text('分支A'), findsNothing);
    });

    testWidgets('cancel button closes', (tester) async {
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => BranchTreeDialog.show(
                ctx,
                chapterTitle: '第5章',
                options: nodes,
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
      expect(find.text('分支A'), findsNothing);
    });
  });
}
