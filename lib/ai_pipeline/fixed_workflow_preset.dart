import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 固定分工预设；只保存端点描述，密钥由用户本机导入，不内置密钥。
class FixedWorkflowPreset {
  const FixedWorkflowPreset._();

  /// 已知密钥环境变量名。
  ///
  /// 显式列出而非前缀匹配：`NOVEL_KEY_FILE`（文件路径）也以 `NOVEL_KEY_`
  /// 开头，前缀匹配会把它误当成一个密钥。
  static const List<String> knownEnvKeys = <String>[
    'NOVEL_KEY_AMD',
    'NOVEL_KEY_SENSE_K1',
    'NOVEL_KEY_SENSE_K2',
    'NOVEL_KEY_SENSE_K3',
    'NOVEL_KEY_NVIDIA',
    'NOVEL_KEY_OPENROUTER',
  ];

  /// 支持 .env.local 或用户提供的 API 清单文本。只提取已知字段。
  static Map<String, String> parseKeys(String text) {
    final result = <String, String>{};
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      final match = RegExp(r'^\s*(NOVEL_KEY_[A-Z0-9_]+)\s*=\s*(\S+)')
          .firstMatch(line);
      if (match != null) result[match[1]!] = match[2]!;
    }
    void pick(String name, String pattern) {
      final match = RegExp(pattern).firstMatch(text);
      if (match != null) result.putIfAbsent(name, () => match[0]!);
    }
    pick('NOVEL_KEY_AMD', r'rc-[a-zA-Z0-9_-]+');
    pick('NOVEL_KEY_NVIDIA', r'nvapi-[a-zA-Z0-9_-]+');
    pick('NOVEL_KEY_OPENROUTER', r'sk-or-v1-[a-zA-Z0-9_-]+');
    final sense = RegExp(r'\bsk-(?!or-v1-)[a-zA-Z0-9_-]+')
        .allMatches(text).map((m) => m[0]!).toSet().take(3).toList();
    for (int i = 0; i < sense.length; i++) {
      result.putIfAbsent('NOVEL_KEY_SENSE_K${i + 1}', () => sense[i]);
    }
    return result;
  }

  /// 缺密钥端点不进入链；可选候选模型未经本轮验证，默认不启用。
  ///
  /// 角色分配（2026-09-22 全端点实测定稿）：
  /// - 规划官：SenseNova K1 `glm-5.2`（长 JSON 输出稳；需 temp=1.0 + maxTokens≥4000）
  /// - 写手：AMD `DeepSeek-V4-Flash`（17~20 字/s 全量实测最稳，配额最宽）
  /// - 编辑：K2 `kimi-k3`（去AI味效果最好，配额波动大，必须带降级链）
  /// - 标题官：K3 `deepseek-v4-flash`（轻量高频，独占 K3 分散 RPM）
  /// - 审校：K1 `glm-5.2`（低频，与规划共享 K1，温度压到 0.2）
  static Map<AiRole, AiRoleConfig> roles(Map<String, String> keys,
      {bool includeCandidates = false}) {
    LlmConfig endpoint(String key, String base, String model, double temp) =>
        LlmConfig(provider: LlmProvider.openaiCompatible,
          baseUrl: base, model: model, apiKey: keys[key]?.trim() ?? '',
          temperature: temp, maxTokens: 4096);
    final amd = endpoint('NOVEL_KEY_AMD',
        'https://developer.amd.com.cn/radeon/api/v1', 'DeepSeek-V4-Flash', 0.8);
    // 规划/审校主力（K1：低频角色专用）
    final planner = endpoint('NOVEL_KEY_SENSE_K1',
        'https://token.sensenova.cn/v1', 'glm-5.2', 1.0);
    // 写手备选 / 标题官备选（K2：与编辑同 Key 的轻量模型）
    final dsfK2 = endpoint('NOVEL_KEY_SENSE_K2',
        'https://token.sensenova.cn/v1', 'deepseek-v4-flash', 0.8);
    // 去AI味编辑主力（K2：kimi 配额波动大，失败沿链降级）
    final editor = endpoint('NOVEL_KEY_SENSE_K2',
        'https://token.sensenova.cn/v1', 'kimi-k3', 1.0);
    // 标题官主力（K3：独占第三个 Key，避免与规划/编辑抢配额）
    final title = endpoint('NOVEL_KEY_SENSE_K3',
        'https://token.sensenova.cn/v1', 'deepseek-v4-flash', 0.8);
    final candidates = includeCandidates ? [
      // NVIDIA `z-ai/glm-5.2` 已 EOL（410，2026-09-23 确认不在在架目录）→
      // 换代际后继 `z-ai/glm-5.3` 作链尾兜底（NV 端点当前排队严重，仅象征性兜底）。
      endpoint('NOVEL_KEY_NVIDIA', 'https://integrate.api.nvidia.com/v1',
          'z-ai/glm-5.3', 1.0),
      // OpenRouter 免费档 50 次/天；`stealth/ox-alpha` 已更名为 z-ai/glm-5.3-flash。
      endpoint('NOVEL_KEY_OPENROUTER', 'https://openrouter.ai/api/v1',
          'z-ai/glm-5.3-flash', 0.8),
    ] : <LlmConfig>[];
    final chains = <AiRole, List<LlmConfig>>{
      AiRole.planner: [planner, amd, ...candidates],
      AiRole.writer: [amd, dsfK2, planner, ...candidates],
      AiRole.editor: [editor, planner, amd, ...candidates],
      AiRole.titler: [title, dsfK2, amd],
      AiRole.verifier: [planner.copyWith(temperature: 0.2),
        dsfK2.copyWith(temperature: 0.2), amd, ...candidates],
    };
    return chains.map((role, chain) {
      final seen = <(String, String, String)>{};
      final usable = chain.where((c) => c.isConfigured &&
          seen.add((c.baseUrl, c.model, c.apiKey))).toList();
      return MapEntry(role, AiRoleConfig(role: role,
          llm: usable.isEmpty ? const LlmConfig() : usable.first,
          fallbacks: usable.skip(1).toList()));
    });
  }
}
