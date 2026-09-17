import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/llm_chat_client.dart';
import 'package:novel_writer/engine/llm_http_errors.dart';
import 'package:novel_writer/engine/llm_retry.dart';
import 'package:novel_writer/engine/quality/token_tier.dart';
import 'package:novel_writer/engine/writing_guidelines.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/llm_config.dart';

/// LLM 驱动的生成引擎（可插拔 [GenerationEngine] 实现）。
///
/// 支持两种后端（由 [LlmConfig.provider] 决定）：
/// - [LlmProvider.openaiCompatible]：OpenAI 兼容 chat/completions API
///   （DeepSeek / Moonshot / 通义千问 / 本地 vLLM 等）；
/// - [LlmProvider.ollama]：本地 Ollama `/api/chat`。
///
/// 提示词采用 **system / user 双消息**：system 注入作家人设、核心写作
/// 技法与反 AI 腔自查清单（[WritingGuidelines.systemPrompt]），user 只传
/// 本章「章节简报」（设定 + 承接 + 大纲 + 结构要求），使模型专注于
/// 「怎么写」而非重复解析设定。
///
/// 使用 `dart:io` 的 [HttpClient]（SDK 自带，**不引入任何网络库依赖**），
/// 保持项目零 pub 网络依赖的约束。支持取消（强制断开连接）与进度回报
/// （token 流）。
///
/// **深度优化**：
/// - HttpClient 实例复用：连接池化，避免每次请求重建 TCP/TLS 连接。
/// - 分级自动重试：429/500/502/503 指数退避重试，最多 2 次。
/// - 错误分类：网络超时 / 认证失败 / 限流 / 服务端错误，给出友好错误描述。
/// - 资源保证释放：finally 块确保 client 关闭与 subscription 取消。
class LlmEngine implements GenerationEngine {
  /// 构造引擎。
  ///
  /// [maxRetries] / [baseBackoffMs] 控制限流退避；[sleep] 仅测试用。
  LlmEngine({
    required this.config,
    this.timeout = const Duration(minutes: 5),
    this.maxRetries = 2,
    this.baseBackoffMs = 2000,
    Sleeper? sleep,
    this.clientFactory,
  })  : sleep = sleep ?? _delayed,
        assert(maxRetries >= 0, 'maxRetries 不能为负');

  /// LLM 连接配置。
  final LlmConfig config;

  /// 单次请求超时。
  final Duration timeout;

  /// 最大重试次数（限流/服务端错误）。
  final int maxRetries;

  /// 基础退避毫秒（指数退避基数）。
  final int baseBackoffMs;

  /// 等待实现（测试可注入，避免真等几秒）。
  final Sleeper sleep;

  /// HttpClient 工厂（测试可注入）。
  final HttpClient Function()? clientFactory;

  static Future<void> _delayed(Duration d) => Future<void>.delayed(d);

  /// OpenAI 兼容 chat/completions 端点。
  static const String _chatPath = '/chat/completions';

  /// Ollama chat 端点。
  static const String _ollamaChatPath = '/api/chat';

  /// 共享 HttpClient（连接池化；跨请求复用 TCP/TLS 连接）。
  HttpClient? _sharedClient;

