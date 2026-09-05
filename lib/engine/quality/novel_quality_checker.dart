import 'package:characters/characters.dart';

/// 小说生成结果的自动化质量检查器。
///
/// 纯本地算法实现（无 LLM 调用、无网络），检测以下维度：
/// 1. AI 囷痕：典型 AI 句式/万能描写/空泛总结
/// 2. 重复啰嗦：相邻段落/句子级别的重复用词
/// 3. 节奏失衡：某段过长或过短
/// 4. 五感覆盖：视觉外感官描写占比
/// 5. 对话占比：对话行数占总行数的比例
///
/// 适合用于「生成后自动质检 → 决定是否需要 LLM 润色」的决策依据。
class NovelQualityChecker {
  /// 私有构造，使用静态方法即可。
  const NovelQualityChecker._();

  /// 对 [text] 执行全套质检，返回 [QualityReport]。
  static QualityReport check(String text) {
    return QualityReport(
      aiEchoScore: _calcAiEchoScore(text),
      repetitionScore: _calcRepetitionScore(text),
      rhythmScore: _calcRhythmScore(text),
      sensoryScore: _calcSensoryScore(text),
      dialogueRatio: _calcDialogueRatio(text),
      totalWords: _countWords(text),
      hardViolations: _findHardViolations(text),
    );
  }

  /// 硬伤数量超过阈值则标记需要 LLM 润色。
  static bool needsPolish(QualityReport report) {
    return report.aiEchoScore > 0.02 || // 每 100 字囷痕 > 2 处
        report.repetitionScore > 0.10 || // 段落重复率 > 10%
        report.hardViolations.length >= 3;
  }

  /// ============================================================
  /// 1. AI 囷痕密度（命中数 / 正文字数 × 100）
  /// ============================================================
  static double _calcAiEchoScore(String text) {
    if (text.isEmpty) return 0.0;
    int hits = 0;
    for (final _AiEchoPattern p in _aiEchoPatterns) {
      hits += p.allMatches(text).length;
    }
    final int words = _countWords(text);
    return words == 0 ? 0.0 : (hits / words) * 100.0;
  }

  /// 查找所有硬伤命中详情。
  static List<QualityViolation> _findHardViolations(String text) {
    final List<QualityViolation> list = <QualityViolation>[];
    for (final _AiEchoPattern p in _aiEchoPatterns) {
      for (final RegExpMatch m in p.allMatches(text)) {
        list.add(QualityViolation(
          type: QualityViolationType.aiEcho,
          description: p.description,
          position: m.start,
          matchedText: m.group(0) ?? '',
        ));
      }
    }
    // 相邻段落重复检测（相似度 > 0.7 视为留痕）
    final List<String> paragraphs =
        text.split('\n\n').where((String p) => p.trim().length > 10).toList();
    for (int i = 1; i < paragraphs.length; i++) {
      final double sim = _similarity(paragraphs[i - 1], paragraphs[i]);
      if (sim > 0.7) {
        list.add(QualityViolation(
          type: QualityViolationType.repetition,
          description:
              '与上一段高度重复（相似度 ${(sim * 100).toStringAsFixed(0)}%）',
          position: text.indexOf(paragraphs[i]),
          matchedText: paragraphs[i].substring(
              0, paragraphs[i].length > 30 ? 30 : paragraphs[i].length),
        ));
      }
    }
    return list;
  }

  /// ============================================================
  /// 2. 相邻段落平均相似度
  /// ============================================================
  static double _calcRepetitionScore(String text) {
    final List<String> paragraphs =
        text.split('\n\n').where((String p) => p.trim().length > 10).toList();
    if (paragraphs.length < 2) return 0.0;

    double totalSim = 0.0;
    int pairs = 0;
    for (int i = 1; i < paragraphs.length; i++) {
      totalSim += _similarity(paragraphs[i - 1], paragraphs[i]);
      pairs++;
    }
    return pairs == 0 ? 0.0 : totalSim / pairs;
  }

  /// ============================================================
  /// 3. 段落节奏失衡率（段落词数不在 30~400 之间）
  /// ============================================================
  static double _calcRhythmScore(String text) {
    final List<String> paragraphs =
        text.split('\n\n').where((String p) => p.trim().isNotEmpty).toList();
    if (paragraphs.isEmpty) return 0.0;

    int badCount = 0;
    for (final String p in paragraphs) {
      final int len = _countWords(p);
      if (len < 30 || len > 400) badCount++;
    }
    return badCount / paragraphs.length;
  }

  /// ============================================================
  /// 4. 非视觉感官占比
  /// ============================================================
  static double _calcSensoryScore(String text) {
    final RegExp nonVisual = RegExp(
      r'闻[到见]|气[味息]|听[到见]|声[音]|触[感]|摸[上去起来]|冰[冷凉]'
      r'|滚[烫]|疼[痛]|寒冷|温暖|湿润|干燥|柔软|坚硬|芬芳|恶臭',
      unicode: true,
    );
    final int hits = nonVisual.allMatches(text).length;
    final int words = _countWords(text);
    return words == 0 ? 0.0 : (hits / words) * 100.0;
  }

