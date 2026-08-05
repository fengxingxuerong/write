import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/llm_config.dart';

/// AI 修改（重写）弹窗：针对选中文本，按用户意见重写。
///
/// 流式展示重写结果；确认后通过 [result] 返回新的文本，由编辑器替换选中区域。
class RewriteDialog extends ConsumerStatefulWidget {
  /// 构造弹窗。
  const RewriteDialog({
    super.key,
    required this.selectedText,
    this.genre,
    this.tone,
    this.protagonistName,
    this.characters = const <Character>[],
  });

  /// 被选中的原文。
  final String selectedText;

  /// 项目题材 / 基调 / 主角名。
  final String? genre;
  final String? tone;
  final String? protagonistName;

  /// 项目角色（提供说话风格，让重写对话更贴人设）。
  final List<Character> characters;

  @override
  ConsumerState<RewriteDialog> createState() => _RewriteDialogState();
}

class _RewriteDialogState extends ConsumerState<RewriteDialog> {
  final TextEditingController _instructionCtrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _running = false;
  bool _streaming = false;
  String _streamText = '';
  String? _error;
  String? _finalText;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _instructionCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 向 user prompt 追加角色说话风格块（仅非空风格的角色）。
  void _appendDialogueStyles(StringBuffer user) {
    final List<Character> styled = widget.characters
        .where((c) => c.dialogueStyle.trim().isNotEmpty)
        .toList();
    if (styled.isEmpty) return;
    user.writeln();
    user.writeln('【角色说话风格（对话必须严格贴合）】');
    for (final c in styled) {
      user.writeln('- ${c.name}：${c.dialogueStyle.trim()}');
    }
  }