  @override
  Future<GenerationResult> generate(
    GenerationConfig config,
    ContextBundle ctx, {
    CancelToken? cancelToken,
    void Function(GenerationProgress)? onProgress,
  }) async {
    if (!this.config.isConfigured) {
      throw const EngineException('LLM 未配置：请先在设置页填写模型与地址');
    }
    // 深度优化：复用共享 HttpClient（连接池化）。使用后不关闭，留给下一次请求复用。
    final HttpClient client = _obtainClient();

    // 大纲扩写：把用户填的章节大纲扩写成结构化场景序列，
    // 让正文生成模型不必自己脑补结构（2B 模型尤其受益）。
    // 失败/超时回退原始大纲，不阻塞生成。
    final String rawOutline = ctx.outline.trim();
    if (config.expandOutline &&
        rawOutline.isNotEmpty &&
        !(cancelToken?.isCancelled ?? false)) {
      final String expanded =
          await _tryExpandOutline(config, ctx, rawOutline);
      if (expanded.isNotEmpty) {
        ctx = ctx.copyWith(outline: expanded);
      }
    }

    // 取消时：强制断开底层连接（取消后连接不可复用，清空让下次重建）。
    cancelToken?.onCancel = () {
      try {
        _sharedClient?.close(force: true);
        _sharedClient = null;
      } catch (_) {
        // 连接已关闭。
      }
    };

    final Completer<GenerationResult> completer = Completer<GenerationResult>();
    String content = '';
    int total = 0;
    // thinking 链收集器：把 reasoning_content 透传到后续结果，
    // 便于 UI 调试展示思考过程；不参与正文拼接。
    final List<String> reasoningTokens = <String>[];

    // 建连与状态校验（429/5xx 在这里退避重来）。
    // 注意：一旦开始收流就不再重试——半章内容重发会变成两段重复正文。
    final HttpClientResponse response =
        await _openWithRetry(client, config, ctx, cancelToken, onProgress);

    // 流式读取响应，逐 token 拼接并回报进度。
    // 注意顺序：先按行切分（String），再逐行解析。
    final Stream<String> lines =
        response.transform(utf8.decoder).transform(const LineSplitter());
    final StreamSubscription<String> sub = lines.listen(
      (String line) {
        if (line.trim().isEmpty) return;
        final String? delta = _extractDelta(line, reasoningSink: reasoningTokens);
        if (delta != null && delta.isNotEmpty) {
          content += delta;
          total += delta.length;
          onProgress?.call(GenerationProgress(
            charsWritten: total,
            targetWords: config.targetWords,
            stage: 'AI 写作中（${AppConstants.countWords(content)} 字）…',
            previewText: content,
          ));
        }
      },
      onError: (Object e) {
        if (cancelToken?.isCancelled ?? false) {
          if (!completer.isCompleted) {
            completer.completeError(const GenerationCancelledException());
          }
        } else if (!completer.isCompleted) {
          completer.completeError(_classifyError(e));
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          final String trimmed = content.trim();
          completer.complete(GenerationResult(
            content: trimmed,
            actualWords: AppConstants.countWords(trimmed),
            usedConfig: config,
            reasoningTokens: reasoningTokens,
          ));
        }
      },
    );

    try {
      return await completer.future;
    } finally {
      await sub.cancel();
      // 不关闭共享 client：它会被下一次请求复用，由 dispose() 统一释放。
    }
  }

  /// 获取或初始化共享 HttpClient；连接池化减少 TCP/TLS 握手。
  HttpClient _obtainClient() {
    _sharedClient ??= (clientFactory ?? HttpClient.new)()
        ..connectionTimeout = const Duration(seconds: 8)
        ..idleTimeout = const Duration(seconds: 30);
    return _sharedClient!;
  }

