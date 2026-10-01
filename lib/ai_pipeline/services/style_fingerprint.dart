import 'dart:math' as math;

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/utils/text_index.dart';
import 'package:novel_writer/engine/quality/quality_rules.g.dart';

/// 文风指纹与统计层 AI 腔检测（从 pipeline_qa.dart 拆出，2026-10-01）。
///
/// **只做文件切分，判定逻辑与口径一字未改**：`PipelineQa` 仍保留同名静态方法
/// 薄封装转调到这里，故 20+ 处调用方（含 tool/ 下的双端对账脚本）无需改动。
///
/// 拆分的理由不是「文件太长」这么表面：pipeline_qa.dart 类头有一段 14 行的
/// 「双端同步」清单，点名 11 个 Dart 词表 + 5 个 Python 对应项——那份清单说的
/// 正是本文件里这些方法。让「清单」与「被清单约束的代码」同处一个文件，
/// 改词表时才不会漏看注释。
///
/// 依赖说明：原 `_countOccurrences` 是本类的私有方法，拆出后本文件也要用，
/// 故上移到 core/utils/text_index.dart 作为 `countOccurrences`（实现逐字照搬，
/// 非重叠计数语义不变），两处共用一份，避免为一个 8 行循环引入反向依赖。
class StyleFingerprintQa {
  const StyleFingerprintQa._();

  /// AI 高频叠词修饰（轻轻/微微/淡淡…，AI 腔典型特征）。
  static const List<String> _aiAdverbs = QualityRules.aiAdverbs;

  /// 句首连接词（AI 爱用「然而/于是/随即」起句，真人少用）。
  static const List<String> _sentenceConnectors = QualityRules.sentenceConnectors;

  /// 句式层 AI 指纹·比喻强结构正则（与 Python METAPHOR_PAT 同口径）：
  /// 只抓明喻强结构（像X一样/似的/般、跟X似的、如同X一般）+ 比喻独词；
  /// 「他像他爹」类判断句不带结构标记不计入（宁漏检勿误报）。
  static final RegExp _metaphorPattern = RegExp(
    r'像[^。！？！?，\n]{1,18}(?:一样|似的|般)'
    r'|跟[^。！？！?，\n]{1,18}(?:一样|似的)'
    r'|如同[^。！？！?，\n]{1,14}(?:一样|一般|似的)'
    r'|仿佛|宛如|好似|犹如|恰似',
  );

  /// 句式层 AI 指纹·身体反应四件套词表（与 Python BODY_REACTION_WORDS 同步）。
  /// 值来自 [QualityRules.bodyReactionWords]（rules/quality_rules.json 生成）。
  static const List<String> _bodyReactionWords = QualityRules.bodyReactionWords;

  /// 单句成段阈值：段落 ≤14 字视为单句段（喘气段）。
  static const int _singleParaMaxChars = 14;

  /// 句式指纹超标线（与 Python STYLE_FP_LIMITS 同步，2026-09-12 四本书回测校准）：
  /// 比喻 2.0 对齐写手准则承诺线；单句段 30%、身体反应 1.5 由真实成书分布定。
  /// 定位是「标记风格特征供人工复核」，非否决线。
  static const Map<String, double> styleFpLimits = <String, double>{
    'metaphorDensity': 2.0,
    'singleParaRate': 30.0,
    'bodyReactionDensity': 1.5,
  };

  /// 引号内字数占比（文风指纹用；与 Python `fanqie_review.dialogue_ratio` 同口径）。
  ///
  /// 双风格引号都算：「“”」「『』」与直角引号在网文里混用。
  ///
  /// 【口径核实 2026-09-30】曾怀疑起引号类与收引号类混配会让直引号 `"` 自配对
  /// （把 `'青'` 误算成对白），遂一度改为「同类型配对」的多正则版本。
  /// **实测四种边界情形（跨类型混排 / 奇数个直引号 / 奇数个中文引号 / 直角引号
  /// 跨句）两种口径输出完全一致**——落单的引号两边都匹配不到，故原写法并无
  /// 实际缺陷。已回退，保持单正则（与历史产物对账口径不变，也与 Python
  /// `fanqie_review.dialogue_ratio` 保持一致）。
  static final RegExp _quotedText = RegExp(r'[“"『「]([^”"』」]{1,200})[”"』」]');

