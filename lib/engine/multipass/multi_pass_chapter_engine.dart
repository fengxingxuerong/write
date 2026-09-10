import 'dart:async';
import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/llm_engine.dart';
import 'package:novel_writer/engine/llm_retry.dart';
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
  ///
  /// [retrySleep] 仅供测试注入（把退避等待换成空操作）。
  const MultiPassChapterEngine({
    required this.config,
    required this.sceneBuilder,
    this.retrySleep,
  });

  /// 退避等待实现（null = 真等）。
  final Sleeper? retrySleep;

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
    int failedScenes = 0;
    Object? lastSceneError;

    for (int i = 0; i < scenes.length; i++) {
      if (cancelToken?.isCancelled == true) break;

      final ScenePlan scene = scenes[i];
      onProgress?.call(GenerationProgress(
        charsWritten: totalWords,
        targetWords: chapterConfig.targetWords,
        stage: '第 ${i + 1}/${scenes.length} 场景（${scene.stage}）：${scene.goal}',
        previewText: fullText.toString(),
      ));

      final ({String text, Object? error}) sceneResult = await _generateScene(
        scene: scene,
        chapterConfig: chapterConfig,
        ctx: ctx,
        prevSummary: prevSummary,
        sceneIndex: i,
      );
      final String sceneText = sceneResult.text;

      if (sceneText.trim().isNotEmpty) {
        if (fullText.isNotEmpty) fullText.write('\n\n');
        fullText.write(sceneText.trim());
        totalWords = AppConstants.countWords(fullText.toString());
      } else if (sceneResult.error != null) {
        failedScenes++;
        lastSceneError ??= sceneResult.error;
      }

      prevSummary = _summarizeScene(sceneText, 120);
      if (totalWords >= chapterConfig.targetWords) break;
    }

    // 一个场景都没写出来：这不是「短」，是挂了。别吐一个空章节给 UI 当好结果。
    final String content = fullText.toString().trim();
    if (content.isEmpty && failedScenes > 0) {
      throw EngineException(
        'AI 场景生成全部失败（$failedScenes 个场景）：$lastSceneError',
        lastSceneError,
      );
    }
    if (failedScenes > 0) {
      onProgress?.call(GenerationProgress(
        charsWritten: totalWords,
        targetWords: chapterConfig.targetWords,
        stage: '已生成（$failedScenes 个场景因「$lastSceneError」缺席，可重跑本章）',
        previewText: content,
      ));
    }

    return GenerationResult(
      content: content,
      actualWords: AppConstants.countWords(content),
      usedConfig: chapterConfig,
    );
  }

  /// 生成单个场景。失败不抛异常（由调用方统计），但会把错误带回去。
  Future<({String text, Object? error})> _generateScene({
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

    // 退避交给统一的 RetryPolicy：以前这里自己写了一套 2s/4s/8s，
    // 既不看 Retry-After，也不能注入 sleep 做测试。
    final RetryPolicy policy = RetryPolicy(
      maxAttempts: _maxSceneRetries + 1,
      baseBackoff: Duration(milliseconds: _baseBackoffMs),
      sleep: retrySleep ?? _delayed,
    );
    try {
      final String text = await policy.run(
        (int attempt) async {
          final String out = await engine.generateSingle(
            systemPrompt: WritingGuidelines.systemPrompt,
            userMessage: prompt,
            targetWords: scene.targetWords,
          );
          // 空响应也算失败，要重试。
          if (out.trim().isEmpty) {
            throw const EngineException('AI 返回空内容');
          }
          return out;
        },
        isRetryable: _isRetryableError,
      );
      return (text: text, error: null);
    } catch (e) {
      return (text: '', error: e);
    } finally {
      engine.dispose();
    }
  }

  /// 默认等待（真退避）。
  static Future<void> _delayed(Duration d) => Future<void>.delayed(d);

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
    if (scene.isEnding) {
      b.writeln();
      b.writeln('这是本章最后一个场景：结尾必须落在未落地的钩子上'
          '（悬念/变故/威胁逼近/秘密将揭），禁止平稳收尾，让读者必须看下一章。');
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
