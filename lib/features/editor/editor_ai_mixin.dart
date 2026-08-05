import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/features/editor/continue_write_dialog.dart';
import 'package:novel_writer/features/editor/proofread_dialog.dart';
import 'package:novel_writer/features/editor/rewrite_dialog.dart';
import 'package:novel_writer/features/editor/writing_stats_dialog.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/chapter_repository.dart';

/// 编辑器 AI 相关动作与辅助方法（续写 / 修改 / 校对 / 存稿箱）。
///
/// 混入 [ConsumerState]，提供正文已变化时的统一回调 [onApplyEdit]。
mixin EditorAiMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// 正文输入控制器（宿主提供）。
  TextEditingController get editorController;

  /// 正文已变化时的统一回调（宿主负责保存 + 敏感词复查）。
  void onApplyEdit(String newText);

  /// 正文文本（宿主提供，用于 AI 调用）。
  String get currentText;

  /// 项目（宿主提供，用于获取 genre/tone/characters）。
  Novel? get currentNovel;

  /// 章节（宿主提供，用于标题）。
  Chapter? get currentChapter;

  /// 文本被修改后标记为未保存（宿主提供）。
  void markDirty();

  // ---- AI 辅助方法 ----

  /// 从项目角色中找主角名（role 含"主角/主人公"）。
  String? _protagonistName(Novel? novel) {
    if (novel == null) return null;
    for (final Character c in novel.characters) {
      if (c.role.contains('主角') || c.role.contains('主人公')) {
        return c.name;
      }
    }
    return null;
  }

  // ---- AI 动作 ----

  /// AI 续写：从当前正文末尾续写，流式展示，确认后替换正文。
  Future<void> continueWrite() async {
    final LlmSettingsState llm = ref.read(llmSettingsProvider);
    if (!llm.useLlm || !llm.config.isConfigured) {
      _showSnack('AI 未配置：请先在「设置 → AI 生成设置」中配置本地模型');
      return;
    }
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => ContinueWriteDialog(
        initialText: currentText,
        genre: currentNovel?.genre,
        tone: currentNovel?.tone,
        protagonistName: _protagonistName(currentNovel),
        characters: currentNovel?.characters ?? const <Character>[],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    applyAiResult(result);
  }

  /// AI 修改选中内容：弹出意见输入框，流式重写，确认后替换选中区域。
  Future<void> rewriteSelected() async {
    final TextSelection sel = editorController.selection;
    final bool hasSelection = sel.isValid && !sel.isCollapsed;
    if (!hasSelection) {
      _showSnack('请先在正文中选中要修改的内容');
      return;
    }
    final LlmSettingsState llm = ref.read(llmSettingsProvider);
    if (!llm.useLlm || !llm.config.isConfigured) {
      _showSnack('AI 未配置：请先在「设置 → AI 生成设置」中配置本地模型');
      return;
    }
    final String selectedText = currentText.substring(sel.start, sel.end);
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => RewriteDialog(
        selectedText: selectedText,
        genre: currentNovel?.genre,
        tone: currentNovel?.tone,
        protagonistName: _protagonistName(currentNovel),
        characters: currentNovel?.characters ?? const <Character>[],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    final TextEditingValue v = editorController.value;
    final String replaced =
        v.text.replaceRange(sel.start, sel.end, result);
    editorController.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: sel.start + result.length),
    );
    markDirty();
    onApplyEdit(replaced);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✅ 已替换选中内容（${AppConstants.countWords(result)} 字）'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 全文 AI 校对：检查错别字/病句，逐条勾选应用修正。
  Future<void> proofread() async {
    if (AppConstants.countWords(currentText) < 50) {
      _showSnack('正文太短（不足 50 字），暂不需要校对');
      return;
    }
    final LlmSettingsState llm = ref.read(llmSettingsProvider);
    if (!llm.useLlm || !llm.config.isConfigured) {
      _showSnack('AI 未配置：请先在「设置 → AI 生成设置」中配置本地模型');
      return;
    }
    final ProofreadDialogResult? result = await showProofreadDialog(
      context,
      text: currentText,
      genre: currentNovel?.genre,
      tone: currentNovel?.tone,
      protagonistName: _protagonistName(currentNovel),
      characters: currentNovel?.characters ?? const <Character>[],
    );
    if (result == null || !mounted) return;
    if (result.appliedCount == 0) return;
    applyAiResult(result.revised);
  }

  /// 把当前正文存入存稿箱（不落正式章节）。
  Future<void> saveDraft() async {
    final String text = currentText.trim();
    if (text.isEmpty) {
      _showSnack('正文为空，无法存入存稿箱');
      return;
    }
    final Novel? novel = currentNovel;
    if (novel == null) return;
    final String? title = await _askDraftTitle();
    if (title == null || !mounted) return;
    try {
      final ChapterRepository repo = ref.read(chapterRepositoryProvider);
      await repo.addDraft(novel.id, title: title, content: text);
      if (!mounted) return;
      _showSnack('✅ 已存入存稿箱');
    } catch (e) {
      if (!mounted) return;
      _showSnack('存入失败：$e');
    }
  }

  /// 打开写作统计弹窗。
  Future<void> showStats() async {
    final WritingStats stats = computeWritingStats(
      currentText,
      initialWords: initialWords,
    );
    final int target = currentNovel?.targetWordsPerChapter ?? 0;
    showWritingStatsDialog(context, stats: stats, targetWords: target);
  }

  /// 进入本章时的字数（宿主提供，用于统计本次新增）。
  int get initialWords;

  /// 询问存稿标题（默认「草稿 时间戳」）。
  Future<String?> _askDraftTitle() async {
    final TextEditingController ctrl = TextEditingController(
      text: '草稿 ${DateTime.now().toString().substring(5, 16)}',
    );
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('存入存稿箱'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: '草稿标题',
            hintText: '给这份草稿起个名字',
          ),
          autofocus: true,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('存入'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  /// 应用 AI 结果到编辑器：替换正文 + 触发统一回调。
  void applyAiResult(String result) {
    editorController.value = TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: result.length),
    );
    markDirty();
    onApplyEdit(result);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✅ 已应用（${AppConstants.countWords(result)} 字）'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
