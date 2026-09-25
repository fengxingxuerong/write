import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/engine/quality/novel_consistency_checker.dart';
import 'package:novel_writer/engine/quality/novel_quality_checker.dart';
import 'package:novel_writer/engine/quality/token_tier.dart';
import 'package:novel_writer/features/generate/generate_viewmodel.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 产生典型 AI 囷痕的假正文。
String _aiEchoContent() {
  return '他深吸一口气，看着前方。嘴角勾起一抹笑意。'
      '眼底闪过一丝精光，空气仿佛凝固了。命运的车轮开始转动。'
      '他知道自己的人生轨迹已经改变。';
}

void main() {
  group('QualityCheckNote', () {
    test('summary 显示评分变化', () {
      const QualityCheckNote note = QualityCheckNote(
        beforeScore: 60,
        afterScore: 85,
        issueCount: 5,
        polished: true,
      );
      expect(note.summary, contains('5'));
      expect(note.summary, contains('60'));
      expect(note.summary, contains('85'));
    });

    test('未润色时 summary 仅显示评分', () {
      const QualityCheckNote note = QualityCheckNote(
        beforeScore: 95,
        afterScore: 95,
        issueCount: 1,
        polished: false,
      );
      expect(note.summary, contains('质检通过'));
      expect(note.summary, contains('95'));
    });
  });

  group('QualityCheckResult', () {
    test('empty 工厂构造返回原文且 polished=false', () {
      final QualityCheckResult r = QualityCheckResult.empty('原始正文');
      expect(r.note, isNull);
      expect(r.polishedContent, '原始正文');
      expect(r.polished, isFalse);
    });

    test('正常构造保存 note 和 polishedContent', () {
      const QualityCheckNote note = QualityCheckNote(
        beforeScore: 70,
        afterScore: 90,
        issueCount: 3,
        polished: true,
      );
      const QualityCheckResult r = QualityCheckResult(
        note: note,
        polishedContent: '润色后的正文',
      );
      expect(r.note, note);
      expect(r.polishedContent, '润色后的正文');
      expect(r.polished, isTrue);
    });
  });

  group('GenerateState qualityNote 字段', () {
    test('初始状态 qualityNote 为 null', () {
      const GenerateState s = GenerateState();
      expect(s.qualityNote, isNull);
    });

    test('copyWith 可设置 qualityNote', () {
      const QualityCheckNote note = QualityCheckNote(
        beforeScore: 80,
        afterScore: 80,
        issueCount: 0,
        polished: false,
      );
      const GenerateState s = GenerateState(qualityNote: note);
      expect(s.qualityNote, note);
    });

    test('clearQualityNote 可清除字段', () {
      const QualityCheckNote note = QualityCheckNote(
        beforeScore: 80,
        afterScore: 80,
        issueCount: 0,
        polished: false,
      );
      const GenerateState s0 = GenerateState(qualityNote: note);
      final GenerateState s1 = s0.copyWith(clearQualityNote: true);
      expect(s1.qualityNote, isNull);
    });
  });

  group('GenerateState 字段与 clear 开关', () {
    test('copyWith 设置生成进度、章节、记忆和预览字段', () {
      const QualityCheckNote note = QualityCheckNote(
        beforeScore: 60,
        afterScore: 70,
        issueCount: 2,
        polished: false,
      );
      const GenerateState initial = GenerateState();
      final GenerateState updated = initial.copyWith(
        isGenerating: true,
        progress: 0.4,
        stage: '写第 2 章',
        error: '临时错误',
        generatedChapter: Chapter(
          id: 'c1',
          novelId: 'n1',
          title: '第1章',
          order: 0,
          content: '正文',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
        memoryNote: 'AI 已记忆：新增 1 个角色',
        memoryPending: true,
        previewText: '流式预览',
        qualityNote: note,
        consistencyReport: const ConsistencyReport(),
      );

      expect(updated.isGenerating, isTrue);
      expect(updated.progress, 0.4);
      expect(updated.stage, '写第 2 章');
      expect(updated.error, '临时错误');
      expect(updated.generatedChapter?.id, 'c1');
      expect(updated.memoryNote, contains('新增 1 个角色'));
      expect(updated.memoryPending, isTrue);
      expect(updated.previewText, '流式预览');
      expect(updated.qualityNote, note);
      expect(updated.consistencyReport, isNotNull);
    });

    test('clear* 开关可单独清掉章节、预览、质检和一致性报告', () {
      final GenerateState seeded = GenerateState(
        generatedChapter: Chapter(
          id: 'c1',
          novelId: 'n1',
          title: '第1章',
          order: 0,
          content: '正文',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
        previewText: '旧预览',
        qualityNote: const QualityCheckNote(
          beforeScore: 10,
          afterScore: 20,
          issueCount: 1,
          polished: false,
        ),
        consistencyReport: const ConsistencyReport(),
        isGenerating: true,
        progress: 0.9,
        stage: '上一任务',
      );

      final GenerateState cleared = seeded.copyWith(
        stage: '准备生成',
        error: null,
        clearChapter: true,
        clearPreview: true,
        clearQualityNote: true,
        clearConsistencyReport: true,
      );

      expect(cleared.generatedChapter, isNull);
      expect(cleared.previewText, isNull);
      expect(cleared.qualityNote, isNull);
      expect(cleared.consistencyReport, isNull);
      expect(cleared.stage, '准备生成');
      expect(cleared.isGenerating, isTrue);
      expect(cleared.progress, 0.9);
    });
  });

  group('NovelQualityChecker 囷痕检测', () {
    test('AI 囷痕正文触发 needsPolish', () {
      final QualityReport r = NovelQualityChecker.check(_aiEchoContent());
      expect(r.hardViolations, isNotEmpty);
      expect(r.needsPolish, isTrue);
    });

    test('干净正文不触发润色', () {
      const String good =
          '张三走进院子，坐在石桌旁。第三级台阶上长着青苔，'
          '袖口磨出了毛边。远处传来砍柴的声音，混杂着松脂的气味。';
      final QualityReport r = NovelQualityChecker.check(good);
      expect(r.hardViolations, isEmpty);
      expect(r.needsPolish, isFalse);
    });
  });

  group('TokenTier 集成', () {
    test('SensNova 模型走 reasoning 等级', () {
      const LlmConfig config = LlmConfig(model: 'sensenova-6.7-flash-lite');
      expect(TokenTier.fromModel(config.model), TokenTier.reasoning);
      expect(TokenBudget.needsExtraThinkingFlag(config), isTrue);
    });

    test('推理模型预算是标准模型约 2 倍', () {
      final int standard = TokenBudget.calculate(
        targetWords: 3000,
        tier: TokenTier.standard,
        maxTokens: 32000,
      );
      final int reasoning = TokenBudget.calculate(
        targetWords: 3000,
        tier: TokenTier.reasoning,
        maxTokens: 32000,
      );
      expect(reasoning ~/ standard, 2);
    });
  });
}
