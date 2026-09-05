import 'dart:async';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/llm_engine.dart';
import 'package:novel_writer/engine/multipass/scene_builder.dart';
import 'package:novel_writer/engine/multipass/scene_plan.dart';
import 'package:novel_writer/engine/writing_guidelines.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 单章多 pass 引擎：把章拆成多个「场景」，每场景独立生成。
///
/// 相比单 pass 生成长文本：
/// 1. 每场景 400~800 字 → 模型维持高文学水准不崩坏
/// 2. 场景间通过「上一场景摘要」维持情节连贯
/// 3. 高潮段分配更多 token → 战斗/反转更丰满
class MultiPassChapterEngine {
  /// 构造。
  const MultiPassChapterEngine({
    required this.config,
    required this.sceneBuilder,
  });

  /// LLM 配置。
  final LlmConfig config;

  /// 场景规划器。
  final SceneBuilder sceneBuilder;

  /// 入口：生成完整一章。
  Future<GenerationResult> generate(
    GenerationConfig chapterConfig,
    ContextBundle ctx, {
    CancelToken? cancelToken,
    void Function(GenerationProgress)? onProgress,
  }) async {
    // Step 1: 规划场景列表
    final List<ScenePlan> scenes = await sceneBuilder.build(
      ctx.outline,
      chapterTargetWords: chapterConfig.targetWords,
      genre: chapterConfig.genre,
      tone: chapterConfig.tone,
      prevSceneSummary:
          ctx.plotSummary.isNotEmpty ? ctx.plotSummary : null,
    );

    // Step 2: 逐场景生成
    final StringBuffer fullText = StringBuffer();
    String prevSummary = '';
    int totalWords = 0;

    for (int i = 0; i < scenes.length; i++) {
      if (cancelToken?.isCancelled == true) break;

      final ScenePlan scene = scenes[i];
      onProgress?.call(GenerationProgress(
        charsWritten: totalWords,
        targetWords: chapterConfig.targetWords,
        stage: '第 ${i + 1}/${scenes.length} 场景（${scene.stage}）：${scene.goal}',
        previewText: fullText.toString(),
      ));

      final String sceneText = await _generateScene(
        scene: scene,
        chapterConfig: chapterConfig,
        ctx: ctx,
        prevSummary: prevSummary,
        sceneIndex: i,
      );

      if (sceneText.trim().isNotEmpty) {
        if (fullText.isNotEmpty) fullText.write('\n\n');
        fullText.write(sceneText.trim());
        totalWords = AppConstants.countWords(fullText.toString());
      }

      prevSummary = _summarizeScene(sceneText, 120);
      if (totalWords >= chapterConfig.targetWords) break;
    }

    final String content = fullText.toString().trim();
    return GenerationResult(
      content: content,
      actualWords: AppConstants.countWords(content),
      usedConfig: chapterConfig,
    );
  }

  Future<String> _generateScene({
    required ScenePlan scene,
    required GenerationConfig chapterConfig,
    required ContextBundle ctx,
    required String prevSummary,
    required int sceneIndex,
  }) async {
    final String prompt = _buildScenePrompt(
      scene: scene,
      chapterConfig: chapterConfig,
      ctx: ctx,
      prevSummary: prevSummary,
      sceneIndex: sceneIndex,
    );
    // 复用引擎实例（连接池化 + 重试时保持连接）
    final LlmEngine engine = LlmEngine(config: config);

    Object? lastError;
    for (int attempt = 0; attempt <= _maxSceneRetries; attempt++) {
      try {
        final String text = await engine.generateSingle(
          systemPrompt: WritingGuidelines.systemPrompt,
          userMessage: prompt,
          targetWords: scene.targetWords,
        );
        if (text.trim().isNotEmpty) return text;
        // 空响应视为失败
        lastError = const EngineException('AI 返回空内容');
      } catch (e) {
        lastError = e;
        // 判断是否为可重试错误
        if (!_isRetryableError(e) || attempt == _maxSceneRetries) break;
        // 指数退避 + 抖动（2s, 4s, 8s...）
        final backoff = _baseBackoffMs * (1 << attempt) + _randomJitterMs();
        await Future<void>.delayed(Duration(milliseconds: backoff));
      }
    }
    // 全部重试失败：返回空（不阻塞整章生成）
    return '';
  }

  /// 判断错误是否可重试（网络超时 / 限流 / 服务端错误）。
  bool _isRetryableError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('429') ||
        msg.contains('500') ||
        msg.contains('502') ||
        msg.contains('503') ||
        msg.contains('504') ||
        msg.contains('timeout') ||
        msg.contains('connection');
  }

  int _randomJitterMs() => (DateTime.now().microsecondsSinceEpoch % 1000);

  /// 每场景最大重试次数。
  static const int _maxSceneRetries = 2;

  /// 基础退避毫秒（2s → 4s → 8s 指数增长）。
  static const int _baseBackoffMs = 2000;

  String _buildScenePrompt({
    required ScenePlan scene,
    required GenerationConfig chapterConfig,
    required ContextBundle ctx,
    required String prevSummary,
    required int sceneIndex,
  }) {
    final StringBuffer b = StringBuffer();
    b.writeln('这是本章第 ${sceneIndex + 1} 个场景（${scene.stage}）。');
    b.writeln('本场景目标字数：${scene.targetWords} 字。');
    b.writeln('本场景任务：${scene.goal}');
    if (scene.beats.isNotEmpty) {
      b.writeln('必须完成的节拍：${scene.beats.join(' → ')}');
    }
    if (prevSummary.isNotEmpty) {
      b.writeln();
      b.writeln('上一场景的情境（请承接，不要矛盾）：');
      b.writeln(prevSummary);
    }
    if (ctx.characters.isNotEmpty) {
      b.writeln();
      b.writeln('【角色】');
      for (final c in ctx.characters) {
        b.writeln('- ${c.name}：${c.traits}');
      }
    }
    if (sceneIndex == 0) {
      b.writeln();
      b.writeln(WritingGuidelines.structureRequirements);
      b.writeln();
      b.write(WritingGuidelines.genreGuidance(chapterConfig.genre));
    }
    b.writeln();
    b.writeln('只输出场景正文：');
    return b.toString();
  }

  String _summarizeScene(String text, int tailChars) {
    if (text.length <= tailChars) return text;
    return text.substring(text.length - tailChars);
  }
}
