import 'package:novel_writer/models/llm_config.dart';

/// 多模型协作流水线 —— 角色枚举。
///
/// 每个角色对应一类生成任务，可配置独立的模型/端点/温度：
/// - [planner]   总规划官：全书大纲 + 章节场景规划（质量优先，量少）
/// - [writer]    正文写手：逐场景正文生成（速度/质量平衡，量大）
/// - [editor]    去AI味编辑：整章润色（清除 AI 高频表达）
/// - [titler]    标题官：章节标题提炼（轻量快速）
/// - [verifier]  一致性审校：每 N 章跨章设定/伏笔校验（只记录不阻塞）
enum AiRole { planner, writer, editor, titler, verifier }

/// 角色中文名。
extension AiRoleLabel on AiRole {
  String get label => switch (this) {
        AiRole.planner => '总规划官',
        AiRole.writer => '正文写手',
        AiRole.editor => '去AI味编辑',
        AiRole.titler => '标题官',
        AiRole.verifier => '一致性审校',
      };

  String get description => switch (this) {
        AiRole.planner => '全书大纲 + 场景规划（glm-5.2 需 temp=1.0 且 maxTokens≥4000，否则输出为空）',
        AiRole.writer => '逐场景正文（建议速度质量均衡的 flash 模型）',
        AiRole.editor => '整章去AI味润色（kimi/glm 需 temp=1.0；配额紧张时建议留本地兜底）',
        AiRole.titler => '章节标题（轻量模型即可）',
        AiRole.verifier => '跨章一致性校验（每 5 章一次，可选）',
      };

  /// 该角色默认温度（glm/kimi 系需 1.0）。
  double get defaultTemperature => switch (this) {
        AiRole.planner => 1.0,
        AiRole.writer => 0.8,
        AiRole.editor => 1.0,
        AiRole.titler => 0.8,
        AiRole.verifier => 1.0,
      };
}

/// 单个角色的模型配置（复用 [LlmConfig]，含 provider/model/key/baseUrl/温度）。
///
/// 支持**有序备用链** [fallbacks]：主 [llm] 失败/空响应/冷却时沿链切换，
/// 对齐 Python `scripts/novel_pipeline.py` 的 `PLANNER_CHAIN` 等 failover 语义。
class AiRoleConfig {
  /// 角色。
  final AiRole role;

  /// 是否启用该角色（停用后由兜底逻辑或本地规则替代）。
  final bool enabled;

  /// 主模型连接配置。
  final LlmConfig llm;

  /// 备用端点（有序）：主模型失败后按序尝试，直到拿到非空正文。
  ///
  /// 空列表 = 只有主模型（与旧版行为一致）。序列化缺省时保持向后兼容。
  final List<LlmConfig> fallbacks;

  /// 构造配置。
  const AiRoleConfig({
    required this.role,
    this.enabled = true,
    this.llm = const LlmConfig(),
    this.fallbacks = const <LlmConfig>[],
  });

