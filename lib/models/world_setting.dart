/// 世界观设定实体。
///
/// 描述小说世界中的势力、地理、规则、物品等设定条目。
/// 由 [SettingRepository] 管理，生成时引擎可读取以丰富正文细节。
class WorldSetting {
  /// 全局唯一主键（uuid v4）。
  final String id;

  /// 所属项目主键。
  final String novelId;

  /// 设定标题（如「修炼体系」「天玄大陆」）。
  final String title;

  /// 分类（如「地理」「势力」「规则」）。
  final String category;

  /// 设定正文 / 说明。
  final String content;

  /// 构造世界观设定实体。
  const WorldSetting({
    required this.id,
    required this.novelId,
    required this.title,
    required this.category,
    required this.content,
  });

  /// 从 JSON 反序列化。
  factory WorldSetting.fromJson(Map<String, dynamic> json) {
    return WorldSetting(
      id: json['id'] as String,
      novelId: json['novelId'] as String,
      title: (json['title'] as String?) ?? '',
      category: (json['category'] as String?) ?? '',
      content: (json['content'] as String?) ?? '',
    );
  }

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'novelId': novelId,
        'title': title,
        'category': category,
        'content': content,
      };

  /// 不可变更新副本。
  WorldSetting copyWith({
    String? id,
    String? novelId,
    String? title,
    String? category,
    String? content,
  }) {
    return WorldSetting(
      id: id ?? this.id,
      novelId: novelId ?? this.novelId,
      title: title ?? this.title,
      category: category ?? this.category,
      content: content ?? this.content,
    );
  }
}
