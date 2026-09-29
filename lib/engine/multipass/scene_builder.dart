import 'dart:convert';

import 'package:novel_writer/engine/llm_chat_client.dart';
import 'package:novel_writer/engine/writing_guidelines.dart';
import 'package:novel_writer/models/llm_config.dart';

import 'scene_plan.dart';

/// 章纲 → 场景列表 的规划器。
///
/// 做两件事：
/// 1. 把章纲拆成 3~5 个「各有结构目标的」场景（起承转合）
/// 2. 为每个场景分配字数（总目标按场景「轻重」分配，高潮段给更多）
///
/// 失败时回退到 [_fallback]：按均分 + 固定起承转合硬编码拆解，
/// 保证主流程不阻塞。
class SceneBuilder {
  /// 构造。
  const SceneBuilder({required this.config});

  /// LLM 配置。
  final LlmConfig config;

  /// 规划出口：给章纲返回场景列表。
  Future<List<ScenePlan>> build(
    String chapterOutline, {
    required int chapterTargetWords,
    required String genre,
    required String tone,
    String? prevSceneSummary,
    String storyContext = '',
  }) async {
    try {
      final String raw = await _callLlm(
        chapterOutline: chapterOutline,
        chapterTargetWords: chapterTargetWords,
        genre: genre,
        tone: tone,
        prevSceneSummary: prevSceneSummary,
        storyContext: storyContext,
      );
      return _parseResponse(raw, chapterTargetWords);
    } catch (_) {
      return _fallback(chapterTargetWords);
    }
  }

  Future<String> _callLlm({
    required String chapterOutline,
    required int chapterTargetWords,
    required String genre,
    required String tone,
    String? prevSceneSummary,
    required String storyContext,
  }) async {
    final LlmChatClient client = LlmChatClient(config: config);
    final LlmChatResult res = await client.chat(
      '${WritingGuidelines.writerPersona}\n你擅长长篇小说结构，'
      '能把一段章纲拆解成有序场景组合。',
      _buildPlanningPrompt(
        chapterOutline: chapterOutline,
        chapterTargetWords: chapterTargetWords,
        genre: genre,
        tone: tone,
        prevSceneSummary: prevSceneSummary,
        storyContext: storyContext,
      ),
    );
    return res.content;
  }

  String _buildPlanningPrompt({
    required String chapterOutline,
    required int chapterTargetWords,
    required String genre,
    required String tone,
    String? prevSceneSummary,
    required String storyContext,
  }) {
    final StringBuffer b = StringBuffer();
    b.writeln('请把下面的章纲拆成 3~5 个场景，每个场景完成「起承转合」中的一段。');
    b.writeln('整章总目标字数：$chapterTargetWords 字。高潮/战斗/反转场景多分一些，');
    b.writeln('过场少分一些，每场景控制在 400~1000 字。');
    b.writeln();
    b.writeln('【规划要求】');
    b.writeln('- 本章至少安排 1 个爽点场景（打脸/升级/收获/秘密揭露四选一），放在后半段；');
    // 与 Python `scene_planning_prompt` 同口径：goal 被限死 20 字内时模型倾向写
    // 「局势逆转，危机爆发」这类不含爽点关键词的文案，写手侧按关键词触发的
    // 外显爽点硬约束因此收不到（实测 108 章仅 16 章 goal 含爽点键）。
    b.writeln('- 该爽点场景的 goal 必须以「外显爽点：」开头（写手按此关键词触发'
        '「必须写出外部可见反应」的硬约束）；');
    b.writeln('- 最后一个场景必须是「合」：收束本章并埋下章末钩子（未落地悬念）。');
    b.writeln();
    b.writeln('题材：$genre | 基调：$tone');
    if (storyContext.trim().isNotEmpty) {
      b.writeln('【故事上下文（规划不得与既有事实矛盾）】');
      b.writeln(storyContext.trim());
    }
    if (prevSceneSummary != null && prevSceneSummary.trim().isNotEmpty) {
      b.writeln();
      b.writeln('上一场景摘要（本场景必须承接此情境）：');
      b.writeln(prevSceneSummary.trim());
    }
    b.writeln();
    b.writeln('【章纲】');
    b.writeln(chapterOutline.trim());
    b.writeln();
    b.writeln('请严格输出 JSON，不要 Markdown 包裹，格式：');
    b.writeln('{"scenes": [{"index":0,"stage":"起","goal":"...",'
        '"beats":["节拍1"],"targetWords":600}, ...]}');
    return b.toString();
  }

  List<ScenePlan> _parseResponse(String raw, int fallbackTotal) {
    String cleaned = raw.trim();
    if (cleaned.startsWith('```')) {
      cleaned = cleaned.replaceAll(RegExp(r'^```(?:json)?\s*'), '');
      cleaned = cleaned.replaceAll(RegExp(r'\s*```$'), '');
    }
    final int start = cleaned.indexOf('{');
    final int end = cleaned.lastIndexOf('}');
    if (start < 0 || end <= start) return _fallback(fallbackTotal);
    cleaned = cleaned.substring(start, end + 1);
    final Map<String, dynamic> json =
        jsonDecode(cleaned) as Map<String, dynamic>;
    final List<dynamic> arr = json['scenes'] as List<dynamic>? ?? <dynamic>[];
    if (arr.isEmpty) return _fallback(fallbackTotal);
    return arr
        .map((dynamic e) => ScenePlan.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  List<ScenePlan> _fallback(int chapterTargetWords) {
    final int per = (chapterTargetWords / 4).round().clamp(300, 1200);
    return <ScenePlan>[
      ScenePlan(
        index: 0,
        stage: '起',
        goal: '锚定本幕时间地点人物，建立基调',
        beats: const <String>['环境开场', '人物登场', '初始状态'],
        targetWords: per,
      ),
      ScenePlan(
        index: 1,
        stage: '承',
        goal: '推进情节，释放关键信息',
        beats: const <String>['冲突升级', '信息揭露', '内心活动'],
        targetWords: per,
      ),
      ScenePlan(
        index: 2,
        stage: '转',
        // 与 Python `fallback_scenes` 同口径：「转」场景定为外显爽点场景
        // （位置天然落在后半段，与「爽点放章内后半段」准则一致）。此前兜底
        // 骨架一个爽点场景都没有，规划链失败时 💥 通道必然断供。
        goal: '外显爽点：局势逆转，当众打脸或收获到手',
        beats: const <String>['反转危机', '情绪顶点'],
        targetWords: per,
      ),
      ScenePlan(
        index: 3,
        stage: '合',
        goal: '收束本幕，留下章末钩子（悬念/变故/未落地威胁）',
        beats: const <String>['余波收尾', '章末钩子强制'],
        targetWords: per,
      ),
    ];
  }
}
