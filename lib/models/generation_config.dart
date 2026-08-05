import 'package:novel_writer/core/constants/app_constants.dart';

/// 生成约束。
///
/// 控制单章生成的安全边界，由 UI 在生成前装配进 [GenerationConfig]。
class GenerationConstraints {
  /// 单章字数上限（性能安全线，默认 20000）。
  final int maxWordsPerChapter;

  /// 是否允许句式/段落重复（默认 false，开启去重抑制）。
  final bool allowRepeat;

  /// 构造生成约束。
  const GenerationConstraints({
    this.maxWordsPerChapter = AppConstants.defaultMaxWordsPerChapter,
    this.allowRepeat = false,
  });

  /// 从 JSON 反序列化。
  factory GenerationConstraints.fromJson(Map<String, dynamic> json) {
    return GenerationConstraints(
      maxWordsPerChapter:
          (json['maxWordsPerChapter'] as int?) ?? AppConstants.defaultMaxWordsPerChapter,
      allowRepeat: (json['allowRepeat'] as bool?) ?? false,
    );
  }

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'maxWordsPerChapter': maxWordsPerChapter,
        'allowRepeat': allowRepeat,
      };

  /// 不可变更新副本。
  GenerationConstraints copyWith({
    int? maxWordsPerChapter,
    bool? allowRepeat,
  }) {
    return GenerationConstraints(
      maxWordsPerChapter: maxWordsPerChapter ?? this.maxWordsPerChapter,
      allowRepeat: allowRepeat ?? this.allowRepeat,
    );
  }
}

/// 一键生成配置。
///
/// 聚合题材、基调、目标字数、随机度与约束，作为 [GenerationEngine.generate] 的输入。
class GenerationConfig {
  /// 题材 key（对应 [GenrePresets]）。
  final String genre;

  /// 基调（对应题材预设的 tones）。
  final String tone;

  /// 目标字数（会被约束在 [GenerationConstraints.maxWordsPerChapter] 内）。
  final int targetWords;

  /// 是否复用项目已有的角色 / 世界观设定。
  final bool useExistingSettings;

  /// 指定主角名（可选，为空时由引擎从设定或语料中选取）。
  final String? protagonistName;

  /// 随机度（0=保守可复现，1=高度随机），影响种子与选词多样性。
  final double randomLevel;

  /// 承接上文（可选）：续写模式时传入上一章末尾文本，引擎会衔接剧情。
  final String? continuation;

  /// 连续生成章节数（默认 1）。>1 时引擎逐章承接上一章结尾连续生成。
  final int chapterCount;

  /// 卷纲（可选）：多章连写时每行一个要点，按顺序分配到各章推进。
  final String volumeOutline;

  /// 是否在生成前用 AI 把大纲扩写成场景序列（默认开启）。
  ///
  /// 仅当 [GenerationConfig.volumeOutline] 或 ctx.outline 非空时生效；
  /// 扩写让 2B 模型不必自己脑补结构，正文质量更稳。
  final bool expandOutline;

  /// 写作风格偏好（影响段落结构 / 节奏 / 对话占比）。
  final WritingStyle style;

  /// 文风（语言质感：现代网文 / 古龙简洁 / 金庸古典 / 日轻细腻）。
  final ProseStyle proseStyle;

  /// 生成约束。
  final GenerationConstraints constraints;

  /// 构造生成配置。
  const GenerationConfig({
    required this.genre,
    required this.tone,
    required this.targetWords,
    this.useExistingSettings = true,
    this.protagonistName,
    this.randomLevel = 0.5,
    this.continuation,
    this.chapterCount = 1,
    this.volumeOutline = '',
    this.expandOutline = true,
    this.style = WritingStyle.standard,
    this.proseStyle = ProseStyle.web,
    required this.constraints,
  });

