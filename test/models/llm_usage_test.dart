import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/models/llm_usage.dart';

void main() {
  group('LlmUsage.parse：多口径兼容', () {
    test('OpenAI 兼容的 usage 子对象', () {
      final LlmUsage u = LlmUsage.parse(<String, dynamic>{
        'choices': <dynamic>[],
        'usage': <String, dynamic>{
          'prompt_tokens': 120,
          'completion_tokens': 30,
          'total_tokens': 150,
        },
      });
      expect(u.inputTokens, 120);
      expect(u.outputTokens, 30);
      expect(u.totalTokens, 150);
      expect(u.isKnown, isTrue);
    });

    test('Anthropic 风格 input/output_tokens', () {
      final LlmUsage u = LlmUsage.parse(<String, dynamic>{
        'usage': <String, dynamic>{'input_tokens': 9, 'output_tokens': 4},
      });
      expect(u.inputTokens, 9);
      expect(u.outputTokens, 4);
    });

    test('部分网关把字段拍平在响应根上', () {
      final LlmUsage u = LlmUsage.parse(<String, dynamic>{
        'prompt_tokens': 7,
        'completion_tokens': 3,
      });
      expect(u.totalTokens, 10);
    });

    test('Ollama 的 prompt_eval_count / eval_count', () {
      final LlmUsage u = LlmUsage.parse(<String, dynamic>{
        'prompt_eval_count': 44,
        'eval_count': 11,
      });
      expect(u.inputTokens, 44);
      expect(u.outputTokens, 11);
    });

    test('只有 total_tokens 不制造假的输入/输出拆分', () {
      final LlmUsage u = LlmUsage.parse(<String, dynamic>{
        'usage': <String, dynamic>{'total_tokens': 999},
      });
      expect(u.isKnown, isFalse);
      expect(u.totalTokens, 0);
    });

    test('缺失/非法/非 Map 一律记未知，不估算', () {
      expect(LlmUsage.parse(null).isKnown, isFalse);
      expect(LlmUsage.parse('not a map').isKnown, isFalse);
      expect(LlmUsage.parse(<String, dynamic>{}).isKnown, isFalse);
      expect(
        LlmUsage.parse(<String, dynamic>{
          'usage': <String, dynamic>{'prompt_tokens': 'abc'},
        }).isKnown,
        isFalse,
      );
    });

    test('字符串数字按整数解析（端点偶尔回字符串）', () {
      final LlmUsage u = LlmUsage.parse(<String, dynamic>{
        'usage': <String, dynamic>{
          'prompt_tokens': '21',
          'completion_tokens': '8',
        },
      });
      expect(u.inputTokens, 21);
      expect(u.outputTokens, 8);
    });
  });

  group('LlmLedger：聚合与成本', () {
    final LlmLedger ledger = LlmLedger(<LlmLedgerEntry>[
      const LlmLedgerEntry(
        role: '正文写手',
        model: 'deepseek-v4-flash',
        chapterIdx: 1,
        usage: LlmUsage(inputTokens: 1000000, outputTokens: 1000000),
      ),
      const LlmLedgerEntry(
        role: '正文写手',
        model: 'deepseek-v4-flash',
        chapterIdx: 2,
        usage: LlmUsage(inputTokens: 500000, outputTokens: 500000),
      ),
      const LlmLedgerEntry(
        role: '总规划官',
        model: 'unknown-model',
        chapterIdx: 0,
        usage: LlmUsage(inputTokens: 10, outputTokens: 5),
      ),
      const LlmLedgerEntry(
        role: '去AI味编辑',
        model: 'glm-5',
        chapterIdx: 1,
      ),
    ]);

    test('累计用量与调用次数', () {
      expect(ledger.callCount, 4);
      expect(ledger.total.inputTokens, 1500010);
      expect(ledger.total.outputTokens, 1500005);
      expect(ledger.hasKnownUsage, isTrue);
    });

    test('按角色 / 按章聚合', () {
      final Map<String, LlmLedgerBucket> byRole = ledger.byRole();
      expect(byRole['正文写手']!.callCount, 2);
      expect(byRole['正文写手']!.usage.inputTokens, 1500000);
      expect(byRole['总规划官']!.callCount, 1);

      final Map<int, LlmLedgerBucket> byChapter = ledger.byChapter();
      expect(byChapter[1]!.callCount, 2);
      expect(byChapter[2]!.callCount, 1);
      expect(byChapter[0]!.callCount, 1);
    });

    test('成本只累计「用量已知且价格已知」的记录', () {
      // deepseek-v4-flash: 输入 $0.10 / 输出 $0.40 每百万 token。
      // 1M in + 1M out = 0.10 + 0.40 = 0.50；
      // 0.5M in + 0.5M out = 0.05 + 0.20 = 0.25。
      // unknown-model 与空用量不参与，也不把总和拉成 null。
      expect(ledger.estimatedCostUsd, closeTo(0.75, 1e-9));
    });

    test('全部未知时成本返回 null（未知 ≠ 免费）', () {
      final LlmLedger unknown = LlmLedger(<LlmLedgerEntry>[
        const LlmLedgerEntry(role: '写手', model: 'unknown'),
      ]);
      expect(unknown.estimatedCostUsd, isNull);
      expect(formatCostUsd(null), '未知');
    });

    test('序列化 round-trip 保留每条记录', () {
      final LlmLedger back = LlmLedger.fromJson(ledger.toJson());
      expect(back.callCount, ledger.callCount);
      expect(back.total.inputTokens, ledger.total.inputTokens);
      expect(back.entries[0].role, '正文写手');
      expect(back.entries[0].usage.outputTokens, 1000000);
      expect(back.estimatedCostUsd, closeTo(0.75, 1e-9));
    });

    test('空 JSON 反序列化为空账本，不抛错', () {
      final LlmLedger empty = LlmLedger.fromJson(<String, dynamic>{});
      expect(empty.callCount, 0);
      expect(empty.total.isKnown, isFalse);
      expect(empty.estimatedCostUsd, isNull);
    });
  });

  group('成本与计数格式化', () {
    test('已知成本按量级显示', () {
      expect(formatCostUsd(0), '\$0.00');
      expect(formatCostUsd(0.0034), '\$0.0034');
      expect(formatCostUsd(1.234), '\$1.23');
    });

    test('未知模型不猜价格', () {
      expect(ModelPricing.forModel('some-unknown-model'), isNull);
      expect(ModelPricing.forModel(''), isNull);
    });

    test('模型匹配优先具体片段（gpt-4o-mini 不被 gpt-4o 抢先）', () {
      expect(ModelPricing.forModel('gpt-4o-mini-2024')!.model, 'gpt-4o-mini');
      expect(ModelPricing.forModel('DeepSeek-V4-Flash')!.model,
          'deepseek-v4-flash');
    });

    test('token 计数带千分位', () {
      expect(formatTokenCount(1234567), '1,234,567');
      expect(formatTokenCount(0), '0');
    });
  });
}
