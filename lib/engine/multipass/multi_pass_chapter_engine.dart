import 'dart:async';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/llm_context_brief.dart';
import 'package:novel_writer/engine/llm_engine.dart';
import 'package:novel_writer/engine/llm_http_errors.dart';
import 'package:novel_writer/engine/llm_retry.dart';
import 'package:novel_writer/engine/multipass/scene_builder.dart';
import 'package:novel_writer/engine/multipass/scene_plan.dart';
import 'package:novel_writer/engine/writing_guidelines.dart';
import 'package:novel_writer/models/character.dart';
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
      storyContext: LlmContextBrief.contextBlock(chapterConfig, ctx),
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
        sceneCount: scenes.length,
        cancelToken: cancelToken,
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

      prevSummary = LlmContextBrief.sceneHandoff(sceneText, tailChars: 120);
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

    // 外显爽点补修（跨章断供口径，与 Python `novel_pipeline` 7.56 同构）：
    // 场景拼装后整章一次性判定——断供是**跨章**形态，单场景看不出来。
    // 旧情绪闸门只有「双低」（💥<0.5 且 ✨<1.0），而 ✨ 含蓄异动恒高使双低几乎
    // 永不成立；此处用 needsPayoffRepair 双通道（单章双低 + 断供带），
    // 采纳走 acceptPayoffRepair（字数区间 + 角色名完整 + 必须真补上外显兑现），
    // 任一不过即保留原文，绝不劣化。
    final int droughtLen =
        PipelineQa.trailingDroughtLen(ctx.payoffHistory);
    final String why = droughtLen >= 3 ? '跨章断供 $droughtLen 章' : '单章双低';
    if (content.isNotEmpty &&
        PipelineQa.needsPayoffRepair(
          thrill: PipelineQa.thrillPerThousand(content),
          surge: PipelineQa.surgePerThousand(content),
          side: PipelineQa.sideReactionPerThousand(content),
          minWordsOk: AppConstants.countWords(content) >=
              (chapterConfig.targetWords * 0.5).round(),
          droughtLen: droughtLen,
        )) {
      onProgress?.call(GenerationProgress(
        charsWritten: totalWords,
        targetWords: chapterConfig.targetWords,
        stage: '外显爽点补修（$why）…',
        previewText: content,
      ));
      final String? fixed = await _repairPayoff(
        content,
        chapterConfig,
        droughtLen: droughtLen,
        cancelToken: cancelToken,
      );
      if (fixed != null) {
        return GenerationResult(
          content: fixed,
          actualWords: AppConstants.countWords(fixed),
          usedConfig: chapterConfig,
        );
      }
    }

    return GenerationResult(
      content: content,
      actualWords: AppConstants.countWords(content),
      usedConfig: chapterConfig,
    );
  }

  /// 外显爽点情绪强化：整章改写一次，验收通过才返回新正文，否则返回 null。
  ///
  /// 与 Python `payoff_repair_prompt` / `accept_payoff_repair` 同口径。
  /// 失败、空产出、未过验收一律返回 null——调用方保留原文，不阻塞生成。
  Future<String?> _repairPayoff(
    String content,
    GenerationConfig chapterConfig, {
    required int droughtLen,
    CancelToken? cancelToken,
  }) async {
    final LlmEngine engine =
        LlmEngine(config: config, chatRetry: const RetryPolicy(maxAttempts: 1));
    String out;
    try {
      out = await engine.generateSingle(
        systemPrompt: WritingGuidelines.systemPrompt,
        userMessage: PipelineQa.payoffRepairPrompt(
          content,
          droughtLen: droughtLen,
          characters: const <Character>[],
        ),
        targetWords: AppConstants.countWords(content),
      );
    } catch (_) {
      return null; // 补修失败不阻塞：保原文。
    } finally {
      engine.dispose();
    }
    final String fix = out.trim();
    if (fix.isEmpty) return null;
    final (bool ok, String why) = PipelineQa.acceptPayoffRepair(content, fix);
    return ok ? fix : null;
  }

  /// 生成单个场景。失败不抛异常（由调用方统计），但会把错误带回去。
  Future<({String text, Object? error})> _generateScene({
    required ScenePlan scene,
    required GenerationConfig chapterConfig,
    required ContextBundle ctx,
    required String prevSummary,
    required int sceneIndex,
    required int sceneCount,
    CancelToken? cancelToken,
  }) async {
    final String prompt = _buildScenePrompt(
      scene: scene,
      chapterConfig: chapterConfig,
      ctx: ctx,
      prevSummary: prevSummary,
      sceneIndex: sceneIndex,
      sceneCount: sceneCount,
    );
    // 复用引擎实例（连接池化 + 重试时保持连接）。
    // chatRetry 关闭客户端层重试：本层 RetryPolicy 已负责退避，
    // 避免两层叠乘成 3×3=9 次加倍等待。
    final LlmEngine engine = LlmEngine(
      config: config,
      chatRetry: const RetryPolicy(maxAttempts: 1),
    );

    // 退避交给统一的 RetryPolicy：以前这里自己写了一套 2s/4s/8s，
    // 既不看 Retry-After，也不能注入 sleep 做测试。
    final RetryPolicy policy = RetryPolicy(
      maxAttempts: _maxSceneRetries + 1,
      baseBackoff: const Duration(milliseconds: _baseBackoffMs),
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
        // 退避等 2s/4s 期间用户取消 → 立即中断，不白等。
        isCancelled: () => cancelToken?.isCancelled ?? false,
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

  /// 判断错误是否可重试：限流/5xx 传输错误，或模型返回空内容。
  ///
  /// 用异常类型而非字符串嗅探——之前 `msg.contains('500')` 会把
  /// "第 500 章" 之类的正文误判成服务端错误。
  bool _isRetryableError(Object e) {
    if (LlmHttpErrors.retryable(e)) return true;
    return e is EngineException && e.message.contains('空内容');
  }


  /// 每场景最大重试次数。
  static const int _maxSceneRetries = 2;

  /// 基础退避毫秒（2s → 4s → 8s 指数增长）。
  static const int _baseBackoffMs = 2000;

  /// 外显爽点场景的识别键：规划层 goal 里出现任一即视为爽点场景。
  static const List<String> payoffSceneKeys = <String>[
    '外显爽点', '打脸', '当众',
  ];

  /// 本场景是否承担「外显爽点」职责（关键词 **或** 位置双通道判定）。
  ///
  /// 与 Python `novel_pipeline.is_payoff_scene` 同口径。为什么不能只靠关键词：
  /// 规划 prompt 把 goal 限死「20字内」，模型倾向写「局势逆转，危机爆发」这类
  /// 不含爽点词的文案（实测 14 本成书 108 章里仅 16 章 goal 含爽点键），
  /// 关键词通道因此几乎不可用；规划失败走 [SceneBuilder] 的兜底骨架时更是
  /// 必然不命中。位置通道利用「爽点放章内后半段 + 起承转合」的既有结构事实
  /// 兜底，使「每章至少一个外显爽点场景」不再依赖模型是否恰好用了那三个词。
  static bool isPayoffScene(String goal, String stage, int index, int total) {
    for (final String k in payoffSceneKeys) {
      if (goal.contains(k)) return true;
    }
    if (total <= 0) return false;
    // 后半段（进度 >= 55%）且 stage 为「转」——起承转合的第三拍
    return stage == '转' && (index + 1) / total >= 0.55;
  }

  /// 写手「外显爽点」硬约束文案（与 Python `payoff_scene_constraint` 同文）。
  static const String payoffSceneConstraint =
      '【本场景硬约束·外显爽点】这是外显爽点场景：必须写出对手/旁观者的'
      '当众外部反应（脸色骤变、失态、惊呼、修为显化、围观哗然），'
      '禁止只写主角内心感受或含蓄暗示。';

  String _buildScenePrompt({
    required ScenePlan scene,
    required GenerationConfig chapterConfig,
    required ContextBundle ctx,
    required String prevSummary,
    required int sceneIndex,
    required int sceneCount,
  }) {
    final StringBuffer b = StringBuffer();
    b.writeln('这是本章第 ${sceneIndex + 1} 个场景（${scene.stage}）。');
    b.writeln('本场景目标字数：${scene.targetWords} 字。');
    b.writeln('本场景任务：${scene.goal}');
    // 外显爽点硬约束：关键词命中 **或** 位置兜底（后半段「转」）时强制注入。
    // 与 Python `novel_pipeline` 两处写手调用点同口径——此前本文件完全没有
    // 这道约束，桌面端写手收不到「必须写外部可见反应」的要求。
    if (isPayoffScene(scene.goal, scene.stage, sceneIndex, sceneCount)) {
      b.writeln(payoffSceneConstraint);
    }
    if (scene.beats.isNotEmpty) {
      b.writeln('必须完成的节拍：${scene.beats.join(' → ')}');
    }
    if (prevSummary.isNotEmpty) {
      b.writeln();
      b.writeln('上一场景的情境（请承接，不要矛盾）：');
      b.writeln(prevSummary);
    }
    b.write(LlmContextBrief.contextBlock(
      chapterConfig,
      ctx,
      includeContinuation: prevSummary.trim().isEmpty,
    ));
    b.writeln('【题材】${chapterConfig.genre}');
    b.writeln('【基调】${chapterConfig.tone}');
    if (chapterConfig.protagonistName?.trim().isNotEmpty == true) {
      b.writeln('【主角名】${chapterConfig.protagonistName}');
    }
    b.writeln('【写作风格】${chapterConfig.style.instruction}');
    b.writeln('【文风】${chapterConfig.proseStyle.instruction}');
    if (ctx.outline.trim().isNotEmpty) {
      b.writeln('【整章大纲（仅作背景，本次只完成当前场景节拍）】');
      b.writeln(ctx.outline.trim());
    }
    if (sceneIndex == 0) {
      b.writeln(WritingGuidelines.structureRequirements);
    }
    b.writeln('只推进当前场景，不提前完成后续场景或重复已发生的事件。');
    b.write(WritingGuidelines.genreGuidance(chapterConfig.genre));
    if (scene.isEnding) {
      b.writeln();
      b.writeln('这是本章最后一个场景：结尾必须落在未落地的钩子上'
          '（悬念/变故/威胁逼近/秘密将揭），禁止平稳收尾，让读者必须看下一章。');
    }
    b.writeln();
    b.writeln('只输出场景正文：');
    return b.toString();
  }
}
