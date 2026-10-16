import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/theme/app_theme.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/features/reader/reader_page.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/reader_settings.dart';
import 'package:novel_writer/models/world_setting.dart';

/// 阅读器版式回归。
///
/// 两类检查：
/// 1. **版式体检**（任何环境都跑）：**正文限宽生效**、三主题都能渲染完、
///    进度条在、无溢出异常。
/// 2. **截图对比**（仅本地，`INK_GOLDEN=1` 时开）：三主题各一张，字体用系统 CJK
///    注册成主题声明的家族名，图上字距/行高与真机一致。
///
/// 为什么值得单独一份：阅读器是「排版」最敏感的一屏（限宽、行高、字距、主题底色），
/// 而且它**不依赖**任何 repository 读盘（只吃 provider + 一个 Novel 值对象），
/// 是少数能在 widget 测试里完整渲染的整页。
void main() {
  final Novel novel = _sampleNovel();
  final bool record = Platform.environment.containsKey('INK_GOLDEN');

  const List<(String, ReaderTheme)> themes = <(String, ReaderTheme)>[
    ('light', ReaderTheme.light),
    ('sepia', ReaderTheme.sepia),
    ('dark', ReaderTheme.dark),
  ];

  setUpAll(() async {
    await _loadCjkFonts();
  });

  for (final (String name, ReaderTheme theme) in themes) {
    testWidgets('阅读器版式体检 · $name', (WidgetTester tester) async {
      await _pumpReader(tester, novel: novel, theme: theme, width: 1280);

      expect(find.textContaining('第一章'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 正文限宽：桌面宽窗口下正文块必须被夹住——不限宽一行会到 60+ 字，
      // 眼睛回到下一行找不到起点。这条断言就是那处修复的哨兵。
      final double w =
          tester.getSize(find.byKey(const Key('reader-body'))).width;
      expect(w, lessThanOrEqualTo(AppTokens.maxWidthReading),
          reason: '正文宽度必须被 maxWidthReading 夹住');

      // 阅读进度条存在。
      expect(find.byType(LinearProgressIndicator), findsWidgets);
    });
  }

  testWidgets('golden：阅读器三主题截图对比（仅本地）', (WidgetTester tester) async {
    if (!record) return;
    for (final (String name, ReaderTheme theme) in themes) {
      await _pumpReader(tester, novel: novel, theme: theme, width: 1280);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/reader_$name.png'),
      );
    }
  }, skip: !record);
}

/// 以固定窗口尺寸渲染阅读器。
Future<void> _pumpReader(
  WidgetTester tester, {
  required Novel novel,
  required ReaderTheme theme,
  required double width,
}) async {
  tester.view.physicalSize = Size(width * 2, 900 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        // 直接灌状态：真实 controller 会在构造时发起读盘，而 fake-async 下
        // 文件 IO 不会完成，state 就停在我们设的初始值上。
        readerSettingsProvider.overrideWith(
          (Ref ref) => _StubReaderSettings(ReaderSettings(theme: theme)),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        debugShowCheckedModeBanner: false,
        home: ReaderPage(novel: novel),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // 兜底：无论是「读盘完成把 state 覆盖回默认」还是别的时序，这里从容器
  // 重设一次，把主题钉死（update 只改内存状态，落盘失败不影响断言）。
  final ProviderContainer container =
      ProviderScope.containerOf(tester.element(find.byType(ReaderPage)));
  container
      .read(readerSettingsProvider.notifier)
      .update(ReaderSettings(theme: theme));
  await tester.pumpAndSettle();
}

/// 直接灌状态的阅读设置（不读盘）。
class _StubReaderSettings extends ReaderSettingsController {
  _StubReaderSettings(ReaderSettings initial)
      : super(ReaderSettingsRepository(Directory.systemTemp.path)) {
    state = initial;
  }
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

Novel _sampleNovel() {
  final DateTime t = DateTime(2026, 10, 1);
  Chapter ch(int order, String title, String content) => Chapter(
        id: 'c$order',
        novelId: 'n1',
        title: title,
        order: order,
        content: content,
        outline: '本章大纲',
        createdAt: t,
        updatedAt: t,
      );
  return Novel(
    id: 'n1',
    title: '碎星航线',
    genre: 'kehuan',
    tone: 'standard',
    targetWordsPerChapter: 2000,
    createdAt: t,
    updatedAt: t,
    chapters: <Chapter>[
      ch(
        1,
        '第一章 除名',
        '　　夜色压在碎星港的穹顶上，货舱的灯一盏一盏灭下去。林昭把最后一箱样本搬上船，'
            '抬眼看了一眼航线图——那条被标红的线，从没有人活着走完过。\n\n'
            '　　「你要去哪？」守港人把通行牌递过来，手在抖。\n\n'
            '　　「去线的另一头。」林昭接过牌子，指腹在边缘那道旧痕上停了半秒。'
            '那是三年前留下的，母亲的名字还刻在上面。\n\n'
            '　　引擎点火的声音从脚底升起来，像某种古老的东西在翻身。港口的雾被推开，'
            '碎星一颗一颗从云里露出来。',
      ),
      ch(2, '第二章 灯塔', '　　第二段正文，用于验证翻页与进度。'),
    ],
    characters: const <Character>[],
    worldSettings: const <WorldSetting>[],
  );
}
