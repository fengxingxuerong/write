import 'dart:async';
import 'dart:isolate';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/constraints/generation_constraints.dart';
import 'package:novel_writer/engine/corpus/beat_corpus.dart';
import 'package:novel_writer/engine/corpus/corpus_manager.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/random/seeded_random.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/generation_config.dart';

const String _kCancel = 'cancel';
const String _kCancelled = 'cancelled';

/// 主隔离 -> 生成隔离 的启动消息。
class _IsolateMessage {
  final SendPort resultPort;
  final GenerationConfig config;
  final ContextBundle ctx;
  const _IsolateMessage(this.resultPort, this.config, this.ctx);
}

/// 生成隔离 -> 主隔离 的最终结果消息。
class _IsolateResult {
  final String content;
  final int actualWords;
  final GenerationConfig usedConfig;
  const _IsolateResult(this.content, this.actualWords, this.usedConfig);
}

/// 由种子推导随机种子：同配置 -> 同输出（可复现），randomLevel 扰动随机性。
///
/// 多章连写时各章的 [GenerationConfig.continuation] 不同：把它混进种子，
/// 否则每章拿同一随机序列，会生成「换皮重复」的章节（节奏、句式、
/// 人物出场完全同构，只是开头过渡段不同）。
int _deriveSeed(GenerationConfig config) {
  final int base = config.genre.hashCode ^
      config.tone.hashCode ^
      config.targetWords ^
      (config.continuation?.hashCode ?? 0);
  final int jitter = (config.randomLevel * 1000).floor();
  return (base ^ jitter) & 0x7FFFFFFF;
}

/// 生成隔离入口。
///
/// 1. 创建取消接收端口，并把其 SendPort 回传给主隔离；
/// 2. 在隔离内重建语料（零网络）；
/// 3. 运行核心生成，周期性回报进度并响应取消。
Future<void> _isolateEntry(_IsolateMessage msg) async {
  final ReceivePort cancelReceive = ReceivePort();
  // 把手柄回传，便于主隔离在用户取消时通知本隔离。
  msg.resultPort.send(cancelReceive.sendPort);

  final CorpusManager corpus = CorpusManager.loadPreset(msg.config.genre);
  final SeededRandom rng = SeededRandom(seed: _deriveSeed(msg.config));
  final _TemplateEngineCore core = _TemplateEngineCore(
    corpus: corpus,
    rng: rng,
    config: msg.config,
    ctx: msg.ctx,
  );

  bool cancelled = false;
  final StreamSubscription<dynamic> sub =
      cancelReceive.listen((dynamic m) {
    if (m == _kCancel) cancelled = true;
  });

  try {
    final GenerationResult result = await core.run(msg.resultPort, () => cancelled);
    if (cancelled) {
      msg.resultPort.send(_kCancelled);
    } else {
      msg.resultPort.send(_IsolateResult(
        result.content,
        result.actualWords,
        result.usedConfig,
      ));
    }
  } catch (e) {
    // 生成异常一律视为取消（主隔离丢弃中间结果）。
    msg.resultPort.send(_kCancelled);
  } finally {
    await sub.cancel();
    cancelReceive.close();
  }
}

/// 模板生成引擎（默认离线实现）。
///
/// 在独立 [Isolate] 中运行，保证 UI 不卡顿；支持通过 [CancelToken] 取消，
/// 并回报 [GenerationProgress]。生成采用「章节场景锚定 + 节拍驱动叙事」：
/// 每章固定场景 / 对手 / 盟友 / 关键物，情节骨架的起承转合映射到
/// 叙事功能句组（开篇 / 推进 / 张力 / 高潮 / 转折 / 收束），并以
/// 章末钩子收尾，使正文具备明确的场景连续性与叙事节奏。
class TemplateEngine implements GenerationEngine {
  /// 构造引擎。
  const TemplateEngine();

  @override
  Future<GenerationResult> generate(
    GenerationConfig config,
    ContextBundle ctx, {
    CancelToken? cancelToken,
    void Function(GenerationProgress)? onProgress,
  }) async {
    final ReceivePort resultPort = ReceivePort();
    final Completer<GenerationResult> completer =
        Completer<GenerationResult>();
    late final Isolate isolate;
    SendPort? cancelPort;
    bool cancelRequested = false;

    void cleanup() {
      isolate.kill(priority: Isolate.immediate);
      resultPort.close();
    }

    resultPort.listen((dynamic message) {
      if (message is SendPort) {
        // 生成隔离回传的取消手柄。
        cancelPort = message;
        if (cancelRequested) cancelPort?.send(_kCancel);
      } else if (message is GenerationProgress) {
        onProgress?.call(message);
      } else if (message is _IsolateResult) {
        if (!completer.isCompleted) {
          completer.complete(GenerationResult(
            content: message.content,
            actualWords: message.actualWords,
            usedConfig: message.usedConfig,
          ));
        }
        cleanup();
      } else if (message == _kCancelled) {
        if (!completer.isCompleted) {
          completer.completeError(const GenerationCancelledException());
        }
        cleanup();
      }
    });

    isolate = await Isolate.spawn(
      _isolateEntry,
      _IsolateMessage(resultPort.sendPort, config, ctx),
    );

    // 注册取消回调：通知生成隔离终止。
    cancelToken?.onCancel = () {
      cancelRequested = true;
      cancelPort?.send(_kCancel);
    };

    try {
      return await completer.future;
    } on GenerationCancelledException {
      rethrow;
    } catch (e) {
      throw EngineException('生成失败', e);
    }
  }
}

