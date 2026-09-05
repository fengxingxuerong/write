/// 一个「场景」是章内的一次 LLM 生成单元。
///
/// 章拆成 scene 的核心原因：单 pass 生成长文本时 LLM 容易在
/// 后半段出现套路化、重复用词、节奏塌陷；把章拆成 3~5 个
/// 「各有结构目标的」短 pass，每段 400~800 字，模型能维持
/// 高文学质量不崩坏。
///
/// [stage] 取值对应「起承转合」：
/// - 起：锚定时间地点人物，建立基调
/// - 承：推进冲突，释放信息
/// - 转：危机/反转/情感升级
/// - 合：收束本段，留出钩子引向下一场景
class ScenePlan {
  /// 构造场景。
  const ScenePlan({
    required this.index,
    required this.stage,
    required this.goal,
    required this.beats,
    this.targetWords = 600,
  });

  /// 场景在章内的序号（从 0 开始）。
  final int index;

  /// 结构位置：「起」「承」「转」「合」。
  final String stage;

  /// 本场景要完成的核心任务（一两句话）。
  final String goal;

  /// 必须在此场景中完成的情节节拍（顺序敏感）。
  final List<String> beats;

  /// 本场景目标字数（400~800 为宜）。
  final int targetWords;

  /// 是否为本章的最后一个场景。
  bool get isEnding => stage == '合';

  /// 从 JSON 反序列化（LLM 输出）。
  factory ScenePlan.fromJson(Map<String, dynamic> json) {
    return ScenePlan(
      index: (json['index'] as num?)?.toInt() ?? 0,
      stage: json['stage'] as String? ?? '承',
      goal: json['goal'] as String? ?? '',
      beats: (json['beats'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[],
      targetWords: (json['targetWords'] as num?)?.toInt() ?? 600,
    );
  }

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'index': index,
        'stage': stage,
        'goal': goal,
        'beats': beats,
        'targetWords': targetWords,
      };
}

/// 一章的场景序列。
class ChapterScenes {
  /// 构造。
  const ChapterScenes({
    required this.chapterOutline,
    required this.scenes,
  });

  /// 原始章纲。
  final String chapterOutline;

  /// 场景列表（有序）。
  final List<ScenePlan> scenes;

  /// 整章目标字数（各场景之和）。
  int get totalTargetWords =>
      scenes.fold<int>(0, (int sum, ScenePlan s) => sum + s.targetWords);

  /// 从 JSON 反序列化。
  factory ChapterScenes.fromJson(Map<String, dynamic> json) {
    return ChapterScenes(
      chapterOutline: json['chapterOutline'] as String? ?? '',
      scenes: (json['scenes'] as List<dynamic>?)
              ?.map((e) => ScenePlan.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <ScenePlan>[],
    );
  }
}
