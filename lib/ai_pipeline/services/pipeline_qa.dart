import 'dart:math' as math;

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/utils/text_index.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/engine/quality/quality_rules.g.dart';

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
      if (index.mayContain(w)) hits += _countOccurrences(text, w);
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
      if (index.mayContain(w)) hits += _countOccurrences(text, w);
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
      if (index.mayContain(w)) hits += _countOccurrences(text, w);
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
      if (index.mayContain(w)) hits += _countOccurrences(text, w);
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

  /// 外显爽点断供带（💥 通道枯竭区）：连续 >=[minRun] 章直白爽点低于 [threshold]。
  ///
  /// 背景（与 Python `payoff_drought_zones` 同口径，2026-09-29 真实成书回测）：
  /// 既有爽点闸门一律用「双低」判定（💥<0.5 **且** ✨<1.0 才算过淡），
  /// 本意是放过「含蓄变强流」，但实测 💥 通道**全书性枯竭**——14 本真实成书
  /// 💥 中位数仅 0.18~0.79/千字（参考线 1.5 合格 / 1.0 及格），而 ✨ 稳定在
  /// ~2.2/千字，✨ 恒高分让「双低」几乎永不成立，于是「外显爽点长期断供」
  /// 这一追读杀手没有任何检测器看得见（规则层漏检、LLM 终审看得见）。
  ///
  /// 与「双低塌陷区」互补不重叠：那个判「两通道皆枯」，这个只看 💥 连低，
  /// 专抓「✨ 含蓄流把 💥 断供掩盖」。故入参只有逐章 💥 密度，不看 ✨。
  ///
  /// 阈值标定（minRun=3）：1~2 章连低属正常节奏起伏（6/14 本书出现且质量正常），
  /// >=3 章才判断供带；健康小样零命中，无误报。
  ///
  /// [sidePerK] 逃生通道（2026-09-29 真机 A/B 实测后补，与 Python 同口径）：
  /// 只看 💥 会误伤「不写套话的好章节」——真机单发拿到一段教科书级当众兑现
  /// （满堂哄笑 → 全场屏息 → 众目睽睽 → 公开揭示），💥 命中 0 词（=0.0），
  /// 因 THRILL_WORDS 是 96 词闭合套话表，而不套话的模型恰好系统性绕开它。
  /// 故凡侧面反响达标（在场者确有反应）的章一律不判断供。传 null 保持旧口径。
  static List<({int start, int end, int chapters})> payoffDroughtZones(
    List<double> thrillPerK, {
    double threshold = QualityRules.droughtThrillPerK,
    int minRun = QualityRules.droughtMinRun,
    List<double>? sidePerK,
    double sideThreshold = QualityRules.droughtSidePerK,
  }) {
    final List<({int start, int end, int chapters})> zones =
        <({int start, int end, int chapters})>[];
    int? start;
    for (int i = 0; i < thrillPerK.length; i++) {
      bool flat = thrillPerK[i] < threshold;
      if (flat && sidePerK != null && i < sidePerK.length) {
        // 侧面反响达标 = 在场者确有反应 = 外显兑现已送达读者，不算断供
        flat = sidePerK[i] < sideThreshold;
      }
      if (flat) {
        start ??= i;
      } else if (start != null) {
        if (i - start >= minRun) {
          zones.add((start: start, end: i - 1, chapters: i - start));
        }
        start = null;
      }
    }
    if (start != null && thrillPerK.length - start >= minRun) {
      zones.add((
        start: start,
        end: thrillPerK.length - 1,
        chapters: thrillPerK.length - start,
      ));
    }
    return zones;
  }

  /// 评审证据串：外显爽点断供带（注入 qaEvidence，与 Python
  /// `payoff_drought_ev_fragment` 同文）。
  ///
  /// 评审的「爽点与期待感」维度此前只看本章 💥/✨ 两个数，含蓄流单章并不异常
  /// （✨ 高），只有**跨章连低**才暴露断供——不给连低证据，评审会把
  /// 「十几章没有一次外显爽点」判成节奏紧凑。
  static String payoffDroughtEvFragment(
    List<double> thrillPerK, {
    double threshold = QualityRules.droughtThrillPerK,
    int minRun = QualityRules.droughtMinRun,
    List<double>? sidePerK,
    double sideThreshold = QualityRules.droughtSidePerK,
  }) {
    final List<({int start, int end, int chapters})> zones =
        payoffDroughtZones(thrillPerK,
            threshold: threshold,
            minRun: minRun,
            sidePerK: sidePerK,
            sideThreshold: sideThreshold);
    if (zones.isEmpty) return '';
    final int total =
        zones.fold<int>(0, (int s, ({int end, int start, int chapters}) z) =>
            s + z.chapters);
    final String spans = zones
        .take(4)
        .map((({int chapters, int end, int start}) z) =>
            '第${z.start + 1}-${z.end + 1}章(${z.chapters}章)')
        .join('、');
    return '外显爽点断供：连续 $total 章 💥<$threshold/千字且无在场者反应（$spans）'
        '——含蓄异动不能替代外显兑现，此区间「期待感」维度不应高于 40 分';
  }

  /// 末尾连续「无外显兑现」的章数（判断「已断供多久」）。
  ///
  /// 与 Python `novel_pipeline.trailing_drought_len` 同口径。传入**已完成的**前序
  /// 章序列（[ChapterPayoff] 按章序、最新在末尾），返回当前章之前处于断供中的
  /// 连续长度：0 表示上一章有外显兑现，>=3 表示已连着 3 章以上没有。
  ///
  /// 侧面反响逃生通道：某章 💥 低但在场者反应达标 = 外显兑现其实已送达读者，
  /// 不计断供（`THRILL_WORDS` 是 96 词闭合套话表，不套话的好稿天然被误伤）。
  static int trailingDroughtLen(
    List<ChapterPayoff> history, {
    double threshold = QualityRules.droughtThrillPerK,
    double sideThreshold = QualityRules.droughtSidePerK,
  }) {
    int k = 0;
    for (int i = history.length - 1; i >= 0; i--) {
      final ChapterPayoff p = history[i];
      final bool flat = p.thrillPerK < threshold && p.sidePerK < sideThreshold;
      if (!flat) break;
      k++;
    }
    return k;
  }

  /// 高频泛用词停用表（跨章复读的假阳性主要来源）。
  ///
  /// 这类词天然高频且不承载意象，出现在多章是**正常叙事**而非偷懒。
  /// 本表用真机 12.6 万字长篇（31 章）反推：取频次 top40 的 2~3 字候选逐个判读，
  /// 把「语法碎片」与「通用共词」全部停用——它们占了 top40 的 8 成
  /// （了一×429、一下×238、似的×202、什么×198、出来×198、一道×191…）。
  /// 不停用的话，检测器会满屏报「了一跨31章」，那份证据就没人信了。
  ///
  /// 只收**确实高频到不可能是意象**的词；宁可漏报也不误报（标记类功能，
  /// 漏了只是少给一条提示，误报会让整份证据不可信）。
  static const Set<String> imageryCommonStop = <String>{
    // ---- 语法碎片（真机 top 高频：虚词/连词/助词/代词/量词）----
    '了一', '一下', '似的', '什么', '出来', '一道', '自己', '那道', '顺着',
    '一声', '底下', '东西', '上的', '不是', '起来', '来的', '里那', '一个',
    '一样', '下来', '已经', '第三', '跟着', '出一个', '这会儿', '那么',
    // 真机复验补录（第一版遗漏，第二轮真机跑才暴露）：
    '出一', '下去', '上来', '出去', '进来', '回来',
    '缝里', '缝中', '里却', '以内', '以外',
    '之后', '之前', '此刻', '当下', '随即', '顿时',
    // 第三轮真机补录：感官动词短语（看见/听见/闻到…都是叙述动词，不是意象）
    '头看', '看见', '听见', '听到', '闻到', '看到', '望见', '瞥见',
    '看着', '听着', '摸着', '盯着', '望着', '瞧见', '见到', '想到',
    // ---- 单字虚词（1 字不会被抽取，此处仅作文档说明）----
    '了', '的', '着', '过', '是', '在', '不', '就', '也', '都', '还', '只',
    '把', '被', '让', '使', '有', '和', '这', '那', '我', '你', '他', '她',
    '它', '们', '个', '与', '及', '而', '之', '其', '但', '却', '又', '再',
    '才', '更', '最', '很', '太', '或', '并', '则', '乃', '亦',
    // ---- 方位/位置泛称 ----
    '下头', '旁处', '内侧', '外侧', '底部', '顶部', '当中', '上方', '下方',
    '其中', '之间', '中央', '边缘', '尽头', '前方', '后方', '里侧', '外头',
    // ---- 空间/场景共词（真机高频但非意象）----
    '台阶', '门口', '窗前', '窗外', '屋里', '屋外', '里面', '外面', '地方',
    '时候', '身边', '面前', '眼前', '身后', '头上', '脚下', '手里', '手中',
    '地上', '地下', '墙头', '房顶', '墙角', '房梁', '窗台', '门框',
    // ---- 人体泛称 ----
    '手指', '掌心', '指节', '指尖', '眼睛', '目光', '脸色', '身上', '声音',
    '手掌', '手腕', '肩膀', '胸口', '喉咙', '嗓子', '额头', '脸颊', '下巴',
    // ---- 修仙题材设定词（高频但属设定体系，非意象复用）----
    '丹田', '经脉', '灵力', '修为', '灵气', '真气', '内力', '金丹', '灵根',
    '神识', '气血', '骨骼', '骨髓', '窍穴', '灵光',
    // ---- 时间/程度/属性泛称 ----
    '片刻', '半晌', '一时', '许久', '良久', '微微', '轻轻',
    '缓缓', '渐渐', '慢慢', '深深', '狠狠', '默默', '骤然',
    '黑暗', '安静', '冷冷', '静静', '一片', '一阵', '一层',
    '气味', '味道', '神色', '气息', '影子', '光芒', '颜色', '声响',
    // ---- 动作连接 ----
    '走来', '走去', '停下', '抬头', '低头', '转身', '开口', '动手',
    '伸出', '收回', '抓住', '松开', '抬起', '落下', '站住', '起身',
    '移开', '移步', '往前', '往回', '冲出', '走出', '走进', '跑开',
    // ---- 叙事连接词 ----
    '于是', '然后', '接着', '随后', '忽然', '突然', '猛然',
    '终于', '仍旧', '依然', '仍然', '依旧', '始终', '只是', '但是', '可是',
  };

  /// 跨章意象复读检测（2026-09-30 新增，治「青苔 138 次」）。
  ///
  /// 既有重复检测全是**章内**的（`FanqieGateChecker.intraRepeat` 抓 120 字以上
  /// 整块重复、`adjacentRepetition` 抓相邻段相似），因此真机 12.6 万字长篇
  /// 整句重复率仅 0.26% 却是「读了三年还是那个调门」的观感——因为**同一个意象
  /// 被换着句式反复用**：实测「青苔」138 次、横跨全部 31 章。
  ///
  /// 本方法做两件既有检测都做不到的事：
  ///  ① 统计全书高频**意象/物象词**（2~3 字中文名词短语）出现次数与章分布；
  ///  ② 标出「在一本书里横跨 ≥[spreadChapters] 章反复出现」的高复读词。
  ///
  /// 定位是**标记供人工复核**，不是判废线：一个意象出现 20 次可以是风格母题，
  /// 出现 138 次且横跨全部章节则是偷懒。阈值默认给得宽。
  ///
  /// [exclude] 供调用方传入**人名/专名**（主角「陆沉」真机出现 298 次，
  /// 那是人物名不是意象复用），从候选中剔除。
  static List<({String term, int total, double perThousand, int chapters})>
      crossChapterImagery(
    List<String> chapterTexts, {
    int minTotal = 40,
    double minPerThousand = 1.0,
    int spreadChapters = 8,
    List<String> exclude = const <String>[],
  }) {
    if (chapterTexts.length < spreadChapters) {
      return const <({String term, int total, double perThousand, int chapters})>[];
    }
    final int totalWords = chapterTexts.fold<int>(
        0, (int s, String t) => s + AppConstants.countWords(t));
    if (totalWords == 0) {
      return const <({String term, int total, double perThousand, int chapters})>[];
    }
    final Set<String> skip = <String>{...exclude, ...imageryCommonStop};
    final Map<String, int> total = <String, int>{};
    final Map<String, int> spread = <String, int>{};
    for (final String t in chapterTexts) {
      // 同一章内同一词只计一次章分布（否则一章里刷 20 次就虚高「跨章」）
      final Set<String> seenInChapter = <String>{};
      for (final MapEntry<String, int> e in _imageryCandidates(t).entries) {
        if (skip.contains(e.key)) continue;
        total[e.key] = (total[e.key] ?? 0) + e.value;
        if (seenInChapter.add(e.key)) spread[e.key] = (spread[e.key] ?? 0) + 1;
      }
    }
    final List<({String term, int total, double perThousand, int chapters})> out =
        <({String term, int total, double perThousand, int chapters})>[];
    total.forEach((String term, int n) {
      final int ch = spread[term] ?? 0;
      if (n < minTotal || ch < spreadChapters) return;
      final double pk = n / totalWords * 1000;
      if (pk < minPerThousand) return;
      out.add((
        term: term,
        total: n,
        perThousand: double.parse(pk.toStringAsFixed(2)),
        chapters: ch,
      ));
    });
    out.sort((a, b) => b.total.compareTo(a.total));
    return out;
  }

  /// 意象候选的虚词黑名单（含 1 字判定用字符类）。
  static final RegExp _imageryStopword =
      RegExp(r'[了的着过是在有和就不都也很又还只把被让使个们这那我你他她它]');

  /// 抽单章的 2~3 字意象候选词及其词频。
  ///
  /// 判据（刻意保守，避免把「一个」「这样」这类虚词当意象）：
  ///  · 长度 2~3 个汉字；
  ///  · 不含虚词/常用动词字（的了着过是在有和就不都也很又还只把被让使）；
  ///  · 不在 [imageryCommonStop] 泛用词停用表里。
  ///
  /// 降噪：2 字链与 3 字链大量重叠（「青苔」与「台阶的」这类会互相吞掉噪声）。
  /// 规则是**3 字优先**——若某 3 字链的频次达到其内部 2 字子链的 60% 以上，
  /// 说明这 3 字本身是稳定意象，删掉两个 2 字子链的独立计数（读者感知的是
  /// 完整意象，不是它的碎片）。
  static Map<String, int> _imageryCandidates(String text) {
    final Map<String, int> freq = <String, int>{};
    final String flat = text.replaceAll(RegExp(r'[^\u4e00-\u9fff]'), '');
    for (int i = 0; i + 1 < flat.length; i++) {
      final String two = flat.substring(i, i + 2);
      if (_imageryStopword.hasMatch(two) || imageryCommonStop.contains(two)) {
        continue;
      }
      freq[two] = (freq[two] ?? 0) + 1;
      if (i + 2 < flat.length) {
        final String three = flat.substring(i, i + 3);
        if (!_imageryStopword.hasMatch(three) &&
            !imageryCommonStop.contains(three)) {
          freq[three] = (freq[three] ?? 0) + 1;
        }
      }
    }
    // 跨边界碎片剪枝（真机复验发现的关键缺陷）。
    //
    // 滑窗切出的 3 字链大量是「跨词边界的垃圾」：把「陆沉抬手」切成
    // 「陆沉抬」「沉抬手」「抬手陆」——三个都不成词，但每个频次都很高，
    // 于是刷满榜单、把真正的意象（青苔）挤出去。而按**完整词**统计的
    // 「陆沉」频次必然 ≥ 任一碎片（碎片只是它出现次数的子集）。
    //
    // 剪枝判据：3 字链的频次必须**严格高于**它内部任一 2 字子链。
    //  · 「陆沉抬」频次 = 陆沉频次（同一批出现位置切出来的）→ 相等 → 纯碎片，剪掉；
    //  · 「青苔」频次也等于其出现次数，但它的 2 字子链（青/苔/青苔的邻接链）
    //    因为不是独立成词而频次更低 → 保留。
    // 即：独立意象的子链频次必然低于自身，跨边界碎片则与之持平。
    final List<String> threes = freq.keys
        .where((String k) => k.length == 3)
        .toList(growable: false);
    for (final String three in threes) {
      final int n3 = freq[three]!;
      if (n3 < 3) continue;
      bool isFragment = false;
      for (int k = 0; k < 2; k++) {
        // 子链频次与自身持平 → 说明这 3 字只是某个 2 字词的另一种切法
        if ((freq[three.substring(k, k + 2)] ?? 0) >= n3) {
          isFragment = true;
          break;
        }
      }
      if (isFragment) {
        freq.remove(three);
        continue;
      }
      // 3 字链是独立意象：剪掉被它覆盖的 2 字碎片（避免同一个意象占两个名额）
      for (int k = 0; k < 2; k++) {
        final String sub = three.substring(k, k + 2);
        if ((freq[sub] ?? 0) <= 0) continue;
        if (n3 * 10 >= (freq[sub] ?? 0) * 6) freq.remove(sub);
      }
    }
    return freq;
  }

  /// 跨章「对白塌陷」检测（2026-09-30 新增）。
  ///
  /// 【实测结论】真机 33 章 / 12.6 万字长篇：**30 章里有 29 章对白占比 <15%**，
  /// 番茄要求 25%~45%。这不是个别章塌陷，而是**全书性的对白不足**——
  /// 写手在用连续叙述推进剧情，读者在移动端缺少喘息与代入的抓手。
  /// 其中第 5、9 章**一个引号都没有**（纯独白章），最严重。
  ///
  /// 【为何既有检查看不见】
  /// ① [FanqieGateChecker] 的 `minDialogue` 是**单章**判定，而那本真机的评审
  ///    阶段被配额掐断（jsonl 零条 review 记录），根本没跑到；
  /// ② [NovelQualityChecker.overallScore] 的对白扣分只压**分数**，
  ///    不产出「哪几章塌了」的可执行清单；
  /// ③ 跨章视角此前没有这个维度——单章各判各的，没人回答「这本书有多少章没人说话」。
  ///
  /// 口径复用 [dialogueRatioOf]（引号内字数 / 总字数），与番茄 25%~45% 同源，
  /// **不另起标准**。阈值 [ratioThreshold] 取 0.15 而非 0.25：0.25 是「建议」，
  /// 0.15 附近是番茄闸门 [FanqieGateChecker.minDialogue] 的下限，低于它即算塌陷。
  static List<({int idx, double ratio, int words})> dialogueCollapseChapters(
    List<({int idx, String content})> chapters, {
    double ratioThreshold = 0.15,
    int minWords = 800,
  }) {
    final List<({int idx, double ratio, int words})> out =
        <({int idx, double ratio, int words})>[];
    for (final ({String content, int idx}) c in chapters) {
      final int words = AppConstants.countWords(c.content);
      // 短章不判：几百字的样本对白占比天然低，没有可比性。
      if (words < minWords) continue;
      final double r = dialogueRatioOf(c.content);
      if (r < ratioThreshold) {
        out.add((idx: c.idx, ratio: r, words: words));
      }
    }
    return out;
  }

  /// 评审证据串：对白塌陷（注入 qaEvidence）。
  ///
  /// 单章对白低不一定是问题（叙述章可以有），但**成片**塌陷是结构问题——
  /// 读者会觉得「这本书没人说话」。故证据里同时给出塌陷章数与占比，
  /// 让评审判断是偶发还是系统性。
  static String dialogueCollapseEvFragment(
    List<({int idx, String content})> chapters, {
    double ratioThreshold = 0.15,
    int minWords = 800,
  }) {
    final List<({int idx, double ratio, int words})> hits =
        dialogueCollapseChapters(chapters,
            ratioThreshold: ratioThreshold, minWords: minWords);
    if (hits.isEmpty) return '';
    final int judged = chapters
        .where((({String content, int idx}) c) =>
            AppConstants.countWords(c.content) >= minWords)
        .length;
    if (judged == 0) return '';
    final String list = hits
        .take(8)
        .map((({double ratio, int words, int idx}) h) =>
            '第${h.idx}章(${(h.ratio * 100).toStringAsFixed(1)}%)')
        .join('、');
    final String more = hits.length > 8 ? ' 等 ${hits.length} 章' : '';
    return '对白塌陷：${hits.length}/$judged 章引号内字数占比低于 '
        '${(ratioThreshold * 100).round()}%（$list$more）'
        '——移动端靠对白推进，纯独白章完读率会掉；'
        '「节奏」「人物感」维度不应高于 50 分，宜补人物交锋或内心独白转对话';
  }

  /// 评审证据串：跨章意象复读（注入 qaEvidence）。
  ///
  /// 给评审一个此前完全不存在的信号：「你这本书在反复合用同一个意象」。
  /// 单看每章都合规（每章只出现 3~5 次，不触发章内重复），只有跨章视角才暴露。
  ///
  /// [exclude] 必须传入**人名/专名**：真机主角「陆沉」全书 298 次，
  /// 那是人物名不是意象复用，混进证据会让评审误判「氛围描写重复」。
  static String imageryEvFragment(
    List<String> chapterTexts, {
    int minTotal = 40,
    double minPerThousand = 1.0,
    int spreadChapters = 8,
    List<String> exclude = const <String>[],
  }) {
    final List<({String term, int total, double perThousand, int chapters})> hits =
        crossChapterImagery(chapterTexts,
            minTotal: minTotal,
            minPerThousand: minPerThousand,
            spreadChapters: spreadChapters,
            exclude: exclude);
    if (hits.isEmpty) return '';
    final String top = hits
        .take(5)
        .map((({int chapters, int total, double perThousand, String term}) h) =>
            '${h.term}×${h.total}(跨${h.chapters}章)')
        .join('、');
    return '跨章意象复读：$top'
        '——同一批意象在多章反复出现，「氛围描写」维度应下调，'
        '建议替换为具体可感的物件细节而非同一意象换句式复用';
  }

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
      bodyHits += _countOccurrences(text, w);
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
        ? _countOccurrences(text, '的') / words * 100
        : 0.0;

    // 3) 叠词修饰密度（每千字）
    int advHits = 0;
    for (final String w in _aiAdverbs) {
      advHits += _countOccurrences(text, w);
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
    final int w = QualityRules.triadEndWindow;
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

  /// 统计子串出现次数。
  static int _countOccurrences(String text, String needle) {
    if (needle.isEmpty) return 0;
    int count = 0;
    int idx = 0;
    while (true) {
      final int found = text.indexOf(needle, idx);
      if (found < 0) break;
      count++;
      idx = found + needle.length;
    }
    return count;
  }

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
