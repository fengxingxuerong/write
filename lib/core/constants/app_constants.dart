/// 全局常量与通用工具。
///
/// 集中存放路径、默认上限、防抖时间等全局配置，避免魔法数字散落各处。
class AppConstants {
  /// 应用名称。
  static const String appName = '墨匠 InkSmith';

  /// 项目数据子目录名（位于 applicationSupportDirectory 下）。
  static const String novelsDirName = 'novels';

  /// 单章生成目标字数上限（性能安全线），可配置。
  static const int defaultMaxWordsPerChapter = 20000;

  /// 编辑器自动保存防抖时间（毫秒）。主理人裁定：失焦/退出立即保存 + 防抖 3 秒。
  static const int autosaveDebounceMs = 3000;

  /// 一键生成默认目标字数。
  static const int defaultTargetWords = 2000;

  /// 默认题材与基调（见 genre_presets.dart）。
  static const String defaultGenre = 'xuanhuan';
  static const String defaultTone = '热血';

  /// 中文字数统计。
  ///
  /// 规则：CJK 统一字符（含扩展 A、兼容区）每字计 1；
  /// 连续的 ASCII 字母/数字串计 1（一个英文单词/数字）。
  /// 模型层 [Chapter.wordCount] / [Novel.wordCount] 复用此实现。
  static int countWords(String text) {
    if (text.isEmpty) return 0;
    int count = 0;
    // CJK 统一表意文字（基本区 + 扩展 A + 兼容区）。
    final RegExp cjk = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]');
    // 连续 ASCII 字母或数字，作为一个单词计 1。
    final RegExp asciiWord = RegExp(r'[A-Za-z0-9]+');
    count += cjk.allMatches(text).length;
    count += asciiWord.allMatches(text).length;
    return count;
  }

  /// 将任意字符串转换为安全的文件名片段（去除路径分隔符等）。
  static String safeFileName(String input) {
    final String trimmed = input.trim().replaceAll(RegExp(r'\s+'), '_');
    return trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  /// 生成本地时间戳（yyyyMMdd_HHmmss），不依赖 intl 以避免多余依赖。
  static String timestamp([DateTime? time]) {
    final DateTime t = time ?? DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${p(t.month)}${p(t.day)}_${p(t.hour)}${p(t.minute)}${p(t.second)}';
  }
}
