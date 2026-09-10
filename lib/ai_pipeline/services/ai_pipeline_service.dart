import 'dart:convert';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/prompts/pipeline_prompts.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/llm_chat_client.dart';

/// 多模型协作长篇小说流水线（Dart 原生编排）。
///
/// 流程：
/// 1. 总规划官规划全书大纲（JSON）；
/// 2. 逐章：规划官拆场景 → 写手逐场景生成 → 编辑去AI味润色 →
///    标题官提炼章名 → 每 5 章审校官一致性校验 → 本地质检；
/// 3. 断点续传：每章完成后原子落盘，中断后可从下一章继续。
///
/// 网络层复用 [LlmChatClient]（OpenAI 兼容非流式，支持 enable_thinking）。
class AiPipelineService {
  /// 构造服务。
  AiPipelineService(this._storage);

  final PipelineStorage _storage;

  /// 当前任务（run 期间有效）。
  AiPipelineTask? _task;

  /// 各角色客户端缓存（按角色名）。
  final Map<String, LlmChatClient> _clients = <String, LlmChatClient>{};

  /// 获取任务的某角色客户端。
  LlmChatClient _clientFor(AiRoleConfig cfg) {
    return _clients.putIfAbsent(
      cfg.role.name,
      () => LlmChatClient(config: cfg.llm),
    );
  }

  /// 调用某角色模型（带 429/5xx 指数退避重试）。失败返回空串。
  Future<String> _call(
    AiRole role,
    String system,
    String user, {
    double? temperature,
  }) async {
    final AiPipelineTask task = _task!;
    final AiRoleConfig cfg = task.config.roleOf(role);
    if (!cfg.enabled) return '';
    if (!cfg.llm.isConfigured) {
      task.addLog('  [配置] ${role.label} 未配置模型，跳过');
      return '';
    }
    final LlmChatClient client = _clientFor(cfg);
    for (int attempt = 0; attempt <= 2; attempt++) {
      try {
        final LlmChatResult r = await client.chat(
          system,
          user,
          temperature: temperature ?? cfg.llm.temperature,
        );
        final String content = r.content.trim();
        if (content.isNotEmpty) return content;
        task.addLog('  [空响应] ${role.label}（${cfg.llm.model}）');
        return '';
      } on EngineException catch (e) {
        final String msg = e.toString();
        final bool retriable = msg.contains('429') ||
            msg.contains('500') ||
            msg.contains('502') ||
            msg.contains('503');
        if (retriable && attempt < 2) {
          final int wait = (3 * (attempt + 1)) * 5 + 3;
          task.addLog('  [重试 ${attempt + 1}/3] ${role.label} $msg（等 ${wait}s）');
          await Future<void>.delayed(Duration(seconds: wait));
          continue;
        }
        task.addLog('  [HTTP] ${role.label} ${cfg.llm.model}: $msg');
        return '';
      } catch (e) {
        if (attempt < 2) {
          task.addLog('  [重试 ${attempt + 1}/3] ${role.label}: ${e.toString().substring(0, 80)}');
          await Future<void>.delayed(Duration(seconds: (3 * (attempt + 1)) * 3));
          continue;
        }
        task.addLog('  [错误] ${role.label}: ${e.toString().substring(0, 120)}');
        return '';
      }
    }
    return '';
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
  static List<AiRole> missingRoles(AiPipelineConfig config) {
    return AiRole.values
        .where((AiRole r) {
          final AiRoleConfig cfg = config.roleOf(r);
          if (r == AiRole.writer) return !cfg.llm.isConfigured;
          if (r == AiRole.planner) return !cfg.llm.isConfigured;
          if (r == AiRole.editor) {
            return config.useEditor && !cfg.llm.isConfigured;
          }
          if (r == AiRole.titler) return !cfg.llm.isConfigured;
          if (r == AiRole.verifier) {
            return config.useVerifier && !cfg.llm.isConfigured;
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
      for (int attempt = 0; attempt < 2; attempt++) {
        final String raw = await _call(
          AiRole.planner,
          plannerSystemPrompt,
          scenePlanningPrompt(
            goal,
            lastSummary,
            state: task.config.useStateTrack ? task.stateTrack : '',
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
      int rawWords = w;
      if (task.config.useEditor) {
        final String edited = await _call(
          AiRole.editor,
          editorSystemPrompt,
          editorPrompt(fullText),
        );
        if (edited.isNotEmpty) {
          final int wEdited = _countWords(edited);
          task.addLog('  [编辑] 润色完成 $w -> $wEdited 字');
          fullText = edited;
        } else {
          task.addLog('  [编辑] 润色失败，保留原文');
        }
      }

      // 3.5) 章末钩子兜底：结尾 200 字无钩子信号词时，补写钩子句（保追读）
      if (fullText.trim().isNotEmpty && !PipelineQa.hasEndingHook(fullText)) {
        task.addLog('  [钩子] 章末缺钩，自动补写钩子...');
        final String add = await _call(
          AiRole.writer,
          writerSystemPrompt,
          '下面是本章结尾，最后 1~2 句太平淡，没有留下让读者必须看下一章的悬念。'
          '请接着补写 30~80 字的钩子句（悬念/变故/威胁逼近/秘密将揭，按${task.config.genre}题材），'
          '不新增情节、不改变已发生的事，只把结尾收在悬念上。只输出补写内容：\n\n${_tail(fullText, 300)}',
        );
        if (add.trim().length > 8) {
          fullText = '${fullText.trimRight()}\n\n${add.trim()}';
          task.addLog('  [钩子] 已补写钩子');
        } else {
          task.addLog('  [钩子] 补写失败，保留原文');
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
}
