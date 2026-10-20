import 'dart:convert';

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
  /// 角色分配（2026-09-24 真实链路回测，2026-10-20 复核）：
  /// - 规划官：AMD `DeepSeek-V4-Flash`（实测能稳定返回长 JSON；temp=1.0，预算 12000）
  /// - 写手：AMD `DeepSeek-V4-Flash`（正文实测完整、配额较宽）
  /// - 编辑：K2 `kimi-k3`（去AI味效果较好，失败沿链降级）
  /// - 标题官：K3 `deepseek-v4-flash`（轻量高频，独占 K3 分散 RPM）
  /// - 审校：AMD `DeepSeek-V4-Flash`（低频，温度压到 0.2）
  /// - 规划/审校备用：K1 `deepseek-v4-flash`。**原为 glm-5.2，2026-10-20 换掉**：
  ///   glm-5.2 长 prompt 下思考链吃满预算、正文恒空，作备用等于没有备用。
  ///
  /// **[roleOverrides] 让「换模型」不必改代码**：形如
  /// `{'writer': {'model': 'glm-5.3', 'temperature': 0.9}}`。这是竞品
  /// InkOS `config set-model` 的对等能力——此前换模型必须改本文件重新编译，
  /// 而真实链路里模型换代极快（实测 NVIDIA `z-ai/glm-5.2` 已 410 EOL、
  /// `stealth/ox-alpha` 更名 `z-ai/glm-5.3-flash`），硬编码必然跟不上。
  static Map<AiRole, AiRoleConfig> roles(
    Map<String, String> keys, {
    bool includeCandidates = false,
    Map<AiRole, Map<String, dynamic>> roleOverrides = const
        <AiRole, Map<String, dynamic>>{},
  }) {
    LlmConfig endpoint(String key, String base, String model, double temp,
            {int maxTokens = 4096}) =>
        LlmConfig(provider: LlmProvider.openaiCompatible,
          baseUrl: base, model: model, apiKey: keys[key]?.trim() ?? '',
          temperature: temp, maxTokens: maxTokens);
    final amd = endpoint('NOVEL_KEY_AMD',
        'https://developer.amd.com.cn/radeon/api/v1', 'DeepSeek-V4-Flash', 0.8);
    // 规划/审校主力（2026-09-24 真实回测：glm-5.2 空正文，AMD 正常）。
    //
    // **maxTokens 单列到 12000**，不能用 endpoint() 的 4096 默认：
    // 真机 2026-10-20 实跑暴露——AMD 规划超时后落到 glm-5.2 备用，4096 预算
    // 被 reasoning_tokens 吃掉约 1/3（实测 1338/4096），剩下的额度不够写完
    // 一份带缩进的多章大纲 JSON，响应被**截断在 `"origin"` 字段中间**，
    // 解析失败 → 整轮规划失败、流水线在第一章之前就退出。Python 端的规划官
    // 早在 2026-09-30 就因同一类事故从 4000 提到 12000（见 docs/交付文档.md 9 节），
    // Dart 端的 4096 是照搬旧值留下的历史欠账。审校（同链、temp 0.2）一并继承本值。
    final planner = amd.copyWith(temperature: 1.0, maxTokens: 12000);
    // 规划/审校备用：SenseNova `deepseek-v4-flash`，仅在 AMD 失败时启用。
    //
    // **2026-10-20 换掉原 glm-5.2**。三 个理由，都是实测：
    // ① 空正文：glm-5.2 在长 prompt 下思考链吃满预算、正文恒空（规划 prompt
    //    实测 reasoning_tokens 1338~4436），作"备用"等于没有备用；
    // ② 同一份规划 prompt，`deepseek-v4-flash` 实测 11.4s 出完整 3 章大纲
    //    JSON、reasoning 只用 435 token；
    // ③ 它本来就是这个仓库的 house 值（写手备选 / 标题官主力都用它），
    //    少一个模型就少一处需要单独跟进的失效模式。
    //
    // **maxTokens 也必须跟着单列 12000**：本行原先吃 endpoint() 的 4096 默认，
    // 而 4096 会被推理额度吃掉一截后**把大纲 JSON 截断在 `"origin"` 字段中间**
    // → 解析失败 → 整轮规划失败（真机 2026-10-20 就是这个形态）。
    // 审校链上的同一端点经 copyWith(temperature: 0.2) 继承本值。
    final sensePlanner = endpoint('NOVEL_KEY_SENSE_K1',
        'https://token.sensenova.cn/v1', 'deepseek-v4-flash', 0.8,
        maxTokens: 12000);
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
      AiRole.planner: [planner, sensePlanner, ...candidates],
      AiRole.writer: [amd, dsfK2, sensePlanner, ...candidates],
      AiRole.editor: [editor, sensePlanner, amd, ...candidates],
      AiRole.titler: [title, dsfK2, amd],
      AiRole.verifier: [planner.copyWith(temperature: 0.2),
        sensePlanner.copyWith(temperature: 0.2), amd, ...candidates],
    };
    // 按角色套用用户覆盖：只改链**首位**（主模型）的指定字段，备用链保持
    // 预设不变——用户表达的是「这个角色主位换成 X」，不是「把整条链重排」。
    // 若连备用链一起换，端点健康池的多级降级就废了。
    final Map<AiRole, List<LlmConfig>> routed = chains.map(
      (AiRole role, List<LlmConfig> chain) => MapEntry(
        role,
        _applyOverride(chain, roleOverrides[role]),
      ),
    );
    return routed.map((role, chain) {
      final seen = <(String, String, String)>{};
      final usable = chain.where((c) => c.isConfigured &&
          seen.add((c.baseUrl, c.model, c.apiKey))).toList();
      return MapEntry(role, AiRoleConfig(role: role,
          llm: usable.isEmpty ? const LlmConfig() : usable.first,
          fallbacks: usable.skip(1).toList()));
    });
  }

  /// 把 [override] 套到链首位（主模型）上。
  ///
  /// 支持字段：`model` / `temperature` / `maxTokens` / `baseUrl` / `apiKey` /
  /// `enabled`。**未知字段一律忽略而不是报错**——配置文本是人手写的，
  /// 拼错一个键不该让整个预设装配失败、进而让用户以为「程序坏了」。
  static List<LlmConfig> _applyOverride(
    List<LlmConfig> chain,
    Map<String, dynamic>? override,
  ) {
    if (override == null || override.isEmpty || chain.isEmpty) return chain;
    final List<LlmConfig> next = List<LlmConfig>.from(chain);
    LlmConfig head = next.first;
    final dynamic model = override['model'];
    if (model is String && model.trim().isNotEmpty) {
      head = head.copyWith(model: model.trim());
    }
    final dynamic temp = override['temperature'];
    if (temp is num) head = head.copyWith(temperature: temp.toDouble());
    final dynamic maxTok = override['maxTokens'];
    if (maxTok is num && maxTok > 0) {
      head = head.copyWith(maxTokens: maxTok.toInt());
    }
    final dynamic base = override['baseUrl'];
    if (base is String && base.trim().isNotEmpty) {
      head = head.copyWith(baseUrl: base.trim());
    }
    final dynamic key = override['apiKey'];
    if (key is String && key.trim().isNotEmpty) {
      head = head.copyWith(apiKey: key.trim());
    }
    next[0] = head;
    return next;
  }

  /// 解析角色路由覆盖 JSON：`{"writer": {"model": "glm-5.3"}}`。
  ///
  /// 坏 JSON / 非对象 / 未知角色名一律**静默忽略并回退默认**，绝不抛异常——
  /// 这段配置不该有能力把应用启动搞崩。未知角色会被丢弃。
  static Map<AiRole, Map<String, dynamic>> parseOverrides(String text) {
    final Map<AiRole, Map<String, dynamic>> out =
        <AiRole, Map<String, dynamic>>{};
    final String t = text.trim();
    if (t.isEmpty) return out;
    try {
      final dynamic decoded = jsonDecode(t);
      if (decoded is! Map) return out;
      decoded.forEach((dynamic k, dynamic v) {
        if (v is! Map) return;
        for (final AiRole role in AiRole.values) {
          if (role.name == k) {
            out[role] = Map<String, dynamic>.from(v);
          }
        }
      });
    } catch (_) {
      return <AiRole, Map<String, dynamic>>{};
    }
    return out;
  }

  /// 路由覆盖序列化为 JSON（供配置页保存）。
  ///
  /// 空值序列化成 `{}` 而不是 `[null]`——`{}` 是合法的「无覆盖」，而 `[null]`
  /// 读回来还得再判一次 null。
  static String encodeOverrides(Map<AiRole, Map<String, dynamic>> overrides) {
    if (overrides.isEmpty) return '{}';
    return const JsonEncoder.withIndent('  ').convert(
      overrides.map((AiRole k, Map<String, dynamic> v) => MapEntry(k.name, v)),
    );
  }
}
