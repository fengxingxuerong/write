import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/features/generate/generate_viewmodel.dart';
import 'package:novel_writer/features/workspace/llm_settings_dialog.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/novel_repository.dart';

/// 打开一键生成弹窗。
///
/// [onGenerated] 在生成成功并落库后回调（返回新建/覆盖的章节）。
Future<void> showGenerateDialog(
  BuildContext context,
  Novel novel,
  void Function(Chapter) onGenerated,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) => GenerateDialog(novel: novel, onGenerated: onGenerated),
  );
}

/// 一键生成弹窗：选题材 / 基调 / 目标字数 / 随机度 / 主角名，并显示进度与取消。
class GenerateDialog extends ConsumerStatefulWidget {
  /// 构造弹窗。
  const GenerateDialog({
    super.key,
    required this.novel,
    required this.onGenerated,
  });

  /// 当前项目（提供角色 / 世界观）。
  final Novel novel;

  /// 生成完成回调。
  final void Function(Chapter) onGenerated;

  @override
  ConsumerState<GenerateDialog> createState() => _GenerateDialogState();
}

class _GenerateDialogState extends ConsumerState<GenerateDialog> {
  late String _genre;
  late String _tone;
  late int _targetWords;
  late double _randomLevel;
  late WritingStyle _style;
  late ProseStyle _proseStyle;
  late bool _useExisting;
  late bool _continueFromLast;
  int _chapterCount = 1;
  final TextEditingController _protagonistCtrl = TextEditingController();
  final TextEditingController _outlineCtrl = TextEditingController();
  final TextEditingController _volumeCtrl = TextEditingController();

  /// 是否用 AI 把大纲扩写成场景序列再生成（默认开启）。
  bool _expandOutline = true;
  bool _popped = false;

  /// 上一章末尾文本（承接上文用），取末 400 字并截断到句号。
  String get _lastChapterContent {
    if (widget.novel.chapters.isEmpty) return '';
    final String content = widget.novel.chapters.last.content;
    final String trimmed = content.trim();
    if (trimmed.isEmpty) return '';
    const int tail = 400;
    final String tailText =
        trimmed.length <= tail ? trimmed : trimmed.substring(trimmed.length - tail);
    // 截断到最近句号，避免半句开头。
    final int dot = tailText.lastIndexOf('。');
    if (dot >= tailText.length - 6) {
      return tailText.substring(0, dot + 1);
    }
    return tailText;
  }

  /// 构建前情提要：最近 2 章的「章名 + 结尾片段」，帮助跨章保持一致。
  String _buildPlotSummary() {
    final List<Chapter> chapters = widget.novel.chapters;
    if (chapters.isEmpty) return '';
    final List<Chapter> recent =
        chapters.length <= 2 ? chapters : chapters.sublist(chapters.length - 2);
    final StringBuffer b = StringBuffer();
    for (final Chapter c in recent) {
      final String body = c.content.trim();
      if (body.isEmpty) continue;
      b.writeln('- ${c.title}：${body.length > 120 ? body.substring(body.length - 120) : body}');
    }
    return b.toString().trim();
  }

  /// 章节标题：续写时沿用「第 N 章」序号逻辑。
  String _chapterTitle(int order) => '第$order章';

  /// 把当前选择的风格/文风保存为项目偏好（fire-and-forget，失败不影响生成）。
  void _persistPreferences() {
    final String style = _style.name;
    final String prose = _proseStyle.name;
    if (style == widget.novel.preferredStyle &&
        prose == widget.novel.preferredProseStyle) {
      return;
    }
    final NovelRepository repo = ref.read(novelRepositoryProvider);
    unawaited(() async {
      try {
        final Novel latest = await repo.getNovel(widget.novel.id);
        await repo.saveNovel(latest.copyWith(
          preferredStyle: style,
          preferredProseStyle: prose,
        ));
      } catch (_) {
        // 偏好保存失败静默，不影响主流程。
      }
    }());
  }

  @override
  void initState() {
    super.initState();
    // 清除上一次生成遗留状态，避免重新打开弹窗时立即误关。
    ref.read(generateViewModelProvider(widget.novel.id).notifier).reset();
    _genre = widget.novel.genre.isNotEmpty
        ? widget.novel.genre
        : GenrePresets.defaultKey;
    _tone = GenrePresets.get(_genre).tones.first;
    _targetWords = AppConstants.defaultMaxWordsPerChapter > 2000
        ? 2000
        : AppConstants.defaultMaxWordsPerChapter;
    _randomLevel = 0.5;
    _style = WritingStyle.values.asNameMap()[widget.novel.preferredStyle] ??
        WritingStyle.standard;
    _proseStyle =
        ProseStyle.values.asNameMap()[widget.novel.preferredProseStyle] ??
            ProseStyle.web;
    _useExisting = true;
    _continueFromLast = widget.novel.chapters.isNotEmpty;
    _chapterCount = 1;
  }

