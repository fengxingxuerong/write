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
