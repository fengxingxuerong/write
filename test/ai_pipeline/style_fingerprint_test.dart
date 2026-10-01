import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';

/// 文风指纹（P1-1 Dart 侧）：分析 / 渲染 / 距离 的离线回归。
///
/// 与 Python `scripts/test_style_fingerprint.py` 同口径同键名（双端同源）。
/// 另见 `tool/verify_style_fingerprint_parity_test.dart`：对真实成书逐值对账 drift=0
/// （需本地基线，按需手动跑；CI 侧的常量一致性由 quality_rules_parity_test 覆盖）。
void main() {
  /// 参考文风格 A：对白密集 + 短句
  final String dialogueStyle =
      List<String>.filled(30, '「你来做什么。」他推开门。\n「找你。」她抬头。')
          .join('\n');
  /// 参考文风格 B：叙述密集 + 长句
  final String narrativeStyle = List<String>.filled(
      20,
      '暮色四合的山道上，那个背着旧剑的旅人一步一步向山脊走去，'
          '风把他的衣角掀起又放下，像某种迟疑的手势。')
      .join('\n');

  group('PipelineQa.styleFingerprint', () {
    test('键集完整（双端对账的前提）', () {
      final Map<String, double> fp = PipelineQa.styleFingerprint(dialogueStyle);
      expect(
        fp.keys.toSet(),
        <String>{
          'source', 'words', 'sent_len_mean', 'sent_len_cv', 'dialogue_ratio',
          'para_len_mean', 'single_para_rate', 'de_density',
          'adverb_density', 'connector_rate', 'metaphor_density',
        },
      );
      expect(PipelineQa.styleFingerprintKeys.length, 9);
    });

    test('空文本全 0，且不抛异常', () {
      final Map<String, double> fp = PipelineQa.styleFingerprint('');
      expect(fp['words'], 0.0);
      expect(fp['sent_len_mean'], 0.0);
      expect(fp['metaphor_density'], 0.0);
    });

    test('风格方向可分：对白密集文对白占比更高、句长更短', () {
      final Map<String, double> d =
          PipelineQa.styleFingerprint(dialogueStyle);
      final Map<String, double> n =
          PipelineQa.styleFingerprint(narrativeStyle);
      expect(d['dialogue_ratio']! > n['dialogue_ratio']!, isTrue);
      expect(d['sent_len_mean']! < n['sent_len_mean']!, isTrue);
      expect(PipelineQa.fingerprintDistance(d, n), greaterThan(0.2));
    });

    test('确定性：同输入逐值相同', () {
      final Map<String, double> a = PipelineQa.styleFingerprint(narrativeStyle);
      final Map<String, double> b = PipelineQa.styleFingerprint(narrativeStyle);
      for (final String k in PipelineQa.styleFingerprintKeys) {
        expect(a[k], b[k], reason: k);
      }
    });
  });

  group('PipelineQa.styleFingerprintBlock', () {
    test('渲染含数字 + 可执行翻译 + 禁抄条款', () {
      final Map<String, double> fp = PipelineQa.styleFingerprint(dialogueStyle);
      final String block = PipelineQa.styleFingerprintBlock(fp, source: '我的参考文');
      expect(block, contains('我的参考文'));
      expect(block, contains('禁止照抄'));
      expect(block, contains('对白占比'));
      expect(block, contains('句长'));
      expect(block, contains('向参考文靠拢'));
      // 冲突时以准则为准（防「学分布」学成低对白）
      expect(block, contains('与准则冲突时以准则为准'));
    });

    test('空指纹不注入（words=0 → 空串）', () {
      expect(PipelineQa.styleFingerprintBlock(
        PipelineQa.styleFingerprint(''),
        source: 'x',
      ), isEmpty);
    });
  });

  group('PipelineQa.fingerprintDistance', () {
    test('自身距离为 0', () {
      final Map<String, double> fp = PipelineQa.styleFingerprint(narrativeStyle);
      expect(PipelineQa.fingerprintDistance(fp, fp), 0.0);
    });

    test('量纲自归一：不同量级也不爆表', () {
      final Map<String, double> a = <String, double>{
        for (final String k in PipelineQa.styleFingerprintKeys) k: 0.0,
      };
      final Map<String, double> b = <String, double>{
        for (final String k in PipelineQa.styleFingerprintKeys) k: 1.0,
      };
      expect(PipelineQa.fingerprintDistance(a, b), 1.0);
    });
  });

  group('PipelineQa.styleEvFragment', () {
    test('无参考返回空串', () {
      expect(PipelineQa.styleEvFragment(null, dialogueStyle), isEmpty);
    });

    test('有参考则给出距离与分维对比', () {
      final Map<String, double> ref =
          PipelineQa.styleFingerprint(dialogueStyle);
      final String ev =
          PipelineQa.styleEvFragment(ref, narrativeStyle);
      expect(ev, contains('与参考文距离'));
      expect(ev, contains('句长均值'));
    });
  });

  group('PipelineQa.dialogueRatioOf', () {
    test('双风格引号都算对白', () {
      expect(PipelineQa.dialogueRatioOf('「甲」他说。'), greaterThan(0.0));
      expect(PipelineQa.dialogueRatioOf('“乙”她说。'), greaterThan(0.0));
      expect(PipelineQa.dialogueRatioOf('没有引号。'), 0.0);
      expect(PipelineQa.dialogueRatioOf(''), 0.0);
    });
  });
}