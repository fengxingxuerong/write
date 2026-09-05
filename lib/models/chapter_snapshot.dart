import 'dart:convert';

/// 章节版本快照：某一次保存时的章节内容留底。
///
/// 落盘为独立 json 文件（`snapshots/{novelId}/{chapterId}/{millis}.json`），
/// 不进入单本小说的主 json，避免版本历史膨胀主文件。
class ChapterSnapshot {
  /// 构造快照。
  const ChapterSnapshot({
    required this.savedAt,
    required this.title,
    required this.content,
  });

  /// 从 JSON 反序列化。
  factory ChapterSnapshot.fromJson(Map<String, dynamic> json) {
    return ChapterSnapshot(
      savedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['savedAt'] as int?) ?? 0,
      ),
      title: (json['title'] as String?) ?? '',
      content: (json['content'] as String?) ?? '',
    );
  }

  /// 快照时间。
  final DateTime savedAt;

  /// 当时的章节标题。
  final String title;

  /// 当时的正文全文。
  final String content;

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'savedAt': savedAt.millisecondsSinceEpoch,
        'title': title,
        'content': content,
      };

  /// 编码为落盘字符串。
  String encode() => jsonEncode(toJson());
}