/// 生成核心（在隔离内运行）。
///
/// 依据 [CorpusManager] 语料 + 情节骨架 + 叙事节拍语料 + 可控随机，
/// 按节拍生成段落；约束单章字数 ≤ [GenerationConstraints.maxWordsPerChapter]。
class _TemplateEngineCore {
  _TemplateEngineCore({
    required this.corpus,
    required this.rng,
    required this.config,
    required this.ctx,
  }) : _controller = ConstraintController(config.constraints);

  final CorpusManager corpus;
  final SeededRandom rng;
  final GenerationConfig config;
  final ContextBundle ctx;

  final ConstraintController _controller;

  /// 每个句池的去重窗口，防止短距离内句子重复。
  ///
  /// 各功能句池扩容后最大 40 条（对白攻防），窗口取 48 覆盖全部句池：
  /// 每条模板整章至多出现一次，从机制上钉死闸门的
  /// 「整句重复率 >1%」硬指标（旧窗口 24 小于扩容后的对白池，
  /// 同一攻防模板同章可复用，是重复率超标的主因）。
  static const int _poolDedupeWindow = 48;

  /// 句池使用记录（按池名分桶的循环缓冲）。
  final Map<String, List<String>> _recentByPool = <String, List<String>>{};

  /// 本章已产出的整句集合（按填充后的文本查重）。
  ///
  /// 闸门把「整句重复率 >1%」列为重写级硬指标，而模板轮转只能保证
  /// 模板不复用——同一模板若两次取到相同占位符值，仍会产出相同整句。
  /// 故在填充后再查一层重。
  final Set<String> _emitted = <String>{};

  /// 取一条节拍句并填充占位符；填充结果若与本章已有整句重复则换一条重试。
  /// 取一条节拍句并登记查重。
  ///
  /// [forceDialogue] 为 true 时只从对白攻防池取样：用于首屏保底与
  /// 对白占比保底（番茄硬指标：首段须有对白、引号内字数占比 ≥18%）。
  /// [forceTension] 为 true 时只从首屏冲突池取样：用于首屏冲突信号保底
  /// （闸门要求首屏 300 字内出现威胁/要求/损失类信号）。
  String _nextBeatSentence(
    String stage, {
    bool forceDialogue = false,
    bool forceTension = false,
  }) {
    // 重试 12 次：对话池（64 模板 × 71 内容）与各功能句池的组合空间
    // 很大，短距离撞句几乎总能通过重选绕开。
    for (int attempt = 0; attempt < 12; attempt++) {
      final String filled =
          _fill(_pickBeatByFlag(forceDialogue, forceTension, stage));
      if (_emitted.add(filled)) {
        _countBeat(filled);
        return filled;
      }
    }
    // 兜底：句池组合已接近耗尽，接受一次重复，不阻塞生成。
    final String last =
        _fill(_pickBeatByFlag(forceDialogue, forceTension, stage));
    _emitted.add(last);
    _countBeat(last);
    return last;
  }

  /// 按强制标志选模板池：对白 > 首屏冲突 > 阶段加权。
  String _pickBeatByFlag(bool forceDialogue, bool forceTension, String stage) {
    if (forceDialogue) {
      return _pickFromPool('beat:dialoguePairs', _dialoguePairPool);
    }
    if (forceTension) {
      return _pickFromPool('beat:openingConflict', openingConflictSentences);
    }
    return _pickBeat(stage);
  }

  /// 统计对白/旁白句数（用于对白占比保底）。
  void _countBeat(String filled) {
    _totalBeats++;
    if (filled.contains('「')) _dialogueBeats++;
  }

  /// 当前对白句占比是否偏低（低于 1/3 就该在下一句补一次对白）。
  ///
  /// 番茄闸门按「引号内字数 / 总字数」量对白占比，下限 18%、建议 25~45%；
  /// 纯靠阶段权重随机取样时，实测约两成章次会掉到 17% 以下被闸门判重写。
  bool get _needsDialogue => _dialogueBeats * 3 < _totalBeats;

  /// 对白攻防池（强制对白取样用；与 beatCorpus.dialoguePairs 同源）。
  List<String> get _dialoguePairPool => corpus.beatCorpus.dialoguePairs;

  /// 用上一章结尾文本预置已用句集合（跨章查重种子）。
  ///
  /// 来源有三：`continuation`（上一章末尾 300 字）、`ctx.plotSummary`
  /// （前情提要：最近 2~3 章的章名 + 结尾片段）、`ctx.foreshadowing`
  /// （伏笔账本）。只收长度 ≥10 的完整句：短句（「他顿了顿。」）是节奏
  /// 手段，跨章复用不算事故，全部禁掉反而会压缩可用句式。
  void _seedEmittedFromContinuation() {
    final List<String> sources = <String>[
      config.continuation ?? '',
      ctx.plotSummary,
      ctx.foreshadowing,
    ];
    for (final String src in sources) {
      if (src.trim().isEmpty) continue;
      for (final String raw in src.split(RegExp(r'[。！？…\n]+'))) {
        final String s = raw.trim();
        if (s.length >= 10) _emitted.add(s);
      }
    }
  }

