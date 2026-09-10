import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/core/utils/text_fmt.dart';
import 'package:novel_writer/features/project_list/crash_logs_dialog.dart';
import 'package:novel_writer/features/project_list/novel_card.dart';
import 'package:novel_writer/features/project_list/project_list_viewmodel.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/widgets/app_card.dart';
import 'package:novel_writer/widgets/app_feedback.dart';
import 'package:novel_writer/widgets/common.dart';
import 'package:novel_writer/widgets/page_shell.dart';

/// 首页：书架（新建 / 打开 / 重命名 / 归档 / 删除）。
class ProjectListPage extends ConsumerStatefulWidget {
  /// 构造首页。
  const ProjectListPage({super.key});

  @override
  ConsumerState<ProjectListPage> createState() => _ProjectListPageState();
}

class _ProjectListPageState extends ConsumerState<ProjectListPage> {
  final TextEditingController _search = TextEditingController();
  String _sort = 'updated';

  @override
  void initState() {
    super.initState();
    // 进入页面即加载项目列表。
    Future<void>.microtask(
      () => ref.read(projectListViewModelProvider.notifier).load(),
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ProjectListState state = ref.watch(projectListViewModelProvider);
    final AppInk ink = AppInk.of(context);

    return Scaffold(
      body: Column(
        children: <Widget>[
          _Masthead(
            novelCount: state.novels.length,
            totalWords:
                state.novels.fold<int>(0, (int a, NovelSummary n) => a + n.wordCount),
          ),
          if (state.error != null)
            _ErrorBar(
              message: state.error!,
              onRetry: () =>
                  ref.read(projectListViewModelProvider.notifier).load(),
            ),
          _Toolbar(
            controller: _search,
            filter: state.filter,
            sort: _sort,
            onFilter: (String f) =>
                ref.read(projectListViewModelProvider.notifier).setFilter(f),
            onSort: (String s) => setState(() => _sort = s),
            onSearch: (String q) =>
                ref.read(projectListViewModelProvider.notifier).setQuery(q),
            onCreate: _showCreateDialog,
          ),
          Container(height: AppTokens.hairline, color: ink.divider),
          Expanded(
            child: state.isLoading && state.novels.isEmpty
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2.2))
                : _Bookshelf(
                    state: state,
                    sort: _sort,
                    onOpen: (NovelSummary n) => context.push('/novel/${n.id}'),
                    onRename: _showRenameDialog,
                    onArchive: (NovelSummary n) => ref
                        .read(projectListViewModelProvider.notifier)
                        .setArchived(n.id, !n.archived),
                    onDelete: _confirmDelete,
                    onCreate: _showCreateDialog,
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateDialog() async {
    final _NewNovelDraft? draft = await showDialog<_NewNovelDraft>(
      context: context,
      builder: (BuildContext ctx) => const _CreateNovelDialog(),
    );
    if (draft == null || !mounted) return;
    await ref
        .read(projectListViewModelProvider.notifier)
        .create(draft.title, draft.genre, draft.tone);
    if (!mounted) return;
    AppToast.success(context, '《${draft.title}》已创建');
  }

  Future<void> _showRenameDialog(NovelSummary novel) async {
    final String? title = await showTextPromptDialog(
      context,
      title: '重命名',
      label: '作品名',
      initial: novel.title,
    );
    if (title == null || title.trim().isEmpty || !mounted) return;
    await ref
        .read(projectListViewModelProvider.notifier)
        .rename(novel.id, title.trim());
  }

  Future<void> _confirmDelete(NovelSummary novel) async {
    final bool ok = await showConfirmDialog(
      context,
      title: '删除作品',
      content: '确定删除《${novel.title}》？\n${novel.chapterCount} 章 · '
          '${TextFmt.words(novel.wordCount)} 字会一并移除，该操作不可恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(projectListViewModelProvider.notifier).delete(novel.id);
    if (mounted) AppToast.info(context, '已删除《${novel.title}》');
  }
}

/// 顶部刊头：品牌 + 标题 + 总量 + 全局动作。
class _Masthead extends ConsumerWidget {
  const _Masthead({required this.novelCount, required this.totalWords});

  final int novelCount;
  final int totalWords;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppInk ink = AppInk.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppTokens.s6, AppTokens.s4, AppTokens.s4, AppTokens.s3),
      decoration: BoxDecoration(
        color: ink.surface,
        border: Border(bottom: BorderSide(color: ink.divider)),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: ink.primary,
              borderRadius: BorderRadius.circular(AppTokens.r2),
            ),
            child: Text(
              '墨',
              style: AppFonts.text(ink.paper,
                  size: 18, weight: FontWeight.w700, serifFace: true),
            ),
          ),
          const SizedBox(width: AppTokens.s3),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '我的作品',
                style: AppFonts.text(ink.ink,
                    size: 18, weight: FontWeight.w700, height: 1.25),
              ),
              const SizedBox(height: 1),
              Text(
                novelCount == 0
                    ? '墨匠 InkSmith · 本地优先，数据都在你自己的机器上'
                    : '墨匠 InkSmith · $novelCount 部 · 共 ${TextFmt.words(totalWords)} 字',
                style: AppFonts.text(ink.inkFaint, size: 12, height: 1.4),
              ),
            ],
          ),
          const Spacer(),
          ActionGroup(
            children: <Widget>[
              ToolButton(
                icon: Icons.auto_awesome,
                label: 'AI 长篇小说流水线',
                tone: ink.accent,
                onPressed: () => context.push('/ai-pipeline'),
              ),
              ToolButton(
                icon: Icons.bug_report_outlined,
                label: '崩溃日志',
                onPressed: () async {
                  final Directory supportDir =
                      await AppDatabase.supportDirectory();
                  final Directory crashDir = Directory(
                    '${supportDir.path}${Platform.pathSeparator}crash_logs',
                  );
                  if (!context.mounted) return;
                  await showCrashLogsDialog(context, crashDir, supportDir);
                },
              ),
              ToolButton(
                icon: Icons.shield_moon_outlined,
                label: '隐私与合规',
                onPressed: () => context.push('/privacy'),
              ),
              const _ThemeToggle(),
            ],
          ),
        ],
      ),
    );
  }
}

