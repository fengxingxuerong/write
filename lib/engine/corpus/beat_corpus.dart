import 'package:novel_writer/engine/random/seeded_random.dart';

/// 叙事节拍语料库。
///
/// 与 [SentenceTemplates] 的「氛围句」不同，本库按**叙事功能**组织：
/// 开篇锚定、情节推进、张力升级、高潮爆发、转折揭示、收束沉淀、
/// 章末钩子、五感描写、对话攻防、内心独白。每个功能组内置 ≥12 条
/// 可填充句式，由模板引擎按情节阶段加权取样，使正文具备明确的
/// 「场景—冲突—高潮—钩子」节奏，而非随机拼接的氛围句。
///
/// 占位符契约（与 SentenceTemplates 一致，另新增两个）：
/// - `{name}`    主角姓名
/// - `{rival}`   对手 / 敌对者（从角色池取样）
/// - `{ally}`    盟友 / 亲近者（从角色池取样）
/// - `{addr}`    被称呼者（对话内容里喊的人；引擎解析为说话人之外的在场者，
///               杜绝「A 对 A 说话」式自指）
/// - `{place}`   当前场景地名
/// - `{faction}` 势力 / 组织
/// - `{object}`  物件
/// - `{action}`  动作短语（不带主语）
/// - `{emotion}` 情绪词 / 短语（谓词式：可接在句号前或「让人」后）
/// - `{emotionN}` 情绪名词（只作「把…压下去 / 咽了回去」一类宾语）
/// - `{dialogue}` 对话内容片段（不含引号与人名）
///
/// 内容均为自研通用网文句式，严禁打包受版权文本。
class BeatCorpus {
  /// 开篇锚定：建立时间、地点、人物在场感的句子。
  final List<String> openers;

  /// 情节推进：交代事件、推进动作的句子。
  final List<String> development;

  /// 张力升级：制造压迫感、危机逼近的句子。
  final List<String> tension;

  /// 高潮爆发：正面碰撞、情绪顶点的句子。
  final List<String> climax;

  /// 转折揭示：反转、真相、意外信息的句子。
  final List<String> twist;

  /// 收束沉淀：结果落地、情绪回落的句子。
  final List<String> resolution;

  /// 章末钩子：悬念、预告下一冲突的句子。
  final List<String> hooks;

  /// 五感描写：视觉、听觉、嗅觉、触觉的环境细节。
  final List<String> sensory;

  /// 对话攻防：带交锋感的对话及其反应描写。
  final List<String> dialoguePairs;

  /// 内心独白：心理活动与权衡的句子。
  final List<String> innerThoughts;

  /// 构造节拍语料库。
  const BeatCorpus({
    required this.openers,
    required this.development,
    required this.tension,
    required this.climax,
    required this.twist,
    required this.resolution,
    required this.hooks,
    required this.sensory,
    required this.dialoguePairs,
    required this.innerThoughts,
  });

  /// 从列表中随机取一条；空列表抛 [StateError]（与 SeededRandom.pick 一致）。
  String _pick(List<String> pool, SeededRandom rng) => rng.pick(pool);

  /// 取一条开篇句。
  String opener(SeededRandom rng) => _pick(openers, rng);

  /// 取一条推进句。
  String developmentBeat(SeededRandom rng) => _pick(development, rng);

  /// 取一条张力句。
  String tensionBeat(SeededRandom rng) => _pick(tension, rng);

  /// 取一条高潮句。
  String climaxBeat(SeededRandom rng) => _pick(climax, rng);

  /// 取一条转折句。
  String twistBeat(SeededRandom rng) => _pick(twist, rng);

  /// 取一条收束句。
  String resolutionBeat(SeededRandom rng) => _pick(resolution, rng);

  /// 取一条章末钩子。
  String hook(SeededRandom rng) => _pick(hooks, rng);

  /// 取一条五感描写。
  String sensoryLine(SeededRandom rng) => _pick(sensory, rng);

  /// 取一条对话攻防。
  String dialoguePair(SeededRandom rng) => _pick(dialoguePairs, rng);

  /// 取一条内心独白。
  String innerThought(SeededRandom rng) => _pick(innerThoughts, rng);