  // ---- 章节级场景状态（整章锚定，保证场景与人物一致） ----

  /// 主角名。
  late String _hero;

  /// 本章对手 / 敌对者。
  late String _rival;

  /// 本章盟友 / 亲近者。
  late String _ally;

  /// 本章主场景地名。
  late String _scenePlace;

  /// 本章已写段落数（首段对白保底用）。
  int _paragraphsWritten = 0;

  /// 本章已写句数中属对白的句数（对白占比保底用）。
  int _dialogueBeats = 0;

  /// 本章已写句数（对白占比保底用）。
  int _totalBeats = 0;

  /// 正文是否已开始（章节第一句已落笔）。用于章首避雷判断，
  /// 不能用 `_emitted.isEmpty`——续写章的 `_emitted` 会预置上一章末尾句。
  bool _chapterStarted = false;

  /// 本章关联势力。
  late String _sceneFaction;

  /// 本章关键物件。
  late String _sceneObject;

  /// 承接上文时拼接的过渡段模板。
  static const List<String> _continuationOpeners = <String>[
    '这一夜，{place}的灯火久久未熄。',
    '翌日清晨，{place}的雾气还未散尽。',
    '时间一点点流逝，{name}的心绪却无法平复。',
    '事情远未结束，{name}知道真正的风暴还在后头。',
    '过了许久，{place}才重新恢复平静。',
    '那一幕过后，{name}久久难以入眠。',
  ];

  /// 节拍提示织入正文时的引导语。
  static final RegExp _weatherOpenRe =
      RegExp(r'^\s*[^\n]{0,16}[雨雪霜雾风]');

  /// 节拍提示织入正文时的引导语。
  ///
  /// 注意：不得包含 [FanqieGateChecker._leak]（及 scripts/fanqie_review.py
  /// PROMPT_LEAK）里的短语——引导语会大量出现在正文里，撞上泄漏黑名单
  /// 会被整章判「提示词残留」。
  ///
  /// 2026-09 写手优化：旧版仅 5 条，平均每 2~3 段就复用一次同一引导语，
  /// 是成书「机械感」的第一来源。扩到 25 条并覆盖五种句法形态
  /// （时间锚点 / 场所动作 / 声音先至 / 心理预期 / 承接转折），
  /// 且一律不含「雨雪霜雾风」五字（避开闸门的「以天气起手」首屏红线），
  /// 取样经 [_pickFromPool] 分池去重：窗口 24 内不重复。
  static const List<String> _hintLeadIns = <String>[
    // —— 时间锚点 ——
    '这一日，',
    '说来也巧，',
    '晌午刚过，',
    '天刚擦黑，',
    '夜色渐深，',
    '第二遍钟响时，',
    '半炷香后，',
    '出事的那天，',
    // —— 场所 / 动作切入 ——
    '门帘一掀，',
    '转过影壁，',
    '人还没坐稳，',
    '出了这道门，',
    '酒过三巡，',
    '看热闹的人还没散，',
    // —— 声音 / 动静先至 ——
    '话音未落，',
    '靴声由远及近，',
    '没人应声，',
    '没人敢先开口，',
    // —— 心理 / 预期 ——
    '谁都没料到，',
    '不出所料，',
    '谁都看得出，',
    '到了这个地步，',
    // —— 承接 / 转折 ——
    '变故来得毫无征兆——',
    '一切要从那件事说起：',
    '事情坏就坏在，',
    '偏巧这时候，',
    '消息比人先到——',
  ];

  // 通用填充词（题材无关的物件/动作/情绪/对话）。
  static const List<String> _objects = <String>[
    '古剑', '玉佩', '残卷', '令牌', '秘境图', '灵草', '铜镜', '油灯',
    '旧信', '怀表', '钥匙', '棋局', '药囊', '骨笛', '星盘',
  ];
  static const List<String> _actions = <String>[
    '缓步前行', '悄然退后', '凝神细看', '低声沉吟', '猛然惊醒', '负手而立',
    '纵身一跃', '垂眸不语', '转身离去', '驻足回望', '握紧双拳', '闭上双眼',
  ];
  static const List<String> _emotions = <String>[
    '心中一紧', '暗自忖度', '不胜唏嘘', '隐隐不安', '豁然开朗', '怅然若失',
    '肃然起敬', '五味杂陈', '如释重负', '波澜暗生',
  ];

  /// 情绪名词池（供 `{emotionN}` 占位符）：只收可作「把…压下去 / 咽了回去」
  /// 宾语的名词性情绪词。旧版复用谓词式情绪词（如「心中一紧」）会产出
  /// 「把心中一紧咽了回去」这类病句。
  static const List<String> _emotionNouns = <String>[
    '杀意', '火气', '悔意', '怯意', '酸楚', '怨气', '惊疑', '戾气',
    '暖意', '杀气', '疑虑', '不甘', '怒火', '委屈', '兴奋', '忌惮',
  ];

