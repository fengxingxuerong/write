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
  }) async {
    try {
      final String raw = await _callLlm(
        chapterOutline: chapterOutline,
        chapterTargetWords: chapterTargetWords,
        genre: genre,
        tone: tone,
        prevSceneSummary: prevSceneSummary,
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
  }) {
    final StringBuffer b = StringBuffer();
    b.writeln('请把下面的章纲拆成 3~5 个场景，每个场景完成「起承转合」中的一段。');
    b.writeln('整章总目标字数：$chapterTargetWords 字。高潮/战斗/反转场景多分一些，');
    b.writeln('过场少分一些，每场景控制在 400~1000 字。');
    b.writeln();
    b.writeln('题材：$genre | 基调：$tone');
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
        goal: '危机爆发或局势反转',
        beats: const <String>['反转危机', '情绪顶点'],
        targetWords: per,
      ),
      ScenePlan(
        index: 3,
        stage: '合',
        goal: '收束本幕，留出钩子',
        beats: const <String>['余波收尾', '悬念钩子'],
        targetWords: per,
      ),
    ];
  }
}
