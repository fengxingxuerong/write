import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/llm_chat_client.dart';
import 'package:novel_writer/engine/story_memory.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/services/sensitive_words.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/storage/setting_repository.dart';

/// 一键生成视图状态。
class GenerateState {
  /// 是否正在生成。
  final bool isGenerating;

  /// 进度比例 0~1。
  final double progress;

  /// 当前阶段描述。
  final String? stage;

  /// 错误信息（生成失败/取消时填充）。
  final String? error;

  /// 生成完成后的章节（供 UI 打开回显）。
  final Chapter? generatedChapter;

  /// AI 记忆摘要（生成完成后自动提取设定，如“新增 2 个角色，1 条设定”）。
  final String? memoryNote;

  /// AI 记忆是否仍在进行（弹窗需等待其结束再关闭）。
  final bool memoryPending;

  /// 生成中实时正文预览（流式回报；模板引擎为空）。
  final String? previewText;

  /// 构造状态。
  const GenerateState({
    this.isGenerating = false,
    this.progress = 0,
    this.stage,
    this.error,
    this.generatedChapter,
    this.memoryNote,
    this.memoryPending = false,
    this.previewText,
  });

  /// 不可变更新副本。
  GenerateState copyWith({
    bool? isGenerating,
    double? progress,
    String? stage,
    String? error,
    Chapter? generatedChapter,
    bool clearChapter = false,
    String? memoryNote,
    bool? memoryPending,
    String? previewText,
    bool clearPreview = false,
  }) {
    return GenerateState(
      isGenerating: isGenerating ?? this.isGenerating,
      progress: progress ?? this.progress,
      stage: stage ?? this.stage,
      error: error,
      generatedChapter:
          clearChapter ? null : (generatedChapter ?? this.generatedChapter),
      memoryNote: memoryNote,
      memoryPending: memoryPending ?? this.memoryPending,
      previewText: clearPreview ? null : (previewText ?? this.previewText),
    );
  }
}

/// 一键生成视图模型。
///
/// 调用可插拔 [GenerationEngine] 在 Isolate 中生成，回报进度并处理取消，
/// 生成成功后落库到 [ChapterRepository]。按 novelId 区分实例。
class GenerateViewModel extends StateNotifier<GenerateState> {
  /// AI 记忆最长等待时间：超过则后台继续，不阻塞“生成完成”。
  static const Duration kMemoryWait = Duration(seconds: 8);

  /// AI 标题最长等待时间：超过回退原标题，不阻塞落库。
  static const Duration kTitleWait = Duration(seconds: 8);

  /// 构造视图模型。
  GenerateViewModel(
    this._engine,
    this._chapterRepo,
    this._settingRepo,
    this._novelId,
    this._ref,
  ) : super(const GenerateState());

  final GenerationEngine _engine;
  final ChapterRepository _chapterRepo;
  final SettingRepository _settingRepo;
  final String _novelId;
  final Ref _ref;
  final CancelToken _cancelToken = CancelToken();

