import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/core/utils/text_fmt.dart';
import 'package:novel_writer/features/editor/editor_page.dart';
import 'package:novel_writer/features/export/cover_generator.dart';
import 'package:novel_writer/features/export/export_page.dart';
import 'package:novel_writer/features/generate/generate_dialog.dart';
import 'package:novel_writer/features/reader/reader_page.dart';
import 'package:novel_writer/features/workspace/beat_board_dialog.dart';
import 'package:novel_writer/features/workspace/chapter_list_panel.dart';
import 'package:novel_writer/features/workspace/draft_box_dialog.dart';
import 'package:novel_writer/features/workspace/outline_dialog.dart';
import 'package:novel_writer/features/workspace/search_dialog.dart';
import 'package:novel_writer/features/workspace/setting_panel.dart';
import 'package:novel_writer/features/workspace/volume_outline_dialog.dart';
import 'package:novel_writer/features/workspace/world_book_dialog.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/services/search_service.dart';
import 'package:novel_writer/widgets/app_card.dart';
import 'package:novel_writer/widgets/app_feedback.dart';
import 'package:novel_writer/widgets/common.dart';
import 'package:novel_writer/widgets/page_shell.dart';

/// 项目内主界面：可拖三栏（章节 / 编辑器 / 设定），顶部一条工作台标题栏。
///
/// 顶栏原来平铺 12 个图标，密度接近「找不到但也不敢收」的临界点；现在保留
/// 4 个高频动作 + 一个带文字的工具箱菜单，主操作（一键生成）单独成块。
class WorkspacePage extends ConsumerStatefulWidget {
  /// 构造工作区。
  const WorkspacePage({super.key, required this.novelId});

