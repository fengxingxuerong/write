import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/utils/manuscript_parser.dart';
import 'package:novel_writer/features/project_list/manuscript_import_dialog.dart';
import 'package:novel_writer/storage/manuscript_import_service.dart';

void main() {
  const ParsedManuscript manuscript = ParsedManuscript(
    chapters: <ParsedManuscriptChapter>[
      ParsedManuscriptChapter(title: '第一章 起航', content: '飞船离港。'),
      ParsedManuscriptChapter(title: '第二章 星尘', content: '前方出现星尘带。'),
    ],
    detectedHeadings: true,
    totalWords: 11,
  );

  const ManuscriptImportPreview preview = ManuscriptImportPreview(
    fileName: '碎星航线.txt',
    suggestedTitle: '碎星航线',
    manuscript: manuscript,
  );

  Future<void> pumpPreviewDialog(
    WidgetTester tester,
    ManuscriptImportPreview data,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  showManuscriptImportPreview(context, data);
                },
                child: const Text('打开导入'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开导入'));
    await tester.pumpAndSettle();
  }

  testWidgets('预览展示章数、书名与章节列表', (WidgetTester tester) async {
    late Future<ManuscriptImportDraft?> pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  pending = showManuscriptImportPreview(context, preview);
                },
                child: const Text('打开导入'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开导入'));
    await tester.pumpAndSettle();

    expect(find.text('导入原稿'), findsOneWidget);
    expect(find.textContaining('2 章'), findsOneWidget);
    expect(find.text('第一章 起航'), findsOneWidget);
    expect(find.text('第二章 星尘'), findsOneWidget);
    expect(find.text('导入为新作品'), findsOneWidget);

    await tester.tap(find.text('导入为新作品'));
    await tester.pumpAndSettle();
    final ManuscriptImportDraft? draft = await pending;
    expect(draft, isNotNull);
    expect(draft!.title, '碎星航线');
    expect(draft.genre, 'xuanhuan');
    expect(draft.tone, '热血');
  });

  testWidgets('用户可以改书名、题材和基调', (WidgetTester tester) async {
    late Future<ManuscriptImportDraft?> pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  pending = showManuscriptImportPreview(context, preview);
                },
                child: const Text('打开导入'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开导入'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '新书名');
    await tester.tap(find.text('玄幻'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('科幻').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('哲思'));
    await tester.tap(find.text('哲思'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入为新作品'));
    await tester.pumpAndSettle();

    final ManuscriptImportDraft? draft = await pending;
    expect(draft?.title, '新书名');
    expect(draft?.genre, 'kehuan');
    expect(draft?.tone, '哲思');
  });

  testWidgets('未识别到章节标题时给出明确提示', (WidgetTester tester) async {
    const ManuscriptImportPreview fallback = ManuscriptImportPreview(
      fileName: '短篇.txt',
      suggestedTitle: '短篇',
      manuscript: ParsedManuscript(
        chapters: <ParsedManuscriptChapter>[
          ParsedManuscriptChapter(title: '第1章', content: '整篇正文。'),
        ],
        detectedHeadings: false,
        totalWords: 4,
      ),
    );
    await pumpPreviewDialog(tester, fallback);
    expect(find.textContaining('没有识别到'), findsOneWidget);
  });

  testWidgets('书名为空时不关闭弹窗', (WidgetTester tester) async {
    await pumpPreviewDialog(tester, preview);
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.tap(find.text('导入为新作品'));
    await tester.pump();
    expect(find.text('导入原稿'), findsOneWidget);
    expect(find.text('先给作品起个名字'), findsOneWidget);
  });

  testWidgets('导入来源选择器同时给出备份与原稿两条路', (WidgetTester tester) async {
    late Future<ImportSource?> pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  pending = showImportSourceDialog(context);
                },
                child: const Text('打开导入'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开导入'));
    await tester.pumpAndSettle();

    expect(find.text('墨匠 JSON 备份'), findsOneWidget);
    expect(find.text('TXT / Markdown 原稿'), findsOneWidget);

    await tester.tap(find.text('TXT / Markdown 原稿'));
    await tester.pumpAndSettle();
    expect(await pending, ImportSource.manuscript);
  });

  testWidgets('窄窗口下预览弹窗不会横向溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await pumpPreviewDialog(tester, preview);
    expect(find.text('导入原稿'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
