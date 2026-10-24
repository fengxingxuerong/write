import 'package:novel_writer/models/llm_config.dart';

/// 单个模型的每百万 token 价格（用于成本估算）。
///
/// **单位与口径**：数值是「美元 / 百万 token」。选美元而非人民币，是因为
/// OpenAI 兼容网关里相当一部分是境外服务（DeepSeek 官方、OpenRouter 等），
/// 美元是它们的原生计价单位；人民币换算会引入汇率漂移，反而让账本失真。
///
/// **这是一张估算表，不是报价表**：价格随时变动，且不同网关的折扣、
/// 缓存命中折扣、阶梯价各不相同。UI 上所有成本数字都必须带「约」字，
/// 且在端点未返回 usage 时显示「未知」而不是 0——**宁可让作者知道不准，
/// 也不要给一个看起来精确的错数字**。
class ModelPricing {
  /// 模型名（小写匹配片段）。
  final String model;

  /// 输入价格（美元 / 百万 token）。
  final double inputPerMillion;

  /// 输出价格（美元 / 百万 token）。
  final double outputPerMillion;

  /// 构造价格项。
  const ModelPricing({
    required this.model,
    required this.inputPerMillion,
    required this.outputPerMillion,
  });

  /// 已知模型的估算价格表。
  ///
  /// 键为**小写模型名的匹配片段**（不是全名）：端点常带版本后缀
  /// （`deepseek-chat` / `deepseek-v4-flash` / `qwen2.5:7b`），用「包含」匹配
  /// 才能覆盖同一系列的不同版本。**顺序敏感**：更具体的片段放前面。
  static const List<ModelPricing> table = <ModelPricing>[
    // OpenAI 官方。
    ModelPricing(model: 'gpt-4o-mini', inputPerMillion: 0.15, outputPerMillion: 0.60),
    ModelPricing(model: 'gpt-4o', inputPerMillion: 2.50, outputPerMillion: 10.00),
    ModelPricing(model: 'gpt-4.1', inputPerMillion: 2.00, outputPerMillion: 8.00),
    ModelPricing(model: 'o1', inputPerMillion: 15.00, outputPerMillion: 60.00),
    ModelPricing(model: 'o3', inputPerMillion: 10.00, outputPerMillion: 40.00),
    // DeepSeek。
    ModelPricing(model: 'deepseek-reasoner', inputPerMillion: 0.55, outputPerMillion: 2.19),
    ModelPricing(model: 'deepseek-chat', inputPerMillion: 0.27, outputPerMillion: 1.10),
    ModelPricing(model: 'deepseek-v4-flash', inputPerMillion: 0.10, outputPerMillion: 0.40),
    // Moonshot / Kimi。
    ModelPricing(model: 'kimi-k2', inputPerMillion: 0.60, outputPerMillion: 2.50),
    ModelPricing(model: 'moonshot', inputPerMillion: 3.00, outputPerMillion: 12.00),
    // 智谱 GLM。
    ModelPricing(model: 'glm-4.6', inputPerMillion: 0.60, outputPerMillion: 2.20),
    ModelPricing(model: 'glm-5', inputPerMillion: 0.80, outputPerMillion: 2.80),
    ModelPricing(model: 'glm', inputPerMillion: 0.60, outputPerMillion: 2.20),
    // 通义千问。
    ModelPricing(model: 'qwen3-max', inputPerMillion: 1.20, outputPerMillion: 6.00),
    ModelPricing(model: 'qwen-max', inputPerMillion: 1.60, outputPerMillion: 6.40),
    ModelPricing(model: 'qwen-plus', inputPerMillion: 0.40, outputPerMillion: 1.20),
    ModelPricing(model: 'qwen-turbo', inputPerMillion: 0.05, outputPerMillion: 0.20),
    // Anthropic（经兼容网关）。
    ModelPricing(model: 'claude', inputPerMillion: 3.00, outputPerMillion: 15.00),
    // 本地模型：按「免费」计，但显式给出 0 而不是缺省，避免与「未知」混淆。
    ModelPricing(model: 'qwen2.5:', inputPerMillion: 0, outputPerMillion: 0),
    ModelPricing(model: 'ollama', inputPerMillion: 0, outputPerMillion: 0),
  ];

  /// 查某个模型的价格；未知模型返回 null（**不猜**）。
  ///
  /// 未知模型不是「免费」而是「未知」——把未知当免费会让作者以为随便跑，
  /// 拿到账单才发现花了钱。
  static ModelPricing? forModel(String model) {
    final String m = model.trim().toLowerCase();
    if (m.isEmpty) return null;
    for (final ModelPricing p in table) {
      if (m.contains(p.model)) return p;
    }
    return null;
  }
}

/// LLM 用量账本：累计 token 与估算成本。
///
/// **为什么单独建账本而不是在各处现算**：一次流水线跑动会经过几十次调用
/// （规划、逐场景写、润色、标题、核查、终审…），作者真正想知道的是
/// 「这一章花了多少」「全书烧了多少 token」「哪些角色最贵」。这些都需要
/// **按角色/按章聚合**，而聚合的前提是每次调用都留下一条记录。
///
/// 账本是**纯增量、可序列化**的：挂在 [AiPipelineTask] 上随任务落盘，
/// 断点续传时一并恢复——否则续跑后作者看到的成本会从零重来，
/// 而实际账单早就花掉了。
class LlmLedger {
  /// 每次调用一条记录。
  final List<LlmLedgerEntry> entries;

