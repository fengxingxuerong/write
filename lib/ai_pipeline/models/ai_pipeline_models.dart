import 'dart:convert';

import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/models/llm_usage.dart';

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

  /// 回收清单打勾（必兑现清单逐条验收，未兑现定向补写，✅ 联动台账 closed）。
  ///
  /// **默认开启**：这是「伏笔台账闭环」的最后一环。此前 Dart 端只有「台账注入
  /// 写手」，没有验收——写手是否真的兑现了伏笔无人核对，台账 closed 完全依赖
  /// 伏笔官二次提取，限流下易失败，于是正文明明回收了伏笔、台账却仍 open，
  /// 终审官会误判「伏笔悬空」。
  ///
  /// 仅在有「埋设超时未收」的伏笔时才产生调用（`promiseBlock` 为空则完全跳过），
  /// 所以正常推进的书几乎不额外花钱——配额紧张也可关。
  final bool usePromiseCheck;

  /// 终审官通读级总评（全书六维 + 签约建议 + 打回重写权）。
  ///
  /// **默认开启**：这是唯一能判断「节奏曲线有无中期塌陷 / 人物弧光是否闭合 /
  /// 结局有没有给读者交代」的环节——这些维度单看任何一章都判断不了，逐章五维
  /// 里也没有它们。此前 Dart 端只有本地规则分，通读级总评长期无人把守。
  ///
  /// 成本较高：默认 [chiefSamples]=3 次采样 × 1~2 轮（打回后有二审），
  /// 每次都要塞进全书摘要 + 三段样本正文。配额紧张可关。
  final bool useChiefReview;

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
    this.usePromiseCheck = true,
    this.useChiefReview = true,
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
        'usePromiseCheck': usePromiseCheck,
        'useChiefReview': useChiefReview,
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
      // 同上：旧任务文件无此键 → 默认开启（能力补齐方向）。
      usePromiseCheck: json['usePromiseCheck'] as bool? ?? true,
      useChiefReview: json['useChiefReview'] as bool? ?? true,
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

/// 一条伏笔台账条目。
///
/// 字段与 Python 端 `foreshadow_extract` / `apply_promise_closures` 逐字对齐
/// （`desc` / `planted` / `recovered` / `status`），双端同一本书的台账才能
/// 横向比较。`evidence` 是 Dart 侧新增：打勾通过时的正文证据句作**回收凭证**
/// ——没有凭证的 closed 只是一句断言，作者无法复核。
///
/// **超时不收**（[isStale]）是本模型最重要的一条派生属性：终审官会把
/// 「悬空伏笔」判为硬伤，但它单看台账发现不了——需要拿当前章号与埋设章号
/// 一减才知道。做成模型属性而非 UI 临时算，是为了让告警在任何展示入口一致。
class ForeshadowEntry {
  /// 伏笔描述（一句话）。
  final String desc;

  /// 埋设章号。
  final int planted;

  /// 回收章号；未回收为 null。
  final int? recovered;

  /// 状态：`open` 未回收 / `closed` 已回收。
  final String status;

  /// 回收证据句（打勾通过时由验收官给出；无则为空）。
  final String evidence;

  /// 构造条目。
  const ForeshadowEntry({
    required this.desc,
    required this.planted,
    this.recovered,
    this.status = 'open',
    this.evidence = '',
  });

  /// 是否已回收。
  ///
  /// 只看 `status`、不看 `recovered`：两者可能不同步（模型只更新了章号
  /// 没改状态），以 status 为唯一事实源，避免出现「显示 closed 却查不到
  /// 回收章号」的自相矛盾。
  bool get closed => status == 'closed';

  /// 截至 [currentIdx] 仍未回收，且已埋设 [staleAfter] 章以上（超时不收）。
  ///
  /// [staleAfter] <= 0 时关闭判定（收尾章模式不按超时筛）；埋设章号缺省
  /// 或大于当前章号（脏台账）一律不告警——宁可漏报也不误伤。
  bool isStale(int currentIdx, {int staleAfter = 5}) {
    if (closed || staleAfter <= 0) return false;
    if (planted <= 0 || currentIdx - planted < staleAfter) return false;
    return true;
  }

