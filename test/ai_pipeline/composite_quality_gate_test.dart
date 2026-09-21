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

  /// AI 腔样板文本：等长句 + 高「的」密度 + 叠词 + 连接词起句 + 比喻 +
  /// 单句成段 + 身体反应（「发烫」属变强异动词，用于含蓄变强流分支）。
  String aiHeavyText() {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 6; i++) {
      b.writeln('然而他的瞳的孔的神色在灯下微微的变了。'
          '因此他的心的底的念头在这一刻轻轻的散了。'
          '于是他的肩的线的轮廓在风里缓缓的暗了。');
      b.writeln();
      b.writeln(i.isEven ? '他的眼底的光淡淡的浮起。' : '他的掌心发烫的厉害。');
      b.writeln();
      b.writeln('仿佛那张网一样。');
      b.writeln();
    }
    return b.toString();
  }

  /// 平淡超长章（无爽点/无变强异动/无钩子），末尾接三段相邻重复段。
  String blandOverlongText() {
    final String bland =
        '他沿着长街走了一程，风从巷口吹过来，带着潮气。\n\n' * 220;
    const String dup = '他站在长街的尽头，看着那盏灯，一动不动。';
    return '$bland\n\n$dup\n\n$dup\n\n$dup';
  }

  group('CompositeQualityGate 商业与结构分支', () {
    test('超长平淡章 → 结构建议走 note + 爽点过淡 + 缺钩 + 相邻段重复', () {
      final QualityGateReport r = gate.check(blandOverlongText());
      // 超长章（>3800 字）走 note 严重度分支：只建议、不算阻断项
      expect(
        r.issues.any((QualityGateIssue e) =>
            e.message.contains('偏长') && e.severity == QualitySeverity.note),
        isTrue,
      );
      // 相邻段高度重复 → 文笔卫生 repetition 违规
      expect(
        r.issues.any((QualityGateIssue e) =>
            e.source == QualitySource.novelHygiene && e.type == '重复'),
        isTrue,
      );
      // 无爽点（直白与异动双低）→ 爽点告警
      expect(
        r.issues.any((QualityGateIssue e) =>
            e.type == '爽点' && e.severity == QualitySeverity.warn),
        isTrue,
      );
      // 章末无钩子 → 钩子告警（且综合分按 -5 处理，不为负）
      expect(r.issues.any((QualityGateIssue e) => e.type == '钩子'), isTrue);
      expect(r.score, greaterThanOrEqualTo(0));
      expect(r.metrics['thrillPerK'], lessThan(0.5));
    });

    test('含蓄变强流 + 统计层 AI 腔 → 爽点降为 note，并出 AI 腔告警', () {
      final QualityGateReport r = gate.check(aiHeavyText() * 4);
      expect(r.metrics['deepAiLevel']!, greaterThanOrEqualTo(3));
      expect(r.metrics['surgePerK']!, greaterThanOrEqualTo(1.0));
      expect(
        r.issues.any((QualityGateIssue e) =>
            e.type == '爽点' && e.severity == QualitySeverity.note),
        isTrue,
      );
      expect(
        r.issues.any((QualityGateIssue e) => e.type == 'AI腔'),
        isTrue,
      );
    });
  });

}