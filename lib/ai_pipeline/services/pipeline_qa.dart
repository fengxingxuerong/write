import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/utils/text_index.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/engine/quality/quality_rules.g.dart';
import 'package:novel_writer/ai_pipeline/services/style_fingerprint.dart';
import 'package:novel_writer/ai_pipeline/services/cross_chapter_qa.dart';

/// 一章的「外显兑现」度量（供跨章断供判定）。
///
/// 桌面端此前是**无状态单章引擎**：`MultiPassChapterEngine.generate()` 只拿到当前
/// 章，拿不到前序章的爽点密度，于是「外显爽点长期断供」这一跨章形态无从判定
/// （Python 侧靠 `trailing_drought_len` 解决）。本记录由 ViewModel 逐章累积，
/// 随 `ContextBundle.payoffHistory` 传入引擎——纯数据、可跨 Isolate 传递。
///
/// 定义放在本文件（而非 `generation_engine.dart`）是为保持依赖单向：
/// `generation_engine.dart` → `pipeline_qa.dart`，不反向依赖。
class ChapterPayoff {
  /// 直白爽点密度（每千字命中数）。
  final double thrillPerK;

  /// 侧面反响密度（每千字命中数）。
  final double sidePerK;

  /// 构造。
  const ChapterPayoff({required this.thrillPerK, required this.sidePerK});

  /// 由正文现算。
  factory ChapterPayoff.of(String content) => ChapterPayoff(
        thrillPerK: PipelineQa.thrillPerThousand(content),
        sidePerK: PipelineQa.sideReactionPerThousand(content),
      );

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'thrillPerK': thrillPerK,
        'sidePerK': sidePerK,
      };

  /// 反序列化（缺字段按 0 处理，坏数据不得让整轮生成崩掉）。
  factory ChapterPayoff.fromJson(Map<String, dynamic> json) => ChapterPayoff(
        thrillPerK: (json['thrillPerK'] as num?)?.toDouble() ?? 0.0,
        sidePerK: (json['sidePerK'] as num?)?.toDouble() ?? 0.0,
      );

  @override
  String toString() =>
      '💥${thrillPerK.toStringAsFixed(2)}/侧反${sidePerK.toStringAsFixed(2)}';
}

/// 本地规则质检（零成本，不消耗 API）。
///
/// 移植自 `scripts/generate_novel.py` 的 `quality_check` 与演示脚本指标：
/// - AI 味密度：高频 AI 表达出现频率（越低越好）
/// - 相邻段落重复率：Jaccard 相似度均值
/// - 节奏失衡：超长/超短段落占比
/// - 世界观关键词冲突：同一关键词在不同章节「肯定/否定」表述相反
///
/// 双端同步须知：本文件的词表常量（aiClicheWords / _hookWords /
/// _openingStrong / _openingWeak / thrillWords / powerSurgeWords / sideReactionWords /
/// _aiAdverbs / _sentenceConnectors / _bodyReactionWords / worldKeywords）与
/// deepAiMetrics 统计阈值（含句式指纹三项 styleFpLimits），
/// releaseProfile 落点判定（n>=2 适用线 + 0.6/0.5 阈值）、
/// payoffDroughtZones/payoffDroughtEvFragment 外显爽点断供带（只看 💥 连低、
/// 0.5 阈值 + minRun=3，定义在 `scripts/generate_novel.py`），
/// endingTriad/endingEvFragment 三件套收尾（末 60 字窗口 + TRIAD_END_WORDS
/// 词表 + TRIAD_HOOK_ONLY 降级，定义在 `scripts/fanqie_review.py`），与
/// `scripts/generate_novel.py` 的对应常量（HOOK_WORDS /
/// OPENING_STRONG / OPENING_WEAK / THRILL_WORDS / POWER_SURGE_WORDS / SIDE_REACTION_WORDS /
/// AI_ADVERBS / SENTENCE_CONNECTORS / BODY_REACTION_WORDS / METAPHOR_PAT /
/// STYLE_FP_LIMITS / release_profile）及 deep_ai_metrics 阈值同步维护，
/// 调优时必须同一次同时更新两端，防止标准漂移。
class PipelineQa {
  PipelineQa._();

  /// AI 高频表达（反 AI 腔词表）。
  static const List<String> aiClicheWords = <String>[
    '嘴角', '唇角', '眼底', '眼神', '目光', '仿佛', '似乎', '宛如',
    '空气', '心跳', '深吸', '命运', '轨迹', '万语', '舒了一口',
    '微微上扬', '闪过一丝', '勾起一抹', '空气凝固', '嘴角勾起', '眼底闪过',
  ];

  /// 世界观关键词（检测前后文冲突）。
  static const List<String> worldKeywords = <String>[
    '灵气', '斗气', '筑基', '金丹', '元婴', '灵石', '灵根', '灵脉',
  ];

  /// 否定词（前缀 6 字内出现则视为否定表述）。
  /// 值来自 [QualityRules.negation]（rules/quality_rules.json 生成）。
  static const List<String> negations = QualityRules.negation;