  /// 项目 id。
  final String novelId;

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  Novel? _novel;
  bool _loading = true;
  String? _selectedChapterId;
  bool _focusMode = false;
  int _mobileTab = 1; // 0=章节 1=写作 2=设定

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final Novel novel =
          await ref.read(novelRepositoryProvider).getNovel(widget.novelId);
      // 保持当前选中（若仍存在于列表中）。
      final bool stillThere = _selectedChapterId != null &&
          novel.chapters.any((Chapter c) => c.id == _selectedChapterId);
      if (!mounted) return;
      setState(() {
        _novel = novel;
        _selectedChapterId = stillThere
            ? _selectedChapterId
            : (novel.chapters.isNotEmpty ? novel.chapters.first.id : null);
      });
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, '打开项目失败：$e');
      context.pop();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addChapter() async {
    final Chapter ch = await ref
        .read(chapterRepositoryProvider)
        .addChapter(widget.novelId);
    await _reload();
    if (!mounted) return;
    setState(() => _selectedChapterId = ch.id);
  }

  Future<void> _deleteChapter(String id) async {
    final Novel? novel = _novel;
    Chapter? target;
    for (final Chapter c in novel?.chapters ?? const <Chapter>[]) {
      if (c.id == id) target = c;
    }
    final bool ok = await showConfirmDialog(
      context,
      title: '删除章节',
      content: target == null
          ? '确定删除这一章？正文会一并移除，不可恢复。'
          : '确定删除《${target.title}》？${TextFmt.words(target.wordCount())} 字正文会一并移除，不可恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(chapterRepositoryProvider).deleteChapter(widget.novelId, id);
    if (_selectedChapterId == id) _selectedChapterId = null;
    await _reload();
    if (mounted) AppToast.info(context, '章节已删除');
  }

  Future<void> _editOutline(Chapter chapter) async {
    final String? outline = await showOutlineDialog(
      context,
      chapterTitle: chapter.title,
      initial: chapter.outline,
    );
    if (outline == null) return;
    await ref
        .read(chapterRepositoryProvider)
        .updateChapter(widget.novelId, chapter.copyWith(outline: outline));
    await _reload();
  }

  /// 打开卷纲总览弹窗（全书章节大纲汇总）。
  Future<void> _openVolumeOutline(Novel novel) async {
    Future<void> editAndReopen() async {
      if (!context.mounted) return;
      final Novel? fresh = _novel;
      await showVolumeOutlineDialog(
        context,
        novelTitle: novel.title,
        chapters: fresh?.chapters ?? novel.chapters,
        onEditOutline: (Chapter c) async {
          if (!context.mounted) return;
          Navigator.of(context).pop();
          await _editOutline(c);
          await editAndReopen();
        },
      );
    }

    await showVolumeOutlineDialog(
      context,
      novelTitle: novel.title,
      chapters: novel.chapters,
      onEditOutline: (Chapter ch) async {
        if (!context.mounted) return;
        Navigator.of(context).pop();
        await _editOutline(ch);
        await editAndReopen();
      },
    );
  }

  Future<void> _move(int index, int delta) async {
    final Novel? novel = _novel;
    if (novel == null) return;
    final int target = index + delta;
    if (target < 0 || target >= novel.chapters.length) return;
    final List<String> ordered = novel.chapters.map((Chapter c) => c.id).toList();
    final String tmp = ordered[index];
    ordered[index] = ordered[target];
    ordered[target] = tmp;
    await ref
        .read(chapterRepositoryProvider)
        .reorderChapters(widget.novelId, ordered);
    await _reload();
  }

  /// 拖拽重排章节。
  Future<void> _reorder(int oldIndex, int newIndex) async {
    final Novel? novel = _novel;
    if (novel == null) return;
    final List<String> ordered = novel.chapters.map((Chapter c) => c.id).toList();
    if (oldIndex < 0 || oldIndex >= ordered.length) return;
    final String moved = ordered.removeAt(oldIndex);
    if (newIndex < 0) newIndex = 0;
    if (newIndex > ordered.length) newIndex = ordered.length;
    ordered.insert(newIndex, moved);
    await ref
        .read(chapterRepositoryProvider)
        .reorderChapters(widget.novelId, ordered);
    await _reload();
  }

  void _toggleFocus() {
    setState(() => _focusMode = !_focusMode);
    AppToast.info(
      context,
      _focusMode ? '专注模式：已收起左右栏（F11 退出）' : '已恢复三栏',
      duration: const Duration(milliseconds: 1200),
    );
  }

  /// 键位速查：应用内唯一可查的快捷键入口（Ctrl+/ 与应用内入口共用）。
  void _showShortcuts() {
    const List<(String, String)> items = <(String, String)>[
      ('Ctrl+S', '保存全部章节'),
      ('Ctrl+B', '一键生成续写'),
      ('Ctrl+E', '导出当前小说'),
      ('F11', '专注模式：收起左右栏'),
      ('Ctrl+/', '本键位速查'),
    ];
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('快捷键'),
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 32, 8),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final (String keys, String desc) in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppInk.of(ctx).inkSoft.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          keys,
                          style: AppFonts.text(
                            AppInk.of(ctx).ink,
                            size: 12,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          desc,
                          style: AppFonts.text(AppInk.of(ctx).inkSoft, size: 13),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _openGenerate() async {
    final Novel? novel = _novel;
    if (novel == null) return;
    await showGenerateDialog(
      context,
      novel,
      (Chapter ch) {
        _reload();
        if (!mounted) return;
        setState(() => _selectedChapterId = ch.id);
      },
    );
  }

  Chapter? get _selectedChapter {
    final Novel? novel = _novel;
    if (novel == null || _selectedChapterId == null) return null;
    for (final Chapter c in novel.chapters) {
      if (c.id == _selectedChapterId) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
              SizedBox(height: AppTokens.s3),
              Text('正在打开作品…', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );
    }
    final Novel? novel = _novel;
    if (novel == null) {
      return Scaffold(
        body: Center(
          child: EmptyState(
            icon: Icons.folder_off_outlined,
            message: '项目不存在',
            hint: '它可能已被删除，或数据目录被移动过。',
            actionLabel: '返回书架',
            onAction: () => context.pop(),
          ),
        ),
      );
    }

    return Scaffold(
      body: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              _saveAll,
          const SingleActivator(LogicalKeyboardKey.keyB, control: true):
              _openGenerate,
          const SingleActivator(LogicalKeyboardKey.keyE, control: true): () {
            final Novel? n = _novel;
            if (n != null) showExportDialog(context, n);
          },
          const SingleActivator(LogicalKeyboardKey.f11): _toggleFocus,
          // Ctrl+/：键位速查（此前快捷键只存在于代码与 README，应用内无处可查）。
          const SingleActivator(LogicalKeyboardKey.slash, control: true):
              _showShortcuts,
        },
        child: Column(
          children: <Widget>[
            _WorkspaceHeader(
              novel: novel,
              chapter: _selectedChapter,
              focusMode: _focusMode,
              onSearch: () => showDialog<void>(
                context: context,
                builder: (BuildContext ctx) => SearchDialog(
                  novel: novel,
                  onSelect: (SearchHit hit) {
                    final Chapter? chapter = hit.chapter;
                    if (chapter != null) {
                      setState(() => _selectedChapterId = chapter.id);
                    } else {
                      WorldBookDialog.show(context, novel);
                    }
                  },
                ),
              ),
              onToggleFocus: _toggleFocus,
              onRead: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ReaderPage(novel: novel),
                ),
              ),
              onWorldBook: () => WorldBookDialog.show(context, novel),
              onDraftBox: () => showDraftBoxDialog(context, novel),
              onVolumeOutline: () => _openVolumeOutline(novel),
              onBeatBoard: _selectedChapter == null
                  ? null
                  : () => BeatBoardDialog.show(context, novel, _selectedChapter!),
              onCover: () =>
                  CoverGenerator.showCoverPreview(context, novel),
              onExport: () => showExportDialog(context, novel),
              onGenerate: _openGenerate,
              onShortcuts: _showShortcuts,
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  if (constraints.maxWidth < 900) {
                    return _buildMobileBody(novel);
                  }
                  return _buildDesktopBody(novel);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _saveAll() {
    if (_selectedChapterId == null) {
      AppToast.info(context, '先选一章再保存');
      return;
    }
    AppToast.success(context, '已保存（自动保存已开启）',
        duration: const Duration(milliseconds: 1100));
  }

  /// 桌面端三栏（可拖宽）。
  Widget _buildDesktopBody(Novel novel) {
    return ResizablePanes(
      left: ChapterListPanel(
        chapters: novel.chapters,
        selectedChapterId: _selectedChapterId,
        onSelect: (String id) => setState(() => _selectedChapterId = id),
        onAdd: _addChapter,
        onDelete: _deleteChapter,
        onMoveUp: (int i) => _move(i, -1),
        onMoveDown: (int i) => _move(i, 1),
        onEditOutline: _editOutline,
        onReorder: _reorder,
        targetWordsPerChapter: novel.targetWordsPerChapter,
      ),
      center: EditorPage(
        key: ValueKey<String?>(_selectedChapterId),
        novelId: widget.novelId,
        chapterId: _selectedChapterId,
      ),
      right: _focusMode
          ? null
          : ColoredBox(
              color: AppInk.of(context).surface,
              child: SettingPanel(novel: novel, onChanged: _reload),
            ),
    );
  }

  /// 窄屏单栏：底部导航在「章节 / 写作 / 设定」间切换。
  Widget _buildMobileBody(Novel novel) {
    return Column(
      children: <Widget>[
        Expanded(
          child: switch (_mobileTab) {
            0 => ChapterListPanel(
                chapters: novel.chapters,
                selectedChapterId: _selectedChapterId,
                onSelect: (String id) {
                  setState(() {
                    _selectedChapterId = id;
                    _mobileTab = 1;
                  });
                },
                onAdd: _addChapter,
                onDelete: _deleteChapter,
                onMoveUp: (int i) => _move(i, -1),
                onMoveDown: (int i) => _move(i, 1),
                onEditOutline: _editOutline,
                onReorder: _reorder,
                targetWordsPerChapter: novel.targetWordsPerChapter,
              ),
            1 => EditorPage(
                key: ValueKey<String?>(_selectedChapterId),
                novelId: widget.novelId,
                chapterId: _selectedChapterId,
              ),
            _ => SingleChildScrollView(
                child: SettingPanel(novel: novel, onChanged: _reload),
              ),
          },
        ),
        NavigationBar(
          selectedIndex: _mobileTab,
          onDestinationSelected: (int i) => setState(() => _mobileTab = i),
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.menu_book_outlined),
              selectedIcon: Icon(Icons.menu_book),
              label: '章节',
            ),
            NavigationDestination(
              icon: Icon(Icons.edit_outlined),
              selectedIcon: Icon(Icons.edit),
              label: '写作',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: '设定',
            ),
          ],
        ),
      ],
    );
  }
}

