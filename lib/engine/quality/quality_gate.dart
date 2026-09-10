/// 统一质检网关（QualityGate）——三套本地质检的公共契约。
///
/// 项目里原本有三套各自为政的质检：
/// - [NovelQualityChecker]：文笔卫生（AI 痕/重复/节奏/五感/对白）
/// - `FanqieGateChecker`：番茄过审闸门（合规红线/首屏/四件套/水段）
/// - `PipelineQa`：商业向指标（爽点/变强异动/章末钩子/统计层 AI 腔）
///
/// 三者报告结构互不相同，UI 无法并列展示，组合检查要各写一遍。
/// 本文件定义统一的问题模型（[QualityGateIssue]）、报告模型
/// （[QualityGateReport]）与网关接口（[QualityGate]）；
/// 组合实现在 `ai_pipeline/services/composite_quality_gate.dart`
/// （放在 ai_pipeline 是因为其依赖 `PipelineQa`，保持 engine 不反向依赖）。
library;

/// 质检来源（哪套检查器报出的问题）。
enum QualitySource {
  /// 文笔卫生（NovelQualityChecker）。
  novelHygiene,

  /// 番茄过审闸门（FanqieGateChecker）。
  fanqieGate,

  /// 商业向规则指标（PipelineQa）。
  pipelineRules;

  /// 展示名。
  String get label => switch (this) {
        QualitySource.novelHygiene => '文笔卫生',
        QualitySource.fanqieGate => '过审闸门',
        QualitySource.pipelineRules => '商业指标',
      };
}

/// 问题严重级别（决定 UI 呈现与是否阻断）。
enum QualitySeverity {
  /// 仅提示。
  note,

  /// 警告（建议修改）。
  warn,

  /// 阻断（结构性问题，建议重写/定点修）。
  blocking,

  /// 一票否决（合规红线）。
  veto;

  /// 展示名。
  String get label => switch (this) {
        QualitySeverity.note => '建议',
        QualitySeverity.warn => '修改',
        QualitySeverity.blocking => '重写',
        QualitySeverity.veto => '红线',
      };
}

/// 统一质检问题。
class QualityGateIssue {
  /// 构造问题。
  const QualityGateIssue({
    required this.source,
    required this.type,
    required this.message,
    required this.severity,
  });

  /// 来源检查器。
  final QualitySource source;

  /// 类别（首屏/对白/AI味/红线/结构…）。
  final String type;

  /// 人读说明。
  final String message;

  /// 严重级别。
  final QualitySeverity severity;

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source.name,
        'type': type,
        'message': message,
        'severity': severity.name,
      };

  /// 反序列化。
  factory QualityGateIssue.fromJson(Map<String, dynamic> json) {
    return QualityGateIssue(
      source: QualitySource.values.firstWhere(
        (QualitySource e) => e.name == json['source'],
        orElse: () => QualitySource.pipelineRules,
      ),
      type: json['type'] as String? ?? '',
      message: json['message'] as String? ?? '',
      severity: QualitySeverity.values.firstWhere(
        (QualitySeverity e) => e.name == json['severity'],
        orElse: () => QualitySeverity.note,
      ),
    );
  }

  @override
  String toString() => '[${severity.label}][${source.label}] $type：$message';
}

/// 统一质检报告。
class QualityGateReport {
  /// 构造报告。
  const QualityGateReport({
    required this.totalWords,
    required this.score,
    required this.pass,
    required this.issues,
    required this.metrics,
    required this.summaries,
  });

  /// 正文字数。
  final int totalWords;

  /// 综合评分（0~100，越高越好）。
  final double score;

  /// 是否达线（无红线且分数达标）。
  final bool pass;

  /// 全部问题（跨检查器汇总）。
  final List<QualityGateIssue> issues;

  /// 命名指标（各检查器的关键数值，供 UI 表格展示）。
  final Map<String, double> metrics;

  /// 各来源检查器的一句话摘要。
  final List<String> summaries;

  /// 需要动手的问题（排除「仅建议」）。
  List<QualityGateIssue> get blockingIssues => issues
      .where((QualityGateIssue e) =>
          e.severity == QualitySeverity.warn ||
          e.severity == QualitySeverity.blocking ||
          e.severity == QualitySeverity.veto)
      .toList();

  /// 一句话摘要。
  String get summary {
    if (issues.any((QualityGateIssue e) => e.severity == QualitySeverity.veto)) {
      return '命中合规红线，需人工复核';
    }
    return '${score.toStringAsFixed(0)} 分${pass ? ' 达线' : ''}，'
        '${blockingIssues.length} 项需处理';
  }

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'totalWords': totalWords,
        'score': score,
        'pass': pass,
        'issues': issues.map((QualityGateIssue e) => e.toJson()).toList(),
        'metrics': metrics,
        'summaries': summaries,
      };

  /// 反序列化。
  factory QualityGateReport.fromJson(Map<String, dynamic> json) {
    return QualityGateReport(
      totalWords: json['totalWords'] as int? ?? 0,
      score: (json['score'] as num?)?.toDouble() ?? 0,
      pass: json['pass'] as bool? ?? false,
      issues: (json['issues'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(QualityGateIssue.fromJson)
          .toList(),
      metrics: (json['metrics'] as Map<String, dynamic>? ?? const {})
          .map((String k, dynamic v) => MapEntry<String, double>(
              k, (v as num).toDouble())),
      summaries: (json['summaries'] as List<dynamic>? ?? const [])
          .map((dynamic e) => e.toString())
          .toList(),
    );
  }
}

/// 统一质检网关接口。
///
/// 契约：
/// 1. 纯本地规则计算（零 LLM 调用、零网络），可安全在 UI 线程短文本调用；
/// 2. 返回统一 [QualityGateReport]，不抛业务异常（检查器内部自兜底）；
/// 3. [QualityGateReport.score] 与各来源原始分的关系在实现类文档中说明。
abstract interface class QualityGate {
  /// 对单章正文执行统一质检。
  ///
  /// [prevContent] 用于跨章自我重复比对（可空）；
  /// [chapterIndex] 章号（影响个别章节相关规则）。
  QualityGateReport check(
    String text, {
    String prevContent = '',
    int chapterIndex = 1,
  });
}