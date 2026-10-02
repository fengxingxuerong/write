import 'dart:async';
import 'dart:convert';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/prompts/pipeline_prompts.dart';
import 'package:novel_writer/ai_pipeline/services/llm_router.dart';
import 'package:novel_writer/ai_pipeline/services/outline_text.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/quality/fanqie_gate_checker.dart';
import 'package:novel_writer/engine/quality/quality_rules.g.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 关卡5 定点修的字数下限比例。
///
/// 值取自单一数据源 `QualityRules.fixMinRatio`（rules/quality_rules.json），
/// 与 Python `FIX_MIN_RATIO` 同值同源——2026-10-03 此前这里是独立硬编码 0.92，
/// 与生成常量构成又一处「需要手工同步的第二份」。
///
/// 提示词下限必须**严于**代码采纳守卫（editorMinRatio=0.85）：模型是照着数字办事的，
/// 若提示词说「压缩到 85%」而守卫也只要 85%，两者卡在同一根线上毫无余量；
/// 提示词给 0.92 留出的空间让模型先自查，守卫只兜「模型完全不听指令」的情况。
const double factFixMinRatio = QualityRules.fixMinRatio;

/// 多模型协作长篇小说流水线（Dart 原生编排）。
///
/// 流程：
/// 1. 总规划官规划全书大纲（JSON）；
/// 2. 逐章：规划官拆场景 → 写手逐场景生成 → 编辑去AI味润色 →
///    标题官提炼章名 → 每 5 章审校官一致性校验 → 本地质检 →
///    **关卡5 编造核查（对照已确立事实独立核查，命中即修 + 复检）**；
/// 3. 断点续传：每章完成后原子落盘，中断后可从下一章继续。
///
/// 网络层复用 [LlmChatClient]（OpenAI 兼容非流式，支持 enable_thinking），
/// 多端点 failover 由 [LlmRouter]（配额感知链式路由）承载：
/// 每个角色可配置主 + 备用链，主失败/空响应/限流自动切下一个。
class AiPipelineService {
  /// 构造服务；[router] 可注入测试替身，缺省用 [ChainLlmRouter]。
  AiPipelineService(this._storage, {LlmRouter? router})
      : _router = router ?? ChainLlmRouter();

  final PipelineStorage _storage;

  /// 角色 → 模型的路由器（链式 failover + 健康池冷却）。
  final LlmRouter _router;

  /// 链上是否至少一个端点已配置（主或任一备用）。
  static bool _chainConfigured(AiRoleConfig cfg) =>
      cfg.chain.any((LlmConfig c) => c.isConfigured);

  /// 调用某角色模型（链式 failover：冷却跳过/失败/空响应自动切下一个可用端点）。
  /// 链上全部失败返回空串。统一在任务日志里记录 `[角色]` 前缀的路由过程。
  Future<String> _call(
    AiPipelineTask task,
    AiRole role,
    String system,
    String user, {
    double? temperature,
    bool Function()? isCancelled,
  }) async {
    final AiRoleConfig cfg = task.config.roleOf(role);
    if (!cfg.enabled) return '';
    if (!_chainConfigured(cfg)) {
      task.addLog('  [配置] ${role.label} 未配置模型，跳过');
      return '';
    }
    final LlmRouteResult result = await _router.call(
      cfg.chain,
      system: system,
      user: user,
      temperature: temperature,
      onLog: (String line) => task.addLog('  [${role.label}] $line'),
      isCancelled: isCancelled,
    );
    final String content = result.content.trim();
    if (content.isEmpty) {
      task.addLog('  [空响应] ${role.label}（${cfg.llm.model}）');
    }
    return content;
  }

  /// 拼逐章指标行（终审 prompt 的摘要输入）。
  ///
  /// 口径与 Python `chief_editor_prompt` 逐字一致：章号/标题/字数/评审分/
  /// 钩子有无/AI 味%/问题数。**只拼指标不拼正文**——终审的上下文预算要留给
  /// 三段样本正文。
  static String _chiefChapterRows(AiPipelineTask task) {
    final List<PipelineChapter> chapters = List<PipelineChapter>.from(
      task.chapters,
    )..sort((PipelineChapter a, PipelineChapter b) => a.idx.compareTo(b.idx));
    final StringBuffer b = StringBuffer();
    for (final PipelineChapter c in chapters) {
      final ChapterQualityReview? r = c.review;
      final double echo = PipelineQa.aiEchoPct(c.content);
      b.writeln('第${c.idx}章《${c.title}》${c.words}字｜'
          '评审${r != null && r.scored ? r.overall : '-'}分｜'
          '钩子${PipelineQa.hasEndingHook(c.content) ? '有' : '无'}｜'
          'AI味${echo.toStringAsFixed(0)}%｜问题${c.issues.length}处');
    }
    return b.toString().trim();
  }

  /// 拼未收伏笔行（终审判「伏笔回收」维度的直接依据）。
  static String _chiefOpenForeshadows(ForeshadowLedger ledger) {
    final StringBuffer b = StringBuffer();
    for (final ForeshadowEntry e in ledger.open.take(12)) {
      final String d = e.desc.length > 40 ? e.desc.substring(0, 40) : e.desc;
      b.writeln('第${e.planted}章埋：$d');
    }
    return b.toString().trim();
  }

  /// 取评分最低的章（终审样本三）；无评分时退回第 1 章。
  static PipelineChapter? _worstScoredChapter(AiPipelineTask task) {
    PipelineChapter? worst;
    int worstScore = 101;
    for (final PipelineChapter c in task.chapters) {
      final ChapterQualityReview? r = c.review;
      if (r == null || !r.scored) continue;
      if (r.overall < worstScore) {
        worstScore = r.overall;
        worst = c;
      }
    }
    return worst ??
        (task.chapters.isEmpty ? null : task.chapters.first);
  }

  /// 解析六维分（只收数值项，非数值一律跳过而非强转）。
  static Map<String, int> _chiefDimensions(Map<String, dynamic> parsed) {
    final Map<String, int> out = <String, int>{};
    final Map<String, dynamic>? raw =
        parsed['dimensions'] as Map<String, dynamic>?;
    raw?.forEach((String k, dynamic v) {
      if (v is num) out[k] = v.toInt();
    });
    return out;
  }

