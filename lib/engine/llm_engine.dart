import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/llm_chat_client.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/llm_config.dart';

/// LLM 驱动的生成引擎（可插拔 [GenerationEngine] 实现）。
///
/// 支持两种后端（由 [LlmConfig.provider] 决定）：
/// - [LlmProvider.openaiCompatible]：OpenAI 兼容 chat/completions API
///   （DeepSeek / Moonshot / 通义千问 / 本地 vLLM 等）；
/// - [LlmProvider.ollama]：本地 Ollama `/api/chat`。
///
/// 使用 `dart:io` 的 [HttpClient]（SDK 自带，**不引入任何网络库依赖**），
/// 保持项目零 pub 网络依赖的约束。支持取消（关闭连接）与进度回报（token 流）。
class LlmEngine implements GenerationEngine {
  /// 构造引擎。
  LlmEngine({required this.config, this.timeout = const Duration(minutes: 5)});

  /// LLM 连接配置。
  final LlmConfig config;

  /// 单次请求超时。
  final Duration timeout;

  /// OpenAI 兼容 chat/completions 端点。
  static const String _chatPath = '/chat/completions';

  /// Ollama chat 端点。
  static const String _ollamaChatPath = '/api/chat';

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
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);

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

    final HttpClientRequest request;
    try {
      request = await _createRequest(client, config, ctx);
    } catch (e) {
      client.close(force: true);
      throw EngineException('无法连接 LLM 服务：$e', e);
    }

    // 取消：关闭请求连接，流读取将抛异常。
    cancelToken?.onCancel = () {
      try {
        request.close();
      } catch (_) {
        // 连接已关闭。
      }
    };

    final Completer<GenerationResult> completer = Completer<GenerationResult>();
    String content = '';
    int total = 0;

    final HttpClientResponse response = await request.close();
    // 非 2xx：读取错误体后抛出。
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String body = await response.transform(utf8.decoder).join();
      client.close(force: true);
      throw EngineException('LLM 服务返回 ${response.statusCode}：$body');
    }

    // 流式读取响应，逐 token 拼接并回报进度。
    // 注意顺序：先按行切分（String），再逐行解析。
    final Stream<String> lines =
        response.transform(utf8.decoder).transform(const LineSplitter());
    final StreamSubscription<String> sub = lines.listen(
      (String line) {
        if (line.trim().isEmpty) return;
        final String? delta = _extractDelta(line);
        if (delta != null && delta.isNotEmpty) {
          content += delta;
          total += delta.length;
          onProgress?.call(GenerationProgress(
            charsWritten: total,
            targetWords: config.targetWords,
            stage: 'AI 写作中（${(total / 2).round()} 字）…',
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
          completer.completeError(EngineException('LLM 流读取失败：$e', e));
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(GenerationResult(
            content: content.trim(),
            actualWords: content.trim().length,
            usedConfig: config,
          ));
        }
      },
    );

    try {
      return await completer.future;
    } finally {
      await sub.cancel();
      client.close(force: true);
    }
  }

  /// 大纲扩写：把 [rawOutline]（章节大纲或卷纲要点）交给 LLM 扩写成
  /// 结构化场景序列（每个场景含地点/人物/事件/情绪走向/建议字数）。
  ///
  /// 返回扩写后的文本；失败/超时/未配置返回空串（调用方回退原大纲）。
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

  /// 拼接完整请求体。
  Map<String, dynamic> _payload(GenerationConfig genConfig, ContextBundle ctx) {
    final String prompt = _buildPrompt(genConfig, ctx);
    // 按目标字数推算最大 token：中文 1 字≈1.5 token，留 15% 余量，
    // 并封顶在配置上限内（避免小 maxTokens 截断长文）。
    final int needed = (genConfig.targetWords * 1.5 * 1.15).round();
    final int maxTokens = needed.clamp(256, config.maxTokens);
    if (config.provider == LlmProvider.ollama) {
      return <String, dynamic>{
        'model': config.model,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': prompt},
        ],
        'stream': true,
        'options': <String, dynamic>{
          'temperature': config.temperature,
          'num_predict': maxTokens,
        },
      };
    }
    // OpenAI 兼容（含 llama-server 本地推理模型）。
    // chat_template_kwargs 关闭 thinking：Qwen3 等推理模型默认先输出
    // 大段思维链（reasoning_content），会吃光 max_tokens 导致正文空白。
    return <String, dynamic>{
      'model': config.model,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': prompt},
      ],
      'stream': true,
      'max_tokens': maxTokens,
      'temperature': config.temperature,
      'chat_template_kwargs': <String, dynamic>{'enable_thinking': false},
    };
  }

  /// 构造 LLM 端点 URI。
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
  ///   `data: [DONE]` 结束。
  /// - Ollama：`{json}`，json 含 `message.content`，`done:true` 结束。
  String? _extractDelta(String line) {
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

  /// 组装写作提示词（含题材 / 基调 / 角色 / 世界观 / 承接上文 / 大纲）。
  String _buildPrompt(GenerationConfig genConfig, ContextBundle ctx) {
    final StringBuffer b = StringBuffer();

    b.writeln('你是一名资深中文网络小说作家。请根据以下设定，创作一段连贯的中文小说正文。');
    b.writeln();
    b.writeln('【要求】');
    b.writeln('- 只输出小说正文，不要输出标题、章节号、解释或 Markdown 标记；');
    b.writeln('- 目标字数约 ${genConfig.targetWords} 字，控制在 '
        '${genConfig.constraints.maxWordsPerChapter} 字以内；');
    b.writeln('- 语言生动，有场景、对话、心理与动作描写；');
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
      b.writeln('【上一章结尾（请承接此情节继续）】');
      b.writeln(genConfig.continuation);
    }
    if (ctx.plotSummary.trim().isNotEmpty) {
      b.writeln();
      b.writeln('【前情提要（最近的剧情进展，保持伏笔与人物弧光一致）】');
      b.writeln(ctx.plotSummary.trim());
    }
    if (ctx.outline.trim().isNotEmpty) {
      b.writeln();
      b.writeln('【本章大纲（按此顺序推进）】');
      b.writeln(ctx.outline.trim());
    }
    b.writeln();
    b.writeln('现在开始写作：');

    return b.toString();
  }
}