/// 工具条：搜索 + 筛选 + 排序 + 新建。
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.filter,
    required this.sort,
    required this.onFilter,
    required this.onSort,
    required this.onSearch,
    required this.onCreate,
  });

  final TextEditingController controller;
  final String filter;
  final String sort;
  final ValueChanged<String> onFilter;
  final ValueChanged<String> onSort;
  final ValueChanged<String> onSearch;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTokens.s6, AppTokens.s3, AppTokens.s4, AppTokens.s3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 260,
            child: TextField(
              controller: controller,
              onChanged: onSearch,
              textInputAction: TextInputAction.search,
              style: AppFonts.text(ink.ink, size: 13.5, height: 1.5),
              decoration: InputDecoration(
                hintText: '搜索作品标题',
                prefixIcon: const Icon(Icons.search, size: 17),
                prefixIconConstraints: const BoxConstraints(
                    minWidth: 36, minHeight: 36),
                suffixIcon: controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 15),
                        tooltip: '清空',
                        onPressed: () {
                          controller.clear();
                          onSearch('');
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(width: AppTokens.s3),
          SegmentedButton<String>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            segments: const <ButtonSegment<String>>[
              ButtonSegment<String>(value: 'all', label: Text('全部')),
              ButtonSegment<String>(value: 'active', label: Text('写作中')),
              ButtonSegment<String>(value: 'archived', label: Text('已归档')),
            ],
            selected: <String>{filter},
            onSelectionChanged: (Set<String> s) => onFilter(s.first),
          ),
          const Spacer(),
          _SortMenu(sort: sort, onSort: onSort),
          const SizedBox(width: AppTokens.s3),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add, size: 17),
            label: const Text('新建作品'),
          ),
        ],
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.sort, required this.onSort});

  final String sort;
  final ValueChanged<String> onSort;

  static const Map<String, String> _labels = <String, String>{
    'updated': '最近更新',
    'created': '创建顺序',
    'words': '字数最多',
    'title': '标题',
  };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '排序',
      onSelected: onSort,
      itemBuilder: (BuildContext context) => _labels.entries
          .map(
            (MapEntry<String, String> e) => PopupMenuItem<String>(
              value: e.key,
              child: Row(
                children: <Widget>[
                  Icon(
                    e.key == sort
                        ? Icons.check
                        : Icons.text_format_outlined,
                    size: 15,
                    color: e.key == sort
                        ? AppInk.of(context).primary
                        : AppInk.of(context).inkFaint,
                  ),
                  const SizedBox(width: AppTokens.s3),
                  Text(e.value),
                ],
              ),
            ),
          )
          .toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.s3, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.swap_vert, size: 16, color: AppInk.of(context).inkSoft),
            const SizedBox(width: AppTokens.s2 - 2),
            Text(
              _labels[sort] ?? '排序',
              style: AppFonts.text(AppInk.of(context).inkSoft,
                  size: 13, height: 1.3),
            ),
          ],
        ),
      ),
    );
  }
}