  /// 全部功能组（供测试统计）。
  Map<String, List<String>> get all => <String, List<String>>{
        'openers': openers,
        'development': development,
        'tension': tension,
        'climax': climax,
        'twist': twist,
        'resolution': resolution,
        'hooks': hooks,
        'sensory': sensory,
        'dialoguePairs': dialoguePairs,
        'innerThoughts': innerThoughts,
      };

  /// 情节阶段 → 功能组及权重映射。
  ///
  /// - 起：开篇为主，辅以五感与推进，开局即入对白（首屏有对白是闸门硬指标）；
  /// - 承：推进与对话并重（闸门对白占比下限 18%，对话是完读率抓手）；
  /// - 转：张力 / 高潮 / 转折为主，对话交锋穿插；
  /// - 合：收束为主，辅以独白。
  static Map<String, int> groupsForStage(String stage) {
    switch (stage) {
      case '起':
        return <String, int>{
          _openersRef: 4,
          _sensoryRef: 2,
          _developmentRef: 3,
          _dialoguePairsRef: 3,
          _innerThoughtsRef: 1,
        };
      case '转':
        return <String, int>{
          _tensionRef: 4,
          _climaxRef: 3,
          _twistRef: 3,
          _dialoguePairsRef: 4,
        };
      case '合':
        return <String, int>{
          _resolutionRef: 5,
          _innerThoughtsRef: 2,
          _dialoguePairsRef: 1,
          _sensoryRef: 1,
        };
      case '承':
      default:
        return <String, int>{
          _developmentRef: 4,
          _dialoguePairsRef: 5,
          _innerThoughtsRef: 2,
          _tensionRef: 1,
          _sensoryRef: 1,
        };
    }
  }

  // 以下常量为功能组组名，[groupsForStage] 返回的键即这些字符串，
  // 运行时通过 [groupOf] 把组名解析成实际模板池。
  static const String _openersRef = 'openers';
  static const String _developmentRef = 'development';
  static const String _tensionRef = 'tension';
  static const String _climaxRef = 'climax';
  static const String _twistRef = 'twist';
  static const String _resolutionRef = 'resolution';
  static const String _hooksRef = 'hooks';
  static const String _sensoryRef = 'sensory';
  static const String _dialoguePairsRef = 'dialoguePairs';
  static const String _innerThoughtsRef = 'innerThoughts';

  /// 组名 → 实际模板池。未知组名回退到推进组。
  List<String> groupOf(String key) {
    switch (key) {
      case _openersRef:
        return openers;
      case _developmentRef:
        return development;
      case _tensionRef:
        return tension;
      case _climaxRef:
        return climax;
      case _twistRef:
        return twist;
      case _resolutionRef:
        return resolution;
      case _hooksRef:
        return hooks;
      case _sensoryRef:
        return sensory;
      case _dialoguePairsRef:
        return dialoguePairs;
      case _innerThoughtsRef:
        return innerThoughts;
      default:
        return development;
    }
  }

  /// 按权重从某阶段对应的功能组中取一条模板。
  String pickForStage(String stage, SeededRandom rng) {
    final Map<String, int> weights = groupsForStage(stage);
    int total = 0;
    for (final int w in weights.values) {
      total += w;
    }
    int roll = rng.range(0, total);
    for (final MapEntry<String, int> entry in weights.entries) {
      roll -= entry.value;
      if (roll < 0) {
        return _pick(groupOf(entry.key), rng);
      }
    }
    return _pick(development, rng);
  }
}

// ---------------------------------------------------------------------------
// 默认语料：每个功能组 ≥12 条，覆盖各题材通用。
// ---------------------------------------------------------------------------

/// 默认叙事节拍语料（供 [corpus_manager.CorpusManager] 聚合）。
const BeatCorpus defaultBeatCorpus = BeatCorpus(
  openers: _kOpeners,
  development: _kDevelopment,
  tension: _kTension,
  climax: _kClimax,
  twist: _kTwist,
  resolution: _kResolution,
  hooks: _kHooks,
  sensory: _kSensory,
  dialoguePairs: _kDialoguePairs,
  innerThoughts: _kInnerThoughts,
);

