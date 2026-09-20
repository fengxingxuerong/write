/// 大纲字段的文本归一化。
///
/// 规划官按提示词契约会把 `world` 这类字段返回成**对象**
/// （如 `{"continent":..., "power_system":...}`），`protagonist` 亦然；
/// 而下游要的是可注入提示词的纯文本。以前这些位置写死 `as String?`，
/// 真实模型一按契约返回就抛类型错误、整任务失败。
///
/// 本函数把任意 JSON 值拍平成可读文本：
/// - String 原样返回；num/bool 用字面量；
/// - Map 按 `键：值` 逐行拼接（嵌套递归）；
/// - Iterable 用「、」连接（嵌套递归）；
/// - null 与其它类型返回空串。
String outlineText(dynamic value) {
  if (value == null) return '';
  if (value is String) return value.trim();
  if (value is num || value is bool) return value.toString();
  if (value is Map) {
    final List<String> parts = <String>[];
    for (final MapEntry<dynamic, dynamic> e in value.entries) {
      final String v = outlineText(e.value);
      if (v.isEmpty) continue;
      parts.add(e.key.toString().trim().isEmpty
          ? v
          : '${e.key.toString().trim()}：$v');
    }
    return parts.join('；');
  }
  if (value is Iterable) {
    return value
        .map(outlineText)
        .where((String e) => e.isNotEmpty)
        .join('、');
  }
  return '';
}