  /// AI 味密度（%）：命中次数 / 总字数 * 100。
  static double aiEchoPct(String text) {
    final int words = AppConstants.countWords(text);
    if (words == 0) return 0.0;
    // 大词表先过 TextIndex：必然不命中的词直接跳过，计数口径不变
    // （全书体检下这三处词表各有几十~上百词，逐个扫全文曾是主要开销）。
    final TextIndex index = TextIndex(text);
    int hits = 0;
    for (final String w in aiClicheWords) {
      if (index.mayContain(w)) hits += countOccurrences(text, w);
    }
    return (hits / words * 100).clamp(0.0, 100.0);
  }

  /// 相邻段落重复率：相邻段落二元组 Jaccard 相似度均值。
  static double adjacentRepetition(String text) => _repetitionOf(_qaParas(text));

  /// 节奏失衡：超长（>400 字）或超短（<30 字）段落占比。
  static double rhythmScore(String text) => _rhythmOf(_qaParas(text));

  /// 相邻段落重复率 + 节奏失衡率（同一份段落切分只做一次）。
  ///
  /// 两个指标的段落口径完全一致（`\n\n` 切分后只留 `trim().length > 10` 的段），
  /// 旧实现各自切一遍；全书体检按章调用时是白扫的第二遍。单指标入口保留为
  /// 薄封装，单独调用时不会多做另一项计算。
  static ({double repetition, double rhythm}) repetitionAndRhythm(String text) {
    final List<String> paras = _qaParas(text);
    return (repetition: _repetitionOf(paras), rhythm: _rhythmOf(paras));
  }

  /// 商业指标共用的段落切分口径。
  static List<String> _qaParas(String text) => text
      .split('\n\n')
      .where((String p) => p.trim().length > 10)
      .toList();

  /// 已切好的段落 → 相邻段落重复率。
  static double _repetitionOf(List<String> paras) {
    if (paras.length < 2) return 0.0;
    double sum = 0.0;
    for (int i = 1; i < paras.length; i++) {
      sum += _jaccard(paras[i - 1], paras[i]);
    }
    return sum / (paras.length - 1);
  }

  /// 已切好的段落 → 节奏失衡率。
  static double _rhythmOf(List<String> paras) {
    if (paras.isEmpty) return 0.0;
    int bad = 0;
    for (final String p in paras) {
      final int w = AppConstants.countWords(p);
      if (w < 30 || w > 400) bad++;
    }
    return bad / paras.length;
  }

  /// 生成一章节的质检摘要（供 UI 报告展示）。
  static Map<String, dynamic> chapterReport(PipelineChapter chapter) {
    final double echo = aiEchoPct(chapter.content);
    // 重复率与节奏共用同一份段落切分（口径见 repetitionAndRhythm）。
    final ({double repetition, double rhythm}) rr =
        repetitionAndRhythm(chapter.content);
    final double rep = rr.repetition;
    final double rhy = rr.rhythm;
    final Map<String, dynamic> deep = deepAiMetrics(chapter.content);
    return <String, dynamic>{
      'idx': chapter.idx,
      'words': chapter.words,
      'aiEcho': echo.toStringAsFixed(2),
      'repetition': rep.toStringAsFixed(3),
      'rhythm': rhy.toStringAsFixed(3),
      'hasHook': hasEndingHook(chapter.content),
      'thrillPerK': thrillPerThousand(chapter.content).toStringAsFixed(2),
      'surgePerK': surgePerThousand(chapter.content).toStringAsFixed(2),
      'sideReactionPerK': sideReactionPerThousand(chapter.content).toStringAsFixed(2),
      'release': releaseProfile(chapter.content).verdict,
      'endingTriad': endingTriad(chapter.content),
      'aiDeepLevel': deep['level'],
      // 口径与 chapterIssues 保持一致：词表密度、重复率或统计层 AI 味
      // （level>=3）任一超标即需润色，避免报告与告警列表矛盾。
      'needsPolish':
          echo > 0.02 || rep > 0.10 || (deep['level'] as int) >= 3,
    };
  }

  // ---------------- 商业向质检（签约级网文标准） ----------------

  /// 章末钩子信号词（结尾 200 字内出现即视为有钩子）。
  ///
  /// 覆盖三类信号：① 直白突变（突然/竟然/怎么回事…）；
  /// ② 隐喻式钩子（被跟踪感/身份伏笔/诡谲意象/威胁暗示）；
  /// ③ 悬而未决/监视/异常（有什么探出/暗处那只眼/将落未落/又闪又响）。
  /// 词表经《碎脉铸仙录》33 章成书结尾全量实测校准（人工基线 91% 覆盖率，
  /// 规则命中 39% → 升级后目标 90%+），避免「睁眼瞎」漏判。
  ///
  /// **三件套不算钩**（FANQIE 规则 20/10）：尾部命中若全是三件套词
  /// （发烫/醒了过来）且末 60 字无问号/省略号悬念 → 判无钩。修正
  /// 「三件套收尾反被判有钩」的检测矛盾（真实成书 116 章实测 93% 反向
  /// 奖励；回测仅 1/116 章因此翻转，其余三件套章尾部另有真实钩子信号）。
  /// 值来自 [QualityRules.hookWords]（rules/quality_rules.json 生成）——
  /// 本文件不再保存字面量，双端结构上不可能再漂移。
  static const List<String> _hookWords = QualityRules.hookWords;

