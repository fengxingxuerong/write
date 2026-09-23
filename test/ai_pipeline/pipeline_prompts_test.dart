import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/prompts/pipeline_prompts.dart';

/// pipeline_prompts 关键 prompt 的内容回归（防双端同步倒退）。
void main() {
  group('stateExtractPrompt', () {
    test('硬状态含人物关系条目与关系格式行（防关系张冠李戴，2026-09-23）', () {
      final String p = stateExtractPrompt('正文', '旧状态');
      expect(p, contains('人物关系'));
      expect(p, contains('关系：A是B的师父'));
      expect(p, contains('旧状态'));
    });

    test('旧状态为空时渲染（无）', () {
      expect(stateExtractPrompt('正文', ''), contains('（无）'));
    });
  });

  group('qualityReviewPrompt', () {
    test('qaEvidence 注入本地质检证据块（与 Python qa_evidence 同口径）', () {
      final String p =
          qualityReviewPrompt('正文', qaEvidence: '章末钩子检测：命中 ✅');
      expect(p, contains('本地质检证据'));
      expect(p, contains('章末钩子检测：命中'));
    });

    test('无证据时不渲染证据块', () {
      expect(qualityReviewPrompt('正文'), isNot(contains('本地质检证据')));
    });
  });
}