  /// 截至 [currentIdx] 的存续章数（已回收返回 0）。
  int age(int currentIdx) => closed ? 0 : (currentIdx - planted).clamp(0, 1 << 30);

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'desc': desc,
        'planted': planted,
        'recovered': recovered,
        'status': status,
        'evidence': evidence,
      };

  /// 反序列化。
  ///
  /// `status` 非法值按 open 处理——fail-open 优于把脏数据当已回收
  /// （虚报「已回收」会让终审漏掉真正的悬空伏笔）。
  factory ForeshadowEntry.fromJson(Map<String, dynamic> json) {
    return ForeshadowEntry(
      desc: (json['desc'] ?? '').toString().trim(),
      planted: (json['planted'] as num?)?.toInt() ?? 0,
      recovered: (json['recovered'] as num?)?.toInt(),
      status: json['status'] == 'closed' ? 'closed' : 'open',
      evidence: (json['evidence'] ?? '').toString(),
    );
  }

  /// 打勾通过后的新条目（标记 closed + 记回收章号与证据句）。
  ForeshadowEntry markClosed(int chapterIdx, String ev) => ForeshadowEntry(
        desc: desc,
        planted: planted,
        recovered: chapterIdx,
        status: 'closed',
        evidence: ev.length > 80 ? ev.substring(0, 80) : ev,
      );
}

/// 终审官（六维通读级总评）的一轮结果。
///
/// **与逐章评分是两回事**：逐章评分看的是单章五维，终审看的是**全书通读**
/// 才能判断的维度——节奏曲线（是否有中期塌陷）、人物弧光、伏笔回收的悬空风险、
/// 结局力度。这些维度单看任何一章都无从判断，此前 Dart 端只有 CLI 有。
///
/// [_round] 记录这是第几轮：终审带打回权，会「终审 → 打回重写 → 二审」，
/// **以二审为准**（重写后模型仍会如实给低分，不放水），故轮次必须可追溯——
/// 只留最后一轮就看不出「这本书被打回过一次」。
class ChiefReview {
  /// 轮次（1 = 初审，2 = 二审…）。
  final int round;

  /// 综合总分（0~100）；-1 = 本轮没跑成。
  final int overall;

  /// 六维分（开篇钩子/节奏曲线/人物弧光/爽点与期待感/伏笔回收/结局力度）。
  final Map<String, int> dimensions;

  /// 签约判档（高潜可投/可投/需打磨/不建议）。
  final String verdict;

  /// 问题清单（具体到章 + 指标证据）。
  final List<ChiefIssue> topIssues;

  /// 修改优先级建议（可执行）。
  final List<String> fixPriority;

  /// 本轮有效采样次数（多采样取中位数时用）。
  final int samples;

  /// 本轮是否真的跑出结论。
  bool get ok => overall >= 0;

  /// 硬伤维度（任一维 ≤40）。**这是防漏报的关键**：「总分 83 但伏笔回收 30」
  /// 这种稿子会被总分掩盖，必须单独拎出来强制人工复核。
  Map<String, int> get hardDimensions {
    final Map<String, int> out = <String, int>{};
    dimensions.forEach((String k, int v) {
      if (v <= 40) out[k] = v;
    });
    return out;
  }

  /// 构造一轮终审结果。
  const ChiefReview({
    required this.round,
    this.overall = -1,
    this.dimensions = const <String, int>{},
    this.verdict = '',
    this.topIssues = const <ChiefIssue>[],
    this.fixPriority = const <String>[],
    this.samples = 1,
  });

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'round': round,
        'overall': overall,
        'dimensions': dimensions,
        'verdict': verdict,
        'topIssues': topIssues.map((ChiefIssue e) => e.toJson()).toList(),
        'fixPriority': fixPriority,
        'samples': samples,
      };

  /// 反序列化。
  factory ChiefReview.fromJson(Map<String, dynamic> json) {
    final Map<String, int> d = <String, int>{};
    final Map<String, dynamic>? raw =
        json['dimensions'] as Map<String, dynamic>?;
    raw?.forEach((String k, dynamic v) {
      if (v is num) d[k] = v.toInt();
    });
    return ChiefReview(
      round: (json['round'] as num?)?.toInt() ?? 1,
      overall: (json['overall'] as num?)?.toInt() ?? -1,
      dimensions: d,
      verdict: json['verdict'] as String? ?? '',
      topIssues: (json['topIssues'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ChiefIssue.fromJson)
          .toList(),
      fixPriority: (json['fixPriority'] as List<dynamic>? ?? const [])
          .map((dynamic e) => e.toString())
          .toList(),
      samples: (json['samples'] as num?)?.toInt() ?? 1,
    );
  }
}

/// 终审问题清单里的一条（具体到章 + 指标证据）。
class ChiefIssue {
  /// 章号（0 = 未指明具体章）。
  final int chapter;

