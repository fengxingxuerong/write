import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/engine/editor_ai.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/llm_chat_client.dart';
import 'package:novel_writer/engine/llm_engine.dart';
import 'package:novel_writer/engine/multipass/multi_pass_chapter_engine.dart';
import 'package:novel_writer/engine/multipass/scene_builder.dart';
import 'package:novel_writer/engine/quality/fanqie_gate_checker.dart';
import 'package:novel_writer/engine/quality/novel_quality_checker.dart';
import 'package:novel_writer/engine/quality/novel_consistency_checker.dart';
import 'package:novel_writer/engine/story_memory.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/services/sensitive_words.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/storage/setting_repository.dart';

/// 质检润色结果容器：摘要 + 润色后正文。
class QualityCheckResult {
  /// 构造。
  const QualityCheckResult({required this.note, required this.polishedContent});

  /// 空构造（无问题或润色失败）。
  factory QualityCheckResult.empty(String originalContent) {
    return QualityCheckResult(note: null, polishedContent: originalContent);
  }

  /// 质检润色摘要（null 表示跳过质检）。
  final QualityCheckNote? note;

  /// 润色后的正文；未润色时等于原始 content。
  final String polishedContent;

  /// 是否执行了润色。
  bool get polished => note?.polished ?? false;
}

/// 自动质检润色结果摘要。
class QualityCheckNote {
  /// 构造。
  const QualityCheckNote({
    required this.beforeScore,
    required this.afterScore,
    required this.issueCount,
    required this.polished,
  });

  /// 质检评分（润色前）。
  final double beforeScore;

  /// 质检评分（润色后；未润色时等于 beforeScore）。
  final double afterScore;

  /// 检测到的违规数。
  final int issueCount;

  /// 是否执行了 LLM 润色。
  final bool polished;

  /// 人类可读摘要。
  String get summary => polished
      ? '质检 $issueCount 处问题，已自动润色（${beforeScore.toStringAsFixed(0)}→${afterScore.toStringAsFixed(0)}）'
      : '质检通过（评分 ${afterScore.toStringAsFixed(0)}）';
}

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

  /// AI 记忆摘要（生成完成后自动提取设定，如"新增 2 个角色，1 条设定"）。
  final String? memoryNote;

  /// AI 记忆是否仍在进行（弹窗需等待其结束再关闭）。
  final bool memoryPending;

  /// 生成中实时正文预览（流式回报；模板引擎为空）。
  final String? previewText;

  /// 质检润色摘要（生成完成后填充；无问题或未启用时为 null）。
  final QualityCheckNote? qualityNote;

  /// 跨章一致性报告（生成完成后填充；仅 LLM 引擎 + 多章时计算）。
  final ConsistencyReport? consistencyReport;

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
    this.qualityNote,
    this.consistencyReport,
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
    QualityCheckNote? qualityNote,
    bool clearQualityNote = false,
    ConsistencyReport? consistencyReport,
    bool clearConsistencyReport = false,
  }) {
    return GenerateState(
      isGenerating: isGenerating ?? this.isGenerating,
      progress: progress ?? this.progress,
      stage: stage ?? this.stage,
      error: error,
      generatedChapter: clearChapter
          ? null
          : (generatedChapter ?? this.generatedChapter),
      memoryNote: memoryNote,
      memoryPending: memoryPending ?? this.memoryPending,
      previewText: clearPreview ? null : (previewText ?? this.previewText),
      qualityNote: clearQualityNote ? null : (qualityNote ?? this.qualityNote),
      consistencyReport: clearConsistencyReport
          ? null
          : (consistencyReport ?? this.consistencyReport),
    );
  }
}

/// 一键生成视图模型。
///
/// 调用可插拔 [GenerationEngine] 在 Isolate 中生成，回报进度并处理取消，
/// 生成成功后落库到 [ChapterRepository]。按 novelId 区分实例。
class GenerateViewModel extends StateNotifier<GenerateState> {
  /// AI 记忆最长等待时间：超过则后台继续，不阻塞"生成完成"。
  static const Duration kMemoryWait = Duration(seconds: 8);

  /// AI 标题最长等待时间：超过回退原标题，不阻塞落库。
  static const Duration kTitleWait = Duration(seconds: 8);

  /// 质检 LLM 润色最长等待时间：超过则跳过润色，使用原文。
  static const Duration kPolishWait = Duration(seconds: 15);

  /// 前情提要 LLM 提炼最长等待时间：超时回退本地启发式摘要，不阻塞下一章。
  static const Duration kSummaryWait = Duration(seconds: 8);

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

