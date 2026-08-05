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

/// 模板生成引擎（MVP 默认实现）。
///
/// 在独立 [Isolate] 中运行，保证 UI 不卡顿；支持通过 [CancelToken] 取消，
/// 并回报 [GenerationProgress]。输出为按情节骨架分段、含段落与章法的连贯正文。
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
/// 依据 [CorpusManager] 语料 + 情节骨架 + 可控随机，按节拍生成段落，
/// 约束单章字数 ≤ [GenerationConstraints.maxWordsPerChapter]。
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

  /// 最近使用的模板去重窗口（默认 8），防止短时间内句子重复。
  static const int _dedupeWindow = 8;

  /// 模板使用记录（循环缓冲，仅存模板原文）。
  final List<String> _recentTemplates = <String>[];

  /// 承接上文时拼接的过渡段模板。
  static const List<String> _continuationOpeners = <String>[
    '这一夜，{place}的灯火久久未熄。',
    '翌日清晨，{place}的雾气还未散尽。',
    '时间一点点流逝，{name}的心绪却无法平复。',
    '事情远未结束，{name}知道真正的风暴还在后头。',
    '过了许久，{place}才重新恢复平静。',
    '那一幕过后，{name}久久难以入眠。',
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

  /// 取一条模板：优先避开最近使用过的（去重窗口），窗口满则回退随机。
  String _pickTemplate() {
    final List<String> all = corpus.sentenceTemplates.templates;
    final Set<String> recent = _recentTemplates.toSet();
    final List<String> candidates =
        all.where((String t) => !recent.contains(t)).toList();
    final String tpl;
    if (candidates.isNotEmpty && candidates.length > 1) {
      tpl = rng.pick(candidates);
    } else {
      tpl = rng.pick(all);
    }
    // 维护窗口：追加并裁剪到窗口大小。
    _recentTemplates.add(tpl);
    if (_recentTemplates.length > _dedupeWindow) {
      _recentTemplates.removeRange(0, _recentTemplates.length - _dedupeWindow);
    }
    return tpl;
  }

  /// 承接上文：若配置了 [config.continuation]，先输出过渡段衔接。
  void _writeContinuation(StringBuffer buffer) {
    final String? cont = config.continuation;
    if (cont == null || cont.trim().isEmpty) return;
    // 过渡句：用上一个主角名填充，衔接自然。
    final String tpl = rng.pick(_continuationOpeners);
    final String sentenceName = _heroName();
    buffer.write(_fill(tpl, sentenceName));
    buffer.writeln();
    buffer.writeln();
  }

  /// 单句使用的姓名：70% 主角，否则侧角色/随机名，保持段落内一致。
  String _sentenceName(String heroName) {
    if (ctx.characters.isNotEmpty && rng.chance(0.5)) {
      final Character ch = rng.pick(ctx.characters);
      if (ch.name.isNotEmpty) return ch.name;
    }
    if (rng.chance(0.3)) return rng.pick(corpus.namesCorpus.names);
    return heroName;
  }

  String _valueFor(String key, String sentenceName) {
    switch (key) {
      case 'name':
        return sentenceName;
      case 'place':
        return rng.pick(corpus.namesCorpus.places);
      case 'faction':
        return rng.pick(corpus.namesCorpus.factions);
      case 'object':
        return rng.pick(_objects);
      case 'action':
        return rng.pick(_actions);
      case 'emotion':
        return rng.pick(_emotions);
      case 'dialogue':
        return rng.pick(_dialogues).replaceAll('{name}', sentenceName);
      default:
        return '';
    }
  }

  /// 用语料填充句式模板中的占位符。
  String _fill(String template, String sentenceName) {
    return template.replaceAllMapped(RegExp(r'\{(\w+)\}'), (Match m) {
      return _valueFor(m.group(1)!, sentenceName);
    });
  }

  /// 处理一组节拍：逐节拍生成段落，过程中回报进度、响应取消、让出事件循环。
  ///
  /// [buffer] 与 [current] 为累加状态：[current] 为当前字数，方法返回更新后的字数。
  /// 若 [isCancelled] 或字数已达 [target]，立即停止（仅依赖 rng 序列与字数，
  /// 不引入任何不确定性，保证同配置可复现）。每个节拍段落间以双换行分段。
  Future<int> _writeBeats(
    List<PlotBeat> beats,
    String heroName,
    StringBuffer buffer,
    int current,
    SendPort resultPort,
    bool Function() isCancelled,
    int target,
  ) async {
    for (final PlotBeat beat in beats) {
      if (isCancelled()) return current;
      resultPort.send(GenerationProgress(
        charsWritten: current,
        targetWords: target,
        stage: '${beat.stage}：${beat.hint}',
      ));

      final int sentences = rng.range(2, 5); // 每段 2~4 句
      for (int i = 0; i < sentences; i++) {
        if (isCancelled()) return current;
        final String tpl = _pickTemplate();
        final String sentenceName = _sentenceName(heroName);
        buffer.write(_fill(tpl, sentenceName));
        current = AppConstants.countWords(buffer.toString());
        resultPort.send(GenerationProgress(
          charsWritten: current,
          targetWords: target,
          stage: beat.stage,
        ));
        if (current >= target) return current;
        // 让出事件循环，使取消信号得以被处理。
        await Future<dynamic>.delayed(Duration.zero);
      }

      buffer.writeln();
      buffer.writeln();
      current = AppConstants.countWords(buffer.toString());
      if (current >= target) return current;
      await Future<dynamic>.delayed(Duration.zero);
    }
    return current;
  }

  /// 大纲驱动的生成：按大纲要点逐点推进，骨架仅提供章法节奏。
  ///
  /// 策略：每处理一个要点，先用一个「事件句」点题（第 N 点 + 改写要点），
  /// 再补充 2~3 句常规句式展开；骨架节拍穿插其间保证段落结构。
  Future<int> _writeOutlineDriven(
    List<PlotBeat> beats,
    List<String> outlinePoints,
    String heroName,
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
      final String point = outlinePoints[p];

      // 若当前字数已达目标，提前收束。
      if (current >= target) break;

      // 每段之间插入一个骨架节拍标题（作为进度阶段）。
      final PlotBeat beat =
          usableBeats[beatIndex % usableBeats.length];
      beatIndex++;
      resultPort.send(GenerationProgress(
        charsWritten: current,
        targetWords: target,
        stage: '大纲 ${p + 1}/${outlinePoints.length}：${beat.stage}',
      ));

      // 事件句：把要点改写为正文事件（第 N 点 + 事件化）。
      buffer.write('第${p + 1}点。$point。');
      current = AppConstants.countWords(buffer.toString());
      resultPort.send(GenerationProgress(
        charsWritten: current,
        targetWords: target,
        stage: beat.stage,
      ));
      if (current >= target) break;

      // 补充 2~3 句常规句式展开该要点。
      final int extra = rng.range(2, 4);
      for (int i = 0; i < extra; i++) {
        if (isCancelled()) return current;
        final String tpl = _pickTemplate();
        final String sentenceName = _sentenceName(heroName);
        buffer.write(_fill(tpl, sentenceName));
        current = AppConstants.countWords(buffer.toString());
        resultPort.send(GenerationProgress(
          charsWritten: current,
          targetWords: target,
          stage: beat.stage,
        ));
        if (current >= target) break;
        await Future<dynamic>.delayed(Duration.zero);
      }

      buffer.writeln();
      buffer.writeln();
      current = AppConstants.countWords(buffer.toString());
      await Future<dynamic>.delayed(Duration.zero);
    }
    return current;
  }

  /// 执行生成：按情节骨架分节拍产出段落，循环拼接骨架以逼近目标字数。
  ///
  /// 策略：
  /// 1. 首轮选一个完整骨架（起承转合）逐节拍生成；
  /// 2. 续写轮在 [current] < [target] 且未取消时，循环选取骨架、仅追加其
  ///    `承`/`转` 发展段，避免堆叠多个「合（结局）」导致结构混乱；
  /// 3. 收尾若仍不足，再取一个骨架的 `合` 节拍作收束。
  /// 每句后更新 [current] 并回报进度，达到 [target] 即停止该层循环。
  /// 全程保留取消检查、进度回报、可复现（种子化 rng 顺序推进）与段落分段。
  Future<GenerationResult> run(
    SendPort resultPort,
    bool Function() isCancelled,
  ) async {
    final int target =
        config.targetWords.clamp(200, _controller.maxWords);
    final List<List<PlotBeat>> skeletons = corpus.plotSkeleton.skeletons;
    final String heroName = _heroName();

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

    // 首轮：选一个完整骨架（起承转合），按原逻辑逐节拍生成段落。
    final List<PlotBeat> firstSkeleton = rng.pick(skeletons);
    if (outlinePoints.isNotEmpty) {
      // 有大纲：以「第 N 点」形式把每个要点改写为事件句，穿插在节拍之间。
      current = await _writeOutlineDriven(
        firstSkeleton,
        outlinePoints,
        heroName,
        buffer,
        current,
        resultPort,
        isCancelled,
        target,
      );
    } else {
      current = await _writeBeats(
        firstSkeleton,
        heroName,
        buffer,
        current,
        resultPort,
        isCancelled,
        target,
      );
    }

    // 续写轮：循环拼接骨架的发展段（承/转），逼近目标字数。
    while (current < target && !isCancelled()) {
      final List<PlotBeat> skeleton = rng.pick(skeletons);
      final List<PlotBeat> devBeats = skeleton
          .where((PlotBeat b) => b.stage == '承' || b.stage == '转')
          .toList();
      // 理论上每个骨架都含承/转，健壮性兜底：若取不到发展段则退出续写。
      if (devBeats.isEmpty) break;
      current = await _writeBeats(
        devBeats,
        heroName,
        buffer,
        current,
        resultPort,
        isCancelled,
        target,
      );
    }

    // 收尾：若仍不足且未取消，补一段「合（结局）」作收束。
    if (current < target && !isCancelled()) {
      final List<PlotBeat> skeleton = rng.pick(skeletons);
      final List<PlotBeat> endingBeats =
          skeleton.where((PlotBeat b) => b.stage == '合').toList();
      if (endingBeats.isNotEmpty) {
        current = await _writeBeats(
          endingBeats,
          heroName,
          buffer,
          current,
          resultPort,
          isCancelled,
          target,
        );
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
