/// 展示层格式化工具（时间/字数）。
///
/// 原来这些私有小函数散在 4 个页面里各写一遍，输出还不一致
/// （有的「3 天前」，有的「2026-09-05」）；集中一处便于测试。
class TextFmt {
  const TextFmt._();

  /// 相对时间：近期用「分钟/小时」，久了退回日期，避免列表里全是时间戳。
  static String relativeTime(DateTime value, {DateTime? now}) {
    final DateTime base = now ?? DateTime.now();
    final Duration d = base.difference(value);
    if (d.isNegative) {
      // 未来时间（时钟偏差/手工改文件）不显示「-3 分钟前」。
      return '刚刚';
    }
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    if (d.inDays == 1) return '昨天';
    if (d.inDays == 2) return '前天';
    if (d.inDays < 8) return '${d.inDays} 天前';
    if (value.year == base.year) {
      return '${value.month} 月 ${value.day} 日';
    }
    return '${value.year} 年 ${value.month} 月 ${value.day} 日';
  }

  /// 完整日期时间（用于详情/导出文件名）。
  static String dateTime(DateTime value) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${value.year}-${p(value.month)}-${p(value.day)} '
        '${p(value.hour)}:${p(value.minute)}';
  }

  /// 字数：一万以内给精确值，以上用「万」，长篇小说列表一眼能比量级。
  static String words(int count) {
    if (count < 10000) return count.toString();
    final double wan = count / 10000;
    final String s =
        wan >= 100 ? wan.toStringAsFixed(0) : wan.toStringAsFixed(wan >= 10 ? 1 : 2);
    return '${_trimZero(s)} 万';
  }

  static String _trimZero(String s) {
    if (!s.contains('.')) return s;
    String r = s;
    while (r.endsWith('0')) {
      r = r.substring(0, r.length - 1);
    }
    return r.endsWith('.') ? r.substring(0, r.length - 1) : r;
  }

  /// 千分位（统计面板用）。
  static String group(int value) {
    final String s = value.abs().toString();
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
      out.write(s[i]);
    }
    return (value < 0 ? '-' : '') + out.toString();
  }

  /// 百分比：0.391 → 「39%」（列表里不需要两位小数）。
  static String percent(double ratio, {bool signed = false}) {
    final int p = (ratio * 100).round();
    final String sign = signed && p > 0 ? '+' : '';
    return '$sign$p%';
  }

  /// 耗时：< 60s 用秒，以上用「x 分 y 秒」。
  static String duration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
    return '${d.inHours}h${(d.inMinutes % 60).toString().padLeft(2, '0')}m';
  }
}