const List<String> _kOpeners = <String>[
  '{place}的天刚蒙蒙亮，{name}已经站在了这里。',
  '辰时刚过，{place}的人声便渐渐稠了起来。',
  '{name}到{place}的时候，风里还带着夜里的凉意。',
  '这是{name}第无数次踏进{place}，但今天不一样。',
  '{place}深处传来钟声，一下一下，敲得人心头发紧。',
  '晨雾未散，{name}的身影已经出现在{place}的入口。',
  '没有人注意到，{name}在{place}的角落停了下来。',
  '{faction}的告示才贴出半天，{place}前就围满了人。',
  '日头偏西，{place}的影子被拉得老长，{name}终于来了。',
  '雨后的{place}泛着一股土腥气，{name}深一脚浅一脚地走。',
  '{object}被{name}贴身收着，一路随着心跳发烫。',
  '夜里落过一场雨，{place}的石阶上还汪着水光。',
  // —— 2026-09 写手优化：扩容开篇池（降低跨章 8-gram 撞车）——
  '{place}的灯已经点上了，{name}踩着最后一缕天光进门。',
  '牌匾上的字被磨得发亮，{name}在{place}门前站定。',
  '{faction}的车马停在{place}外，车辕上还挂着没卸的泥。',
  '{name}到得比约定的时辰早了半个钟头。',
  '{place}里正喧闹，{name}一进门，话音就低了下去。',
  '{ally}在{place}的廊下等了许久，手里的茶换了三遍。',
];

const List<String> _kDevelopment = <String>[
  '{name}{action}，顺着人群往里走，眼睛却在飞快地打量四周。',
  '事情比预想的顺利，顺利得让{name}反而不敢松劲。',
  '{ally}凑过来压低声音：「先别动手，看看再说。」',
  '{name}不动声色地绕到侧面，把整件事从头到尾又捋了一遍。',
  '按照计划，接下来只差最后一步。',
  '{name}把{object}递过去，指尖在对方看不见的角度轻轻一压。',
  '人群忽然朝两边让开，来人的身份不言自明。',
  '{name}沿着{place}的回廊疾行，靴底敲出的声响又急又稳。',
  '{ally}在前头引路，一路上把{faction}的门道讲了个七七八八。',
  '时间一点点过去，{place}的气氛却越来越不对。',
  '{name}试着催动体内那股暖流，这一次竟没有半分滞涩。',
  '线索断在这里，{name}却从{object}的夹层里摸出了新东西。',
  '{name}把{object}翻来覆去看了三遍，终于看出了门道。',
  '路过的仆役多看了{ally}一眼，又飞快地低下头去。',
  '{name}借着整理袖口的动作，把角落里的动静尽收眼底。',
  '验过腰牌，门房的脸色变了变，还是把人放了进去。',
  '{name}与{rival}擦肩而过，谁都没有先开口。',
  '消息比人跑得快，{name}还没进门，{place}里已经传开了。',
  '{ally}塞给{name}一张字条，转身就混进了人群。',
  '{name}按着{rival}留下的记号，一路摸到了后院墙根。',
  // —— 2026-09 写手优化：扩容推进池 ——
  '{name}把{object}用布裹好，贴身收妥。',
  '两拨人马在{place}外撞了个正着，谁也不肯先让路。',
  '{name}借着添茶的工夫，把{ally}的神色又看了一遍。',
  '{rival}带来的消息像块石头，砸进原本平静的水面。',
  '账本翻到第三页，{name}的手指停住了。',
  '{ally}把灯往桌心挪了挪，压低了声音。',
];