  /// ============================================================
  /// 5. 对话占比（含 「」"" 的行）
  /// ============================================================
  static double _calcDialogueRatio(String text) {
    final List<String> lines = text.split(RegExp(r'[\n]'));
    if (lines.isEmpty) return 0.0;

    final RegExp dialogueLine = RegExp(r'["「『"].+?["」』"]');
    int count = 0;
    for (final String l in lines) {
      if (dialogueLine.hasMatch(l.trim())) count++;
    }
    return count / lines.length;
  }

  /// ============================================================
  /// 工具方法
  /// ============================================================

  /// 统计中文字符数（按字符而非字节）。
  static int _countWords(String text) {
    return text.characters.where((String c) {
      final int code = c.codeUnitAt(0);
      return (code >= 0x4E00 && code <= 0x9FFF) || // CJK
          (code >= 0x30 && code <= 0x39); // 数字
    }).length;
  }

  /// 两个字符串的 3-gram 相似度（0~1），轻量级近似。
  ///
  /// 为避免中文高频停用字（的/了/是/在/他/她/我/你/一/不/就/都/也）导致
  /// 「任何两段都看着像」的虚警，构建 gram 时跳过纯停用字。
  static double _similarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    final String shortStr = a.length <= b.length ? a : b;

    if (shortStr.length < 3) return 0.0;
    final Set<String> grams = <String>{};
    for (int i = 0; i <= shortStr.length - 3; i++) {
      final String g = shortStr.substring(i, i + 3);
      // 过滤：gram 中全部字符都是停用字 → 跳过高频噪声
      if (_isStopGram(g)) continue;
      grams.add(g);
    }
    if (grams.isEmpty) return 0.0;
    final String longStr = a.length <= b.length ? b : a;
    int hitGrams = 0;
    for (final String g in grams) {
      if (longStr.contains(g)) hitGrams++;
    }
    return hitGrams / grams.length;
  }

  /// 3-gram 是否由纯中文停用字构成（这些 gram 无判别力，仅反映文本自然相似度）。
  static final Set<String> _stopChars = <String>{
    '的', '了', '是', '在', '他', '她', '我', '你', '一', '不',
    '就', '都', '也', '这', '那', '有', '和', '与', '而', '但',
    '却', '又', '很', '到', '说', '要', '会', '能', '可', '得',
  };

  /// 检查 [gram] 是否全部由停用字构成（true = 应跳过）。
  static bool _isStopGram(String gram) {
    for (final String ch in gram.characters) {
      if (!_stopChars.contains(ch)) return false;
    }
    return true;
  }

  /// ============================================================
  /// AI 囷痕正则模式列表
  /// ============================================================

  static final List<_AiEchoPattern> _aiEchoPatterns = <_AiEchoPattern>[
    // 万能描写
    _AiEchoPattern('嘴角勾起一抹'),
    _AiEchoPattern('嘴角微微上扬'),
    _AiEchoPattern('眼底闪过一丝'),
    _AiEchoPattern('唇角勾勒出'),
    _AiEchoPattern('空气凝固'),
    _AiEchoPattern('空气仿佛凝固'),
    _AiEchoPattern('时间仿佛静止'),
    _AiEchoPattern('心跳加速'),
    _AiEchoPattern('深吸一口气'),
    _AiEchoPattern('长长地舒了一口气'),
    _AiEchoPattern('眼神变得凌厉'),
    _AiEchoPattern('目光如炬'),
    _AiEchoPattern('微微一笑'),
    _AiEchoPattern('大手一挥'),
    _AiEchoPattern('眼中闪过'),
    _AiEchoPattern('心里五味杂陈'),
    _AiEchoPattern('喉咙发紧'),
    _AiEchoPattern('手指微颤'),
    _AiEchoPattern('身体僵硬'),
    _AiEchoPattern('不寒而栗'),
    _AiEchoPattern('汗毛倒竖'),
    // 空泛总结
    _AiEchoPattern('命运的车轮'),
    _AiEchoPattern('人生的轨迹'),
    _AiEchoPattern('一切都将改变'),
    _AiEchoPattern('悄然发生了变化'),
    // 文艺腔
    _AiEchoPattern('不得而知'),
    _AiEchoPattern('尽在不言中'),
    _AiEchoPattern('宛如梦境'),
    _AiEchoPattern('仿佛置身'),
    _AiEchoPattern('恍惚间'),
    _AiEchoPattern('不知何时'),
    _AiEchoPattern('恍如隔世'),
    _AiEchoPattern('时光荏苒'),
    _AiEchoPattern('岁月如歌'),
    // 通用模板
    _AiEchoPattern('莫名[的 ]伤痛'),
    _AiEchoPattern('一种[莫名 ][的 ]情绪'),
    _AiEchoPattern('不知[道 ][什么 ][原因 ]'),
    _AiEchoPattern('说[不 ][出 ][的 ]'),
    // 对话/引用滥用（常见的 LLM 开场/结尾）
    _AiEchoPattern('想到这里'),
    _AiEchoPattern('话音刚落'),
    _AiEchoPattern('话虽如此'),
    _AiEchoPattern('然而事实上'),
    _AiEchoPattern('不可否认'),
    _AiEchoPattern('毋庸置疑'),
  ];
}

