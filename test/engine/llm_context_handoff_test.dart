import 'package:characters/characters.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/llm_context_brief.dart';

void main() {
  group('LlmContextBrief.sceneHandoff', () {
    test('短文本原样返回，不做裁剪', () {
      expect(LlmContextBrief.sceneHandoff('林舟收起钥匙。'), '林舟收起钥匙。');
    });

    test('空文本与纯空白返回空串', () {
      expect(LlmContextBrief.sceneHandoff(''), isEmpty);
      expect(LlmContextBrief.sceneHandoff('  \n '), isEmpty);
    });

    test('超长文本截尾并裁到最近句首', () {
      final String text = '${'前' * 100}残句结束。林舟推门。';
      expect(LlmContextBrief.sceneHandoff(text, tailChars: 12), '林舟推门。');
    });

    test('预算内只有长句末尾时保留尾部而非清空', () {
      final String text =
          '第一句完整。第二句也完整。${'水声在岩缝间回荡，' * 30}终句落地。';
      expect(LlmContextBrief.sceneHandoff(text, tailChars: 60),
          text.characters.skip(text.characters.length - 60).toString());
    });

    test('截取点恰好是句首时不丢弃完整句子', () {
      const suffix = '林舟推门。门锁坏了。';
      expect(LlmContextBrief.sceneHandoff('前文。$suffix',
          tailChars: suffix.characters.length), suffix);
    });

    test('跳过句末连续标点与右引号，保留下一句左引号', () {
      expect(LlmContextBrief.sceneHandoff(
          '${'前' * 100}他说：“快走！？”林舟推门。', tailChars: 12), '林舟推门。');
      expect(LlmContextBrief.sceneHandoff('前文。”林舟推门。', tailChars: 6),
          '林舟推门。');
      expect(LlmContextBrief.sceneHandoff('${'前' * 100}残句！“走吧。”',
          tailChars: 9), '“走吧。”');
    });

    test('复合 emoji 与组合字符保持完整字素', () {
      for (final glyph in ['e\u0301', '👨‍👩‍👧‍👦']) {
        final result = LlmContextBrief.sceneHandoff(glyph * 80, tailChars: 30);
        expect(result, glyph * 30);
        expect(result.characters.length, 30);
      }
    });

    test('换行后的段落可作为承接起点', () {
      for (final newline in ['\n', '\r\n']) {
        expect(LlmContextBrief.sceneHandoff('${'前' * 80}$newline林舟推门。',
            tailChars: 8), '林舟推门。');
        expect(LlmContextBrief.sceneHandoff('前文$newline林舟推门。门锁坏了。',
            tailChars: 10), '林舟推门。门锁坏了。');
      }
    });

    test('零长度返回空串，负数明确报错', () {
      expect(LlmContextBrief.sceneHandoff('正文', tailChars: 0), isEmpty);
      expect(() => LlmContextBrief.sceneHandoff('正文', tailChars: -1),
          throwsRangeError);
    });

    test('截尾不劈开 emoji 等字素（grapheme 安全）', () {
      final String body = '🔥' * 80; // 160 个 UTF-16 码元，全部是代理对。
      final String handoff = LlmContextBrief.sceneHandoff(body, tailChars: 30);
      // 30 个字素 × 2 码元 = 60 码元，且必须是完整 emoji 数（无半个代理对）。
      expect(handoff.characters.length, 30);
      expect(handoff, '🔥' * 30);
    });

    test('尾部无句末标点时保留原文（宁多勿缺）', () {
      final String text = '开头一句。${'a' * 200}';
      final String handoff = LlmContextBrief.sceneHandoff(text, tailChars: 50);
      expect(handoff, 'a' * 50);
      // 截断点恰好落在标点后时不能返回空串。
      final String dotted = '前文。${'x' * 10}。${'y' * 100}';
      final String handoff2 = LlmContextBrief.sceneHandoff(dotted, tailChars: 12);
      expect(handoff2, isNotEmpty);
    });
  });
}