  /// 章末三件套收尾词表（FANQIE 规则 20「禁止发烫/亮起/苏醒收尾」+
  /// 规则 10 + scene_prompt「禁止发热/发光/苏醒收束」——与 Python
  /// `fanqie_review.TRIAD_END_WORDS` 同步）。
  ///
  /// 长词在前（像有什么东西醒了 > 醒了过来 > 醒了、亮了起来 > 亮了）；
  /// 「亮」字族带天字排除（「天亮了」是时间过渡，不是发光物件收束）。
  /// 校准：tool/probe_ending_and_simile.py 三窗口敏感性——末句 6.9% /
  /// 末60字 11.2% / 末200字 25.9%，取末 60 字收束窗口（与 Python
  /// TRIAD_END_WINDOW 同步）。
  /// 值来自 [QualityRules.triadEndWords]（顺序敏感，取决于生成物中的登记顺序）。
  static const List<String> _triadEndWords = QualityRules.triadEndWords;

  /// [_hookWords] 中属三件套性质的成员：作为**唯一**尾部钩子信号时不采信。
  static const Set<String> _triadHookOnly = QualityRules.triadHookOnly;

  /// 开场节奏·强信号词（双字/特定短语，1 个即视为快速进入事件）。
  ///
  /// 双级判定避免单字词（碎/撞/压）在比喻语境（"像纸一样一碰就碎"）
  /// 的误报：强信号 1 个达标，弱信号需 ≥2 个才达标。
  /// 值来自 [QualityRules.openingStrong]（rules/quality_rules.json 生成）。
  static const List<String> _openingStrong = QualityRules.openingStrong;

  /// 开场节奏·弱信号词（单字动词/名词，需 ≥2 个同时出现）。
  /// 值来自 [QualityRules.openingWeak]（rules/quality_rules.json 生成）。
  static const List<String> _openingWeak = QualityRules.openingWeak;

  /// 爽点信号词（打脸 / 升级 / 收获 / 揭露 四大类）。
  ///
  /// 番茄签约的核心追读指标：每千字爽点数过低 = 读者流失风险。
  /// 词表选「语义明确」的词，避免「获得/发现/到手」类宽泛误报。
  /// 值来自 [QualityRules.thrillWords]（rules/quality_rules.json 生成）。
  /// 全表必须唯一（重复登记会让命中数被记两次，双端密度不一致）。
  static const List<String> thrillWords = QualityRules.thrillWords;

  /// 爽点密度（每千字命中数）。网文参考线：≥1.5 为合格，<1.0 偏淡。
  static double thrillPerThousand(String text) {
    if (text.isEmpty) return 0.0;
    final TextIndex index = TextIndex(text);
    int hits = 0;
    for (final String w in thrillWords) {
      if (index.mayContain(w)) hits += countOccurrences(text, w);
    }
    final int words = AppConstants.countWords(text);
    return words == 0 ? 0.0 : (hits / words * 1000).clamp(0.0, 100.0);
  }

  /// 变强异动信号词（玄幻/仙侠文含蓄爽点：金手指与修为成长的身体异动表达）。
  ///
  /// 经《碎脉铸仙录》10.6 万字全量实测：直白爽点词仅命中 5 处，而
  /// 「发烫/温热/苏醒/流转」类变强异动命中 58 处——含蓄文风的爽点
  /// 全藏在「丹田那团温热」「掌心微微发烫」里。双通道检测避免误判
  /// 「爽点过淡」，同时也能识别「只有异动缺外显爽点」的书。
  /// 值来自 [QualityRules.powerSurgeWords]（rules/quality_rules.json 生成）。
  static const List<String> powerSurgeWords = QualityRules.powerSurgeWords;

  /// 变强异动密度（每千字命中数）。玄幻文参考线：>=1.0 为「含蓄变强流」。
  static double surgePerThousand(String text) {
    if (text.isEmpty) return 0.0;
    final TextIndex index = TextIndex(text);
    int hits = 0;
    for (final String w in powerSurgeWords) {
      if (index.mayContain(w)) hits += countOccurrences(text, w);
    }
    final int words = AppConstants.countWords(text);
    return words == 0 ? 0.0 : (hits / words * 1000).clamp(0.0, 100.0);
  }
  /// 侧面反响/震惊链信号词（三视角震惊环：反派崩溃/路人倒吸冷气/权威暗惊）。
  ///
  /// 网文爽感放大的核心机制：主角装逼或打脸时，若无配角与围观者的侧面反响，
  /// 会沦为「自嗨式平铺」。本词表量化侧面反应密度，确保爽点产生波澜。
  /// 值来自 [QualityRules.sideReactionWords]（rules/quality_rules.json 生成）。
  /// 同时是「爽点断供」判定的逃生通道（见 docs/quality-rules-current.md）。
  static const List<String> sideReactionWords = QualityRules.sideReactionWords;

