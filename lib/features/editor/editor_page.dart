import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/core/utils/text_fmt.dart';
import 'package:novel_writer/features/editor/autosave_mixin.dart';
import 'package:novel_writer/features/editor/chapter_history_dialog.dart';
import 'package:novel_writer/features/editor/editor_ai_mixin.dart';
import 'package:novel_writer/features/editor/editor_pomodoro_mixin.dart';
import 'package:novel_writer/features/editor/editor_search_mixin.dart';
import 'package:novel_writer/features/editor/editor_toolbar.dart';
import 'package:novel_writer/features/editor/sensitive_check_dialog.dart';
import 'package:novel_writer/features/editor/split_chapter_dialog.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/chapter_snapshot.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/services/sensitive_words.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/widgets/app_card.dart';
import 'package:novel_writer/widgets/app_feedback.dart';
import 'package:novel_writer/widgets/common.dart';

/// 中间栏：章节正文编辑器。
///
/// - 通过 [chapterId] 定位章节（父级用 Key 切换时强制重建）。
/// - 输入防抖 3 秒自动保存（[AutosaveMixin]）；
/// - 失焦 / 退出即保存；
/// - 显示「已保存」指示。
///
/// 编辑器的查找替换 / 番茄钟 / AI 动作逻辑分别拆在
/// [EditorSearchMixin] / [EditorPomodoroMixin] / [EditorAiMixin] 中，
/// 本类只保留核心状态与装配。
class EditorPage extends ConsumerStatefulWidget {
  /// 构造编辑器。
  const EditorPage({
    super.key,
    required this.novelId,
    required this.chapterId,
  });

  /// 所属项目。
  final String novelId;

  /// 当前章节 id（为空时显示占位）。
  final String? chapterId;

  @override
  ConsumerState<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends ConsumerState<EditorPage>
    with
        AutosaveMixin,
        EditorSearchMixin<EditorPage>,
        EditorPomodoroMixin<EditorPage>,
        EditorAiMixin<EditorPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Chapter? _chapter;
  Novel? _novel;
  bool _loading = true;
  bool _saved = true;
  SensitiveCheckResult? _check;

  /// 进入本章时的字数（用于统计本次新增）。
  int _initialWords = 0;

  /// 分割阈值：空白段落块小于该字符数时并入上一块。
  static const int _splitMinChars = 150;

  // ---- 写作体验设置 ----
  double _fontSize = 17;
  double _lineHeight = 1.9;

  /// 正文用衬线（宋体）——长篇校对更舒服；关掉即回到黑体，更像纯码字。
  bool _serifBody = true;

  // ---- 敏感词防抖 ----
  Timer? _recheckDebouncer;
  static const Duration _recheckDebounceDelay = Duration(milliseconds: 300);

  // ---- mixin 接口实现 ----
  @override
  TextEditingController get editorController => _controller;

  @override
  Novel? get currentNovel => _novel;

  @override
  Chapter? get currentChapter => _chapter;

  @override
  String get currentText => _controller.text;

  @override
  int get initialWords => _initialWords;

  @override
  void markDirty() {
    if (_saved) setState(() => _saved = false);
  }

  @override
  void onApplyEdit(String newText) {
    scheduleSave(newText);
    markDirty(); // 内部已 setState
    _recheck(newText); // 防抖异步，内部自行 setState
    if (searchOpen && searchCtrl.text.isNotEmpty) {
      doSearch(searchCtrl.text, select: false);
    }
    // 移除冗余 setState(() {})：markDirty 已更新 _saved，_recheck 防抖后由内部触发
  }

  @override
  void initState() {
    super.initState();
    initAutosave((String content) => _persist(content));
    _focusNode.addListener(() {
      // 失焦立即保存；同时刷一下纸面描边（聚焦态）。
      if (!_focusNode.hasFocus) unawaited(flushNow());
      if (mounted) setState(() {});
    });
    _load();
  }

