import 'dart:math' as math;

import 'package:novel_writer/core/utils/text_index.dart';
import 'package:novel_writer/services/sensitive_words.dart';
import 'package:novel_writer/engine/quality/quality_rules.g.dart';

/// 定点修字数下限（与 Python 侧 `fanqie_review.FIX_MIN_RATIO` 同值同源）。
///
/// 低于此比例整份产出会被采纳守卫拒绝（守卫阈值为 `QualityRules.editorMinRatio`
/// =0.85，Python 侧 apply_text_patch 同值）——提示词必须比守卫更严一档，并写明
/// 「评审的压缩诉求让位于本下限」，否则模型会照
/// 【改写要求】的「删水段/短句」把整章压掉三成，产出全被拒、定点修白跑
/// （门禁 v7 实测 4 次：4087→2847 / 3465→2718 / 4176→2707 / 5983→1517）。
const double fixMinRatio = QualityRules.fixMinRatio;

/// 番茄过审闸门（本地零成本，纯函数，可单测）。
///
/// 与 `scripts/fanqie_review.py` 同口径：两边指标一一对应，改任一端必须同步另一端
/// （测试 `test/engine/quality/fanqie_gate_checker_test.dart` 钉住了关键阈值）。
///
/// 它和 [NovelQualityChecker] 的分工：
/// - [NovelQualityChecker] 管「AI 味/重复」这类文笔卫生问题；
/// - 本类管「能不能过编辑初审」：合规红线、首屏、每章四件套、完读率格式、
///   以及**大纲↔正文一致性**（写手跑题是本项目历史上最大的质量事故）。
class FanqieGateAction {
  const FanqieGateAction._(this.label, this.penalty);

  /// 展示名。
  final String label;

  /// 扣分。
  final double penalty;

  /// 必须重写（结构性问题）。
  static const FanqieGateAction rewrite =
      FanqieGateAction._('重写', 8.0);

  /// 需要修改（格式/节奏问题）。
  static const FanqieGateAction revise = FanqieGateAction._('修改', 4.0);

  /// 仅提示。
  static const FanqieGateAction note = FanqieGateAction._('建议', 1.5);
}

/// 一条不达标项。
class FanqieGateIssue {
  const FanqieGateIssue(this.type, this.message, this.action);

  /// 类别（首屏/对白/一致性…）。
  final String type;

  /// 人读说明。
  final String message;

  /// 处置等级。
  final FanqieGateAction action;

  @override
  String toString() => '[${action.label}] $type：$message';
}

/// 红线命中。
class FanqieRedlineHit {
  const FanqieRedlineHit(this.category, this.word, this.context, this.veto);

  final String category;
  final String word;
  final String context;

  /// true = 一票否决；false = 仅提示（情节性使用）。
  final bool veto;
}

/// 闸门结论。
class FanqieGateReport {
  const FanqieGateReport({
    required this.score,
    required this.issues,
    required this.redlines,
    required this.dialogueRatio,
    required this.fillerRatio,
    this.fillerCounted = 0,
    required this.worldHit,
    required this.worldTotal,
    this.worldMissing = const <String>[],
    this.words = 0,
  });

  /// 0~100 分。
  final double score;

  /// 不达标项。
  final List<FanqieGateIssue> issues;

  /// 红线命中。
  final List<FanqieRedlineHit> redlines;

  final double dialogueRatio;
  final double fillerRatio;

  /// 参与水段统计的长段数（<8 时百分比仅供参考）。
  final int fillerCounted;
  final int worldHit;
  final int worldTotal;

  /// 正文里尚未出现的大纲世界观专名（≤8 个展示用）。
  ///
  /// 定点修指令要靠它点名：只报「专名一个都没出现」而不给清单，模型无从下手
  /// （门禁 v7 第 13 项「世界观未落地」定点修一轮后仍残留的直接原因）。
  final List<String> worldMissing;

  /// 正文汉字数（0 = 未知；阻断项判定需要它）。
  final int words;

  /// 阻断级硬伤（不修完不给「可投」）。与 Python 侧 `blocking_reasons` 同口径。
  ///
  /// 与「扣分项」分开的原因：分数只回答「这一章写得好不好」，阻断项回答
  /// 「这本书现在能不能投」。实测事故：92 分的章里混着补写模型的操作说明
  /// （元话语残留），旧的 `pass` 只看分数 → 判「可投」且 fixPrompt 返回空串，
  /// 那一章再也没被修，脏文本一路留到成书。
  List<String> get blockers {
    final List<String> out = <String>[];
    for (final FanqieGateIssue e in issues) {
      if (e.type == '泄漏') {
        out.add('提示词/元话语残留');
      } else if (e.type == '重复' && e.message.contains('章内大段重复')) {
        out.add('章内大段重复');
      } else if (e.type == '一致性' && e.message.contains('题材漂移')) {
        out.add('题材漂移');
      } else if (e.type == '一致性' && e.message.contains('没接住主角')) {
        out.add('主角缺席');
      } else if (e.type == '一致性' && e.message.contains('没接住设定')) {
        out.add('世界观未落地');
      }
    }
    if (words > 0 && words < 1500) out.add('单章仅 $words 字');
    return out;
  }

  /// 是否达线（无否决红线、无阻断级硬伤且分数 >= 80）。
  bool get pass => !hasVeto && blockers.isEmpty && score >= 80;

  /// 是否存在一票否决级红线。
  bool get hasVeto => redlines.any((FanqieRedlineHit h) => h.veto);

  /// 一句话摘要（进生成日志/提示）。
  String get summary {
    if (hasVeto) return '番茄闸门：命中 ${redlines.length} 处合规红线，需人工复核';
    if (pass) return '番茄闸门：$score 分 达线';
    return '番茄闸门：$score 分，${issues.length} 项不达标';
  }

  /// 不达标项里需要模型动手的那些（排除「仅建议」）。
  List<FanqieGateIssue> get blockingIssues => issues
      .where((FanqieGateIssue e) => e.action != FanqieGateAction.note)
      .toList();