  /// 建连 + 发送 + 状态校验，带限流退避重试。
  ///
  /// 返回尚未消费的响应流；调用方一旦开始读正文，就不能再重试了。
  Future<HttpClientResponse> _openWithRetry(
    HttpClient client,
    GenerationConfig genConfig,
    ContextBundle ctx,
    CancelToken? cancelToken,
    void Function(GenerationProgress)? onProgress,
  ) {
    final RetryPolicy policy = RetryPolicy(
      maxAttempts: maxRetries + 1,
      baseBackoff: Duration(milliseconds: baseBackoffMs),
      sleep: sleep,
    );
    return policy.run(
      (int attempt) async {
        final HttpClientRequest request;
        try {
          request = await _createRequest(client, genConfig, ctx);
        } catch (e) {
          // 请求创建失败时连接可能已损坏，清空让下次重建。
          _sharedClient?.close(force: true);
          _sharedClient = null;
          throw LlmHttpErrors.transport(e);
        }
        final HttpClientResponse response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final String body = await response.transform(utf8.decoder).join();
          // 非 2xx 时关闭共享 client：连接可能已损坏，下次会重新创建。
          _sharedClient?.close(force: true);
          _sharedClient = null;
          throw LlmHttpErrors.fromStatus(
            response.statusCode,
            body,
            retryAfterHeader:
                response.headers.value(HttpHeaders.retryAfterHeader),
          );
        }
        return response;
      },
      isRetryable: (Object e) =>
          !(cancelToken?.isCancelled ?? false) && LlmHttpErrors.retryable(e),
      onRetry: (int attempt, Duration delay, Object error) {
        onProgress?.call(GenerationProgress(
          charsWritten: 0,
          targetWords: genConfig.targetWords,
          stage: 'AI 服务繁忙，${delay.inSeconds}s 后重试（第 ${attempt + 1} 次）…',
        ));
      },
    );
  }

  /// 分类错误，返回对作者友好的错误描述。
  EngineException _classifyError(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('timeout') || msg.contains('time out')) {
      return const EngineException('AI 请求超时，请稍后重试或检查网络连接');
    }
    if (msg.contains('certificate') || msg.contains('tls') || msg.contains('ssl')) {
      return const EngineException('TLS 证书验证失败，请检查 API 地址是否正确');
    }
    if (msg.contains('401') || msg.contains('unauthorized')) {
      return const EngineException('API 密钥无效（401），请在设置页检查 API Key');
    }
    if (msg.contains('403') || msg.contains('forbidden')) {
      return const EngineException('访问被拒绝（403），请检查 API Key 权限');
    }
    if (msg.contains('429') || msg.contains('rate limit')) {
      return const EngineException('请求频率过高（429），请稍后再试');
    }
    if (msg.contains('500') || msg.contains('502') || msg.contains('503')) {
      return EngineException('AI 服务暂时不可用（${e.toString().split(' ').first}），请稍后重试', e);
    }
    return EngineException('LLM 服务异常：$e', e);
  }

  /// 释放共享 HTTP 连接（在引擎生命周期结束时调用）。
  void dispose() {
    _sharedClient?.close(force: true);
    _sharedClient = null;
  }

  /// 扩写结果最长字符数：超出会挤压正文 token 预算，回退原大纲。
  static const int kMaxOutlineExpandedChars = 3000;

  /// 大纲扩写：把 [rawOutline]（章节大纲或卷纲要点）交给 LLM 扩写成
  /// 结构化场景序列（每个场景含地点/人物/事件/情绪走向/建议字数）。
  ///
  /// 返回扩写后的文本；失败/超时/未配置/结果过长返回空串（调用方回退原大纲）。
  Future<String> _tryExpandOutline(
    GenerationConfig genConfig,
    ContextBundle ctx,
    String rawOutline,
  ) async {
    try {
      final StringBuffer sys = StringBuffer();
      sys.writeln('你是一名资深小说编剧，擅长把大纲扩写成可执行的场景序列。');
      sys.writeln('任务：把下面这章的大纲扩写成 3~6 个场景，每个场景：');
      sys.writeln('- 场景名（一句话概括）');
      sys.writeln('- 地点与出场人物');
      sys.writeln('- 核心事件（推进情节的关键动作/对话/冲突）');
      sys.writeln('- 情绪走向（紧张/舒缓/转折/悬念…）');
      sys.writeln('- 建议字数（占总字数的比例或具体字数）');
      sys.writeln('要求：');
      sys.writeln('- 只输出场景序列文本，不要输出其他内容、不要 Markdown 代码块；');
      sys.writeln('- 每个场景用一行“场景 N：”开头，内容用“- ”分点；');
      sys.writeln('- 场景之间必须有因果推进，结尾留钩子；');
      sys.writeln('- 结合题材与基调，不要引入与原大纲无关的新支线。');

      final StringBuffer user = StringBuffer();
      user.writeln('【题材】${genConfig.genre}');
      user.writeln('【基调】${genConfig.tone}');
      user.writeln('【目标字数】约 ${genConfig.targetWords} 字');
      if (genConfig.protagonistName != null &&
          genConfig.protagonistName!.isNotEmpty) {
        user.writeln('【主角】${genConfig.protagonistName}');
      }
      if (ctx.characters.isNotEmpty) {
        user.writeln('【主要角色】');
        for (final c in ctx.characters) {
          user.writeln('- ${c.name}（${c.role}）：${c.traits}');
        }
      }
      if (ctx.plotSummary.trim().isNotEmpty) {
        user.writeln('【前情提要】');
        user.writeln(ctx.plotSummary.trim());
      }
      user.writeln();
      user.writeln('【本章大纲】');
      user.writeln(rawOutline.trim());
      user.writeln();
      user.writeln('请扩写成场景序列：');

      final LlmChatClient client = LlmChatClient(
        config: config,
        timeout: const Duration(seconds: 30),
      );
      final LlmChatResult res = await client
          .chat(sys.toString(), user.toString())
          .timeout(const Duration(seconds: 30), onTimeout: () {
        throw const EngineException('大纲扩写超时');
      });
      final String expanded = res.content.trim();
      // 过长 → 回退：避免挤压正文 token 预算。
      if (expanded.length > kMaxOutlineExpandedChars) return '';
      return expanded.length > rawOutline.length ? expanded : '';
    } catch (_) {
      // 扩写失败不阻塞生成：回退原始大纲。
      return '';
    }
  }

  /// 创建请求：OpenAI 兼容或 Ollama。
  Future<HttpClientRequest> _createRequest(
    HttpClient client,
    GenerationConfig genConfig,
    ContextBundle ctx,
  ) async {
    final Uri uri = _endpoint();
    final HttpClientRequest request = await client.postUrl(uri);
    request.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set(HttpHeaders.acceptHeader, 'application/json');
    if (config.provider == LlmProvider.openaiCompatible &&
        config.apiKey.trim().isNotEmpty) {
      request.headers.set(
          HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
    }
    request.add(utf8.encode(jsonEncode(_payload(genConfig, ctx))));
    return request;
  }

  /// 单场景简易生成（供 [MultiPassChapterEngine] 逐场景调用）。
  ///
  /// 入参直接是 system 与 user 字符串（不再依赖 [GenerationConfig] /
  /// [ContextBundle] 的章节简报拼装），返回生成好的纯文本。
  /// 失败**抛出异常**：原来这里把错误吞成空串，上层只能「静默少写一段」，
  /// 作者看到的是一章莫名其妙的短稿，而不是「哪一步挂了」。
  Future<String> generateSingle({
    required String systemPrompt,
    required String userMessage,
    required int targetWords,
  }) async {
    if (!config.isConfigured) {
      throw const EngineException('LLM 未配置：请先在设置页填写模型与地址');
    }
    // 按目标字数推 token 预算：以前不传，场景长度全靠模型自觉。
    final TokenTier tier = TokenTier.fromModel(config.model);
    final int budget = TokenBudget.calculate(
      targetWords: targetWords,
      tier: tier,
      maxTokens: config.maxTokens,
    );
    final LlmChatResult res = await _llmClient.chat(
      systemPrompt,
      userMessage,
      maxTokens: budget,
    );
    return _llmClient.stripThinkingFromContent(res.content).trim();
  }

  /// 复用 [LlmChatClient] 单例（避免每场景重建 HTTP 连接）。
  LlmChatClient? _client;

  LlmChatClient get _llmClient => _client ??= LlmChatClient(config: config);

  /// 拼接完整请求体（system + user 双消息）。
  Map<String, dynamic> _payload(GenerationConfig genConfig, ContextBundle ctx) {
    final List<Map<String, String>> messages = <Map<String, String>>[
      <String, String>{
        'role': 'system',
        'content': WritingGuidelines.systemPrompt,
      },
      <String, String>{
        'role': 'user',
        'content': _buildChapterBrief(genConfig, ctx),
      },
    ];
    // 按目标字数推算最大 token：中文 1 字≈1.5 token，留 15% 余量；
    // 推理等级倍率由 TokenTier 统一管理。
    final TokenTier tier = TokenTier.fromModel(config.model);
    final int tokenBudget = TokenBudget.calculate(
      targetWords: genConfig.targetWords,
      tier: tier,
      maxTokens: config.maxTokens,
    );

    if (config.provider == LlmProvider.ollama) {
      return <String, dynamic>{
        'model': config.model,
        'messages': messages,
        'stream': true,
        'options': <String, dynamic>{
          'temperature': config.temperature,
          'num_predict': tokenBudget,
        },
      };
    }
    // OpenAI 兼容 API 一律发送 enable_thinking: false（对标准模型无害，对推理模型有效）
    final Map<String, dynamic> payload = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      'stream': true,
      'max_tokens': tokenBudget,
      'temperature': config.temperature,
      'chat_template_kwargs': <String, dynamic>{'enable_thinking': false},
    };
    // 部分推理模型（如 SensNova）需要额外的 options.Thinking: false
    if (TokenBudget.needsExtraThinkingFlag(config)) {
      payload['options'] = <String, dynamic>{'Thinking': false};
    }
    return payload;
  }

  /// 构建 LLM 端点 URI。
  Uri _endpoint() {
    final String base = config.baseUrl.trim();
    final String normalized = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    final String path = config.provider == LlmProvider.ollama
        ? _ollamaChatPath
        : _chatPath;
    return Uri.parse('$normalized$path');
  }

  /// 从 SSE 行提取增量文本。
  ///
  /// - OpenAI 兼容：`data: {json}`，json 含 `choices[0].delta.content`；
  ///   `data: [DONE]` 结束。`choices[0].delta.reasoning_content` 为隐藏思考链，
  ///   不混入正文，但可通过 [reasoningSink] 送到调试/观察端（如 UI 思考过程面板）。
  /// - Ollama：`{json}`，json 含 `message.content`，`done:true` 结束。
  ///
  /// 返回 null 表示「本行无正文增量」（token 为 thinking 或无效行）。
  String? _extractDelta(String line, {List<String>? reasoningSink}) {
    final String trimmed = line.trim();
    if (trimmed.startsWith('data:')) {
      final String data = trimmed.substring(5).trim();
      if (data == '[DONE]') return null;
      try {
        final Map<String, dynamic> json =
            jsonDecode(data) as Map<String, dynamic>;
        final List<dynamic> choices = json['choices'] as List<dynamic>? ?? const [];
        if (choices.isEmpty) return null;
        final Map<String, dynamic> delta =
            (choices.first as Map<String, dynamic>)['delta']
                as Map<String, dynamic>? ??
            const <String, dynamic>{};
        // reasoning_content → 送到调试 sink，不返回为正文
        final String? reasoning = delta['reasoning_content'] as String?;
        if (reasoning != null && reasoning.isNotEmpty && reasoningSink != null) {
          reasoningSink.add(reasoning);
        }
        return delta['content'] as String?;
      } catch (_) {
        return null; // 跳过无法解析的 SSE 行。
      }
    }
    // Ollama 行：{json}。
    try {
      final Map<String, dynamic> json = jsonDecode(trimmed) as Map<String, dynamic>;
      final Map<String, dynamic>? message = json['message'] as Map<String, dynamic>?;
      return message?['content'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// 组装章节简报（user 消息）。
  ///
  /// 作家人设与写作技法已由 system 消息承载（[WritingGuidelines.systemPrompt]），
  /// 此处只提供本章所需的设定、承接与大纲，并在末尾追加结构要求。
  String _buildChapterBrief(GenerationConfig genConfig, ContextBundle ctx) {
    final StringBuffer b = StringBuffer();

    b.writeln('请根据以下设定，创作一段连贯的中文小说正文。');
    b.writeln();
    b.writeln('【要求】');
    b.writeln('- 目标字数约 ${genConfig.targetWords} 字，控制在 '
        '${genConfig.constraints.maxWordsPerChapter} 字以内；');
    b.writeln('- 保持设定一致，不出现前后矛盾；');
    if (ctx.characters.any((c) => c.dialogueStyle.isNotEmpty)) {
      b.writeln('- 角色的对话必须严格贴合其「说话风格」，不要所有人一个腔调。');
    }
    b.writeln();
    b.writeln('【写作风格】');
    b.writeln(genConfig.style.instruction);
    b.writeln();
    b.writeln('【文风】');
    b.writeln(genConfig.proseStyle.instruction);
    b.writeln();
    b.writeln('【题材】${genConfig.genre}');
    b.writeln('【基调】${genConfig.tone}');
    if (genConfig.protagonistName != null && genConfig.protagonistName!.isNotEmpty) {
      b.writeln('【主角名】${genConfig.protagonistName}');
    }

    if (ctx.characters.isNotEmpty) {
      b.writeln();
      b.writeln('【已有角色】');
      for (final c in ctx.characters) {
        b.writeln('- ${c.name}（${c.role}）：${c.traits}');
        if (c.background.isNotEmpty) b.writeln('  背景：${c.background}');
        if (c.dialogueStyle.isNotEmpty) {
          b.writeln('  说话风格：${c.dialogueStyle}');
        }
      }
    }
    if (ctx.worldSettings.isNotEmpty) {
      b.writeln();
      b.writeln('【世界观设定】');
      for (final w in ctx.worldSettings) {
        b.writeln('- ${w.title}（${w.category}）：${w.content}');
      }
    }
    if (genConfig.continuation != null && genConfig.continuation!.isNotEmpty) {
      b.writeln();
      b.writeln('【上一章结尾（请承接此情节继续，不要复述）】');
      b.writeln(genConfig.continuation);
    }
    if (ctx.plotSummary.trim().isNotEmpty) {
      b.writeln();
      b.writeln('【前情提要（最近的剧情进展，保持伏笔与人物弧光一致）】');
      b.writeln(ctx.plotSummary.trim());
    }
    if (ctx.foreshadowing.trim().isNotEmpty) {
      b.writeln();
      b.writeln('【伏笔账本（未回收的伏笔，按埋设顺序）】');
      b.writeln(ctx.foreshadowing.trim());
      b.writeln('- 若本章大纲与某条伏笔相关，应自然推进或回收该伏笔；');
      b.writeln('- 其余伏笔不得与之矛盾，也不要强行提前回收；');
      b.writeln('- 本章埋设的新悬念须清晰可追踪，不要随手弃坑。');
    }
    if (ctx.outline.trim().isNotEmpty) {
      b.writeln();
      b.writeln('【本章大纲（按此顺序推进）】');
      b.writeln(ctx.outline.trim());
    }
    // 题材专用提示：玄幻 / 言情 / 悬疑 等不同题材侧重点不同。
    final String genreNote = WritingGuidelines.genreGuidance(genConfig.genre);
    if (genreNote.isNotEmpty) {
      b.writeln();
      b.write(genreNote);
    }
    b.writeln();
    b.write(WritingGuidelines.structureRequirements);

    return b.toString();
  }
}