  /// 对白占比（0~1）。
  static double dialogueRatioOf(String text) {
    if (text.isEmpty) return 0.0;
    final StringBuffer quoted = StringBuffer();
    for (final RegExpMatch m in _quotedText.allMatches(text)) {
      quoted.write(m.group(1));
    }
    final int total = math.max(AppConstants.countWords(text), 1);
    final double r = AppConstants.countWords(quoted.toString()) / total;
    return double.parse(r.toStringAsFixed(3));
  }

  /// 指纹项（不含 source），用于距离计算与展示。顺序与 Python 侧一致。
  static const List<String> styleFingerprintKeys = <String>[
    'sent_len_mean', 'sent_len_cv', 'dialogue_ratio', 'para_len_mean',
    'single_para_rate', 'de_density', 'adverb_density', 'connector_rate',
    'metaphor_density',
  ];

  /// 文风指纹（P1-1）：把参考文的可统计风格压成九项分布指标。
  ///
  /// 与 Python `generate_novel.style_fingerprint` **同口径同键名**（双端同源，
  /// 改一处必须同改另一处）。九项全部复用本文件既有度量（`deepAiMetrics` /
  /// `styleFingerprintMetrics` / `dialogueRatioOf`），**不另起标准**。
  ///
  /// 返回值只含分布数值，**不含任何可照抄内容**（防文风仿写滑向抄袭）。
  /// 空文本/无有效句子段落时返回全 0 指纹。
  ///
  /// 键名沿用 Python 侧的下划线风格以便双端逐值对账；`source` 只用于展示
  /// （提示词里显示「《xxx》」），不参与距离计算，故此处占位 0。
  static Map<String, double> styleFingerprint(String text) {
    final Map<String, double> zero = <String, double>{
      'source': 0,
      'words': 0,
      'sent_len_mean': 0.0,
      'sent_len_cv': 0.0,
      'dialogue_ratio': 0.0,
      'para_len_mean': 0.0,
      'single_para_rate': 0.0,
      'de_density': 0.0,
      'adverb_density': 0.0,
      'connector_rate': 0.0,
      'metaphor_density': 0.0,
    };
    if (text.isEmpty) return zero;
    final Map<String, dynamic> deep = deepAiMetrics(text);
    final List<int> lens = _splitSentences(text)
        .map((String s) => AppConstants.countWords(s))
        .where((int n) => n > 0)
        .toList();
    // 段落均长按**空行**切；单句成段占比按 \n 切（见 styleFingerprintMetrics）——
    // 两个口径不同，勿混。
    final List<int> paraLens = text
        .split(RegExp(r'\n\s*\n'))
        .map((String p) => AppConstants.countWords(p))
        .where((int n) => n > 0)
        .toList();
    if (lens.isEmpty || paraLens.isEmpty) return zero;
    final Map<String, double> fp = styleFingerprintMetrics(text);
    double mean(List<int> xs) =>
        xs.fold<int>(0, (int a, int b) => a + b) / xs.length;
    return <String, double>{
      'source': 0,
      'words': AppConstants.countWords(text).toDouble(),
      'sent_len_mean': double.parse(mean(lens).toStringAsFixed(1)),
      'sent_len_cv': (deep['sentenceCv'] as num?)?.toDouble() ?? 0.0,
      'dialogue_ratio': dialogueRatioOf(text),
      'para_len_mean': double.parse(mean(paraLens).toStringAsFixed(1)),
      'single_para_rate': fp['singleParaRate'] ?? 0.0,
      'de_density': (deep['deDensity'] as num?)?.toDouble() ?? 0.0,
      'adverb_density': (deep['adverbDensity'] as num?)?.toDouble() ?? 0.0,
      'connector_rate': (deep['connectorRate'] as num?)?.toDouble() ?? 0.0,
      'metaphor_density': fp['metaphorDensity'] ?? 0.0,
    };
  }