  /// 把不达标项转成「只改问题处」的定点修指令（与 Python 侧 fix_prompt 同语义）。
  /// 达线且无阻断项时返回空串——调用方据此跳过一轮 LLM 调用。
  /// 有阻断项时即使分数达标也要出单（阻断项不修完不算过关）。
  String get fixPrompt {
    final List<FanqieGateIssue> todo = blockingIssues;
    if (todo.isEmpty || (pass && blockers.isEmpty)) return '';
    final StringBuffer b = StringBuffer()
      ..writeln('这一章要过番茄初审，评审器给出以下硬伤。请**只针对这些点改写**，'
          '保持人物名、事件顺序、已埋伏笔完全不变，不要重写无关段落：');
    for (final FanqieGateIssue e in todo) {
      b.writeln('- ${e.type}：${e.message}');
    }
    for (final FanqieRedlineHit h in redlines.where((x) => x.veto)) {
      b.writeln('- 合规红线：出现「${h.word}」（${h.category}），换成不点名的写法');
    }
    // 字数硬约束：没有它时，模型会把【改写要求】的「删水段/25 字句/3 行段」整章执行，
    // 产出低于采纳下限被整份拒绝 → 定点修白跑（与 Python fix_prompt 同款条款）
    if (words > 0) {
      final int floor = (words * fixMinRatio).floor();
      b
        ..writeln()
        ..writeln('【字数硬约束·先看这条】改写后正文不得少于 $floor 字（原文 $words 字，'
            '最多允许压缩 ${((1 - fixMinRatio) * 100).round()}%）。'
            '「删水段」只许删与剧情无关的段落，且删掉多少就要用冲突/对白/动作/细节'
            '补足同等篇幅——**总字数不得下降**。若评审意见（如「篇幅偏长」）与本下限冲突，'
            '以本下限为准：压缩诉求请用「改写」（并句、去修饰、换更短的表达）满足，不靠删段。');
    }
    // 世界观专名缺失清单：与 Python 侧 fix_prompt 同口径——不点名缺哪些，模型改不动
    if (worldMissing.isNotEmpty &&
        todo.any((FanqieGateIssue e) => e.message.contains('世界观专名'))) {
      final int need = worldMissing.length < 5 ? worldMissing.length : 5;
      final String state =
          worldHit == 0 ? '一个都没出现' : '仅命中 $worldHit/$worldTotal';
      b
        ..writeln()
        ..writeln('【世界观专名·本条为阻断项，必须解决】下列专名取自本书大纲，'
            '当前正文$state，还缺 ${worldMissing.length} 个：'
            '${worldMissing.take(8).join('、')}')
        ..writeln('改写时必须把其中至少 $need 个自然织进正文（地名/机构/功法/器物/称谓皆可）：'
            '经由对白称呼、路牌招牌、他人提及、物件来历描写带出；专名按字面照抄，'
            '禁止换成近义词/简称/拼音（初审按字面命中判定）；'
            '禁止把专名列成清单、禁止整段解释设定、禁止为塞专名插入无关段落。');
    }
    b
      ..writeln()
      ..writeln('【改写要求】首屏 300 字必须有主角在场、正在发生的冲突、至少一句对白；'
          '主角本章至少做一次有代价的主动选择；对话占比提到 25%~45%；'
          '只删与剧情无关的水段（删多少就补多少，见上文【字数硬约束】）；句子尽量 25 字内，段落不超过 3 行。')
      ..writeln('**题材与世界观必须与本作一致**：不得出现现代词汇、不得更换主角、不得引入新故事线。')
      ..writeln('**只输出改写后的正文**：不要任何解释、说明、前言、字数报告或操作描述（写进正文即判废）。');
    return b.toString();
  }
}

/// 番茄过审闸门检查器。
class FanqieGateChecker {
  const FanqieGateChecker({
    this.genre = '',
    this.protagonist = '',
    this.worldTerms = const <String>[],
    this.minDialogue = QualityRules.minDialogueRatio,
    this.maxFiller = QualityRules.maxFillerRatio,
  });

  /// 题材（用于红线降级判断）。
  final String genre;

  /// 大纲主角名（查主角漂移）。
  final String protagonist;

  /// 大纲 world 里的专名（查世界观一致性）。
  final List<String> worldTerms;

  /// 对白占比下限。
  final double minDialogue;

  /// 水段率上限（%）。
  final double maxFiller;

  static final RegExp _chapterRe = RegExp(r'^\s*第\s*(\d+)\s*章');
  static final RegExp _han = RegExp(r'[\u4e00-\u9fff]');
  static final RegExp _sentSplit = RegExp(r'[。！？…；]+');
  static final RegExp _weatherOpen = RegExp(r'^\s*[^\n]{0,16}[雨雪霜雾风]');
  static final RegExp _namePat = RegExp(
      r'([\u4e00-\u9fff]{2,3})[，,、]?(?:说|道|问|答|笑|喊|盯|看|抬头|转身|点头|摇头|皱眉|站|蹲|伸手|开口)');

  /// 空白扁平化（去空白用）。旧实现在 6 处内联 `RegExp(r'\s+')`，
  /// 其中两处位于段落两两比对的 O(n²) 循环里，每次配对都重编一次正则。
  static final RegExp _ws = RegExp(r'\s+');

  /// 专名合法性校验 / 引号内片段 / 尾缀虚词（编译一次常驻）。
  static final RegExp _termOk = RegExp(r'^[\u4e00-\u9fffA-Za-z0-9·]{2,12}$');
  static final RegExp _quotedTerm =
      RegExp('[「『《“‘]([^\\n」』”’]{2,10})[」』”’]');
  static final RegExp _termTail = RegExp(r'[的地了]+$');

  /// 对白引号内片段（编译一次常驻）。
  static final RegExp _dialogueQuote =
      RegExp('[“"「『]([^”"」』]{1,200})[”"」』]');

  /// 冲突信号：首屏要带包袋。
/// 值来自 [QualityRules.conflictWords]（rules/quality_rules.json 生成，40 词）。
/// 2026-10-03 收编：本表原为 31 词硬编码，是 Python 表的真子集——实测
/// Python 独有的 9 词在 123 份真实成书上命中 66 份（53.7%），即过半成书
/// Dart 会漏判首屏冲突。收编后两端同源，不再有「子集漂移」。
  static const List<String> _conflict = QualityRules.conflictWords;

  /// 网文高频套句（同质化风险）。
  /// 值来自 [QualityRules.gateClichePhrases]（Dart 闸门口径 19 条）；
  /// Python 侧同名指标用的是另一张表（见 docs/quality-rules-current.md 第三节）。
  static const List<String> _cliche = QualityRules.gateClichePhrases;

  /// 「推进力」词：段落里出现即视为该段在推进剧情。
  static const List<String> _drive = <String>[
    '说', '道', '问', '答', '喊', '笑', '看', '抓', '推', '砸', '拔', '转身',
    '走', '跑', '冲', '拿', '递', '写', '敲', '点', '掀', '摸', '掏', '塞',
    '死', '伤', '血', '钱', '字', '信', '刀', '枪', '门', '窗', '牌', '图',
    '答应', '拒绝', '决定', '必须', '马上', '今晚', '三天', '名字',
  ];

