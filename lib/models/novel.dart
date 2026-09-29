import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/chapter_draft.dart';
import 'package:novel_writer/models/export_prefs.dart';
import 'package:novel_writer/models/style_ref.dart';
import 'package:novel_writer/models/world_setting.dart';

/// 小说项目实体（聚合根）。
///
/// 一个 [Novel] 包含若干 [Chapter]、[Character] 与 [WorldSetting]。
/// 在存储层，整本项目被序列化为**单个 JSON 文件**，天然支持跨端拷贝迁移。
class Novel {
  /// 全局唯一主键（uuid v4）。
  final String id;

  /// 项目标题。
  final String title;

  /// 题材 key（对应 [GenrePresets]）。
  final String genre;

  /// 基调。
  final String tone;

  /// 单章目标字数（仅作默认提示，生成时以配置为准）。
  final int targetWordsPerChapter;

  /// 创建时间。
  final DateTime createdAt;

  /// 最后更新时间。
  final DateTime updatedAt;

  /// 是否已归档（归档后从首页默认列表隐藏，可随时恢复）。
  final bool archived;

  /// 项目偏好的写作风格（生成弹窗默认值，随项目保存）。
  final String preferredStyle;

  /// 项目偏好的文风（生成弹窗默认值，随项目保存）。
  final String preferredProseStyle;

  /// 章节列表（有序）。
  final List<Chapter> chapters;

  /// 角色列表。
  final List<Character> characters;

  /// 世界观设定列表。
  final List<WorldSetting> worldSettings;

  /// 存稿箱条目列表（不参与正式章节，按创建时间倒序展示）。
  final List<ChapterDraft> drafts;

  /// 一键导出配置（记住上次的设定集开关与格式）。
  final ExportPrefs exportPrefs;

  /// 文风参考（P1-1，可空）。非空时生成会把该指纹注入写手提示词。
  ///
  /// 存的是**分布数值**而非原文——见 [StyleRef] 的说明。null = 未设置，生成行为
  /// 与旧版逐字一致。
  final StyleRef? styleRef;

  /// 构造项目实体。
  const Novel({
    required this.id,
    required this.title,
    required this.genre,
    required this.tone,
    required this.targetWordsPerChapter,
    required this.createdAt,
    required this.updatedAt,
    this.archived = false,
    this.preferredStyle = 'standard',
    this.preferredProseStyle = 'web',
    required this.chapters,
    required this.characters,
    required this.worldSettings,
    this.drafts = const <ChapterDraft>[],
    this.exportPrefs = const ExportPrefs(),
    this.styleRef,
  });

  /// 统计整本项目总字数（所有章节之和）。
  int wordCount() =>
      chapters.fold<int>(0, (int sum, Chapter c) => sum + c.wordCount());

  /// 从 JSON 反序列化（单 json 文件读取）。
  factory Novel.fromJson(Map<String, dynamic> json) {
    return Novel(
      id: json['id'] as String,
      title: json['title'] as String,
      genre: (json['genre'] as String?) ?? AppConstants.defaultGenre,
      tone: (json['tone'] as String?) ?? AppConstants.defaultTone,
      targetWordsPerChapter:
          (json['targetWordsPerChapter'] as int?) ?? AppConstants.defaultMaxWordsPerChapter,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      archived: (json['archived'] as bool?) ?? false,
      preferredStyle: (json['preferredStyle'] as String?) ?? 'standard',
      preferredProseStyle:
          (json['preferredProseStyle'] as String?) ?? 'web',
      chapters: (json['chapters'] as List<dynamic>? ?? <dynamic>[])
          .map((e) => Chapter.fromJson(e as Map<String, dynamic>))
          .toList(),
      characters: (json['characters'] as List<dynamic>? ?? <dynamic>[])
          .map((e) => Character.fromJson(e as Map<String, dynamic>))
          .toList(),
      worldSettings: (json['worldSettings'] as List<dynamic>? ?? <dynamic>[])
          .map((e) => WorldSetting.fromJson(e as Map<String, dynamic>))
          .toList(),
      drafts: (json['drafts'] as List<dynamic>? ?? <dynamic>[])
          .map((e) => ChapterDraft.fromJson(e as Map<String, dynamic>))
          .toList(),
      exportPrefs: ExportPrefs.fromJson(
          json['exportPrefs'] as Map<String, dynamic>?),
      // 老项目没有该字段 → tryFromJson(null) = null，行为与旧版一致。
      styleRef: StyleRef.tryFromJson(json['styleRef']),
    );
  }

