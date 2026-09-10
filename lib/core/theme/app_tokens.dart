import 'package:flutter/material.dart';

/// 字体栈。
///
/// 桌面端（尤其 Windows）默认字体不含中文字形，必须显式给出 CJK 家族与回退链，
/// 否则中文会走系统兜底、字重与行高失控。UI 用黑体系，正文/阅读用衬体系。
class AppFonts {
  const AppFonts._();

  /// UI 字体主选。
  static const String ui = 'Microsoft YaHei UI';

  /// UI 字体回退链（覆盖 macOS / Linux / Windows 旧版）。
  static const List<String> uiFallback = <String>[
    'Microsoft YaHei',
    'PingFang SC',
    'Hiragino Sans GB',
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'WenQuanYi Micro Hei',
    'Segoe UI',
    'Roboto',
  ];

  /// 正文/阅读字体主选（衬线，中文长篇阅读的默认舒适选择）。
  static const String serif = 'Noto Serif SC';

  /// 衬线回退链。
  static const List<String> serifFallback = <String>[
    'Source Han Serif SC',
    'Songti SC',
    'STSong',
    'SimSun',
    'Noto Serif CJK SC',
    'serif',
  ];

  /// 数字/统计用等宽（对齐不错位）。
  static const String mono = 'Cascadia Mono';

  /// 等宽回退链。
  static const List<String> monoFallback = <String>[
    'Consolas',
    'JetBrains Mono',
    'Menlo',
    'DejaVu Sans Mono',
    'monospace',
  ];

  /// 组装一份带 CJK 回退的 [TextStyle]。
  static TextStyle text(
    Color color, {
    double size = 14,
    FontWeight weight = FontWeight.w400,
    double height = 1.6,
    double letterSpacing = 0,
    bool serifFace = false,
    bool monoFace = false,
  }) {
    return TextStyle(
      fontFamily: monoFace ? mono : (serifFace ? serif : ui),
      fontFamilyFallback: monoFace
          ? monoFallback
          : (serifFace ? serifFallback : uiFallback),
      color: color,
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
    );
  }
}

/// 应用主题（Material 3 + 自定语义色板）。
///
/// 设计取向：**纸墨**。宣纸底、墨青主色、朱砂只用在「AI 动作」和关键状态上；
/// 卡片用 1px 描边代替重投影，桌面端长会话不累眼。所有取值来自 [AppTokens] /
/// [AppInk]，本文件只负责把语义色映射成两套完整主题。

/// 设计令牌（Design Tokens）——全应用唯一的尺寸/色彩/动效来源。
///
/// 约定：页面与组件**不得**再写裸数字（`EdgeInsets.all(12)`）或裸色值，
/// 一律从这里取。改主题只改这一处，避免「12/16/24 混用」导致的节奏紊乱。
class AppTokens {
  /// 纯静态类，禁止实例化。
  const AppTokens._();

  // ---------------------------------------------------------------- 间距

  /// 4px——图标与文字之间、标签内边距。
  static const double s1 = 4;

  /// 8px——行内元素间距。
  static const double s2 = 8;

  /// 12px——卡片内小间隔。
  static const double s3 = 12;

  /// 16px——卡片内边距、区块间隔（默认档）。
  static const double s4 = 16;

  /// 24px——区块之间的呼吸。
  static const double s6 = 24;

  /// 32px——页面级留白。
  static const double s8 = 32;

  /// 卡片/面板统一内边距。
  static const EdgeInsets padCard = EdgeInsets.all(s4);

  /// 页面统一外边距。
  static const EdgeInsets padPage = EdgeInsets.symmetric(horizontal: s4, vertical: s3);

  /// 内容区最大宽度：宽屏下居中，避免正文一行拉到 200 字。
  static const double maxWidthReading = 760;

  /// 列表/表单页最大宽度。
  static const double maxWidthPanel = 1180;

  // ---------------------------------------------------------------- 圆角

  /// 4px——小标签、输入框内的按钮。
  static const double r1 = 4;

  /// 8px——按钮、输入框。
  static const double r2 = 8;

  /// 12px——卡片（默认档）。
  static const double r3 = 12;

  /// 16px——对话框、浮层。
  static const double r4 = 16;

  /// 20px——封面块等装饰容器。
  static const double r5 = 20;