  /// 侧面反响密度（每千字命中数）。网文参考线：>=0.8 为合格，<0.3 偏淡。
  static double sideReactionPerThousand(String text) {
    if (text.isEmpty) return 0.0;
    final TextIndex index = TextIndex(text);
    int hits = 0;
    for (final String w in sideReactionWords) {
      if (index.mayContain(w)) hits += countOccurrences(text, w);
    }
    final int words = AppConstants.countWords(text);
    return words == 0 ? 0.0 : (hits / words * 1000).clamp(0.0, 100.0);
  }

  /// 压抑释放结构（爽点落点）——先抑后扬是否成立。
  ///
  /// 规则来源：写作准则「爽点放在章内后半段：压抑蓄水不超过全章 60%，
  /// 后半段瞬间释放」——该规则此前只有 prompt 承诺、没有检测器
  /// （与 Python `generate_novel.release_profile` 同口径：n>=2 才有结构可言，
  /// first>0.6 判 late_start、last<0.5 判 front_loaded；真实成书 156 章校准，
  /// note 级「标记供人工复核」，与句式指纹同定位）。
  ///
  /// 只用基础 [thrillWords] 判落点（题材加成词仅 Python 侧存在，用了会破坏双端同口径）。
  static ({String verdict, int hits, double first, double last}) releaseProfile(
    String text,
  ) {
    if (text.isEmpty) {
      return (verdict: 'none', hits: 0, first: 0.0, last: 0.0);
    }
    final TextIndex index = TextIndex(text);
    final List<int> positions = <int>[];
    for (final String w in thrillWords) {
      if (!index.mayContain(w)) continue;
      int start = 0;
      while (true) {
        final int i = text.indexOf(w, start);
        if (i < 0) break;
        positions.add(i);
        start = i + w.length;
      }
    }
    if (positions.isEmpty) {
      return (verdict: 'none', hits: 0, first: 0.0, last: 0.0);
    }
    positions.sort();
    final double denom = text.length.toDouble();
    final double first =
        ((positions.first / denom) * 100).roundToDouble() / 100;
    final double last = ((positions.last / denom) * 100).roundToDouble() / 100;
    final int hits = positions.length;
    final String verdict;
    if (hits < 2) {
      verdict = 'single';
    } else if (first > 0.6) {
      verdict = 'late_start';
    } else if (last < 0.5) {
      verdict = 'front_loaded';
    } else {
      verdict = 'ok';
    }
    return (verdict: verdict, hits: hits, first: first, last: last);
  }


  // ---------------- 跨章质检（实现见 cross_chapter_qa.dart） ----------------
  //
  // 以下同样是**薄封装**，转调 CrossChapterQa。保留门面是为了让 tool/ 下的
  // 双端对账脚本与 lib/ 各服务一行都不用改。
  // 阈值标定与误报取舍的推理见 cross_chapter_qa.dart 内的逐方法注释。

  /// 外显爽点断供带（💥 通道枯竭区）：连续 >=[minRun] 章直白爽点低于 [threshold]。
  static List<({int start, int end, int chapters})> payoffDroughtZones(
    List<double> thrillPerK, {
    double threshold = QualityRules.droughtThrillPerK,
    int minRun = QualityRules.droughtMinRun,
    List<double>? sidePerK,
    double sideThreshold = QualityRules.droughtSidePerK,
  }) =>
      CrossChapterQa.payoffDroughtZones(
        thrillPerK,
        threshold: threshold,
        minRun: minRun,
        sidePerK: sidePerK,
        sideThreshold: sideThreshold,
      );

  /// 评审证据串：外显爽点断供带。
  static String payoffDroughtEvFragment(
    List<double> thrillPerK, {
    double threshold = QualityRules.droughtThrillPerK,
    int minRun = QualityRules.droughtMinRun,
    List<double>? sidePerK,
    double sideThreshold = QualityRules.droughtSidePerK,
  }) =>
      CrossChapterQa.payoffDroughtEvFragment(
        thrillPerK,
        threshold: threshold,
        minRun: minRun,
        sidePerK: sidePerK,
        sideThreshold: sideThreshold,
      );

  /// 当前章之前处于断供中的连续长度（与 Python novel_pipeline 同口径）。
  static int trailingDroughtLen(
    List<ChapterPayoff> history, {
    double threshold = QualityRules.droughtThrillPerK,
    double sideThreshold = QualityRules.droughtSidePerK,
  }) =>
      CrossChapterQa.trailingDroughtLen(
        history,
        threshold: threshold,
        sideThreshold: sideThreshold,
      );

  /// 高频泛用词停用表（跨章复读的假阳性主要来源）。
  static const Set<String> imageryCommonStop = CrossChapterQa.imageryCommonStop;

  /// 跨章意象复读检测。
  static List<({String term, int total, double perThousand, int chapters})>
      crossChapterImagery(
    List<String> chapterTexts, {
    int minTotal = 40,
    double minPerThousand = 1.0,
    int spreadChapters = 8,
    List<String> exclude = const <String>[],
  }) =>
          CrossChapterQa.crossChapterImagery(
            chapterTexts,
            minTotal: minTotal,
            minPerThousand: minPerThousand,
            spreadChapters: spreadChapters,
            exclude: exclude,
          );

