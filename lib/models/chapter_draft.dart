/// 存稿箱条目。
///
/// AI 生成或手动暂存的不满意的章节草稿，不进入正式章节列表，
/// 可在存稿箱中预览、恢复（转为正式章节）或删除。
class ChapterDraft {
  /// 全局唯一主键（uuid v4）。
  final String id;

  /// 所属项目主键。
  final String novelId;

  /// 草稿标题（默认「第 N 章」风格，或用户自定义）。
  final String title;

  /// 草稿正文。
  final String content;

  /// 创建时间。
  final DateTime createdAt;

  /// 构造存稿箱条目。
  const ChapterDraft({
    required this.id,
    required this.novelId,
    required this.title,
    required this.content,
    required this.createdAt,
  });

  /// 统计草稿字数。
  int wordCount() {
    // 中文按字符计；与 AppConstants.countWords 保持一致的口径。
    return content.replaceAll(RegExp(r'\s'), '').length;
  }

  /// 从 JSON 反序列化（单 json 文件内）。
  factory ChapterDraft.fromJson(Map<String, dynamic> json) {
    return ChapterDraft(
      id: json['id'] as String,
      novelId: json['novelId'] as String,
      title: (json['title'] as String?) ?? '',
      content: (json['content'] as String?) ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'novelId': novelId,
        'title': title,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
      };

  /// 不可变更新副本。
  ChapterDraft copyWith({
    String? id,
    String? novelId,
    String? title,
    String? content,
    DateTime? createdAt,
  }) {
    return ChapterDraft(
      id: id ?? this.id,
      novelId: novelId ?? this.novelId,
      title: title ?? this.title,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
