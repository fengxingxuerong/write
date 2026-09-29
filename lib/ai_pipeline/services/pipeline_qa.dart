import 'dart:math' as math;

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/utils/text_index.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/models/character.dart';

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
  static const List<String> negations = <String>[
    '不', '没', '无', '没有', '并未', '不曾', '决不', '毫无',
  ];

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
  static const List<String> _hookWords = <String>[
    // 直白突变 / 意外
    '突然', '猛然', '竟然', '就在这时', '就在此时', '刹那', '一瞬',
    '缓缓', '响起', '逼近', '袭来', '浮现', '动静', '不对劲',
    '怎么回事', '为什么', '究竟', '难道', '敲门声', '脚步声',
    // 威胁 / 窥伺 / 追踪
    '目光', '视线', '盯着', '没开过口', '探猎物', '不安全', '跟着',
    '尾随', '跟踪', '有人', '像有人', '一道人影', '一个声音', '一声冷笑',
    '有什么', '探出来', '那只眼', '正看着他', '暗处', '暗影',
    // 身份伏笔 / 反常细节 / 诡谲意象
    '旧疤', '刃口', '符箓', '未展开', '惨白', '泛着', '异动',
    '火燎', '咬掉', '又闪', '又响', '醒了过来', '暗红', '风铃', '渗',
    // 悬而未决 / 未知
    '看不清', '看不透', '将落未落', '还没有断', '没断', '发烫', '滴水',
    '黑影', '还没', '尚未', '来不及', '远远没', '不知何时', '轰', '嗡',
  ];

  /// 章末三件套收尾词表（FANQIE 规则 20「禁止发烫/亮起/苏醒收尾」+
  /// 规则 10 + scene_prompt「禁止发热/发光/苏醒收束」——与 Python
  /// `fanqie_review.TRIAD_END_WORDS` 同步）。
  ///
  /// 长词在前（像有什么东西醒了 > 醒了过来 > 醒了、亮了起来 > 亮了）；
  /// 「亮」字族带天字排除（「天亮了」是时间过渡，不是发光物件收束）。
  /// 校准：tool/probe_ending_and_simile.py 三窗口敏感性——末句 6.9% /
  /// 末60字 11.2% / 末200字 25.9%，取末 60 字收束窗口（与 Python
  /// TRIAD_END_WINDOW 同步）。
  static const List<String> _triadEndWords = <String>[
    '像有什么东西醒了', '醒了过来', '亮了起来', '亮起来',
    '发烫', '发热', '亮起', '苏醒', '醒来', '醒了', '发光', '亮了',
  ];

  /// [_hookWords] 中属三件套性质的成员：作为**唯一**尾部钩子信号时不采信。
  static const Set<String> _triadHookOnly = <String>{'发烫', '醒了过来'};

  /// 开场节奏·强信号词（双字/特定短语，1 个即视为快速进入事件）。
  ///
  /// 双级判定避免单字词（碎/撞/压）在比喻语境（"像纸一样一碰就碎"）
  /// 的误报：强信号 1 个达标，弱信号需 ≥2 个才达标。
  static const List<String> _openingStrong = <String>[
    '穿越', '醒来', '重生', '系统', '觉醒', '废物', '杂种', '契约',
    '丹田', '灵根', '考核', '耳光', '滚出',
  ];

  /// 开场节奏·弱信号词（单字动词/名词，需 ≥2 个同时出现）。
  static const List<String> _openingWeak = <String>[
    '闯', '砸', '吼', '骂', '跪', '杀', '死', '血', '痛',
    '摔', '怒', '冲', '撞', '剑', '刀', '雷', '震', '裂', '碎',
    '废', '辱', '欺', '压', '滚', '魂',
  ];

  /// 爽点信号词（打脸 / 升级 / 收获 / 揭露 四大类）。
  ///
  /// 番茄签约的核心追读指标：每千字爽点数过低 = 读者流失风险。
  /// 词表选「语义明确」的词，避免「获得/发现/到手」类宽泛误报。
  static const List<String> thrillWords = <String>[
    // 升级类
    '突破', '觉醒', '晋升', '顿悟', '蜕变', '脱胎换骨', '突破瓶颈', '进阶',
    // 打脸类
    '哑口无言', '脸色铁青', '目瞪口呆', '鸦雀无声', '颜面扫地',
    '下不来台', '难以置信', '不敢置信', '灰头土脸', '噤声', '讪讪',
    // 具象反应信号（回归自《逆命修仙录》短样：对手震惊/打脸常写身体反应）
    '愣住', '说不出话',
    // 收获类
    '收入囊中', '白捡', '意外之喜', '认主', '获得传承', '获得功法',
    '大丰收', '捡到宝', '至宝', '契约',
    // 揭露类
    '真相大白', '水落石出', '恍然大悟', '惊觉', '识破', '原来是你',
    '竟然是他', '谜底', '露出真面目',
    // 具象真相信号（真相反转/物件对照的具象写法）
    '一模一样', '对得上',
    // —— 2026-09-07 题材扩展（都市/悬疑/末世/科幻/游戏）——
    // 系统流 / 都市金手指
    '系统激活', '绑定成功', '完成任务', '任务完成', '解锁', '权限提升',
    '经验值', '奖励到账', '到账', '首杀', '通关', '满级',
    // 打脸通用（都市/职场/商战）
    '碾压', '碾压全场', '全场震惊', '刮目相看', '俯首',
    '乖乖交出', '低头认错', '自取其辱', '搬起石头', '打脸',
    // 悬疑/推理反转
    '真凶', '反转', '神反转', '真相浮出', '证据确凿',
    '铁证如山', '一锤定音', '当场拆穿', '原形毕露', '身份暴露',
    // 末世/科幻 变强
    '进化', '异能觉醒', '获得异能', '能力提升', '升级成功', '吞噬成功',
    '融合成功', '突破极限', '超频', '进化完成', '变异强化', '战力飙升',
    // 游戏/竞技
    '击败', '完胜', '绝杀', '反超', '夺冠', '晋级', '破纪录', 'MVP',
    '团灭', '一波带走',
  ];

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
  static const List<String> powerSurgeWords = <String>[
    '发烫', '温热', '流转', '苏醒', '凝聚', '暴涨', '充盈', '贯通',
    '蠕动', '微光', '亮了一亮', '震颤', '嗡鸣', '顺着经脉', '涌入丹田',
    '沉进丹田', '吞吸', '周天', '拱了一下', '醒了', '睁开眼',
    // —— 2026-09-07 题材扩展（异能/系统/末世）——
    '星纹', '光纹', '发亮', '一明一灭', '热流', '涌入体内', '灌入',
    '钻进体内', '钻进经脉', '皮肉底下', '骨刺', '断茬', '长出',
    '顶开', '破土', '抽芽', '生根', '融合', '数据流', '面板',
    '提示音', '嘀', '叮', '进度条', '金光', '青芒', '白光',
    '烫得', '灼热', '胀热', '酸麻', '发麻', '暴起', '腾起',
  ];

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
  static const List<String> sideReactionWords = <String>[
    // 围观路人震惊 / 失声 / 倒抽气
    '倒吸一口凉气', '倒吸凉气', '倒吸一口气', '倒抽一口凉气', '倒抽凉气',
    '失声', '惊呼', '骇然', '哗然', '炸开了锅', '全场哗然', '满座皆惊',
    '瞠目结舌', '目瞪口呆', '呆若木鸡', '看怪物一样', '看疯子一样',
    // 反派绝望 / 脸色骤变 / 怀疑人生
    '难以置信', '不可置信', '绝不可能', '怎么可能', '不可能',
    '脸色惨白', '面如死灰', '面色惨白', '脸色铁青', '面色铁青',
    '两腿发软', '踉跄后退', '连连后退', '一屁股坐', '瘫坐在地',
    '冷汗直流', '冷汗涔涔', '汗如雨下', '道心动摇', '道心崩溃',
    // 权威重估 / 重新审视 / 暗自心惊
    '暗自心惊', '心中巨震', '心头巨震', '瞳孔骤缩', '瞳孔猛缩',
    '倒退数步', '倒退几步', '刮目相看', '重新审视', '倒吸冷气',
  ];

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
    double threshold = 0.5,
    int minRun = 3,
    List<double>? sidePerK,
    double sideThreshold = 0.3,
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
    double threshold = 0.5,
    int minRun = 3,
    List<double>? sidePerK,
    double sideThreshold = 0.3,
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
    double threshold = 0.5,
    double sideThreshold = 0.3,
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
    double threshold = 0.5,
    double surgeOk = 1.0,
    int droughtMinRun = 3,
    double side = 0.0,
    double sideOk = 0.3,
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
    double threshold = 0.5,
    double sideOk = 0.3,
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
  static const List<String> _aiAdverbs = <String>[
    '微微', '轻轻', '淡淡', '深深', '缓缓', '悄悄', '默默', '隐隐',
    '幽幽', '怔怔', '静静', '浅浅',
  ];

  /// 句首连接词（AI 爱用「然而/于是/随即」起句，真人少用）。
  static const List<String> _sentenceConnectors = <String>[
    '然而', '但是', '因此', '与此同时', '于是', '随即', '紧接着',
    '然后', '不过', '可是',
  ];

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
  static const List<String> _bodyReactionWords = <String>[
    '发烫', '发凉', '发冷', '嗓子发干', '喉咙发干', '汗毛',
    '头皮发麻', '掌心出汗', '手心出汗', '脊背发凉', '寒意',
    '牙根发酸', '后槽牙', '呼吸一窒', '心跳漏拍', '胃里发紧',
    '指尖发麻', '指尖发凉', '太阳穴一跳',
  ];

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
    final String seg =
        text.length > 60 ? text.substring(text.length - 60) : text;
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