  /// 序列化为 JSON（单 json 文件写入：meta + chapters + characters + worldSettings）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'genre': genre,
        'tone': tone,
        'targetWordsPerChapter': targetWordsPerChapter,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'archived': archived,
        'preferredStyle': preferredStyle,
        'preferredProseStyle': preferredProseStyle,
        'chapters': chapters.map((c) => c.toJson()).toList(),
        'characters': characters.map((c) => c.toJson()).toList(),
        'worldSettings': worldSettings.map((w) => w.toJson()).toList(),
        'drafts': drafts.map((d) => d.toJson()).toList(),
        'exportPrefs': exportPrefs.toJson(),
        'styleRef': styleRef?.toJson(),
      };

  /// 不可变更新副本。
  Novel copyWith({
    String? id,
    String? title,
    String? genre,
    String? tone,
    int? targetWordsPerChapter,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? archived,
    String? preferredStyle,
    String? preferredProseStyle,
    List<Chapter>? chapters,
    List<Character>? characters,
    List<WorldSetting>? worldSettings,
    List<ChapterDraft>? drafts,
    ExportPrefs? exportPrefs,
    StyleRef? styleRef,
    bool clearStyleRef = false,
  }) {
    return Novel(
      id: id ?? this.id,
      title: title ?? this.title,
      genre: genre ?? this.genre,
      tone: tone ?? this.tone,
      targetWordsPerChapter:
          targetWordsPerChapter ?? this.targetWordsPerChapter,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      archived: archived ?? this.archived,
      preferredStyle: preferredStyle ?? this.preferredStyle,
      preferredProseStyle:
          preferredProseStyle ?? this.preferredProseStyle,
      chapters: chapters ?? this.chapters,
      characters: characters ?? this.characters,
      worldSettings: worldSettings ?? this.worldSettings,
      drafts: drafts ?? this.drafts,
      exportPrefs: exportPrefs ?? this.exportPrefs,
      // copyWith 无法把 null 当作「要写 null」，故显式给 clearStyleRef 开关——
      // 否则「清除文风参考」只能整个字段丢掉重造，与本类其余可空字段的写法不一致。
      styleRef: clearStyleRef ? null : (styleRef ?? this.styleRef),
    );
  }
}

/// 项目摘要（用于首页列表与索引文件，避免整本反序列化）。
class NovelSummary {
  /// 项目主键。
  final String id;

  /// 项目标题。
  final String title;

  /// 题材 key。
  final String genre;

  /// 最后更新时间。
  final DateTime updatedAt;

  /// 是否已归档。
  final bool archived;

  /// 项目总字数（索引冗余，避免列表逐本读取）。
  final int wordCount;

  /// 章节数（索引冗余）。
  final int chapterCount;

  /// 构造摘要。
  const NovelSummary({
    required this.id,
    required this.title,
    required this.genre,
    required this.updatedAt,
    this.archived = false,
    this.wordCount = 0,
    this.chapterCount = 0,
  });

  /// 从 JSON 反序列化。
  factory NovelSummary.fromJson(Map<String, dynamic> json) {
    return NovelSummary(
      id: json['id'] as String,
      title: json['title'] as String,
      genre: (json['genre'] as String?) ?? '',
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      archived: (json['archived'] as bool?) ?? false,
      wordCount: (json['wordCount'] as int?) ?? 0,
      chapterCount: (json['chapterCount'] as int?) ?? 0,
    );
  }

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'genre': genre,
        'updatedAt': updatedAt.toIso8601String(),
        'archived': archived,
        'wordCount': wordCount,
        'chapterCount': chapterCount,
      };
}