/// 书架：宽度自适应的卡片流。
class _Bookshelf extends StatelessWidget {
  const _Bookshelf({
    required this.state,
    required this.sort,
    required this.onOpen,
    required this.onRename,
    required this.onArchive,
    required this.onDelete,
    required this.onCreate,
  });

  final ProjectListState state;
  final String sort;
  final ValueChanged<NovelSummary> onOpen;
  final ValueChanged<NovelSummary> onRename;
  final ValueChanged<NovelSummary> onArchive;
  final ValueChanged<NovelSummary> onDelete;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final List<NovelSummary> items = _sorted(state.visibleNovels);

    if (items.isEmpty) {
      return state.novels.isEmpty
          ? EmptyState(
              icon: Icons.auto_stories_outlined,
              message: '书架还是空的',
              hint: '新建一部作品，或让 AI 流水线从一句灵感开始铺出整本大纲。',
              actionLabel: '新建作品',
              onAction: onCreate,
            )
          : const EmptyState(
              icon: Icons.search_off,
              message: '没有符合条件的作品',
              hint: '换个关键词，或把筛选切回「全部」。',
            );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        const double gap = AppTokens.s4;
        const double cardH = 200;
        final double avail = c.maxWidth - AppTokens.s6 - AppTokens.s4;
        final int columns = (avail / (296 + gap)).floor().clamp(1, 5);
        final double cardW =
            ((avail - gap * (columns - 1)) / columns).clamp(240.0, 420.0);
        final bool showAdd = state.filter != 'archived';

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
              AppTokens.s6, AppTokens.s4, AppTokens.s4, AppTokens.s8),
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (final NovelSummary n in items)
                SizedBox(
                  width: cardW,
                  height: cardH,
                  child: NovelCard(
                    novel: n,
                    width: cardW,
                    height: cardH,
                    onOpen: () => onOpen(n),
                    onRename: () => onRename(n),
                    onArchive: () => onArchive(n),
                    onDelete: () => onDelete(n),
                  ),
                ),
              // 末尾补一个「新建」卡，宽屏不会出现空洞。
              if (showAdd)
                SizedBox(
                  width: cardW,
                  height: cardH,
                  child: _NewHereCard(ink: ink, onTap: onCreate),
                ),
            ],
          ),
        );
      },
    );
  }

  List<NovelSummary> _sorted(List<NovelSummary> input) {
    final List<NovelSummary> out = List<NovelSummary>.of(input);
    switch (sort) {
      case 'words':
        out.sort((NovelSummary a, NovelSummary b) =>
            b.wordCount.compareTo(a.wordCount));
      case 'title':
        out.sort((NovelSummary a, NovelSummary b) =>
            a.title.compareTo(b.title));
      case 'created':
        out.sort((NovelSummary a, NovelSummary b) =>
            b.updatedAt.compareTo(a.updatedAt));
      default:
        out.sort((NovelSummary a, NovelSummary b) =>
            b.updatedAt.compareTo(a.updatedAt));
    }
    return out;
  }
}

class _NewHereCard extends StatelessWidget {
  const _NewHereCard({required this.ink, required this.onTap});