const List<String> _kTension = <String>[
  '空气像是被人抽走了，{place}安静得能听见自己的心跳。',
  '{rival}缓缓抬起眼，那道目光像刀子一样刮过来。',
  '不对——{name}的后颈猛地绷紧，杀气！',
  '四面八方的退路，不知何时已经被堵死了。',
  '{rival}笑了，笑声不大，却让在场每个人心头一寒。',
  '{object}开始发烫，这是危险临近的信号。',
  '{name}数着自己的呼吸，把翻涌的{emotionN}一寸寸压下去。',
  '头顶的房梁发出不堪重负的呻吟，尘灰簌簌往下掉。',
  '{rival}每向前一步，{name}掌心的汗就多一分。',
  '远处传来一声闷响，紧接着是第二声、第三声，越来越近。',
  '所有人都看得出，这一击之下必有一方倒下。',
  '灯花爆了一声，{place}里的火光骤然暗了一瞬。',
  '烛火无风自动，{name}握着{object}的手紧了紧。',
  '{rival}身后的人影一字排开，堵死了最后一条路。',
  '空气里有血的味道，很淡，但{name}不会闻错。',
  '第二遍钟声响到一半，戛然而止。',
  '{name}听见自己的名字从{rival}口中吐出来，像含着一把碎冰。',
  '鼓声停了，全场只剩{rival}的脚步声，一步一步踩在人心上。',
  // —— 2026-09 写手优化：扩容张力池 ——
  '{name}忽然发现，自己一直站着的这块地正被人围拢。',
  '不知何时，{place}的两扇门都被人从外面守住了。',
  '{rival}不再说话，只把{object}在指间转了一圈。',
  '远处有人吹熄了灯，一排，接着一排。',
  '{name}数到第七声心跳时，明白了这不是巧合。',
  '{ally}的手悄悄按上{name}的手腕——别动。',
  // —— 2026-09 写手优化：首屏冲突信号保底句 ——
  // 闸门要求首屏 300 字内出现「威胁/要求/损失」类信号（词表含
  // 夺/断/碎/血/伤/罚/赔/警告/期限/逐/抢/抓/退婚 等）。以下句子把这些
  // 冲突标记写进压力情境，供强制张力取样时命中首屏硬指标。
  '{rival}的人已经堵住门口：{object}要么交出来，要么留下一条胳膊。',
  '有人把{name}的{object}摔在地上，碎片溅到脚边。',
  '契约上的期限就压在今日，逾期要赔上三年寿元。',
  '{faction}的封门令贴在{place}最显眼的位置，上头第一个名字就是{name}。',
  '退婚的帖子当着满堂人的面递到{name}手上。',
  '{name}的右臂还伤着，绷带底下渗出的血迹已经透出布面。',
  '{rival}把话说得明白：三日之内要么交出{object}，要么逐出{place}。',
];

/// 首屏冲突句池（番茄闸门首屏硬指标专用）。
///
/// 闸门要求首屏 300 字内出现「威胁 / 要求 / 损失」类信号，判定用一张
/// 冲突标记词表（含：夺 断 碎 血 伤 罚 赔 警告 期限 逐 抢 抓 退婚 除名
/// 当场 抬走 拉走 遗物 最后 偿命 让位 跪 …）。本池每条都把这类标记
/// 写进压力情境，模板引擎在首段强制取样一条，保证首屏不出现
/// 「无冲突信号」——旧版从通用张力池随机抽，只有约 1/4 命中。
///
/// 内容为自研原创句式，严禁打包受版权文本。
const List<String> openingConflictSentences = <String>[
  // 每条都必须含闸门冲突词表中的一个词（当场/断/抢/碎/退婚/血/伤/罚/
  // 赔/期限/逐/抓/除名/封门/警告/死/抬走…），否则首屏仍会被判无冲突信号。
  '{rival}的人已经堵住门口，非要{name}当场把{object}交出来。',
  '有人当众把{name}的{object}摔在地上，碎片一直溅到脚边。',
  '契书上的期限就压在今日，逾期要赔三年寿元。',
  '{faction}的封门令贴在{place}最显眼处，头一个名字就是{name}。',
  '退婚的帖子当着满堂人的面，被递到了{name}手上。',
  '{name}的右臂还有伤，绷带底下的血迹已经透到布面外。',
  '{rival}把话说得明白：三日之内不交出{object}，就逐出{place}。',
  '{name}的名字被人从名册上划掉了——除名，即刻生效。',
  '有人在{place}门口拦下{name}，伸手就要抢那件{object}。',
  '{ally}压着声音警告：今日之内必须离开{place}，否则连命都保不住。',
];