  static const List<String> _active = <String>[
    '我决定', '我选', '我接', '我应', '我来', '我先', '当场', '主动', '开口',
    '提出', '要求', '接下', '应下', '带着人', '连夜', '先把', '他决定', '他选',
    '她要', '他要', '我偏', '我会', '我自己', '不靠', '就算', '也要', '给我',
    '等着', '记住', '他反问', '他拒绝', '他点头', '他开口', '他伸手', '他站起身',
    '他抢', '他夺', '他扫', '他赌', '他押', '他扯', '他拆开', '他抬手', '他推开', '他回', '他接',
  ];
  static const List<String> _passive = <String>[
    '不得不', '只能', '只好', '由不得', '被人', '无从', '无处可',
    '听天由命', '没办法', '被拖', '被推', '被换', '被安排',
  ];

  /// 骨架/提示词泄漏（漏进正文即判废）。
  /// 值来自 [QualityRules.promptLeak]（rules/quality_rules.json 生成）。
  static const List<String> _leak = QualityRules.promptLeak;

  /// 元话语/指令残留（模型把「补写操作说明」当正文吐出来 = 直接判废）。
  ///
  /// 实测事故：钩子补写返回「我拿到的指令是补写钩子，不是扩写…」被原样拼进第 1 章末尾，
  /// 旧词表只覆盖骨架词，抓不到这类元话语。选词原则：只收叙事里不可能出现的短语。
  static const List<String> _metaTalk = QualityRules.metaTalk;

  /// 题材漂移：给非现代题材用的现代生活标志词。
  ///
  /// 实测事故：玄幻书第 3 章整章变成现代都市悬疑（路灯/手机/牛皮纸袋/面包车），
  /// 逐章本地评审仍给 84 分，直到终审官通读才发现。玄幻里也可能合法的词（钥匙/医院/巷口）
  /// 一律不收，避免误伤。
  static const List<String> _modernMarkers = QualityRules.modernMarkers;

  /// 需要锁题材的非现代题材（都市/校园/悬疑等题材不做现代词漂移判定）。
  static const List<String> _ancientGenres = QualityRules.ancientGenres;

  /// 章内重复块最短字数（与 Python 侧 INTRA_REPEAT_MIN_BLOCK 同口径）。
  static const int intraRepeatMinBlock = QualityRules.intraRepeatMinBlock;

  /// 章内重复指纹长度（与 Python 侧 INTRA_REPEAT_GRAM 同口径）。
  static const int _intraGram = QualityRules.intraRepeatGram;

  /// 滑动指纹的滚动哈希底数与掩码（模 2^30 运算，保持 int 有界且不依赖平台）。
  static const int _hashBase = 31;
  static const int _hashMask = 0x3FFFFFFF;

  /// 番茄专有红线类别（其余类别走 [SensitiveWordsService] 内置词库）。
  ///
  /// 2026-10-03 收编：本表原为 5 类 56 词硬编码，其中 4 类是
  /// `QualityRules` 生成物的**真子集**（时政 13/30、未成年 11/17、
  /// 品牌真人 17/25、教唆 9/15）。子集意味着 Dart 侧会**漏判**——
  /// Python 有词、Dart 无词 → 不判违规，而漏判性质比多判严重。
  /// 已按 scripts/ab_rules_parity.py 在 134 份真实成书实测：这 4 类
  /// Python 独有的 37 词**零命中**，故取全集不新增任何误判，同时消除漏判。
  ///
  /// 「宗教民族」**故意不收编**：它与生成物双向独有（Dart 独有
  /// 邪教徒/异教徒该死/侮辱/藏传佛教活佛转世），且生成物独有的「礼拜」
  /// 在 134 份真实成书里命中 2 份——合并会立刻改变这 2 份的判定，
  /// 而 Dart 独有的「侮辱」在网文叙述里极易误伤。属口径设计分歧，
  /// 须产品裁决，不得由本文件单方面对齐（见 quality_rules.json
  /// 的 redlineReligion doc 与 docs/quality-rules-current.md 第三节）。
  ///
  /// 改词表请改 rules/quality_rules.json 再跑 scripts/rules_codegen.py。
  static const Map<String, List<String>> _extraRedline = <String, List<String>>{
    '时政敏感': QualityRules.redlinePolitics,
    // 宗教民族：故意保留 Dart 自有词表（见上方说明），不引生成物。
    '宗教民族': <String>[
      '邪教徒', '圣战', '异教徒该死', '侮辱', '藏传佛教活佛转世', '请神', '问米',
      '通灵', '招魂', '借尸还魂', '苗疆蛊', '蛊毒', '降头', '养小鬼',
    ],
    '未成年风险': QualityRules.redlineMinorRisk,
    '现实品牌与真人': QualityRules.redlineBrandCelebrity,
    '教唆细节': QualityRules.redlineIllegalDetail,
  };

  /// 「教唆/推广」语境标记：只有伴随这些词，情节类红线才升级为否决。
  ///
  /// 值来自 [QualityRules.instructionMarks]（rules/quality_rules.json 生成，
  /// 2026-10-03 收编）。此前本文件与 Python `INSTRUCTION_MARKERS` 各写一份
  /// （Dart 21 词 / Python 24 词），漂移只能靠注释约束；收编前已按
  /// scripts/ab_rules_parity.py 在 134 份真实成书上测**否决条数增量**：
  /// 两表同为 5 条否决、增量 +0，即改判定零风险，故取 Python 全集。
  /// 改词表请改 JSON 再跑 scripts/rules_codegen.py，不要在此写字面量。
  static const List<String> _instructionMark = QualityRules.instructionMarks;

  /// 这些类别在小说里作为情节元素出现是正常的，只有教唆语境才否决。
  ///
  /// 键必须与 [_extraRedline] 的**实际分类名**逐字一致，否则该类别永远
  /// `narrativeOk == false` → 恒为「否决」，教唆语境判定形同虚设。
  ///
  /// 2026-10-03 修复：本集合原本漏了 `教唆细节`——即 [_extraRedline] 里
  /// 教唆类红线的**真实分类名**。后果是该类红线完全无法区分「叙事提及」
  /// 与「教唆传授」：小说里写「他妹妹欠下高利贷」也会被判否决，
  /// 正是 Python 侧注释记载要避免的「误伤《碎星航线》第 1 章」。
  /// （Python 侧对应键是 `教唆与违法细节`——同一语义、不同命名，
  /// 故两端键集按各自的分类命名体系对齐，不强行统一成同一个字符串。）
  ///
  /// 两类教唆路径都要接上白名单，二者不可只留其一：
  /// - `教唆细节`：番茄专有红线（[_extraRedline]）；
  /// - `违法违规`：编辑自查词库（[SensitiveWordsService]）里的违法操作类。
  static const Set<String> _narrativeOkCategories = <String>{
    '教唆细节', '违法违规', '宗教民族', '现实品牌与真人', '广告引流',
  };

