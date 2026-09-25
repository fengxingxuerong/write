import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/theme/app_theme.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/features/project_list/novel_card.dart';
import 'package:novel_writer/models/novel.dart';

/// NovelCard 交互测试：打开按钮、更多操作菜单、归档态与无菜单分支。
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(
      body: Center(child: SizedBox(width: 320, height: 360, child: child)),
    ),
    builder: (BuildContext context, Widget? child) => AppInkTheme(
      brightness: Brightness.light,
      child: child ?? const SizedBox.shrink(),
    ),
  );

  NovelSummary summary({bool archived = false}) => NovelSummary(
    id: 'n1',
    title: '碎星航线',
    genre: 'kehuan',
    updatedAt: DateTime(2026, 9, 1),
    wordCount: 128400,
    chapterCount: 42,
    archived: archived,
  );

  testWidgets('未归档卡片：继续写作 + 更多操作全部回调', (WidgetTester tester) async {
    int opened = 0;
    int qa = 0;
    int renamed = 0;
    int archived = 0;
    int deleted = 0;

    await tester.pumpWidget(
      wrap(
        NovelCard(
          novel: summary(),
          height: 340,
          onOpen: () => opened++,
          onQa: () => qa++,
          onRename: () => renamed++,
          onArchive: () => archived++,
          onDelete: () => deleted++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('碎星航线'), findsOneWidget);
    expect(find.text('继续写作'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.byTooltip('更多操作'), findsOneWidget);

    await tester.tap(find.text('继续写作'));
    await tester.pump();
    expect(opened, 1);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('全书体检'), findsOneWidget);
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('归档'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect(renamed, 1);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('归档'));
    await tester.pumpAndSettle();
    expect(archived, 1);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(deleted, 1);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('全书体检'), findsOneWidget);
    await tester.tap(find.text('全书体检'));
    await tester.pumpAndSettle();
    expect(qa, 1);
  });

  testWidgets('归档卡片：显示归档标记与「取消归档」', (WidgetTester tester) async {
    int archived = 0;
    await tester.pumpWidget(
      wrap(
        NovelCard(
          novel: summary(archived: true),
          height: 340,
          onOpen: () {},
          onArchive: () => archived++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('打开查看'), findsOneWidget);
    expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
    expect(find.byIcon(Icons.unarchive_outlined), findsOneWidget);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('取消归档'), findsOneWidget);
    expect(find.text('归档'), findsNothing);
    await tester.tap(find.text('取消归档'));
    await tester.pumpAndSettle();
    expect(archived, 1);
  });

  testWidgets('未提供任何菜单回调时不渲染更多操作', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(NovelCard(novel: summary(), height: 340, onOpen: () {})),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('更多操作'), findsNothing);
    expect(find.text('继续写作'), findsOneWidget);
  });
}
