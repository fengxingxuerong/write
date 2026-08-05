import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 单次 LLM 对话（非流式）的响应片段。
class LlmChatResult {
  /// 模型回复全文。
  final String content;

  /// 构造结果。
  const LlmChatResult(this.content);
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
  Future<LlmChatResult> chat(String system, String user) async {
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
            'num_predict': config.maxTokens,
          },
          'messages': <Map<String, dynamic>>[
            if (system.isNotEmpty) <String, dynamic>{'role': 'system', 'content': system},
            <String, dynamic>{'role': 'user', 'content': user},
          ],
        };
      } else {
        payload = <String, dynamic>{
          'model': config.model,
          'stream': false,
          'max_tokens': config.maxTokens,
          'temperature': 0.2,
          'chat_template_kwargs': <String, dynamic>{'enable_thinking': false},
          'messages': <Map<String, dynamic>>[
            if (system.isNotEmpty) <String, dynamic>{'role': 'system', 'content': system},
            <String, dynamic>{'role': 'user', 'content': user},
          ],
        };
      }
      req.add(utf8.encode(jsonEncode(payload)));
      final HttpClientResponse resp = await req.close();
      final String text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw EngineException('LLM 服务返回 ${resp.statusCode}：$text');
      }
      return LlmChatResult(_extractContent(text));
    } finally {
      client.close(force: true);
    }
  }

  /// 从响应体提取 content（OpenAI 兼容 / Ollama）。
  String _extractContent(String body) {
    try {
      final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
      if (config.provider == LlmProvider.ollama) {
        return (json['message'] as Map<String, dynamic>?)?['content'] as String? ?? '';
      }
      final List<dynamic> choices = json['choices'] as List<dynamic>? ?? const [];
      if (choices.isEmpty) return '';
      return ((choices.first as Map<String, dynamic>)['message']
              as Map<String, dynamic>?)?['content'] as String? ??
          '';
    } catch (_) {
      return '';
    }
  }
}
