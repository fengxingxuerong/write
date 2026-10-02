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

  /// 关卡5 编造核查（对照已确立事实独立核查本章正文，命中即定点修 + 复检）。
  ///
  /// **默认开启**：这是 Python 端冒烟门禁第 16 项的对应能力，Dart 生成路径此前
  /// 完全缺失——写手凭空补的细节会原样留在成书里，作者在 GUI 上还看不到提示。
  /// 每次核查多一次 LLM 调用（命中时再加修复 + 复检两次），配额紧张可关。
  final bool useFactCheck;

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
    this.useFactCheck = true,
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
        'useFactCheck': useFactCheck,
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
      // 旧任务文件无此键 → 默认开启（能力补齐方向），不是默认关闭。
      useFactCheck: json['useFactCheck'] as bool? ?? true,
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

/// 单章语义级质量评分（审校官五维打分，结构化）。
///
/// **为什么必须结构化落库**：审校官的五维分原本只拼进 `task.addLog` 的日志文本
/// （「[评分] 第 3 章 综合 78 分（开篇85/爽点60/钩子90…）」），日志一滚动到
/// 400 条之外就被裁掉，且 UI 无法按维度渲染——等于评分**只存在于运行当时的
/// 屏幕上**。Python 端把同一份数据落在 jsonl `type=review`，作者随时能回看
/// 「第 7 章当年被判多少分、卡在哪一维」，这是打回权的数据基础。
///
/// 缺字段一律按「未评分」处理（[scored] 为 false），绝不用 0 冒充真实低分：
/// 0 分是「评了但很差」，null 是「压根没评」，两者在 UI 上必须区分。
class ChapterQualityReview {
  /// 章序。
  final int idx;

  /// 综合分（0~100）；未评分为 -1。
  final int overall;

  /// 五维分（开篇/爽点/钩子/动机/节奏）；未拿到该维度的键会被略过。
  final Map<String, int> dims;

  /// 一句话点评。
  final String comment;

  /// 本地质检证据串（与打分同批注入，供人工复核「机器判的」与「模型评的」是否一致）。
  final String evidence;

  /// 是否真的评出了分（区分「未评分」与「评了 0 分」）。
  bool get scored => overall >= 0;

  /// 构造评分记录。
  const ChapterQualityReview({
    required this.idx,
    this.overall = -1,
    this.dims = const <String, int>{},
    this.comment = '',
    this.evidence = '',
  });

  /// 达线（对齐 Python `--review-pass 78` 与 [BookQaService.passThreshold]）。
  bool get pass => overall >= 78;

  /// 分数最薄弱的维度名（用于 UI 一句话点出短板）；无有效维度返回空串。
  String get weakestDim {
    if (dims.isEmpty) return '';
    String worst = '';
    int worstVal = 101;
    dims.forEach((String k, int v) {
      if (v < worstVal) {
        worstVal = v;
        worst = k;
      }
    });
    return worst;
  }

  /// 五维中文名（未知键原样返回，避免新增维度时静默显示英文）。
  static String dimLabel(String key) => switch (key) {
        'opening' => '开篇',
        'thrill' => '爽点',
        'hook' => '钩子',
        'motivation' => '动机',
        'rhythm' => '节奏',
        _ => key,
      };

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'idx': idx,
        'overall': overall,
        'dims': dims,
        'comment': comment,
        'evidence': evidence,
      };

  /// 反序列化；`overall` 缺失或非数值按未评分处理。
  factory ChapterQualityReview.fromJson(Map<String, dynamic> json) {
    final Map<String, int> d = <String, int>{};
    final Map<String, dynamic>? raw = json['dims'] as Map<String, dynamic>?;
    raw?.forEach((String k, dynamic v) {
      if (v is num) d[k] = v.toInt();
    });
    return ChapterQualityReview(
      idx: json['idx'] as int? ?? 0,
      overall: (json['overall'] as num?)?.toInt() ?? -1,
      dims: d,
      comment: json['comment'] as String? ?? '',
      evidence: json['evidence'] as String? ?? '',
    );
  }
}

/// 一处编造核查命中（关卡5）。
///
/// 与 Python `fabrication_check_prompt` 的返回结构逐字对齐
/// （`claim` / `evidence` / `type`），双端同一本书扫出来的命中才能横向比较。
class Fabrication {
  /// 问题断言原句节选。
  final String claim;

