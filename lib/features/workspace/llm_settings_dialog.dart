import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 打开 AI 设置弹窗。
Future<void> showLlmSettingsDialog(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => const LlmSettingsDialog(),
  );
}

/// AI 生成设置弹窗：提供商 / 模型 / Key / BaseURL / 温度 + 测试连接。
class LlmSettingsDialog extends ConsumerStatefulWidget {
  /// 构造弹窗。
  const LlmSettingsDialog({super.key});

  @override
  ConsumerState<LlmSettingsDialog> createState() => _LlmSettingsDialogState();
}

class _LlmSettingsDialogState extends ConsumerState<LlmSettingsDialog> {
  late LlmProvider _provider;
  late double _temperature;
  late int _maxTokens;
  late bool _autoMemory;
  bool _saving = false;
  String? _testResult;
  bool _testing = false;

  // 提升为 State 字段，避免每次 build 新建导致泄漏
  late final TextEditingController _modelCtrl;
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _baseUrlCtrl;

  @override
  void initState() {
    super.initState();
    final LlmConfig c = ref.read(llmSettingsProvider).config;
    _provider = c.provider;
    _temperature = c.temperature;
    _maxTokens = c.maxTokens;
    _autoMemory = ref.read(llmSettingsProvider).autoMemory;
    _modelCtrl = TextEditingController(text: c.model);
    _apiKeyCtrl = TextEditingController(text: c.apiKey);
    _baseUrlCtrl = TextEditingController(text: c.baseUrl);
  }

  @override
  void dispose() {
    _modelCtrl.dispose();
    _apiKeyCtrl.dispose();
    _baseUrlCtrl.dispose();
    super.dispose();
  }

  String get _defaultBaseUrl =>
      _provider == LlmProvider.ollama ? 'http://localhost:11434' : 'https://api.deepseek.com/v1';

  String get _defaultModel =>
      _provider == LlmProvider.ollama ? 'qwen2.5:7b' : 'deepseek-chat';

