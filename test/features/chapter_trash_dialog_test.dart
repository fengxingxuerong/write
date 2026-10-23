import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/workspace/chapter_trash_dialog.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/storage/chapter_trash_service.dart';

class _FakeChapterTrash implements ChapterTrashStore {
  _FakeChapterTrash(this.entries);

  final List<ChapterTrashEntry> entries;
  int restored = 0;
  int purged = 0;
  int purgedAll = 0;
  bool failList = false;

  @override
  Future<List<ChapterTrashEntry>> list(String novelId) async {
    if (failList) throw StateError('磁盘不可用');
    return List<ChapterTrashEntry>.of(entries);
  }

  @override
  Future<Chapter> restore(ChapterTrashEntry entry) async {
    entries.remove(entry);
    restored++;
    return Chapter(
      id: entry.chapterId,
      novelId: entry.novelId,
      title: entry.title,
      order: entry.order,
      content: entry.content,
      outline: entry.outline,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
  }

  @override
  Future<void> purge(ChapterTrashEntry entry) async {
    entries.remove(entry);
    purged++;
  }

  @override
  Future<void> purgeAll(String novelId) async {
    entries.clear();
    purgedAll++;
  }
}

ChapterTrashEntry _entry(String id, String title, {int order = 2}) {
  return ChapterTrashEntry(
    novelId: 'n1',
    chapterId: id,
    title: title,
    content: '这是一段正文。',
    outline: '大纲',
    order: order,
    deletedAt: DateTime(2026, 10, 21, 9, 30),
    filePath: 'C:/trash/chapters/n1/$id.json',
  );
}

void main() {
  Future<void> open(WidgetTester tester, ChapterTrashStore store) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    showChapterTrashDialog(context, store, novelId: 'n1'),
                child: const Text('打开章节回收站'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开章节回收站'));
    await tester.pumpAndSettle();
  }

  testWidgets('列出已删章节的原位置与删除时间', (WidgetTester tester) async {
    await open(
      tester,
      _FakeChapterTrash(<ChapterTrashEntry>[
        _entry('c2', '被删的第二章'),
        _entry('c3', '被删的第三章', order: 5),
      ]),
    );

    expect(find.text('章节回收站'), findsOneWidget);
    expect(find.text('被删的第二章'), findsOneWidget);
    expect(find.textContaining('原第 3 章'), findsOneWidget);
    expect(find.textContaining('2026-10-21 09:30'), findsNWidgets(2));
    expect(find.text('清空回收站'), findsOneWidget);
  });

  testWidgets('恢复章节会调用 store 并刷新列表', (WidgetTester tester) async {
    final _FakeChapterTrash store = _FakeChapterTrash(<ChapterTrashEntry>[
      _entry('c2', '被删的第二章'),
      _entry('c3', '被删的第三章'),
    ]);
    await open(tester, store);

    await tester.tap(find.byTooltip('恢复章节').first);
    await tester.pumpAndSettle();

    expect(store.restored, 1);
    expect(find.text('被删的第二章'), findsNothing);
    expect(find.text('被删的第三章'), findsOneWidget);
    expect(find.textContaining('已恢复'), findsOneWidget);
  });

  testWidgets('永久删除章节需要二次确认', (WidgetTester tester) async {
    final _FakeChapterTrash store = _FakeChapterTrash(<ChapterTrashEntry>[
      _entry('c2', '被删的第二章'),
      _entry('c3', '被删的第三章'),
    ]);
    await open(tester, store);

    await tester.tap(find.byTooltip('永久删除章节').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('永久删除「被删的第二章」'), findsOneWidget);
    expect(store.purged, 0);

    await tester.tap(find.text('永久删除').last);
    await tester.pumpAndSettle();
    expect(store.purged, 1);
    expect(find.text('被删的第二章'), findsNothing);
  });

  testWidgets('清空章节回收站需要二次确认', (WidgetTester tester) async {
    final _FakeChapterTrash store = _FakeChapterTrash(<ChapterTrashEntry>[
      _entry('c2', '被删的第二章'),
      _entry('c3', '被删的第三章'),
    ]);
    await open(tester, store);

    await tester.tap(find.text('清空回收站'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 个已删章节'), findsOneWidget);

    await tester.tap(find.text('全部删除'));
    await tester.pumpAndSettle();
    expect(store.purgedAll, 1);
    expect(find.text('没有已删除的章节'), findsOneWidget);
  });

  testWidgets('空章节回收站给出说明', (WidgetTester tester) async {
    await open(tester, _FakeChapterTrash(<ChapterTrashEntry>[]));
    expect(find.text('没有已删除的章节'), findsOneWidget);
    expect(find.textContaining('30 天'), findsOneWidget);
  });

  testWidgets('读取失败可重试', (WidgetTester tester) async {
    final _FakeChapterTrash store = _FakeChapterTrash(<ChapterTrashEntry>[])
      ..failList = true;
    await open(tester, store);
    expect(find.text('章节回收站读取失败'), findsOneWidget);
    store.failList = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('没有已删除的章节'), findsOneWidget);
  });

  testWidgets('窄窗口下不横向溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await open(
      tester,
      _FakeChapterTrash(<ChapterTrashEntry>[_entry('c2', '窄窗口里的章节')]),
    );
    expect(find.text('窄窗口里的章节'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