  /// 卡片圆角。
  static const BorderRadius radiusCard = BorderRadius.all(Radius.circular(r3));

  /// 对话框圆角。
  static const BorderRadius radiusDialog = BorderRadius.all(Radius.circular(r4));

  // ---------------------------------------------------------------- 线条 / 动效

  /// 分隔线粗细。
  static const double hairline = 1;

  /// 卡片描边粗细（用 border 代替重阴影，桌面端更干净）。
  static const double cardBorder = 1;

  /// 快反馈（hover、按下）。
  static const Duration fast = Duration(milliseconds: 120);

  /// 常规过渡（展开、切换）。
  static const Duration normal = Duration(milliseconds: 220);

  /// 大面积移动（分栏、抽屉）。
  static const Duration slow = Duration(milliseconds: 320);

  /// 统一的减速曲线（进场自然、不弹）。
  static const Curve curve = Curves.easeOutCubic;

  // ---------------------------------------------------------------- 字号（编辑器/阅读器用）

  /// 编辑器正文最小可读字号。
  static const double editorFontMin = 14;

  /// 编辑器正文默认字号。
  static const double editorFontDefault = 17;

  /// 编辑器正文最大字号。
  static const double editorFontMax = 28;

  /// 中文行高：正文需要比西文更松。
  static const double lineHeightBody = 1.75;

  /// 编辑器行高（写作时长段落的可读性优先）。
  static const double lineHeightEditor = 1.9;
}

/// 语义色板（非 Material 生成色，手工定值）。
///
/// 主题只负责把「语义」映射到「明暗两套取值」；组件永远写
/// `AppInk.of(context).accent`，不写 `Colors.red[400]`。
@immutable
class AppInk {
  /// 纸面底色（页面背景）。
  final Color paper;

  /// 卡片面底色。
  final Color surface;

  /// 抬升面底色（悬浮层、输入区）。
  final Color surfaceRaised;

  /// 正文墨色（最高对比）。
  final Color ink;

  /// 次级文字（说明、元信息）。
  final Color inkSoft;

  /// 三级文字（占位、禁用）。
  final Color inkFaint;

  /// 分隔线。
  final Color divider;

  /// 卡片描边。
  final Color border;

  /// 主色（墨青）——主按钮、选中态、焦点环。
  final Color primary;

  /// 主色上的文字。
  final Color onPrimary;

  /// 强调色（朱砂）——AI 相关、关键动作、需要一眼看到的东西。
  final Color accent;

  /// 成功/达标（竹青）。
  final Color success;

  /// 警告（琥珀）。
  final Color warn;

  /// 危险/红线（胭脂）。
  final Color danger;

  /// 选中底色（半透明主色）。
  final Color selectTint;

  /// hover 底色（半透明墨色）。
  final Color hoverTint;

  /// 代码/统计数字底纹。
  final Color codeTint;

  /// 是否深色模式（组件里偶尔需要区分描边强度）。
  final bool dark;

  /// 构造语义色板。
  const AppInk({
    required this.paper,
    required this.surface,
    required this.surfaceRaised,
    required this.ink,
    required this.inkSoft,
    required this.inkFaint,
    required this.divider,
    required this.border,
    required this.primary,
    required this.onPrimary,
    required this.accent,
    required this.success,
    required this.warn,
    required this.danger,
    required this.selectTint,
    required this.hoverTint,
    required this.codeTint,
    required this.dark,
  });

  /// 浅色：宣纸底 + 墨青字。
  static const AppInk light = AppInk(
    paper: Color(0xFFF6F3EC),
    surface: Color(0xFFFFFDF8),
    surfaceRaised: Color(0xFFFFFFFF),
    ink: Color(0xFF23211E),
    inkSoft: Color(0xFF6A655C),
    inkFaint: Color(0xFF716B5B),
    divider: Color(0xFFE3DDD1),
    border: Color(0xFFE0DACC),
    primary: Color(0xFF2F5D62),
    onPrimary: Color(0xFFF6F3EC),
    accent: Color(0xFFB23A2C),
    success: Color(0xFF2F6B49),
    warn: Color(0xFF8F5F0E),
    danger: Color(0xFFB0342E),
    selectTint: Color(0x142F5D62),
    hoverTint: Color(0x0A23211E),
    codeTint: Color(0x0F23211E),
    dark: false,
  );