  /// 前情提要有序条目（每章一条，仅保留最近数条以控制 prompt 体积）。
  final List<String> _plotSummaryLines = <String>[];

  /// 多 pass 场景引擎（懒加载；仅 LLM 引擎 + enableMultiPass 时启用）。
  MultiPassChapterEngine? _multiPassEngine;

  /// 拼接后的前情提要文本（多章连写时注入 ContextBundle.plotSummary）。
  String _plotSummary = '';

  /// 提交生成：按 [order] 覆盖或新增章节。
  /// [config.chapterCount] > 1 时多章连写：逐章承接上一章结尾，自动落库。
  Future<void> generate(
    GenerationConfig config,
    ContextBundle ctx,
    int order,
    String chapterTitle,
  ) async {
    // 每次生成都开启新的取消周期，避免上次取消令牌延续到本轮。
    _cancelToken.reset();

    state = state.copyWith(
      isGenerating: true,
      progress: 0,
      stage: '准备生成…',
      error: null,
      clearChapter: true,
      memoryPending: false,
      clearPreview: true,
      clearQualityNote: true,
      clearConsistencyReport: true,
    );
    final int count = config.chapterCount < 1 ? 1 : config.chapterCount;
    // 每次任务清理内部累积，但保留调用方提供的既有剧情。
    // 否则续写已有小说（包括单章生成）会在第一章丢失前情提要。
    _plotSummaryLines.clear();
    _plotSummaryLines.addAll(
      ctx.plotSummary
          .split(RegExp(r'[\r\n]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty),
    );
    if (_plotSummaryLines.length > 3) {
      _plotSummaryLines.removeRange(0, _plotSummaryLines.length - 3);
    }
    _plotSummary = _plotSummaryLines.join('\n');
    final List<String> outlineParts = config.volumeOutline
        .split(RegExp(r'[\r\n]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    try {
      String? continuation = config.continuation;
      // 上一章正文：番茄闸门的跨章 8-gram 重合检查（自我重复）需要它。
      String prevChapterForGate = '';
      for (int i = 0; i < count; i++) {
        // 取消：跳出循环。
        if (_cancelToken.isCancelled) {
          throw const GenerationCancelledException();
        }
        // 从第 2 章起承接上一章结尾。
        final GenerationConfig chapterConfig = config.copyWith(
          continuation: continuation,
        );
        // 卷纲分配：按比例切分到每章，余数分给靠前的章节。
        // 旧实现用 ceil 按固定步长跳取，末章会堆叠剩余全部要点；
        // 均分后各章负担均衡，不会出现「一章吃掉半卷纲」。
        String chapterOutline = ctx.outline;
        if (outlineParts.isNotEmpty) {
          final int base = outlineParts.length ~/ count;
          final int remainder = outlineParts.length % count;
          final int start = i * base + (i < remainder ? i : remainder);
          final int take = base + (i < remainder ? 1 : 0);
          chapterOutline = outlineParts.skip(start).take(take).join('\n');
        }
        final ContextBundle chapterCtx = ctx.copyWith(
          outline: chapterOutline,
          plotSummary: _plotSummary,
        );

        final int thisOrder = order + i;
        final String thisTitle = i == 0 ? chapterTitle : '第$thisOrder章';
        state = state.copyWith(
          stage: count > 1 ? '第 ${i + 1}/$count 章：准备…' : '准备生成…',
        );

        // 多 pass 生成路径：LLM 已配置 + enableMultiPass=true 时，
        // 走 MultiPassChapterEngine（场景拆解 → 逐场景生成 → 拼接）。
        final LlmSettingsState llmSnaphot = _ref.read(llmSettingsProvider);
        final bool useMultiPass =
            chapterConfig.enableMultiPass &&
            llmSnaphot.useLlm &&
            llmSnaphot.config.isConfigured &&
            _engine is LlmEngine;

        final GenerationResult result;
        if (useMultiPass) {
          final MultiPassChapterEngine mpe = _multiPassEngine ??=
              MultiPassChapterEngine(
                config: llmSnaphot.config,
                sceneBuilder: SceneBuilder(config: llmSnaphot.config),
              );
          state = state.copyWith(stage: '规划场景…');
          result = await mpe.generate(
            chapterConfig,
            chapterCtx,
            cancelToken: _cancelToken,
            onProgress: (GenerationProgress p) {
              state = state.copyWith(
                progress: count > 1 ? (i + p.progress) / count : p.progress,
                stage: count > 1 ? '第 ${i + 1}/$count 章 · ${p.stage}' : p.stage,
                previewText: p.previewText,
              );
            },
          );
        } else {
          result = await _engine.generate(
            chapterConfig,
            chapterCtx,
            cancelToken: _cancelToken,
            onProgress: (GenerationProgress p) {
              state = state.copyWith(
                progress: count > 1 ? (i + p.progress) / count : p.progress,
                stage: count > 1 ? '第 ${i + 1}/$count 章 · ${p.stage}' : p.stage,
                previewText: p.previewText,
              );
            },
          );
        }

        // 自动质检 + 润色（仅 LLM 引擎启用时；失败静默，不阻塞主流程）。
        final LlmSettingsState llm0 = _ref.read(llmSettingsProvider);
        String finalContent = result.content;
        QualityCheckNote? qualityNote;
        if (llm0.useLlm && llm0.config.isConfigured) {
          final QualityCheckResult qcResult = await _runQualityCheck(
            llm0,
            finalContent,
            config,
          );
          qualityNote = qcResult.note;
          final QualityCheckNote? note = qcResult.note;
          if (note != null && note.polished) {
            finalContent = qcResult.polishedContent;
            state = state.copyWith(
              stage: count > 1
                  ? '第 ${i + 1}/$count 章：${note.summary}'
                  : note.summary,
            );
          }
        }

        // 番茄过审闸门：首屏/对白/水段/一致性/合规红线。不达标则按评审意见
        // 定点修一轮，重评后分数没升就回滚（宁可不动，不让它越改越差）。
        if (llm0.useLlm && llm0.config.isConfigured) {
          final FanqieGateChecker gate = FanqieGateChecker(
            genre: config.genre,
            protagonist: config.protagonistName ?? '',
            worldTerms: FanqieGateChecker.worldTermsFrom(
              ctx.worldSettings.map((w) => '${w.title} ${w.content}'),
            ),
          );
          final FanqieGateReport before = gate.check(
            finalContent,
            prevContent: prevChapterForGate,
            chapterIndex: i + 1,
          );
          if (!before.pass && before.fixPrompt.isNotEmpty) {
            state = state.copyWith(
              stage: count > 1
                  ? '第 ${i + 1}/$count 章：番茄闸门 ${before.score} 分，定点修…'
                  : '番茄闸门 ${before.score} 分，定点修…',
            );
            try {
              final String fixed = await EditorAi(config: llm0.config)
                  .rewrite(
                    text: finalContent,
                    instruction: before.fixPrompt,
                    genre: config.genre,
                    tone: config.tone,
                    protagonistName: config.protagonistName,
                  )
                  .timeout(kPolishWait, onTimeout: () => finalContent);
              if (fixed.trim().isNotEmpty && fixed != finalContent) {
                final FanqieGateReport after = gate.check(
                  fixed,
                  prevContent: prevChapterForGate,
                  chapterIndex: i + 1,
                );
                if (after.score >= before.score) {
                  finalContent = fixed.trim();
                  state = state.copyWith(
                    stage: '番茄闸门 ${before.score} → ${after.score} 分',
                  );
                }
              }
            } catch (_) {
              // 定点修失败不阻塞生成：保留原文与闸门结论。
            }
          }
        }

        // AI 章节标题：AI 引擎启用时提炼标题（失败/超时回退原标题）。
        String finalTitle = thisTitle;
        if (llm0.useLlm && llm0.config.isConfigured) {
          state = state.copyWith(
            stage: count > 1 ? '第 ${i + 1}/$count 章：提炼标题…' : '正在提炼章节标题…',
          );
          final String? aiTitle = await _generateTitle(
            llm0,
            finalContent,
          ).timeout(kTitleWait, onTimeout: () => null);
          if (aiTitle != null && aiTitle.isNotEmpty) {
            finalTitle = '$thisTitle $aiTitle';
          }
        }
        final Chapter chapter = await _chapterRepo.saveGeneratedChapter(
          _novelId,
          thisOrder,
          finalTitle,
          finalContent,
        );
        // 后续章节承接本段结尾（取末尾约 300 字，控制上下文长度）。
        // 使用 runes 按「字符」截取，避免 UTF-16 码元截断产生乱码。
        final String tail = finalContent.trim();
        continuation = tail.length > 300
            ? tail.characters.skip(tail.length - 300).toString()
            : tail;
        // 为下一章的闸门跨章重合检查留存本章正文。
        prevChapterForGate = finalContent;

        // 前情提要：为下一章积累剧情摘要。LLM 提炼优先（超时/失败回退
        // 本地启发式摘要），仅多章连写的中间章需要（末章无需为下一章准备）。
        if (count > 1 && i < count - 1) {
          state = state.copyWith(
            stage: count > 1 ? '第 ${i + 1}/$count 章：提炼前情提要…' : '提炼前情提要…',
          );
          String? summary;
          if (llm0.useLlm && llm0.config.isConfigured) {
            try {
              summary = await _summarizeChapter(
                llm0,
                finalContent,
              ).timeout(kSummaryWait, onTimeout: () => null);
            } catch (_) {
              summary = null; // 提炼失败不阻塞：走本地兜底。
            }
          }
          _appendPlotSummary(order + i, summary ?? _localSummary(finalContent));
        }

        // 跨章一致性检查（生成完 N 章后，检测 N 章之间的矛盾）。
        // 仅 LLM 引擎 + 写了不止一章时运行；结果写入 state 展示给用户。
        ConsistencyReport? consistencyReport;
        if (llm0.useLlm && llm0.config.isConfigured && count > 1) {
          try {
            final List<Chapter> existing = await _chapterRepo.listChapters(
              _novelId,
            );
            consistencyReport = NovelConsistencyChecker.check(existing);
            if (consistencyReport.hasIssues) {
              state = state.copyWith(
                stage: '跨章检测：发现 ${consistencyReport.totalIssues} 处矛盾',
              );
            }
          } catch (_) {
            // 一致性检查失败不阻塞主流程。
          }
        }

        // 每章都做内容安全自查（记录最后结果展示）。
        final SensitiveWordsService sensitive = _ref.read(
          sensitiveWordsProvider,
        );
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
            stage: count > 1 ? '第 ${i + 1}/$count 章：记忆角色与设定…' : '正在记忆新角色与设定…',
          );
          // 记忆提取只启动一次；超时仅表示「UI 不再等待」，
          // 原任务继续在后台完成。旧实现在 onTimeout 里再次调用
          // _runMemory，会导致同一段正文被提取两次（浪费配额且可能重复入库）。
          final Future<String?> memoryFuture = _runMemory(llm, finalContent);
          String? note;
          try {
            note = await memoryFuture.timeout(kMemoryWait);
          } on TimeoutException {
            // 超时：后台继续跑。
          }
          if (note != null && note.isNotEmpty) memoryNote = note;
          // 多章连写：章节 N 提取的新角色/设定反馈到第 N+1 章的 prompt。
          // 从 DB 重新读取最新 novel，更新 ctx 的角色与世界观列表。
          // readNovel 在文件不存在时抛 StorageException，try-catch 吞掉不影响主流程。
          if (count > 1 && i < count - 1) {
            try {
              final Novel freshNovel = await _chapterRepo.db.readNovel(
                _novelId,
              );
              ctx = ctx.copyWith(
                characters: freshNovel.characters,
                worldSettings: freshNovel.worldSettings,
                // 伏笔账本：把最新（含本章新埋/已回收）的未回收伏笔注入下一章。
                foreshadowing: StoryMemory.buildForeshadowLedger(
                  freshNovel.worldSettings,
                ),
              );
            } catch (_) {
              // 读取失败不中断：沿用旧 ctx 继续生成。
            }
          }
        }

        // 每章完成时刷新状态：多章时只更新，不结束。
        state = state.copyWith(
          generatedChapter: chapter,
          memoryNote: memoryNote,
          memoryPending: false,
          qualityNote: qualityNote,
          consistencyReport: consistencyReport,
          stage: count > 1
              ? '第 ${i + 1}/$count 章 完成 ✓'
              : (check.clean ? '生成完成' : '生成完成（检测到 ${check.count} 处敏感词，建议检查）'),
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

  /// 追加一章的前情提要条目，仅保留最近 3 条（控制注入 prompt 的体积）。
  void _appendPlotSummary(int chapterNo, String summary) {
    final String s = summary.trim();
    if (s.isEmpty) return;
    _plotSummaryLines.add('第$chapterNo章：$s');
    if (_plotSummaryLines.length > 3) {
      _plotSummaryLines.removeRange(0, _plotSummaryLines.length - 3);
    }
    _plotSummary = _plotSummaryLines.join('\n');
  }

  /// 用 LLM 把一章正文提炼成 2~3 句剧情摘要（注入下一章的前情提要）。
  /// 输出不合规（空/过长/含 Markdown）返回 null，调用方回退本地启发式。
  Future<String?> _summarizeChapter(
    LlmSettingsState llm,
    String content,
  ) async {
    try {
      final LlmChatClient client = LlmChatClient(config: llm.config);
      final LlmChatResult res = await client.chat(
        '你是小说剧情记录员。把一章正文压缩成剧情摘要，供后续章节写作时保持连贯。',
        '本章正文如下（只读后半部分即可把握本章进展）：\n\n'
            '${content.length > 4000 ? content.substring(content.length - 4000) : content}\n\n'
            '要求：\n'
            '- 用 2~3 句话概括本章发生的关键事件、人物关系变化与新信息；\n'
            '- 只输出摘要本身，不要标题、序号、引号或任何解释；\n'
            '- 总长不超过 80 字；\n'
            '- 使用第三人称陈述句，不用感叹与抒情。',
      );
      final String raw = res.content.trim().replaceAll(RegExp(r'[\r\n]+'), ' ');
      if (raw.isEmpty || raw.length > 120) return null;
      if (raw.contains('#') || raw.contains('```')) return null;
      return raw;
    } catch (_) {
      return null;
    }
  }

  /// 本地启发式摘要（零成本兜底）：取第一个完整句，截断到 60 字。
  String _localSummary(String content) {
    final String trimmed = content.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (trimmed.isEmpty) return '';
    final RegExpMatch? m = RegExp(r'^(.{4,60}?)[。！？!?]').firstMatch(trimmed);
    if (m != null) return m.group(1)!;
    return trimmed.length > 60
        ? trimmed.characters.take(60).toString()
        : trimmed;
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
            '${content.characters.take(600).toString()}\n\n'
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

  /// 自动质检 + 润色：对正文执行本地算法质检，
  /// 若发现典型 AI 囷痕则调用 LLM 自动润色去 AI 腔。
  ///
  /// 失败/超时静默返回原始评分但不执行润色。
  /// 返回 [QualityCheckResult]：包含 QualityCheckNote 摘要 + 润色后正文。
  /// polished 为 false 时 polishedContent 等于原始 content。
  Future<QualityCheckResult> _runQualityCheck(
    LlmSettingsState llm,
    String content,
    GenerationConfig config,
  ) async {
    try {
      // 本地算法质检
      final QualityReport report = NovelQualityChecker.check(content);
      // 不合格阈值触发 LLM 润色
      if (!report.needsPolish) {
        return QualityCheckResult(
          note: QualityCheckNote(
            beforeScore: report.overallScore,
            afterScore: report.overallScore,
            issueCount: report.hardViolations.length,
            polished: false,
          ),
          polishedContent: content,
        );
      }
      // LLM 润色：需要 LLM 已配置且是 LLM 引擎；模板引擎跳过润色
      if (!llm.useLlm || !llm.config.isConfigured) {
        return QualityCheckResult(
          note: QualityCheckNote(
            beforeScore: report.overallScore,
            afterScore: report.overallScore,
            issueCount: report.hardViolations.length,
            polished: false,
          ),
          polishedContent: content,
        );
      }
      state = state.copyWith(
        stage: '质检到 ${report.hardViolations.length} 处问题，AI 润色中…',
      );
      final EditorAi editor = EditorAi(config: llm.config);
      final String polished = await editor
          .polish(
            text: content,
            qualityReport: report,
            genre: config.genre,
            tone: config.tone,
            protagonistName: config.protagonistName,
          )
          .timeout(kPolishWait, onTimeout: () => content);
      // 二次质检（仅统计评分，不再次触发润色，避免死循环）
      final QualityReport afterReport = NovelQualityChecker.check(polished);
      return QualityCheckResult(
        note: QualityCheckNote(
          beforeScore: report.overallScore,
          afterScore: afterReport.overallScore,
          issueCount: report.hardViolations.length,
          polished: polished != content,
        ),
        polishedContent: polished,
      );
    } catch (_) {
      // 任何失败都不阻塞主流程：跳过质检润色，返回原文
      return QualityCheckResult.empty(content);
    }
  }

  /// 后台运行 AI 记忆提取（失败静默，不影响主流程）。
  /// 返回记忆摘要文本（如"新增 2 个角色，1 条设定"）；无写入或失败返回 null。
  Future<String?> _runMemory(LlmSettingsState llm, String content) async {
    try {
      final Novel novel = await _settingRepo.db.readNovel(_novelId);
      final StoryMemory memory = StoryMemory(
        config: llm.config,
        settingRepo: _settingRepo,
      );
      final MemoryWriteSummary summary = await memory.extractAndMerge(
        novel,
        content,
      );
      if (summary.any) return 'AI 已记忆：${summary.describe}';
    } catch (_) {
      // 记忆失败不影响生成结果。
    }
    return null;
  }
}
