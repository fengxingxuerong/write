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
/// - `{place}`   当前场景地名
/// - `{faction}` 势力 / 组织
/// - `{object}`  物件
/// - `{action}`  动作短语（不带主语）
/// - `{emotion}` 情绪词 / 短语
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
  /// - 起：开篇为主，辅以五感与推进；
  /// - 承：推进为主，穿插对话与独白；
  /// - 转：张力 / 高潮 / 转折按 4:3:3 加权；
  /// - 合：收束为主，辅以独白。
  static Map<String, int> groupsForStage(String stage) {
    switch (stage) {
      case '起':
        return <String, int>{
          _openersRef: 5,
          _sensoryRef: 2,
          _developmentRef: 2,
          _innerThoughtsRef: 1,
        };
      case '转':
        return <String, int>{
          _tensionRef: 4,
          _climaxRef: 3,
          _twistRef: 3,
          _dialoguePairsRef: 1,
        };
      case '合':
        return <String, int>{
          _resolutionRef: 5,
          _innerThoughtsRef: 2,
          _sensoryRef: 1,
        };
      case '承':
      default:
        return <String, int>{
          _developmentRef: 5,
          _dialoguePairsRef: 2,
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
];

const List<String> _kTension = <String>[
  '空气像是被人抽走了，{place}安静得能听见自己的心跳。',
  '{rival}缓缓抬起眼，那道目光像刀子一样刮过来。',
  '不对——{name}的后颈猛地绷紧，杀气！',
  '四面八方的退路，不知何时已经被堵死了。',
  '{rival}笑了，笑声不大，却让在场每个人心头一寒。',
  '{object}开始发烫，这是危险临近的信号。',
  '{name}数着自己的呼吸，把翻涌的{emotion}一寸寸压下去。',
  '头顶的房梁发出不堪重负的呻吟，尘灰簌簌往下掉。',
  '{rival}每向前一步，{name}掌心的汗就多一分。',
  '远处传来一声闷响，紧接着是第二声、第三声，越来越近。',
  '所有人都看得出，这一击之下必有一方倒下。',
  '灯花爆了一声，{place}里的火光骤然暗了一瞬。',
];

const List<String> _kClimax = <String>[
  '电光石火之间，{name}{action}，快得没有人看清轨迹。',
  '轰然巨响，气浪掀翻了半个{place}。',
  '{name}把积攒了许久的{emotion}在这一刻尽数砸了出去。',
  '「住手！」{name}一声怒喝，人已欺身而至。',
  '两股力道狠狠相撞，僵持不过三息，胜负已分。',
  '{rival}的攻势密不透风，{name}却硬生生从中撕开一道口子。',
  '这一下用尽了全力，{name}连站姿都晃了一晃。',
  '血珠溅上半空，{rival}难以置信地看着自己颤抖的手。',
  '{object}应声而碎，碎片里迸出的光却照亮了全场。',
  '{name}咬碎了牙关，硬扛着这雷霆一击没有后退半步。',
  '满场哗然之中，唯有{name}的呼吸依旧平稳如初。',
  '胜负在此一举，{name}把所有底牌都摊在了这一击里。',
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
];

const List<String> _kHooks = <String>[
  '就在这时，门外传来一阵极轻、却绝对刻意放出来的脚步声。',
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
];

const List<String> _kDialoguePairs = <String>[
  '「{dialogue}」{rival}慢条斯理地说，像是在谈论今天的天气。',
  '{name}冷笑一声：「{dialogue}。」',
  '「{dialogue}？」{ally}的声音陡然拔高，「你知道自己在说什么吗！」',
  '「{dialogue}。」{name}答得干脆，不给对方留半分余地。',
  '{rival}眯起眼：「{dialogue}——有意思，可惜晚了。」',
  '「{dialogue}。」这句话很轻，落在耳中却重若千钧。',
  '{name}沉默片刻，才缓缓开口：「{dialogue}。」',
  '「{dialogue}！」{rival}拍案而起，满座皆惊。',
  '{ally}苦笑着摇头：「{dialogue}。你自己掂量吧。」',
  '「{dialogue}。」{name}说完转身就走，任凭身后议论纷纷。',
  '「{dialogue}。」对方话里有话，{name}听懂了，面上却不露分毫。',
  '{rival}盯着{name}看了许久，忽而一笑：「{dialogue}。」',
];

const List<String> _kInnerThoughts = <String>[
  '{name}在心里飞快地权衡：退，前功尽弃；进，十死无生。',
  '不能露怯——至少现在不能。',
  '如果{ally}说的是真的，那么此前的一切都要推倒重来。',
  '{name}想起临行前的承诺，胸口像堵着一团烧红的炭。',
  '赌吗？赌。除此之外别无他法。',
  '对方越是从容，说明水越深。',
  '{name}把{emotion}咽了回去，眼下不是动情的时候。',
  '一步一步走到今天，靠的从来不只是运气。',
  '最坏的结果无非是死，可比起等死，{name}宁可去搏。',
  '这件事透着蹊跷，而蹊跷就在于它太顺理成章。',
  '{name}提醒自己：越是这种时候，越要慢。',
  '罢了，路是自己选的，跪着也要走完。',
];