  /// 用 [index] 预筛后取 [words] 中命中的子集（保持 [words] 原有顺序）。
  ///
  /// [TextIndex.mayContain] 为 false 时 `text.contains(w)` 必为 false（见
  /// `text_index.dart` 的安全契约），故这里只可能**少做**扫描、不可能改变
  /// 命中集合——与旧的 `words.where(text.contains)` 逐字等价。
  static List<String> _hitsOf(
    List<String> words,
    String text,
    TextIndex index,
  ) =>
      words.where((String w) => index.mayContain(w) && text.contains(w)).toList();

  /// 执行检查。[prevContent] 用于跨章自我重复比对（可空）。
  FanqieGateReport check(
    String content, {
    String prevContent = '',
    int chapterIndex = 1,
  }) {
    final String text = content.trim();
    final List<FanqieGateIssue> issues = <FanqieGateIssue>[];
    final int words = _hanCount(text);
    if (words == 0) {
      return const FanqieGateReport(
        score: 0,
        issues: <FanqieGateIssue>[
          FanqieGateIssue('结构', '正文为空', FanqieGateAction.rewrite),
        ],
        redlines: <FanqieRedlineHit>[],
        dialogueRatio: 0,
        fillerRatio: 100,
        worldHit: 0,
        worldTotal: 0,
      );
    }

    if (words < 1800) {
      issues.add(FanqieGateIssue('结构', '本章仅 $words 字（番茄单章建议 2000~3000）',
          FanqieGateAction.rewrite));
    } else if (words > 3800) {
      issues.add(FanqieGateIssue('结构', '本章 $words 字偏长，建议压到 3000 内',
          FanqieGateAction.note));
    }

    // ---- 首屏 ----
    final String head = text.length > 320 ? text.substring(0, 320) : text;
    if (_weatherOpen.hasMatch(head)) {
      issues.add(const FanqieGateIssue('首屏', '以天气起手（模板化，且未进入事件）',
          FanqieGateAction.revise));
    }
    if (!_hasQuote(head)) {
      issues.add(const FanqieGateIssue('首屏', '无对白：纯描述开场完读率风险高',
          FanqieGateAction.rewrite));
    }
    if (!_namePat.hasMatch(head) && !_hasQuote(head)) {
      issues.add(const FanqieGateIssue('首屏', '看不到「谁在做什么」——缺具体主语+动作',
          FanqieGateAction.revise));
    }
    if (!_conflict.any(head.contains)) {
      issues.add(const FanqieGateIssue('首屏', '无冲突信号（无威胁/无要求/无损失）',
          FanqieGateAction.revise));
    }
    final int headLong =
        _sentences(head).where((String s) => s.length > 32).length;
    if (headLong >= 3) {
      issues.add(FanqieGateIssue('首屏', '有 $headLong 句超 32 字（移动端一行放不下）',
          FanqieGateAction.revise));
    }

    // ---- 完读率格式 ----
    final double dialogue = dialogueRatioOf(text);
    if (dialogue < minDialogue) {
      issues.add(FanqieGateIssue('对白',
          '对话占比仅 ${(dialogue * 100).toStringAsFixed(0)}%（建议 25~45%）',
          FanqieGateAction.rewrite));
    }
    final List<String> sents = _sentences(text);
    final double over30 = sents.isEmpty
        ? 0
        : sents.where((String s) => s.length > 30).length * 100.0 / sents.length;
    if (over30 > 18) {
      issues.add(FanqieGateIssue('句长',
          '${over30.toStringAsFixed(1)}% 的句子超 30 字，移动端阅读吃力',
          FanqieGateAction.revise));
    }
    final List<String> paras = _paragraphs(text);
    final double bigPara = paras.isEmpty
        ? 0
        : paras.where((String p) => _hanCount(p) > 160).length * 100.0 / paras.length;
    if (bigPara > 12) {
      issues.add(FanqieGateIssue('段落',
          '${bigPara.toStringAsFixed(1)}% 的段落超 160 字，需要拆分',
          FanqieGateAction.revise));
    }

    // ---- 水段 / 套句 / 自我重复 ----
    final ({double ratio, int counted}) filler = fillerStats(text, paras: paras);
    if (filler.ratio > maxFiller) {
      // 长段样本不足 8 个时，百分比会说谎（短章可能一共就 4 个长段）。
      final FanqieGateAction act =
          filler.counted >= 8 ? FanqieGateAction.rewrite : FanqieGateAction.note;
      issues.add(FanqieGateIssue(
          '水段',
          '水段率 ${filler.ratio.toStringAsFixed(1)}%（统计自 ${filler.counted} 个 ≥40 字段落），'
          '删掉不影响剧情的一律重写',
          act));
    }
    // 全文只建一次 TextIndex，供本章所有「词表 × 全文 contains」扫描预筛复用。
    // 旧实现在 genreDrift / _redline / _countAny / 套句·泄漏·元话语 各建一次，
    // 单章重复建 6 遍索引（每遍都是一次 O(文本长) 全码元扫描）。命中集合与
    // 顺序均不变——mayContain=false 蕴含 contains=false。
    final TextIndex textIndex = TextIndex(text);
    final List<String> hits = _hitsOf(_cliche, text, textIndex);
    if (hits.length * 1000.0 / math.max(words, 1) > 1.2) {
      issues.add(FanqieGateIssue('同质化',
          '套句 ${hits.take(4).join('、')}（每千字 ${(hits.length * 1000.0 / words).toStringAsFixed(2)} 处）',
          FanqieGateAction.revise));
    }
    final double selfRepeat = _selfRepeat(sents);
    if (selfRepeat > 1.0) {
      issues.add(FanqieGateIssue('重复',
          '整句重复率 ${selfRepeat.toStringAsFixed(2)}%（同句复用，读者会判定为凑字）',
          FanqieGateAction.rewrite));
    }
    if (prevContent.trim().isNotEmpty) {
      final double dup = _gramOverlap(text, prevContent);
      if (dup > 4) {
        issues.add(FanqieGateIssue('自我重复',
            '与上一章 8-gram 重合 ${dup.toStringAsFixed(1)}%',
            FanqieGateAction.revise));
      }
    }
    final List<String> leak = _hitsOf(_leak, text, textIndex);
    if (leak.isNotEmpty) {
      issues.add(FanqieGateIssue('泄漏',
          '提示词/骨架残留漏进正文：${leak.take(4).join('、')}',
          FanqieGateAction.rewrite));
    }
    // 元话语/指令残留：补写与定点修把「我在干什么」写进正文（实测被拼进成书）
    final List<String> meta = _hitsOf(_metaTalk, text, textIndex);
    if (meta.isNotEmpty) {
      issues.add(FanqieGateIssue('泄漏',
          '模型操作说明/元话语混进正文：${meta.take(3).join('、')}'
          '（补写或定点修的说明文字被当成正文采纳）',
          FanqieGateAction.rewrite));
    }
    // 题材漂移：玄幻书写成都市悬疑（终审官抓到的整章跑题，旧规则看不见）
    final ({String level, List<String> hits, int count}) drift =
        genreDrift(text, genre, index: textIndex);
    if (drift.level.isNotEmpty) {
      issues.add(FanqieGateIssue('一致性',
          '题材漂移：$genre 题材出现现代标志词 ${drift.hits.take(4).join('、')}'
          '（共 ${drift.count} 处）——补写/改写把正文带出了本书世界观',
          drift.level == '重写' ? FanqieGateAction.rewrite : FanqieGateAction.revise));
    }
    // 章内大段重复：复制粘贴级事故（实测第 3 章开头 800 字整块两遍）
    final ({int blocks, int words, String sample}) inrep =
        intraRepeat(text, paras: paras);
    if (inrep.blocks > 0) {
      issues.add(FanqieGateIssue('重复',
          '章内大段重复：${inrep.words} 字整块出现两次（如「${inrep.sample}…」），'
          '属复制粘贴级事故',
          FanqieGateAction.rewrite));
    }

    // ---- 一致性与主角性 ----
    for (final String msg in _nameDrift(text)) {
      issues.add(FanqieGateIssue('一致性', msg, FanqieGateAction.rewrite));
    }
    final List<String> worldMissing = worldTerms
        .where((String t) => !_termHit(text, t))
        .toList(growable: false);
    if (worldTerms.isNotEmpty) {
      final int hit = worldTerms.length - worldMissing.length;
      // 待补清单：评审只报「专名一个都没出现」时，模型不知道补哪几个（与 Python 同口径）
      final String pending = worldMissing.take(6).join('、');
      if (hit == 0) {
        issues.add(FanqieGateIssue('一致性',
            '大纲世界观专名 ${worldTerms.length} 个在正文一个都没出现'
            '（写手没接住设定，已另起故事；待补：$pending）',
            FanqieGateAction.rewrite));
      } else if (hit <= 1) {
        issues.add(FanqieGateIssue('一致性',
            '世界观专名仅命中 $hit/${worldTerms.length}，题材锁定不够紧（待补：$pending）',
            FanqieGateAction.revise));
      }
    }
    final int active = _countAny(text, _active, index: textIndex);
    final int passive = _countAny(text, _passive, index: textIndex);
    if ((passive >= 3 && active == 0) ||
        (passive >= 5 && active < passive * 0.4)) {
      issues.add(FanqieGateIssue('主角性',
          '主角主动句 $active 处 / 被动 $passive 处（代理指标：'
          '本章建议安排一次有代价的主动选择）',
          FanqieGateAction.revise));
    }

    // ---- 红线 ----
    final List<FanqieRedlineHit> redlines = _redline(text, index: textIndex);

    double score = 100.0;
    for (final FanqieGateIssue e in issues) {
      score -= e.action.penalty;
    }
    score -= redlines.where((FanqieRedlineHit h) => h.veto).length * 45.0;
    score -= redlines.where((FanqieRedlineHit h) => !h.veto).length * 5.0;
    score = score.clamp(0.0, 100.0);

    return FanqieGateReport(
      score: double.parse(score.toStringAsFixed(1)),
      issues: issues,
      redlines: redlines,
      dialogueRatio: double.parse(dialogue.toStringAsFixed(3)),
      fillerRatio: double.parse(filler.ratio.toStringAsFixed(1)),
      fillerCounted: filler.counted,
      worldHit: worldTerms.length - worldMissing.length,
      worldTotal: worldTerms.length,
      worldMissing: worldMissing.take(8).toList(growable: false),
      words: words,
    );
  }

