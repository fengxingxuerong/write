import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/core/errors/app_exceptions.dart';

/// LLM 提供商类型。
enum LlmProvider {
  /// OpenAI 兼容 API（DeepSeek / Moonshot / 通义 / 本地 vLLM 等）。
  openaiCompatible,

  /// 本地 Ollama（http://localhost:11434）。
  ollama,
}

/// LLM 引擎配置。
class LlmConfig {
  /// 提供商类型。
  final LlmProvider provider;

  /// 模型名（如 deepseek-chat / qwen-max / qwen2.5:7b）。
  final String model;

  /// API Key（OpenAI 兼容必填；Ollama 留空）。
  final String apiKey;

  /// Base URL（OpenAI 兼容默认 https://api.deepseek.com/v1；Ollama 默认 http://localhost:11434）。
  final String baseUrl;

  /// 单次生成最大 token 数。
  final int maxTokens;

  /// 温度（0~2，默认 0.8）。
  final double temperature;

  /// 构造配置。
  const LlmConfig({
    this.provider = LlmProvider.ollama,
    this.model = 'qwen2.5:7b',
    this.apiKey = '',
    this.baseUrl = '',
    this.maxTokens = 8192,
    this.temperature = 0.8,
  });

  /// 是否已配置可用（模型非空；端点必须符合安全策略）。
  bool get isConfigured {
    if (model.trim().isEmpty) return false;
    if (!isEndpointAllowed(baseUrl)) return false;
    if (provider == LlmProvider.openaiCompatible) {
      if (_isLocalUrl(baseUrl)) return true; // 本地服务免 Key
      return apiKey.trim().isNotEmpty;
    }
    return true;
  }

  /// 端点安全策略：仅允许 http/https；远程地址必须使用 HTTPS；
  /// 拒绝 URL 内嵌账号密码、查询参数和片段。
  static bool isEndpointAllowed(String raw) {
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty) return false;
    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return false;
    if (scheme == 'https') return true;
    return _isLocalUrl(raw);
  }

  /// 是否本地回环地址（严格按 URI.host 判断，避免 localhost.evil 绕过）。
  static bool _isLocalUrl(String url) {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    final String host = uri.host.toLowerCase();
    if (host == 'localhost' || host == '::1' || host == '[::1]') return true;
    final List<String> parts = host.split('.');
    return parts.length == 4 &&
        parts[0].isNotEmpty &&
        int.tryParse(parts[0]) == 127 &&
        parts.every((String part) {
          final int? value = int.tryParse(part);
          return value != null && value >= 0 && value <= 255;
        });
  }

  /// 是否本地服务配置（用于 UI 提示免 Key）。
  bool get isLocal => _isLocalUrl(baseUrl);

  /// 展示名。
  String get label {
    final String p = provider == LlmProvider.ollama ? 'Ollama 本地' : '云端 API';
    return '$p · $model';
  }

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'provider': provider.name,
        'model': model,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'maxTokens': maxTokens,
        'temperature': temperature,
      };

  /// 反序列化（兼容缺失字段）。
  factory LlmConfig.fromJson(Map<String, dynamic> json) {
    return LlmConfig(
      provider: LlmProvider.values.firstWhere(
        (LlmProvider e) => e.name == json['provider'],
        orElse: () => LlmProvider.ollama,
      ),
      model: json['model'] as String? ?? 'qwen2.5:7b',
      apiKey: json['apiKey'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      maxTokens: json['maxTokens'] as int? ?? 8192,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.8,
    );
  }

  /// 复制并修改部分字段。
  LlmConfig copyWith({
    LlmProvider? provider,
    String? model,
    String? apiKey,
    String? baseUrl,
    int? maxTokens,
    double? temperature,
  }) {
    return LlmConfig(
      provider: provider ?? this.provider,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
    );
  }
}

/// 引擎行为开关：与 [LlmConfig] 存在同一个 `llm_settings.json`，
/// 但独立成键空间，避免把「用不用 AI」混进连接配置语义。
class LlmEngineFlags {
  /// 是否启用 AI 引擎（false = 离线模板引擎）。
  final bool useLlm;

  /// 是否在生成后自动提取角色/世界观并落库。
  final bool autoMemory;

  /// 构造开关。
  const LlmEngineFlags({this.useLlm = false, this.autoMemory = true});

  /// 序列化。
  Map<String, dynamic> toMap() => <String, dynamic>{
        'useLlm': useLlm,
        'autoMemory': autoMemory,
      };

  /// 反序列化（缺失字段回落默认值，兼容旧配置文件）。
  factory LlmEngineFlags.fromMap(Map<String, dynamic> json) {
    final Object? auto = json['autoMemory'];
    return LlmEngineFlags(
      useLlm: json['useLlm'] == true,
      autoMemory: auto is bool ? auto : true,
    );
  }
}

/// LLM 设置仓库：JSON 文件持久化。
///
/// 存于 applicationSupportDirectory 下的 `llm_settings.json`，
/// 同时承载 [LlmConfig]（连接配置）与 [LlmEngineFlags]（引擎开关）；
/// 两者各自 [save]/[saveFlags] 时都会先读回整份文件再合并写回，
/// 互不覆盖。读配置失败抛 [StorageException]；读开关失败回落默认值（见 [loadFlags]）。
class LlmSettingsRepository {
  /// 构造仓库。
  LlmSettingsRepository(this.directory);

  /// 配置所在目录（AppDatabase 同级，避免额外 path_provider 依赖）。
  final String directory;

  /// 配置文件路径。
  String get filePath => '$directory/llm_settings.json';

  /// 读取配置；文件不存在时返回默认（Ollama）。
  Future<LlmConfig> load() async {
    final File file = File(filePath);
    if (!await file.exists()) return const LlmConfig();
    try {
      final Map<String, dynamic> json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return LlmConfig.fromJson(json);
    } catch (e) {
      throw StorageException('LLM 配置读取失败', e);
    }
  }

  /// 保存配置（原子写；保留同文件内的引擎开关键）。
  Future<void> save(LlmConfig config) async {
    await _writeJson(<String, dynamic>{
      ...await _readJson(),
      ...config.toJson(),
    });
  }

  /// 读取引擎开关。文件缺失或内容损坏时返回默认值而不抛错——
  /// 开关读失败不该让设置页崩掉。
  Future<LlmEngineFlags> loadFlags() async {
    return LlmEngineFlags.fromMap(await _readJson());
  }

  /// 保存引擎开关（原子写；保留同文件内的 [LlmConfig] 字段）。
  Future<void> saveFlags(LlmEngineFlags flags) async {
    await _writeJson(<String, dynamic>{
      ...await _readJson(),
      ...flags.toMap(),
    });
  }

  /// 读取原始 JSON；文件不存在或解析失败返回空映射。
  Future<Map<String, dynamic>> _readJson() async {
    final File file = File(filePath);
    if (!await file.exists()) return <String, dynamic>{};
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// 原子写：临时文件 + 重命名，失败清理残留。
  Future<void> _writeJson(Map<String, dynamic> json) async {
    final File file = File(filePath);
    final File tmp = File('$filePath.tmp');
    try {
      await tmp.writeAsString(jsonEncode(json), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      if (await tmp.exists()) {
        await tmp.delete().ignore();
      }
      throw StorageException('LLM 配置保存失败', e);
    }
  }
}

/// 忽略异常的清理扩展。
extension _FutureIgnore<T> on Future<T> {
  /// 吞掉异常。
  Future<void> ignore() async {
    try {
      await this;
    } catch (_) {
      // 忽略。
    }
  }
}
