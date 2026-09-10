import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/writing_guidelines.dart';

/// WritingGuidelines 静态指令库单元测试
///
/// 覆盖：各指令模块非空、包含预期关键词、systemPrompt 组装完整。

void main() {
  group('WritingGuidelines.writerPersona', () {
    test('非空且包含作家关键词', () {
      final text = WritingGuidelines.writerPersona;
      expect(text, isNotEmpty);
      expect(text, contains('作家'));
    });
  });

  group('WritingGuidelines.coreTechniques', () {
    test('非空且包含核心技法', () {
      final text = WritingGuidelines.coreTechniques;
      expect(text, isNotEmpty);
      expect(text, contains('核心技法'));
      expect(text, contains('展示而非陈述'));
      expect(text, contains('具体战胜抽象'));
      expect(text, contains('对话即交锋'));
      expect(text, contains('五感轮换'));
      expect(text, contains('节奏张弛'));
      expect(text, contains('结尾留钩'));
    });
  });

  group('WritingGuidelines.antiAiTone', () {
    test('非空且包含反 AI 腔关键词', () {
      final text = WritingGuidelines.antiAiTone;
      expect(text, isNotEmpty);
      expect(text, contains('反AI腔'));
      expect(text, contains('仿佛'));
      expect(text, contains('禁用'));
    });
  });

  group('WritingGuidelines.outputRules', () {
    test('非空且包含输出规则', () {
      final text = WritingGuidelines.outputRules;
      expect(text, isNotEmpty);
      expect(text, contains('输出规则'));
      expect(text, contains('正文'));
    });
  });

  group('WritingGuidelines.systemPrompt', () {
    test('包含所有子模块', () {
      final prompt = WritingGuidelines.systemPrompt;
      expect(prompt, contains('作家'));
      expect(prompt, contains('核心技法'));
      expect(prompt, contains('反AI腔'));
      expect(prompt, contains('输出规则'));
    });

    test('每次调用返回相同内容', () {
      final a = WritingGuidelines.systemPrompt;
      final b = WritingGuidelines.systemPrompt;
      expect(a, b);
    });
  });

  group('WritingGuidelines.fanqieGate', () {
    test('包含番茄四件套与移动端硬门槛', () {
      final text = WritingGuidelines.fanqieGate;
      expect(text, contains('番茄过审硬门槛'));
      expect(text, contains('25%~45%'));
      expect(text, contains('每章四件套'));
      expect(text, contains('首屏 300 字'));
      expect(text, contains('可替换性'));
    });

    test('systemPrompt 已组装进 fanqieGate', () {
      expect(WritingGuidelines.systemPrompt, contains('番茄过审硬门槛'));
    });

    test('通用技法不再含修仙专属意象（防题材渗漏）', () {
      expect(WritingGuidelines.coreTechniques.contains('丹田'), isFalse);
      expect(WritingGuidelines.coreTechniques.contains('周天'), isFalse);
      expect(WritingGuidelines.antiAiTone.contains('三件套'), isTrue);
      // 下放而非删掉：玄幻专属仍保留这套意象
      expect(WritingGuidelines.genreGuidance('玄幻').contains('丹田'), isTrue);
    });

    test('非修仙题材拿不到修仙意象', () {
      for (final g in ['体育', '科幻', '都市', 'jingsai', 'kehuan']) {
        final t = WritingGuidelines.genreGuidance(g);
        expect(t.contains('丹田'), isFalse, reason: '$g 不应含修仙意象');
        expect(t.contains('周天'), isFalse, reason: '$g 不应含修仙意象');
      }
    });
  });

  group('WritingGuidelines.structureRequirements', () {
    test('非空且包含结构要求', () {
      final text = WritingGuidelines.structureRequirements;
      expect(text, isNotEmpty);
      expect(text, contains('结构要求'));
      expect(text, contains('开场'));
      expect(text, contains('冲突'));
      expect(text, contains('钩子'));
    });
  });
}