  /// 从 JSON 反序列化。
  factory GenerationConfig.fromJson(Map<String, dynamic> json) {
    return GenerationConfig(
      genre: json['genre'] as String,
      tone: json['tone'] as String,
      targetWords: json['targetWords'] as int,
      useExistingSettings: (json['useExistingSettings'] as bool?) ?? true,
      protagonistName: json['protagonistName'] as String?,
      randomLevel: (json['randomLevel'] as num? ?? 0.5).toDouble(),
      continuation: json['continuation'] as String?,
      chapterCount: (json['chapterCount'] as int?) ?? 1,
      volumeOutline: (json['volumeOutline'] as String?) ?? '',
      expandOutline: (json['expandOutline'] as bool?) ?? true,
      style: WritingStyle.values.asNameMap()[json['style'] as String?] ??
          WritingStyle.standard,
      proseStyle: ProseStyle.values.asNameMap()[json['proseStyle'] as String?] ??
          ProseStyle.web,
      constraints: GenerationConstraints.fromJson(
        (json['constraints'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      ),
    );
  }

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'genre': genre,
        'tone': tone,
        'targetWords': targetWords,
        'useExistingSettings': useExistingSettings,
        'protagonistName': protagonistName,
        'randomLevel': randomLevel,
        'continuation': continuation,
        'chapterCount': chapterCount,
        'volumeOutline': volumeOutline,
        'expandOutline': expandOutline,
        'style': style.name,
        'proseStyle': proseStyle.name,
        'constraints': constraints.toJson(),
      };

  /// 不可变更新副本。
  GenerationConfig copyWith({
    String? genre,
    String? tone,
    int? targetWords,
    bool? useExistingSettings,
    String? protagonistName,
    double? randomLevel,
    String? continuation,
    int? chapterCount,
    String? volumeOutline,
    bool? expandOutline,
    WritingStyle? style,
    ProseStyle? proseStyle,
    GenerationConstraints? constraints,
  }) {
    return GenerationConfig(
      genre: genre ?? this.genre,
      tone: tone ?? this.tone,
      targetWords: targetWords ?? this.targetWords,
      useExistingSettings: useExistingSettings ?? this.useExistingSettings,
      protagonistName: protagonistName ?? this.protagonistName,
      randomLevel: randomLevel ?? this.randomLevel,
      continuation: continuation ?? this.continuation,
      chapterCount: chapterCount ?? this.chapterCount,
      volumeOutline: volumeOutline ?? this.volumeOutline,
      expandOutline: expandOutline ?? this.expandOutline,
      style: style ?? this.style,
      proseStyle: proseStyle ?? this.proseStyle,
      constraints: constraints ?? this.constraints,
    );
  }
}

/// 写作风格偏好（控制段落结构 / 节奏 / 对话占比）。
enum WritingStyle {
  /// 标准：均衡的段落长度与描写、对话比例（默认）。
  standard,

  /// 精炼短句：段落短促、节奏快，适合打斗/紧张情节。
  crisp,

  /// 绵长细腻：段落较长、心理与环境描写多，节奏舒缓。
  detailed,

  /// 对话密集：以对话推动剧情，旁白精简。
  dialogue;

  /// 展示用中文名。
  String get label => switch (this) {
        WritingStyle.standard => '标准',
        WritingStyle.crisp => '精炼短句（快节奏）',
        WritingStyle.detailed => '绵长细腻（慢节奏）',
        WritingStyle.dialogue => '对话密集',
      };

  /// 注入 prompt 的写作指令。
  String get instruction => switch (this) {
        WritingStyle.standard =>
            '- 段落长短适中，描写、对话、动作穿插；\n- 每 80~150 字换一段，节奏平稳。',
        WritingStyle.crisp =>
            '- 段落短促有力，每段 30~80 字；\n- 多用短句与动作推进，少大段描写；\n- 对话简练，节奏明快，张力十足。',
        WritingStyle.detailed =>
            '- 段落较长，每段 150~300 字；\n- 注重环境、心理与细节描写，节奏舒缓；\n- 对话从容，留白与回味并重。',
        WritingStyle.dialogue =>
            '- 以对话为主推动剧情，对话占比 60% 以上；\n- 旁白与动作简洁，服务于对话情境；\n- 每段对话独立成段，人物口吻鲜明。',
      };
}

/// 文风（语言质感）偏好。
///
/// 与 [WritingStyle]（段落结构/节奏）正交：文风决定句式与用语风格。
enum ProseStyle {
  /// 现代网文：口语化、爽感强、节奏明快（默认）。
  web,

  /// 古龙简洁：短句、留白、意境，推理与快意恩仇。
  guluo,

  /// 金庸古典：半文半白、典雅、有江湖气。
  jinyong,

  /// 日轻细腻：心理描写多、语气柔和、带吐槽与反差萌。
  lightNovel;

  /// 展示用中文名。
  String get label => switch (this) {
        ProseStyle.web => '现代网文（爽感）',
        ProseStyle.guluo => '古龙简洁（短句留白）',
        ProseStyle.jinyong => '金庸古典（半文半白）',
        ProseStyle.lightNovel => '日轻细腻（心理吐槽）',
      };

  /// 注入 prompt 的文风指令。
  String get instruction => switch (this) {
        ProseStyle.web =>
            '- 语言口语化、现代感强，节奏明快，爽点密集；\n- 避免过度文绉绉，符合当下网文阅读习惯。',
        ProseStyle.guluo =>
            '- 多用短句与名词断句，字少意丰，留白多；\n- 写动作与环境多用白描，不用华丽辞藻；\n- 对话简洁锋利，常有出人意料的转折。',
        ProseStyle.jinyong =>
            '- 半文半白，典雅大气，有古典武侠韵味；\n- 适当使用成语、对仗与古雅词汇；\n- 景物与人物描写讲究意境，点到即止。',
        ProseStyle.lightNovel =>
            '- 心理描写细腻，语气柔和生动；\n- 常有人物内心吐槽、反差萌与轻松氛围；\n- 对话口语化、带角色口癖，节奏轻快。',
      };
}