  /// 对话内容池：不含引号与人名槽（被称呼者用 {addr}，由引擎按
  /// 「说话人之外的在场者」解析，杜绝「陆沉对陆沉说话」式自指）。
  static const List<String> _dialogues = <String>[
    '「{addr}，你当真要走？」',
    '「此事，绝非表面那般简单。」',
    '「你可知自己惹了多大的麻烦？」',
    '「放心，有我在。」',
    '「若你执意如此，便别怪我不念旧情。」',
    '「有些话，我藏了很久。」',
    '「这世间，值得你守护的，还剩什么？」',
    '「{addr}，你可想清楚了？」',
    '「哼，就凭你？」',
    '「这一次，我不会再让了。」',
    '「账，总要有人来算。」',
    '「你猜，我等这一天多久了？」',
    '「现在回头，还来得及。」',
    '「可惜，世上没有如果。」',
    '「你的胆子，比我想的大。」',
    '「这件事，我记下了。」',
    '「走吧，去看个好戏。」',
    '「你到底想干什么？」',
    '「别逼我动手。」',
    '「三日之内，我要一个答案。」',
    '「你我之间，还没完。」',
    '「话我放这儿，你最好记住。」',
    '「{addr}，你我之间的恩怨，今日一并了断。」',
    '「我劝你三思，这不是你能插手的事。」',
    '「这盘棋下到今天，该到落子的时候了。」',
    '「话已至此，你我从此桥归桥，路归路。」',
    '「要么把东西交出来，要么把命留下。」',
    '「这一局是我输了，我认，愿赌服输。」',
    '「从他踏进这道门起，就没打算活着走出去。」',
    '「你走吧，趁我还没改变主意。」',
    '「记住今天这个日子，也记住你欠我什么。」',
    '「若还有再见之日，我希望你是站着的。」',
    // —— 2026-09 写手优化：扩容 + 口语化/信息增量 ——
    '「这个价钱，我不还价。」',
    '「今晚子时，后山见。」',
    '「我数到三，把手里的东西放下。」',
    '「你这一身伤，怎么来的？」',
    '「这一趟，值了。」',
    '「门外的脚步声，你听见了吗？」',
    '「明人不说暗话，我要见你们主事的人。」',
    '「一半是真，一半是假，你自己品。」',
    '「这么大的事，你怎么不早说？」',
    '「他给的价，我翻倍。」',
    '「这笔账，我替你记着。」',
    '「退一步是海阔天空——可退了，就再没有站回去的机会。」',
    '「{addr}的手艺，我信不过第二个人。」',
    '「我等这一天，等了三年。」',
    // —— 2026-09 写手优化：中长台词（抬高引号内字数占比，逼近番茄 25~45%）——
    '「你进门的时候我就在看了。脚步比上次稳，心态也比上次沉，这不像是来求人的。」',
    '「东西我可以给，但你要想清楚——拿了它，往后就没有回头路了。」',
    '「我不管你和他们之间有过什么。我只认一件事：你答应过的事，什么时候兑现。」',
    '「这世上的便宜没有白占的。你要么现在把话说明白，要么今晚就走。」',
    '「我不问你从哪来，也不问你为什么。你只要告诉我，这趟走完，还会不会回来。」',
    '「他们都以为你死在那一年。我替你把名字从名册上抹了。这笔账，你打算怎么还。」',
    '「天色不早，你再不定主意，门外那些人可就要进来替你定了。」',
    '「我劝你少打听。有些事知道得越多，活着的日子就越短。」',
    // —— 原对白攻防模板的硬编码尾句移入本池轮转（压整句重复率）——
    '别让我说第二遍。',
    '装，接着装。',
    '信我一次。',
    '这话，你留着骗别人吧。',
    '你要是有个三长两短，我怎么交代？',
    '你，听明白了？',
    '你自己掂量吧。',
    '可惜，你猜错了。',
    '再说一遍试试。',
    '我数三声。',
    '东西你收好。',
    '就凭你们？',
  ];

  /// 主角名：优先使用指定名 -> 复用设定首角色 -> 随机姓名。
  String _heroName() {
    if (config.protagonistName != null &&
        config.protagonistName!.isNotEmpty) {
      return config.protagonistName!;
    }
    if (config.useExistingSettings && ctx.characters.isNotEmpty) {
      for (final Character c in ctx.characters) {
        if (c.name.isNotEmpty) return c.name;
      }
    }
    return rng.pick(corpus.namesCorpus.names);
  }

  /// 锚定本章场景：固定地名 / 势力 / 关键物，并从角色池确定对手与盟友。
  ///
  /// 优先复用已有设定中的角色（更贴合用户设定），不足时回退随机姓名；
  /// 对手与盟友保证互不相同，且不与主角重名。
  void _setupChapterScene() {
    _hero = _heroName();
    final List<String> pool = corpus.namesCorpus.names;
    final Set<String> exclude = <String>{_hero};
    final List<String> knownNames = <String>[];
    if (config.useExistingSettings) {
      for (final Character c in ctx.characters) {
        if (c.name.isNotEmpty && c.name != _hero) knownNames.add(c.name);
      }
    }

    String pickDistinct(List<String> preferred) {
      final List<String> usable = preferred
          .where((String n) => !exclude.contains(n))
          .toList();
      final String name =
          usable.isNotEmpty ? rng.pick(usable) : rng.pick(pool);
      exclude.add(name);
      return name;
    }

    _rival = pickDistinct(knownNames);
    _ally = pickDistinct(knownNames);
    _scenePlace = rng.pick(corpus.namesCorpus.places);
    _sceneFaction = rng.pick(corpus.namesCorpus.factions);
    _sceneObject = rng.pick(_objects);
  }