  /// 把文风指纹渲染成可注入写手的提示块（学分布，不抄内容）。
  ///
  /// 与 Python `style_fingerprint_block` 同结构：数字目标之外必须带「向分布靠拢」
  /// 的可执行翻译（长短句错落、段落呼吸），否则模型面对裸数字无从下手；
  /// **禁抄条款**防文风仿写变成抄袭。
  ///
  /// [words] <= 0（空/过短）返回空串——不注入无意义的零值块。
  static String styleFingerprintBlock(
    Map<String, double> fp, {
    required String source,
  }) {
    final double words = fp['words'] ?? 0;
    if (words <= 0) return '';
    double g(String k) => fp[k] ?? 0.0;
    return '\n【目标文风指纹（参考《$source》，共 ${words.round()} 字）'
        '——只学分布与节奏，禁止照抄其句子、情节与人名】\n'
        '句长：均值 ${g('sent_len_mean').toStringAsFixed(1)} 字、'
        '变异系数 ${g('sent_len_cv').toStringAsFixed(2)}'
        '（长短句错落，忌句长均匀——紧张处压短句，舒缓处放长句）\n'
        '结构：对白占比 ${(g('dialogue_ratio') * 100).round()}%｜'
        '段落均长 ${g('para_len_mean').toStringAsFixed(1)} 字｜'
        '单句成段 ${g('single_para_rate').toStringAsFixed(1)}%'
        '（段落呼吸与参考文一致）\n'
        '用词：的字密度 ${g('de_density').toStringAsFixed(1)}%｜'
        '叠词 ${g('adverb_density').toStringAsFixed(1)}/千字｜'
        '句首连接词 ${(g('connector_rate') * 100).round()}%｜'
        '比喻 ${g('metaphor_density').toStringAsFixed(2)}/千字\n'
        '写本章时让以上各项向参考文靠拢，其余仍按写作准则执行；'
        '与准则冲突时以准则为准（如对白占比 25%~45%、章末钩子硬门槛），\n'
        '文风分布只在准则允许的范围内调节。\n';
  }

  /// 两份文风指纹的归一化距离（0=同分布，越大差异越大）。
  ///
  /// 与 Python `fingerprint_distance` 同口径：每项 `|a-b|/max(|a|,|b|)` 后取均值
  /// ——比值式让量纲自归一，无需逐项定权；双零项记 0 差异（分母取 1e-9 防除零）。
  ///
  /// ⚠️ 单点噪声远大于「0.5→0.45」这类变化：真机 n=5 独立采样 σ≈0.075、极差 0.181，
  /// 故**单点永不判收敛**（定标数据见 docs/quality-enhancement-log.md 第 25 节）。
  static double fingerprintDistance(
    Map<String, double> a,
    Map<String, double> b,
  ) {
    double sum = 0;
    for (final String k in styleFingerprintKeys) {
      final double x = a[k] ?? 0.0;
      final double y = b[k] ?? 0.0;
      sum += (x - y).abs() / math.max(x.abs(), math.max(y.abs(), 1e-9));
    }
    return double.parse(
        (sum / styleFingerprintKeys.length).toStringAsFixed(3));
  }

  /// 评审证据串：与参考文的文风距离分解（与 Python `style_ev_fragment` 同款注入）。
  ///
  /// 无参考（[referenceFingerprint] 为空）返回空串——不污染评审证据。
  static String styleEvFragment(
    Map<String, double>? referenceFingerprint,
    String generated,
  ) {
    if (referenceFingerprint == null) return '';
    final Map<String, double> gen = styleFingerprint(generated);
    final double d = fingerprintDistance(referenceFingerprint, gen);
    double r(String k) => referenceFingerprint[k] ?? 0.0;
    double g(String k) => gen[k] ?? 0.0;
    return '文风：与参考文距离 ${d.toStringAsFixed(2)}'
        '（句长均值 ${g('sent_len_mean').toStringAsFixed(1)} vs 参考 '
        '${r('sent_len_mean').toStringAsFixed(1)}；'
        '对白 ${(g('dialogue_ratio') * 100).round()}% vs 参考 '
        '${(r('dialogue_ratio') * 100).round()}%；'
        '段落均长 ${g('para_len_mean').toStringAsFixed(1)} vs 参考 '
        '${r('para_len_mean').toStringAsFixed(1)}）';
  }