  Future<void> _start() async {
    final String instruction = _instructionCtrl.text.trim();
    if (instruction.isEmpty) {
      setState(() => _error = '请先输入修改意见');
      return;
    }
    final LlmSettingsState llm = ref.read(llmSettingsProvider);
    if (!llm.useLlm || !llm.config.isConfigured) {
      setState(() => _error = 'AI 未配置：请先在「设置 → AI 生成设置」中配置本地模型');
      return;
    }
    setState(() {
      _running = true;
      _streaming = true;
      _error = null;
      _streamText = '';
      _finalText = null;
    });

    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final LlmConfig cfg = llm.config;
      final String base = cfg.baseUrl.endsWith('/')
          ? cfg.baseUrl.substring(0, cfg.baseUrl.length - 1)
          : cfg.baseUrl;
      final String path = cfg.provider == LlmProvider.ollama
          ? '/api/chat'
          : '/chat/completions';
      final String original = widget.selectedText.trimRight();

      final StringBuffer sys = StringBuffer()
        ..writeln('你是一名资深中文小说编辑，擅长按要求修改小说正文。')
        ..writeln()
        ..writeln('规则：')
        ..writeln('- 严格按用户的修改意见修改，不要擅自添加无关内容；')
        ..writeln('- 保留原文未提及部分的所有信息与情节，不得丢失原有内容；')
        ..writeln('- 只输出修改后的完整正文，不要解释、不要 Markdown、不要标题；')
        ..writeln('- 保持与原文一致的视角、人称、语言风格；')
        ..writeln('- 每 80~150 字换一段，段落短促，对话自然。');

      final StringBuffer user = StringBuffer()
        ..writeln('【修改意见】')
        ..writeln(instruction)
        ..writeln()
        ..writeln('【题材】${widget.genre ?? '未指定'}')
        ..writeln('【基调】${widget.tone ?? '未指定'}');
      if (widget.protagonistName != null && widget.protagonistName!.isNotEmpty) {
        user.writeln('【主角】${widget.protagonistName}');
      }
      _appendDialogueStyles(user);
      user
        ..writeln()
        ..writeln('【原文（${original.length} 字）】')
        ..writeln(original)
        ..writeln()
        ..writeln('请输出修改后的完整正文：');

      final HttpClientRequest req =
          await client.postUrl(Uri.parse('$base$path'));
      req.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.acceptHeader, 'application/json');
      if (cfg.provider == LlmProvider.openaiCompatible &&
          cfg.apiKey.trim().isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${cfg.apiKey}');
      }
      // 修改：输出长度≈原文长度×1.3，留足余量。
      final int maxTokens = (original.length * 1.5 * 1.3)
          .round()
          .clamp(256, cfg.maxTokens);
      final Map<String, dynamic> payload;
      if (cfg.provider == LlmProvider.ollama) {
        payload = <String, dynamic>{
          'model': cfg.model,
          'stream': true,
          'options': <String, dynamic>{
            'temperature': cfg.temperature,
            'num_predict': maxTokens,
          },
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'system', 'content': sys.toString()},
            <String, dynamic>{'role': 'user', 'content': user.toString()},
          ],
        };
      } else {
        payload = <String, dynamic>{
          'model': cfg.model,
          'stream': true,
          'max_tokens': maxTokens,
          'temperature': cfg.temperature,
          'chat_template_kwargs': <String, dynamic>{'enable_thinking': false},
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'system', 'content': sys.toString()},
            <String, dynamic>{'role': 'user', 'content': user.toString()},
          ],
        };
      }
      req.add(utf8.encode(jsonEncode(payload)));

      final HttpClientResponse resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final String body = await resp.transform(utf8.decoder).join();
        throw EngineException('AI 服务返回 ${resp.statusCode}：$body');
      }

      final Stream<String> lines = resp
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      _sub = lines.listen(
        (String line) {
          if (line.trim().isEmpty) return;
          final String? delta = _extractDelta(line, cfg.provider);
          if (delta != null && delta.isNotEmpty) {
            setState(() => _streamText += delta);
          }
        },
        onError: (Object e) {
          setState(() {
            _streaming = false;
            _error = '修改中断：$e';
          });
        },
        onDone: () {
          if (mounted) {
            setState(() {
              _streaming = false;
              _finalText = _streamText.trim();
            });
          }
        },
      );
    } catch (e) {
      client.close(force: true);
      if (mounted) {
        setState(() {
          _streaming = false;
          _error = '修改失败：$e';
        });
      }
    }
  }

  String? _extractDelta(String line, LlmProvider provider) {
    final String trimmed = line.trim();
    if (provider == LlmProvider.ollama) {
      try {
        final Map<String, dynamic> json =
            jsonDecode(trimmed) as Map<String, dynamic>;
        final Map<String, dynamic>? message =
            json['message'] as Map<String, dynamic>?;
        return message?['content'] as String?;
      } catch (_) {
        return null;
      }
    }
    if (!trimmed.startsWith('data:')) return null;
    final String data = trimmed.substring(5).trim();
    if (data == '[DONE]') return null;
    try {
      final Map<String, dynamic> json =
          jsonDecode(data) as Map<String, dynamic>;
      final List<dynamic> choices =
          json['choices'] as List<dynamic>? ?? const <dynamic>[];
      if (choices.isEmpty) return null;
      final Map<String, dynamic> delta =
          (choices.first as Map<String, dynamic>)['delta']
              as Map<String, dynamic>? ??
          const <String, dynamic>{};
      return delta['content'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> _cancelStream() async {
    await _sub?.cancel();
    if (mounted) {
      setState(() {
        _streaming = false;
        _finalText = _streamText.trim().isEmpty ? null : _streamText.trim();
      });
    }
  }

  void _apply() {
    final String? result = _finalText;
    if (result == null || result.isEmpty) return;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final bool showResult = _finalText != null && _finalText!.isNotEmpty;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.edit_note, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'AI 修改选中内容',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // 原文本摘要。
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '已选中 ${widget.selectedText.length} 字',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 10),
              // 修改意见输入。
              TextField(
                controller: _instructionCtrl,
                focusNode: _focusNode,
                maxLines: 2,
                decoration: const InputDecoration(
                  hintText: '如：太拖沓，砍一半；主角太被动；这段改成对话体…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _running ? null : _start(),
              ),
              const SizedBox(height: 10),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              // 流式/结果预览。
              if (_streamText.isNotEmpty || showResult)
                Container(
                  height: 300,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _streamText,
                      style: const TextStyle(fontSize: 14, height: 1.5),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  if (_streaming)
                    TextButton(
                      onPressed: _cancelStream,
                      child: const Text('停止'),
                    )
                  else if (_running && !showResult)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else ...[
                    TextButton(
                      onPressed: _running ? null : _start,
                      child: Text(_finalText == null ? '开始修改' : '重新修改'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: showResult ? _apply : null,
                      child: const Text('替换选中内容'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