  /// 从小说的世界观设定里抽取专名候选（供 [worldTerms] 使用）。
  ///
  /// 口径与 Python 侧 extract_world_terms 一致：
  /// 1) 先收引号/书名号里的片段（规划官写的专名多带引号）；
  /// 2) 再按分隔符切片，只留 3 字以上、含汉字的片段。
  /// 不收 2 字普通词（「秩序」「资本」）是因为它们会跟任何文本随手撞上，
  /// 一致性检查形同虚设；不收纯 ASCII 是因为 JSON 键名（galaxy/faction）会混进来。
  static List<String> worldTermsFrom(Iterable<String> settingTexts) {
    const Set<String> generic = <String>{
      '主舞台', '城市', '势力', '等级', '体系', '境界', '科技', '能源', '联赛', '舞台',
      '俱乐部', '国家队', '朝代名', '大陆名', '星域名', '游戏世界', '职业', '出身',
      '性格特征', '竞技场', '背景', '主要', '门派', '世家', '组织', '机构',
      '主要势力', '自拟', '三大势力', '自拟专名', '能源为',
    };
    const String sepChars =
        '，。、；：！？（）()《》〈〉“”‘’「」『』【】[]{}\\/"\':;,·—-与和及／｜ \t\r\n';
    final Set<String> out = <String>{};

    void push(String raw) {
      final String t = raw.trim().replaceAll(_termTail, '');
      if (!_han.hasMatch(t)) return;
      if (t.length < 2 || t.length > 12) return;
      if (generic.contains(t)) return;
      if (!_termOk.hasMatch(t)) return;
      if (out.length < 14) out.add(t);
    }

    for (final String s in settingTexts) {
      for (final RegExpMatch m in _quotedTerm.allMatches(s)) {
        push(m.group(1) ?? '');
      }
      final List<String> frag = <String>[];
      final StringBuffer cur = StringBuffer();
      for (final String ch in s.split('')) {
        if (sepChars.contains(ch)) {
          frag.add(cur.toString());
          cur.clear();
        } else {
          cur.write(ch);
        }
      }
      frag.add(cur.toString());
      for (final String f in frag) {
        if (f.trim().length >= 3) push(f);
      }
    }
    return out.toList();
  }

