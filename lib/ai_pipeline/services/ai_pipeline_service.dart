import 'dart:convert';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/prompts/pipeline_prompts.dart';
import 'package:novel_writer/ai_pipeline/services/llm_router.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/engine/quality/fanqie_gate_checker.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 多模型协作长篇小说流水线（Dart 原生编排）。
///
/// 流程：
/// 1. 总规划官规划全书大纲（JSON）；
/// 2. 逐章：规划官拆场景 → 写手逐场景生成 → 编辑去AI味润色 →
///    标题官提炼章名 → 每 5 章审校官一致性校验 → 本地质检；
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

  /// 当前任务（run 期间有效）。
  AiPipelineTask? _task;

  /// 链上是否至少一个端点已配置（主或任一备用）。
  static bool _chainConfigured(AiRoleConfig cfg) =>
      cfg.chain.any((LlmConfig c) => c.isConfigured);

  /// 调用某角色模型（链式 failover：冷却跳过/失败/空响应自动切下一个可用端点）。
  /// 链上全部失败返回空串。统一在任务日志里记录 `[角色]` 前缀的路由过程。
  Future<String> _call(
    AiRole role,
    String system,
    String user, {
    double? temperature,
  }) async {
    final AiPipelineTask task = _task!;
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
    );
    final String content = result.content.trim();
    if (content.isEmpty) {
      task.addLog('  [空响应] ${role.label}（${cfg.llm.model}）');
    }
    return content;
  }

  /// 检查超时未回收伏笔：埋设超过 staleAfter 章仍未回收的伏笔，返回告警列表。
  List<String> _checkOpenForeshadows(String ledgerJson, int curIdx, {int staleAfter = 5}) {
    if (ledgerJson.trim().isEmpty || ledgerJson.trim() == '[]') return <String>[];
    try {
      final dynamic decoded = jsonDecode(ledgerJson);
      final List<dynamic> items = decoded is Map<String, dynamic>
          ? (decoded['foreshadows'] as List<dynamic>? ?? <dynamic>[])
          : (decoded is List<dynamic> ? decoded : <dynamic>[]);
      final List<String> warns = <String>[];
      for (final dynamic it in items) {
        if (it is! Map<String, dynamic>) continue;
        if (it['status'] == 'open' && it['recovered'] == null) {
          final int planted = (it['planted'] as num?)?.toInt() ?? curIdx;
          final int age = curIdx - planted;
          if (age >= staleAfter) {
            warns.add('⚠ 伏笔超时未收（已$age章）：${it['desc'] ?? '?'}（埋于第$planted章）');
          }
        }
      }
      return warns;
    } catch (_) {
      return <String>[];
    }
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
  Future<void> run(
    AiPipelineTask task, {
    required bool Function() isCancelled,
    required void Function() onProgress,
  }) async {
    _task = task;
    task.status = PipelineTaskStatus.running;
    task.error = null;
    task.finishedAt = null;
    await _storage.saveTask(task);
    task.addLog('[流水线] 启动：目标 ${task.config.totalWords} 字');

    // ===== Phase 1：总规划官规划全书大纲 =====
    if (task.outline.isEmpty) {
      task.addLog('[规划官] 规划全书大纲...');
      final String raw = await _call(
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

      final String goal = (ch['goal'] as String?) ?? '';
      final int target = (ch['target'] as num?)?.toInt() ?? 3000;
      final String lastSummary = _lastChapterTail(task);
      task.addLog('===== 第 $idx 章（目标 $target 字）：$goal =====');

      // 1) 场景规划（重试 2 次 → 默认骨架兜底），注入跨章状态
      List<Map<String, dynamic>> scenes = <Map<String, dynamic>>[];
      // 全书世界观（规划官设定）注入场景规划，防止正文脱离大纲（裴照系统流→赵铁柱超自然流 事故）
      final Map<String, dynamic> outlineMap = task.outline as Map<String, dynamic>? ?? <String, dynamic>{};
      final String worldHint = (outlineMap['world'] as String?) ?? '';
      final String hookHint = (outlineMap['hook'] as String?) ?? '';
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
            .where((dynamic e) => e['status'] == 'open' && (e['desc'] as String? ?? '').isNotEmpty)
            .take(8)
            .map((dynamic e) => '- ${e['desc']}')
            .toList();
        if (fsOpen.isNotEmpty) {
          final String fsSummary = '【未收伏笔（写作时勿改相关设定，尽量自然推进/回收）】\n${fsOpen.join('\n')}';
          stateInject = stateInject.isNotEmpty ? '$stateInject\n\n$fsSummary' : fsSummary;
        }
      } catch (_) {}
      for (int attempt = 0; attempt < 2; attempt++) {
        final String raw = await _call(
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
      String prevText = lastSummary;
      for (int si = 0; si < scenes.length; si++) {
        final Map<String, dynamic> sc = scenes[si];
        final String stage = (sc['stage'] as String?) ?? '承';
        final String goalS = (sc['goal'] as String?) ?? '';
        final List<String> beats = ((sc['beats'] as List<dynamic>?) ?? <dynamic>[])
            .map((dynamic e) => e.toString())
            .toList();
        final int tw = ((sc['targetWords'] as num?)?.toInt() ?? 600).clamp(300, 1500);
        task.addLog('  [场景 ${si + 1}/${scenes.length}] $stage：$goalS（目标 $tw 字）');
        String text = await _call(
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
        }
        // 字数不足补充续写
        if (w > 50 && w < tw * 0.4) {
          final String add = await _call(
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
        final String add = await _call(
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
      // 字数下限守卫（与 Python 端 EDITOR_MIN_RATIO=0.85 同步）：fulltest 实测编辑链
      // 曾把 3805 字章润色成 1921 字砍半，过度压缩视为无效产出，保留原文并告警
      int rawWords = w;
      if (task.config.useEditor) {
        final String edited = await _call(
          AiRole.editor,
          editorSystemPrompt,
          editorPrompt(fullText),
        );
        if (edited.isNotEmpty) {
          final int wEdited = _countWords(edited);
          if (wEdited >= w * 0.85) {
            task.addLog('  [编辑] 润色完成 $w -> $wEdited 字');
            fullText = edited;
          } else {
            task.addLog('  [编辑] ⚠ 润色产出 $w -> $wEdited 字，过度压缩（<85%），拒绝采纳保留原文');
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
        final String add = await _call(
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
          if (fallback.isNotEmpty) {
            fullText = '${fullText.trimRight()}\n\n$fallback';
            task.addLog('  [钩子] 本地兜底：'
                '${fallback.length > 40 ? fallback.substring(0, 40) : fallback}');
          } else {
            task.addLog('  [钩子] 无可用兜底素材，保留原文');
          }
        }
      }

      // 4) 章节标题（标题官）
      String title = (ch['title'] as String?) ?? '第$idx章';
      final String t = await _call(
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
      if (task.config.useVerifier && idx % 5 == 0 && task.chapters.isNotEmpty) {
        final String chapList = task.chapters
            .where((PipelineChapter c) => c.idx >= idx - 4)
            .map((PipelineChapter c) => '第${c.idx}章《${c.title}》')
            .join('\n');
        final String v = await _call(
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
        final String qr = await _call(
          AiRole.verifier,
          verifierSystemPrompt,
          qualityReviewPrompt(fullText),
        );
        final Map<String, dynamic>? parsed = _parseJsonObject(qr);
        final Map<String, dynamic>? scores =
            parsed?['scores'] as Map<String, dynamic>?;
        final int overall = (parsed?['overall'] as num?)?.toInt() ?? -1;
        if (overall >= 0) {
          final String comment = (parsed?['comment'] as String?) ?? '';
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
            final String rewritten = await _call(
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
              task.addLog('  [重写] 第 $idx 章 $w 字 -> $wNew 字');
              fullText = rewritten.trim();
              w = wNew;
              // 低分告警替换为「已重写」记录。
              issues.removeWhere((String e) => e.contains('语义质量评分'));
              issues.add('第 $idx 章 质量评分 $overall 分（<${task.config.rewriteThreshold}），已自动重写');
            } else {
              task.addLog('  [重写] 第 $idx 章 重写失败，保留原文');
            }
          }
        } else {
          task.addLog('  [评分] 第 $idx 章 评分解析失败，跳过（不影响生成）');
        }
      }

      final PipelineChapter chapter = PipelineChapter(
        idx: idx,
        title: title,
        content: fullText,
        rawWords: rawWords,
        words: _countWords(fullText),
        issues: issues,
      );
      task.chapters.add(chapter);
      task.chapters.sort((a, b) => a.idx.compareTo(b.idx));
      task.totalWords += chapter.words;

      // 8) 跨章状态提取：维护状态清单供下一章写作遵守（失败保留旧状态）
      if (task.config.useStateTrack) {
        final String st = await _call(
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

      // 8.5) 伏笔台账提取：记录新埋伏笔/标记回收（失败保留旧台账，不阻断）
      final String fs = await _call(
        AiRole.verifier,
        verifierSystemPrompt,
        foreshadowExtractPrompt(fullText, task.foreshadowLedger, idx),
      );
      final Map<String, dynamic>? fsData = _parseJsonObject(fs);
      final List<dynamic>? fsList = fsData?['foreshadows'] as List<dynamic>?;
      if (fsData != null && fsList != null && fsList.isNotEmpty) {
        task.foreshadowLedger = jsonEncode(fsData);
        final int nOpen = fsList.whereType<Map<String, dynamic>>().where((dynamic e) => e['status'] == 'open').length;
        final int nClosed = fsList.whereType<Map<String, dynamic>>().where((dynamic e) => e['status'] == 'closed').length;
        task.addLog('  [伏笔] 台账已更新（open $nOpen / closed $nClosed）');
      } else {
        task.addLog('  [伏笔] 提取失败，保留旧台账');
      }

      // 8.6) 每 5 章检查超时未收伏笔（防长篇丢伏笔/改设定）
      if (idx % 5 == 0) {
        final List<String> fsWarns = _checkOpenForeshadows(task.foreshadowLedger, idx, staleAfter: 5);
        if (fsWarns.isNotEmpty) {
          task.addLog('  [伏笔] 超时未收告警：');
          for (final String w in fsWarns) {
            task.addLog('    $w');
          }
        } else {
          task.addLog('  [伏笔] 无超时未收伏笔 ✅');
        }
      }

      task.addLog('  [完成] 第 $idx 章：${chapter.words} 字 | 累计 ${task.totalWords} 字');
      await _storage.saveTask(task);
      onProgress();
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
    final String goal = (ch['goal'] as String?) ?? '';
    final RegExpMatch? m =
        RegExp(r'钩子[=＝:：]\s*([^｜|]+)').firstMatch(goal);
    if (m != null) return m.group(1)!.trim();
    return (ch['hook'] as String?)?.trim() ?? '';
  }

  /// 零 LLM 钩子兜底：用章纲自带的钩子写死一句章末悬念，保证不掉钩、不跑题。
  ///
  /// 与 Python 侧 `local_hook_fallback` 同口径。LLM 补写被拒
  /// （指令残留/题材漂移/重复）或全模型不可用时，仍要留住追读命门。
  static String _localHookFallback(String hookHint, String protagonist, String genre) {
    String txt = hookHint.trim();
    if (txt.isEmpty) return '';
    final RegExpMatch? colon = RegExp(r'[：:]').firstMatch(txt);
    if (colon != null) txt = txt.substring(colon.end);
    txt = txt.replaceAll(RegExp(r'^[（）()「」『』\s]+'), '').trim();
    if (txt.isEmpty) return '';
    final String head = protagonist.isNotEmpty ? protagonist : '他';
    const List<String> signals = <String>[
      '还没', '突然', '竟然', '不对劲', '盯着', '动静', '浮现', '逼近', '异动',
    ];
    String out;
    if (txt.contains(head)) {
      out = txt;
    } else {
      out = '$head回头。${txt.replaceAll(RegExp(r'。$'), '')}。';
    }
    if (!signals.any(out.contains)) {
      // 保证章末有钩子信号（与 PipelineQa.hasEndingHook 的词表对齐）
      out = '${out.replaceAll(RegExp(r'。$'), '')}——他还没看清那是什么。';
    }
    return out;
  }
}