  @override
  void dispose() {
    _protagonistCtrl.dispose();
    _outlineCtrl.dispose();
    _volumeCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final GenerationConfig config = GenerationConfig(
      genre: _genre,
      tone: _tone,
      targetWords: _targetWords,
      useExistingSettings: _useExisting,
      protagonistName: _protagonistCtrl.text.trim().isEmpty
          ? null
          : _protagonistCtrl.text.trim(),
      randomLevel: _randomLevel,
      style: _style,
      proseStyle: _proseStyle,
      // 承接上文：传入上一章末尾（截断至最近句号，避免过长上下文）。
      continuation: _continueFromLast ? _lastChapterContent : null,
      chapterCount: _chapterCount,
      volumeOutline: _chapterCount > 1 ? _volumeCtrl.text.trim() : '',
      expandOutline: _expandOutline &&
          (_outlineCtrl.text.trim().isNotEmpty ||
              (_chapterCount > 1 && _volumeCtrl.text.trim().isNotEmpty)),
      constraints: const GenerationConstraints(
        maxWordsPerChapter: AppConstants.defaultMaxWordsPerChapter,
      ),
    );
    final ContextBundle ctx = ContextBundle(
      characters: widget.novel.characters,
      worldSettings: widget.novel.worldSettings,
      genrePreset: GenrePresets.get(_genre),
      plotSkeleton: PlotSkeleton.forGenre(_genre),
      // 章节大纲：用户填写则按大纲驱动生成。
      outline: _outlineCtrl.text.trim(),
      // 前情提要：最近 2 章剧情摘要，保持伏笔与人物弧光一致。
      plotSummary: _buildPlotSummary(),
    );
    final int order = widget.novel.chapters.length;
    final String title = _chapterTitle(order);
    ref
        .read(generateViewModelProvider(widget.novel.id).notifier)
        .generate(config, ctx, order, title);
  }