  /// 对白塌陷章列表（跨章视角）。
  static List<({int idx, double ratio, int words})> dialogueCollapseChapters(
    List<({int idx, String content})> chapters, {
    double ratioThreshold = 0.15,
    int minWords = 800,
  }) =>
      CrossChapterQa.dialogueCollapseChapters(chapters,
          ratioThreshold: ratioThreshold, minWords: minWords);

  /// 评审证据串：对白塌陷。
  static String dialogueCollapseEvFragment(
    List<({int idx, String content})> chapters, {
    double ratioThreshold = 0.15,
    int minWords = 800,
  }) =>
      CrossChapterQa.dialogueCollapseEvFragment(chapters,
          ratioThreshold: ratioThreshold, minWords: minWords);

  /// 评审证据串：跨章意象复读。
  static String imageryEvFragment(
    List<String> chapterTexts, {
    int minTotal = 40,
    double minPerThousand = 1.0,
    int spreadChapters = 8,
    List<String> exclude = const <String>[],
  }) =>
      CrossChapterQa.imageryEvFragment(
        chapterTexts,
        minTotal: minTotal,
        minPerThousand: minPerThousand,
        spreadChapters: spreadChapters,
        exclude: exclude,
      );

  /// 本章是否需要「外显爽点」情绪强化修（与 Python `needs_payoff_repair` 同口径）。
  ///
  /// 两个通道取或：
  /// ① 单章双低（💥<[threshold] 且 ✨<1.0）——保留旧行为，零回归；
  /// ② 跨章断供：[droughtLen] >= [droughtMinRun] 时，本章只要 💥 仍低就修。
  ///
  /// 侧面反响逃生：若在场者已有明确反应（[side] >= [sideOk]），说明外显兑现其实
  /// 已送达读者，再送修纯属白烧一次 LLM 调用，直接跳过。[sideOk] 传 0 即关闭。
  static bool needsPayoffRepair({
    required double thrill,
    required double surge,
    bool minWordsOk = true,
    int droughtLen = 0,
    double threshold = QualityRules.droughtThrillPerK,
    double surgeOk = 1.0,
    int droughtMinRun = QualityRules.droughtMinRun,
    double side = 0.0,
    double sideOk = QualityRules.droughtSidePerK,
  }) {
    if (!minWordsOk) return false;
    if (sideOk > 0 && side >= sideOk) return false;
    if (thrill < threshold && surge < surgeOk) return true;
    return droughtLen >= droughtMinRun && thrill < threshold;
  }

  /// 情绪强化定点修提示词（与 Python `payoff_repair_prompt` 同文）。
  ///
  /// [droughtLen] >= 3 时补一条**断供语境**（点明已连着 N 章没爽点），处方更对症。
  static String payoffRepairPrompt(
    String fullText, {
    int droughtLen = 0,
    List<Character> characters = const <Character>[],
  }) {
    final StringBuffer b = StringBuffer();
    b.writeln('下面这章小说情节完整，但缺少读者可感知的「外显爽点」，'
        '移动端读者会弃书。');
    if (droughtLen >= 3) {
      b.writeln('【背景】本书已连续 $droughtLen 章没有出现读者可感知的'
          '「外显爽点」（打脸/收获/揭露/当众反应），追读正在流失——'
          '本章必须补上一处，且要外部可见。');
    }
    b.writeln('请输出强化后的全章正文，要求：');
    b.writeln('- 主线情节、人物姓名、数字设定一律不变；');
    b.writeln('- 选章内一个冲突场景，补一处「外部可见」的爽点：'
        '对手当众吃瘪的反应 / 关键物件入手的触感细节 / 真相反转时在众人的震惊，三选一；');
    b.writeln('- 禁止只写主角内心感受充当爽点（如「他感到修为精进」）；');
    b.writeln('- 保持原有字数规模（±20% 内），不要另起新情节。');
    if (characters.isNotEmpty) {
      b.writeln();
      b.writeln('【角色名册】以下姓名必须原样保留：'
          '${characters.map((Character c) => c.name).join('、')}');
    }
    b.writeln();
    b.writeln('【原章正文】');
    b.write(fullText);
    b.writeln();
    b.writeln();
    b.writeln('只输出强化后的全章正文：');
    return b.toString();
  }

