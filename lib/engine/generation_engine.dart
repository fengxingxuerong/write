import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/world_setting.dart';

/// 生成进度（引擎在 Isolate 中周期性回报）。
class GenerationProgress {
  /// 已写入字符数（约当字数）。
  final int charsWritten;

  /// 目标字数。
  final int targetWords;

  /// 当前阶段描述（如「起：引入主角与日常」）。
  final String stage;

  /// 已生成正文预览（流式实时回报；模板引擎可不带）。
  final String? previewText;

  /// 构造进度对象。
  const GenerationProgress({
    required this.charsWritten,
    required this.targetWords,
    required this.stage,
    this.previewText,
  });

  /// 进度比例（0~1）。
  double get progress =>
      targetWords <= 0 ? 0.0 : (charsWritten / targetWords).clamp(0.0, 1.0);
}

/// 生成结果。
class GenerationResult {
  /// 生成的正文内容。
  final String content;

  /// 实际字数（与 [GenerationConfig.targetWords] 接近，且 ≤ 约束上限）。
  final int actualWords;

  /// 实际使用的配置（便于回显/复现）。
  final GenerationConfig usedConfig;

  /// 构造结果对象。
  const GenerationResult({
    required this.content,
    required this.actualWords,
    required this.usedConfig,
  });
}

/// 取消令牌。
///
/// 由 UI / ViewModel 持有，调用 [cancel] 通知引擎终止 Isolate 并丢弃中间结果。
class CancelToken {
  bool _cancelled = false;

  /// 取消回调（由引擎在 [generate] 时注册，用于向 Isolate 发送取消信号）。
  void Function()? onCancel;

  /// 是否已取消。
  bool get isCancelled => _cancelled;

  /// 请求取消。幂等：多次调用仅生效一次。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    onCancel?.call();
  }
}

/// 生成上下文聚合包。
///
/// 由 ViewModel 在调用前聚合：项目已有角色 / 世界观 + 题材预设 + 情节骨架。
/// 引擎**只读不改**；所有数据为可序列化的纯数据，便于跨 Isolate 传递。
class ContextBundle {
  /// 角色列表。
  final List<Character> characters;

  /// 世界观设定列表。
  final List<WorldSetting> worldSettings;

  /// 题材预设。
  final GenrePreset genrePreset;

  /// 情节骨架。
  final PlotSkeleton plotSkeleton;

  /// 当前章节大纲要点（可选，空串表示无大纲）。
  /// 由调用方传入，引擎按要点组织内容。
  final String outline;

  /// 前情提要：最近 2~3 章的剧情摘要（章名 + 结尾片段）。
  /// 生成新章时注入，帮助模型保持跨章人物弧光与伏笔一致。
  final String plotSummary;

  /// 构造上下文包。
  const ContextBundle({
    required this.characters,
    required this.worldSettings,
    required this.genrePreset,
    required this.plotSkeleton,
    this.outline = '',
    this.plotSummary = '',
  });

  /// 不可变更新副本（多章连写时替换大纲用）。
  ContextBundle copyWith({String? outline, String? plotSummary}) {
    return ContextBundle(
      characters: characters,
      worldSettings: worldSettings,
      genrePreset: genrePreset,
      plotSkeleton: plotSkeleton,
      outline: outline ?? this.outline,
      plotSummary: plotSummary ?? this.plotSummary,
    );
  }
}

/// 生成引擎抽象接口（可插拔）。
///
/// 契约：
/// 1. 纯离线，不发起任何网络请求；
/// 2. 可通过 [cancelToken] 取消（实现类应在 Isolate 中监听并在取消时终止）；
/// 3. 返回的 [GenerationResult.content] 字数必须 ≤ [GenerationConfig.constraints.maxWordsPerChapter]；
/// 4. [actualWords] 为真实字数。
///
/// MVP 仅 [TemplateEngine] 实现；未来新增 LocalLlmEngine 只需实现同一接口。
abstract class GenerationEngine {
  /// 生成一章正文。
  ///
  /// - [config]：题材 / 基调 / 目标字数 / 随机度 / 约束。
  /// - [ctx]：聚合的角色 / 世界观 / 题材预设 / 情节骨架。
  /// - [cancelToken]：可选取消令牌。
  /// - [onProgress]：进度回调（UI 显示进度条与阶段）。
  ///
  /// 取消时抛 [GenerationCancelledException]；其它失败抛 [EngineException]。
  Future<GenerationResult> generate(
    GenerationConfig config,
    ContextBundle ctx, {
    CancelToken? cancelToken,
    void Function(GenerationProgress)? onProgress,
  });
}
