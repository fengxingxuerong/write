import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 单次 LLM 对话（非流式）的响应片段。
class LlmChatResult {
  /// 模型回复正文（纯正文，已剥离思考链）。
  final String content;

  /// 模型思考过程（如有，供开发面板/审计用）。
  final String? reasoning;

  /// 构造结果。
  const LlmChatResult(this.content, {this.reasoning});
}

/// 轻量 LLM 对话客户端（非流式）。
///
/// 供 [StoryMemory] 等后台任务使用：发一次请求拿完整回复。
/// 与 [LlmEngine] 共用 [LlmConfig]，但走非流式端点，便于结构化输出。
class LlmChatClient {
  /// 构造客户端。
  LlmChatClient({required this.config, this.timeout = const Duration(minutes: 3)});

  /// 连接配置。
  final LlmConfig config;

  /// 请求超时。
  final Duration timeout;

  /// 发送一轮对话，返回完整回复。
  ///
  /// [temperature] 可选：不传时保持默认 0.2（向后兼容既有调用方）；
  /// 流水线等高级调用方可显式传入角色所需温度（如 glm/kimi 需 1.0）。
  Future<LlmChatResult> chat(String system, String user,
      {String? role, double? temperature}) async {
    if (!config.isConfigured) {
      throw const EngineException('LLM 未配置：请先在设置页填写模型与地址');
    }
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final String base = config.baseUrl.endsWith('/')
          ? config.baseUrl.substring(0, config.baseUrl.length - 1)
          : config.baseUrl;
      final String path = config.provider == LlmProvider.ollama
          ? '/api/chat'
          : '/chat/completions';
      final HttpClientRequest req = await client.postUrl(Uri.parse('$base$path'));
      req.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.acceptHeader, 'application/json');
      if (config.provider == LlmProvider.openaiCompatible &&
          config.apiKey.trim().isNotEmpty) {
        req.headers.set(
            HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
      }
      final Map<String, dynamic> payload;
      if (config.provider == LlmProvider.ollama) {
        payload = <String, dynamic>{
          'model': config.model,
          'stream': false,
          'options': <String, dynamic>{
            'temperature': 0.2,
            'num_predict': _calcTokenBudget(),
          },
          'messages': _buildMessages(system, user, role),
        };
      } else {
        // OpenAI 兼容
        final bool isReasoningModel = _isReasoningModel(config.model);
        payload = <String, dynamic>{
          'model': config.model,
          'stream': false,
          'max_tokens': _calcTokenBudget(),
          'temperature': temperature ?? 0.2,
          'messages': _buildMessages(system, user, role),
        };
        // OpenAI 兼容 API 一律发送 enable_thinking: false（对标准模型无害，对推理模型有效）
        payload['chat_template_kwargs'] = <String, dynamic>{'enable_thinking': false};
        // 推理模型（SensNova 等）额外发送 options.Thinking: false
        if (isReasoningModel) {
          payload['options'] = <String, dynamic>{'Thinking': false};
        }
      }
      req.add(utf8.encode(jsonEncode(payload)));
      final HttpClientResponse resp = await req.close();
      final String text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw EngineException('LLM 服务返回 ${resp.statusCode}：$text');
      }
      return _extractResult(text);
    } finally {
      client.close(force: true);
    }
  }

  /// 构造 messages 数组（支持可选 assistant 前缀）。
  List<Map<String, dynamic>> _buildMessages(String system, String user, String? role) {
    final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[];
    if (system.isNotEmpty) {
      messages.add(<String, dynamic>{'role': 'system', 'content': system});
    }
    messages.add(<String, dynamic>{'role': role ?? 'user', 'content': user});
    return messages;
  }

  /// 计算 token 预算（推理模型预留 thinking 空间）。
  int _calcTokenBudget() {
    final bool isReasoning = _isReasoningModel(config.model);
    if (isReasoning) {
      // 推理模型需要 ~2 token 输出才能生成 1 token 正文
      return (config.maxTokens * 2.5).round().clamp(512, 32768);
    }
    return config.maxTokens;
  }

  /// 判断当前模型是否为推理模型（受 thinking/reasoning 影响）。
  static bool _isReasoningModel(String model) {
    final String m = model.toLowerCase();
    return m.contains('flash-lite') ||
        m.contains('r1') ||
        m.contains('thinking') ||
        m.contains('reason') ||
        m.contains('deepseek-v4-flash') ||
        m.contains('sensenova');
  }

  /// 从响应体提取结果，分离 reasoning 与正文。
  LlmChatResult _extractResult(String body) {
    try {
      final Map<String, dynamic> jsonResp =
          jsonDecode(body) as Map<String, dynamic>;

      // Ollama 非流式响应
      if (config.provider == LlmProvider.ollama) {
        final Map<String, dynamic>? message =
            jsonResp['message'] as Map<String, dynamic>?;
        final String raw = (message?['content'] as String? ?? '');
        return _splitReasoning(raw);
      }

      // OpenAI 兼容非流式响应
      final List<dynamic> choices =
          jsonResp['choices'] as List<dynamic>? ?? const [];
      if (choices.isEmpty) {
        return const LlmChatResult('');
      }
      final Map<String, dynamic> first =
          choices.first as Map<String, dynamic>;
      final Map<String, dynamic>? message =
          first['message'] as Map<String, dynamic>?;

      if (message == null) {
        return const LlmChatResult('');
      }

      // 优先从独立 reasoning 字段提取思考链（OpenAI 标准格式）
      final String? reasoningField =
          message['reasoning_content'] as String? ?? message['reasoning'] as String?;

      // 正文 = content 字段（可能混入了 thinking 文本）
      final String rawContent = (message['content'] as String? ?? '').trim();

      // 如果 content 混入了 thinking 文本，剥离
      final String cleanContent = _stripThinkingFromContent(rawContent);

      // reasoning = 独立字段 OR 从 content 中剥离出的 thinking 文本
      String? reasoning = reasoningField;
      if (reasoning == null && rawContent != cleanContent) {
        // thinking 被剥离了，可以记录但不作为正文
        // （这里为了兼容性，不把剥离的 thinking 暴露给上层）
      }

      return LlmChatResult(cleanContent, reasoning: reasoning);
    } catch (_) {
      return const LlmChatResult('');
    }
  }

  /// 从 content 中剥离思考链文本（SensNova 等推理模型的特性）。
  ///
  /// 模式：模型在 content 中输出 "Thinking Process:" 或 "思考过程："，
  /// 然后是英文思考，最后才是正文。需要识别并剥离。
  String stripThinkingFromContent(String raw) => _stripThinkingFromContent(raw);

  /// 内部实现。
  String _stripThinkingFromContent(String raw) {
    if (raw.isEmpty) return raw;

    final String trimmed = raw.trim();

    // 1. 识别 "Thinking Process" / "思考过程" 开头
    final RegExp thinkingHeader = RegExp(
      r'^(Thinking Process|思考过程|Reasoning Chain)[:\s]*\n+',
      caseSensitive: false,
    );
    if (thinkingHeader.hasMatch(trimmed)) {
      // 找到 thinking 结束位置：正文通常以中文段落开始
      // 策略：找到 thinking header 之后的第一段纯中文内容
      final int headerEnd = trimmed.indexOf('\n');
      if (headerEnd > 0) {
        final String afterHeader = trimmed.substring(headerEnd + 1);
        // 寻找正文起始：第一个非空行且包含 >= 30% 中文字符
        final List<String> lines = afterHeader.split('\n');
        int chineseBlockStart = -1;

        for (int i = 0; i < lines.length; i++) {
          final String line = lines[i].trim();
          if (line.isEmpty) {
            if (chineseBlockStart >= 0) break; // 空行 = thinking 结束
            continue;
          }
          if (_isMostlyChinese(line)) {
            if (chineseBlockStart < 0) chineseBlockStart = i;
          } else {
            if (chineseBlockStart >= 0) break;
          }
        }

        if (chineseBlockStart >= 0) {
          // 从 chineseBlockStart 行开始，取到文件末尾
          final List<String> contentLines =
              lines.sublist(chineseBlockStart);
          return contentLines.join('\n').trim();
        }
      }
    }

    // 2. 如果 thinking header 在中间某处出现
    int midThinking = trimmed.indexOf('\nThinking Process');
    if (midThinking < 0) {
      midThinking = trimmed.indexOf('\n思考过程');
    }
    if (midThinking > 0) {
      // thinking 之前的内容保留
      final String before = trimmed.substring(0, midThinking).trim();
      return before;
    }

    return trimmed;
  }

  /// 判断文本是否主要由中文组成（>= 30% 中文字符且不在 thinking 模式）。
  bool _isMostlyChinese(String text) {
    if (text.isEmpty) return false;
    int chinese = 0;
    int total = 0;
    for (int i = 0; i < text.length; i++) {
      final int code = text.codeUnitAt(i);
      // 中文字符范围：CJK 统一汉字
      if (code >= 0x4E00 && code <= 0x9FFF) {
        chinese++;
        total++;
      } else if ((code >= 0x30 && code <= 0x39) || // 数字
          (code >= 0x20 && code <= 0x7E)) {
        total++;
      }
    }
    if (total == 0) return false;
    return (chinese / total) >= 0.15; // 15% 中文即认为进入正文
  }

  /// 从原始响应分离 reasoning 与 content（向后兼容入口）。
  LlmChatResult _splitReasoning(String rawContent) {
    final String clean = _stripThinkingFromContent(rawContent);
    return LlmChatResult(clean);
  }
}