  /// 有效调用链：主 + 备（保持主在前）。
  List<LlmConfig> get chain => <LlmConfig>[llm, ...fallbacks];

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'role': role.name,
        'enabled': enabled,
        'llm': llm.toJson(),
        'fallbacks': fallbacks.map((LlmConfig e) => e.toJson()).toList(),
      };

  /// 反序列化。
  factory AiRoleConfig.fromJson(Map<String, dynamic> json) {
    return AiRoleConfig(
      role: AiRole.values.firstWhere(
        (AiRole e) => e.name == json['role'],
        orElse: () => AiRole.writer,
      ),
      enabled: json['enabled'] as bool? ?? true,
      llm: LlmConfig.fromJson(
        (json['llm'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      ),
      fallbacks: (json['fallbacks'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(LlmConfig.fromJson)
          .toList(),
    );
  }
}

/// 流水线全局配置。
class AiPipelineConfig {
  /// 目标总字数。
  final int totalWords;

  /// 最大章节数。
  final int maxChapters;

  /// 题材（映射到写作准则/语料提示）。
  final String genre;

  /// 主角名（可选，空串让规划官起名）。
  final String protagonist;

  /// 是否启用去AI味润色。
  final bool useEditor;

  /// 是否启用一致性审校（每 5 章）。
  final bool useVerifier;

  /// 是否启用语义级质量评分（审校官五维打分，每 [qualityReviewEvery] 章一次，
  /// 只记录不阻塞）。
  final bool useQualityReview;

  /// 质量评分间隔（每几章评一次，默认 3）。
  final int qualityReviewEvery;

  /// 是否自动重写低分章节（评分低于 [rewriteThreshold] 时触发编辑重写）。
  final bool autoRewriteLowScore;

  /// 低分触发重写的阈值（默认 55，低于告警线 60，只重写明显差的章节）。
  final int rewriteThreshold;

  /// 是否启用跨章状态追踪（每章提取状态清单，注入下一章防穿帮）。
  final bool useStateTrack;

  /// 各角色配置（未配置的默认启用，模型需用户在配置页填写）。
  final Map<AiRole, AiRoleConfig> roles;

  /// 构造配置。
  const AiPipelineConfig({
    this.totalWords = 100000,
    this.maxChapters = 40,
    this.genre = '玄幻',
    this.protagonist = '',
    this.useEditor = true,
    this.useVerifier = true,
    this.useQualityReview = true,
    this.qualityReviewEvery = 3,
    this.autoRewriteLowScore = true,
    this.rewriteThreshold = 55,
    this.useStateTrack = true,
    this.roles = const <AiRole, AiRoleConfig>{},
  });

  /// 取某角色配置（缺失时返回默认启用配置）。
  AiRoleConfig roleOf(AiRole role) {
    final AiRoleConfig? c = roles[role];
    if (c != null) return c;
    return AiRoleConfig(
      role: role,
      llm: LlmConfig(temperature: role.defaultTemperature),
    );
  }

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'totalWords': totalWords,
        'maxChapters': maxChapters,
        'genre': genre,
        'protagonist': protagonist,
        'useEditor': useEditor,
        'useVerifier': useVerifier,
        'useQualityReview': useQualityReview,
        'qualityReviewEvery': qualityReviewEvery,
        'autoRewriteLowScore': autoRewriteLowScore,
        'rewriteThreshold': rewriteThreshold,
        'useStateTrack': useStateTrack,
        'roles': roles.values.map((AiRoleConfig e) => e.toJson()).toList(),
      };

  /// 反序列化。
  factory AiPipelineConfig.fromJson(Map<String, dynamic> json) {
    final Map<AiRole, AiRoleConfig> roles = <AiRole, AiRoleConfig>{};
    for (final dynamic e in (json['roles'] as List<dynamic>? ?? const [])) {
      final AiRoleConfig c = AiRoleConfig.fromJson(e as Map<String, dynamic>);
      roles[c.role] = c;
    }
    return AiPipelineConfig(
      totalWords: json['totalWords'] as int? ?? 100000,
      maxChapters: json['maxChapters'] as int? ?? 40,
      genre: json['genre'] as String? ?? '玄幻',
      protagonist: json['protagonist'] as String? ?? '',
      useEditor: json['useEditor'] as bool? ?? true,
      useVerifier: json['useVerifier'] as bool? ?? true,
      useQualityReview: json['useQualityReview'] as bool? ?? true,
      qualityReviewEvery: json['qualityReviewEvery'] as int? ?? 3,
      autoRewriteLowScore: json['autoRewriteLowScore'] as bool? ?? true,
      rewriteThreshold: json['rewriteThreshold'] as int? ?? 55,
      useStateTrack: json['useStateTrack'] as bool? ?? true,
      roles: roles,
    );
  }
}

/// 流水线任务状态。
enum PipelineTaskStatus {
  /// 待运行。
  idle,

  /// 运行中。
  running,

  /// 已完成。
  done,

  /// 失败中止。
  failed,

  /// 用户取消。
  cancelled,
}

/// 单章生成记录。
class PipelineChapter {
  /// 章节序号。
  final int idx;

  /// 章节标题。
  final String title;

  /// 最终正文（润色后；未润色即原文）。
  final String content;

  /// 润色前字数（用于对比 AI 味）。
  final int rawWords;

  /// 润色后字数。
  final int words;

  /// 审校/质检记录的问题（每行一条）。
  final List<String> issues;

  /// 构造记录。
  const PipelineChapter({
    required this.idx,
    required this.title,
    required this.content,
    required this.rawWords,
    required this.words,
    this.issues = const <String>[],
  });

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'idx': idx,
        'title': title,
        'content': content,
        'rawWords': rawWords,
        'words': words,
        'issues': issues,
      };

  /// 反序列化。
  factory PipelineChapter.fromJson(Map<String, dynamic> json) {
    return PipelineChapter(
      idx: json['idx'] as int? ?? 0,
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      rawWords: json['rawWords'] as int? ?? 0,
      words: json['words'] as int? ?? 0,
      issues: (json['issues'] as List<dynamic>? ?? const [])
          .map((dynamic e) => e.toString())
          .toList(),
    );
  }
}

/// 长篇小说生成任务（含断点数据）。
class AiPipelineTask {
  /// 任务 ID。
  final String id;

  /// 当前状态。
  PipelineTaskStatus status;

  /// 流水线配置（含各角色模型）。
  final AiPipelineConfig config;

  /// 全书大纲（规划官产物，Map 结构；未规划时为空 Map）。
  Map<String, dynamic> outline;

  /// 已生成章节（按 idx 排序）。
  final List<PipelineChapter> chapters;

  /// 已累计字数。
  int totalWords;

  /// 最近日志（滚动保留，供 UI 展示）。
  final List<String> log;

  /// 创建时间。
  final DateTime createdAt;

  /// 完成/失败时间。
  DateTime? finishedAt;

  /// 失败原因（status=failed 时）。
  String? error;

  /// 导入书架后的 Novel 项目 id（幂等导入依据）。
  String? importedNovelId;

  /// 跨章状态清单（每章提取的人物伤势/修为/物品/承诺，注入下一章防穿帮）。
  String stateTrack;

  /// 伏笔台账 JSON（每章提取的未收伏笔清单，防长篇丢伏笔/改设定）。
  String foreshadowLedger;

  /// 构造任务。
  AiPipelineTask({
    required this.id,
    required this.config,
    this.status = PipelineTaskStatus.idle,
    this.outline = const <String, dynamic>{},
    List<PipelineChapter>? chapters,
    this.totalWords = 0,
    List<String>? log,
    required this.createdAt,
    this.finishedAt,
    this.error,
    this.importedNovelId,
    this.stateTrack = '',
    this.foreshadowLedger = '[]',
  })  : chapters = chapters ?? <PipelineChapter>[],
        log = log ?? <String>[];

  /// 追加日志（超过 400 条裁剪）。
  void addLog(String line) {
    log.add('${DateTime.now().toIso8601String().substring(11, 19)} $line');
    if (log.length > 400) {
      log.removeRange(0, log.length - 400);
    }
  }

  /// 已生成章节数。
  int get chapterCount => chapters.length;

  /// 书名（大纲产出后可用）。非字符串类型的 title 不抛错，回退为「未命名」。
  String get title {
    final dynamic v = outline['title'];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return '未命名';
  }

  /// 是否可续跑（有进度且未完成）。
  bool get resumable =>
      status == PipelineTaskStatus.idle ||
      status == PipelineTaskStatus.failed;

  /// 序列化（断点存储）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'status': status.name,
        'config': config.toJson(),
        'outline': outline,
        'chapters': chapters.map((PipelineChapter e) => e.toJson()).toList(),
        'totalWords': totalWords,
        'log': log,
        'createdAt': createdAt.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
        'error': error,
        'importedNovelId': importedNovelId,
        'stateTrack': stateTrack,
        'foreshadowLedger': foreshadowLedger,
      };

  /// 反序列化。
  factory AiPipelineTask.fromJson(Map<String, dynamic> json) {
    return AiPipelineTask(
      id: json['id'] as String? ?? '',
      config: AiPipelineConfig.fromJson(
        (json['config'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      ),
      status: PipelineTaskStatus.values.firstWhere(
        (PipelineTaskStatus e) => e.name == json['status'],
        orElse: () => PipelineTaskStatus.idle,
      ),
      outline: (json['outline'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      chapters: (json['chapters'] as List<dynamic>? ?? const [])
          .map((dynamic e) => PipelineChapter.fromJson(e as Map<String, dynamic>))
          .toList(),
      totalWords: json['totalWords'] as int? ?? 0,
      log: (json['log'] as List<dynamic>? ?? const [])
          .map((dynamic e) => e.toString())
          .toList(),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
              DateTime.now(),
      finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? ''),
      error: json['error'] as String?,
      importedNovelId: json['importedNovelId'] as String?,
      stateTrack: json['stateTrack'] as String? ?? '',
      foreshadowLedger: json['foreshadowLedger'] as String? ?? '[]',
    );
  }
}