  /// 问题描述。
  final String issue;

  /// 引用的指标证据。
  final String evidence;

  /// 构造一条问题。
  const ChiefIssue({
    required this.chapter,
    required this.issue,
    required this.evidence,
  });

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'chapter': chapter,
        'issue': issue,
        'evidence': evidence,
      };

  /// 反序列化。
  factory ChiefIssue.fromJson(Map<String, dynamic> json) => ChiefIssue(
        chapter: (json['chapter'] as num?)?.toInt() ?? 0,
        issue: (json['issue'] ?? '').toString(),
        evidence: (json['evidence'] ?? '').toString(),
      );
}

/// 打回重写的一轮记录（终审 → 打回 → 重写 → 二审的轨迹）。
///
/// **轨迹本身就是交付物**：作者需要看到「这本书被判回过一次、因为什么、
/// 改完变成什么样」，而不只是最终分数。没有轨迹，打回权就等于不存在——
/// 它看起来像一次没发生过的事。
class ChiefRewriteRecord {
  /// 章号。
  final int chapterIdx;

  /// 触发打回的问题描述。
  final String reason;

  /// 重写前字数。
  final int oldWords;

  /// 重写后字数。
  final int newWords;

  /// 重写后复审分（-1 = 未复审）。
  final int rescore;

  /// 是否真的重写了（false = 重写产出未过采纳闸，保留原文）。
  final bool applied;

  /// 构造记录。
  const ChiefRewriteRecord({
    required this.chapterIdx,
    required this.reason,
    required this.oldWords,
    required this.newWords,
    this.rescore = -1,
    this.applied = true,
  });

  /// 字数变化（负数说明变短了——通常是异常信号）。
  int get delta => newWords - oldWords;

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'chapterIdx': chapterIdx,
        'reason': reason,
        'oldWords': oldWords,
        'newWords': newWords,
        'rescore': rescore,
        'applied': applied,
      };

  /// 反序列化。
  factory ChiefRewriteRecord.fromJson(Map<String, dynamic> json) =>
      ChiefRewriteRecord(
        chapterIdx: (json['chapterIdx'] as num?)?.toInt() ?? 0,
        reason: (json['reason'] ?? '').toString(),
        oldWords: (json['oldWords'] as num?)?.toInt() ?? 0,
        newWords: (json['newWords'] as num?)?.toInt() ?? 0,
        rescore: (json['rescore'] as num?)?.toInt() ?? -1,
        applied: json['applied'] as bool? ?? false,
      );
}

/// 一条回收清单的验收结果（打勾 ✅/❌）。
///
/// [failed] 表示**验收环节本身没跑成**（端点全失败 / 两次解析失败），与
/// 「验收了但没兑现」（[fulfilled]=false）是相反的结论：前者不该触发补写
/// （正文没问题，是验收坏了），更不该联动台账（否则一次静默失效会被记成
/// N 条伏笔已回收）。
class PromiseCheck {
  /// 清单序号（从 1 开始）。
  final int id;

  /// 是否兑现（答案落到纸面；只暗示 / 留白 / 远景铺陈不算）。
  final bool fulfilled;

  /// 正文证据句（未兑现则填缺失原因）。
  final String evidence;

  /// 验收环节是否失败（true 时本条无实质结论）。
  final bool failed;

  /// 构造验收结果。
  const PromiseCheck({
    required this.id,
    required this.fulfilled,
    required this.evidence,
    this.failed = false,
  });

  /// 验收环节失败时的占位结果（`id` 用 -1，与真实序号区分）。
  static const PromiseCheck failure = PromiseCheck(
    id: -1,
    fulfilled: false,
    evidence: '校验调用失败，打勾未执行（非正文问题，是验收环节失败）',
    failed: true,
  );

  /// 打勾标记（✅ / ❌ / ☠）。
  String get mark => failed ? '☠' : (fulfilled ? '✅' : '❌');

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'fulfilled': fulfilled,
        'evidence': evidence,
        'failed': failed,
      };

  /// 反序列化。
  factory PromiseCheck.fromJson(Map<String, dynamic> json) => PromiseCheck(
        id: (json['id'] as num?)?.toInt() ?? -1,
        fulfilled: json['fulfilled'] == true,
        evidence: (json['evidence'] ?? '').toString(),
        failed: json['failed'] == true,
      );
}

/// 伏笔台账（有序列表，保持埋设顺序）。
class ForeshadowLedger {
  /// 构造台账。
  const ForeshadowLedger(this.items);

