import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/project_list/trash_dialog.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/storage/trash_service.dart';

class _FakeTrash implements TrashStore {
  _FakeTrash(this.entries);

  final List<TrashEntry> entries;
  int restored = 0;
  int purged = 0;
  int purgedAll = 0;
  bool failList = false;

  @override
  Future<List<TrashEntry>> list() async {
    if (failList) throw StateError('磁盘不可用');
    return List<TrashEntry>.of(entries);
  }

  @override
  Future<Novel> restore(TrashEntry entry) async {
    entries.remove(entry);
    restored++;
    return Novel(
      id: entry.id,
      title: entry.title,
      genre: 'xuanhuan',
      tone: '热血',
      targetWordsPerChapter: 2000,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      chapters: const <Chapter>[],
      characters: const <Character>[],
      worldSettings: const <WorldSetting>[],
    );
  }

  @override
  Future<void> purge(TrashEntry entry) async {
    entries.remove(entry);
    purged++;
  }

  @override
  Future<void> purgeAll() async {
    entries.clear();
    purgedAll++;
  }
}

TrashEntry _entry(String id, String title, {int chapters = 3}) {
  return TrashEntry(
    id: id,
    title: title,
    genre: 'xuanhuan',
    chapterCount: chapters,
    wordCount: 12345,
    deletedAt: DateTime(2026, 10, 20, 14, 5),
    folderPath: 'C:/trash/$id',
  );
}

void main() {
  Future<void> open(WidgetTester tester, TrashStore store) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showTrashDialog(context, store),
                child: const Text('打开回收站'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开回收站'));
    await tester.pumpAndSettle();
  }

  testWidgets('回收站列出删除时间、章数与字数', (WidgetTester tester) async {
    final _FakeTrash store = _FakeTrash(<TrashEntry>[
      _entry('n1', '被删的书'),
      _entry('n2', '另一本书', chapters: 1),
    ]);
    await open(tester, store);

    expect(find.text('回收站'), findsOneWidget);
    expect(find.text('被删的书'), findsOneWidget);
    expect(find.text('另一本书'), findsOneWidget);
    expect(find.textContaining('3 章'), findsOneWidget);
    expect(find.textContaining('2026-10-20 14:05'), findsNWidgets(2));
    expect(find.text('清空回收站'), findsOneWidget);
  });

  testWidgets('点恢复会调用 store 并刷新到只剩另一本', (WidgetTester tester) async {
    final _FakeTrash store = _FakeTrash(<TrashEntry>[
      _entry('n1', '被删的书'),
      _entry('n2', '另一本书'),
    ]);
    await open(tester, store);

    await tester.tap(find.byTooltip('恢复').first);
    await tester.pumpAndSettle();

    expect(store.restored, 1);
    expect(find.text('被删的书'), findsNothing);
    expect(find.text('另一本书'), findsOneWidget);
    expect(find.textContaining('已恢复到书架'), findsOneWidget);
  });

  testWidgets('永久删除需要二次确认', (WidgetTester tester) async {
    final _FakeTrash store = _FakeTrash(<TrashEntry>[
      _entry('n1', '被删的书'),
      _entry('n2', '另一本书'),
    ]);
    await open(tester, store);

    await tester.tap(find.byTooltip('永久删除').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('永久删除《被删的书》'), findsOneWidget);
    expect(store.purged, 0);

    await tester.tap(find.text('永久删除').last);
    await tester.pumpAndSettle();
    expect(store.purged, 1);
    expect(find.text('被删的书'), findsNothing);
  });

  testWidgets('清空回收站需要二次确认', (WidgetTester tester) async {
    final _FakeTrash store = _FakeTrash(<TrashEntry>[
      _entry('n1', '被删的书'),
      _entry('n2', '另一本书'),
    ]);
    await open(tester, store);

    await tester.tap(find.text('清空回收站'));
    await tester.pumpAndSettle();
    expect(find.textContaining('永久删除回收站中的 2 本作品'), findsOneWidget);

    await tester.tap(find.text('全部删除'));
    await tester.pumpAndSettle();
    expect(store.purgedAll, 1);
    expect(find.text('回收站是空的'), findsOneWidget);
    expect(find.text('清空回收站'), findsNothing);
  });

  testWidgets('空回收站给出说明而不是空白', (WidgetTester tester) async {
    await open(tester, _FakeTrash(<TrashEntry>[]));
    expect(find.text('回收站是空的'), findsOneWidget);
    expect(find.textContaining('30 天'), findsOneWidget);
  });

  testWidgets('读取失败时可重试', (WidgetTester tester) async {
    final _FakeTrash store = _FakeTrash(<TrashEntry>[])..failList = true;
    await open(tester, store);

    expect(find.text('回收站读取失败'), findsOneWidget);
    store.failList = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('回收站是空的'), findsOneWidget);
  });

  testWidgets('窄窗口下不横向溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await open(tester, _FakeTrash(<TrashEntry>[_entry('n1', '窄窗口里的书')]));
    expect(find.text('窄窗口里的书'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