const List<String> _kClimax = <String>[
  '电光石火之间，{name}{action}，快得没有人看清轨迹。',
  '轰然巨响，气浪掀翻了半个{place}。',
  '{name}把积攒了许久的{emotionN}在这一刻尽数砸了出去。',
  '「住手！」{name}一声怒喝，人已欺身而至。',
  '两股力道狠狠相撞，僵持不过三息，胜负已分。',
  '{rival}的攻势密不透风，{name}却硬生生从中撕开一道口子。',
  '这一下用尽了全力，{name}连站姿都晃了一晃。',
  '血珠溅上半空，{rival}难以置信地看着自己颤抖的手。',
  '{object}应声而碎，碎片里迸出的光却照亮了全场。',
  '{name}咬碎了牙关，硬扛着这雷霆一击没有后退半步。',
  '满场哗然之中，唯有{name}的呼吸依旧平稳如初。',
  '胜负在此一举，{name}把所有底牌都摊在了这一击里。',
  '{name}借力旋身，反手一记肘击正中{rival}胸口。',
  '地面裂开蛛网般的纹路，两道身影在尘埃里交错而过。',
  '{name}把最后一丝力气都灌进了这一击。',
  '{rival}的兵刃断了，断口处还冒着白气。',
  // —— 2026-09 写手优化：扩容高潮池 ——
  '{name}一把攥住{object}，指缝里渗出血来。',
  '这一击没有花哨，{rival}却不得不用双手去接。',
  '{place}的瓦片被震落一片，砸在地上粉碎。',
  '{name}站着没动，{rival}却先退了半步。',
  '两只手同时按上{object}，谁也没有松。',
];

const List<String> _kTwist = <String>[
  '直到这时{name}才发现，事情从一开始就不是那个样子。',
  '「你以为你赢定了？」{rival}撕下伪装，眼底一片冰凉。',
  '{object}背面赫然刻着一行小字，正是{name}再熟悉不过的手迹。',
  '{ally}站在了对面，这个事实比任何刀剑都伤人。',
  '原来所谓机缘，不过是有人布下的一个局。',
  '记忆里模糊的一角忽然清晰，{name}浑身发冷。',
  '{faction}的态度一夜之间急转直下，其中必有隐情。',
  '死者手中攥着的，竟是半块{name}从小佩戴的信物。',
  '真话说了一半，往往比谎话更让人心惊。',
  '{rival}临走前丢下的那句话，此刻才显出真正的分量。',
  '账目对不上，缺的那一笔恰好指向最不可能的人。',
  '{name}反复确认了三遍，结论依然荒谬得可怕。',
  '{ally}递来的水囊里，飘着一缕几乎看不见的丝线。',
  '{rival}的鞋底沾着{place}特有的红泥——他根本不该来过这里。',
  '那份名单上，赫然写着{ally}的名字。',
  '{name}忽然想起，{object}的钥匙从来只有一把。',
];

const List<String> _kResolution = <String>[
  '尘埃落定，{place}恢复了往日的嘈杂，仿佛什么都没发生过。',
  '{name}长长吐出一口气，紧绷的肩膀这才垮了下来。',
  '{ally}拍着{name}的肩，半天只说出一句「好样的」。',
  '夜深了，{name}独自坐在灯下，把今日种种又想了一遍。',
  '该来的总会来，躲不掉的，{name}便不再躲。',
  '伤好得差不多了，有些账也该慢慢算了。',
  '{object}重新收进怀里，这一次，{name}握得更紧。',
  '{faction}的封赏如期而至，{name}却只淡淡谢过。',
  '风波暂平，可{name}清楚，这不过是暴风雨前的宁静。',
  '日子照旧过，只是{place}的人再看{name}时，眼神都变了。',
  '睡梦里，{name}又回到了白天那一刻，这一次没有失手。',
  '第二天清晨，{name}照常出现在练功场上，仿佛无事发生。',
  // —— 2026-09 写手优化：扩容收束池 ——
  '{name}把{object}擦干净，收进怀里。',
  '{place}的人散去大半，只剩零星几盏灯还亮着。',
  '{ally}没再说什么，只把门带上了。',
  '{name}把袖子里的血迹掩好，抬头时神色如常。',
  '这一夜{name}睡得很沉，梦里没有刀光。',
];

const List<String> _kHooks = <String>[
  '门外传来一阵极轻、却绝对刻意放出来的脚步声。',
  '{rival}留下的最后一句话在耳边反复回响——「三日之后，老地方。」',
  '{object}忽然毫无征兆地震了一下。',
  '深夜，{faction}方向的天空亮起了一道不祥的红光。',
  '信使滚落下马，手里死死攥着一封火漆未拆的信。',
  '{name}吹熄灯火，黑暗里那双眼睛却迟迟没有合上。',
  '第二天一早，{place}门口多了一具无名尸首。',
  '更漏三声，窗外黑影一闪而过，快得像是错觉。',
  '{ally}欲言又止，最终还是把那句警告咽了回去。',
  '名册翻到最后一页，{name}的瞳孔骤然收缩。',
  '远方的地平线上，烟柱正一根接一根地竖起来。',
  '「他们来了。」不知是谁在暗处低低说了一句。',
  // —— 2026-09 写手优化：扩容章末钩子池 ——
  '{name}推门进屋，桌上多了一封没有署名的信。',
  '{object}在袖中轻轻一响，像是回应了什么。',
  '{ally}的名字，忽然从{place}的名册上被划掉了。',
  '更远处的山道上，有人正朝{place}来。',
];

