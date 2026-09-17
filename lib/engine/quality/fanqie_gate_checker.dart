import 'dart:math' as math;

import 'package:novel_writer/services/sensitive_words.dart';

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
    b
      ..writeln()
      ..writeln('【改写要求】首屏 300 字必须有主角在场、正在发生的冲突、至少一句对白；'
          '主角本章至少做一次有代价的主动选择；对话占比提到 25%~45%；'
          '删掉所有「删了不影响剧情」的段落；句子尽量 25 字内，段落不超过 3 行。')
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
    this.minDialogue = 0.18,
    this.maxFiller = 12.0,
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

  /// 冲突信号：首屏要带包袋。
  static const List<String> _conflict = <String>[
    '吼', '骂', '砸', '押', '欠', '逐', '抢', '抓', '审', '封门', '退婚', '断', '碎',
    '伤', '血', '死', '遗物', '最后', '偿命', '让位', '除名', '扫地出门', '罚', '跪',
    '赔', '欠条', '警告', '期限', '当场', '拉走', '抬走',
  ];

  /// 网文高频套句（同质化风险）。
  static const List<String> _cliche = <String>[
    '空气仿佛凝固', '嘴角勾起一抹', '眼底闪过一丝', '心中一凛', '心头一震',
    '不由得倒吸一口凉气', '瞳孔骤缩', '深吸一口气', '缓缓开口', '淡淡开口',
    '全场寂静', '鸦雀无声', '面面相觑', '就在这时', '谁也没想到',
    '从这一刻起', '命运的车轮', '像有什么东西醒', '仿佛在诉说',
  ];

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
  static const List<String> _leak = <String>[
    '本场景任务', '必须完成的节拍', '爽点：', '钩子：', '一次奇缘让主角获得机缘',
    '遭遇强敌或瓶颈', '心境蜕变', '就在众人以为风平浪静时', 'targetWords',
    '【场景', '【跨章状态',
  ];

  /// 元话语/指令残留（模型把「补写操作说明」当正文吐出来 = 直接判废）。
  ///
  /// 实测事故：钩子补写返回「我拿到的指令是补写钩子，不是扩写…」被原样拼进第 1 章末尾，
  /// 旧词表只覆盖骨架词，抓不到这类元话语。选词原则：只收叙事里不可能出现的短语。
  static const List<String> _metaTalk = <String>[
    '我拿到的指令', '拿到的指令是', '根据你的指令', '按你的指令', '按照你的要求', '按你的要求',
    '作为AI', '作为人工智能', '作为一个AI', '作为语言模型', '我无法完成', '我无法直接',
    '抱歉，我', '很抱歉，我', '你贴的那段', '你提供的文本', '以下是我的改写', '以上是补写',
    '字数要求', '扩写到', '如需继续', '如果你需要', '希望这符合', '无法满足这个要求',
  ];

  /// 题材漂移：给非现代题材用的现代生活标志词。
  ///
  /// 实测事故：玄幻书第 3 章整章变成现代都市悬疑（路灯/手机/牛皮纸袋/面包车），
  /// 逐章本地评审仍给 84 分，直到终审官通读才发现。玄幻里也可能合法的词（钥匙/医院/巷口）
  /// 一律不收，避免误伤。
  static const List<String> _modernMarkers = <String>[
    '手机', '电脑', '网络', '微信', '支付宝', '电梯', '汽车', '面包车', '出租车', '公交车',
    '马路', '红绿灯', '路灯', '屏幕', '短信', '沙发', '咖啡', '监控', '摄像头', '银行卡',
    '外卖', '快递', '物业', '办公室', '上班', '加班', '房租', '塑料袋', '牛皮纸袋', '客服',
    '二维码', '充电', '导航', '直播', '朋友圈', '地铁', '高铁', '身份证',
  ];

  /// 需要锁题材的非现代题材（都市/校园/悬疑等题材不做现代词漂移判定）。
  static const List<String> _ancientGenres = <String>[
    '玄幻', '仙侠', '武侠', '修真', '历史', '古代', '宫斗', '权谋', '奇幻', '东方', '洪荒',
    '仙', '古言',
  ];

  /// 章内重复块最短字数（与 Python 侧 INTRA_REPEAT_MIN_BLOCK 同口径）。
  static const int intraRepeatMinBlock = 120;

  /// 章内重复指纹长度（与 Python 侧 INTRA_REPEAT_GRAM 同口径）。
  static const int _intraGram = 12;

  /// 番茄专有红线类别（其余类别走 [SensitiveWordsService] 内置词库）。
  static const Map<String, List<String>> _extraRedline = <String, List<String>>{
    '时政敏感': <String>[
      '国家主席', '国务院', '中南海', '政治局', '省委书记', '中央委员会', '全国人大',
      '政变', '分裂势力', '台独', '港独', '暴乱', '骚乱',
    ],
    '宗教民族': <String>[
      '邪教徒', '圣战', '异教徒该死', '侮辱', '藏传佛教活佛转世', '请神', '问米',
      '通灵', '招魂', '借尸还魂', '苗疆蛊', '蛊毒', '降头', '养小鬼',
    ],
    '未成年风险': <String>[
      '师生恋', '初中生怀孕', '高中生开房', '萝莉', '正太', '诱奸', '童养媳圆房',
      '校园霸凌视频', '拍视频传播', '扒光衣服', '拍裸照',
    ],
    '现实品牌与真人': <String>[
      '微信', '支付宝', '淘宝', '京东', '拼多多', '抖音', '快手', '腾讯', '阿里巴巴',
      '清华大学', '北京大学', '协和医院', '钟南山', '马云', '马化腾', '任正非', '姚明',
    ],
    '教唆细节': <String>[
      '制作炸药的方法', '土制炸弹', '开锁技巧', '伪造身份证', '办假证', '洗钱方法',
      '下毒剂量', '自制枪支', '弩的图纸',
    ],
  };

  /// 「教唆/推广」语境标记：只有伴随这些词，情节类红线才升级为否决。
  static const List<String> _instructionMark = <String>[
    '方法', '教程', '步骤', '配方', '图解', '教你', '怎么', '如何', '加入', '联系',
    '转发', '关注', '下载', '买卖', '出售', '招募', '价格', '免抵押', '低息', '放款',
    '链接',
  ];

  /// 这些类别在小说里作为情节元素出现是正常的，只有教唆语境才否决。
  static const Set<String> _narrativeOkCategories = <String>{
    '违法违规', '宗教民族', '现实品牌与真人', '广告引流',
  };

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
    final ({double ratio, int counted}) filler = fillerStats(text);
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
    final List<String> hits = _cliche.where(text.contains).toList();
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
    final List<String> leak = _leak.where(text.contains).toList();
    if (leak.isNotEmpty) {
      issues.add(FanqieGateIssue('泄漏',
          '提示词/骨架残留漏进正文：${leak.take(4).join('、')}',
          FanqieGateAction.rewrite));
    }
    // 元话语/指令残留：补写与定点修把「我在干什么」写进正文（实测被拼进成书）
    final List<String> meta = _metaTalk.where(text.contains).toList();
    if (meta.isNotEmpty) {
      issues.add(FanqieGateIssue('泄漏',
          '模型操作说明/元话语混进正文：${meta.take(3).join('、')}'
          '（补写或定点修的说明文字被当成正文采纳）',
          FanqieGateAction.rewrite));
    }
    // 题材漂移：玄幻书写成都市悬疑（终审官抓到的整章跑题，旧规则看不见）
    final ({String level, List<String> hits, int count}) drift = genreDrift(text, genre);
    if (drift.level.isNotEmpty) {
      issues.add(FanqieGateIssue('一致性',
          '题材漂移：$genre 题材出现现代标志词 ${drift.hits.take(4).join('、')}'
          '（共 ${drift.count} 处）——补写/改写把正文带出了本书世界观',
          drift.level == '重写' ? FanqieGateAction.rewrite : FanqieGateAction.revise));
    }
    // 章内大段重复：复制粘贴级事故（实测第 3 章开头 800 字整块两遍）
    final ({int blocks, int words, String sample}) inrep = intraRepeat(text);
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
    if (worldTerms.isNotEmpty) {
      final int hit = worldTerms.where((String t) => _termHit(text, t)).length;
      if (hit == 0) {
        issues.add(FanqieGateIssue('一致性',
            '大纲世界观专名 ${worldTerms.length} 个在正文一个都没出现（写手没接住设定，已另起故事）',
            FanqieGateAction.rewrite));
      } else if (hit <= 1) {
        issues.add(FanqieGateIssue('一致性',
            '世界观专名仅命中 $hit/${worldTerms.length}，题材锁定不够紧',
            FanqieGateAction.revise));
      }
    }
    final int active = _countAny(text, _active);
    final int passive = _countAny(text, _passive);
    if ((passive >= 3 && active == 0) ||
        (passive >= 5 && active < passive * 0.4)) {
      issues.add(FanqieGateIssue('主角性',
          '主角主动句 $active 处 / 被动 $passive 处（代理指标：'
          '本章建议安排一次有代价的主动选择）',
          FanqieGateAction.revise));
    }

    // ---- 红线 ----
    final List<FanqieRedlineHit> redlines = _redline(text);

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
      worldHit: worldTerms.where((String t) => _termHit(text, t)).length,
      worldTotal: worldTerms.length,
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
        '，。、；：！？（）()《》〈〉“”‘’「」『』【】[]{}\\/"\':;,·—-与和及 \t\r\n';
    final RegExp ok = RegExp(r'^[\u4e00-\u9fffA-Za-z0-9·]{2,12}$');
    final RegExp quoted = RegExp('[「『《“‘]([^\\n」』”’]{2,10})[」』”’]');
    final Set<String> out = <String>{};

    void push(String raw) {
      final String t = raw.trim().replaceAll(RegExp(r'[的地了]+$'), '');
      if (!RegExp(r'[\u4e00-\u9fff]').hasMatch(t)) return;
      if (t.length < 2 || t.length > 12) return;
      if (generic.contains(t)) return;
      if (!ok.hasMatch(t)) return;
      if (out.length < 14) out.add(t);
    }

    for (final String s in settingTexts) {
      for (final RegExpMatch m in quoted.allMatches(s)) {
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
    final RegExp q = RegExp(r'[“"「『]([^”"」』]{1,200})[”"」』]');
    final StringBuffer buf = StringBuffer();
    for (final RegExpMatch m in q.allMatches(text)) {
      buf.write(m.group(1));
    }
    final int total = RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
    if (total == 0) return 0;
    return _hanCount(buf.toString()) / total;
  }

  /// 水段率：长度 ≥ 40 字、既无对白又无推进词的段落占比。
  ///
  /// 短段不参统计：「他顿了顿。」这种喘气段是准则明写的节奏手段，
  /// 按段落长短砍它会把好文风压成流水账。返回的 counted 用于判样本量。
  static ({double ratio, int counted}) fillerStats(String text) {
    final List<String> paras = _paragraphs(text);
    int bad = 0;
    int counted = 0;
    for (final String p in paras) {
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
  static ({int blocks, int words, String sample}) intraRepeat(String text) {
    final String flat = text.replaceAll(RegExp(r'\s+'), '');
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
    final List<String> longParas = _paragraphs(text)
        .where((String p) => _hanCount(p) >= intraRepeatMinBlock)
        .toList();
    for (int i = 1; i < longParas.length; i++) {
      for (int j = 0; j < i; j++) {
        if (_bigramJaccard(longParas[j], longParas[i]) >= 0.85) {
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
  static List<List<int>> _dupSpans(String t) {
    final Map<String, int> seen = <String, int>{};
    final List<List<int>> spans = <List<int>>[];
    for (int i = 0; i + _intraGram <= t.length; i += 3) {
      final String g = t.substring(i, i + _intraGram);
      final int? first = seen[g];
      if (first == null) {
        seen[g] = i;
        continue;
      }
      int k = 0;
      while (first + k < t.length &&
          i + k < t.length &&
          t[first + k] == t[i + k]) {
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
      String text, String genre) {
    final String g = genre.trim();
    final bool lock =
        g.isNotEmpty && _ancientGenres.any((String a) => g.contains(a));
    if (!lock) return (level: '', hits: <String>[], count: 0);
    final List<String> hits = _modernMarkers.where(text.contains).toList();
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
      final String flatP = p.replaceAll(RegExp(r'\s+'), '');
      final String base = baseText.replaceAll(RegExp(r'\s+'), '');
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

  /// 两段文字的汉字二元组 Jaccard 相似度（段落级近似重复判定用）。
  static double _bigramJaccard(String a, String b) {
    Set<String> grams(String s) {
      final String t = s.replaceAll(RegExp(r'\s+'), '');
      final Set<String> set = <String>{};
      for (int i = 0; i + 1 < t.length; i++) {
        set.add(t.substring(i, i + 2));
      }
      return set;
    }

    final Set<String> ga = grams(a);
    final Set<String> gb = grams(b);
    if (ga.isEmpty || gb.isEmpty) return 0.0;
    return ga.intersection(gb).length / ga.union(gb).length;
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

  static int _hanCount(String s) => _han.allMatches(s).length;

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

  static int _countAny(String text, List<String> words) {
    int n = 0;
    for (final String w in words) {
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
      final String t = s.replaceAll(RegExp(r'\s+'), '');
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

  List<String> _nameDrift(String text) {
    const String surnames =
        '王李张刘陈杨黄赵周吴徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘于蒋蔡'
        '余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯'
        '龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤柴桑关岳鲍盛赖樊温柯岑路桂傅齐应宗简';
    final Map<String, int> cnt = <String, int>{};
    for (final RegExpMatch m in _namePat.allMatches(text)) {
      final String nm = m.group(1)!;
      final bool isName = surnames.contains(nm.isEmpty ? '' : nm[0]) ||
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
      final int c = ' $text '.split(protagonist).length - 1;
      if (c < 3) out.add('大纲主角「$protagonist」本章仅出现 $c 次（写手没接住主角）');
    }
    return out;
  }

  List<FanqieRedlineHit> _redline(String text) {
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
    _extraRedline.forEach((String cat, List<String> words) {
      for (final String w in words) {
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
