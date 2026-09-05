import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/features/project_list/crash_logs_dialog.dart';
import 'package:novel_writer/features/project_list/project_list_viewmodel.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/widgets/common.dart';

/// 首页：项目列表（新建 / 打开 / 重命名 / 删除）。
class ProjectListPage extends ConsumerStatefulWidget {
  /// 构造首页。
  const ProjectListPage({super.key});

  @override
  ConsumerState<ProjectListPage> createState() => _ProjectListPageState();
}

class _ProjectListPageState extends ConsumerState<ProjectListPage> {
  @override
  void initState() {
    super.initState();
    // 进入页面即加载项目列表。
    Future<void>.microtask(
      () => ref.read(projectListViewModelProvider.notifier).load(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ProjectListState state = ref.watch(projectListViewModelProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('墨匠 InkSmith · 我的作品'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            tooltip: 'AI 长篇小说流水线',
            onPressed: () => context.push('/ai-pipeline'),
          ),
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: '崩溃日志',
            onPressed: () async {
              final Directory supportDir = await AppDatabase.supportDirectory();
              final Directory crashDir = Directory(
                '${supportDir.path}${Platform.pathSeparator}crash_logs',
              );
              if (!context.mounted) return;
              await showCrashLogsDialog(context, crashDir, supportDir);
            },
          ),
          IconButton(
            icon: const Icon(Icons.shield_outlined),
            tooltip: '隐私与合规',
            onPressed: () => context.push('/privacy'),
          ),
        ],
      ),
      body: _buildBody(context, state),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('新建作品'),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ProjectListState state) {
    if (state.error != null) {
      return Center(child: Text('加载失败：${state.error}'));
    }
    if (state.isLoading && state.novels.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final List<NovelSummary> visible = state.visibleNovels;
    return Column(
      children: <Widget>[
        _buildSearchBar(context, state),
        _buildFilterChips(context, state),
        const Divider(height: 1),
        Expanded(
          child: visible.isEmpty
              ? (state.novels.isEmpty
                    ? const EmptyState(
                        message: '还没有作品，点击右下角新建第一部小说吧',
                        icon: Icons.auto_stories_outlined,
                      )
                    : const EmptyState(
                        message: '没有符合条件的作品',
                        icon: Icons.search_off,
                      ))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: visible.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final NovelSummary novel = visible[index];
                    final GenrePreset preset = GenrePresets.get(novel.genre);
                    return Card(
                      child: ListTile(
                        leading: Icon(
                          Icons.auto_stories,
                          color: novel.archived
                              ? Theme.of(context).colorScheme.outline
                              : null,
                        ),
                        title: Text(
                          novel.title,
                          style: novel.archived
                              ? TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.outline,
                                )
                              : null,
                        ),
                        subtitle: Text(
                          '${preset.label} · ${novel.chapterCount} 章 · '
                          '${_formatWords(novel.wordCount)} 字 · '
                          '更新于 ${_formatDate(novel.updatedAt)}'
                          '${novel.archived ? ' · 📦 已归档' : ''}',
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) async {
                            if (value == 'rename') {
                              await _showRenameDialog(context, novel);
                            } else if (value == 'archive') {
                              await ref
                                  .read(projectListViewModelProvider.notifier)
                                  .setArchived(novel.id, !novel.archived);
                            } else if (value == 'delete') {
                              final bool ok = await showConfirmDialog(
                                context,
                                title: '删除作品',
                                content: '确定删除《${novel.title}》？该操作不可恢复。',
                              );
                              if (ok && mounted) {
                                await ref
                                    .read(projectListViewModelProvider.notifier)
                                    .delete(novel.id);
                              }
                            }
                          },
                          itemBuilder: (context) => <PopupMenuEntry<String>>[
                            const PopupMenuItem(
                                value: 'rename', child: Text('重命名')),
                            PopupMenuItem(
                              value: 'archive',
                              child: Text(novel.archived ? '取消归档' : '归档'),
                            ),
                            const PopupMenuItem(
                                value: 'delete', child: Text('删除')),
                          ],
                        ),
                        onTap: () => context.push('/novel/${novel.id}'),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 顶部搜索框。
  Widget _buildSearchBar(BuildContext context, ProjectListState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: TextField(
        decoration: const InputDecoration(
          hintText: '搜索作品标题…',
          prefixIcon: Icon(Icons.search),
          isDense: true,
          border: OutlineInputBorder(),
        ),
        onChanged: (v) => ref
            .read(projectListViewModelProvider.notifier)
            .setQuery(v),
      ),
    );
  }

  /// 筛选 chips：全部 / 进行中 / 已归档。
  Widget _buildFilterChips(BuildContext context, ProjectListState state) {
    final Map<String, String> options = <String, String>{
      'all': '全部',
      'active': '进行中',
      'archived': '已归档',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: options.entries
            .map((e) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(e.value),
                    selected: state.filter == e.key,
                    onSelected: (_) => ref
                        .read(projectListViewModelProvider.notifier)
                        .setFilter(e.key),
                  ),
                ))
            .toList(),
      ),
    );
  }

  String _formatWords(int n) {
    if (n >= 10000) {
      return '${(n / 10000).toStringAsFixed(1)}万';
    }
    return n.toString();
  }

  Future<void> _showCreateDialog(BuildContext context) async {
    String title = '';
    String genre = GenrePresets.defaultKey;
    String tone = GenrePresets.get(GenrePresets.defaultKey).tones.first;
    final GlobalKey<FormState> formKey = GlobalKey<FormState>();

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (context, setInner) => AlertDialog(
          title: const Text('新建作品'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextFormField(
                  decoration: const InputDecoration(labelText: '作品名'),
                  onChanged: (v) => title = v,
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '请输入作品名' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: genre,
                  decoration: const InputDecoration(labelText: '题材'),
                  items: GenrePresets.all
                      .map((e) => DropdownMenuItem(
                          value: e.key, child: Text(e.label)))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setInner(() {
                      genre = v;
                      tone = GenrePresets.get(v).tones.first;
                    });
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: tone,
                  decoration: const InputDecoration(labelText: '基调'),
                  items: GenrePresets.get(genre)
                      .tones
                      .map((e) =>
                          DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setInner(() => tone = v);
                  },
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(ctx).pop();
                  ref
                      .read(projectListViewModelProvider.notifier)
                      .create(title.trim(), genre, tone);
                }
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRenameDialog(
      BuildContext context, NovelSummary novel) async {
    String title = novel.title;
    final GlobalKey<FormState> formKey = GlobalKey<FormState>();
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('重命名'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: novel.title,
            decoration: const InputDecoration(labelText: '作品名'),
            onChanged: (v) => title = v,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? '请输入作品名' : null,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(ctx).pop();
                ref
                    .read(projectListViewModelProvider.notifier)
                    .rename(novel.id, title.trim());
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${p(dt.month)}-${p(dt.day)} ${p(dt.hour)}:${p(dt.minute)}';
  }
}