  /// 对白占比（引号内字数 / 总字数）。
  static double dialogueRatioOf(String text) {
    // 逐段累计汉字数，省掉「先拼成一整串、再整串数一遍」的 StringBuffer 与
    // 全串二次扫描；单码点计数逐段相加与拼接后再数完全等价（计数单位不跨片段）。
    int quoted = 0;
    for (final RegExpMatch m in _dialogueQuote.allMatches(text)) {
      final String? g = m.group(1);
      if (g != null) quoted += _hanCount(g);
    }
    final int total = _hanCount(text);
    if (total == 0) return 0;
    return quoted / total;
  }

  /// 水段率：长度 ≥ 40 字、既无对白又无推进词的段落占比。
  ///
  /// 短段不参统计：「他顿了顿。」这种喘气段是准则明写的节奏手段，
  /// 按段落长短砍它会把好文风压成流水账。返回的 counted 用于判样本量。
  ///
  /// [paras] 可由调用方传入已切好的段落（[check] 里同一章要切三次，见
  /// [intraRepeat] 注释）；不传则现场切分，口径完全一致。
  static ({double ratio, int counted}) fillerStats(String text,
      {List<String>? paras}) {
    final List<String> list = paras ?? _paragraphs(text);
    int bad = 0;
    int counted = 0;
    for (final String p in list) {
      if (_hanCount(p) < 40) continue;
      counted++;
      if (p.contains('“') || p.contains('"') || p.contains('「')) continue;
      if (_drive.any(p.contains)) continue;
      bad++;
    }
    if (counted == 0) return (ratio: 0.0, counted: 0);
    return (ratio: bad * 100.0 / counted, counted: counted);
  }

  /// 兼容旧签名：只取水段率。
  static double fillerRatioOf(String text) => fillerStats(text).ratio;

  /// 章内大段重复：同章 ≥120 字的整块文字出现两次（复制粘贴级事故）。
  ///
  /// 与 Python 侧 `fanqie_review.intra_repeat` 同口径：
  /// ① 扁平文本滑动指纹（完全相同的长块）；② 段落级近似比对（标点/个别用词微调）。
  /// `blocks` > 0 即判「重写」级事故（实测：第 3 章开头 800 字整块出现两遍）。
  static ({int blocks, int words, String sample}) intraRepeat(
    String text, {
    List<String>? paras,
  }) {
    final String flat = text.replaceAll(_ws, '');
    final List<List<int>> spans =
        flat.length >= intraRepeatMinBlock * 2 ? _dupSpans(flat) : <List<int>>[];
    if (spans.isNotEmpty) {
      int words = 0;
      for (final List<int> s in spans) {
        words += s[1] - s[0];
      }
      final int head = spans.first[0];
      final int end = head + 24 > flat.length ? flat.length : head + 24;
      return (blocks: spans.length, words: words, sample: flat.substring(head, end));
    }
    // 近似重复通道：段落级二元组相似度 ≥0.85（标点/个别用词微调也算）
    // [paras] 由调用方传入时省掉重复切分（[check] 里同一章还要用它算段长与水段率）。
    final List<String> longParas = (paras ?? _paragraphs(text))
        .where((String p) => _hanCount(p) >= intraRepeatMinBlock)
        .toList();
    // 二元组集合按段落只算一次：旧实现在下面的 O(n²) 配对里，
    // 每一对都把这两段重新扁平化 + 重切一遍二元组（O(n²·L) 次冗余工作）。
    final List<Set<int>> parasGrams =
        longParas.map(_bigrams).toList(growable: false);
    for (int i = 1; i < longParas.length; i++) {
      final Set<int> gi = parasGrams[i];
      final int li = gi.length;
      for (int j = 0; j < i; j++) {
        final Set<int> gj = parasGrams[j];
        final int lj = gj.length;
        // 尺寸预筛：Jaccard ≤ min(|A|,|B|)/max(|A|,|B|)，尺寸差超 15% 的段落对
        // 数学上到不了 0.85，直接跳过集合比对（长章段落多时省掉大部分配对）。
        if (lj < li ? lj * 100 < li * 85 : li * 100 < lj * 85) continue;
        if (_jaccardOf(gj, gi) >= 0.85) {
          final String p = longParas[i];
          return (
            blocks: 1,
            words: _hanCount(p),
            sample: p.length > 24 ? p.substring(0, 24) : p,
          );
        }
      }
    }
    return (blocks: 0, words: 0, sample: '');
  }

  /// 滑动指纹找长重复块：返回 [起点, 终点] 列表（第二次出现的区间）。
  ///
  /// 窗口指纹用滚动哈希（旧实现是每个窗口 `substring` 出一个 12 字串当 Map 键：
  /// 单章约 660 个窗口，每个窗口要分配一个 12 字串再做 12 次码元哈希）。哈希桶里
  /// 按出现顺序存下标，取桶内**首个逐码元比对相等的窗口**，与「以子串为键、只记
  /// 首次出现」完全等价：哈希冲突的窗口不会被误判为命中（后面还要连续比对够
  /// [intraRepeatMinBlock] 个码元才算重复块，而这必然蕴含 12 元窗口本身相等）。
  static List<List<int>> _dupSpans(String t) {
    final int n = t.length;
    final List<List<int>> spans = <List<int>>[];
    if (n < _intraGram) return spans;
    final Map<int, List<int>> seen = <int, List<int>>{};
    int h = 0;
    for (int k = 0; k < _intraGram; k++) {
      h = (h * _hashBase + t.codeUnitAt(k)) & _hashMask;
    }
    int pow = 1;
    for (int k = 1; k < _intraGram; k++) {
      pow = (pow * _hashBase) & _hashMask;
    }
    for (int i = 0; i + _intraGram <= n; i += 3) {
      if (i > 0) {
        // 窗口右移 3（步长与旧实现一致），滚动 3 次：h ← (h - 出窗*base^11)*base + 入窗
        for (int s = 0; s < 3; s++) {
          final int out = t.codeUnitAt(i - 3 + s);
          h = ((h - out * pow) * _hashBase +
                  t.codeUnitAt(i + _intraGram - 3 + s)) &
              _hashMask;
        }
      }
      int first = -1;
      final List<int>? bucket = seen[h];
      if (bucket != null) {
        for (final int at in bucket) {
          bool same = true;
          for (int k = 0; k < _intraGram; k++) {
            if (t.codeUnitAt(at + k) != t.codeUnitAt(i + k)) {
              same = false;
              break;
            }
          }
          if (same) {
            first = at;
            break;
          }
        }
      }
      if (first < 0) {
        (seen[h] ??= <int>[]).add(i);
        continue;
      }
      int k = 0;
      while (first + k < n &&
          i + k < n &&
          t.codeUnitAt(first + k) == t.codeUnitAt(i + k)) {
        k++;
      }
      if (k >= intraRepeatMinBlock) spans.add(<int>[i, i + k]);
    }
    spans.sort((List<int> a, List<int> b) => a[0].compareTo(b[0]));
    final List<List<int>> merged = <List<int>>[];
    for (final List<int> s in spans) {
      if (merged.isNotEmpty && s[0] <= merged.last[1]) {
        if (s[1] > merged.last[1]) merged.last[1] = s[1];
      } else {
        merged.add(<int>[s[0], s[1]]);
      }
    }
    return merged;
  }

