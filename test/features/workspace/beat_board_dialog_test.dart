import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/workspace/beat_board_dialog.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => ProviderScope(
        child: MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Builder(builder: (_) => child),
        ),
      );

  Novel _testNovel() => Novel(
        id: 'n1',
        title: 'Test',
        genre: 'xuanhuan',
        targetWordsPerChapter: 3000,
        characters: const [],
        worldSettings: const [],
      );

  Chapter _testChapter() => const Chapter(
        id: 'ch1',
        novelId: 'n1',
        title: 'Chapter 1',
        order: 0,
        content: '',
      );

  group('BeatBoardDialog beat board', () {
    testWidgets('shows chapter title in header', (tester) async {
      final novel = _testNovel();
      final ch = _testChapter();
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => BeatBoardDialog.show(ctx, novel, ch),
              child: const Text('open'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Chapter 1'), findsOneWidget);
    });

    testWidgets('shows 4 initial beat cards', (tester) async {
      final novel = _testNovel();
      final ch = _testChapter();
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => BeatBoardDialog.show(ctx, novel, ch),
              child: const Text('open'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // 玄幻 has at least 4 beats in the first skeleton
      expect(find.text('起'), findsOneWidget);
      expect(find.text('承'), findsOneWidget);
      expect(find.text('转'), findsOneWidget);
      expect(find.text('合'), findsOneWidget);
    });

    testWidgets('skeleton chip selector shows count', (tester) async {
      final novel = _testNovel();
      final ch = _testChapter();
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => BeatBoardDialog.show(ctx, novel, ch),
              child: const Text('open'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // 玄幻 has 10 skeletons
      expect(find.textContaining('/10'), findsOneWidget);
    });

    testWidgets('close button works', (tester) async {
      final novel = _testNovel();
      final ch = _testChapter();
      await tester.pumpWidget(
        wrap(Material(
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => BeatBoardDialog.show(ctx, novel, ch),
              child: const Text('open'),
            ),
          ),
        )),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.textContaining('Chapter 1'), findsNothing);
    });
  });
}