  /// 情绪强化稿采纳判定：字数在区间 + 角色名完整 + **必须真的补上外显兑现**。
  ///
  /// 与 Python `accept_payoff_repair` 同口径。关键两点：
  /// ① 只涨 ✨（含蓄异动）**不算修好**——那正是断供的成因本身；
  /// ② 但若**侧面反响涨到达标**（在场者确有反应，如惊呼/哗然/脸色铁青），
  ///    外显兑现同样成立——真机实测确有此类不套话的好稿，💥 词表抓不到。
  ///
  /// 返回 (是否采纳, 原因/指标串)。任一不过即保留原文，绝不劣化。
  static (bool, String) acceptPayoffRepair(
    String original,
    String fix, {
    List<Character> characters = const <Character>[],
    double minRatio = 0.7,
    double maxRatio = 1.6,
    double threshold = QualityRules.droughtThrillPerK,
    double sideOk = QualityRules.droughtSidePerK,
  }) {
    final int oW = AppConstants.countWords(original);
    final int fW = AppConstants.countWords(fix);
    if (fW < minRatio * oW || fW > maxRatio * oW) {
      return (false, '字数越界（$oW->$fW 字，允许 ${(minRatio * 100).round()}'
          '%~${(maxRatio * 100).round()}%）');
    }
    for (final Character c in characters) {
      final String n = c.name.trim();
      if (n.isNotEmpty && !fix.contains(n)) {
        return (false, '角色丢失（$n）');
      }
    }
    final double oT = thrillPerThousand(original);
    final double fT = thrillPerThousand(fix);
    final double oS = surgePerThousand(original);
    final double fS = surgePerThousand(fix);
    final double oSide = sideReactionPerThousand(original);
    final double fSide = sideReactionPerThousand(fix);
    // 判定顺序要紧：先把「侧反达标」记为有效提升，再看「是否整体没动」——
    // 否则只涨侧反（💥/✨ 都没动）的好稿会被「未提升」提前拒掉。
    final bool sideGain = sideOk > 0 && fSide >= sideOk && fSide > oSide;
    if (!sideGain && fT <= oT && fS <= oS) {
      return (false, '未提升（💥${oT.toStringAsFixed(2)}->${fT.toStringAsFixed(2)}'
          '｜✨${oS.toStringAsFixed(2)}->${fS.toStringAsFixed(2)}'
          '｜侧反${oSide.toStringAsFixed(2)}->${fSide.toStringAsFixed(2)}）');
    }
    if (fT < threshold && !sideGain) {
      return (false, '未补上外显爽点（💥${fT.toStringAsFixed(2)}<$threshold、'
          '侧反${fSide.toStringAsFixed(2)}<$sideOk）');
    }
    return (true, '💥${oT.toStringAsFixed(2)}->${fT.toStringAsFixed(2)}'
        '｜✨${oS.toStringAsFixed(2)}->${fS.toStringAsFixed(2)}'
        '｜侧反${fSide.toStringAsFixed(2)}｜$fW 字');
  }

  /// 评审证据串：爽点落点（注入 qualityReviewPrompt 的 qaEvidence，
  /// 与 Python `release_ev_fragment` 同文，双端评审读到同一份证据）。
  static String releaseEvFragment(String text) {
    final ({String verdict, int hits, double first, double last}) p =
        releaseProfile(text);
    switch (p.verdict) {
      case 'none':
        return '爽点落点：无外显爽点命中（落点不适用，按密度指标判 thrill）';
      case 'single':
        return '爽点落点：仅 ${p.hits} 处命中于 ${_releasePct(p.first)}'
            '（单点无结构，落点不适用）';
      case 'ok':
        return '爽点落点：首现 ${_releasePct(p.first)}、末现 ${_releasePct(p.last)}'
            '（先抑后扬结构正常 ✅）';
      case 'late_start':
        return '爽点落点：首现 ${_releasePct(p.first)} ⚠ 压抑超过全章 60% 才首次释放'
            '（先抑后扬失衡，rhythm 维度不应高于 60 分）';
      default: // front_loaded
        return '爽点落点：末现 ${_releasePct(p.last)} ⚠ 爽点全在前半段、后半段零释放'
            '（前置泄洪，rhythm 维度不应高于 60 分）';
    }
  }

  /// 落点百分比渲染（与 Python f-string `{:.0%}` 同口径）。
  static String _releasePct(double v) => '${(v * 100).round()}%';

  // ---------------- 文风指纹 / AI 腔（实现见 style_fingerprint.dart） ----------------
  //
  // 以下全是**薄封装**，一行转调 StyleFingerprintQa。刻意保留这层门面而不是让
  // 调用方直接改用 StyleFingerprintQa：20+ 处调用点（含 tool/ 下与 Python 双端
  // 对账的脚本）一行都不用改，拆分就纯粹是内部结构调整，不产生行为差异。
  // 口径与校准依据见 style_fingerprint.dart 内的逐方法注释。

  /// 指纹项（不含 source），用于距离计算与展示。顺序与 Python 侧一致。
  static const List<String> styleFingerprintKeys = StyleFingerprintQa.styleFingerprintKeys;

  /// 句式指纹超标线（与 Python STYLE_FP_LIMITS 同步）。
  static const Map<String, double> styleFpLimits = StyleFingerprintQa.styleFpLimits;

  /// 对白占比（0~1）。
  static double dialogueRatioOf(String text) => StyleFingerprintQa.dialogueRatioOf(text);

  /// 文风指纹（P1-1）：把参考文的可统计风格压成九项分布指标。
  static Map<String, double> styleFingerprint(String text) =>
      StyleFingerprintQa.styleFingerprint(text);

  /// 句式指纹三项：比喻密度 / 单句成段占比 / 身体反应密度。
  static Map<String, double> styleFingerprintMetrics(String text) =>
      StyleFingerprintQa.styleFingerprintMetrics(text);

  /// 把文风指纹渲染成可注入写手的提示块（学分布，不抄内容）。
  static String styleFingerprintBlock(
    Map<String, double> fp, {
    required String source,
  }) =>
      StyleFingerprintQa.styleFingerprintBlock(fp, source: source);