  /// 句式指纹三项：比喻密度 / 单句成段占比 / 身体反应密度。
  static Map<String, double> styleFingerprintMetrics(String text) {
    if (text.isEmpty) {
      return <String, double>{
        'metaphorDensity': 0.0,
        'singleParaRate': 0.0,
        'bodyReactionDensity': 0.0,
      };
    }
    final int words = AppConstants.countWords(text);
    // 1) 比喻密度（每千字）
    final int metaphorHits = _metaphorPattern.allMatches(text).length;
    final double metaphorDensity =
        words > 0 ? metaphorHits / words * 1000 : 0.0;
    // 2) 单句成段占比
    final List<String> paras = text
        .split('\n')
        .map((String p) => p.trim())
        .where((String p) => p.isNotEmpty)
        .toList();
    final double singleParaRate = paras.isEmpty
        ? 0.0
        : paras.where((String p) => AppConstants.countWords(p) <= _singleParaMaxChars).length /
            paras.length *
            100;
    // 3) 身体反应密度（每千字）
    int bodyHits = 0;
    for (final String w in _bodyReactionWords) {
      bodyHits += countOccurrences(text, w);
    }
    final double bodyReactionDensity =
        words > 0 ? bodyHits / words * 1000 : 0.0;
    return <String, double>{
      'metaphorDensity': double.parse(metaphorDensity.toStringAsFixed(2)),
      'singleParaRate': double.parse(singleParaRate.toStringAsFixed(1)),
      'bodyReactionDensity': double.parse(bodyReactionDensity.toStringAsFixed(2)),
    };
  }

  /// 按句末标点切分句子（正则编译一次常驻）。
  static final RegExp _sentenceSplit = RegExp(r'[。！？!?…]+');

  static List<String> _splitSentences(String text) {
    return text
        .split(_sentenceSplit)
        .where((String s) => s.trim().isNotEmpty)
        .toList();
  }