  final AppInk ink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      borderRadius: AppTokens.radiusCard,
      child: Container(
        height: 200,
        decoration: BoxDecoration(
          borderRadius: AppTokens.radiusCard,
          border: Border.all(color: ink.border, width: AppTokens.cardBorder),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.add_circle_outline, size: 26, color: ink.inkFaint),
            const SizedBox(height: AppTokens.s2),
            Text('新建一部作品',
                style: AppFonts.text(ink.inkSoft,
                    size: 13.5, weight: FontWeight.w500, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return Container(
      width: double.infinity,
      color: ink.danger.withValues(alpha: ink.dark ? 0.16 : 0.08),
      padding: const EdgeInsets.fromLTRB(
          AppTokens.s6, AppTokens.s2 + 2, AppTokens.s4, AppTokens.s2 + 2),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, size: 16, color: ink.danger),
          const SizedBox(width: AppTokens.s2 + 2),
          Expanded(
            child: Text(
              message,
              style: AppFonts.text(ink.danger, size: 13, height: 1.5),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
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
    final IconData icon = switch (mode) {
      ThemeMode.dark => Icons.dark_mode,
      ThemeMode.light => Icons.light_mode,
      _ => Icons.brightness_auto_outlined,
    };
    return ToolButton(
      icon: icon,
      label: switch (mode) {
        ThemeMode.dark => '深色',
        ThemeMode.light => '浅色',
        _ => '跟随系统',
      },
      tooltip: '切换主题（当前：${switch (mode) {
        ThemeMode.dark => '深色',
        ThemeMode.light => '浅色',
        _ => '跟随系统',
      }}）',
      onPressed: () {
        const List<ThemeMode> order = <ThemeMode>[
          ThemeMode.light,
          ThemeMode.dark,
          ThemeMode.system,
        ];
        final int next = (order.indexOf(mode) + 1) % order.length;
        ref.read(themeModeProvider.notifier).state = order[next];
      },
    );
  }
}

/// 新建草稿（对话框返回值）。
class _NewNovelDraft {
  const _NewNovelDraft(this.title, this.genre, this.tone);

  /// 作品名。
  final String title;

  /// 题材 key。
  final String genre;

  /// 基调。
  final String tone;
}

/// 新建作品对话框：左边选题材（带题材色），右边填名字与基调。
class _CreateNovelDialog extends StatefulWidget {
  const _CreateNovelDialog();

  @override
  State<_CreateNovelDialog> createState() => _CreateNovelDialogState();
}

class _CreateNovelDialogState extends State<_CreateNovelDialog> {
  final TextEditingController _title = TextEditingController();
  String _genre = GenrePresets.defaultKey;
  late String _tone = GenrePresets.get(GenrePresets.defaultKey).tones.first;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    final String title = _title.text.trim();
    if (title.isEmpty) {
      AppToast.warn(context, '先给作品起个名字');
      return;
    }
    Navigator.of(context).pop(_NewNovelDraft(title, _genre, _tone));
  }

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final List<String> tones = GenrePresets.get(_genre).tones;
    return AlertDialog(
      title: const Text('新建作品'),
      content: SizedBox(
        width: 640,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 340,
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: AppTokens.s2,
                  runSpacing: AppTokens.s2,
                  children: GenrePresets.all.map((GenrePreset p) {
                    final bool on = p.key == _genre;
                    final Color c = GenreColors.of(p.key);
                    return SizedBox(
                      width: 104,
                      child: Hoverable(
                        onTap: () => setState(() {
                          _genre = p.key;
                          _tone = p.tones.first;
                        }),
                        selected: on,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: AppTokens.s2 + 2,
                              horizontal: AppTokens.s2),
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular(AppTokens.r2),
                            border: Border.all(
                              color: on ? c : ink.border,
                              width: on ? 1.4 : AppTokens.hairline,
                            ),
                            color: on
                                ? c.withValues(
                                    alpha: ink.dark ? 0.20 : 0.10)
                                : null,
                          ),
                          child: Row(
                            children: <Widget>[
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                    color: c, shape: BoxShape.circle),
                              ),
                              const SizedBox(width: AppTokens.s2),
                              Expanded(
                                child: Text(
                                  p.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppFonts.text(
                                    on ? ink.ink : ink.inkSoft,
                                    size: 13,
                                    weight: on
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(width: AppTokens.s4),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    controller: _title,
                    autofocus: true,
                    onSubmitted: (_) => _submit(),
                    style: AppFonts.text(ink.ink, size: 14, height: 1.5),
                    decoration: const InputDecoration(
                      labelText: '作品名',
                      hintText: '例：碎星航线',
                    ),
                  ),
                  const SizedBox(height: AppTokens.s3),
                  Text('基调',
                      style: AppFonts.text(ink.inkFaint,
                          size: 12, weight: FontWeight.w600, height: 1.4)),
                  const SizedBox(height: AppTokens.s2 - 2),
                  Wrap(
                    spacing: AppTokens.s2,
                    runSpacing: AppTokens.s2 - 4,
                    children: tones
                        .map((String t) => ChoiceChip(
                              label: Text(t),
                              selected: t == _tone,
                              onSelected: (_) => setState(() => _tone = t),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: AppTokens.s3),
                  Text(
                    '题材决定 AI 写手的人设、术语与节奏基调；基调影响开篇氛围。'
                    '两者之后都能在工作区里改。',
                    style: AppFonts.text(ink.inkFaint,
                        size: 12, height: 1.7),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.check, size: 16),
          label: const Text('创建并进入'),
        ),
      ],
    );
  }
}
