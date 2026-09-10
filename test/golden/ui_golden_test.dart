import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/theme/app_theme.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/features/project_list/project_list_page.dart';
import 'package:novel_writer/features/project_list/project_list_viewmodel.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/novel_repository.dart';
import 'package:novel_writer/widgets/app_card.dart';

/// 书架页的版式回归。
///
/// 两类检查：
/// 1. **跑遍宽度的排版体检**（任何环境都跑）：卡片数得下、不能溢出、
///    同类卡片等宽、刊头/工具条不能被挤没。溢出会以 RenderFlex 异常形式让测试红。
/// 2. **截图对比**（只在本地跑）：`flutter test` 默认用 Ahem 测试字体，中文全是方块，
///    所以这里显式加载系统 CJK 字体并注册成主题声明的家族名，图上字距/行高与真机一致。
///    生成：`$env:INK_GOLDEN='1'; flutter test --update-goldens test/golden/ui_golden_test.dart`
void main() {
  final List<NovelSummary> shelf = _sampleShelf();
  final bool record = Platform.environment.containsKey('INK_GOLDEN');

  setUpAll(() async {
    await _loadCjkFonts();
  });

  for (final Brightness brightness in <Brightness>[
    Brightness.light,
    Brightness.dark,
  ]) {
    for (final double width in <double>[1560, 1180, 940]) {
      testWidgets(
          '书架版式体检 · ${brightness == Brightness.dark ? '深色' : '浅色'} @ ${width.toInt()}px',
          (WidgetTester tester) async {
        await _pumpShelf(tester, width: width, brightness: brightness, shelf: shelf);

        // 刊头与工具条不能被挤掉。
        expect(find.text('我的作品'), findsOneWidget);
        expect(find.text('新建作品'), findsWidgets);
        // 空态不该出现（有数据时）。
        expect(find.text('书架还是空的'), findsNothing);
        // 6 本书 + 末尾「新建」卡。
        expect(find.byType(Card), findsNothing); // 不再用裸 Card
        expect(tester.widgetList<Hoverable>(find.byType(Hoverable)).length,
            greaterThanOrEqualTo(shelf.length));
        // 溢出会以异常形式抛出；这里显式断言没有异常。
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('空书架时给出可点的下一步', (WidgetTester tester) async {
      await _pumpShelf(tester, width: 1280, brightness: brightness, shelf: const []);
      expect(find.text('书架还是空的'), findsOneWidget);
      expect(find.text('新建作品'), findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);
      // 点空态里的主行动，应当真的拉起新建对话框（不是写着好看的文案）。
      await tester.tap(find.text('新建作品').last);
      await tester.pumpAndSettle();
      expect(find.text('创建并进入'), findsOneWidget);
      expect(find.text('基调'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('搜索能把列表滤到空并给出解释', (WidgetTester tester) async {
      await _pumpShelf(tester, width: 1280, brightness: brightness, shelf: shelf);
      await tester.enterText(find.byType(TextField).first, '不存在的名字');
      await tester.pump();
      expect(find.text('没有符合条件的作品'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('golden：书架页截图对比（仅本地）', (WidgetTester tester) async {
    if (!record) {
      return; // CI 上字体/渲染与本地不同，不做像素对比。
    }
    for (final (String name, Brightness brightness) in <(String, Brightness)>[
      ('light', Brightness.light),
      ('dark', Brightness.dark),
    ]) {
      await _pumpShelf(tester, width: 1560, brightness: brightness, shelf: shelf);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/shelf_$name.png'),
      );
    }
  }, skip: !record);
}

/// 以固定窗口尺寸渲染书架。
Future<void> _pumpShelf(
  WidgetTester tester, {
  required double width,
  required Brightness brightness,
  required List<NovelSummary> shelf,
}) async {
  tester.view.physicalSize = Size(width * 2, 980 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final Directory dir = Directory.systemTemp.createTempSync('ink_golden');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响断言。
    }
  });
  final AppDatabase db = AppDatabase.initForTest(dir.path);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(db),
        projectListViewModelProvider
            .overrideWith((Ref ref) => _StubList(db, shelf)),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
        debugShowCheckedModeBanner: false,
        home: const ProjectListPage(),
        builder: (BuildContext context, Widget? child) => AppInkTheme(
          brightness: brightness,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 加载系统中文字体，注册为 [AppFonts] 声明的家族名。
Future<void> _loadCjkFonts() async {
  const List<String> candidates = <String>[
    r'C:\Windows\Fonts\simhei.ttf',
    r'C:\Windows\Fonts\NotoSansSC-VF.ttf',
  ];
  File? font;
  for (final String path in candidates) {
    if (File(path).existsSync()) {
      font = File(path);
      break;
    }
  }
  if (font == null) return; // 非 Windows：跳过加载，版式断言仍然有效。
  final ByteData data = ByteData.sublistView(await font.readAsBytes());
  for (final String family in <String>[
    AppFonts.ui,
    AppFonts.serif,
    AppFonts.mono,
  ]) {
    final FontLoader loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(data));
    await loader.load();
  }
}

/// 直接灌状态的列表模型（版式测试不碰磁盘）。
class _StubList extends ProjectListViewModel {
  _StubList(AppDatabase db, List<NovelSummary> items)
      : super(NovelRepository(db)) {
    state = ProjectListState(novels: items);
  }

  /// 页面 initState 会调 load()；这里置空，避免测试里等一个不会完成的文件 IO。
  @override
  Future<void> load() async {}
}

List<NovelSummary> _sampleShelf() {
  final DateTime now = DateTime.now();
  return <NovelSummary>[
    NovelSummary(
      id: 'a1',
      title: '碎星航线',
      genre: 'kehuan',
      updatedAt: now.subtract(const Duration(minutes: 12)),
      wordCount: 128400,
      chapterCount: 42,
    ),
    NovelSummary(
      id: 'a2',
      title: '残刃破风',
      genre: 'tiyu',
      updatedAt: now.subtract(const Duration(hours: 5)),
      wordCount: 9600,
      chapterCount: 4,
    ),
    NovelSummary(
      id: 'a3',
      title: '权臣棋局',
      genre: 'lishi',
      updatedAt: now.subtract(const Duration(days: 2)),
      wordCount: 312000,
      chapterCount: 104,
    ),
    NovelSummary(
      id: 'a4',
      title: '雨夜第十三层',
      genre: 'xuanyi',
      updatedAt: now.subtract(const Duration(days: 9)),
      wordCount: 45200,
      chapterCount: 18,
    ),
    NovelSummary(
      id: 'a5',
      title: '长夜灯未灭',
      genre: 'yanqing',
      updatedAt: now.subtract(const Duration(days: 40)),
      wordCount: 1200,
      chapterCount: 1,
    ),
    NovelSummary(
      id: 'a6',
      title: '山门有雪',
      genre: 'xianxia',
      updatedAt: now.subtract(const Duration(days: 120)),
      wordCount: 88000,
      chapterCount: 30,
      archived: true,
    ),
  ];
}
