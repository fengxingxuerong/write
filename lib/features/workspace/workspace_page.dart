import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:novel_writer/features/editor/editor_page.dart';
import 'package:novel_writer/features/export/export_page.dart';
import 'package:novel_writer/features/export/cover_generator.dart';
import 'package:novel_writer/features/generate/generate_dialog.dart';
import 'package:novel_writer/features/reader/reader_page.dart';
import 'package:novel_writer/features/workspace/chapter_list_panel.dart';
import 'package:novel_writer/features/workspace/draft_box_dialog.dart';
import 'package:novel_writer/features/workspace/outline_dialog.dart';
import 'package:novel_writer/features/workspace/volume_outline_dialog.dart';
import 'package:novel_writer/features/workspace/search_dialog.dart';
import 'package:novel_writer/features/workspace/setting_panel.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/core/di/providers.dart';

/// 项目内主界面（三栏布局）：左章节列表 / 中编辑器 / 右设定，顶栏含导出与一键生成。
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
      final bool stillThere =
          _selectedChapterId != null &&
              novel.chapters.any((c) => c.id == _selectedChapterId);
      setState(() {
        _novel = novel;
        _selectedChapterId = stillThere
            ? _selectedChapterId
            : (novel.chapters.isNotEmpty ? novel.chapters.first.id : null);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开项目失败：$e')),
        );
        context.pop();
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addChapter() async {
    final Chapter ch = await ref
        .read(chapterRepositoryProvider)
        .addChapter(widget.novelId);
    await _reload();
    setState(() => _selectedChapterId = ch.id);
  }

  Future<void> _deleteChapter(String id) async {
    await ref.read(chapterRepositoryProvider).deleteChapter(widget.novelId, id);
    if (_selectedChapterId == id) _selectedChapterId = null;
    await _reload();
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
      // 当前总览已关闭，重新打开并允许继续编辑。
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
    final List<String> ordered =
        novel.chapters.map((c) => c.id).toList();
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
    // onReorderItem 已自动处理移除后索引，直接 clamp。
    final List<String> ordered = novel.chapters.map((c) => c.id).toList();
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

  Future<void> _toggleFocus() async {
    setState(() => _focusMode = !_focusMode);
    if (!_focusMode) return;
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(_selectedChapterId == null
                ? '专注模式已开启（暂无章节）'
                : '专注模式已开启，隐藏左右栏'),
            duration: const Duration(seconds: 1),
          ),
        );
    }
  }

  Future<void> _openGenerate() async {
    final Novel? novel = _novel;
    if (novel == null) return;
    await showGenerateDialog(
      context,
      novel,
      (Chapter ch) {
        _reload();
        setState(() => _selectedChapterId = ch.id);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final Novel? novel = _novel;
    if (novel == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('作品')),
        body: const Center(child: Text('项目不存在')),
      );
    }
    final ThemeMode themeMode = ref.watch(themeModeProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(novel.title),
        actions: <Widget>[
          IconButton(
            icon: Icon(themeMode == ThemeMode.dark
                ? Icons.dark_mode
                : themeMode == ThemeMode.light
                    ? Icons.light_mode
                    : Icons.brightness_auto),
            tooltip: '切换主题',
            onPressed: () {
              final List<ThemeMode> order = <ThemeMode>[
                ThemeMode.light,
                ThemeMode.dark,
                ThemeMode.system,
              ];
              final int next = (order.indexOf(themeMode) + 1) % order.length;
              ref.read(themeModeProvider.notifier).state = order[next];
            },
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '全文搜索',
            onPressed: () {
              showDialog<void>(
                context: context,
                builder: (BuildContext ctx) => SearchDialog(
                  novel: novel,
                  onSelect: (String chapterId, int offset) {
                    setState(() => _selectedChapterId = chapterId);
                  },
                ),
              );
            },
          ),
          IconButton(
            icon: Icon(_focusMode ? Icons.fullscreen_exit : Icons.fullscreen),
            tooltip: '专注模式 (F11)',
            onPressed: _toggleFocus,
          ),
          IconButton(
            icon: const Icon(Icons.menu_book_outlined),
            tooltip: '阅读预览',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ReaderPage(novel: novel),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.inventory_2_outlined),
            tooltip: '存稿箱',
            onPressed: () => showDraftBoxDialog(context, novel),
          ),
          IconButton(
            icon: const Icon(Icons.account_tree_outlined),
            tooltip: '卷纲总览',
            onPressed: () => _openVolumeOutline(novel),
          ),
          IconButton(
            icon: const Icon(Icons.auto_awesome_mosaic_outlined),
            tooltip: '封面生成',
            onPressed: () => CoverGenerator.showCoverPreview(context, novel),
          ),
          IconButton(
            icon: const Icon(Icons.upload),
            tooltip: '导出',
            onPressed: () => showExportDialog(context, novel),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.auto_awesome),
            label: const Text('一键生成'),
            onPressed: _openGenerate,
          ),
        ],
      ),
      body: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          // Ctrl+S 保存（编辑器已自动保存，此处刷新并提示）。
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              _saveAll,
          // Ctrl+B 一键生成。
          const SingleActivator(LogicalKeyboardKey.keyB, control: true):
              _openGenerate,
          // Ctrl+E 导出。
          const SingleActivator(LogicalKeyboardKey.keyE, control: true): () {
            final Novel? n = _novel;
            if (n != null) showExportDialog(context, n);
          },
          // F11 专注模式。
          const SingleActivator(LogicalKeyboardKey.f11): _toggleFocus,
        },
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 移动端（窄屏 < 900）：单栏 + 底部导航；桌面：三栏。
            final bool isMobile = constraints.maxWidth < 900;
            if (isMobile) {
              return _buildMobileBody(novel);
            }
            return _buildDesktopBody(novel);
          },
        ),
      ),
    );
  }

  void _saveAll() {
    final String? cid = _selectedChapterId;
    if (cid == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('已保存（自动保存已开启）'),
          duration: Duration(seconds: 1),
        ),
      );
  }

  /// 桌面端三栏布局。
  Widget _buildDesktopBody(Novel novel) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (!_focusMode) ...<Widget>[
          ChapterListPanel(
            chapters: novel.chapters,
            selectedChapterId: _selectedChapterId,
            onSelect: (id) => setState(() => _selectedChapterId = id),
            onAdd: _addChapter,
            onDelete: _deleteChapter,
            onMoveUp: (i) => _move(i, -1),
            onMoveDown: (i) => _move(i, 1),
            onEditOutline: _editOutline,
            onReorder: (oldIndex, newIndex) =>
                _reorder(oldIndex, newIndex),
          ),
          const VerticalDivider(width: 1),
        ],
        Expanded(
          child: EditorPage(
            key: ValueKey<String?>(_selectedChapterId),
            novelId: widget.novelId,
            chapterId: _selectedChapterId,
          ),
        ),
        if (!_focusMode) ...<Widget>[
          const VerticalDivider(width: 1),
          SettingPanel(novel: novel, onChanged: _reload),
        ],
      ],
    );
  }

  /// 移动端单栏布局：编辑器为主，底部导航在「章节 / 设定」间切换。
  Widget _buildMobileBody(Novel novel) {
    return Column(
      children: <Widget>[
        Expanded(
          child: _mobileTab == 0
              ? ChapterListPanel(
                  chapters: novel.chapters,
                  selectedChapterId: _selectedChapterId,
                  onSelect: (id) {
                    setState(() => _selectedChapterId = id);
                    // 选中后切到编辑器。
                    setState(() => _mobileTab = 1);
                  },
                  onAdd: _addChapter,
                  onDelete: _deleteChapter,
                  onMoveUp: (i) => _move(i, -1),
                  onMoveDown: (i) => _move(i, 1),
                  onEditOutline: _editOutline,
                  onReorder: (oldIndex, newIndex) =>
                      _reorder(oldIndex, newIndex),
                )
              : _mobileTab == 1
                  ? EditorPage(
                      key: ValueKey<String?>(_selectedChapterId),
                      novelId: widget.novelId,
                      chapterId: _selectedChapterId,
                    )
                  : SingleChildScrollView(
                      child: SettingPanel(novel: novel, onChanged: _reload),
                    ),
        ),
        // 底部导航。
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