  /// 单句使用的姓名：75% 主角，其余在「对手 / 盟友」之间轮换。
  ///
  /// 配角出场收窄到本章锚定的两个人物：一来视角聚焦不漂移（闸门的
  /// 人名一致性检查看的就是「群演名字太多」），二来对手/盟友反复
  /// 出场才有戏剧张力。
  String _sentenceName() {
    if (rng.chance(0.75)) return _hero;
    return rng.chance(0.5) ? _rival : _ally;
  }

  String _valueFor(String key, Set<String> usedNames) {
    switch (key) {
      case 'name':
        // 第一个 {name} 槽按权重取（75% 主角）；同一模板内出现第二个
        // {name} 时换人，避免「A 塞给 A」式自指。
        if (usedNames.isEmpty) {
          final String first = _sentenceName();
          usedNames.add(first);
          return first;
        }
        final List<String> remaining = <String>[_hero, _rival, _ally]
            .where((String p) => !usedNames.contains(p))
            .toList();
        final String next = remaining.isNotEmpty
            ? rng.pick(remaining)
            : _hero;
        usedNames.add(next);
        return next;
      case 'addr':
        // 被称呼者：优先主角（对手喊主角最常见），排除本句已出现的姓名。
        final List<String> candidates = <String>[_hero, _rival, _ally]
            .where((String n) => !usedNames.contains(n))
            .toList();
        final String addr = candidates.isNotEmpty ? candidates.first : _hero;
        usedNames.add(addr);
        return addr;
      case 'rival':
        return _rival;
      case 'ally':
        return _ally;
      case 'place':
        return _scenePlace;
      case 'faction':
        return _sceneFaction;
      case 'object':
        // 70% 复用本章关键物，强化物件线索的连贯性。
        return rng.chance(0.7) ? _sceneObject : rng.pick(_objects);
      case 'action':
        return rng.pick(_actions);
      case 'emotion':
        return rng.pick(_emotions);
      case 'emotionN':
        return rng.pick(_emotionNouns);
      case 'dialogue':
        // 契约（见 beat_corpus 文档）：{dialogue} 应为「不含引号」的对话内容。
        // 语料 _dialogues 历史上自带「」，直接替换会与句式模板的外层引号
        // 叠成「「…」。」嵌套；这里统一剥掉内层引号与句尾终结标点，
        // 由模板自己决定追加的标点（避免「…？。」「…。。」连标）。
        // 对话内容也走句池去重：同一句台词不在不同句式模板里反复出现，
        // 直接压低整句重复率。被称呼者 {addr} 排除本句已用姓名。
        final String line =
            _pickFromPool('dialogue-content', _dialogues)
                .replaceAll('{addr}', _pickAddr(usedNames));
        return line
            .replaceAll('「', '')
            .replaceAll('」', '')
            .replaceAll(RegExp(r'[。！？…]+$'), '');
      default:
        return '';
    }
  }

  /// 取被称呼者：偏好主角（对手对主角喊话是最常见的对话形态），
  /// 但排除本句已用的姓名，杜绝「说话人喊自己」。
  String _pickAddr(Set<String> usedNames) {
    for (final String candidate in <String>[_hero, _rival, _ally]) {
      if (!usedNames.contains(candidate)) return candidate;
    }
    return _hero;
  }

  /// 修正「说话人自指」：句首主语与对白引号内的人名相同
  /// （「陆沉摇头：『陆沉，你可想清楚了？』」），把引号内的名字换成另一人。
  ///
  /// 只认句首主语形态，避免误伤合法的第三方称呼——例如
  /// 「钟离盯着陆沉看了许久：『陆沉，你当真要走？』」中引号内的
  /// 「陆沉」是对手喊主角，属正常对话，不得替换。
  /// （说话人与被称呼者互斥的主逻辑在 `_fill` 的 usedNames 追踪里，
  /// 本方法是针对句首主语形态的兜底。）
  String _fixSelfAddress(String text) {
    if (!text.contains('「')) return text;
    final RegExp quoteRe = RegExp(r'「([^」]*)」');
    final List<String> cast = <String>[_hero, _rival, _ally];
    return text.replaceAllMapped(quoteRe, (Match m) {
      final String quoted = m.group(1)!;
      // 引号之前的文本（句首主语所在处）。
      final String before = text.substring(0, m.start);
      String inner = quoted;
      for (final String who in cast) {
        if (who.isEmpty || !quoted.contains(who)) continue;
        // 仅当该名出现在引号之前、且是句首主语时才算自指。
        if (!before.contains(who)) continue;
        final int pos = before.indexOf(who);
        if (pos > 2) continue; // 不是句首（前面还有别的字），跳过
        String? other;
        for (final String n in cast) {
          if (n.isNotEmpty && n != who && !quoted.contains(n)) {
            other = n;
            break;
          }
        }
        if (other == null) continue;
        inner = inner.replaceAll(who, other);
      }
      return '「$inner」';
    });
  }

  /// 用语料填充句式模板中的占位符。
  ///
  /// 同一次填充内追踪已用姓名：多个 `{name}` 槽互不重名（修「A 塞给 A」）；
  /// 填充后再跑一遍自指修正（对白内说话人名字 → 换人）。
  String _fill(String template) {
    final Set<String> usedNames = <String>{};
    final String filled = template.replaceAllMapped(RegExp(r'\{(\w+)\}'), (
      Match m,
    ) {
      return _valueFor(m.group(1)!, usedNames);
    });
    return _fixSelfAddress(filled);
  }

