import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/core/security/secret_store.dart';

/// LLM 提供商类型。
enum LlmProvider {
  /// OpenAI 兼容 API（DeepSeek / Moonshot / 通义 / 本地 vLLM 等）。
  openaiCompatible,

  /// 本地 Ollama（http://localhost:11434）。
  ollama,
}

/// 单次 LLM 调用的 token 用量。
///
/// **为什么需要它**：此前 Dart 与 Python 两端都只取正文，**从不解析响应里的
/// `usage`**——于是「这本书花了多少钱」「哪一章最烧 token」这类问题在产品里
/// 根本无从回答：作者只能看服务商后台的账单，而账单分不出「哪一章的润色
/// 把额度吃完了」。多角色流水线一次跑动几十次调用，作者对成本的感知是
/// 完全黑箱的。
///
/// 解析 `usage` 是零成本的（字段本来就在响应体里），不解析才是浪费。
/// 各家字段口径不同，故这里做**多口径兼容**：
/// - OpenAI 兼容：`usage.prompt_tokens` / `completion_tokens` / `total_tokens`；
/// - 部分网关只给 `usage.input_tokens` / `output_tokens`（Anthropic 风格）；
/// - 部分网关把字段拍平在**顶层**（不在 `usage` 子对象里）；
/// - Ollama：`prompt_eval_count` / `eval_count`。
///
/// 缺字段时一律记 0（**不猜、不估算**）：账本宁可显示「未知」也不能编造数字，
/// 编出来的成本会让作者误判预算，见 [LlmUsage.isKnown]。
class LlmUsage {
  /// 输入 token 数（prompt / input）。
  final int inputTokens;

  /// 输出 token 数（completion / output）。
  final int outputTokens;

  /// 构造用量。
  const LlmUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  /// 空用量（端点未返回 usage 时）。
  static const LlmUsage empty = LlmUsage();

  /// 是否拿到了真实数字。
  ///
  /// 两者皆 0 视为「未知」——端点不返回 usage 是常态，不该在 UI 上显示
  /// 「本次消耗 0 token」（那会被作者读成「这次免费」）。
  bool get isKnown => inputTokens > 0 || outputTokens > 0;

  /// 总 token 数。
  int get totalTokens => inputTokens + outputTokens;

  /// 累加另一段用量（重试、链式 failover 会产生多段）。
  LlmUsage operator +(LlmUsage other) => LlmUsage(
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
      );

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
      };

  /// 反序列化。
  factory LlmUsage.fromJson(Map<String, dynamic> json) => LlmUsage(
        inputTokens: json['inputTokens'] as int? ?? 0,
        outputTokens: json['outputTokens'] as int? ?? 0,
      );

  /// 从任意响应 JSON 中解析用量（兼容多口径）。
  ///
  /// 传 null（解析失败）返回 [empty]。
  static LlmUsage parse(Object? body) {
    if (body is! Map) return empty;
    final Map<dynamic, dynamic> root = body;

    // 口径 1：标准 `usage` 子对象（OpenAI 兼容）。
    final Object? usage = root['usage'];
    if (usage is Map) {
      final LlmUsage parsed = _parseUsageMap(usage);
      if (parsed.isKnown) return parsed;
    }

    // 口径 2：顶层拍平（部分网关把 usage 字段直接放在响应根上）。
    final LlmUsage flat = _parseUsageMap(root);
    if (flat.isKnown) return flat;

    // 口径 3：Ollama 字段名不同，单独兜一次。
    final int? promptEval = _asInt(root['prompt_eval_count']);
    final int? evalCount = _asInt(root['eval_count']);
    if (promptEval != null || evalCount != null) {
      return LlmUsage(
        inputTokens: promptEval ?? 0,
        outputTokens: evalCount ?? 0,
      );
    }

    return empty;
  }

  /// 解析一个 usage 风格的对象（字段名多口径兼容）。
  static LlmUsage _parseUsageMap(Map<dynamic, dynamic> map) {
    final int? input = _asInt(map['prompt_tokens']) ??
        _asInt(map['input_tokens']) ??
        _asInt(map['promptTokens']) ??
        _asInt(map['inputTokens']);
    final int? output = _asInt(map['completion_tokens']) ??
        _asInt(map['output_tokens']) ??
        _asInt(map['completionTokens']) ??
        _asInt(map['outputTokens']);
    // 只有 total_tokens 时无法拆分输入/输出，按「全是输出」处理是错的，
    // 宁可记 0（未知）也不制造错误的拆分口径。
    if (input == null && output == null) return empty;
    return LlmUsage(inputTokens: input ?? 0, outputTokens: output ?? 0);
  }

  /// 宽松取整数（端点偶尔回字符串形式的数字）。
  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  @override
  String toString() =>
      'LlmUsage(in: $inputTokens, out: $outputTokens, total: $totalTokens)';
}

