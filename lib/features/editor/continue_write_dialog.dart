import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 目标续写字数可选项。
const List<int> kContinueTargets = <int>[200, 400, 600, 800, 1000];

/// 编辑器续写弹窗：选择目标字数，流式展示续写内容，确认后替换正文。
class ContinueWriteDialog extends ConsumerStatefulWidget {
  /// 构造弹窗。
  const ContinueWriteDialog({
    super.key,
    required this.initialText,
    this.genre,
    this.tone,
    this.protagonistName,
    this.characters = const <Character>[],
  });

  /// 当前章节正文。
  final String initialText;

  /// 项目题材 / 基调 / 主角名（注入提示词）。
  final String? genre;
  final String? tone;
  final String? protagonistName;

  /// 项目角色（提供说话风格，让续写对话更贴人设）。
  final List<Character> characters;

  @override
  ConsumerState<ContinueWriteDialog> createState() =>
      _ContinueWriteDialogState();
}

class _ContinueWriteDialogState extends ConsumerState<ContinueWriteDialog> {
  int _targetWords = 400;
  bool _running = false;
  bool _streaming = false;
  String _streamText = '';
  String? _error;
  String? _finalText;
  StreamSubscription<String>? _sub;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _sub?.cancel();
    _focusNode.dispose();
    _scrollCtrl.dispose();
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
      final String input = widget.initialText.trimRight();
      final String ctxText = input.length > 6000
          ? input.substring(input.length - 6000)
          : input;

      final StringBuffer sys = StringBuffer()
        ..writeln('你是一名资深中文网络小说作家。你的任务是【续写】一段小说正文。')
        ..writeln()
        ..writeln('规则：')
        ..writeln('- 只输出续写的新内容，不要重复或复述已有正文，不要输出标题/章节号/解释/Markdown；')
        ..writeln('- 紧接已有正文的结尾继续推进剧情，衔接自然，不突兀；')
        ..writeln('- 保持与已有正文一致的视角、人称、语言风格与节奏；')
        ..writeln('- 目标续写约 $_targetWords 字；')
        ..writeln('- 每 80~150 字换一段，多用对话推进，段落短促有力；')
        ..writeln('- 不要在这里结束整个故事，保持情节持续推进（结尾留钩子）。');

      final StringBuffer user = StringBuffer()
        ..writeln('【题材】${widget.genre ?? '未指定'}')
        ..writeln('【基调】${widget.tone ?? '未指定'}');
      if (widget.protagonistName != null && widget.protagonistName!.isNotEmpty) {
        user.writeln('【主角】${widget.protagonistName}');
      }
      _appendDialogueStyles(user);
      user
        ..writeln()
        ..writeln('【已有正文（结尾部分）】')
        ..writeln(ctxText)
        ..writeln()
        ..writeln('请从上述正文的结尾处开始续写：');

      final HttpClientRequest req =
          await client.postUrl(Uri.parse('$base$path'));
      req.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.acceptHeader, 'application/json');
      if (cfg.provider == LlmProvider.openaiCompatible &&
          cfg.apiKey.trim().isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${cfg.apiKey}');
      }
      final Map<String, dynamic> payload;
      final int maxTokens = (_targetWords * 1.5 * 1.15).round().clamp(256, cfg.maxTokens);
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
          if (mounted) {
            setState(() {
              _streaming = false;
              _error = '续写中断：$e';
            });
          }
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
          _error = '续写失败：$e';
        });
      }
    }
  }

  /// 从 SSE 行提取增量（OpenAI 兼容 / Ollama）。
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
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.s4 + 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.auto_awesome, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'AI 续写',
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
              const SizedBox(height: AppTokens.s3),
              // 目标字数选择（运行中禁用）。
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final int n in kContinueTargets)
                    ChoiceChip(
                      label: Text('$n 字'),
                      selected: _targetWords == n,
                      onSelected: _running
                          ? null
                          : (_) => setState(() => _targetWords = n),
                    ),
                ],
              ),
              const SizedBox(height: AppTokens.s3),
              // 状态区。
              if (_running && _streamText.isEmpty && _error == null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTokens.s2),
                  child: Row(
                    children: <Widget>[
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text('AI 思考中…',
                          style: AppFonts.text(AppInk.of(context).inkSoft, size: 13)),
                    ],
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTokens.s2),
                  child: Text(
                    _error!,
                    style: AppFonts.text(Theme.of(context).colorScheme.error, size: 13),
                  ),
                ),
              // 流式/结果预览区。
              if (_streamText.isNotEmpty || showResult)
                Container(
                  height: 280,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(AppTokens.r2),
                  ),
                  padding: const EdgeInsets.all(AppTokens.s2 + 2),
                  child: SingleChildScrollView(
                    controller: _scrollCtrl,
                    child: SelectableText(
                      _streamText,
                      style: AppFonts.text(AppInk.of(context).ink, size: 14, height: 1.5),
                    ),
                  ),
                ),
              const SizedBox(height: AppTokens.s3),
              // 操作按钮。
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
                      child: Text(_finalText == null ? '开始续写' : '重新续写'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: showResult ? _apply : null,
                      child: const Text('替换正文'),
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