  /// 构造账本。
  LlmLedger([List<LlmLedgerEntry>? entries])
      : entries = entries ?? <LlmLedgerEntry>[];

  /// 累计用量。
  LlmUsage get total {
    LlmUsage sum = LlmUsage.empty;
    for (final LlmLedgerEntry e in entries) {
      sum = sum + e.usage;
    }
    return sum;
  }

  /// 是否有任何一条记录带真实用量。
  bool get hasKnownUsage => entries.any((LlmLedgerEntry e) => e.usage.isKnown);

  /// 调用次数。
  int get callCount => entries.length;

  /// 按角色聚合（用量 + 估算成本）。
  Map<String, LlmLedgerBucket> byRole() {
    final Map<String, LlmLedgerBucket> map = <String, LlmLedgerBucket>{};
    for (final LlmLedgerEntry e in entries) {
      map.update(
        e.role,
        (LlmLedgerBucket b) => b.add(e),
        ifAbsent: () => LlmLedgerBucket(e.role).add(e),
      );
    }
    return map;
  }

  /// 按章节聚合（用量 + 估算成本）。
  Map<int, LlmLedgerBucket> byChapter() {
    final Map<int, LlmLedgerBucket> map = <int, LlmLedgerBucket>{};
    for (final LlmLedgerEntry e in entries) {
      final int key = e.chapterIdx;
      map.update(
        key,
        (LlmLedgerBucket b) => b.add(e),
        ifAbsent: () => LlmLedgerBucket('第 $key 章').add(e),
      );
    }
    return map;
  }

  /// 估算总成本（美元）；用量未知或价格未知时返回 null。
  double? get estimatedCostUsd {
    double? sum;
    for (final LlmLedgerEntry e in entries) {
      final double? c = e.estimatedCostUsd;
      if (c == null) continue;
      sum = (sum ?? 0) + c;
    }
    return sum;
  }

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'entries': entries.map((LlmLedgerEntry e) => e.toJson()).toList(),
      };

  /// 反序列化。
  factory LlmLedger.fromJson(Map<String, dynamic> json) => LlmLedger(
        (json['entries'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(LlmLedgerEntry.fromJson)
            .toList(),
      );
}

/// 账本中的一条调用记录。
class LlmLedgerEntry {
  /// 角色名（如「正文写手」）。
  final String role;

  /// 模型名。
  final String model;

  /// 章序（0 = 不属于具体章节，如全书大纲规划）。
  final int chapterIdx;

  /// 本次用量。
  final LlmUsage usage;

  /// 耗时（毫秒）。
  final int elapsedMs;

  /// 构造记录。
  const LlmLedgerEntry({
    required this.role,
    required this.model,
    this.chapterIdx = 0,
    this.usage = LlmUsage.empty,
    this.elapsedMs = 0,
  });

  /// 估算成本（美元）；用量或价格未知时返回 null。
  double? get estimatedCostUsd {
    if (!usage.isKnown) return null;
    final ModelPricing? p = ModelPricing.forModel(model);
    if (p == null) return null;
    final double inCost = usage.inputTokens / 1000000 * p.inputPerMillion;
    final double outCost = usage.outputTokens / 1000000 * p.outputPerMillion;
    return inCost + outCost;
  }

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'role': role,
        'model': model,
        'chapterIdx': chapterIdx,
        'usage': usage.toJson(),
        'elapsedMs': elapsedMs,
      };

  /// 反序列化。
  factory LlmLedgerEntry.fromJson(Map<String, dynamic> json) => LlmLedgerEntry(
        role: json['role'] as String? ?? '',
        model: json['model'] as String? ?? '',
        chapterIdx: json['chapterIdx'] as int? ?? 0,
        usage: LlmUsage.fromJson(
          (json['usage'] as Map<String, dynamic>?) ?? <String, dynamic>{},
        ),
        elapsedMs: json['elapsedMs'] as int? ?? 0,
      );
}

/// 一个聚合桶（按角色或按章）。
class LlmLedgerBucket {
  /// 桶名。
  final String label;

  /// 桶内记录。
  final List<LlmLedgerEntry> entries;

  /// 构造桶。
  LlmLedgerBucket(this.label, [List<LlmLedgerEntry>? entries])
      : entries = entries ?? <LlmLedgerEntry>[];

  /// 把一条记录并入桶。
  LlmLedgerBucket add(LlmLedgerEntry e) {
    entries.add(e);
    return this;
  }

  /// 累计用量。
  LlmUsage get usage {
    LlmUsage sum = LlmUsage.empty;
    for (final LlmLedgerEntry e in entries) {
      sum = sum + e.usage;
    }
    return sum;
  }

  /// 调用次数。
  int get callCount => entries.length;

  /// 估算成本（美元）；未知时返回 null。
  double? get estimatedCostUsd {
    double? sum;
    for (final LlmLedgerEntry e in entries) {
      final double? c = e.estimatedCostUsd;
      if (c == null) continue;
      sum = (sum ?? 0) + c;
    }
    return sum;
  }
}

/// 人类可读的成本（美元）。未知时返回「未知」而非「$0.00」。
String formatCostUsd(double? usd) {
  if (usd == null) return '未知';
  if (usd == 0) return '\$0.00';
  if (usd < 0.01) return '\$${usd.toStringAsFixed(4)}';
  return '\$${usd.toStringAsFixed(2)}';
}
