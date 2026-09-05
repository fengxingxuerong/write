import 'package:novel_writer/models/llm_config.dart';

/// LLM 推理等级（决定 token 预算策略与 thinking 参数）。
///
/// - [standard]：标准聊天模型（GPT-4 / Qwen / DeepSeek-Chat）；
///   不生成 thinking 链，token 预算等于正文 × 1.5。
/// - [reasoning]：类 DeepSeek R1 的推理模型；
///   会先生成隐藏 thinking 链再输出正文，需预留约 2 倍 token 预算，
///   并显式关闭 thinking（避免前端显示思考过程）。
/// - [hybrid]：可选开启/关闭推理的混合模型（如 QwQ、DeepSeek-V3）；
///   默认关闭 thinking 走 plain-chat，token 策略等同 [standard]。
enum TokenTier {
  /// 标准聊天模型。
  standard(thinkingMultiplier: 1.0, supportsThinking: false),

  /// 需要 2 倍 token 预算的推理模型。
  reasoning(thinkingMultiplier: 2.0, supportsThinking: true),

  /// 可选推理（默认关闭，等同 standard）。
  hybrid(thinkingMultiplier: 1.0, supportsThinking: true);

  /// 构造等级。
  const TokenTier({
    required this.thinkingMultiplier,
    required this.supportsThinking,
  });

  /// thinking 链的 token 倍数（standard = 1.0，不预留 thinking 空间）。
  final double thinkingMultiplier;

  /// 该等级是否支持显式 thinking 参数切换。
  final bool supportsThinking;

  /// 是否为推理型（需要预留 thinking 预算）。
  bool get isReasoning => thinkingMultiplier > 1.0;

  /// 根据模型名推断推理等级。
  static TokenTier fromModel(String model) {
    final String m = model.toLowerCase();

    // 已知推理模型关键词
    if (m.contains('flash-lite') ||
        m.contains('-r1') ||
        m.contains('thinking') ||
        m.contains('reason') ||
        m.contains('deepseek-v4-flash') ||
        m.contains('distill')) {
      return TokenTier.reasoning;
    }

    // 已知混合模型（支持 enable_thinking 切换）
    if (m.contains('deepseek-v3') ||
        m.contains('qwq') ||
        m.contains('o1') ||
        m.contains('o3')) {
      return TokenTier.hybrid;
    }

    // 默认标准
    return TokenTier.standard;
  }
}

/// Token 预算计算工具（按推理等级调整）。
class TokenBudget {
  /// 私有构造。
  const TokenBudget._();

  /// 计算单次生成的 max_tokens。
  ///
  /// - [targetWords]：目标正文字数
  /// - [tier]：模型的推理等级
  /// - [maxTokens]：配置的上限（封顶值）
  static int calculate({
    required int targetWords,
    required TokenTier tier,
    required int maxTokens,
  }) {
    // 中文 1 字约等于 1.5 token，留 15% 余量
    double base = targetWords * 1.5 * 1.15;
    // 推理等级倍率
    base *= tier.thinkingMultiplier;
    return base.round().clamp(256, maxTokens);
  }

  /// 是否需要抑制思考链输出。
  ///
  /// 返回 true 时调用方应在 payload 中发送
  /// `chat_template_kwargs.enable_thinking: false`。
  /// 目前对所有模型统一禁用（前端不展示思考过程）。
  static bool shouldSuppressThinking(LlmConfig config) {
    // 所有模型在写作场景统一禁用 thinking 输出
    return true;
  }

  /// 是否需要在 payload 中额外发送 `options.Thinking: false`。
  ///
  /// SensNova 等模型需要同时设置两层：
  /// 1. chat_template_kwargs.enable_thinking = false
  /// 2. options.Thinking = false
  ///
  /// 普通 OpenAI 兼容模型仅需要第 1 层。
  static bool needsExtraThinkingFlag(LlmConfig config) {
    final String m = config.model.toLowerCase();
    return m.contains('sensenova') ||
        m.contains('flash-lite') ||
        m.contains('deepseek-v4-flash');
  }
}