  /// 解析问题清单。
  static List<ChiefIssue> _chiefIssues(Map<String, dynamic> parsed) {
    return (parsed['top_issues'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ChiefIssue.fromJson)
        .where((ChiefIssue e) => e.issue.trim().isNotEmpty)
        .toList();
  }

  /// 合并多采样：六维逐项取中位数 + 综合取中位数。
  ///
  /// 逐项中位而非「先合并总分再各维取样」——后者在样本数少时会把不同轮次的
  /// 维度混在一起，凭空造出一个从未被任何一轮打出过的组合。
  static ChiefReview _mergeChiefSamples(
    List<ChiefReview> samples,
    int round,
  ) {
    int median(List<int> xs) {
      final List<int> s = List<int>.from(xs)..sort();
      return s[s.length ~/ 2];
    }

    final Set<String> keys = <String>{};
    for (final ChiefReview r in samples) {
      keys.addAll(r.dimensions.keys);
    }
    final Map<String, int> dims = <String, int>{};
    for (final String k in keys) {
      final List<int> vs = samples
          .map((ChiefReview r) => r.dimensions[k])
          .where((int? v) => v != null && v >= 0)
          .map((int? v) => v!)
          .toList();
      if (vs.isNotEmpty) dims[k] = median(vs);
    }

    // 问题清单按「多轮共识」优先：多轮都点名的排前面。
    final Map<String, int> seen = <String, int>{};
    for (final ChiefReview r in samples) {
      for (final ChiefIssue e in r.topIssues) {
        final String k = '${e.chapter}|${e.issue}';
        seen[k] = (seen[k] ?? 0) + 1;
      }
    }
    final List<ChiefIssue> issues = <ChiefIssue>[];
    final List<ChiefReview> ordered = List<ChiefReview>.from(samples)
      ..sort((ChiefReview a, ChiefReview b) =>
          b.topIssues.length.compareTo(a.topIssues.length));
    for (final ChiefReview r in ordered) {
      for (final ChiefIssue e in r.topIssues) {
        final bool dup = issues.any((ChiefIssue x) =>
            x.chapter == e.chapter && x.issue == e.issue);
        if (!dup) issues.add(e);
      }
    }
    final List<String> fixes = <String>[];
    for (final ChiefReview r in samples) {
      for (final String f in r.fixPriority) {
        if (!fixes.contains(f)) fixes.add(f);
      }
    }
    final int overall =
        median(samples.map((ChiefReview r) => r.overall).toList());
    return ChiefReview(
      round: round,
      overall: overall,
      dimensions: dims,
      // 判档**本地按分数区间**判，模型判词只作参考——同分必同档。
      verdict: AiPipelineTask.verdictOf(overall),
      topIssues: issues.take(5).toList(),
      fixPriority: fixes.take(3).toList(),
      samples: samples.length,
    );
  }

  /// 跑一轮终审（多采样取中位数）。
  ///
  /// **多采样是必需的不是优化**：实测同一本书跨轮终审 83/68/64/71/64，单次采样
  /// 的噪声比章间真实差距还大，「70 分打回线」在这种方差下毫无意义。
  ///
  /// 返回 `overall = -1` 表示本轮没跑出结论（端点全败/解析失败），调用方须
  /// 据此记「无结论」，**不得当成「0 分」**——那会让打回重写对着一个从未存在
  /// 的低分去改稿。
  Future<ChiefReview> _runChiefPass(
    AiPipelineTask task,
    int round, {
    required bool Function() isCancelled,
  }) async {
    final AiRoleConfig cfg = task.config.roleOf(AiRole.editor);
    if (!_chainConfigured(cfg)) return ChiefReview(round: round, overall: -1);
    final List<PipelineChapter> chapters = List<PipelineChapter>.from(
      task.chapters,
    )..sort((PipelineChapter a, PipelineChapter b) => a.idx.compareTo(b.idx));
    if (chapters.isEmpty) return ChiefReview(round: round, overall: -1);

    final PipelineChapter? worst = _worstScoredChapter(task);
    final String prompt = chiefEditorPrompt(
      title: task.title,
      genre: task.config.genre,
      totalWords: task.totalWords,
      chapterCount: chapters.length,
      rows: _chiefChapterRows(task),
      openForeshadows: _chiefOpenForeshadows(task.ledger),
      stateTrack: task.stateTrack,
      first: chapters.first.content.length > 1200
          ? chapters.first.content.substring(0, 1200)
          : chapters.first.content,
      last: chapters.last.content.length > 1200
          ? chapters.last.content.substring(0, 1200)
          : chapters.last.content,
      worstIdx: worst?.idx ?? 0,
      worstText: worst == null
          ? '（无）'
          : worst.content.length > 800
              ? worst.content.substring(0, 800)
              : worst.content,
    );

    final int target = task.chiefSamples < 1 ? 1 : task.chiefSamples;
    final List<ChiefReview> samples = <ChiefReview>[];
    // 最多打 2×目标次数补解析失败（对齐 Python `max_attempts = target * 2`）。
    for (int attempt = 0;
        attempt < target * 2 && samples.length < target;
        attempt++) {
      if (isCancelled()) break;
      final String raw = await _call(
        task,
        AiRole.editor,
        chiefEditorSystemPrompt,
        prompt,
        isCancelled: isCancelled,
      );
      final Map<String, dynamic>? parsed = _parseJsonObject(raw);
      final int overall = (parsed?['overall'] as num?)?.toInt() ?? -1;
      if (parsed != null && overall >= 0) {
        samples.add(ChiefReview(
          round: round,
          overall: overall,
          dimensions: _chiefDimensions(parsed),
          verdict: AiPipelineTask.verdictOf(overall),
          topIssues: _chiefIssues(parsed),
          // parsed 已在上方判过非空，这里不必再用 ?[]。
          fixPriority:
              ((parsed['fix_priority'] ?? const <dynamic>[]) as List<dynamic>)
                  .map((dynamic e) => e.toString())
                  .toList(),
        ));
        task.addLog('  [终审·第$round轮·采样 ${samples.length}/$target] 综合 $overall 分');
      } else {
        task.addLog('  [终审·第$round轮·尝试 ${attempt + 1}] 解析失败');
      }
    }
    if (samples.isEmpty) {
      task.addLog('  [终审·第$round轮] 全部采样解析失败，本轮无结论');
      return ChiefReview(round: round, overall: -1);
    }
    final ChiefReview merged = _mergeChiefSamples(samples, round);
    task.addLog('  [终审·第$round轮] 合并综合 ${merged.overall} 分｜${merged.verdict}'
        '（有效采样 ${merged.samples} 次）');
    final Map<String, int> hard = merged.hardDimensions;
    if (hard.isNotEmpty) {
      // 硬伤维度告警：任一维 ≤40 时即使总分达标也要强制人工复核
      // （防「总分 83 但伏笔回收 30」被总分掩盖）。
      task.addLog('  [终审·第$round轮] ☠ 硬伤维度（≤40）：'
          '${hard.keys.join('、')}——即使总分达标也建议人工复核');
    }
    return merged;
  }

  /// 回收清单打勾结果里兑现的条数（用于「复检是否变好」的比较）。
  static int _fulfilledCount(List<PromiseCheck> checks) =>
      checks.where((PromiseCheck r) => r.fulfilled && !r.failed).length;

  /// 取清单第 [id] 条（1 起）的描述；越界返回空串。
  ///
  /// 补写 prompt 要点名「哪一条没兑现」，而验收结果里只有序号 + 反馈，
  /// 没有描述——这里按 [promiseBlock] 的同序映射回查（与
  /// `applyClosures` 的映射规则一致）。查不到就返回空串让调用方过滤掉，
  /// 宁可少补一条，也不能把错误的描述塞进 prompt 让模型改错地方。
  static String _promiseDescAt(List<ForeshadowEntry> block, int id) {
    final int n = id - 1;
    if (n < 0 || n >= block.length) return '';
    return block[n].desc;
  }

  /// 跑一轮回收清单验收，返回 `(打勾结果, 是否跑成)`。
  ///
  /// **[ok=false 绝不等于「全部未兑现」]**——与 [ChannelFactCheck] 的 `ok`
  /// 同构的纪律：端点全失败 / 两次解析失败 / 不合 schema，都说明「验收没跑成」，
  /// 此时若当成「都没兑现」，会触发一次针对不存在问题的补写，白烧一次调用并
  /// 可能把好正文改坏。最多重试一次（对齐 Python `_verify` 的两次尝试）。
  ///
  /// 校验走编辑链（与写手异家族），理由同 Python：单点端点在思考链风暴期
  /// 会原地连败，链式 failover 让健康池自动换端点。
  Future<({List<PromiseCheck> checks, bool ok})> _verifyPromises(
    AiPipelineTask task,
    String text,
    int idx,
    List<ForeshadowEntry> block,
  ) async {
    final AiRoleConfig cfg = task.config.roleOf(AiRole.editor);
    if (!_chainConfigured(cfg)) return (checks: const <PromiseCheck>[], ok: false);
    final String prompt = promiseVerifyPrompt(
      text,
      block
          .map((ForeshadowEntry e) => ForeshadowLine(e.desc))
          .toList(),
      idx,
    );
    for (int attempt = 0; attempt < 2; attempt++) {
      final String raw = await _call(
        task,
        AiRole.editor,
        promiseVerifySystemPrompt,
        prompt,
        isCancelled: () => false,
      );
      final Map<String, dynamic>? parsed = _parseJsonObject(raw);
      final List<dynamic>? list = parsed?['results'] as List<dynamic>?;
      if (list != null && list.isNotEmpty) {
        return (
          checks: list
              .whereType<Map<String, dynamic>>()
              .map(PromiseCheck.fromJson)
              .where((PromiseCheck r) => r.id > 0 && !r.failed)
              .toList(),
          ok: true,
        );
      }
      if (attempt == 0) {
        task.addLog('  [打勾] 校验输出为空/解析失败，重试一次…');
      }
    }
    return (checks: const <PromiseCheck>[], ok: false);
  }

  /// 关卡5 跑一轮编造核查，返回 `(命中列表, 是否跑成)`。
  ///
  /// **[ok=false 绝不等于「0 命中」]**——这是 Python 端门禁第 16 项的核心语义：
  /// 端点全链失败 / 返回不是 JSON / `fabrications` 不是数组，三种情况都说明
  /// 「核查没跑成」，此时若当成干净结果，等于把一次静默失效伪装成一次通过。
  /// 调用方据此单独记账，UI 也必须区分显示（见 [ChapterFactCheck.ok]）。
  ///
  /// 用规划官链（与写手异家族）做核查，理由同 Python 端：同模型自我核查容易
  /// 把自己写过的细节当成「台账里的既有事实」，异家族才有真正的对照价值。
  Future<({List<Fabrication> hits, bool ok})> _runFactCheck(
    AiPipelineTask task,
    String text,
    int idx,
  ) async {
    final AiRoleConfig cfg = task.config.roleOf(AiRole.planner);
    if (!_chainConfigured(cfg)) {
      return (hits: const <Fabrication>[], ok: false);
    }
    // 户籍表取大纲的世界观 + 主角设定，数字/状态台账取跨章状态清单
    // （Dart 侧目前只有 stateTrack 一份台账，Python 侧的 registry/facts
    //  拆分更细——核查覆盖面因此窄于 Python 端，属已知差距，见交付文档）。
    final String raw = await _call(
      task,
      AiRole.planner,
      factCheckSystemPrompt,
      fabricationCheckPrompt(
        text,
        idx,
        registry: task.worldTermsForCheck,
        facts: '',
        stateTrack: task.stateTrack,
      ),
      isCancelled: () => false,
    );
    final Map<String, dynamic>? parsed = _parseJsonObject(raw);
    final List<dynamic>? list = parsed?['fabrications'] as List<dynamic>?;
    if (list == null) {
      // 合 schema 守卫：必须真的拿到数组才认「跑成了」。
      return (hits: const <Fabrication>[], ok: false);
    }
    return (
      hits: list
          .whereType<Map<String, dynamic>>()
          .map(Fabrication.fromJson)
          .where((Fabrication fb) => fb.claim.trim().isNotEmpty)
          .toList(),
      ok: true,
    );
  }

  /// 从 LLM 文本提取首个 JSON 对象（失败返回 null）。
  Map<String, dynamic>? _parseJsonObject(String text) {
    if (text.isEmpty) return null;
    final int s = text.indexOf('{');
    final int e = text.lastIndexOf('}');
    if (s < 0 || e <= s) return null;
    try {
      final dynamic decoded = jsonDecode(text.substring(s, e + 1));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 场景/章节衔接去重：若 newText 开头与 prevText 结尾有 >=minOverlap 字的
  /// 连续重叠（LLM 续写常把上一段结尾复述一遍），裁掉重叠部分再拼接。
  /// 返回 (去重后文本, 是否发生裁剪)。
  (String, bool) _dedupSceneJoin(String prevText, String newText, [int minOverlap = 12]) {
    if (prevText.isEmpty || newText.isEmpty) return (newText, false);
    final String trimmed = prevText.trimRight();
    final String prevTail = trimmed.length > 200
        ? trimmed.substring(trimmed.length - 200)
        : trimmed;
    int best = 0;
    final int maxCheck = newText.length < prevTail.length ? newText.length : prevTail.length;
    for (int i = maxCheck; i >= minOverlap; i--) {
      if (prevTail.substring(prevTail.length - i) == newText.substring(0, i)) {
        best = i;
        break;
      }
    }
    if (best >= minOverlap) {
      return (newText.substring(best), true);
    }
    return (newText, false);
  }

  /// 校验五角色配置是否就绪（用于 UI 启动前提示）。
  /// 链上任一端点（主或备用）已配置即视为就绪。
  static List<AiRole> missingRoles(AiPipelineConfig config) {
    return AiRole.values
        .where((AiRole r) {
          final AiRoleConfig cfg = config.roleOf(r);
          if (r == AiRole.writer) return !_chainConfigured(cfg);
          if (r == AiRole.planner) return !_chainConfigured(cfg);
          if (r == AiRole.editor) {
            return config.useEditor && !_chainConfigured(cfg);
          }
          if (r == AiRole.titler) return !_chainConfigured(cfg);
          if (r == AiRole.verifier) {
            return config.useVerifier && !_chainConfigured(cfg);
          }
          return false;
        })
        .toList();
  }

  /// 运行（或续跑）一个任务，直到完成/取消/失败。
  ///
  /// [isCancelled] 每章节循环节点检查；[onProgress] 每章节完成后回调。
  /// 同一存储目录下所有服务实例共用的 FIFO 运行队列。
  static final Map<String, Future<void>> _runTails = <String, Future<void>>{};

  /// 运行任务（外部入口，跨服务实例串行执行）。
  Future<void> run(
    AiPipelineTask task, {
    required bool Function() isCancelled,
    required void Function() onProgress,
  }) {
    final String key = _storage.directory.replaceAll('\\', '/').toLowerCase();
    final Future<void>? previous = _runTails[key];
    final Completer<void> done = Completer<void>();
    _runTails[key] = done.future;
    return () async {
      try {
        try {
          await previous;
        } catch (_) {
          // 前一个任务失败不应阻塞后续任务。
        }
        await _runUnlocked(
          task,
          isCancelled: isCancelled,
          onProgress: onProgress,
        );
      } on GenerationCancelledException {
        _finishCancel(task);
        await _storage.saveTask(task);
      } catch (error, stack) {
        task.status = PipelineTaskStatus.failed;
        task.finishedAt = DateTime.now();
        task.error = error.toString();
        task.addLog('  [异常] 流水线失败：$error');
        try {
          await _storage.saveTask(task);
        } catch (saveError, saveStack) {
          task.addLog('  [异常] 失败状态保存也失败：$saveError');
          Error.throwWithStackTrace(saveError, saveStack);
        }
        Error.throwWithStackTrace(error, stack);
      } finally {
        if (identical(_runTails[key], done.future)) {
          _runTails.remove(key);
        }
        done.complete();
      }
    }();
  }

  /// 实际执行逻辑；只能由串行的 [run] 调用。
  Future<void> _runUnlocked(
    AiPipelineTask task, {
    required bool Function() isCancelled,
    required void Function() onProgress,
  }) async {
    Future<String> call(
      AiRole role,
      String system,
      String user, {
      double? temperature,
    }) =>
        _call(
          task,
          role,
          system,
          user,
          temperature: temperature,
          isCancelled: isCancelled,
        );

    task.status = PipelineTaskStatus.running;
    task.error = null;
    task.finishedAt = null;
    await _storage.saveTask(task);
    task.addLog('[流水线] 启动：目标 ${task.config.totalWords} 字');

    // ===== Phase 1：总规划官规划全书大纲 =====
    if (task.outline.isEmpty) {
      task.addLog('[规划官] 规划全书大纲...');
      final String raw = await call(
        AiRole.planner,
        plannerSystemPrompt,
        planningPrompt(
          totalWords: task.config.totalWords,
          genre: task.config.genre,
          protagonist: task.config.protagonist,
        ),
      );
      final Map<String, dynamic>? outline = _parseJsonObject(raw);
      final List<dynamic>? chars =
          outline?['chapter_outlines'] as List<dynamic>?;
      if (outline == null || chars == null || chars.isEmpty) {
        task.status = PipelineTaskStatus.failed;
        task.error = '大纲规划失败：${raw.substring(0, raw.length > 120 ? 120 : raw.length)}';
        task.finishedAt = DateTime.now();
        await _storage.saveTask(task);
        return;
      }
      task.outline = outline;
      task.addLog('[规划官] 《${outline['title']}》共 ${chars.length} 章');
      await _storage.saveTask(task);
    } else {
      task.addLog('[续传] 《${task.title}》已有 ${task.chapterCount} 章');
    }

    final List<dynamic> chars =
        (task.outline['chapter_outlines'] as List<dynamic>?) ?? <dynamic>[];
    if (isCancelled()) {
      _finishCancel(task);
      await _storage.saveTask(task);
      return;
    }

    // ===== Phase 2：逐章多角色协作 =====
    for (final dynamic ch in chars) {
      if (isCancelled()) {
        _finishCancel(task);
        await _storage.saveTask(task);
        return;
      }
      final int idx = (ch['idx'] as num?)?.toInt() ?? 0;
      if (task.chapters.any((PipelineChapter c) => c.idx == idx)) continue;
      if (task.totalWords >= task.config.totalWords) break;
      if (idx > task.config.maxChapters) break;

      final String goal = outlineText(ch['goal']);
      // LLM 大纲里的 target 也属于不可信输入：限制到可执行的最小/最大范围，
      // 避免模型返回 0 或负数把质量门槛降到 1 字。
      final int target =
          ((ch['target'] as num?)?.toInt() ?? 3000).clamp(60, 20000);
      final String lastSummary = _lastChapterTail(task);
      task.addLog('===== 第 $idx 章（目标 $target 字）：$goal =====');

      // 1) 场景规划（重试 2 次 → 默认骨架兜底），注入跨章状态
      List<Map<String, dynamic>> scenes = <Map<String, dynamic>>[];
      // 全书世界观（规划官设定）注入场景规划，防止正文脱离大纲（裴照系统流→赵铁柱超自然流 事故）
      final Map<String, dynamic> outlineMap =
          task.outline as Map<String, dynamic>? ?? <String, dynamic>{};
      // 规划官按契约会把 world/protagonist 返回成对象，这里统一拍平成文本。
      final String worldHint = outlineText(outlineMap['world']);
      final String hookHint = outlineText(outlineMap['hook']);
      final String fullWorldHint = [
        if (worldHint.isNotEmpty) worldHint,
        if (hookHint.isNotEmpty) '开篇钩子：$hookHint',
      ].join('；');
      // 未收伏笔摘要注入（提醒写手：已埋伏笔勿改设定，长线伏笔等待回收）
      String stateInject = task.config.useStateTrack ? task.stateTrack : '';
      try {
        final dynamic fsDecoded = task.foreshadowLedger.trim().isEmpty
            ? null
            : jsonDecode(task.foreshadowLedger);
        final List<dynamic> fsItems = fsDecoded is Map<String, dynamic>
            ? (fsDecoded['foreshadows'] as List<dynamic>? ?? <dynamic>[])
            : (fsDecoded is List<dynamic> ? fsDecoded : <dynamic>[]);
        final List<String> fsOpen = fsItems
            .whereType<Map<String, dynamic>>()
            .where((dynamic e) =>
                e['status'] == 'open' && outlineText(e['desc']).isNotEmpty)
            .take(8)
            .map((dynamic e) => '- ${outlineText(e['desc'])}')
            .toList();
        if (fsOpen.isNotEmpty) {
          final String fsSummary = '【未收伏笔（写作时勿改相关设定，尽量自然推进/回收）】\n${fsOpen.join('\n')}';
          stateInject = stateInject.isNotEmpty ? '$stateInject\n\n$fsSummary' : fsSummary;
        }
      } catch (_) {}
      for (int attempt = 0; attempt < 2; attempt++) {
        final String raw = await call(
          AiRole.planner,
          plannerSystemPrompt,
          scenePlanningPrompt(
            goal,
            lastSummary,
            state: stateInject,
            worldHint: fullWorldHint,
          ),
        );
        final Map<String, dynamic>? plan = _parseJsonObject(raw);
        final List<dynamic>? list = plan?['scenes'] as List<dynamic>?;
        if (list != null && list.isNotEmpty) {
          scenes = list
              .whereType<Map<String, dynamic>>()
              .toList();
          break;
        }
      }
      if (scenes.isEmpty) {
        scenes = defaultScenePlan(target);
        task.addLog('  [规划] LLM 场景规划失败，使用默认「起承转合」骨架');
      }
      task.addLog('  [规划] ${scenes.length} 场景：${scenes.map((s) => s['stage']).join('/')}');

      // 2) 逐场景正文（写手）
      final List<String> sceneTexts = <String>[];
      // 未产出正文的场景序号（1 基），用于成书残缺告警与落库记账。
      final List<int> lostScenes = <int>[];
      String prevText = lastSummary;
      for (int si = 0; si < scenes.length; si++) {
        final Map<String, dynamic> sc = scenes[si];
        final String stage = outlineText(sc['stage']).isEmpty
            ? '承'
            : outlineText(sc['stage']);
        final String goalS = outlineText(sc['goal']);
        final List<String> beats = (sc['beats'] is Iterable)
            ? (sc['beats'] as Iterable<dynamic>)
                .map(outlineText)
                .where((String e) => e.isNotEmpty)
                .toList()
            : <String>[];
        final int tw = ((sc['targetWords'] as num?)?.toInt() ?? 600).clamp(300, 1500);
        task.addLog('  [场景 ${si + 1}/${scenes.length}] $stage：$goalS（目标 $tw 字）');
        String text = await call(
          AiRole.writer,
          writerSystemPrompt,
          scenePrompt(
            sceneNo: si + 1,
            totalScenes: scenes.length,
            stage: stage,
            goal: goalS,
            beats: beats,
            prevText: prevText,
            state: task.config.useStateTrack ? task.stateTrack : '',
            genre: task.config.genre,
            protagonist: task.config.protagonist,
            world: worldHint,
            isOpening: idx == 1 && si == 0,
          ),
        );
        text = text.trim();
        // 场景衔接去重：裁掉与上一场景结尾重复的开头
        if (sceneTexts.isNotEmpty) {
          final (String deduped, bool cut) = _dedupSceneJoin(sceneTexts.last, text);
          if (cut) {
            task.addLog('    [去重] 场景衔接重叠，已裁剪');
          }
          text = deduped;
        }
        final int w = text.isEmpty ? 0 : _countWords(text);
        task.addLog('    -> $w 字');
        if (text.isNotEmpty) {
          sceneTexts.add(text);
          prevText = text;
        } else {
          // 【可观测性 2026-09-30】场景返回空 = 该端点/模型整条链都没出正文
          // （思考链吃满 max_tokens、全部冷却等）。旧实现直接跳过，成书残缺却
          // 无任何痕迹——真机第 4 章 4 个场景丢了 2 个，标题与章纲都对不上，
          // 却伪装成正常章节落库。这里显式记账并告警。
          lostScenes.add(si + 1);
          task.addLog('    [WARN] 场景 $stage 未产出正文（端点全链失败），'
              '本章将残缺 ${scenes.length - lostScenes.length}/${scenes.length} 场景');
        }
        // 字数不足补充续写
        if (w > 50 && w < tw * 0.4) {
          final String add = await call(
            AiRole.writer,
            writerSystemPrompt,
            '请续写 300 字，承接：\n${_tail(text, 100)}\n\n只输出续写正文：',
          );
          if (add.trim().isNotEmpty) {
            sceneTexts.add('\n\n${add.trim()}');
          }
        }
      }

      String fullText = sceneTexts.join('\n\n');
      // 章节级衔接去重：本章开头若与上一章结尾重叠（LLM 跨章续写常见），裁剪
      if (idx > 1 && lastSummary.isNotEmpty) {
        final (String deduped, bool cut) = _dedupSceneJoin(lastSummary, fullText);
        if (cut) {
          task.addLog('  [去重] 章节衔接重叠，已裁剪');
        }
        fullText = deduped;
      }
      int w = _countWords(fullText);
      if (w < target * 0.5) {
        task.addLog('  [WARN] 仅 $w 字，整章续写...');
        final String add = await call(
          AiRole.writer,
          writerSystemPrompt,
          '请将下面章节内容扩充到 $target 字以上，保留原意，只输出正文：\n${_tail(fullText, 500)}...',
        );
        if (add.trim().isNotEmpty) {
          fullText = '$fullText\n\n${add.trim()}';
          w = _countWords(fullText);
        }
      }

      // 3) 去AI味润色（编辑）
      // 字数下限守卫：fulltest 实测编辑链曾把 3805 字章润色成 1921 字砍半，
      // 过度压缩视为无效产出，保留原文并告警。
      // 阈值取自单一数据源 QualityRules.editorMinRatio（rules/quality_rules.json），
      // 与 Python EDITOR_MIN_RATIO 同值同源——此前两端各自硬编码 0.85，
      // 是唯一一条不受 rules_codegen 保护的阈值。
      int rawWords = w;
      if (task.config.useEditor) {
        final String edited = await call(
          AiRole.editor,
          editorSystemPrompt,
          editorPrompt(fullText),
        );
        if (edited.isNotEmpty) {
          final int wEdited = _countWords(edited);
          final int minWords = (w * QualityRules.editorMinRatio).ceil();
          if (wEdited >= minWords) {
            task.addLog('  [编辑] 润色完成 $w -> $wEdited 字');
            fullText = edited;
          } else {
            task.addLog('  [编辑] ⚠ 润色产出 $w -> $wEdited 字，过度压缩'
                '（<${(QualityRules.editorMinRatio * 100).round()}%），拒绝采纳保留原文');
          }
        } else {
          task.addLog('  [编辑] 润色失败，保留原文');
        }
      }

      // 3.5) 章末钩子兜底：结尾 200 字无钩子信号词时，补写钩子句（保追读）
      //      补丁卫生：补写产出先过 FanqieGateChecker.patchReject，被拒时改用章纲钩子本地兜底。
      //      实测事故：补写返回「我拿到的指令是补写钩子，不是扩写…」被原样拼进正文；
      //      另一章补出「手机屏幕亮了。不是短信。」把玄幻书写成了都市悬疑。
      if (fullText.trim().isNotEmpty && !PipelineQa.hasEndingHook(fullText)) {
        task.addLog('  [钩子] 章末缺钩，自动补写钩子...');
        final String add = await call(
          AiRole.writer,
          writerSystemPrompt,
          '下面是本章结尾，最后 1~2 句太平淡，没有留下让读者必须看下一章的悬念。'
          '请接着补写 30~80 字的钩子句（悬念/变故/威胁逼近/秘密将揭，按${task.config.genre}题材），'
          '不新增情节、不改变已发生的事，只把结尾收在悬念上。'
          '只输出补写内容本身，不要任何解释、说明或字数报告：\n\n${_tail(fullText, 300)}',
        );
        final String? why = FanqieGateChecker.patchReject(
          add,
          baseText: fullText,
          genre: task.config.genre,
          maxWords: 160,
        );
        if (why == null) {
          fullText = '${fullText.trimRight()}\n\n${add.trim()}';
          task.addLog('  [钩子] 已补写钩子');
        } else {
          task.addLog('  [钩子] LLM 补写被拒（$why）→ 章纲钩子本地兜底');
          final String fallback = _localHookFallback(
            _chapterHookHint(ch),
            task.config.protagonist,
            task.config.genre,
          );
          // 兜底产出同样要过补丁卫生闸：旧实现只审 LLM 补写，本地兜底是盲区，
          // 大纲标注就是这么漏进成书的（实测「威胁逼近（……）」落进第 1 章末尾）。
          final String? fbWhy = fallback.isEmpty
              ? '无可用兜底素材'
              : FanqieGateChecker.patchReject(
                  fallback,
                  baseText: fullText,
                  genre: task.config.genre,
                  maxWords: 160,
                );
          if (fallback.isNotEmpty && fbWhy == null) {
            fullText = '${fullText.trimRight()}\n\n$fallback';
            task.addLog('  [钩子] 本地兜底：'
                '${fallback.length > 40 ? fallback.substring(0, 40) : fallback}');
          } else {
            task.addLog('  [钩子] 本地兜底被拒（${fbWhy ?? '空产出'}）→ 保留原文，章末无钩需人工补');
          }
        }
      }

      // 4) 章节最低正文门槛：模型/端点全失败时不能把空章当成成功。
      // 仍保留已有扩写与编辑链路作为正常降级路径；只有最终正文仍不足时才失败。
      final int finalWords = _countWords(fullText);
      final int minWords = target > 0 ? (target * 0.5).ceil() : 1;
      if (fullText.trim().isEmpty || finalWords < minWords) {
        task.status = PipelineTaskStatus.failed;
        task.error = '第 $idx 章正文不足：仅 $finalWords 字，最低要求 $minWords 字';
        task.finishedAt = DateTime.now();
        task.addLog('  [失败] ${task.error}');
        await _storage.saveTask(task);
        return;
      }

      // 5) 章节标题（标题官）
      final String titleHint = outlineText(ch['title']);
      String title = titleHint.isEmpty ? '第$idx章' : titleHint;
      final String t = await call(
        AiRole.titler,
        titlerSystemPrompt,
        titlerPrompt(fullText),
      );
      if (t.isNotEmpty) {
        title = t.length > 30 ? t.substring(0, 30) : t;
      }
      task.addLog('  [标题] $title');

      // 5) 每 5 章一致性审校（审校官，只记录）
      final List<String> issues = <String>[];
      // 结构化质量记录：随章节一并落库，供 UI「质量」面板与导出报告使用。
      // 旧实现只把分数拼进日志文本，日志滚出 400 条即丢——评分等于只存在于
      // 运行当时的屏幕上，作者事后无法回看「第 7 章当年被判多少、卡在哪一维」。
      ChapterQualityReview? qualityReview;
      ChapterFactCheck? factCheck;
      if (task.config.useVerifier && idx % 5 == 0 && task.chapters.isNotEmpty) {
        final String chapList = task.chapters
            .where((PipelineChapter c) => c.idx >= idx - 4)
            .map((PipelineChapter c) => '第${c.idx}章《${c.title}》')
            .join('\n');
        final String v = await call(
          AiRole.verifier,
          verifierSystemPrompt,
          verifierPrompt(jsonEncode(task.outline), chapList),
        );
        final Map<String, dynamic>? parsed = _parseJsonObject(v);
        final List<dynamic>? issueList = parsed?['issues'] as List<dynamic>?;
        if (issueList != null) {
          for (final dynamic it in issueList) {
            final Map<String, dynamic> m = it as Map<String, dynamic>;
            final String desc =
                '第${m['chapter']}章 ${m['type']}: ${m['desc']}';
            issues.add(desc);
            task.addLog('  [审校] ⚠ $desc');
          }
        }
      }

      // 6) 本地质检：世界观冲突 + 商业向（钩子/开场节奏）
      final List<String> conflicts = PipelineQa.worldConflicts(
        task.chapters.toList(),
        PipelineChapter(
          idx: idx,
          title: title,
          content: fullText,
          rawWords: rawWords,
          words: _countWords(fullText),
        ),
      );
      for (final String c in conflicts) {
        issues.add(c);
        task.addLog('  [质检] ⚠ $c');
      }
      // 商业向质检：章末钩子缺失 / 黄金三章开场迟缓（只记录不阻塞）。
      final List<String> commercial = PipelineQa.chapterIssues(
        PipelineChapter(
          idx: idx,
          title: title,
          content: fullText,
          rawWords: rawWords,
          words: _countWords(fullText),
        ),
      );
      for (final String c in commercial) {
        issues.add(c);
        task.addLog('  [质检] ⚠ $c');
      }

      // 7) 语义级质量评分（审校官五维打分，每 N 章一次，只记录不阻塞）
      if (task.config.useQualityReview &&
          idx % task.config.qualityReviewEvery == 0) {
        // 本地质检证据注入：LLM 评审带证据打分，不与规则引擎矛盾
        // （治「100 分无钩子」分裂，与 Python 端 qa_ev 同口径；落点证据串
        // 与 Python release_ev_fragment 同文）。
        final String releaseEv = PipelineQa.releaseEvFragment(fullText);
        final String endingEv = PipelineQa.endingEvFragment(fullText);
        final String qaEv =
            '章末钩子检测：${PipelineQa.hasEndingHook(fullText) ? '命中 ✅' : '未命中 ❌（hook 维度不应高于 40 分）'}；'
            '直白爽点 ${PipelineQa.thrillPerThousand(fullText).toStringAsFixed(2)}/千字；'
            '变强异动 ${PipelineQa.surgePerThousand(fullText).toStringAsFixed(2)}/千字；'
            '侧面反响 ${PipelineQa.sideReactionPerThousand(fullText).toStringAsFixed(2)}/千字；'
            '$releaseEv；$endingEv';
        final String qr = await call(
          AiRole.verifier,
          verifierSystemPrompt,
          qualityReviewPrompt(fullText, qaEvidence: qaEv),
        );
        final Map<String, dynamic>? parsed = _parseJsonObject(qr);
        final Map<String, dynamic>? scores =
            parsed?['scores'] as Map<String, dynamic>?;
        final int overall = (parsed?['overall'] as num?)?.toInt() ?? -1;
        if (overall >= 0) {
          final String comment = outlineText(parsed?['comment']);
          // 结构化落库：五维分原样存下，UI 才能按维度渲染、排序、定位短板。
          qualityReview = ChapterQualityReview(
            idx: idx,
            overall: overall,
            dims: <String, int>{
              for (final String k in const <String>[
                'opening',
                'thrill',
                'hook',
                'motivation',
                'rhythm',
              ])
                if (scores?[k] is num) k: (scores![k] as num).toInt(),
            },
            comment: comment,
            evidence: qaEv,
          );
          task.addLog('  [评分] 第 $idx 章 综合 $overall 分'
              '（开篇${scores?['opening'] ?? '-'}/爽点${scores?['thrill'] ?? '-'}'
              '/钩子${scores?['hook'] ?? '-'}/动机${scores?['motivation'] ?? '-'}'
              '/节奏${scores?['rhythm'] ?? '-'}）$comment');
          if (overall < 60) {
            issues.add('第 $idx 章 语义质量评分 $overall 分（<60）：$comment');
            task.addLog('  [评分] ⚠ 低于 60 分，建议人工关注或触发重写');
          }
          // 低分自动重写：低于阈值时由编辑官定向重写，当场修复。
          if (task.config.autoRewriteLowScore &&
              overall < task.config.rewriteThreshold) {
            task.addLog('  [重写] 第 $idx 章 $overall 分 < ${task.config.rewriteThreshold}，触发自动重写...');
            final String rewritten = await call(
              AiRole.editor,
              editorSystemPrompt,
              rewritePrompt(
                text: fullText,
                reviewComment: comment,
                scores: scores,
              ),
            );
            if (rewritten.trim().isNotEmpty) {
              final int wNew = _countWords(rewritten.trim());
              if (wNew < minWords) {
                task.addLog('  [重写] 重写产出 $wNew 字，低于最低 $minWords 字，保留原文');
              } else {
                task.addLog('  [重写] 第 $idx 章 $w 字 -> $wNew 字');
                fullText = rewritten.trim();
                w = wNew;
                // 低分告警替换为「已重写」记录。
                issues.removeWhere((String e) => e.contains('语义质量评分'));
                issues.add('第 $idx 章 质量评分 $overall 分（<${task.config.rewriteThreshold}），已自动重写');
              }
            } else {
              task.addLog('  [重写] 第 $idx 章 重写失败，保留原文');
            }
          }
        } else {
          task.addLog('  [评分] 第 $idx 章 评分解析失败，跳过（不影响生成）');
        }
      }

      // 7.5) 关卡5 编造核查：对照已确立事实独立核查本章正文（Dart 端此前完全缺失）
      //
      // 【为什么补】Python 端有完整关卡5（核查→修→复检），Dart 生成路径只有
      // 番茄闸门与语义关——写手凭空补出的「老周欠债三年」「命火令凹槽」这类
      // 细节会原样留在成书里，**再跑一百遍也不会好**，而作者在 GUI 上看不到
      // 任何提示。语义关卡抓的是「人称/称谓/题材/关系」，抓不到「凭空编」。
      //
      // 三条与 Python 端同构的纪律：
      // ① 没跑成 ≠ 没问题（ok=false 单独标记，绝不冒充 0 命中的干净结果）；
      // ② 命中即定点修，但**只有复检命中数确实下降才采纳**，否则回滚原文——
      //    「换了段文字」不等于「问题解决了」；
      // ③ 字数下限随 prompt 下发（fixMinRatio 口径），禁止「以删代修」把整章压没。
      if (task.config.useFactCheck) {
        final ({List<Fabrication> hits, bool ok}) first = await _runFactCheck(
          task,
          fullText,
          idx,
        );
        if (!first.ok) {
          factCheck = ChapterFactCheck(idx: idx, ok: false);
          issues.add('第 $idx 章编造核查未跑成（端点全链失败或返回不合 schema）'
              '——不能据此认为本章无编造，建议人工核对本章与前章设定');
          task.addLog('  [核查] ⚠ 核查未跑成（不计入「无编造」结论）');
        } else if (first.hits.isEmpty) {
          factCheck = ChapterFactCheck(idx: idx, ok: true);
          task.addLog('  [核查] 编造核查通过 ✅（0 处编造）');
        } else {
          for (final Fabrication fb in first.hits.take(8)) {
            task.addLog('  [核查] ⚠ ${fb.typeLabel}: '
                '${fb.claim.length > 60 ? fb.claim.substring(0, 60) : fb.claim}');
          }
          task.addLog('  [核查] ${first.hits.length} 处编造 → 定点修并复检…');
          final String rawFix = await call(
            AiRole.editor,
            editorSystemPrompt,
            factFixPrompt(
              fullText,
              first.hits
                  .map(
                    (Fabrication fb) => FabricationSpec(
                      claim: fb.claim,
                      evidence: fb.evidence,
                      type: fb.type,
                    ),
                  )
                  .toList(),
              idx,
              minWords: (_countWords(fullText) * factFixMinRatio).ceil(),
            ),
          );
          final String? rejectWhy = rawFix.trim().isEmpty
              ? '空产出'
              : FanqieGateChecker.patchReject(
                  rawFix,
                  baseText: fullText,
                  genre: task.config.genre,
                  maxWords: (_countWords(fullText) * 2).ceil(),
                );
          if (rejectWhy != null) {
            factCheck = ChapterFactCheck(
              idx: idx,
              fabrications: first.hits,
              ok: true,
              firstRoundCount: first.hits.length,
            );
            task.addLog('  [核查] 修复稿未过采纳闸（$rejectWhy），保留原文照记命中');
            for (final Fabrication fb in first.hits.take(3)) {
              issues.add('第 $idx 章编造（${fb.typeLabel}，未修）：${fb.claim}');
            }
          } else {
            final String repaired = '${fullText.trimRight()}\n\n${rawFix.trim()}';
            final ({List<Fabrication> hits, bool ok}) second =
                await _runFactCheck(task, repaired, idx);
            final bool improved = second.ok && second.hits.length < first.hits.length;
            if (improved) {
              fullText = repaired;
              factCheck = ChapterFactCheck(
                idx: idx,
                fabrications: second.hits,
                ok: true,
                repaired: true,
                firstRoundCount: first.hits.length,
              );
              task.addLog('  [核查] 复检 ${first.hits.length} → ${second.hits.length} 处，'
                  '采纳修复稿（${_countWords(repaired)} 字）');
              for (final Fabrication fb in second.hits.take(3)) {
                issues.add('第 $idx 章编造残留（${fb.typeLabel}，修复未清零）：${fb.claim}');
              }
            } else {
              factCheck = ChapterFactCheck(
                idx: idx,
                fabrications: first.hits,
                ok: true,
                firstRoundCount: first.hits.length,
              );
              task.addLog('  [核查] ${second.ok ? '复检仍 ${second.hits.length} 处' : '复检未跑成'}、'
                  '未优于首轮，回滚保留原文（首轮命中照记）');
              for (final Fabrication fb in first.hits.take(3)) {
                issues.add('第 $idx 章编造（${fb.typeLabel}，复检未改善）：${fb.claim}');
              }
            }
          }
        }
      }

      // 主角在场记账 + 场景残缺记账（2026-09-30 新增，可观测性）
      //
      // 【主角漂移实测】真机 33 章长篇：主角「陆沉」第 1~29 章正常出场，自第 30 章
      // 起**连续 4 章 0 次**，POV 被换成了他人。提示词里早有硬约束
      // （`本章主角：X。全章只用这个名字`，见 pipeline_prompts.dart:176），
      // 但**提示词级指令不构成保证**——端点偶发抽风就绕过去了。
      //
      // 定位是「记账 + 告警」而非「判失败」：他人视角章是合法的文学选择
      // （多线叙事常写），一刀切失败会误伤好书，也会白烧一次 LLM 调用。
      // 真正兜底的是书级 [NovelConsistencyChecker.protagonistContinuity]：
      // 单章可疑不动，连续多章消失才判定事故。
      final String heroName = task.config.protagonist.trim();
      int heroMentions = -1;
      if (heroName.length >= 2) {
        heroMentions = ' $fullText '.split(heroName).length - 1;
        if (finalWords >= 800 && heroMentions == 0) {
          issues.add('第 $idx 章主角「$heroName」本章 0 次出场（正文 $finalWords 字）'
              '——写手可能换了 POV 人物；若本章本就是他人视角可忽略，'
              '但若连续多章如此则成书失去主角');
          task.addLog('  [WARN] 第 $idx 章主角「$heroName」0 次出场，'
              '已记入本章问题（书级体检会对连续消失判事故）');
        }
      }
      if (lostScenes.isNotEmpty) {
        issues.add('第 $idx 章 ${lostScenes.length}/${scenes.length} 个场景'
            '未产出正文（端点全链失败），本章内容残缺，'
            '标题与章纲可能对不上，建议重跑本章或人工补写');
        task.addLog('  [WARN] 第 $idx 章场景残缺 '
            '${scenes.length - lostScenes.length}/${scenes.length}，已记入本章问题');
      }


      // 8) 跨章状态提取：维护状态清单供下一章写作遵守（失败保留旧状态）
      if (task.config.useStateTrack) {
        final String st = await call(
          AiRole.verifier,
          verifierSystemPrompt,
          stateExtractPrompt(fullText, task.stateTrack),
        );
        if (st.trim().isNotEmpty) {
          task.stateTrack = st.trim();
          final int stLines = st.trim().split('\n').length;
          task.addLog('  [状态] 已更新跨章状态清单（$stLines 行）');
        } else {
          task.addLog('  [状态] 提取失败，保留旧状态');
        }
      }

      // 8.5) 回收清单打勾：必兑现清单逐条验收 → 未兑现定向补写 → ✅ 联动台账
      //
      // 【为什么补】Python 端闭环是「清单注入 → 写手 → 打勾 → 补写 → 台账联动」，
      // Dart 端此前**只有「台账注入」**（8.5 段），没有打勾与联动：
      // ① 写手是否真的兑现了伏笔，无人验收；② 台账 closed 完全依赖伏笔官
      // 二次提取，限流/截断下易失败——正文明明回收了伏笔、台账却仍 open，
      // 终审官会误判「伏笔悬空」。打勾 ✅ 直接联动 closed（证据句作回收凭证），
      // 台账不再依赖二次提取。
      //
      // 顺序上放在 8.5 段**之前**：打勾读的是「本章写作前的台账」，
      // 若先用伏笔官更新了台账，清单与本章的对应关系就乱了。
      List<PromiseCheck>? promiseChecks;
      final List<ForeshadowEntry> promiseBlock =
          task.ledger.promiseBlock(idx, maxPromises: 6, staleAfter: 5);
      if (task.config.usePromiseCheck && promiseBlock.isNotEmpty) {
        task.addLog('  [打勾] 本章必兑现清单 ${promiseBlock.length} 条：');
        for (int k = 0; k < promiseBlock.length; k++) {
          task.addLog('    ${k + 1}. ${promiseBlock[k].desc}');
        }
        final ({List<PromiseCheck> checks, bool ok}) vr = await _verifyPromises(
          task,
          fullText,
          idx,
          promiseBlock,
        );
        if (!vr.ok) {
          // 验收环节失败：正文可能没问题，是验收坏了。不触发补写、不联动台账，
          // 但必须留痕——否则这次失败对作者完全不可见。
          promiseChecks = <PromiseCheck>[PromiseCheck.failure];
          task.addLog('  [打勾] ☠ 校验调用失败，打勾未执行——请人工复核伏笔兑现');
          issues.add('第 $idx 章回收清单打勾未执行（验收调用失败），'
              '本章伏笔兑现情况需人工复核');
        } else {
          promiseChecks = vr.checks;
          for (final PromiseCheck r in vr.checks) {
            task.addLog('  [打勾] ${r.mark} 清单${r.id}：'
                '${r.evidence.length > 50 ? r.evidence.substring(0, 50) : r.evidence}');
          }
          final List<PromiseCheck> unfulfilled = vr.checks
              .where((PromiseCheck r) => !r.fulfilled)
              .toList();
          if (unfulfilled.isNotEmpty) {
            task.addLog('  [打勾] ${unfulfilled.length} 条未兑现，编辑链定向补写…');
            final String fix = await call(
              AiRole.editor,
              editorSystemPrompt,
              promiseRepairPrompt(
                fullText,
                unfulfilled
                    .map((PromiseCheck r) => UnfulfilledPromise(
                          desc: _promiseDescAt(promiseBlock, r.id),
                          reason: r.evidence,
                        ))
                    .where((UnfulfilledPromise e) => e.desc.isNotEmpty)
                    .toList(),
                idx,
                minWords: (_countWords(fullText) * factFixMinRatio).ceil(),
              ),
            );
            // 补写稿同样要过采纳闸：过不了就保留原文照记未兑现，
            // 否则「补了但被整份丢弃」会被记成「已兑现」。
            final String? why = fix.trim().isEmpty
                ? '空产出'
                : FanqieGateChecker.patchReject(
                    fix,
                    baseText: fullText,
                    genre: task.config.genre,
                    maxWords: (_countWords(fullText) * 2).ceil(),
                  );
            if (why != null) {
              task.addLog('  [打勾] 补写稿未过采纳闸（$why），保留原文照记未兑现');
              for (final PromiseCheck r in unfulfilled.take(3)) {
                issues.add('第 $idx 章伏笔未兑现（清单${r.id}）：${r.evidence}');
              }
            } else {
              final String repaired = '${fullText.trimRight()}\n\n${fix.trim()}';
              final ({List<PromiseCheck> checks, bool ok}) vr2 =
                  await _verifyPromises(task, repaired, idx, promiseBlock);
              if (vr2.ok && _fulfilledCount(vr2.checks) > _fulfilledCount(vr.checks)) {
                fullText = repaired;
                promiseChecks = vr2.checks;
                task.addLog('  [打勾] 复检兑现 '
                    '${_fulfilledCount(vr.checks)} → ${_fulfilledCount(vr2.checks)} 条，'
                    '采纳补写稿（${_countWords(repaired)} 字）');
              } else {
                task.addLog('  [打勾] 复检未改善'
                    '${vr2.ok ? '（仍 ${_fulfilledCount(vr2.checks)} 条）' : '（复检未跑成）'}、'
                    '回滚保留原文');
                for (final PromiseCheck r in unfulfilled.take(3)) {
                  issues.add('第 $idx 章伏笔未兑现（清单${r.id}，补写未改善）：'
                      '${r.evidence}');
                }
              }
            }
          }
          // 打勾 ✅ 联动台账（未兑现的条目不动，仍 open）。
          final (ForeshadowLedger next, int nClosed) =
              task.ledger.applyClosures(promiseBlock, promiseChecks, idx);
          if (nClosed > 0) {
            task.setLedger(next);
            task.addLog('  [打勾] $nClosed 条已联动标记 closed（证据句作回收凭证）');
          }
        }
      }

      // 8.5) 伏笔台账提取：记录新埋伏笔/标记回收（失败保留旧台账，不阻断）
      final String fs = await call(
        AiRole.verifier,
        verifierSystemPrompt,
        foreshadowExtractPrompt(fullText, task.foreshadowLedger, idx),
      );
      final Map<String, dynamic>? fsData = _parseJsonObject(fs);
      final List<dynamic>? fsList = fsData?['foreshadows'] as List<dynamic>?;
      if (fsData != null && fsList != null && fsList.isNotEmpty) {
        task.foreshadowLedger = jsonEncode(fsData);
        final ForeshadowLedger l = task.ledger;
        task.addLog('  [伏笔] 台账已更新'
            '（open ${l.open.length} / closed ${l.closed.length}）');
      } else {
        task.addLog('  [伏笔] 提取失败，保留旧台账');
      }

      // 8.6) 每 5 章检查超时未收伏笔（防长篇丢伏笔/改设定）
      if (idx % 5 == 0) {
        final List<ForeshadowEntry> stale =
            task.ledger.stale(idx, staleAfter: 5);
        if (stale.isNotEmpty) {
          task.addLog('  [伏笔] 超时未收告警：');
          for (final ForeshadowEntry e in stale) {
            task.addLog('    ⚠ 伏笔超时未收（已${e.age(idx)}章）：'
                '${e.desc}（埋于第${e.planted}章）');
          }
        } else {
          task.addLog('  [伏笔] 无超时未收伏笔 ✅');
        }
      }

      final PipelineChapter chapter = PipelineChapter(
        idx: idx,
        title: title,
        content: fullText,
        rawWords: rawWords,
        words: _countWords(fullText),
        issues: issues,
        scenesPlanned: scenes.length,
        scenesWritten: scenes.length - lostScenes.length,
        protagonistMentions: heroMentions,
        review: qualityReview,
        factCheck: factCheck,
        promiseChecks: promiseChecks,
      );
      task.chapters.add(chapter);
      task.chapters.sort((a, b) => a.idx.compareTo(b.idx));
      task.totalWords += chapter.words;

      task.addLog('  [完成] 第 $idx 章：${chapter.words} 字 | 累计 ${task.totalWords} 字');
      await _storage.saveTask(task);
      onProgress();
    }

    // ===== Phase 3.5：终审官通读级总评 + 打回重写权 =====
    //
    // 【为什么放在完成之后】终审看的是**全书**——节奏曲线是否有中期塌陷、
    // 人物弧光是否闭合、伏笔回收有无悬空、末章有没有给读者交代。这些维度
    // 单看任何一章都判断不了，而逐章评分看不到它们（逐章五维里没有它们）。
    // 此前 Dart 端只有本地规则分与逐章五分，通读级总评长期无人把守。
    //
    // 流程与 Python `Phase 3.5` 同构：终审 → 总分低于打回线则定向重写被点名的
    // 章（最多 chiefRewriteMax 章）→ 二审一轮 → **以二审为准**（重写后模型仍
    // 会如实给低分，不放水）。
    if (task.config.useChiefReview && task.chapters.isNotEmpty) {
      task.addLog('[终审] 通读级总评（六维 + 签约建议）…');
      ChiefReview chief = await _runChiefPass(
        task,
        task.chiefReviews.length + 1,
        isCancelled: isCancelled,
      );
      task.chiefReviews.add(chief);

      // 打回重写权：仅在终审真出结论（ok）且低于打回线时才动。
      // ok=false 时**绝不打回**——对着一个从未存在的低分改稿是纯破坏。
      if (chief.ok &&
          chief.overall < task.chiefRewriteThreshold &&
          chief.topIssues.isNotEmpty) {
        final String fixes = chief.fixPriority.take(3).join('；');
        final List<int> cited = <int>[];
        for (final ChiefIssue it in chief.topIssues) {
          if (it.chapter > 0 &&
              !cited.contains(it.chapter) &&
              task.chapters.any((PipelineChapter c) => c.idx == it.chapter)) {
            cited.add(it.chapter);
          }
          if (cited.length >= task.chiefRewriteMax) break;
        }
        if (cited.isNotEmpty) {
          task.addLog('  [打回] ${chief.overall} 分 < 打回线 '
              '${task.chiefRewriteThreshold}，打回重写第 ${cited.join("、")} 章');
          for (final int n in cited) {
            final int i = task.chapters
                .indexWhere((PipelineChapter c) => c.idx == n);
            final PipelineChapter target = task.chapters[i];
            final ChiefIssue issue = chief.topIssues.firstWhere(
              (ChiefIssue e) => e.chapter == n,
              orElse: () => const ChiefIssue(
                chapter: 0,
                issue: '',
                evidence: '',
              ),
            );
            final int oldWords = _countWords(target.content);
            final String rw = await call(
              AiRole.editor,
              editorSystemPrompt,
              chiefRewritePrompt(
                text: target.content,
                issue: issue.issue,
                evidence: issue.evidence,
                fixes: fixes,
              ),
            );
            // 采纳守卫：重写产出过不了闸就保留原文（过审/长度/补丁卫生），
            // 并**照记轨迹**——「打回过但没改成」比「没打回」更需要被看见。
            final String? why = rw.trim().isEmpty
                ? '空产出'
                : FanqieGateChecker.patchReject(
                    rw,
                    baseText: target.content,
                    genre: task.config.genre,
                    maxWords: (oldWords * 2).ceil(),
                  );
            final int newWords = _countWords(rw.trim());
            final int minWords = (oldWords * QualityRules.editorMinRatio).ceil();
            if (why == null && newWords >= minWords) {
              task.chapters[i] = PipelineChapter(
                idx: target.idx,
                title: target.title,
                content: rw.trim(),
                rawWords: oldWords,
                words: newWords,
                issues: <String>[
                  ...target.issues,
                  '终审打回重写：${issue.issue}',
                ],
                scenesPlanned: target.scenesPlanned,
                scenesWritten: target.scenesWritten,
                protagonistMentions: target.protagonistMentions,
                review: target.review,
                factCheck: target.factCheck,
                promiseChecks: target.promiseChecks,
              );
              task.totalWords += newWords - oldWords;
              task.chiefRewrites.add(ChiefRewriteRecord(
                chapterIdx: n,
                reason: issue.issue,
                oldWords: oldWords,
                newWords: newWords,
                applied: true,
              ));
              task.addLog('  [重写] 第 $n 章 $oldWords -> $newWords 字（已采纳）');
            } else {
              task.chiefRewrites.add(ChiefRewriteRecord(
                chapterIdx: n,
                reason: issue.issue,
                oldWords: oldWords,
                newWords: oldWords,
                applied: false,
              ));
              task.addLog('  [重写] 第 $n 章未过采纳闸'
                  '（${why ?? "压缩至 $newWords 字（<85%）"}），保留原文照记打回');
            }
          }
          await _storage.saveTask(task);
          // 二审：以重写后的书再终审一轮，重写后的结论才是最终结论。
          chief = await _runChiefPass(
            task,
            task.chiefReviews.length + 1,
            isCancelled: isCancelled,
          );
          task.chiefReviews.add(chief);
          task.addLog('  [打回] 二审完成，以第 ${chief.round} 轮为准'
              '（${chief.ok ? "${chief.overall} 分" : "无结论"}）');
        }
      }
      await _storage.saveTask(task);
    }

    // ===== Phase 3：完成 =====
    task.addLog('[流水线] 完成：${task.chapterCount} 章 / ${task.totalWords} 字');
    task.status = PipelineTaskStatus.done;
    task.finishedAt = DateTime.now();
    await _storage.saveTask(task);
  }

  /// 取消时的状态收尾。
  void _finishCancel(AiPipelineTask task) {
    task.status = PipelineTaskStatus.cancelled;
    task.finishedAt = DateTime.now();
    task.addLog('[流水线] 已取消');
  }

  /// 最后一章内容尾部（用于跨章承接）。
  String _lastChapterTail(AiPipelineTask task) {
    if (task.chapters.isEmpty) return '';
    final PipelineChapter last =
        task.chapters.reduce((a, b) => a.idx > b.idx ? a : b);
    return _tail(last.content, 200);
  }

  /// 取文本尾部 N 字符。
  String _tail(String text, int n) {
    if (text.length <= n) return text;
    return text.substring(text.length - n);
  }

  /// 字数统计（复用 AppConstants.countWords 的语义）。
  int _countWords(String text) {
    int count = 0;
    bool inAscii = false;
    for (final int code in text.codeUnits) {
      final int r = code;
      if ((r >= 0x4E00 && r <= 0x9FFF) || (r >= 0xF900 && r <= 0xFAFF)) {
        count++;
        inAscii = false;
      } else if (r >= 0x30 && r <= 0x39) {
        count++;
        inAscii = false;
      } else if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
        if (!inAscii) count++;
        inAscii = true;
      } else {
        inAscii = false;
      }
    }
    return count;
  }

  /// 从章纲里取钩子原文（本地兜底的唯一素材：规划官写的钩子，必然在题材内）。
  ///
  /// 与 Python 侧 `extract_chapter_hook` 同口径：钩子多写在 goal 里
  /// （`…｜钩子=威胁逼近：血煞盟的人影一闪而逝`），结构补章才带独立 hook 字段。
  static String _chapterHookHint(Map<String, dynamic> ch) {
    final String goal = outlineText(ch['goal']);
    final RegExpMatch? m =
        RegExp(r'钩子[=＝:：]\s*([^｜|]+)').firstMatch(goal);
    if (m != null) return m.group(1)!.trim();
    return outlineText(ch['hook']);
  }

  /// 零 LLM 钩子兜底：用章纲自带的钩子写死一句章末悬念，保证不掉钩、不跑题。
  ///
  /// 与 Python 侧 `local_hook_fallback` 同口径。LLM 补写被拒
  /// （指令残留/题材漂移/重复）或全模型不可用时，仍要留住追读命门。
  ///
  /// 【实测事故 2026-09-30】规划官的钩子**系统性**写成 `类型（说明）` 形式
  /// （`钩子=威胁逼近（周管事察觉异象，封铺捉贼）`，真机 5 章 5 中），
  /// 旧实现只按冒号切后半段，遇到括号时整段原样返回，于是
  /// 「威胁逼近（……）」这种**大纲标注**被拼进成书第 1 章末尾——
  /// 读者一眼判定机器产物，直接判废。故此处必须：
  ///   ① 括号/冒号两种切法都支持，剥掉 `威胁逼近` 这类类型词与外层括号；
  ///   ② 剥完仍带标注感的（残留 `＝`/`｜`/未闭合括号）直接放弃兜底，交由上层保留原文；
  ///   ③ 产出为纯叙事句，绝不把「说明」当正文。
  static String _localHookFallback(String hookHint, String protagonist, String genre) {
    String txt = hookHint.trim();
    if (txt.isEmpty) return '';

    // ① 先剥外层成对括号：取括号内说明（`威胁逼近（说明）` → `说明`）。
    //    规划官的类型词（威胁逼近/信息反转/选择困境/反常细节/承诺未兑）
    //    连同括号一起丢弃——它是大纲标签，不是叙事。
    //    尾部容许句末标点：真机存在 `（……只剩九十天）。` 这种右括号后带句号的写法，
    //    以 `$` 锚定的旧正则会整条失配 → 退回冒号切法 → 切在内层引号的冒号上，
    //    吐出「……'拔擢试上，你会死得很难看'，……）。」，尾部 `）` 漏进正文。
    final RegExpMatch? paren = RegExp(
      r'^[^(（]{0,12}[(（]([^()（）]*)[)）][。．.！!？?、，,；;：:\s]*$',
    ).firstMatch(txt);
    if (paren != null) {
      txt = paren.group(1)!.trim();
    } else {
      // ② 无括号时才退回冒号切法（兼容 `威胁逼近：说明` 写法）。
      final RegExpMatch? colon = RegExp(r'[：:]').firstMatch(txt);
      if (colon != null) txt = txt.substring(colon.end);
    }
    txt = txt.replaceAll(RegExp(r'^[（）()「」『』\s]+'), '')
        .replaceAll(RegExp(r'[（）()「」『』\s]+$'), '')
        .trim();
    if (txt.isEmpty) return '';

    // ③ 标注残留自检：仍带大纲分隔符或括号不闭合，说明这不是可用的叙事素材，
    //    与其把标注拼进正文，不如放弃兜底（上层会保留原文并记日志）。
    if (txt.contains('＝') || txt.contains('=') || txt.contains('｜') ||
        txt.contains('|') || RegExp(r'[（(]').hasMatch(txt)) {
      return '';
    }

    final String head = protagonist.trim().isNotEmpty ? protagonist.trim() : '他';
    const List<String> signals = <String>[
      '还没', '突然', '竟然', '不对劲', '盯着', '动静', '浮现', '逼近', '异动',
    ];
    // 剥离后仍可能以主角名开头（「宿峥必须在搜身之前藏住古钱」），此时直接补主语
    // 会读成「宿峥回头。宿峥必须……」，故只在不含主角名时才追加主语。
    String out = txt.contains(head) ? txt : '$head回头。$txt';
    // 补主语后若以引号起头（「回头。'你会死得很难看'」），会读成无主语引语，
    // 直接弃用这段素材——宁可章末无钩，也不拼出病句。
    if (out.isNotEmpty && "'\"“”‘’「」『』".contains(out[0])) return '';
    out = out.replaceAll(RegExp(r'[。！？]+$'), '');
    if (out.isEmpty) return '';
    out = '$out。';
    if (!signals.any(out.contains)) {
      // 保证章末有钩子信号（与 PipelineQa.hasEndingHook 的词表对齐）
      out = '${out.replaceAll(RegExp(r'。$'), '')}——他还没看清那是什么。';
    }
    return out;
  }
}