  /// 全部条目（按埋设顺序）。
  final List<ForeshadowEntry> items;

  /// 空台账。
  static const ForeshadowLedger empty =
      ForeshadowLedger(<ForeshadowEntry>[]);

  /// 未回收条目。
  List<ForeshadowEntry> get open =>
      items.where((ForeshadowEntry e) => !e.closed).toList();

  /// 已回收条目。
  List<ForeshadowEntry> get closed =>
      items.where((ForeshadowEntry e) => e.closed).toList();

  /// 超时不收的条目（截至 [currentIdx]）。
  List<ForeshadowEntry> stale(int currentIdx, {int staleAfter = 5}) =>
      items
          .where((ForeshadowEntry e) =>
              e.isStale(currentIdx, staleAfter: staleAfter))
          .toList();

  /// 反序列化（坏数据一律退化为空台账，绝不让整本任务打不开）。
  factory ForeshadowLedger.parse(String raw) {
    if (raw.trim().isEmpty) return empty;
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) return empty;
      final List<dynamic> list =
          decoded['foreshadows'] as List<dynamic>? ?? const [];
      return ForeshadowLedger(
        list
            .whereType<Map<String, dynamic>>()
            .map(ForeshadowEntry.fromJson)
            // desc 为空的条目无法验收也不可展示，直接丢弃。
            .where((ForeshadowEntry e) => e.desc.isNotEmpty)
            .toList(),
      );
    } catch (_) {
      return empty;
    }
  }

  /// 序列化（供导出与下游复用）。
  String encode() => jsonEncode(<String, dynamic>{
        'foreshadows': items.map((ForeshadowEntry e) => e.toJson()).toList(),
      });

  /// 返回「本章必兑现清单」条目（最多 [maxPromises] 条）。
  ///
  /// 与 Python `build_promise_block` 同口径：`staleAfter > 0` 时只取
  /// 「埋设已超时」的条目——普通章不该背全部回收负担，只在伏笔快烂时上
  /// 硬约束；`staleAfter <= 0`（收尾章）取全部 open 前 N 条。
  List<ForeshadowEntry> promiseBlock(
    int currentIdx, {
    int maxPromises = 6,
    int staleAfter = 5,
  }) {
    final List<ForeshadowEntry> pool =
        staleAfter > 0 ? stale(currentIdx, staleAfter: staleAfter) : open;
    return pool.take(maxPromises).toList();
  }

  /// 打勾 ✅ 联动台账：把 [results] 里校验通过的条目标记 closed。
  ///
  /// **映射关系**：清单第 n 条 ↔ [promise] 列表第 n 个（与
  /// `build_promise_block` 同序产出，见 Python `apply_promise_closures`）。
  /// 序号越界、或存在验收环节失败（[PromiseCheck.failed]）的条目一律不联动——
  /// **「验收没跑成」绝不等于「已回收」**。
  ///
  /// 返回打勾后的**新台账**与关闭数量（原台账不可变，便于失败回滚）。
  (ForeshadowLedger, int) applyClosures(
    List<ForeshadowEntry> promise,
    List<PromiseCheck> results,
    int chapterIdx,
  ) {
    if (promise.isEmpty || results.isEmpty) return (this, 0);
    // 验收环节失败时整体不联动：宁可台账停在 open，也不能把一次静默失效
    // 记成 N 条伏笔已回收。
    if (results.any((PromiseCheck r) => r.failed)) return (this, 0);
    final List<ForeshadowEntry> next = List<ForeshadowEntry>.from(items);
    int closed = 0;
    for (final PromiseCheck r in results) {
      if (!r.fulfilled) continue;
      final int n = r.id - 1;
      if (n < 0 || n >= promise.length) continue;
      final ForeshadowEntry target = promise[n];
      final int idx = next.indexWhere(
        (ForeshadowEntry e) =>
            e.desc == target.desc &&
            e.planted == target.planted &&
            !e.closed,
      );
      if (idx < 0) continue;
      next[idx] = next[idx].markClosed(chapterIdx, r.evidence);
      closed++;
    }
    return (ForeshadowLedger(next), closed);
  }
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

  /// 本章回收清单打勾结果（未打勾为 null）。
  ///
  /// 每条含 ✅/❌ 与正文证据句——**证据句是回收凭证**，没有它，
  /// 「已回收」只是一句无法复核的断言（Python 端 `verify_promises_prompt`
  /// 同样强制要求 evidence）。
  final List<PromiseCheck>? promiseChecks;

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
    this.promiseChecks,
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
        'promiseChecks': promiseChecks?.map((PromiseCheck e) => e.toJson()).toList(),
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
      // null = 本章没打勾；空列表 = 打过勾但清单为空（合法，区别于未打勾）。
      promiseChecks: json['promiseChecks'] == null
          ? null
          : (json['promiseChecks'] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map(PromiseCheck.fromJson)
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

  /// LLM 调用用量账本（按角色/按章可聚合；随任务落盘，续跑不丢）。
  ///
  /// **未知不等于免费**：端点不返回 usage 时记空用量，成本显示「未知」，
  /// 绝不按字数估算——那会给作者一份看起来精确的假账。
  final LlmLedger llmLedger;

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
    LlmLedger? llmLedger,
    List<ChiefReview>? chiefReviews,
    List<ChiefRewriteRecord>? chiefRewrites,
    this.chiefSamples = 3,
    this.chiefRewriteThreshold = 70,
    this.chiefRewriteMax = 2,
  })  : chapters = chapters ?? <PipelineChapter>[],
        log = log ?? <String>[],
        llmLedger = llmLedger ?? LlmLedger(),
        chiefReviews = chiefReviews ?? <ChiefReview>[],
        chiefRewrites = chiefRewrites ?? <ChiefRewriteRecord>[];

  /// 最后一轮终审（**以二审为准**）；尚未终审返回 null。
  ChiefReview? get latestChiefReview =>
      chiefReviews.isEmpty ? null : chiefReviews.last;

  /// 终审是否曾打回过（作者据此知道「这本书被判回过一次」）。
  bool get chiefRewrote => chiefRewrites.isNotEmpty;

  /// 综合分本地判档。
  ///
  /// **同分必同档**：模型自己写的判词会漂（「可投」和「需打磨」差几分时说
  /// 一样的话），按分数区间本地判档后判词唯一，模型判词只作参考。
  static String verdictOf(int overall) {
    if (overall >= 80) return '高潜可投';
    if (overall >= 70) return '可投';
    if (overall >= 60) return '需打磨';
    return '不建议';
  }

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

  /// 终审官各轮记录（按轮次升序；空 = 尚未终审）。
  List<ChiefReview> chiefReviews;

  /// 打回重写轨迹（按发生顺序；空 = 未打回过）。
  List<ChiefRewriteRecord> chiefRewrites;

  /// 终审官多采样次数（合并中位数，实测单轮评分方差大：同书 83/68/64/71/64）。
  final int chiefSamples;

  /// 终审打回重写线（低于此分则打回重写问题章）。
  final int chiefRewriteThreshold;

  /// 终审打回时最多重写几章。
  final int chiefRewriteMax;

  /// 伏笔台账（结构化视图）。
  ///
  /// [foreshadowLedger] 是原始 JSON 串（模型每次整份重写），本 getter 负责
  /// 解析成 [ForeshadowLedger]。旧代码在三处各写一遍 `jsonDecode` + 逐字段
  /// 取值，且**各自 try/catch 各自兜底**，一处漏判就会静默返回空清单——
  /// 集中到这里后，「解析失败 = 空台账」只有一个地方决定。
  ForeshadowLedger get ledger => ForeshadowLedger.parse(foreshadowLedger);

  /// 把结构化台账写回原始字段。
  void setLedger(ForeshadowLedger l) => foreshadowLedger = l.encode();

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
        'llmLedger': llmLedger.toJson(),
        'chiefReviews': chiefReviews.map((ChiefReview e) => e.toJson()).toList(),
        'chiefRewrites':
            chiefRewrites.map((ChiefRewriteRecord e) => e.toJson()).toList(),
        'chiefSamples': chiefSamples,
        'chiefRewriteThreshold': chiefRewriteThreshold,
        'chiefRewriteMax': chiefRewriteMax,
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
      // 旧任务文件无此键 → 空账本（= 未记录），不是「0 token」。
      llmLedger: LlmLedger.fromJson(
        (json['llmLedger'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      ),
      // 旧任务文件无这些键 → 空列表（= 尚未终审），不是「终审了 0 分」。
      chiefReviews: (json['chiefReviews'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ChiefReview.fromJson)
          .toList(),
      chiefRewrites: (json['chiefRewrites'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ChiefRewriteRecord.fromJson)
          .toList(),
      chiefSamples: json['chiefSamples'] as int? ?? 3,
      chiefRewriteThreshold: json['chiefRewriteThreshold'] as int? ?? 70,
      chiefRewriteMax: json['chiefRewriteMax'] as int? ?? 2,
    );
  }
}