  /// AI 味深度检测（统计层，非词表匹配）：
  /// 1. 句长变异系数 CV（AI 句子长度过于均匀 → CV 低）
  /// 2. 「的」字密度（AI 爱用「他的眼底」式修饰 → 密度高）
  /// 3. 叠词修饰密度（微微/轻轻/淡淡…）
  /// 4. 句首连接词比例（然而/于是/随即…）
  /// 5. 句式指纹三项：比喻密度 / 单句成段占比 / 身体反应密度
  ///    （三项中 ≥2 项超标合并计入 1 档，保守设计防 level 失真）
  ///
  /// 返回各指标 + level（0~5，超标 +1；>=3 视为 AI 腔偏重）。
  static Map<String, dynamic> deepAiMetrics(String text) {
    if (text.isEmpty) {
      return <String, dynamic>{
        'sentenceCv': 0.0,
        'deDensity': 0.0,
        'adverbDensity': 0.0,
        'connectorRate': 0.0,
        'metaphorDensity': 0.0,
        'singleParaRate': 0.0,
        'bodyReactionDensity': 0.0,
        'level': 0,
      };
    }
    final int words = AppConstants.countWords(text);

    // 1) 句长变异系数
    final List<int> lens = _splitSentences(text)
        .map((String s) => AppConstants.countWords(s))
        .where((int n) => n > 0)
        .toList();
    double cv = 0.0;
    if (lens.length >= 3) {
      final double mean =
          lens.fold<int>(0, (int a, int b) => a + b) / lens.length;
      final double variance = lens
              .map((int n) {
                final double d = n - mean;
                return d * d;
              })
              .fold<double>(0.0, (double a, double b) => a + b) /
          lens.length;
      final double sd = math.sqrt(variance);
      cv = mean > 0 ? sd / mean : 0.0;
    }

    // 2) 「的」字密度
    final double deDensity = words > 0
        ? countOccurrences(text, '的') / words * 100
        : 0.0;

    // 3) 叠词修饰密度（每千字）
    int advHits = 0;
    for (final String w in _aiAdverbs) {
      advHits += countOccurrences(text, w);
    }
    final double adverbDensity =
        words > 0 ? advHits / words * 1000 : 0.0;

    // 4) 句首连接词比例
    int connHits = 0;
    for (final String s in _splitSentences(text)) {
      final String t = s.trim();
      final String head = t.substring(0, t.length > 4 ? 4 : t.length);
      for (final String c in _sentenceConnectors) {
        if (head.startsWith(c)) {
          connHits++;
          break;
        }
      }
    }
    final double connectorRate =
        _splitSentences(text).isEmpty ? 0.0 : connHits / _splitSentences(text).length;

    // 5) 句式指纹三项（≥2/3 超标 → 记 1 档，与 Python deep_ai_metrics 同口径）
    final Map<String, double> fp = styleFingerprintMetrics(text);
    final int fpOver = <bool>[
      fp['metaphorDensity']! > styleFpLimits['metaphorDensity']!,
      fp['singleParaRate']! > styleFpLimits['singleParaRate']!,
      fp['bodyReactionDensity']! > styleFpLimits['bodyReactionDensity']!,
    ].where((bool b) => b).length;

    // 综合档位（原四项各超标 +1；句式指纹 ≥2 项超标再 +1）
    final int level = (cv < 0.55 ? 1 : 0) +
        (deDensity > 4.0 ? 1 : 0) +
        (adverbDensity > 2.0 ? 1 : 0) +
        (connectorRate > 0.15 ? 1 : 0) +
        (fpOver >= 2 ? 1 : 0);
    return <String, dynamic>{
      'sentenceCv': double.parse(cv.toStringAsFixed(2)),
      'deDensity': double.parse(deDensity.toStringAsFixed(2)),
      'adverbDensity': double.parse(adverbDensity.toStringAsFixed(2)),
      'connectorRate': double.parse(connectorRate.toStringAsFixed(2)),
      'metaphorDensity': fp['metaphorDensity'],
      'singleParaRate': fp['singleParaRate'],
      'bodyReactionDensity': fp['bodyReactionDensity'],
      'level': level,
    };
  }

  /// AI 味深度告警（level>=3 时提示具体超标项，含句式指纹超标项）。
  static List<String> deepAiIssues(String text) {
    final Map<String, dynamic> m = deepAiMetrics(text);
    if ((m['level'] as int) < 3) return const <String>[];
    final List<String> issues = <String>[];
    if ((m['sentenceCv'] as double) < 0.55) {
      issues.add('句长过于均匀（CV=${m['sentenceCv']}，真人写作 >0.55）');
    }
    if ((m['deDensity'] as double) > 4.0) {
      issues.add('「的」字密度偏高（${m['deDensity']}%，>4% 偏 AI 腔）');
    }
    if ((m['adverbDensity'] as double) > 2.0) {
      issues.add('叠词修饰偏多（${m['adverbDensity']}/千字，微微/轻轻/淡淡类）');
    }
    if ((m['connectorRate'] as double) > 0.15) {
      issues.add('句首连接词偏多（${(m['connectorRate'] as double) * 100}% 句子以「然而/于是/随即」开头）');
    }
    // 句式指纹：≥2 项超标会推高 level，告警里列出具体项供定点修
    if ((m['metaphorDensity'] as double) > styleFpLimits['metaphorDensity']!) {
      issues.add('比喻密度偏高（${m['metaphorDensity']}/千字，>2.0 偏 AI 风格指纹）');
    }
    if ((m['singleParaRate'] as double) > styleFpLimits['singleParaRate']!) {
      issues.add('单句成段过密（${m['singleParaRate']}% 段落 ≤14 字，喘气段过频节奏机械）');
    }
    if ((m['bodyReactionDensity'] as double) > styleFpLimits['bodyReactionDensity']!) {
      issues.add('身体反应描写过密（${m['bodyReactionDensity']}/千字，发烫/发凉/嗓子发干类四件套）');
    }
    return issues;
  }
}