const List<String> _kSensory = <String>[
  '{place}里弥漫着一股陈年木料混着香灰的味道。',
  '风从窗缝里挤进来，烛火伏低了又直起来。',
  '脚下的木板咯吱作响，每一声都在寂静里放大。',
  '茶汤的热气袅袅上升，映得{name}的眉眼有些模糊。',
  '墙外更鼓敲过二更，寒意顺着衣领往里钻。',
  '指尖抚过{object}粗糙的表面，细小的划痕硌着指腹。',
  '远处市集的喧闹隔着一道墙，闷闷地涌进来。',
  '{place}的日光斜斜切进来，照亮空气里浮动的尘埃。',
  '血腥味混着雨水漫开，呛得人喉头发紧。',
  '檐角铁马叮当乱响，风比想象中大得多。',
  '墨迹未干的纸页散发出清苦的气味。',
  '灶膛里的火星噼啪炸开，映红了半面土墙。',
  // —— 2026-09 写手优化：扩容五感，减少同一氛围句的跨段撞车 ——
  '灶上煨着的药汤咕嘟作响，苦味漫了满屋。',
  '烛芯结了灯花，光线暗了一截。',
  '晾在院里的粗布被吹得猎猎作响。',
  '指尖摸到刀柄缠绳被汗浸出的硬结。',
];

