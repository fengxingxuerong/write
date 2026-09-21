import 'package:flutter/material.dart';

/// 把正文中的实体名（角色/地名等）标成淡色底的高亮 [TextSpan]。
///
/// 只用于**只读渲染**（阅读模式），不做编辑态文本控制器：
/// - 实体名过滤掉单字（「他」「雨」这类单字误伤率过高），并按长度降序参与
///   匹配，避免「林舟」被更短的「林」抢先切断；
/// - 单次正则扫描（[RegExp.allMatches]），不做 N×M 次 indexOf；
/// - 文本超过 [maxScanLength] 时直接返回纯文本，保护超长章节的渲染耗时。
///
/// 找不到任何实体时返回等价的纯文本 span，调用方无需分支。
TextSpan entityHighlightedSpan({
  required String text,
  required TextStyle baseStyle,
  required Iterable<String> entityNames,
  required Color highlightColor,
  int maxScanLength = 60000,
}) {
  final List<String> names = entityNames
      .map((String n) => n.trim())
      .where((String n) => n.length >= 2)
      .toSet()
      .toList()
    ..sort((String a, String b) => b.length.compareTo(a.length));
  if (text.isEmpty || names.isEmpty || text.length > maxScanLength) {
    return TextSpan(text: text, style: baseStyle);
  }

  final RegExp pattern = RegExp(names.map(RegExp.escape).join('|'));
  final List<InlineSpan> spans = <InlineSpan>[];
  int cursor = 0;
  for (final RegExpMatch match in pattern.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(TextSpan(
        text: text.substring(cursor, match.start),
        style: baseStyle,
      ));
    }
    spans.add(TextSpan(
      text: match.group(0),
      style: baseStyle.copyWith(backgroundColor: highlightColor),
    ));
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
  }
  return TextSpan(style: baseStyle, children: spans);
}