  /// 从指定句池取一条模板：优先避开最近使用过的（分池去重窗口）。
  String _pickFromPool(String poolKey, List<String> pool) {
    final List<String> recent =
        _recentByPool.putIfAbsent(poolKey, () => <String>[]);
    final List<String> candidates =
        pool.where((String t) => !recent.contains(t)).toList();
    final String tpl;
    if (candidates.isNotEmpty) {
      tpl = rng.pick(candidates);
    } else {
      // 小池兜底：窗口 ≥ 池大小时候选会被清空，此时至少避开上一条，
      // 保证不相邻重复（整句重复率是番茄闸门的硬指标）。
      final List<String> fallback =
          pool.length > 1 && recent.isNotEmpty
              ? pool.where((String t) => t != recent.last).toList()
              : pool;
      tpl = rng.pick(fallback);
    }
    recent.add(tpl);
    if (recent.length > _poolDedupeWindow) {
      recent.removeRange(0, recent.length - _poolDedupeWindow);
    }
    return tpl;
  }

  /// 取一条通用氛围句（题材句式池，用于细腻文风的穿插调剂）。
  String _pickAmbient() =>
      _pickFromPool('ambient', corpus.sentenceTemplates.templates);

  /// 按阶段加权取一条节拍句（经由句池去重窗口，杜绝短距离重复）。
  ///
  /// 与 [BeatCorpus.pickForStage] 的权重口径一致，但取样走 [_pickFromPool]：
  /// 同一功能句池在去重窗口内不会复用同一模板，从机制上消除
  /// 「相邻段落同句复用」的凑字感。
  String _pickBeat(String stage) {
    final Map<String, int> weights = BeatCorpus.groupsForStage(stage);
    final List<String> bag = <String>[];
    weights.forEach((String group, int w) {
      for (int i = 0; i < w; i++) {
        bag.add(group);
      }
    });
    final String group = bag.isNotEmpty ? rng.pick(bag) : 'development';
    return _pickFromPool('beat:$group', corpus.beatCorpus.groupOf(group));
  }

  /// 把节拍提示织入正文：引导语 + 事件化提示 + 一条匹配阶段的功能句。
  /// 仅用于**用户自写的大纲要点**（点题句有真实信息量）。
  String _weaveHint(String hint, String stage) {
    final String lead = _pickFromPool('leadin', _hintLeadIns);
    return '$lead$hint。${_nextBeatSentence(stage)}';
  }

  /// 阶段驱动的点题句：引导语 + 一条匹配阶段的功能句。
  ///
  /// 骨架的节拍描述词（如「遭遇强敌或瓶颈，心境蜕变」）是抽象规划语言，
  /// 原样写进正文会留下明显的模板痕迹（质检器会判「泄漏」），故此处
  /// 只取引导语 + 功能句，不落提示词；提示词仅用于进度展示。
  String _weaveBeat(String stage) {
    // 章首避雷：第一段若以天气词开头会被闸门判「以天气起手」，
    // 此处重选引导语与首句，直到避开（有限次，保底不阻塞）。
    final bool atChapterStart = !_chapterStarted;
    _chapterStarted = true;
    String lead = _pickFromPool('leadin', _hintLeadIns);
    String tail = _nextBeatSentence(stage);
    for (int attempt = 0;
        atChapterStart &&
            attempt < 5 &&
            _weatherOpenRe.hasMatch('$lead$tail');
        attempt++) {
      lead = _pickFromPool('leadin', _hintLeadIns);
      tail = _nextBeatSentence(stage);
    }
    return '$lead$tail';
  }

  /// 承接上文：若配置了 [config.continuation]，先输出过渡段衔接。
  void _writeContinuation(StringBuffer buffer) {
    final String? cont = config.continuation;
    if (cont == null || cont.trim().isEmpty) return;
    // 章首避雷：开头 16 字内出现雨/雪/霜/雾/风会被闸门判「以天气起手」
    // （首屏硬指标）。过渡段紧跟正文第一行，优先选非天气起手的模板。
    // 取样走 [_pickFromPool]：过渡段模板也不得在窗口内复用（旧版裸 rng.pick
    // 会让同一过渡句反复出现在多章开头）。
    String filled = _fill(_pickFromPool('continuation', _continuationOpeners));
    for (int attempt = 0;
        attempt < 5 && _weatherOpenRe.hasMatch(filled);
        attempt++) {
      filled = _fill(_pickFromPool('continuation', _continuationOpeners));
    }
    _emitted.add(filled);
    buffer.write(filled);
    buffer.writeln();
    buffer.writeln();
  }

