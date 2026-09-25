import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/workspace/world_book_dialog.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => ProviderScope(
    child: MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Scaffold(body: child),
    ),
  );

  Novel testNovel() => Novel(
    id: 'n1',
    title: '测试小说',
    genre: 'xuanhuan',
    tone: 'standard',
    targetWordsPerChapter: 3000,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    chapters: const [],
    characters: const [
      Character(
        id: 'c1',
        novelId: 'n1',
        name: '林尘',
        role: '主角',
        traits: '坚韧重情',
        background: '废柴出身',
        relationships: '苏媚：挚友；圣子：敌对',
        dialogueStyle: '简短有力',
      ),
    ],
    worldSettings: const [
      WorldSetting(
        id: 'w1',
        novelId: 'n1',
        title: '玄天大陆',
        category: '地理',
        content: '东大陆分为三宗七派',
      ),
    ],
  );

  group('WorldBookDialog world book', () {
    testWidgets('title shows novel name', (tester) async {
      final novel = testNovel();
      await tester.pumpWidget(
        wrap(
          Material(
            child: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => WorldBookDialog.show(ctx, novel),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('《测试小说》世界书'), findsOneWidget);
    });

    testWidgets('character card shows name and traits', (tester) async {
      final novel = testNovel();
      await tester.pumpWidget(
        wrap(
          Material(
            child: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => WorldBookDialog.show(ctx, novel),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('林尘'), findsOneWidget);
      expect(find.text('坚韧重情'), findsOneWidget);
    });

    testWidgets('world tab shows settings', (tester) async {
      final novel = testNovel();
      await tester.pumpWidget(
        wrap(
          Material(
            child: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => WorldBookDialog.show(ctx, novel),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('世界观'));
      await tester.pumpAndSettle();
      expect(find.text('玄天大陆'), findsOneWidget);
      expect(find.textContaining('东大陆'), findsOneWidget);
    });

    testWidgets('injection tab builds context text', (tester) async {
      final novel = testNovel();
      await tester.pumpWidget(
        wrap(
          Material(
            child: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => WorldBookDialog.show(ctx, novel),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('注入上下文'));
      await tester.pumpAndSettle();
      expect(find.textContaining('角色档案'), findsOneWidget);
      expect(find.textContaining('世界观设定'), findsOneWidget);
    });

    testWidgets('close button works', (tester) async {
      final novel = testNovel();
      await tester.pumpWidget(
        wrap(
          Material(
            child: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => WorldBookDialog.show(ctx, novel),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.textContaining('《测试小说》世界书'), findsNothing);
    });

    testWidgets('empty characters show empty state', (tester) async {
      final novel = Novel(
        id: 'n2',
        title: '空',
        genre: 'xuanhuan',
        tone: 'standard',
        targetWordsPerChapter: 3000,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        chapters: const [],
        characters: const [],
        worldSettings: const [],
      );
      await tester.pumpWidget(
        wrap(
          Material(
            child: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => WorldBookDialog.show(ctx, novel),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('暂无角色'), findsOneWidget);

      await tester.tap(find.text('世界观'));
      await tester.pumpAndSettle();
      expect(find.textContaining('暂无世界观设定'), findsOneWidget);
    });

    testWidgets(
      'relationship tab counts parsed edges and node tap shows detail',
      (tester) async {
        final novel = testNovel().copyWith(
          characters: const <Character>[
            Character(
              id: 'c1',
              novelId: 'n1',
              name: '林尘',
              role: '主角',
              traits: '坚韧重情',
              background: '废柴出身',
              relationships: '苏媚：挚友',
            ),
            Character(
              id: 'c2',
              novelId: 'n1',
              name: '苏媚',
              role: '反派',
              traits: '狡黠',
              background: '圣女',
              relationships: '林尘：挚友',
            ),
          ],
        );
        await tester.pumpWidget(
          wrap(
            Material(
              child: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () => WorldBookDialog.show(ctx, novel),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('关系图谱'));
        await tester.pumpAndSettle();

        expect(find.textContaining('2 个角色，1 条关系'), findsOneWidget);

        await tester.tap(find.text('林').first);
        await tester.pumpAndSettle();
        expect(find.textContaining('林尘（主角）'), findsOneWidget);
      },
    );

    testWidgets('copy context writes full injection text to clipboard', (
      tester,
    ) async {
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
          }
          return null;
        },
      );

      final novel = testNovel();
      await tester.pumpWidget(
        wrap(
          Material(
            child: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => WorldBookDialog.show(ctx, novel),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('注入上下文'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制全部'));
      await tester.pump();

      expect(clipboardText, contains('## 角色档案'));
      expect(clipboardText, contains('林尘'));
      expect(clipboardText, contains('## 世界观设定'));
      expect(clipboardText, contains('玄天大陆'));
      expect(find.textContaining('已复制到剪贴板'), findsOneWidget);
    });
  });
}