  @override
  Widget build(BuildContext context) {
    final GenerateState vm =
        ref.watch(generateViewModelProvider(widget.novel.id));
    final LlmSettingsState llm = ref.watch(llmSettingsProvider);

    // 生成成功 + 记忆完成：回调节并关闭（防重复回调）。
    // memoryPending 期间停留展示“AI 已记忆…”反馈。
    if (vm.generatedChapter != null &&
        !vm.memoryPending &&
        !_popped &&
        mounted) {
      _popped = true;
      // 生成成功：把本次使用的风格/文风回写为项目偏好（下次弹窗自动带出）。
      _persistPreferences();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onGenerated(vm.generatedChapter!);
        if (mounted) Navigator.of(context).pop();
      });
    }

    return AlertDialog(
      title: const Text('一键生成章节'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 引擎状态提示：模板 / AI。
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  llm.useLlm
                      ? '🤖 AI 生成（${llm.config.label}）'
                      : '🧩 模板生成（零网络离线）',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              // AI 引擎启用但未配置/未启动时：警告 + 快捷设置入口。
              if (llm.useLlm && !llm.config.isConfigured) ...<Widget>[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '⚠ AI 尚未配置，请先设置模型与地址',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            showLlmSettingsDialog(context, ref),
                        child: const Text('去设置'),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _genre,
                decoration: const InputDecoration(labelText: '题材'),
                items: GenrePresets.all
                    .map((e) =>
                        DropdownMenuItem(value: e.key, child: Text(e.label)))
                    .toList(),
                onChanged: vm.isGenerating
                    ? null
                    : (v) {
                        if (v == null) return;
                        setState(() {
                          _genre = v;
                          _tone = GenrePresets.get(v).tones.first;
                        });
                      },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _tone,
                decoration: const InputDecoration(labelText: '基调'),
                items: GenrePresets.get(_genre)
                    .tones
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: vm.isGenerating ? null : (v) => setState(() => _tone = v ?? _tone),
              ),
              const SizedBox(height: 12),
              Text('目标字数：$_targetWords'),
              Slider(
                value: _targetWords.toDouble(),
                min: 200,
                max: AppConstants.defaultMaxWordsPerChapter.toDouble(),
                divisions: 99,
                label: '$_targetWords',
                onChanged: vm.isGenerating
                    ? null
                    : (v) => setState(() => _targetWords = v.round()),
              ),
              const SizedBox(height: 6),
              Text('随机度：${(_randomLevel * 100).round()}%'),
              Slider(
                value: _randomLevel,
                min: 0,
                max: 1,
                divisions: 20,
                label: '${(_randomLevel * 100).round()}%',
                onChanged: vm.isGenerating
                    ? null
                    : (v) => setState(() => _randomLevel = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<WritingStyle>(
                initialValue: _style,
                decoration: const InputDecoration(labelText: '写作风格'),
                items: WritingStyle.values
                    .map((e) => DropdownMenuItem(
                        value: e, child: Text(e.label)))
                    .toList(),
                onChanged: vm.isGenerating
                    ? null
                    : (v) => setState(() => _style = v ?? WritingStyle.standard),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ProseStyle>(
                initialValue: _proseStyle,
                decoration: const InputDecoration(labelText: '文风'),
                items: ProseStyle.values
                    .map((e) => DropdownMenuItem(
                        value: e, child: Text(e.label)))
                    .toList(),
                onChanged: vm.isGenerating
                    ? null
                    : (v) => setState(() => _proseStyle = v ?? ProseStyle.web),
              ),
              const SizedBox(height: 6),
              // 连续生成章数：>1 时多章连写，逐章承接。
              DropdownButtonFormField<int>(
                initialValue: _chapterCount,
                decoration: const InputDecoration(labelText: '连续生成章数'),
                items: List<int>.generate(10, (i) => i + 1)
                    .map((e) =>
                        DropdownMenuItem(value: e, child: Text('$e 章')))
                    .toList(),
                onChanged: vm.isGenerating
                    ? null
                    : (v) => setState(() => _chapterCount = v ?? 1),
              ),
              if (_chapterCount > 1) ...<Widget>[
                const SizedBox(height: 8),
                TextField(
                  controller: _volumeCtrl,
                  enabled: !vm.isGenerating,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '卷纲（可选，按顺序分配到各章）',
                    hintText: '每行一个阶段，将按顺序推进到各章。\n例：\n逃离险境，结识同伴\n前往宗门，参加试炼\n揭开身世之谜',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              TextField(
                controller: _protagonistCtrl,
                decoration: const InputDecoration(labelText: '主角名（可选）'),
                enabled: !vm.isGenerating,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('复用已有角色 / 世界观'),
                value: _useExisting,
                onChanged: vm.isGenerating
                    ? null
                    : (v) => setState(() => _useExisting = v),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 4),
              // 承接上文：已有章节时默认开启，显示上一章末尾预览。
              SwitchListTile(
                title: const Text('承接上文（续写剧情）'),
                subtitle: widget.novel.chapters.isEmpty
                    ? const Text('暂无上一章，将生成新故事开头')
                    : Text(
                        '上一章结尾：$_lastChapterContent',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                value: _continueFromLast,
                onChanged: widget.novel.chapters.isEmpty || vm.isGenerating
                    ? null
                    : (v) => setState(() => _continueFromLast = v),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 8),
              // 章节大纲：可选，填写后按大纲要点组织生成。
              TextField(
                controller: _outlineCtrl,
                enabled: !vm.isGenerating,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '章节大纲（可选）',
                  hintText: '每行一个要点，生成将按此推进。\n例：\n主角到达天玄城\n遇到神秘老者\n获得修炼功法',
                  border: OutlineInputBorder(),
                ),
              ),
              // AI 扩写大纲：先把要点扩成场景序列再生成正文，结构更稳。
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('✨ AI 扩写大纲', style: TextStyle(fontSize: 13)),
                subtitle: const Text('把要点扩成场景序列，正文更有层次',
                    style: TextStyle(fontSize: 11)),
                value: _expandOutline,
                onChanged: vm.isGenerating
                    ? null
                    : (v) => setState(() => _expandOutline = v),
              ),
              if (vm.isGenerating) ...<Widget>[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: vm.progress),
                const SizedBox(height: 6),
                Text(vm.stage ?? '生成中…'),
                if (vm.previewText != null &&
                    vm.previewText!.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  // 实时正文预览：AI 流式写入时逐 token 刷新。
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 160),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).dividerColor,
                      ),
                    ),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: Text(
                        vm.previewText!,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.6,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ] else if (vm.memoryPending) ...<Widget>[
                // 正文已生成，AI 正在后台提取角色/设定。
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
                const SizedBox(height: 6),
                const Text('✨ 正文已生成，正在记忆新角色与设定…'),
              ] else if (vm.memoryNote != null) ...<Widget>[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '🧠 ${vm.memoryNote}',
                    style: TextStyle(
                      fontSize: 13,
                      color:
                          Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                if (vm.previewText != null &&
                    vm.previewText!.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    '正文预览（${vm.previewText!.trim().length} 字）：',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 160),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).dividerColor,
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        vm.previewText!,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.6,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ] else if (vm.error != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(vm.error!, style: const TextStyle(color: Colors.red)),
                if (vm.previewText != null &&
                    vm.previewText!.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    '已生成部分（${vm.previewText!.trim().length} 字）：',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 160),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).dividerColor,
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        vm.previewText!,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.6,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        if (vm.isGenerating)
          TextButton(
            onPressed: () =>
                ref.read(generateViewModelProvider(widget.novel.id).notifier).cancel(),
            child: const Text('取消'),
          )
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        if (!vm.isGenerating)
          FilledButton(
            onPressed: _submit,
            child: const Text('开始生成'),
          ),
      ],
    );
  }
}
