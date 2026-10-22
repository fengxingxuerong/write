import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/workspace/novel_info_dialog.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';

void main() {
  final Novel novel = Novel(
    id: 'n1',
    title: '旧书名',
    genre: 'xuanhuan',
    tone: '热血',
    targetWordsPerChapter: 20000,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    chapters: const <Chapter>[],
    characters: const <Character>[],
    worldSettings: const <WorldSetting>[],
  );

  Future<Future<NovelInfoDraft?>> open(WidgetTester tester) async {
    late Future<NovelInfoDraft?> pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  pending = showNovelInfoDialog(context, novel: novel);
                },
                child: const Text('打开作品信息'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开作品信息'));
    await tester.pumpAndSettle();
    return pending;
  }

  testWidgets('展示当前作品信息并可改书名、题材、基调与单章目标', (
    WidgetTester tester,
  ) async {
    final Future<NovelInfoDraft?> pending = await open(tester);
    expect(find.text('作品信息'), findsOneWidget);
    expect(find.text('旧书名'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '新书名');
    await tester.enterText(find.byType(TextField).last, '2500');
    await tester.tap(find.text('玄幻'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('科幻').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('哲思'));
    await tester.tap(find.text('哲思'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final NovelInfoDraft? draft = await pending;
    expect(draft, isNotNull);
    expect(draft!.title, '新书名');
    expect(draft.genre, 'kehuan');
    expect(draft.tone, '哲思');
    expect(draft.targetWordsPerChapter, 2500);
  });

  testWidgets('书名为空时不保存并提示', (WidgetTester tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('作品信息'), findsOneWidget);
    expect(find.text('作品名不能为空'), findsOneWidget);
  });

  testWidgets('单章目标字数超范围时不保存并提示', (WidgetTester tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).last, '99999');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('作品信息'), findsOneWidget);
    expect(find.textContaining('单章目标字数需在'), findsOneWidget);
  });
}