/// 工作台标题栏。
class _WorkspaceHeader extends ConsumerWidget {
  const _WorkspaceHeader({
    required this.novel,
    required this.chapter,
    required this.focusMode,
    required this.onSearch,
    required this.onToggleFocus,
    required this.onRead,
    required this.onWorldBook,
    required this.onDraftBox,
    required this.onVolumeOutline,
    required this.onExport,
    required this.onGenerate,
    required this.onShortcuts,
    this.onBeatBoard,
    this.onCover,
  });

  final Novel novel;
  final Chapter? chapter;
  final bool focusMode;
  final VoidCallback onSearch;
  final VoidCallback onToggleFocus;
  final VoidCallback onRead;
  final VoidCallback onWorldBook;
  final VoidCallback onDraftBox;
  final VoidCallback onVolumeOutline;
  final VoidCallback? onBeatBoard;
  final VoidCallback? onCover;
  final VoidCallback onExport;
  final VoidCallback onGenerate;
  final VoidCallback onShortcuts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppInk ink = AppInk.of(context);
    final GenrePreset preset = GenrePresets.get(novel.genre);
    final int words = novel.chapters.fold<int>(
        0, (int a, Chapter c) => a + c.wordCount());

    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppTokens.s3, AppTokens.s2, AppTokens.s4, AppTokens.s2),
      decoration: BoxDecoration(
        color: ink.surface,
        border: Border(bottom: BorderSide(color: ink.divider)),
      ),
      child: Row(
        children: <Widget>[
          ToolButton(
            icon: Icons.chevron_left,
            label: '返回书架',
            onPressed: () => context.pop(),
          ),
          const SizedBox(width: AppTokens.s2),
          Container(
            width: 3,
            height: 26,
            decoration: BoxDecoration(
              color: GenreColors.of(novel.genre),
              borderRadius: BorderRadius.circular(AppTokens.r1),
            ),
          ),
          const SizedBox(width: AppTokens.s2 + 2),
          Flexible(
            child: Row(
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: Text(
                    novel.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.text(ink.ink,
                        size: 16.5,
                        weight: FontWeight.w700,
                        height: 1.3,
                        serifFace: true),
                  ),
                ),
                const SizedBox(width: AppTokens.s2 + 2),
                TintBadge(preset.label, dense: true),
                if (novel.archived)
                  const Padding(
                    padding: EdgeInsets.only(left: AppTokens.s2 - 2),
                    child: TintBadge('已归档',
                        dense: true, tone: BadgeTone.warn),
                  ),
                const SizedBox(width: AppTokens.s3),
                Text(
                  '${novel.chapters.length} 章 · ${TextFmt.words(words)} 字',
                  style: AppFonts.text(ink.inkFaint,
                      size: 12, height: 1.3, monoFace: true),
                ),
                if (chapter != null) ...<Widget>[
                  const SizedBox(width: AppTokens.s2),
                  Text('· ${chapter!.title}',
                      style: AppFonts.text(ink.inkSoft,
                          size: 12, height: 1.3)),
                ],
              ],
            ),
          ),
          const Spacer(),
          const SavedBadge(),
          const SizedBox(width: AppTokens.s2),
          ActionGroup(
            children: <Widget>[
              ToolButton(
                  icon: Icons.search, label: '全文搜索 (Ctrl+F)', onPressed: onSearch),
              ToolButton(
                icon: focusMode ? Icons.fullscreen_exit : Icons.fullscreen,
                label: '专注模式 (F11)',
                active: focusMode,
                onPressed: onToggleFocus,
              ),
              ToolButton(
                  icon: Icons.menu_book_outlined,
                  label: '阅读预览',
                  onPressed: onRead),
              ToolButton(
                  icon: Icons.upload_outlined,
                  label: '导出 (Ctrl+E)',
                  onPressed: onExport),
              _ToolOverflow(
                novel: novel,
                onWorldBook: onWorldBook,
                onDraftBox: onDraftBox,
                onVolumeOutline: onVolumeOutline,
                onBeatBoard: onBeatBoard,
                onCover: onCover,
              ),
            ],
          ),
          const SizedBox(width: AppTokens.s3),
          const _ThemeToggle(),
          const SizedBox(width: AppTokens.s2),
          FilledButton.icon(
            onPressed: onGenerate,
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('一键生成'),
          ),
        ],
      ),
    );
  }
}

