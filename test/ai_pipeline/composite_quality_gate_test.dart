import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/composite_quality_gate.dart';
import 'package:novel_writer/engine/quality/quality_gate.dart';

/// CompositeQualityGate 组合质检网关测试。
void main() {
  const CompositeQualityGate gate = CompositeQualityGate();

  /// 生成约 2200 字的"合格"正文：对白充足、末尾带钩子、含爽点词。
  String goodText() {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 40; i++) {
      b.writeln('陈默盯着眼前的对手，怒吼道：「这一局，我不会再退！」');
      b.writeln('对方脸色铁青，一时哑口无言，围观众人也目瞪口呆。');
      b.writeln('灵力自丹田涌入经脉，温热流转，他感到修为又精进了一层。');
    }
    b.write('就在这时，门外忽然传来一阵急促的脚步声——来的人，竟然是他。');
    return b.toString();
  }

  group('CompositeQualityGate', () {
    test('空正文 → 0 分、不达线、含 blocking 结构问题', () {
      final QualityGateReport r = gate.check('');
      expect(r.totalWords, 0);
      expect(r.score, 0);
      expect(r.pass, isFalse);
      expect(
        r.issues.any((QualityGateIssue e) =>
            e.source == QualitySource.fanqieGate &&
            e.severity == QualitySeverity.blocking),
        isTrue,
      );
    });

    test('合格长文 → 报告结构齐全、分数在区间内', () {
      final QualityGateReport r = gate.check(goodText());
      expect(r.totalWords, greaterThan(1500));
      expect(r.score, inInclusiveRange(0, 100));
      expect(r.metrics.containsKey('novelOverall'), isTrue);
      expect(r.metrics.containsKey('fanqieScore'), isTrue);
      expect(r.metrics.containsKey('thrillPerK'), isTrue);
      expect(r.metrics.containsKey('dialogueRatio'), isTrue);
      expect(r.summaries, isNotEmpty);
    });

    test('合格长文不应有 veto 红线', () {
      final QualityGateReport r = gate.check(goodText());
      expect(
        r.issues.where((QualityGateIssue e) => e.severity == QualitySeverity.veto),
        isEmpty,
      );
    });

    test('教唆语境红线 → veto、分数上限 60、不达线', () {
      final QualityGateReport r = gate.check(
        '${goodText()}\n本文教你制作炸药的方法，步骤如下。',
      );
      expect(
        r.issues.any((QualityGateIssue e) =>
            e.severity == QualitySeverity.veto && e.type == '红线'),
        isTrue,
      );
      expect(r.score, lessThanOrEqualTo(60));
      expect(r.pass, isFalse);
    });

    test('AI 痕文本 → 文笔卫生来源问题', () {
      final QualityGateReport r = gate.check(
        '${goodText()}\n他的嘴角勾起一抹弧度，眼底闪过一丝精光，空气仿佛凝固了。',
      );
      expect(
        r.issues.any((QualityGateIssue e) =>
            e.source == QualitySource.novelHygiene && e.type == 'AI痕'),
        isTrue,
      );
    });

    test('blockingIssues 排除纯建议', () {
      final QualityGateReport r = gate.check(goodText());
      // 所有 blockingIssues 都是 warn/blocking/veto，无 note。
      expect(
        r.blockingIssues
            .every((QualityGateIssue e) => e.severity != QualitySeverity.note),
        isTrue,
      );
    });

    test('报告序列化往返一致', () {
      final QualityGateReport r = gate.check(goodText());
      final QualityGateReport restored =
          QualityGateReport.fromJson(r.toJson());
      expect(restored.totalWords, r.totalWords);
      expect(restored.score, r.score);
      expect(restored.pass, r.pass);
      expect(restored.issues.length, r.issues.length);
      expect(restored.metrics.length, r.metrics.length);
      expect(restored.summaries, r.summaries);
    });

    test('问题序列化往返一致', () {
      const QualityGateIssue issue = QualityGateIssue(
        source: QualitySource.pipelineRules,
        type: '爽点',
        message: '测试问题',
        severity: QualitySeverity.warn,
      );
      final QualityGateIssue restored =
          QualityGateIssue.fromJson(issue.toJson());
      expect(restored.source, QualitySource.pipelineRules);
      expect(restored.type, '爽点');
      expect(restored.severity, QualitySeverity.warn);
      expect(restored.toString(), contains('爽点'));
    });

    test('summary 文案区分红线与普通情况', () {
      final QualityGateReport bad = gate.check(
        '${goodText()}\n教你制作炸药的方法。',
      );
      expect(bad.summary, contains('红线'));

      final QualityGateReport r = gate.check(goodText());
      expect(r.summary, isNotEmpty);
    });
  });
}