  /// 提交生成：按 [order] 覆盖或新增章节。
  /// [config.chapterCount] > 1 时多章连写：逐章承接上一章结尾，自动落库。
  Future<void> generate(
    GenerationConfig config,
    ContextBundle ctx,
    int order,
    String chapterTitle,
  ) async {
    state = state.copyWith(
      isGenerating: true,
      progress: 0,
      stage: '准备生成…',
      error: null,
      clearChapter: true,
      memoryPending: false,
      clearPreview: true,
    );
    final int count = config.chapterCount < 1 ? 1 : config.chapterCount;
    final List<String> outlineParts = config.volumeOutline
        .split(RegExp(r'[\r\n]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    try {
      String? continuation = config.continuation;
      for (int i = 0; i < count; i++) {
        // 取消：跳出循环。
        if (_cancelToken.isCancelled) {
          throw const GenerationCancelledException();
        }
        // 从第 2 章起承接上一章结尾。
        final GenerationConfig chapterConfig = config.copyWith(
          continuation: continuation,
        );
        // 卷纲分配：每章取一段（均匀切分）。
        String chapterOutline = ctx.outline;
        if (outlineParts.isNotEmpty) {
          final int chunk = (outlineParts.length / count).ceil();
          chapterOutline = outlineParts
              .skip(i * chunk)
              .take(chunk)
              .join('\n');
        }
        final ContextBundle chapterCtx = ctx.copyWith(
          outline: chapterOutline,
        );

        final int thisOrder = order + i;
        final String thisTitle = i == 0 ? chapterTitle : '第$thisOrder章';
        state = state.copyWith(
          stage: count > 1 ? '第 ${i + 1}/$count 章：准备…' : '准备生成…',
        );

        final GenerationResult result = await _engine.generate(
          chapterConfig,
          chapterCtx,
          cancelToken: _cancelToken,
          onProgress: (GenerationProgress p) {
            state = state.copyWith(
              progress: count > 1
                  ? (i + p.progress) / count
                  : p.progress,
              stage: count > 1
                  ? '第 ${i + 1}/$count 章 · ${p.stage}'
                  : p.stage,
              previewText: p.previewText,
            );
          },
        );

        // AI 章节标题：AI 引擎启用时提炼标题（失败/超时回退原标题）。
        String finalTitle = thisTitle;
        final LlmSettingsState llm0 = _ref.read(llmSettingsProvider);
        if (llm0.useLlm && llm0.config.isConfigured) {
          state = state.copyWith(
            stage: count > 1
                ? '第 ${i + 1}/$count 章：提炼标题…'
                : '正在提炼章节标题…',
          );
          final String? aiTitle =
              await _generateTitle(llm0, result.content).timeout(
            kTitleWait,
            onTimeout: () => null,
          );
          if (aiTitle != null && aiTitle.isNotEmpty) {
            finalTitle = '$thisTitle $aiTitle';
          }
        }
        final Chapter chapter = await _chapterRepo.saveGeneratedChapter(
          _novelId,
          thisOrder,
          finalTitle,
          result.content,
        );
        // 后续章节承接本段结尾（取末尾约 300 字，控制上下文长度）。
        final String tail = result.content.trim();
        continuation = tail.length > 300 ? tail.substring(tail.length - 300) : tail;

        // 每章都做内容安全自查（记录最后结果展示）。
        final SensitiveWordsService sensitive = _ref.read(sensitiveWordsProvider);
        final SensitiveCheckResult check = sensitive.check(chapter.content);
        sensitive.recordStats(check);

        // AI 记忆：每章生成后提取设定并落库（多章时逐章积累）。
        final LlmSettingsState llm = _ref.read(llmSettingsProvider);
        String? memoryNote;
        final bool memoryEnabled =
            llm.useLlm && llm.autoMemory && llm.config.isConfigured;
        if (memoryEnabled) {
          state = state.copyWith(
            memoryPending: true,
            stage: count > 1
                ? '第 ${i + 1}/$count 章：记忆角色与设定…'
                : '正在记忆新角色与设定…',
          );
          final String? note = await _runMemory(llm, chapter.content)
              .timeout(kMemoryWait, onTimeout: () {
            // 超时：后台继续跑，UI 不再等待。
            unawaited(_runMemory(llm, chapter.content));
            return null;
          });
          if (note != null && note.isNotEmpty) memoryNote = note;
        }

        // 每章完成时刷新状态：多章时只更新，不结束。
        state = state.copyWith(
          generatedChapter: chapter,
          memoryNote: memoryNote,
          memoryPending: false,
          stage: count > 1
              ? '第 ${i + 1}/$count 章 完成 ✓'
              : (check.clean
                  ? '生成完成'
                  : '生成完成（检测到 ${check.count} 处敏感词，建议检查）'),
          progress: count > 1 ? (i + 1) / count : 1,
        );
        if (count > 1 && i < count - 1) {
          // 多章间隙：短暂停留让用户看到完成状态。
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
      // 全部完成（单章时也走到这）。
      state = state.copyWith(
        isGenerating: false,
        progress: 1,
        stage: count > 1 ? '全部 $count 章生成完成' : state.stage,
      );
    } on GenerationCancelledException {
      state = state.copyWith(
        isGenerating: false,
        progress: 0,
        error: count > 1 ? '已取消生成（已完成的章节已保存）' : '已取消生成',
        stage: null,
      );
    } on AppException catch (e) {
      state = state.copyWith(isGenerating: false, error: e.message);
    } catch (e) {
      state = state.copyWith(isGenerating: false, error: '生成出错：$e');
    }
  }

  /// 请求取消（终止 Isolate 并丢弃中间结果）。
  void cancel() {
    _cancelToken.cancel();
    state = state.copyWith(stage: '正在取消…');
  }

  /// 重置状态（弹窗重新打开时清除上次生成结果，避免误触关闭）。
  void reset() => state = const GenerateState();

  /// 用 AI 根据正文提炼章节标题（不带“第 N 章”前缀，由调用方拼接）。
  /// 失败或输出不合规返回 null，调用方回退原标题。
  Future<String?> _generateTitle(LlmSettingsState llm, String content) async {
    try {
      final LlmChatClient client = LlmChatClient(config: llm.config);
      final LlmChatResult res = await client.chat(
        '你是一位小说章节标题编辑。根据正文提炼一个吸引人、有文采的章节标题。',
        '正文节选如下（只读前 600 字，不必读完全文）：\n\n'
        '${content.length > 600 ? content.substring(0, 600) : content}\n\n'
        '要求：\n'
        '- 只输出标题本身，不要引号、不要“第 N 章”前缀、不要解释；\n'
        '- 8~15 个汉字，风格贴合正文（热血/悬疑/言情等）；\n'
        '- 可用“·”分隔短句，如“惊鸿一剑·断崖之约”。',
      );
      final String raw = res.content.trim();
      if (raw.isEmpty || raw.length > 40) return null;
      // 去掉可能的多余符号/前缀。
      return raw
          .replaceAll(RegExp("^[「\"“']+"), '')
          .replaceAll(RegExp("[」\"”']+\$"), '')
          .trim();
    } catch (_) {
      return null;
    }
  }

  /// 后台运行 AI 记忆提取（失败静默，不影响主流程）。
  /// 返回记忆摘要文本（如“新增 2 个角色，1 条设定”）；无写入或失败返回 null。
  Future<String?> _runMemory(LlmSettingsState llm, String content) async {
    try {
      final Novel novel = await _settingRepo.db.readNovel(_novelId);
      final StoryMemory memory =
          StoryMemory(config: llm.config, settingRepo: _settingRepo);
      final MemoryWriteSummary summary =
          await memory.extractAndMerge(novel, content);
      if (summary.any) return 'AI 已记忆：${summary.describe}';
    } catch (_) {
      // 记忆失败不影响生成结果。
    }
    return null;
  }
}