/// 工具箱：低频但重要的动作收在这里，菜单里带图标和说明。
class _ToolOverflow extends StatelessWidget {
  const _ToolOverflow({
    required this.novel,
    required this.onWorldBook,
    required this.onDraftBox,
    required this.onVolumeOutline,
    this.onBeatBoard,
    this.onCover,
  });

  final Novel novel;
  final VoidCallback onWorldBook;
  final VoidCallback onDraftBox;
  final VoidCallback onVolumeOutline;
  final VoidCallback? onBeatBoard;
  final VoidCallback? onCover;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return PopupMenuButton<String>(
      tooltip: '工具箱',
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.s2),
      icon: Icon(Icons.apps_outlined, size: 18, color: ink.inkSoft),
      onSelected: (String v) {
        switch (v) {
          case 'world':
            onWorldBook();
          case 'draft':
            onDraftBox();
          case 'volume':
            onVolumeOutline();
          case 'beat':
            onBeatBoard?.call();
          case 'cover':
            onCover?.call();
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        _line(context, 'world', Icons.auto_stories_outlined, '世界书',
            '${novel.characters.length} 角色 · ${novel.worldSettings.length} 设定'),
        _line(context, 'volume', Icons.account_tree_outlined, '卷纲总览',
            '全书章节大纲一屏看'),
        _line(context, 'draft', Icons.inventory_2_outlined, '存稿箱',
            '${novel.drafts.length} 份草稿'),
        if (onBeatBoard != null)
          _line(context, 'beat', Icons.view_week_outlined, '节拍板', '本章场景与节奏'),
        if (onCover != null)
          _line(context, 'cover', Icons.auto_awesome_mosaic_outlined, '封面生成',
              '导出配图'),
      ],
    );
  }

  PopupMenuItem<String> _line(BuildContext context, String value, IconData icon,
      String title, String hint) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 16),
          const SizedBox(width: AppTokens.s3),
          Text(title),
          const SizedBox(width: AppTokens.s2),
          Flexible(
            child: Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11.5, color: AppInk.of(context).inkFaint),
            ),
          ),
        ],
      ),
    );
  }
}

/// 主题切换（浅色 → 深色 → 跟随系统）。
class _ThemeToggle extends ConsumerWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeMode mode = ref.watch(themeModeProvider);
    final (IconData icon, String label) = switch (mode) {
      ThemeMode.dark => (Icons.dark_mode, '深色'),
      ThemeMode.light => (Icons.light_mode, '浅色'),
      _ => (Icons.brightness_auto_outlined, '跟随系统'),
    };
    return ToolButton(icon: icon, label: '主题：$label', tooltip: '切换主题', onPressed: () {
      const List<ThemeMode> order = <ThemeMode>[
        ThemeMode.light,
        ThemeMode.dark,
        ThemeMode.system,
      ];
      final int next = (order.indexOf(mode) + 1) % order.length;
      ref.read(themeModeProvider.notifier).state = order[next];
    });
  }
}
