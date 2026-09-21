/// 角色实体。
///
/// 描述小说中的人物，可包含姓名、身份、性格、背景与人物关系。
/// 由 [SettingRepository] 管理，并在生成时被引擎读取以影响正文。
class Character {
  /// 全局唯一主键（uuid v4）。
  final String id;

  /// 所属项目主键。
  final String novelId;

  /// 角色姓名。
  final String name;

  /// 身份 / 角色定位（如「男主」「反派」「导师」）。
  final String role;

  /// 性格特征。
  final String traits;

  /// 背景故事。
  final String background;

  /// 人物关系。
  final String relationships;

  /// 说话风格（可选）：语气词、口头禅、句长、用词习惯等。
  /// 空串表示未设置，生成时按默认风格处理。
  final String dialogueStyle;

  /// 构造角色实体。
  const Character({
    required this.id,
    required this.novelId,
    required this.name,
    required this.role,
    required this.traits,
    required this.background,
    required this.relationships,
    this.dialogueStyle = '',
  });

  /// 从 JSON 反序列化。
  factory Character.fromJson(Map<String, dynamic> json) {
    return Character(
      id: json['id'] as String,
      novelId: json['novelId'] as String,
      name: (json['name'] as String?) ?? '',
      role: (json['role'] as String?) ?? '',
      traits: (json['traits'] as String?) ?? '',
      background: (json['background'] as String?) ?? '',
      relationships: (json['relationships'] as String?) ?? '',
      dialogueStyle: (json['dialogueStyle'] as String?) ?? '',
    );
  }

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'novelId': novelId,
        'name': name,
        'role': role,
        'traits': traits,
        'background': background,
        'relationships': relationships,
        'dialogueStyle': dialogueStyle,
      };

  /// 不可变更新副本。
  Character copyWith({
    String? id,
    String? novelId,
    String? name,
    String? role,
    String? traits,
    String? background,
    String? relationships,
    String? dialogueStyle,
  }) {
    return Character(
      id: id ?? this.id,
      novelId: novelId ?? this.novelId,
      name: name ?? this.name,
      role: role ?? this.role,
      traits: traits ?? this.traits,
      background: background ?? this.background,
      relationships: relationships ?? this.relationships,
      dialogueStyle: dialogueStyle ?? this.dialogueStyle,
    );
  }

  /// 值语义比较：记忆管线用 `merged != existing` 判断「是否有实质变化」，
  /// 缺省的身份比较会让 copyWith 结果恒不等于原对象 → 每次 LLM 提取同名
  /// 角色都重写落库（写放大 + 更新时间无意义递增）。
  @override
  bool operator ==(Object other) =>
      other is Character &&
      other.id == id &&
      other.novelId == novelId &&
      other.name == name &&
      other.role == role &&
      other.traits == traits &&
      other.background == background &&
      other.relationships == relationships &&
      other.dialogueStyle == dialogueStyle;

  @override
  int get hashCode => Object.hash(
        id,
        novelId,
        name,
        role,
        traits,
        background,
        relationships,
        dialogueStyle,
      );
}
