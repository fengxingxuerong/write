import 'dart:async';
import 'dart:isolate';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/constraints/generation_constraints.dart';
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
int _deriveSeed(GenerationConfig config) {
  final int base =
      config.genre.hashCode ^ config.tone.hashCode ^ config.targetWords;
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
  static const int _poolDedupeWindow = 6;

  /// 句池使用记录（按池名分桶的循环缓冲）。
  final Map<String, List<String>> _recentByPool = <String, List<String>>{};

  // ---- 章节级场景状态（整章锚定，保证场景与人物一致） ----

  /// 主角名。
  late String _hero;

  /// 本章对手 / 敌对者。
  late String _rival;

  /// 本章盟友 / 亲近者。
  late String _ally;

  /// 本章主场景地名。
  late String _scenePlace;

  /// 本章关联势力。
  late String _sceneFaction;

  /// 本章关键物件。
  late String _sceneObject;

  /// 可出场的侧角色池（不含主角与对手 / 盟友）。
  List<String> _cast = <String>[];

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
  static const List<String> _hintLeadIns = <String>[
    '这一日，',
    '说来也巧，',
    '谁也没想到，',
    '变故来得毫无征兆——',
    '一切要从那件事说起：',
    '就在众人以为风平浪静时，',
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
  static const List<String> _dialogues = <String>[
    '「{name}，你当真要走？」',
    '「此事，绝非表面那般简单。」',
    '「你可知自己惹了多大的麻烦？」',
    '「放心，有我在。」',
    '「若你执意如此，便别怪我不念旧情。」',
    '「有些话，我藏了很久。」',
    '「这世间，值得你守护的，还剩什么？」',
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
    _cast = pool.where((String n) => !exclude.contains(n)).toList();
    _scenePlace = rng.pick(corpus.namesCorpus.places);
    _sceneFaction = rng.pick(corpus.namesCorpus.factions);
    _sceneObject = rng.pick(_objects);
  }

  /// 单句使用的姓名：70% 主角，否则侧角色，保持叙事焦点稳定。
  String _sentenceName() {
    if (rng.chance(0.7)) return _hero;
    if (_cast.isNotEmpty && rng.chance(0.5)) return rng.pick(_cast);
    return _hero;
  }

  String _valueFor(String key) {
    switch (key) {
      case 'name':
        return _sentenceName();
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
      case 'dialogue':
        return rng.pick(_dialogues).replaceAll('{name}', _sentenceName());
      default:
        return '';
    }
  }

  /// 用语料填充句式模板中的占位符。
  String _fill(String template) {
    return template.replaceAllMapped(RegExp(r'\{(\w+)\}'), (Match m) {
      return _valueFor(m.group(1)!);
    });
  }

  /// 从指定句池取一条模板：优先避开最近使用过的（分池去重窗口）。
  String _pickFromPool(String poolKey, List<String> pool) {
    final List<String> recent =
        _recentByPool.putIfAbsent(poolKey, () => <String>[]);
    final List<String> candidates =
        pool.where((String t) => !recent.contains(t)).toList();
    final String tpl;
    if (candidates.length > 1) {
      tpl = rng.pick(candidates);
    } else {
      tpl = rng.pick(pool);
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

  /// 把节拍提示织入正文：引导语 + 事件化提示 + 一条匹配阶段的功能句。
  String _weaveHint(String hint, String stage) {
    final String lead = rng.pick(_hintLeadIns);
    final String tail =
        _fill(corpus.beatCorpus.pickForStage(stage, rng));
    return '$lead$hint。$tail';
  }

  /// 承接上文：若配置了 [config.continuation]，先输出过渡段衔接。
  void _writeContinuation(StringBuffer buffer) {
    final String? cont = config.continuation;
    if (cont == null || cont.trim().isEmpty) return;
    final String tpl = rng.pick(_continuationOpeners);
    buffer.write(_fill(tpl));
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

    // 点题句：把节拍提示事件化织入叙事。
    buffer.write(_weaveHint(hint, stage));
    current = AppConstants.countWords(buffer.toString());
    if (current >= target || isCancelled()) return current;
    await Future<dynamic>.delayed(Duration.zero);

    // 节拍句：按阶段加权取样叙事功能句组。
    final int sentences = switch (stage) {
      '转' => rng.range(2, 4),
      '合' => rng.range(3, 5),
      _ => rng.range(3, 6),
    };
    for (int i = 0; i < sentences; i++) {
      if (isCancelled()) return current;
      buffer.write(_fill(corpus.beatCorpus.pickForStage(stage, rng)));
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

      // 展开：与该要点阶段匹配的节拍句。
      final int extra = rng.range(2, 5);
      for (int i = 0; i < extra; i++) {
        if (isCancelled()) return current;
        buffer.write(_fill(corpus.beatCorpus.pickForStage(beat.stage, rng)));
        current = AppConstants.countWords(buffer.toString());
        resultPort.send(GenerationProgress(
          charsWritten: current,
          targetWords: target,
          stage: beat.stage,
        ));
        if (current >= target) break;
        await Future<dynamic>.delayed(Duration.zero);
      }

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
        buffer.write(_fill(_pickAmbient()));
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
    if (!isCancelled()) {
      final String hook = _fill(corpus.beatCorpus.hook(rng));
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