  Future<void> _load() async {
    if (widget.chapterId == null) {
      setState(() {
        _loading = false;
        _chapter = null;
        _controller.text = '';
      });
      return;
    }
    setState(() => _loading = true);
    try {
      _novel = await ref
          .read(novelRepositoryProvider)
          .getNovel(widget.novelId);
      final Chapter ch = await ref
          .read(chapterRepositoryProvider)
          .getChapter(widget.novelId, widget.chapterId!);
      _chapter = ch;
      _controller.text = ch.content;
      _initialWords = AppConstants.countWords(ch.content);
      _saved = true;
      _recheck(ch.content);
    } catch (e) {
      _chapter = null;
      _controller.text = '';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _persist(String content) async {
    if (widget.chapterId == null) return;
    await ref
        .read(chapterRepositoryProvider)
        .updateChapterContent(widget.novelId, widget.chapterId!, content);
    if (mounted) setState(() => _saved = true);
  }

  /// 文本变更时重跑敏感词检测（防抖处理：输入停止 300ms 后才执行）。
  /// 每次新输入取消上一次未执行的检测，避免长文本下每次按键都全量扫描。
  void _recheck(String content) {
    _recheckDebouncer?.cancel();
    _recheckDebouncer = Timer(_recheckDebounceDelay, () {
      if (!mounted) return;
      final SensitiveWordsService svc = ref.read(sensitiveWordsProvider);
      final result = svc.check(content);
      if (mounted) {
        setState(() => _check = result);
      }
    });
  }

  /// 自动章节分割：按空白块拆分成当前章为多章。
  Future<void> _splitChapter() async {
    final String text = _controller.text;
    final List<String> parts = text
        .split(RegExp(r'\n\s*\n'))
        .map((String p) => p.trim())
        .where((String p) => p.isNotEmpty)
        .toList();
    if (parts.length <= 1) {
      AppToast.warn(context, '当前章节没有可分割的空白段落（需要 ≥ 2 个段落块）');
      return;
    }
    final List<String>? finalParts = await showSplitChapterDialog(
      context,
      chapterTitle: _chapter?.title ?? '本章',
      parts: parts,
      minChars: _splitMinChars,
    );
    if (finalParts == null || finalParts.length <= 1) return;

    final String chapterId = widget.chapterId!;
    final ChapterRepository repo = ref.read(chapterRepositoryProvider);
    try {
      await repo.splitChapter(widget.novelId, chapterId, finalParts);
      if (mounted) {
        AppToast.success(context, '✓ 已拆分为 ${finalParts.length} 章');
        // 重新加载当前章节（保留第一块）。
        await _load();
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '分割失败：$e');
      }
    }
  }

  /// 展示敏感词检测详情弹窗。
  Future<void> _showCheckDialog() async {
    final SensitiveCheckResult? r = _check;
    if (r == null) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => SensitiveCheckDialog(
        result: r,
        service: ref.read(sensitiveWordsProvider),
      ),
    );
    // 关闭后重检（可能删了自定义词）。
    _recheck(_controller.text);
  }

  /// 打开历史版本弹窗：恢复选中的快照到编辑器。
  Future<void> _showHistory() async {
    if (widget.chapterId == null) return;
    final ChapterSnapshot? restored = await showChapterHistoryDialog(
      context,
      service: ref.read(chapterSnapshotServiceProvider),
      novelId: widget.novelId,
      chapterId: widget.chapterId!,
    );
    if (restored == null || !mounted) return;
    _controller.text = restored.content;
    _recheck(restored.content);
    await _persist(restored.content);
    if (!mounted) return;
    setState(() => _saved = true);
    AppToast.success(
        context, '已恢复到「${restored.title}」(${restored.content.length} 字)');
  }