/// 对话攻防模板池。
///
/// 2026-09 写手优化（重复率治理）：
/// 1. **禁止硬编码尾句**。旧版在模板尾部写死「别让我说第二遍」「我数三声」
///    「你知道自己在说什么吗」等——模板一旦复用，这些尾句整句重复，
///    闸门「整句重复率 >1%」即判重写（实测第 2 章三处重复全源于此）。
///    需要这类台词时放进引擎的 dialogue 内容池轮转，而不是钉在模板上。
/// 2. **规模 ≥ 单章用量**。旧池 24~30 条 < 单章对白取样数（约 25~35 次），
///    池被用尽后 `_pickFromPool` 只能兜底复用模板。扩到 48 条后
///    单章用不尽，从机制上保证「一章之内每条攻防模板至多一次」。
const List<String> _kDialoguePairs = <String>[
  '「{dialogue}」{rival}慢条斯理地说，像是在谈论今天的天气。',
  '{name}冷笑一声：「{dialogue}。」',
  '「{dialogue}？」{ally}的声音陡然拔高。',
  '「{dialogue}。」{name}答得干脆，不给对方留半分余地。',
  '{rival}眯起眼：「{dialogue}——有意思，可惜晚了。」',
  '「{dialogue}。」这句话很轻，落在耳中却重若千钧。',
  '{name}沉默片刻，才接住话头：「{dialogue}。」',
  '「{dialogue}！」{rival}拍案而起。',
  '{ally}苦笑着摇头：「{dialogue}。」',
  '「{dialogue}。」{name}说完转身就走，任凭身后议论纷纷。',
  '「{dialogue}。」对方话里有话，{name}听懂了，面上却不露分毫。',
  '{rival}盯着{name}看了许久，忽而一笑：「{dialogue}。」',
  '「{dialogue}。」{name}顿了顿，又补了一句。',
  '{rival}抱着臂，见{name}不接话，他又笑了。',
  '「{dialogue}。」{ally}把声音压到只有两个人听得见。',
  '{name}摇了摇头，没接这个话茬：「{dialogue}。」',
  '「{dialogue}？」{rival}像是听见了天大的笑话，「就凭你们？」',
  '{ally}急了：「{dialogue}！」',
  '「{dialogue}。」{name}把{object}推了过去，「东西你收好。」',
  '{rival}凑近半步，一字一顿：「{dialogue}。」',
  '「{dialogue}。」{ally}说完便退到一边，把路让了出来。',
  '{name}笑了：「{dialogue}。」',
  '「{dialogue}？」{rival}的手按上了刀柄。',
  '「{dialogue}。」{name}淡淡道。',
  // —— 2026-09 写手优化：扩容对白攻防，压低同一攻防模板的复用频率 ——
  '{rival}把{object}往桌上一放：「{dialogue}。就现在。」',
  '「{dialogue}。」{name}看都没看对方一眼。',
  '{ally}把声音压得极低：「{dialogue}。听懂了就点头。」',
  '「{dialogue}？」{rival}来回踱了两步，猛地停住。',
  '{name}把茶碗放下，才慢悠悠开口：「{dialogue}。」',
  '「{dialogue}。」{rival}笑了笑，笑意却没到眼底。',
  '{ally}换了个坐姿，手指叩着桌面：「{dialogue}。」',
  '「{dialogue}。」{name}侧过脸，把话丢在两个人之间。',
  '{rival}把话说得极慢，像是怕{name}听不懂：「{dialogue}。」',
  '「{dialogue}。」{ally}没再劝，只把{object}按回{name}手边。',
  '{name}没抬眼：「{dialogue}。」',
  '「{dialogue}。」{rival}往后退了半步，这是他第一次退。',
  '{ally}的语速快了起来：「{dialogue}。」',
  '「{dialogue}。」{name}把后半句咽了回去。',
  '{rival}嗤了一声：「{dialogue}。」',
  '「{dialogue}。」{ally}一边说一边去够门闩。',
  '{name}把{object}推到桌子中央：「{dialogue}。」',
  '「{dialogue}。」{rival}的目光越过{name}，落在门外。',
  '{ally}看了看{name}的脸色，把话改了口：「{dialogue}。」',
  '「{dialogue}？」{rival}伸手按住{object}，「再说一遍。」',
  '{name}把声音放软了些：「{dialogue}。」',
  '「{dialogue}。」{ally}说完就后悔了，可话已经出了口。',
  '{rival}忽然换了称呼：「{dialogue}。」',
  // —— 2026-09 写手优化：双回合攻防模板 ——
  // 番茄闸门按「引号内字数 / 总字数」量对白占比（下限 18%，建议 25~45%），
  // 单句对白 + 长旁白的模板结构天然压不住这个比例。以下模板一正一反
  // 两个引号（各由独立的 dialogue 内容池槽位填充），既是对白交锋的真实
  // 形态，也把引号内字数占比拉进番茄达标区间。
  '「{dialogue}。」{rival}说。\n「{dialogue}。」{name}答。',
  '「{dialogue}？」{ally}追问。\n「{dialogue}。」{name}没打算解释。',
  '{name}把手一摊：「{dialogue}。」\n{rival}盯着看了半晌：「{dialogue}。」',
  '「{dialogue}。」{ally}的声音低下去。\n「{dialogue}。」{name}应了一声。',
  '「{dialogue}」\n「{dialogue}。」两句话撞在一起，谁也没让。',
  '{rival}先开的口：「{dialogue}。」\n「{dialogue}。」{name}把话接了下去。',
  '「{dialogue}。」{name}说。\n{rival}眯起眼：「{dialogue}。」',
  '「{dialogue}？」\n「{dialogue}。」{ally}替{name}把话说了。',
];

const List<String> _kInnerThoughts = <String>[
  '{name}在心里飞快地权衡：退，前功尽弃；进，十死无生。',
  '不能露怯——至少现在不能。',
  '如果{ally}说的是真的，那么此前的一切都要推倒重来。',
  '{name}想起临行前的承诺，胸口像堵着一团烧红的炭。',
  '赌吗？赌。除此之外别无他法。',
  '对方越是从容，说明水越深。',
  '{name}把{emotionN}咽了回去，眼下不是动情的时候。',
  '一步一步走到今天，靠的从来不只是运气。',
  '最坏的结果无非是死，可比起等死，{name}宁可去搏。',
  '这件事透着蹊跷，而蹊跷就在于它太顺理成章。',
  '{name}提醒自己：越是这种时候，越要慢。',
  '罢了，路是自己选的，跪着也要走完。',
  // —— 2026-09 写手优化：扩容独白，给「合」段更多心理质感 ——
  '{name}在心里把话演练了三遍，开口时还是走了样。',
  '念头一转再转，最后只剩一个字：等。',
  '走到这一步，退路是自己亲手烧掉的。',
  '{name}盯着自己的手——方才抖没抖，只有自己知道。',
];
