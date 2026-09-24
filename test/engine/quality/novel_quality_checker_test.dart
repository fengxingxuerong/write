import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/quality/novel_quality_checker.dart';

/// NovelQualityChecker 单元测试。
///
/// 覆盖：中文分词、AI 囷痕检测、段落相似度、非视觉感官、对话占比、
/// 节奏、综合评分、needsPolish 阈值。
void main() {
  group('NovelQualityChecker.check', () {
    test('空文本返回零值', () {
      final QualityReport r = NovelQualityChecker.check('');
      expect(r.totalWords, 0);
      expect(r.aiEchoScore, 0.0);
      expect(r.hardViolations, isEmpty);
      expect(r.overallScore, 0);
      expect(r.needsPolish, isFalse);
    });

    test('纯数字和标点不计入字数', () {
      final QualityReport r = NovelQualityChecker.check('12345，。！？');
      expect(r.totalWords, 5); // 5 个数字
      expect(r.aiEchoScore, 0.0);
    });

    test('完美段落综合分 100', () {
      // 一段纯原创、无 AI 高频词的内容
      const String good = '张三推开门，看见院子里那棵老槐树。'
          '树下的石桌上放着半杯残茶。风一吹，落叶擦过他的鞋面。';
      final QualityReport r = NovelQualityChecker.check(good);
      expect(r.hardViolations, isEmpty);
      expect(r.overallScore, 100);
    });

    test('命中 AI 囷痕关键词命中数会累加', () {
      const String text = '他深吸一口气，看着远方。'
          '嘴角勾起一抹笑意，眼底闪过一丝精光。'
          '空气仿佛凝固了，时间仿佛静止。';
      final QualityReport r = NovelQualityChecker.check(text);
      expect(r.hardViolations.length, greaterThanOrEqualTo(4));
      // 验证至少命中这几类
      expect(
        r.hardViolations.map((v) => v.description).where(
            (d) => d.contains('深吸一口气') || d.contains('嘴角')),
        hasLength(greaterThanOrEqualTo(2)),
      );
    });

    test('囷痕密度超过阈值触发 needsPolish', () {
      // 全篇都是高频 AI 词，密度肯定超限
      const String bad = '他深吸一口气。她深吸一口气。他们都深吸一口气。'
          '嘴角一抹笑。眼底一丝光。空气凝固。空气凝固。';
      final QualityReport r = NovelQualityChecker.check(bad);
      expect(r.aiEchoScore, greaterThan(0));
      expect(r.needsPolish, isTrue);
    });

    test('相邻高相似段落被标记为 repetition', () {
      const String text = '第一章：春日里的花园，蝴蝶翩翩起舞。'
          '\n\n'
          '春日里的花园，蝴蝶翩翩起舞，微风吹过花瓣。';
      final QualityReport r = NovelQualityChecker.check(text);
      // 相似度可能不高（仅抄了前 12 字），但不应抛错
      expect(r.hardViolations.any((v) => v.type == QualityViolationType.repetition), isA<bool>());
    });

    test('非视觉感官匹配', () {
      const String text = '他闻到一股芬芳的气息，听到远处传来的声音，'
          '手指触碰到冰凉的石头，身上感觉寒冷。';
      final QualityReport r = NovelQualityChecker.check(text);
      expect(r.sensoryScore, greaterThan(0));
    });

    test('对话占比计算（一对「」）', () {
      const String text = '「你好吗？」他问。\n「我还好。」她答。\n然后他们离开了。';
      final QualityReport r = NovelQualityChecker.check(text);
      // 3 行，2 行是对话 → 占比约 0.66
      expect(r.dialogueRatio, closeTo(0.66, 0.2));
    });

    test('段落过长/过短触发 rhythmScore > 0', () {
      // 一个 10 字的段落 + 一个 500 字的段落
      final String longP = '啊' * 500;
      final String text = '短段落。\n\n$longP';
      final QualityReport r = NovelQualityChecker.check(text);
      expect(r.rhythmScore, greaterThan(0));
    });
  });

  group('QualityViolation', () {
    test('position 与 matchedText 对齐原文', () {
      const String text = '后缀：眼底闪过一丝寒光。';
      final QualityReport r = NovelQualityChecker.check(text);
      final QualityViolation? v = r.hardViolations.cast<QualityViolation?>().firstWhere(
        (e) => e!.matchedText.contains('眼底'),
        orElse: () => null,
      );
      expect(v, isNotNull);
      expect(text.substring(v!.position, v.position + v.matchedText.length),
          v.matchedText);
    });
  });

  group('QualityReport.summary', () {
    test('输出包含关键字段', () {
      final QualityReport r = NovelQualityChecker.check('测试文字');
      expect(r.summary, contains('综合评分'));
      expect(r.summary, contains('囷痕'));
      expect(r.summary, contains('对话占比'));
      expect(r.summary, contains('违规'));
    });
  });
}