  /// 写一个「节拍段」：点题句（织入提示）+ 若干阶段加权节拍句。
  ///
  /// 返回更新后的字数；过程中回报进度、响应取消、让出事件循环。
  /// 「转」阶段句数更少更紧凑，营造短促张力；段落间以双换行分段。
  Future<int> _writeStageParagraph({
    required String stage,
    required String hint,
    required StringBuffer buffer,
    required int current,
    required SendPort resultPort,
    required bool Function() isCancelled,
    required int target,
  }) async {
    resultPort.send(GenerationProgress(
      charsWritten: current,
      targetWords: target,
      stage: '$stage：$hint',
    ));

    // 点题句：阶段驱动的引导句（骨架提示词只进进度展示，不进正文）。
    buffer.write(_weaveBeat(stage));
    current = AppConstants.countWords(buffer.toString());
    if (current >= target || isCancelled()) return current;

    // 首屏保底（番茄硬指标）：首段必须同时具备①冲突信号②对白，且必须
    // 落在闸门判定的前 300 字内。续写章的过渡段会占掉一部分字窗口，
    // 因此紧跟在点题句之后写入，而不是等到段尾再补（旧版段尾补，实测
    // 常把冲突信号挤出 300 字窗口，被判「无冲突信号」）。
    if (_paragraphsWritten == 0) {
      buffer.write(_nextBeatSentence('转', forceTension: true));
      buffer.write(_nextBeatSentence('承', forceDialogue: true));
      current = AppConstants.countWords(buffer.toString());
      if (current >= target || isCancelled()) return current;
    }
    await Future<dynamic>.delayed(Duration.zero);

    // 节拍句：按阶段加权取样叙事功能句组。
    final int sentences = switch (stage) {
      '转' => rng.range(2, 4),
      '合' => rng.range(3, 5),
      _ => rng.range(3, 6),
    };
    for (int i = 0; i < sentences; i++) {
      if (isCancelled()) return current;
      // 对白占比保底：低于 1/3 时本句强制取对白攻防模板，
      // 使章内对白占比稳定落在番茄达标区间（避免运气差掉到 17%）。
      buffer.write(_nextBeatSentence(stage, forceDialogue: _needsDialogue));
      _chapterStarted = true;
      current = AppConstants.countWords(buffer.toString());
      resultPort.send(GenerationProgress(
        charsWritten: current,
        targetWords: target,
        stage: stage,
      ));
      if (current >= target) return current;
      // 让出事件循环，使取消信号得以被处理。
      await Future<dynamic>.delayed(Duration.zero);
    }

    _paragraphsWritten++;
    buffer
      ..writeln()
      ..writeln();
    return AppConstants.countWords(buffer.toString());
  }

  /// 大纲驱动的生成：按大纲要点逐点推进，骨架提供章法节奏。
  ///
  /// 策略：每个要点先事件化为叙事句（不再是「第 N 点」式罗列），
  /// 再补充 2~4 条与该要点阶段匹配的功能句展开；段落间双换行分段。
  Future<int> _writeOutlineDriven(
    List<PlotBeat> beats,
    List<String> outlinePoints,
    StringBuffer buffer,
    int current,
    SendPort resultPort,
    bool Function() isCancelled,
    int target,
  ) async {
    final List<PlotBeat> usableBeats =
        beats.isNotEmpty ? beats : <PlotBeat>[const PlotBeat('起', '推进剧情')];
    int beatIndex = 0;

    for (int p = 0; p < outlinePoints.length; p++) {
      if (isCancelled()) return current;
      if (current >= target) break;
      final String point = outlinePoints[p];

      final PlotBeat beat =
          usableBeats[beatIndex % usableBeats.length];
      beatIndex++;
      resultPort.send(GenerationProgress(
        charsWritten: current,
        targetWords: target,
        stage: '大纲 ${p + 1}/${outlinePoints.length}：${beat.stage}',
      ));

      // 事件句：把要点改写为正文叙事。
      buffer.write(_weaveHint(point, beat.stage));
      current = AppConstants.countWords(buffer.toString());
      resultPort.send(GenerationProgress(
        charsWritten: current,
        targetWords: target,
        stage: beat.stage,
      ));
      if (current >= target) break;

      // 首屏保底（番茄硬指标）：首段必须同时具备①冲突信号②对白，
    // 且落在前 300 字内。续写章的过渡段占掉部分字窗口，故紧跟在
    // 点题句之后写入。与 _writeStageParagraph 同口径。
    if (_paragraphsWritten == 0) {
      buffer.write(_nextBeatSentence('转', forceTension: true));
      buffer.write(_nextBeatSentence('承', forceDialogue: true));
      current = AppConstants.countWords(buffer.toString());
      if (current >= target) break;
    }

    // 展开：与该要点阶段匹配的节拍句。
      final int extra = rng.range(2, 5);
      for (int i = 0; i < extra; i++) {
        if (isCancelled()) return current;
        // 对白占比保底（与 _writeStageParagraph 同口径）。
        buffer.write(_nextBeatSentence(beat.stage, forceDialogue: _needsDialogue));
        _chapterStarted = true;
        current = AppConstants.countWords(buffer.toString());
        resultPort.send(GenerationProgress(
          charsWritten: current,
          targetWords: target,
          stage: beat.stage,
        ));
        if (current >= target) break;
        await Future<dynamic>.delayed(Duration.zero);
      }

      _paragraphsWritten++;
      buffer
        ..writeln()
        ..writeln();
      current = AppConstants.countWords(buffer.toString());
      await Future<dynamic>.delayed(Duration.zero);
    }
    return current;
  }