  /// 深色：墨底 + 淡纸字（夜间长时间写作不刺眼）。
  static const AppInk darkMode = AppInk(
    paper: Color(0xFF17191C),
    surface: Color(0xFF1E2126),
    surfaceRaised: Color(0xFF252A30),
    ink: Color(0xFFE8E4DB),
    inkSoft: Color(0xFFA9A49A),
    inkFaint: Color(0xFF8C877E),
    divider: Color(0xFF313640),
    border: Color(0xFF343A44),
    primary: Color(0xFF7FB7B2),
    onPrimary: Color(0xFF12171A),
    accent: Color(0xFFE0705C),
    success: Color(0xFF6FB189),
    warn: Color(0xFFD1A24C),
    danger: Color(0xFFE0776F),
    selectTint: Color(0x1F7FB7B2),
    hoverTint: Color(0x0FE8E4DB),
    codeTint: Color(0x14E8E4DB),
    dark: true,
  );

  /// 从最近的主题扩展中取出语义色板。
  static AppInk of(BuildContext context) {
    final _AppInkScope? scope =
        context.dependOnInheritedWidgetOfExactType<_AppInkScope>();
    return scope?.ink ?? (Theme.of(context).brightness == Brightness.dark
        ? darkMode
        : light);
  }

  /// 卡片阴影：浅色用极淡投影，深色用纯描边（阴影在黑底上无意义）。
  List<BoxShadow> shadow({bool raised = false}) {
    if (dark) return const <BoxShadow>[];
    return <BoxShadow>[
      BoxShadow(
        color: Color.fromRGBO(35, 33, 30, raised ? 0.10 : 0.05),
        blurRadius: raised ? 22 : 10,
        offset: Offset(0, raised ? 8 : 2),
      ),
    ];
  }
}

/// 语义色板的 InheritedWidget 载体，使 `AppInk.of(context)` 可随主题切换重建。
class _AppInkScope extends InheritedWidget {
  const _AppInkScope({required this.ink, required super.child});

  /// 当前明暗下的色板。
  final AppInk ink;

  @override
  bool updateShouldNotify(_AppInkScope oldWidget) => ink != oldWidget.ink;
}

/// 主题 → 语义色板的注入入口（app_theme.dart 组装 MaterialApp 时使用）。
class AppInkTheme extends StatelessWidget {
  /// 构造注入层。
  const AppInkTheme({super.key, required this.brightness, required this.child});

  /// 当前明暗模式。
  final Brightness brightness;

  /// 子树。
  final Widget child;

  @override
  Widget build(BuildContext context) => _AppInkScope(
        ink: brightness == Brightness.dark ? AppInk.darkMode : AppInk.light,
        child: child,
      );
}

/// 题材色：让首页卡片、章节列表、统计图在视觉上按题材区分。
///
/// 取值刻意压饱和度（与宣纸底/墨底协调），只用于小面积色块与描边。
class GenreColors {
  const GenreColors._();

  /// 未知题材的中性灰。
  static const Color neutral = Color(0xFF8C8579);

  /// 题材 key → 色值（key 与 `GenrePresets` 保持一致；后四个是流水线侧常用的别名）。
  static const Map<String, Color> map = <String, Color>{
    'xuanhuan': Color(0xFF8E5A9E),
    'xianxia': Color(0xFF4E7FA8),
    'dushi': Color(0xFF5E7F4F),
    'lishi': Color(0xFF9A7B3F),
    'kehuan': Color(0xFF3C7C86),
    'game': Color(0xFFC1783B),
    'jingsai': Color(0xFF3F8A6E),
    'yanqing': Color(0xFFBE6280),
    'xuanyi': Color(0xFF5A5F7A),
    'kongbu': Color(0xFF8A3B3B),
    // 别名（与 scripts/GENRE_SPECS 对齐）。
    'wuxia': Color(0xFF9C5C43),
    'tiyu': Color(0xFF3F8A6E),
    'junshi': Color(0xFF5C6B4A),
    'youxi': Color(0xFFC1783B),
  };

  /// 取题材色，未知返回 [neutral]。
  static Color of(String genre) => map[genre] ?? neutral;

  /// 题材色的淡底（用于封面块背景）。
  static Color tint(String genre, AppInk ink) {
    final Color c = of(genre);
    return ink.dark ? c.withValues(alpha: 0.18) : c.withValues(alpha: 0.12);
  }
}