/// AI 囷痕的关键词匹配（子串匹配，无复杂正则避免运行时开销）。
class _AiEchoPattern {
  // description 由 _describe 动态计算，无法 const 化，故使用普通构造。
  // ignore: prefer_const_constructors_in_immutables
  _AiEchoPattern(String this.keyword)
      : regex = null,
        description = _describe(keyword);

  /// 直接子串关键词（匹配更快）。
  final String? keyword;

  /// 复杂正则（仅特殊模式需要）。
  final RegExp? regex;

  /// 人类可读的描述。
  final String description;

  /// 执行匹配。
  Iterable<RegExpMatch> allMatches(String text) sync* {
    if (keyword != null) {
      final RegExp r = RegExp(RegExp.escape(keyword!), unicode: true);
      yield* r.allMatches(text);
    } else if (regex != null) {
      yield* regex!.allMatches(text);
    }
  }

  /// 根据关键词生成描述。
  static String _describe(String kw) {
    if (kw.startsWith('嘴角') || kw.startsWith('唇角') || kw.startsWith('眼底') || kw.startsWith('眼神') || kw.startsWith('目光')) {
      return '万能表情/眼神「$kw」';
    }
    if (kw == '空气凝固' || kw == '空气仿佛凝固' || kw == '时间仿佛静止' || kw == '心跳加速' || kw == '深吸一口气' || kw == '长长地舒了一口气') {
      return '万能身体反应「$kw」';
    }
    if (kw.contains('命运') || kw.contains('轨迹') || kw.contains('改变')) {
      return '空泛总结「$kw」';
    }
    if (kw == '不得而知' || kw == '尽在不言中' || kw == '宛如梦境' || kw == '恍如隔世' || kw == '时光荏苒' || kw == '岁月如歌') {
      return '文艺腔结尾「$kw」';
    }
    if (kw.contains('莫名') || kw.contains('说不') || kw.contains('不知')) {
      return '通用模糊表达「$kw」';
    }
    return 'AI 高频句式「$kw」';
  }
}

/// 质量违规详情。
class QualityViolation {
  /// 构造详情。
  const QualityViolation({
    required this.type,
    required this.description,
    required this.position,
    required this.matchedText,
  });

  /// 违规类型。
  final QualityViolationType type;

  /// 问题描述（人类可读）。
  final String description;

  /// 在原文中的字符偏移量。
  final int position;

  /// 匹配到的原文片段。
  final String matchedText;
}

/// 违规类型枚举。
enum QualityViolationType {
  /// AI 万能描写 / 空泛总结。
  aiEcho,

  /// 段落间高度重复。
  repetition,

  /// 未闭合标点 / 格式错误。
  formatting,
}

/// 质检结果报告。
class QualityReport {
  /// 构造报告。
  const QualityReport({
    required this.aiEchoScore,
    required this.repetitionScore,
    required this.rhythmScore,
    required this.sensoryScore,
    required this.dialogueRatio,
    required this.totalWords,
    required this.hardViolations,
  });

  /// AI 囷痕密度（每 100 字命中数）。
  final double aiEchoScore;

  /// 相邻段落重复率（0~1）。
  final double repetitionScore;

  /// 段落节奏失衡率（0~1）。
  final double rhythmScore;

  /// 非视觉感官占比（0~100）。
  final double sensoryScore;

  /// 对话占比（0~1）。
  final double dialogueRatio;

  /// 总正文字数。
  final int totalWords;

  /// 具体违规详情列表。
  final List<QualityViolation> hardViolations;

  /// 综合质量评分（0~100，越高越好）。
  double get overallScore {
    final double echoPenalty = (aiEchoScore * 20).clamp(0, 30);
    final double repPenalty = (repetitionScore * 30).clamp(0, 25);
    final double rhythmPenalty = (rhythmScore * 15).clamp(0, 15);
    return (100 - echoPenalty - repPenalty - rhythmPenalty).clamp(0, 100);
  }

  /// 是否需要 LLM 润色。
  bool get needsPolish => NovelQualityChecker.needsPolish(this);

  /// 人类可读摘要。
  String get summary {
    return '综合评分 ${overallScore.toStringAsFixed(0)} | '
        '囷痕 ${aiEchoScore.toStringAsFixed(2)}% | '
        '对话占比 ${(dialogueRatio * 100).toStringAsFixed(0)}% | '
        '违规 ${hardViolations.length} 处';
  }
}