  /// 两份文风指纹的归一化距离（0=同分布，越大差异越大）。
  static double fingerprintDistance(
    Map<String, double> a,
    Map<String, double> b,
  ) =>
      StyleFingerprintQa.fingerprintDistance(a, b);

  /// 评审证据串：与参考文的文风距离分解。
  static String styleEvFragment(
    Map<String, double>? referenceFingerprint,
    String generated,
  ) =>
      StyleFingerprintQa.styleEvFragment(referenceFingerprint, generated);

  /// AI 味深度检测（统计层，非词表匹配）。
  static Map<String, dynamic> deepAiMetrics(String text) =>
      StyleFingerprintQa.deepAiMetrics(text);

  /// AI 味深度告警（level>=3 时提示具体超标项，含句式指纹超标项）。
  static List<String> deepAiIssues(String text) =>
      StyleFingerprintQa.deepAiIssues(text);

  /// 章末钩子检测：结尾 200 字内是否有未落地悬念信号。
  ///
  /// 三件套不算钩（规则 20/10）：尾部命中若全是三件套词（发烫/醒了过来）
  /// 且末 60 字无问号/省略号悬念 → 判无钩（与 Python `has_ending_hook` 同步）。
  static bool hasEndingHook(String text) {
    if (text.isEmpty) return false;
    final String tail =
        text.length > 200 ? text.substring(text.length - 200) : text;
    // 结尾 60 字内出现疑问句或省略号悬念（悬念通道优先于三件套降级）。
    final String last60 =
        tail.length > 60 ? tail.substring(tail.length - 60) : tail;
    if (last60.contains('？') ||
        last60.contains('?') ||
        last60.contains('……')) {
      return true;
    }
    // 存在任一**非三件套**尾部钩子词才算钩；全是三件套词（发烫/醒了过来）
    // → 不采信（检测矛盾修正）；无任何命中 → 无钩。
    for (final String w in _hookWords) {
      if (tail.contains(w) && !_triadHookOnly.contains(w)) return true;
    }
    return false;
  }

  /// 章末三件套收尾检测：收束区域（末 60 字）命中规则 20 词表则返回该词，
  /// 未命中返回空串。只管收尾位置——正文中段的发烫/苏醒是正常身体异动
  /// （POWER_SURGE 通道），不算本违规（与 Python `ending_triad` 同步）。
  static String endingTriad(String text) {
    if (text.isEmpty) return '';
    const int w = QualityRules.triadEndWindow;
    final String seg = text.length > w ? text.substring(text.length - w) : text;
    for (final String w in _triadEndWords) {
      int start = 0;
      while (true) {
        final int i = seg.indexOf(w, start);
        if (i < 0) break;
        // 「天亮了」是时间推进，不是发光物件收束（逐个出现位置排除，
        // 同窗内「天亮了」在前、「玉符亮了」在后时仍能命中后者）。
        if (w.startsWith('亮') && i > 0 && seg[i - 1] == '天') {
          start = i + w.length;
          continue;
        }
        return w;
      }
    }
    return '';
  }

  /// 评审证据串：章末收尾（注入 qualityReviewPrompt 的 qaEvidence，
  /// 与 Python `ending_ev_fragment` 同文）。
  static String endingEvFragment(String text) {
    final String w = endingTriad(text);
    if (w.isNotEmpty) {
      return '章末收尾：三件套命中「$w」⚠（规则20禁止身体异动/发光物件收束，需换成未落地悬念）';
    }
    return '章末收尾：未见三件套 ✅';
  }

  /// 开场节奏检测（黄金三章）：前 300 字是否进入变故/冲突。
  ///
  /// 强信号（穿越/醒来/废物/耳光…）命中 1 个即达标；
  /// 弱信号（单字动词）需 ≥2 个同时出现——避免比喻语境误报。
  static bool hasQuickOpening(String text) {
    if (text.isEmpty) return false;
    final String head =
        text.length > 300 ? text.substring(0, 300) : text;
    for (final String w in _openingStrong) {
      if (head.contains(w)) return true;
    }
    int weakHits = 0;
    for (final String w in _openingWeak) {
      if (head.contains(w)) weakHits++;
    }
    return weakHits >= 2;
  }