  Future<void> _save() async {
    setState(() => _saving = true);
    final LlmConfig config = LlmConfig(
      provider: _provider,
      model: _modelCtrl.text.trim().isEmpty ? _defaultModel : _modelCtrl.text.trim(),
      apiKey: _apiKeyCtrl.text.trim(),
      baseUrl: _baseUrlCtrl.text.trim().isEmpty ? _defaultBaseUrl : _baseUrlCtrl.text.trim(),
      temperature: _temperature,
      maxTokens: _maxTokens,
    );
    await ref.read(llmSettingsProvider.notifier).updateConfig(config);
    await ref.read(llmSettingsProvider.notifier).setAutoMemory(_autoMemory);
    if (mounted) {
      setState(() => _saving = false);
      Navigator.of(context).pop();
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final LlmConfig config = LlmConfig(
      provider: _provider,
      model: _modelCtrl.text.trim().isEmpty ? _defaultModel : _modelCtrl.text.trim(),
      apiKey: _apiKeyCtrl.text.trim(),
      baseUrl: _baseUrlCtrl.text.trim().isEmpty ? _defaultBaseUrl : _baseUrlCtrl.text.trim(),
      temperature: _temperature,
      maxTokens: _maxTokens,
    );
    final String result = await _testConnection(config);
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = result;
      });
    }
  }

  /// 发一个极小的 chat 请求验证连通性。
  Future<String> _testConnection(LlmConfig config) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final String base =
          config.baseUrl.endsWith('/') ? config.baseUrl.substring(0, config.baseUrl.length - 1) : config.baseUrl;
      final String path = config.provider == LlmProvider.ollama ? '/api/chat' : '/chat/completions';
      final HttpClientRequest req = await client.postUrl(Uri.parse('$base$path'));
      req.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.acceptHeader, 'application/json');
      if (config.provider == LlmProvider.openaiCompatible &&
          config.apiKey.trim().isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
      }
      final Map<String, dynamic> body = config.provider == LlmProvider.ollama
          ? <String, dynamic>{
              'model': config.model,
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{'role': 'user', 'content': '你好，请回复"OK"'},
              ],
              'stream': false,
            }
          : <String, dynamic>{
              'model': config.model,
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{'role': 'user', 'content': '你好，请回复"OK"'},
              ],
              'stream': false,
              'max_tokens': 16,
            };
      req.add(utf8.encode(jsonEncode(body)));
      final HttpClientResponse resp = await req.close();
      final String text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return '✅ 连接成功（${resp.statusCode}）';
      }
      return '❌ 失败（${resp.statusCode}）：$text';
    } catch (e) {
      return '❌ 无法连接：$e';
    } finally {
      client.close(force: true);
    }
  }

  /// 探测本地模型服务：优先 llama-server（QClaw 内置，19110），
  /// 其次 Ollama（11434）。命中则自动填充配置。返回提示文案。
  Future<String> _detectLocal() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    const List<({int port, String name})> targets = <({int port, String name})>[
      (port: 19110, name: 'llama-server（QClaw 内置）'),
      (port: 11434, name: 'Ollama'),
    ];
    for (final t in targets) {
      final String base = 'http://127.0.0.1:${t.port}';
      final HttpClient client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      try {
        // 先试 OpenAI 兼容的 /v1/models（llama-server / Ollama 都支持）。
        final HttpClientRequest req =
            await client.getUrl(Uri.parse('$base/v1/models'));
        final HttpClientResponse resp = await req.close();
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          final String text = await resp.transform(utf8.decoder).join();
          final List<dynamic> models =
              (jsonDecode(text) as Map<String, dynamic>)['data'] as List<dynamic>;
          if (models.isNotEmpty) {
            final String model =
                (models.first as Map<String, dynamic>)['id'] as String;
            if (mounted) {
              setState(() {
                _provider = LlmProvider.openaiCompatible;
                _modelCtrl.text = model;
                _baseUrlCtrl.text = base;
                _apiKeyCtrl.text = '';
                _testing = false;
                _testResult = '✅ 发现 ${t.name}（$model）\n已自动填入，可直接保存。';
              });
            }
            return 'detected';
          }
        }
      } catch (_) {
        // 端口未开，继续下一个。
      } finally {
        client.close(force: true);
      }
    }
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = '❌ 未发现本地模型服务\n请先启动 llama-server（桌面快捷方式）或 Ollama。';
      });
    }
    return 'none';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('AI 生成设置'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              DropdownButtonFormField<LlmProvider>(
                initialValue: _provider,
                decoration: const InputDecoration(labelText: '提供商'),
                items: const <DropdownMenuItem<LlmProvider>>[
                  DropdownMenuItem(
                    value: LlmProvider.ollama,
                    child: Text('Ollama（本地免费）'),
                  ),
                  DropdownMenuItem(
                    value: LlmProvider.openaiCompatible,
                    child: Text('云端 API（DeepSeek 等）'),
                  ),
                ],
                onChanged: (LlmProvider? v) {
                  if (v == null) return;
                  setState(() {
                    _provider = v;
                    if (_modelCtrl.text.isEmpty) _modelCtrl.text = _defaultModel;
                    if (_baseUrlCtrl.text.isEmpty) _baseUrlCtrl.text = _defaultBaseUrl;
                  });
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _modelCtrl,
                decoration: InputDecoration(
                  labelText: '模型名',
                  hintText: _defaultModel,
                  helperText: _provider == LlmProvider.ollama
                      ? '如 qwen2.5:7b / llama3.1:8b'
                      : '如 deepseek-chat / qwen-max',
                ),
                enabled: !_testing,
              ),
              const SizedBox(height: 12),
              if (_provider == LlmProvider.openaiCompatible) ...<Widget>[
                TextField(
                  controller: _apiKeyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'API Key',
                    hintText: 'sk-...',
                    helperText: '仅保存在本机，不会上传',
                  ),
                  obscureText: true,
                  enabled: !_testing,
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _baseUrlCtrl,
                decoration: InputDecoration(
                  labelText: 'Base URL',
                  hintText: _defaultBaseUrl,
                ),
                enabled: !_testing,
              ),
              const SizedBox(height: 12),
              Text('温度：${_temperature.toStringAsFixed(1)}（越低越稳定）'),
              Slider(
                value: _temperature,
                min: 0,
                max: 2,
                divisions: 20,
                label: _temperature.toStringAsFixed(1),
                onChanged: _testing ? null : (v) => setState(() => _temperature = v),
              ),
              const SizedBox(height: 12),
              Text('单次最大 Token：$_maxTokens（长文生成建议调高）'),
              Slider(
                value: _maxTokens.toDouble(),
                min: 512,
                max: 16384,
                divisions: 63,
                label: '$_maxTokens',
                onChanged: _testing
                    ? null
                    : (v) => setState(() => _maxTokens = v.round()),
              ),
              const SizedBox(height: 8),
              // 自动维护设定开关。
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('自动维护设定（AI 记忆）'),
                subtitle: const Text(
                  '生成后自动提取新角色/世界观并更新已有设定，保持长文一致',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                value: _autoMemory,
                onChanged: (bool v) => setState(() => _autoMemory = v),
              ),
              const SizedBox(height: 12),
              if (_testResult != null) ...<Widget>[
                Text(
                  _testResult!,
                  style: TextStyle(
                    color: _testResult!.startsWith('✅') ? Colors.green : Colors.red,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _testing
              ? null
              : () async {
                  await _detectLocal();
                },
          child: Text(_testing ? '检测中…' : '检测本地模型'),
        ),
        TextButton(
          onPressed: _testing
              ? null
              : () async {
                  await _test();
                },
          child: Text(_testing ? '测试中…' : '测试连接'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
