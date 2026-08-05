import 'package:novel_writer/core/constants/app_constants.dart';

/// 章节实体。
///
/// 隶属于某个 [Novel]（通过 [novelId] 关联），按 [order] 排序。
/// 内容在本机以纯文本保存，字数由 [wordCount] 统计（复用 [AppConstants.countWords]）。
class Chapter {
  /// 全局唯一主键（uuid v4）。
  final String id;

  /// 所属项目主键。
  final String novelId;

  /// 章节标题。
  final String title;

  /// 排序序号（从 0 开始）。
  final int order;

  /// 正文内容（纯文本）。
  final String content;

  /// 章节大纲 / 要点（可选，空串表示无大纲）。
  final String outline;

  /// 创建时间。
  final DateTime createdAt;

  /// 最后更新时间。
  final DateTime updatedAt;

  /// 构造章节实体。
  const Chapter({
    required this.id,
    required this.novelId,
    required this.title,
    required this.order,
    required this.content,
    this.outline = '',
    required this.createdAt,
    required this.updatedAt,
  });

  /// 统计本章正文字数。
  int wordCount() => AppConstants.countWords(content);

  /// 从 JSON 反序列化（用于单 json 文件读取）。
  factory Chapter.fromJson(Map<String, dynamic> json) {
    return Chapter(
      id: json['id'] as String,
      novelId: json['novelId'] as String,
      title: json['title'] as String,
      order: json['order'] as int,
      content: (json['content'] as String?) ?? '',
      outline: (json['outline'] as String?) ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  /// 序列化为 JSON（用于单 json 文件写入）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'novelId': novelId,
        'title': title,
        'order': order,
        'content': content,
        'outline': outline,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  /// 不可变更新副本。
  Chapter copyWith({
    String? id,
    String? novelId,
    String? title,
    int? order,
    String? content,
    String? outline,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Chapter(
      id: id ?? this.id,
      novelId: novelId ?? this.novelId,
      title: title ?? this.title,
      order: order ?? this.order,
      content: content ?? this.content,
      outline: outline ?? this.outline,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
