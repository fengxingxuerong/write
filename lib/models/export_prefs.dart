/// 一键导出配置（随项目保存）。
///
/// 记住上次导出时「附带设定集」的开关状态，以及最近一次导出用的格式，
/// 让「一键导出全部」与单项导出保持用户习惯。
class ExportPrefs {
  /// 上次是否附带角色与世界观设定（默认 true，正文信息更完整）。
  final bool includeSettings;

  /// 上次使用的导出格式 key（ExportFormat.name）；null 表示从未导出。
  final String? lastFormat;

  /// 构造导出配置。
  const ExportPrefs({
    this.includeSettings = true,
    this.lastFormat,
  });

  /// 从 JSON 反序列化（容错缺字段回退默认）。
  factory ExportPrefs.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ExportPrefs();
    return ExportPrefs(
      includeSettings: (json['includeSettings'] as bool?) ?? true,
      lastFormat: json['lastFormat'] as String?,
    );
  }

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'includeSettings': includeSettings,
        if (lastFormat != null) 'lastFormat': lastFormat,
      };

  /// 不可变更新副本。
  ExportPrefs copyWith({
    bool? includeSettings,
    String? lastFormat,
  }) {
    return ExportPrefs(
      includeSettings: includeSettings ?? this.includeSettings,
      lastFormat: lastFormat ?? this.lastFormat,
    );
  }
}