  @override
  void dispose() {
    _recheckDebouncer?.cancel();
    disposePomodoro();
    disposeSearch();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  // ---- 字数缓存（避免每次 rebuild 重复计算 O(n)） ----
  int _cachedWordsLength = -1;
  int _cachedWordsResult = 0;

  int get _currentWordCount {
    final int len = _controller.text.length;
    if (len == _cachedWordsLength) return _cachedWordsResult;
    _cachedWordsLength = len;
    _cachedWordsResult = AppConstants.countWords(_controller.text);
    return _cachedWordsResult;
  }

  /// 自然段数（工具栏提示用，空行分隔）。
  int get _paragraphCount {
    final String t = _controller.text;
    if (t.trim().isEmpty) return 0;
    return t
        .split(RegExp(r'\n\s*\n'))
        .where((String p) => p.trim().isNotEmpty)
        .length;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chapterId == null) {
      return const EmptyState(
        icon: Icons.edit_note_rounded,
        message: '从左边挑一章开始写',
        hint: '也可以直接点右上角「一键生成」，让 AI 按章纲先把正文铺出来。',
      );
    }
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }
    final Novel? novel = _novel;
    final int target = novel?.targetWordsPerChapter ?? 0;
    final int words = _currentWordCount;
    final AppInk ink = AppInk.of(context);
    return Column(
      children: <Widget>[
        // 工具栏：RepaintBoundary 隔离，避免编辑器输入触发 Toolbar 重绘
        RepaintBoundary(
        child: EditorToolbar(
          title: _chapter?.title ?? '未命名章节',
          wordCount: words,
          searchOpen: searchOpen,
          fontSize: _fontSize,
          lineHeight: _lineHeight,
          pomodoroRemainNotifier: podomoroRemainNotifier,
          pomodoroRunningNotifier: podomoroRunningNotifier,
          check: _check,
          saved: _saved,
          onToggleSearch: toggleSearch,
          onDecreaseFont: () {
            if (_fontSize <= 10) return;
            setState(() => _fontSize -= 1);
          },
          onIncreaseFont: () {
            if (_fontSize >= 28) return;
            setState(() => _fontSize += 1);
          },
          onCycleLineHeight: () {
            final List<double> opts = <double>[1.4, 1.6, 1.8, 2.0];
            final int idx = opts.indexOf(_lineHeight);
            setState(() => _lineHeight = opts[(idx + 1) % opts.length]);
          },
          onTogglePomodoro: togglePomodoro,
          onShowCheck: _showCheckDialog,
          onShowStats: showStats,
          onSplitChapter: _splitChapter,
          onContinueWrite: continueWrite,
          onRewriteSelected: rewriteSelected,
          onProofread: proofread,
          onSaveDraft: saveDraft,
          onShowHistory: _showHistory,
          serif: _serifBody,
          onToggleSerif: () => setState(() => _serifBody = !_serifBody),
          paragraphCount: _paragraphCount,
        ),
        ),
        // 字数目标进度条（目标来自项目设置， 0 表示未设）。
        if (target > 0) _buildTargetBar(context, words, target),
        if (searchOpen) buildSearchBar(context),
        // 正文编辑区：RepaintBoundary 隔离，toolbar/search 变化不触发 TextField 重绘。
        // 桌面「纸面」布局：正文限宽居中，不随窗口拉成一丈长一行。
        Expanded(
          child: RepaintBoundary(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                final double sheetW = c.maxWidth < AppTokens.maxWidthReading + 48
                    ? c.maxWidth
                    : AppTokens.maxWidthReading + 48;
                return ColoredBox(
                  color: ink.paper,
                  child: Center(
                    child: SizedBox(
                      width: sheetW,
                      height: math.max(120.0, c.maxHeight - 40),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: ink.surface,
                          borderRadius: AppTokens.radiusCard,
                          border: Border.all(
                            color: _focusNode.hasFocus
                                ? ink.primary.withValues(alpha: 0.42)
                                : ink.border,
                            width: _focusNode.hasFocus
                                ? 1.4
                                : AppTokens.cardBorder,
                          ),
                          boxShadow: ink.shadow(),
                        ),
                        child: _buildField(context, ink),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 纸面上的输入框（从 build 里拆出来，方便限定高度与样式）。
  Widget _buildField(BuildContext context, AppInk ink) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            ActivateIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              toggleSearch();
              return null;
            },
          ),
        },
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          cursorColor: ink.accent,
          cursorWidth: 2,
          cursorRadius: const Radius.circular(1),
          decoration: const InputDecoration(
            hintText: '在此书写你的故事……',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.fromLTRB(28, 24, 20, 24),
          ),
          style: AppFonts.text(
            ink.ink,
            size: _fontSize,
            height: _lineHeight,
            serifFace: _serifBody,
          ),
          onChanged: (String value) {
            if (_saved) setState(() => _saved = false);
            _recheck(value);
            // 查找栏打开时实时刷新匹配。
            if (searchOpen && searchCtrl.text.isNotEmpty) {
              doSearch(searchCtrl.text, select: false);
            }
            scheduleSave(value);
          },
        ),
      ),
    );
  }

  /// 字数目标进度条（工具栏下方）。
  Widget _buildTargetBar(BuildContext context, int words, int target) {
    final AppInk ink = AppInk.of(context);
    final double ratio = words / target;
    final bool reached = words >= target;
    final int delta = words - _initialWords;
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppTokens.s4, AppTokens.s2, AppTokens.s4, AppTokens.s2 - 2),
      color: ink.codeTint,
      child: Row(
        children: <Widget>[
          Expanded(
            child: ThinProgress(
              value: ratio,
              color: reached ? ink.success : ink.primary,
            ),
          ),
          const SizedBox(width: AppTokens.s3),
          Text(
            reached
                ? '达标 ${TextFmt.group(words)}/${TextFmt.group(target)}'
                : '${TextFmt.group(words)}/${TextFmt.group(target)} 字',
            style: AppFonts.text(
              reached ? ink.success : ink.inkFaint,
              size: 12,
              height: 1.3,
              monoFace: true,
            ),
          ),
          if (delta > 0) ...<Widget>[
            const SizedBox(width: AppTokens.s2),
            TintBadge('本次 +${TextFmt.group(delta)}',
                dense: true, tone: BadgeTone.success),
          ],
        ],
      ),
    );
  }
}