  /// 对照依据（来自户籍表/数字台账/跨章状态）。
  final String evidence;

  /// 类型：`identity` 身份矛盾 / `number` 数字漂移 / `state` 状态矛盾 /
  /// `fabricated` 无中生有。
  final String type;

  /// 构造命中记录。
  const Fabrication({
    required this.claim,
    required this.evidence,
    required this.type,
  });

  /// 类型中文名（未知类型原样返回，不吞掉信息）。
  String get typeLabel => switch (type) {
        'identity' => '身份矛盾',
        'number' => '数字漂移',
        'state' => '状态矛盾',
        'fabricated' => '无中生有',
        _ => type,
      };

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'claim': claim,
        'evidence': evidence,
        'type': type,
      };

  /// 反序列化；缺字段按空串处理，坏数据不得让整章记录崩掉。
  factory Fabrication.fromJson(Map<String, dynamic> json) => Fabrication(
        claim: json['claim'] as String? ?? '',
        evidence: json['evidence'] as String? ?? '',
        type: json['type'] as String? ?? 'fabricated',
      );
}

/// 单章编造核查结果（关卡5，核查 → 修 → 复检的完整轨迹）。
///
/// **error 与「0 命中」必须区分**：核查没跑成（端点全失败/解析失败）与「跑成了
/// 但一处编造都没有」在门禁里是相反的结论——前者判 FAIL，后者判 PASS。
/// Python 端 `fact_check_stage` 返回 `error=True` 让门禁第 16 项拦截，
/// Dart 端此前**完全没有关卡5**，此处把该语义补齐，不让 UI 把「没跑」显示成「干净」。
class ChapterFactCheck {
  /// 章序。
  final int idx;

  /// 命中明细（复检采纳后的最终状态）。
  final List<Fabrication> fabrications;

  /// 核查是否**跑成了**（false = 没跑成，不得当作通过凭据）。
  final bool ok;

  /// 定点修是否被采纳（命中后修过且复检确实变好）。
  final bool repaired;

  /// 首轮命中数（修复前后对比用；未修时等于 [fabrications] 长度）。
  final int firstRoundCount;

  /// 构造核查记录。
  const ChapterFactCheck({
    required this.idx,
    this.fabrications = const <Fabrication>[],
    this.ok = true,
    this.repaired = false,
    this.firstRoundCount = 0,
  });

