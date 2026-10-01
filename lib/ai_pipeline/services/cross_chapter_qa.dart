import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/engine/quality/quality_rules.g.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';

/// 跨章质检维度：外显爽点断供 / 意象复读 / 对白塌陷（从 pipeline_qa.dart 拆出）。
///
/// **只做文件切分，判定逻辑与口径一字未改**：`PipelineQa` 保留同名静态方法薄封装
/// 转调到这里，故 tool/ 与 lib/ 下所有调用点无需改动。
///
/// 这三个维度的共同点是**单章看不出问题**——每章单独看都合规，只有把多章排在一起
/// 才暴露「连着 5 章没爽点」「同一个意象横跨 30 章」「半本书没人说话」。它们因此
/// 共处一文件：阈值标定与误报取舍的推理过程互相引用，拆开反而看不懂。
///
/// 与 Python 的对应关系（改一处必须同步另一处）：
/// - payoffDroughtZones / payoffDroughtEvFragment / trailingDroughtLen
///   <-> generate_novel.payoff_drought_zones / novel_pipeline.trailing_drought_len
/// - imageryCommonStop / 跨章意象复读 <-> generate_novel.imagery_repeat_chapters
/// - dialogueCollapseChapters <-> generate_novel.dialogue_collapse_chapters
///
/// 依赖说明：`ChapterPayoff`（跨章爽点度量）与 `dialogueRatioOf`（对白占比）仍留在
/// 上层，这里直接复用，不另起一份口径。
class CrossChapterQa {
  const CrossChapterQa._();
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
      final double r = PipelineQa.dialogueRatioOf(c.content);
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
}