  /// 题材漂移：非现代题材里出现现代生活标志词。
  ///
  /// `level`：'' 不报 / '修改' 个别穿帮 / '重写' 整章跑题（≥3 个不同标志词）。
  /// 都市/校园/悬疑等现代题材不做判定（它们本来就该有这些词）。
  static ({String level, List<String> hits, int count}) genreDrift(
    String text,
    String genre, {
    TextIndex? index,
  }) {
    final String g = genre.trim();
    final bool lock =
        g.isNotEmpty && _ancientGenres.any((String a) => g.contains(a));
    if (!lock) return (level: '', hits: <String>[], count: 0);
    // 现代词表 36 个，旧实现是逐个 contains 扫全文；先过 TextIndex 把必然
    // 不命中的词挡掉（命中集合与顺序不变，只省扫描）。
    // [index] 由 [check] 传入时复用本章已建的索引，避免重复全码元扫描。
    final TextIndex idx = index ?? TextIndex(text);
    final List<String> hits = _hitsOf(_modernMarkers, text, idx);
    int count = 0;
    for (final String w in hits) {
      count += _countOccurrences(text, w);
    }
    if (hits.length >= 3) return (level: '重写', hits: hits, count: count);
    if (hits.isNotEmpty) return (level: '修改', hits: hits, count: count);
    return (level: '', hits: <String>[], count: 0);
  }

  /// 补丁卫生（与 Python 侧 `patch_gate` 同口径）：补写/扩写/定点修的产出
  /// 在拼回正文前过这道闸。返回 null = 通过；否则返回拒绝原因。
  ///
  /// 拦三类事故：① 指令/元话语残留；② 题材漂移；③ 与正文尾部重复。
  static String? patchReject(
    String patch, {
    String baseText = '',
    String genre = '',
    int maxWords = 260,
  }) {
    final String p = patch.trim();
    if (p.isEmpty) return '空产出';
    if (_hanCount(p) > maxWords) return '超长（${_hanCount(p)} 字 > $maxWords）';
    final List<String> leak = <String>[
      ..._leak.where(p.contains),
      ..._metaTalk.where(p.contains),
    ];
    if (leak.isNotEmpty) return '指令/元话语残留「${leak.first}」';
    final ({String level, List<String> hits, int count}) gd = genreDrift(p, genre);
    if (gd.level.isNotEmpty) return '题材漂移：${gd.hits.take(3).join('、')}';
    if (baseText.trim().isNotEmpty) {
      final String flatP = p.replaceAll(_ws, '');
      final String base = baseText.replaceAll(_ws, '');
      final String tail = base.length > 400 ? base.substring(base.length - 400) : base;
      final int top = flatP.length < 80 ? flatP.length : 80;
      for (int k = top; k > 19; k -= 5) {
        if (k <= flatP.length && tail.contains(flatP.substring(0, k))) {
          return '与正文尾部重复 $k 字';
        }
      }
    }
    return null;
  }

  /// 段落字符二元组集合（去空白扁平化后取相邻两码元）。
  ///
  /// 用「高 16 位前码元 | 低 16 位后码元」的整数编码，替代旧的 2 字子串：
  /// 相等判定不变（两字串相等 ⟺ 两码元对相等），但省掉每段 ~88 次子串分配。
  /// 提出来是为了让 [intraRepeat] 的两两比对能把每个段落只算一次。
  static Set<int> _bigrams(String s) {
    final String t = s.replaceAll(_ws, '');
    final Set<int> set = <int>{};
    for (int i = 0; i + 1 < t.length; i++) {
      set.add((t.codeUnitAt(i) << 16) | t.codeUnitAt(i + 1));
    }
    return set;
  }

  /// 两个已算好的二元组集合的 Jaccard 相似度。
  ///
  /// 并集用容斥 |A∪B| = |A|+|B|-|A∩B| 算，省掉 `A.union(B)` 每次新建临时集合；
  /// 交集遍历较小集合，计数与旧 `A.intersection(B).length` 完全一致。
  static double _jaccardOf(Set<int> ga, Set<int> gb) {
    if (ga.isEmpty || gb.isEmpty) return 0.0;
    final Set<int> small = ga.length <= gb.length ? ga : gb;
    final Set<int> large = identical(small, ga) ? gb : ga;
    int inter = 0;
    for (final int g in small) {
      if (large.contains(g)) inter++;
    }
    return inter / (ga.length + gb.length - inter);
  }

  /// 子串出现次数。
  static int _countOccurrences(String text, String needle) {
    if (needle.isEmpty) return 0;
    int count = 0;
    int i = 0;
    while (true) {
      final int found = text.indexOf(needle, i);
      if (found < 0) break;
      count++;
      i = found + needle.length;
    }
    return count;
  }

  // ---------------- 内部工具 ----------------

  /// 汉字数（CJK 基本区，按 UTF-16 码元计）。
  ///
  /// 逐码点扫描替代 `_han.allMatches(s).length`：正则匹配会为每个汉字建一个
  /// RegExpMatch，而全书体检下单章要调它上百次（字数、段落长度、水段统计、
  /// 章内重复都走这里），纯属白烧的分配。口径不变——[_han] 未开 unicode，
  /// 按码元匹配，区间外码元（含代理对）同样不计。
  static int _hanCount(String s) {
    int n = 0;
    for (int i = 0; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      if (c >= 0x4E00 && c <= 0x9FFF) n++;
    }
    return n;
  }

  static List<String> _sentences(String t) => t
      .split(_sentSplit)
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();

  static List<String> _paragraphs(String t) => t
      .split('\n')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();

  static bool _hasQuote(String s) =>
      s.contains('“') || s.contains('"') || s.contains('「');

  /// 专名命中：允许局部命中（3 字滑窗或尾 2 字）。
  ///
  /// 专名池是大纲 world 里的完整短语（「星洲奥体中心」），正文可能写「星洲青训基地」；
  /// 「体能师老韩」正文写「老韩」。整串包含会把接住设定的正文误判为跑题。
  static bool _termHit(String text, String term) {
    if (term.isEmpty || text.isEmpty) return false;
    if (text.contains(term)) return true;
    for (int i = 0; i + 3 <= term.length; i++) {
      if (text.contains(term.substring(i, i + 3))) return true;
    }
    return term.length >= 2 && text.contains(term.substring(term.length - 2));
  }