  /// 最终命中数。
  int get count => fabrications.length;

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'idx': idx,
        'fabrications': fabrications.map((Fabrication e) => e.toJson()).toList(),
        'ok': ok,
        'repaired': repaired,
        'firstRoundCount': firstRoundCount,
      };

  /// 反序列化：缺 `ok` 视为**未跑成**（宁可显示「未核查」也不谎称「已核查通过」）。
  factory ChapterFactCheck.fromJson(Map<String, dynamic> json) =>
      ChapterFactCheck(
        idx: json['idx'] as int? ?? 0,
        fabrications: (json['fabrications'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Fabrication.fromJson)
            .toList(),
        ok: json['ok'] as bool? ?? false,
        repaired: json['repaired'] as bool? ?? false,
        firstRoundCount: (json['firstRoundCount'] as num?)?.toInt() ?? 0,
      );
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

  /// 规划出的场景总数（2026-09-30 新增，可观测性）。
  ///
  /// 【实测事故】真机第 4 章：4 个场景里 2 个因端点失效返回空（`-> 1 字`），
  /// 被**静默丢弃**——最终成书只有 1.5 个场景的内容，标题与章纲完全对不上
  /// （章纲「禁地借刀」/ 成文「暗巷杀机」），且整章伪装成正常章节落库。
  /// 排查只能靠翻运行日志，作者与用户都无从察觉。
  final int scenesPlanned;

  /// 成功写出正文的场景数（2026-09-30 新增）。
  ///
  /// `scenesWritten < scenesPlanned` 即表示有场景丢失，成书是**残缺的**。
  final int scenesWritten;

  /// 是否有场景因端点失效而丢失（成书残缺）。
  bool get hasLostScenes => scenesWritten < scenesPlanned;

  /// 残缺场景数。
  int get lostScenes => (scenesPlanned - scenesWritten).clamp(0, scenesPlanned);

  /// 本章主角出场次数（-1 = 未记账，即未配置主角名）。
  ///
  /// 【实测事故 2026-09-30】真机 33 章长篇里主角「陆沉」自第 30 章起连续 4 章
  /// 0 次出场，POV 被换成他人。提示词里早有「本章主角：X，只用这个名字」的硬
  /// 约束（pipeline_prompts.dart），但提示词不构成保证——端点偶发抽风就绕过去了。
  ///
  /// 落进章节记录，是让「主角有没有出场」成为可核对的事实。单章 0 次可能是合法
  /// 的他人视角章（多线叙事常写），真正的事故由书级
  /// [NovelConsistencyChecker.protagonistContinuity] 判「连续多章消失」。
  final int protagonistMentions;

  /// 本章语义级质量评分（未评分为 null；见 [ChapterQualityReview.scored]）。
  final ChapterQualityReview? review;

  /// 本章编造核查结果（未核查为 null，与「核查通过 0 命中」严格区分）。
  final ChapterFactCheck? factCheck;

  /// 构造记录。
  const PipelineChapter({
    required this.idx,
    required this.title,
    required this.content,
    required this.rawWords,
    required this.words,
    this.issues = const <String>[],
    this.scenesPlanned = 0,
    this.scenesWritten = 0,
    this.protagonistMentions = -1,
    this.review,
    this.factCheck,
  });

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'idx': idx,
        'title': title,
        'content': content,
        'rawWords': rawWords,
        'words': words,
        'issues': issues,
        'scenesPlanned': scenesPlanned,
        'scenesWritten': scenesWritten,
        'protagonistMentions': protagonistMentions,
        'review': review?.toJson(),
        'factCheck': factCheck?.toJson(),
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
      scenesPlanned: json['scenesPlanned'] as int? ?? 0,
      scenesWritten: json['scenesWritten'] as int? ?? 0,
      protagonistMentions: json['protagonistMentions'] as int? ?? -1,
      // 旧任务文件没有这两个键 → null（未评分/未核查），不是「评了 0 分」。
      review: json['review'] == null
          ? null
          : ChapterQualityReview.fromJson(
              Map<String, dynamic>.from(json['review'] as Map),
            ),
      factCheck: json['factCheck'] == null
          ? null
          : ChapterFactCheck.fromJson(
              Map<String, dynamic>.from(json['factCheck'] as Map),
            ),
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

  /// 供关卡5 编造核查使用的「已确立事实」摘要（世界观设定 + 主角档案）。
  ///
  /// Python 端有独立的配角户籍表（`registry`）与数字台账（`facts`）两份结构化
  /// 账本；Dart 侧只有 `stateTrack` 一份，故此处把大纲里的世界观与主角档案
  /// 拍平成文本一并喂进去。**覆盖面窄于 Python 端是已知差距**：台账越薄，
  /// 「数字漂移」「状态矛盾」两类命中就越查不出来——但「身份矛盾」「无中生有」
  /// （对照世界观硬设定与主角身份）仍能拦住，本关卡仍有实打实的价值。
  String get worldTermsForCheck {
    final StringBuffer b = StringBuffer();
    final dynamic world = outline['world'];
    if (world is Map) {
      world.forEach((dynamic k, dynamic v) {
        final String s = v.toString().trim();
        // 分隔符切分：faction 常写成「青冥宗／玄水宗／烬火阁」，整体塞进去
        // 等于让核查员对着一个不存在的专名做判断（Python 端同名缺陷已修）。
        if (s.isEmpty) return;
        for (final String part in s.split(RegExp(r'[／/|、,，]'))) {
          final String p = part.trim();
          if (p.length >= 2) b.writeln('- $k：$p');
        }
      });
    }
    final dynamic pro = outline['protagonist'];
    if (pro is Map) {
      final String name = (pro['name'] ?? '').toString().trim();
      final String trait = (pro['trait'] ?? '').toString().trim();
      final String origin = (pro['origin'] ?? '').toString().trim();
      if (name.isNotEmpty) {
        b.writeln('- 主角：$name${trait.isEmpty ? '' : '（$trait）'}'
            '${origin.isEmpty ? '' : '；出身：$origin'}');
      }
    }
    return b.toString().trim();
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
