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

  /// 整本小说 JSON 编解码下沉后台 isolate 的字符量阈值。
  ///
  /// 单 json 全量写是本项目存储格式的基本操作；数百章 × 2 万字时
  /// `jsonEncode` 的输入可达数 MB，纯主 isolate 编码会掉帧。
  /// 内容字符量（含章节正文/存稿）超过该阈值才走 isolate，
  /// 小项目直接同步编解码，零 isolate 往返开销。
  static const int isolateJsonThresholdChars = 100000;

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
    bool inAsciiWord = false;
    final runes = text.runes;
    for (final r in runes) {
      // CJK 统一表意文字（基本区 + 扩展 A + 兼容区）：每字计 1。
      if (r >= 0x3400 && r <= 0x4DBF ||
          r >= 0x4E00 && r <= 0x9FFF ||
          r >= 0xF900 && r <= 0xFAFF) {
        count++;
        inAsciiWord = false;
      }
      // ASCII 字母或数字：连续成一个词，计 1。
      else if ((r >= 0x41 && r <= 0x5A) ||
               (r >= 0x61 && r <= 0x7A) ||
               (r >= 0x30 && r <= 0x39)) {
        if (!inAsciiWord) {
          count++;
          inAsciiWord = true;
        }
      } else {
        inAsciiWord = false;
      }
    }
    return count;
  }

  /// 将任意字符串转换为安全的文件名片段（去除路径分隔符、控制字符等）。
  static String safeFileName(String input) {
    final String trimmed =
        input.trim().replaceAll(RegExp(r'\s+'), '_').replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    final String cleaned = trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return cleaned.isEmpty ? '未命名作品' : cleaned;
  }

  /// 生成本地时间戳（yyyyMMdd_HHmmss），不依赖 intl 以避免多余依赖。
  static String timestamp([DateTime? time]) {
    final DateTime t = time ?? DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${p(t.month)}${p(t.day)}_${p(t.hour)}${p(t.minute)}${p(t.second)}';
  }
}