  /// 章节商业向质检：返回告警列表（钩子缺失 / 黄金三章开场迟缓 / 爽点过淡）。
  ///
  /// 只用于提示，不阻塞生成。
  static List<String> chapterIssues(PipelineChapter chapter) {
    final List<String> issues = <String>[];
    if (!hasEndingHook(chapter.content)) {
      issues.add('第 ${chapter.idx} 章 章末疑似缺少钩子（结尾 200 字未见悬念信号）');
    }
    final String triad = endingTriad(chapter.content);
    if (triad.isNotEmpty) {
      issues.add('第 ${chapter.idx} 章 章末三件套收尾：命中「$triad」'
          '（规则20禁止身体异动/发光物件收束，建议换成未落地悬念）');
    }
    if (chapter.idx <= 3 && !hasQuickOpening(chapter.content)) {
      issues.add('第 ${chapter.idx} 章 开场 300 字未检测到变故/冲突信号'
          '（黄金三章要求快速进入事件）');
    }
    // 爽点过淡：章节字数 >1500，直白爽点与变强异动双双过低才算。
    // 含蓄变强流（异动高、直白低）不算过淡，但提示检查是否缺外显爽点。
    if (chapter.words > 1500) {
      final double thrill = thrillPerThousand(chapter.content);
      final double surge = surgePerThousand(chapter.content);
      final double sideReaction = sideReactionPerThousand(chapter.content);
      if (thrill < 0.5 && surge < 1.0) {
        issues.add('第 ${chapter.idx} 章 爽点过淡（直白爽点 <0.5 且变强异动 <1.0/千字，'
            '建议安排打脸/升级/收获/揭露至少一处）');
      } else if (thrill < 0.5) {
        issues.add('第 ${chapter.idx} 章 含蓄变强流（外显爽点偏少，直白爽点 <0.5/千字，'
            '建议补充打脸/收获等外显爽点增强追读）');
      }
      if (thrill >= 0.5 && sideReaction < 0.3) {
        issues.add('第 ${chapter.idx} 章 侧面反响偏弱（震惊链 <0.3/千字，'
            '建议补齐三视角震惊环：反派难以置信/路人失声惊呼/权威重新审视）');
      }
      // 压抑释放结构（爽点落点）：先抑后扬是否成立，note 级供人工复核。
      final ({String verdict, int hits, double first, double last}) rel =
          releaseProfile(chapter.content);
      if (rel.verdict == 'late_start') {
        issues.add('第 ${chapter.idx} 章 压抑过长（首个爽点在全章 '
            '${(rel.first * 100).round()}% 处才释放，先抑后扬要求压抑不超过 60%，'
            '建议把释放点前移或在中段补一处小释放）');
      } else if (rel.verdict == 'front_loaded') {
        issues.add('第 ${chapter.idx} 章 爽点前置泄洪（末个爽点在全章 '
            '${(rel.last * 100).round()}% 处，后半段零释放，'
            '建议后半章补一处打脸/收获落地）');
      }
    }
    // AI 味深度：句长均匀/的字过多/叠词/句首连接词（统计层 AI 腔）。
    final List<String> deep = deepAiIssues(chapter.content);
    if (deep.isNotEmpty) {
      issues.add('第 ${chapter.idx} 章 AI 腔偏重：${deep.join('；')}');
    }
    return issues;
  }

  /// 跨章世界观关键词冲突检测（对比已生成章节与新增章节）。
  ///
  /// 返回冲突描述列表。
  static List<String> worldConflicts(
    List<PipelineChapter> existing,
    PipelineChapter added,
  ) {
    final List<String> result = <String>[];
    for (final String kw in worldKeywords) {
      final int pos = added.content.indexOf(kw);
      if (pos < 0) continue;
      final bool addedNeg = _hasNegationBefore(added.content, pos);
      // 在既有章节里找同关键词的首现。
      for (final PipelineChapter ch in existing) {
        final int prevPos = ch.content.indexOf(kw);
        if (prevPos < 0) continue;
        final bool prevNeg = _hasNegationBefore(ch.content, prevPos);
        if (prevNeg != addedNeg) {
          result.add(
            '第 ${ch.idx} 章「$kw」(${prevNeg ? '否定' : '肯定'}) 与第 ${added.idx} 章'
            '（${addedNeg ? '否定' : '肯定'}）表述相反',
          );
        }
        break; // 只比对最早出现的一次
      }
    }
    return result;
  }

  // ---------------- 内部工具 ----------------

  // 注：原 `_countOccurrences` 已上移到 core/utils/text_index.dart 作为
  // `countOccurrences`（拆分 style_fingerprint.dart 时两边都要用），本类改为调用它。

  /// 两段文字的 Jaccard 相似度（基于 2 字以上中文词组）。
  static double _jaccard(String a, String b) {
    final Set<String> ta = _chineseBigrams(a);
    final Set<String> tb = _chineseBigrams(b);
    if (ta.isEmpty && tb.isEmpty) return 0.0;
    final int inter = ta.intersection(tb).length;
    final int union = ta.union(tb).length;
    return union == 0 ? 0.0 : inter / union;
  }

  /// 提取中文 2 字以上连续片段集合。
  static Set<String> _chineseBigrams(String text) {
    final Set<String> set = <String>{};
    final StringBuffer buf = StringBuffer();
    for (final int code in text.codeUnits) {
      final bool isCjk = code >= 0x4E00 && code <= 0x9FFF;
      if (isCjk) {
        buf.writeCharCode(code);
      } else if (buf.length >= 2) {
        set.add(buf.toString());
        buf.clear();
      } else {
        buf.clear();
      }
    }
    if (buf.length >= 2) set.add(buf.toString());
    return set;
  }

  /// 判断位置 [pos] 前 6 个字符内是否出现否定词。
  static bool _hasNegationBefore(String text, int pos) {
    final int start = pos - 6 < 0 ? 0 : pos - 6;
    final String prefix = text.substring(start, pos);
    for (final String n in negations) {
      if (prefix.contains(n)) return true;
    }
    return false;
  }
}