  static int _countAny(String text, List<String> words, {TextIndex? index}) {
    if (words.isEmpty || text.isEmpty) return 0;
    // 主动/被动句词表各数十词，逐词 indexOf 扫全文；先挡掉必然不命中的词。
    // [index] 由 [check] 传入时复用本章已建的索引。
    final TextIndex idx = index ?? TextIndex(text);
    int n = 0;
    for (final String w in words) {
      if (!idx.mayContain(w)) continue;
      int i = text.indexOf(w);
      while (i != -1) {
        n++;
        i = text.indexOf(w, i + w.length);
      }
    }
    return n;
  }

  /// 整句重复率。
  static double _selfRepeat(List<String> sentences) {
    final List<String> pool =
        sentences.where((String s) => s.length >= 10).toList();
    if (pool.isEmpty) return 0;
    final Set<String> seen = <String>{};
    int dup = 0;
    for (final String s in pool) {
      if (!seen.add(s)) dup++;
    }
    return dup * 100.0 / pool.length;
  }

  /// 与上一章的 8-gram 重合率。
  static double _gramOverlap(String a, String b) {
    Set<String> grams(String s) {
      final String t = s.replaceAll(_ws, '');
      final Set<String> out = <String>{};
      for (int i = 0; i + 8 <= t.length; i += 3) {
        out.add(t.substring(i, i + 8));
      }
      return out;
    }

    final Set<String> ga = grams(a);
    if (ga.isEmpty) return 0;
    final Set<String> gb = grams(b);
    return ga.intersection(gb).length * 100.0 / ga.length;
  }

  /// 常见姓氏首字（由下方 [surnames] 字面量一次性建表）。
  ///
  /// 旧实现是每次匹配都 `surnames.contains(nm[0])`——`contains` 在长串上线性扫描，
  /// 而「百位姓氏」字面量有 ~200 字，单章匹配出几十个人名时就是几十次 ×200 字的
  /// 无谓比对（`_nameDrift` 曾占全书体检单章耗时约 35%）。改成 Set 查表后
  /// 每次匹配 O(1)，命中集合与顺序完全不变。
  static final Set<String> _surnameSet = <String>{
    for (final String s in _surnames.split(''))
      if (s.isNotEmpty) s,
  };

  /// 常见姓氏字面量（仅用于建 [_surnameSet]，不再参与匹配）。
  static const String _surnames =
      '王李张刘陈杨黄赵周吴徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘于蒋蔡'
      '余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯'
      '龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤柴桑关岳鲍盛赖樊温柯岑路桂傅齐应宗简';

  /// 统计 [needle] 在 [text] 中的**非重叠**出现次数。
  ///
  /// 旧实现是 `' $text '.split(protagonist).length - 1`：为了防「命中开头/结尾」
  /// 而在整章正文两侧各补一个空格，于是**每章为了一次计数就复制一遍全文**并
  /// `split` 成列表——全书体检按章调用，这是单章最贵的一处分配。
  /// `indexOf` 循环不复制任何内容，计数口径与 split 完全一致（非重叠、
  /// 空串已由调用方拦掉）。
  static int _countOccur(String text, String needle) {
    if (needle.isEmpty) return 0;
    int n = 0;
    int i = 0;
    while (true) {
      final int found = text.indexOf(needle, i);
      if (found < 0) break;
      n++;
      i = found + needle.length;
    }
    return n;
  }

  List<String> _nameDrift(String text) {
    final Map<String, int> cnt = <String, int>{};
    for (final RegExpMatch m in _namePat.allMatches(text)) {
      final String nm = m.group(1)!;
      final bool isName = _surnameSet.contains(nm.isEmpty ? '' : nm[0]) ||
          nm == protagonist;
      if (!isName) continue;
      cnt[nm] = (cnt[nm] ?? 0) + 1;
    }
    final List<String> hot = cnt.entries
        .where((MapEntry<String, int> e) =>
            e.value >= 3 && e.key != protagonist)
        .map((MapEntry<String, int> e) => '${e.key}×${e.value}')
        .toList();
    final List<String> out = <String>[];
    // 「对手 + 盟友」两个常驻配角同章活跃是正常戏剧结构；
    // 真正的视角漂移信号是 3 个以上高频配角各说各话。
    if (hot.length > 2) {
      out.add('同章出现多个高频人名：${hot.take(4).join('、')}（视角/主角漂移）');
    }
    if (protagonist.isNotEmpty) {
      final int c = _countOccur(text, protagonist);
      if (c < 3) out.add('大纲主角「$protagonist」本章仅出现 $c 次（写手没接住主角）');
    }
    return out;
  }

  List<FanqieRedlineHit> _redline(String text, {TextIndex? index}) {
    final List<FanqieRedlineHit> hits = <FanqieRedlineHit>[];
    // 1) 复用 app 内置词库（暴力血腥/色情/辱骂/违法/广告）
    final SensitiveCheckResult r = SensitiveWordsService().check(text);
    for (final SensitiveHit h in r.hits) {
      final bool narrativeOk = _narrativeOkCategories.contains(h.category);
      final String wide = _window(text, h.start, h.word.length);
      final bool veto =
          !narrativeOk || _instructionMark.any(wide.contains);
      hits.add(FanqieRedlineHit(h.category, h.word, h.context, veto));
    }
    // 2) 番茄专有类别
    // [index] 由 [check] 传入时复用本章已建的索引，避免重复全码元扫描。
    final TextIndex idx = index ?? TextIndex(text);
    _extraRedline.forEach((String cat, List<String> words) {
      for (final String w in words) {
        if (!idx.mayContain(w)) continue;
        int i = text.indexOf(w);
        while (i != -1) {
          final String wide = _window(text, i, w.length);
          final bool narrativeOk = _narrativeOkCategories.contains(cat);
          hits.add(FanqieRedlineHit(
            cat,
            w,
            _context(text, i, w.length),
            !narrativeOk || _instructionMark.any(wide.contains),
          ));
          i = text.indexOf(w, i + w.length);
        }
      }
    });
    return hits;
  }

  static String _window(String text, int start, int len) {
    final int a = math.max(0, start - 40);
    final int b = math.min(text.length, start + len + 40);
    return text.substring(a, b);
  }

  static String _context(String text, int start, int len) {
    final int a = math.max(0, start - 12);
    final int b = math.min(text.length, start + len + 12);
    return text.substring(a, b).replaceAll('\n', ' ');
  }

  /// 章节标题行（供调用方拆章复用）。
  static RegExp get chapterPattern => _chapterRe;
}
