import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/quality/token_tier.dart';
import 'package:novel_writer/models/llm_config.dart';

void main() {
  group('TokenTier.fromModel', () {
    test('识别推理模型 flash-lite', () {
      expect(TokenTier.fromModel('sensenova-6.7-flash-lite'),
          TokenTier.reasoning);
    });

    test('识别推理模型 R1', () {
      expect(TokenTier.fromModel('deepseek-r1'), TokenTier.reasoning);
    });

    test('识别混合模型 QwQ', () {
      expect(TokenTier.fromModel('qwq-32b'), TokenTier.hybrid);
    });

    test('识别混合模型 DeepSeek-V3', () {
      expect(TokenTier.fromModel('deepseek-v3'), TokenTier.hybrid);
    });

    test('默认标准模型', () {
      expect(TokenTier.fromModel('qwen2.5:7b'), TokenTier.standard);
      expect(TokenTier.fromModel('gpt-4'), TokenTier.standard);
    });
  });

  group('TokenBudget.calculate', () {
    test('标准模型 2000 字约需 3450 token', () {
      final int tokens = TokenBudget.calculate(
        targetWords: 2000,
        tier: TokenTier.standard,
        maxTokens: 8192,
      );
      expect(tokens, greaterThan(3000));
      expect(tokens, lessThan(4000));
    });

    test('推理模型预算约为标准 2 倍', () {
      final int standard = TokenBudget.calculate(
        targetWords: 2000,
        tier: TokenTier.standard,
        maxTokens: 32000,
      );
      final int reasoning = TokenBudget.calculate(
        targetWords: 2000,
        tier: TokenTier.reasoning,
        maxTokens: 32000,
      );
      expect(reasoning, closeTo(standard * 2, 50));
    });

    test('不超过 maxTokens 上限', () {
      final int tokens = TokenBudget.calculate(
        targetWords: 10000,
        tier: TokenTier.reasoning,
        maxTokens: 4096,
      );
      expect(tokens, 4096);
    });

    test('不低于 256 下限', () {
      final int tokens = TokenBudget.calculate(
        targetWords: 10,
        tier: TokenTier.standard,
        maxTokens: 8192,
      );
      expect(tokens, 256);
    });

    test('maxTokens 小于 256 时不抛 ArgumentError，仍按 256 下限取值', () {
      // 修复前 clamp(256, maxTokens) 在 maxTokens<256 时抛 ArgumentError。
      final int tokens = TokenBudget.calculate(
        targetWords: 10,
        tier: TokenTier.standard,
        maxTokens: 64,
      );
      expect(tokens, 256);
    });
  });

  group('TokenBudget flag 方法', () {
    test('shouldSuppressThinking 恒为 true', () {
      const LlmConfig config = LlmConfig(model: 'any');
      expect(TokenBudget.shouldSuppressThinking(config), isTrue);
    });

    test('SensNova 需要额外 Thinking: false', () {
      const LlmConfig config = LlmConfig(model: 'sensenova-6.7-flash-lite');
      expect(TokenBudget.needsExtraThinkingFlag(config), isTrue);
    });

    test('普通 Qwen 不需要额外标志', () {
      const LlmConfig config = LlmConfig(model: 'qwen2.5:7b');
      expect(TokenBudget.needsExtraThinkingFlag(config), isFalse);
    });
  });
}