  /// 执行生成：章节场景锚定 + 情节骨架节拍驱动，循环逼近目标字数。
  ///
  /// 策略：
  /// 1. 锚定本章场景（地名 / 势力 / 关键物 / 对手 / 盟友）；
  /// 2. 首轮选一个完整骨架（起承转合）逐节拍生成段落；
  /// 3. 续写轮循环拼接骨架的 `承`/`转` 发展段；细腻文风穿插氛围句段；
  /// 4. 收尾补一个骨架的 `合` 节拍作收束，并以章末钩子悬念句点睛。
  /// 全程保留取消检查、进度回报、可复现（种子化 rng 顺序推进）与段落分段。
  Future<GenerationResult> run(
    SendPort resultPort,
    bool Function() isCancelled,
  ) async {
    final int target =
        config.targetWords.clamp(200, _controller.maxWords);
    final List<List<PlotBeat>> skeletons = corpus.plotSkeleton.skeletons;

    // 锚定整章场景与人物，保证叙事一致性。
    _setupChapterScene();

    // 跨章查重种子：把上一章结尾（continuation，通常 300 字）的句子
    // 预置进已用句集合。番茄闸门会量「与上一章 8-gram 重合率」，
    // 而语料是共享句池——不预置种子时，同一批固定句会在相邻两章各出现
    // 一次，直接把重合率推到 8%~10%。预置后这些句子在本章会被重选绕开。
    _seedEmittedFromContinuation();

    final StringBuffer buffer = StringBuffer();
    int current = 0;

    // 承接上文：若配置了 continuation，先输出过渡段衔接（不计入骨架）。
    _writeContinuation(buffer);
    current = AppConstants.countWords(buffer.toString());

    // 大纲要点：按行拆分，非空行即一个要点（每行一个）。
    final List<String> outlinePoints = ctx.outline
        .split('\n')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();

    // 首轮：选一个完整骨架（起承转合），逐节拍生成段落。
    final List<PlotBeat> firstSkeleton = rng.pick(skeletons);
    if (outlinePoints.isNotEmpty) {
      current = await _writeOutlineDriven(
        firstSkeleton,
        outlinePoints,
        buffer,
        current,
        resultPort,
        isCancelled,
        target,
      );
    } else {
      for (final PlotBeat beat in firstSkeleton) {
        if (current >= target || isCancelled()) break;
        current = await _writeStageParagraph(
          stage: beat.stage,
          hint: beat.hint,
          buffer: buffer,
          current: current,
          resultPort: resultPort,
          isCancelled: isCancelled,
          target: target,
        );
      }
    }

    // 续写轮：循环拼接骨架的发展段（承/转），逼近目标字数；
    // 细腻文风下按概率穿插一条氛围句段，增强环境与心理质感。
    while (current < target && !isCancelled()) {
      final List<PlotBeat> skeleton = rng.pick(skeletons);
      final List<PlotBeat> devBeats = skeleton
          .where((PlotBeat b) => b.stage == '承' || b.stage == '转')
          .toList();
      // 理论上每个骨架都含承/转，健壮性兜底：若取不到发展段则退出续写。
      if (devBeats.isEmpty) break;
      for (final PlotBeat beat in devBeats) {
        if (current >= target || isCancelled()) break;
        current = await _writeStageParagraph(
          stage: beat.stage,
          hint: beat.hint,
          buffer: buffer,
          current: current,
          resultPort: resultPort,
          isCancelled: isCancelled,
          target: target,
        );
      }
      if (current >= target || isCancelled()) break;
      if (config.style == WritingStyle.detailed && rng.chance(0.5)) {
        // 氛围段也进查重：细腻文风下穿插频繁，旧版不查重会与正文撞句。
        String ambient = _fill(_pickAmbient());
        for (int attempt = 0; attempt < 5 && _emitted.contains(ambient);
            attempt++) {
          ambient = _fill(_pickAmbient());
        }
        _emitted.add(ambient);
        buffer.write(ambient);
        buffer
          ..writeln()
          ..writeln();
        current = AppConstants.countWords(buffer.toString());
      }
    }

    // 收尾：若仍不足且未取消，补一段「合（结局）」作收束。
    if (current < target && !isCancelled()) {
      final List<PlotBeat> skeleton = rng.pick(skeletons);
      final List<PlotBeat> endingBeats =
          skeleton.where((PlotBeat b) => b.stage == '合').toList();
      for (final PlotBeat beat in endingBeats) {
        if (current >= target || isCancelled()) break;
        current = await _writeStageParagraph(
          stage: beat.stage,
          hint: beat.hint,
          buffer: buffer,
          current: current,
          resultPort: resultPort,
          isCancelled: isCancelled,
          target: target,
        );
      }
    }

    // 章末钩子：以悬念句收尾，牵引下一章；仅在字数余量充足时追加。
    // 钩子同样进查重：钩子与正文句子撞车会被闸门算作整句重复。
    if (!isCancelled()) {
      String hook = _fill(corpus.beatCorpus.hook(rng));
      for (int attempt = 0; attempt < 5 && _emitted.contains(hook); attempt++) {
        hook = _fill(corpus.beatCorpus.hook(rng));
      }
      _emitted.add(hook);
      final String merged = '${buffer.toString().trim()}$hook';
      if (AppConstants.countWords(merged) <= target + 60) {
        buffer
          ..write(hook)
          ..writeln();
      }
    }

    final String raw = buffer.toString().trim();
    final String content = _controller.truncate(raw, _controller.maxWords);
    return GenerationResult(
      content: content,
      actualWords: AppConstants.countWords(content),
      usedConfig: config,
    );
  }
}
