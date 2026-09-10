import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/features/workspace/chapter_list_panel.dart';
import 'package:novel_writer/models/chapter.dart';

Chapter _ch(int order, String title, String content, {String outline = ''}) => Chapter(
      id: 'c$order',
      novelId: 'n1',
      title: title,
      order: order,
      content: content,
      outline: outline,
      createdAt: DateTime(2026, 9, 1, order),
      updatedAt: DateTime(2026, 9, 1, order),
    );

Widget _wrap(Widget child) => MaterialApp(
      theme: AppThemeForTest.theme(),
      home: Scaffold(body: SizedBox(width: 260, height: 600, child: child)),
    );

void main() {
  testWidgets('章节行显示序号、标题与字数', (WidgetTester tester) async {
    final List<Chapter> chapters = <Chapter>[
      _ch(1, '第一章 除名', '甲' * 320),
      _ch(2, '第二章 立誓', '乙' * 45),
    ];
    await tester.pumpWidget(_wrap(ChapterListPanel(
      chapters: chapters,
      selectedChapterId: 'c1',
      onSelect: (_) {},
      onAdd: () {},
      onDelete: (_) {},
      onMoveUp: (_) {},
      onMoveDown: (_) {},
      onEditOutline: (_) {},
      onReorder: (_, __) {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('第一章 除名'), findsOneWidget);
    expect(find.text('第二章 立誓'), findsOneWidget);
    expect(find.text('320'), findsOneWidget, reason: '字数按章显示');
    expect(find.text('章节'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空列表给出可点的下一步，而不是「暂无章节」四个字', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(ChapterListPanel(
      chapters: const <Chapter>[],
      selectedChapterId: null,
      onSelect: (_) {},
      onAdd: () {},
      onDelete: (_) {},
      onMoveUp: (_) {},
      onMoveDown: (_) {},
      onEditOutline: (_) {},
      onReorder: (_, __) {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('还没有章节'), findsOneWidget);
    await tester.tap(find.text('新增章节'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('设了目标字数时，行内出现达成度进度条', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(ChapterListPanel(
      chapters: <Chapter>[_ch(1, '第一章', '甲' * 500)],
      selectedChapterId: null,
      onSelect: (_) {},
      onAdd: () {},
      onDelete: (_) {},
      onMoveUp: (_) {},
      onMoveDown: (_) {},
      onEditOutline: (_) {},
      onReorder: (_, __) {},
      targetWordsPerChapter: 1000,
    )));
    await tester.pumpAndSettle();

    final Finder bar = find.byType(LinearProgressIndicator);
    expect(bar, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(bar).value, closeTo(0.5, 0.01));
  });

  testWidgets('没有大纲的章节带一个提醒标记', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(ChapterListPanel(
      chapters: <Chapter>[
        _ch(1, '有大纲', '甲' * 10, outline: '本章要写什么'),
        _ch(2, '没大纲', '乙' * 10),
      ],
      selectedChapterId: null,
      onSelect: (_) {},
      onAdd: () {},
      onDelete: (_) {},
      onMoveUp: (_) {},
      onMoveDown: (_) {},
      onEditOutline: (_) {},
      onReorder: (_, __) {},
    )));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget,
        reason: '只给缺大纲的那章打提醒');
  });

  testWidgets('选中行后行内动作可点；未 hover 时菜单也能走通',
      (WidgetTester tester) async {
    String? selected;
    String? edited;
    await tester.pumpWidget(_wrap(ChapterListPanel(
      chapters: <Chapter>[_ch(1, '第一章', '甲' * 10, outline: 'o')],
      selectedChapterId: 'c1',
      onSelect: (String id) => selected = id,
      onAdd: () {},
      onDelete: (_) {},
      onMoveUp: (_) {},
      onMoveDown: (_) {},
      onEditOutline: (Chapter c) => edited = c.id,
      onReorder: (_, __) {},
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('第一章'));
    await tester.pump();
    expect(selected, 'c1');

    // 选中态下动作组不隐藏：直接点笔记图标。
    await tester.tap(find.byIcon(Icons.notes_outlined));
    await tester.pump();
    expect(edited, 'c1');

    // 菜单里的「编辑大纲」是同一件事的备用入口（触屏 / 键盘）。
    edited = null;
    await tester.tap(find.byTooltip('章节操作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('chapter-menu-outline')).last);
    await tester.pumpAndSettle();
    expect(edited, 'c1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除走菜单，且删除项在菜单里', (WidgetTester tester) async {
    String? deleted;
    await tester.pumpWidget(_wrap(ChapterListPanel(
      chapters: <Chapter>[_ch(1, '第一章', '甲' * 10, outline: 'o')],
      selectedChapterId: 'c1',
      onSelect: (_) {},
      onAdd: () {},
      onDelete: (String id) => deleted = id,
      onMoveUp: (_) {},
      onMoveDown: (_) {},
      onEditOutline: (_) {},
      onReorder: (_, __) {},
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('章节操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('chapter-menu-delete')));
    await tester.pumpAndSettle();
    expect(deleted, 'c1');
  });
}

/// 测试用主题：只挂语义色板，避免依赖 AppTheme 的完整装配。
class AppThemeForTest {
  static ThemeData theme() => ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppInk.light.paper,
        textTheme: const TextTheme(bodyMedium: TextStyle(fontSize: 13)),
      );
}