/// 人类可读的 token 计数（按千分位分组，避免 1234567 难以扫读）。
String formatTokenCount(int tokens) {
  final String raw = tokens.abs().toString();
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < raw.length; i++) {
    if (i > 0 && (raw.length - i) % 3 == 0) b.write(',');
    b.write(raw[i]);
  }
  return '${tokens < 0 ? '-' : ''}$b';
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
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return false;
    }
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

  /// 序列化为 JSON（本地配置/断点恢复会包含 API Key）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider.name,
    'model': model,
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'maxTokens': maxTokens,
    'temperature': temperature,
  };

  /// 生成用于日志、诊断和 UI 预览的安全 JSON，不包含真实 API Key。
  Map<String, dynamic> toRedactedJson() => <String, dynamic>{
    ...toJson(),
    'apiKey': apiKey.isEmpty ? '' : '********',
  };

  @override
  String toString() =>
      'LlmConfig($label, key: ${apiKey.isEmpty ? '无' : '********'})';

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
  /// 构造仓库；凭据保护器必须显式注入，避免生产环境静默退回内存实现。
  LlmSettingsRepository(this.directory, {required this.secretStore});

  /// 配置所在目录（AppDatabase 同级，避免额外 path_provider 依赖）。
  final String directory;

  /// 凭据保护器；生产 Windows 使用 DPAPI，测试可注入内存实现。
  final SecretStore secretStore;

  /// 配置文件路径。
  String get filePath => '$directory/llm_settings.json';

  /// 读取配置；文件不存在时返回默认（Ollama）。
  Future<LlmConfig> load() async {
    final File file = File(filePath);
    if (!await file.exists()) return const LlmConfig();
    try {
      final Map<String, dynamic> decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final Map<String, dynamic> restored = Map<String, dynamic>.from(
        (await unprotectJsonSecrets(decoded, secretStore)) as Map,
      );
      final LlmConfig config = LlmConfig.fromJson(restored);
      // 兼容旧版明文配置：首次读取后立即迁移为受保护字段。
      if (decoded['apiKey'] is String &&
          (decoded['apiKey'] as String).isNotEmpty) {
        try {
          await save(config);
        } catch (_) {
          // 迁移失败不应把已经成功读取的旧配置变成读取失败。
        }
      }
      return config;
    } catch (e) {
      throw StorageException('LLM 配置读取失败', e);
    }
  }

  /// 保存配置（原子写；保留同文件内的引擎开关键）。
  Future<void> save(LlmConfig config) async {
    final Map<String, dynamic> merged = <String, dynamic>{...await _readJson()}
      ..remove('apiKey')
      ..remove('apiKeyEncrypted');
    merged.addAll(config.toJson());
    final Map<String, dynamic> protected = Map<String, dynamic>.from(
      (await protectJsonSecrets(merged, secretStore)) as Map,
    );
    await _writeJson(protected);
  }

  /// 读取引擎开关。文件缺失或内容损坏时返回默认值而不抛错——
  /// 开关读失败不该让设置页崩掉。
  Future<LlmEngineFlags> loadFlags() async {
    return LlmEngineFlags.fromMap(await _readJson());
  }

  /// 是否**曾经持久化过**引擎开关（配置文件里存在 `useLlm` 键）。
  ///
  /// 与 [loadFlags] 的区别：后者在文件缺失时也返回「默认的 false」，无法区分
  /// 「用户明确关掉了 AI」和「用户从没做过选择」。首次启动自动接入本机密钥
  /// （见 `autoEnableLlmFromLocalKeys`）只能在前者不成立时动手——否则
  /// 用户关掉 AI、下次启动又被自动打开，开关等于失效。
  Future<bool> hasPersistedFlags() async {
    final Map<String, dynamic> raw = await _readJson();
    return raw.containsKey('useLlm');
  }

  /// 保存引擎开关（原子写；保留同文件内的 [LlmConfig] 字段）。
  Future<void> saveFlags(LlmEngineFlags flags) async {
    final Map<String, dynamic> merged = <String, dynamic>{
      ...await _readJson(),
      ...flags.toMap(),
    };
    // saveFlags 也必须保护旧版明文配置，不能只依赖 load() 完成迁移。
    final Map<String, dynamic> protected = Map<String, dynamic>.from(
      (await protectJsonSecrets(merged, secretStore)) as Map,
    );
    await _writeJson(protected);
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
