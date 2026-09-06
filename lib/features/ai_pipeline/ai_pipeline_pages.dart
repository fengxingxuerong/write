import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/ai_pipeline_service.dart';
import 'package:novel_writer/ai_pipeline/services/novel_importer.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 流水线存储 provider（应用支持目录 /ai_pipeline）。
final Provider<PipelineStorage> pipelineStorageProvider =
    Provider<PipelineStorage>((ref) {
  final String dir = ref.watch(appDatabaseProvider).directory.path;
  return PipelineStorage('$dir${Platform.pathSeparator}ai_pipeline');
});

/// 流水线服务 provider。
final Provider<AiPipelineService> aiPipelineServiceProvider =
    Provider<AiPipelineService>((ref) {
  return AiPipelineService(ref.watch(pipelineStorageProvider));
});

/// 书架导入 provider。
final Provider<NovelImporter> novelImporterProvider =
    Provider<NovelImporter>((ref) {
  return NovelImporter(
    ref.watch(novelRepositoryProvider),
    ref.watch(appDatabaseProvider),
  );
});

// ============================================================
// 首页：任务列表
// ============================================================

/// AI 长篇小说流水线首页（任务列表 + 新建入口）。
class AiPipelineHomePage extends ConsumerStatefulWidget {
  /// 构造页面。
  const AiPipelineHomePage({super.key});

  @override
  ConsumerState<AiPipelineHomePage> createState() =>
      _AiPipelineHomePageState();
}

class _AiPipelineHomePageState extends ConsumerState<AiPipelineHomePage> {
  late Future<List<AiPipelineTask>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(pipelineStorageProvider).listTasks();
  }

  void _reload() {
    setState(() {
      _future = ref.read(pipelineStorageProvider).listTasks();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 长篇小说流水线'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.auto_awesome),
        label: const Text('新建生成任务'),
        onPressed: () async {
          await context.push('/ai-pipeline/config');
          _reload();
        },
      ),
      body: FutureBuilder<List<AiPipelineTask>>(
        future: _future,
        builder: (BuildContext context, AsyncSnapshot<List<AiPipelineTask>> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final List<AiPipelineTask> tasks = snap.data ?? <AiPipelineTask>[];
          if (tasks.isEmpty) {
            return _buildEmpty(context);
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: tasks.length,
            itemBuilder: (BuildContext context, int index) =>
                _TaskCard(task: tasks[index], onChanged: _reload),
          );
        },
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(Icons.auto_stories_outlined, size: 64, color: Colors.grey),
          const SizedBox(height: 12),
          const Text('还没有生成任务'),
          const SizedBox(height: 4),
          Text(
            '配置多模型角色，一键生成完整长篇小说',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// 任务卡片。
class _TaskCard extends ConsumerWidget {
  /// 构造卡片。
  const _TaskCard({required this.task, required this.onChanged});

  final AiPipelineTask task;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String statusText = switch (task.status) {
      PipelineTaskStatus.idle => '待运行',
      PipelineTaskStatus.running => '运行中',
      PipelineTaskStatus.done => '已完成',
      PipelineTaskStatus.failed => '失败',
      PipelineTaskStatus.cancelled => '已取消',
    };
    final Color statusColor = switch (task.status) {
      PipelineTaskStatus.running => Colors.blue,
      PipelineTaskStatus.done => Colors.green,
      PipelineTaskStatus.failed => Colors.red,
      PipelineTaskStatus.cancelled => Colors.orange,
      _ => Colors.grey,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          task.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${task.chapterCount} 章 · ${task.totalWords} 字 · '
          '${task.createdAt.toLocal().toString().substring(0, 16)}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                statusText,
                style: TextStyle(color: statusColor, fontSize: 12),
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (String v) async {
                final PipelineStorage storage =
                    ref.read(pipelineStorageProvider);
                switch (v) {
                  case 'run':
                    await context.push('/ai-pipeline/run/${task.id}');
                    onChanged();
                  case 'report':
                    _showReport(context, task);
                  case 'import':
                    final NovelImporter importer =
                        ref.read(novelImporterProvider);
                    try {
                      final String id = await importer.importTask(task);
                      task.importedNovelId = id;
                      await ref
                          .read(pipelineStorageProvider)
                          .saveTask(task);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已导入书架：《${task.title}》')),
                        );
                      }
                      onChanged();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('导入失败：$e')),
                        );
                      }
                    }
                  case 'open':
                    context.push('/novel/${task.importedNovelId}');
                  case 'delete':
                    final bool? ok = await showDialog<bool>(
                      context: context,
                      builder: (BuildContext c) => AlertDialog(
                        title: const Text('删除任务'),
                        content: Text('确定删除《${task.title}》及其生成数据吗？'),
                        actions: <Widget>[
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await storage.deleteTask(task.id);
                      onChanged();
                    }
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                if (task.resumable)
                  const PopupMenuItem<String>(
                    value: 'run',
                    child: Text('继续 / 查看'),
                  )
                else
                  const PopupMenuItem<String>(
                    value: 'run',
                    child: Text('查看'),
                  ),
                if (task.chapterCount > 0 &&
                    task.status == PipelineTaskStatus.done)
                  PopupMenuItem<String>(
                    value: task.importedNovelId == null ? 'import' : 'open',
                    child: Text(task.importedNovelId == null ? '导入书架' : '打开作品'),
                  ),
                if (task.chapterCount > 0)
                  const PopupMenuItem<String>(value: 'report', child: Text('质检报告')),
                const PopupMenuItem<String>(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
        onTap: () async {
          await context.push('/ai-pipeline/run/${task.id}');
          onChanged();
        },
      ),
    );
  }

  void _showReport(BuildContext context, AiPipelineTask task) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        final List<PipelineChapter> sorted =
            List<PipelineChapter>.from(task.chapters)
              ..sort((a, b) => a.idx.compareTo(b.idx));
        return AlertDialog(
          title: const Text('质检报告'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('总字数：${task.totalWords}　章节：${task.chapterCount}'),
                  const Divider(),
                  for (final PipelineChapter c in sorted)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '第${c.idx}章 ${c.title}（${c.words}字）'
                        '　AI味 ${PipelineQa.aiEchoPct(c.content).toStringAsFixed(2)}%'
                        '　重复 ${PipelineQa.adjacentRepetition(c.content).toStringAsFixed(3)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}

// ============================================================
// 配置页：新建任务
// ============================================================

/// 新建任务配置页。
class AiPipelineConfigPage extends ConsumerStatefulWidget {
  /// 构造页面。
  const AiPipelineConfigPage({super.key});

  @override
  ConsumerState<AiPipelineConfigPage> createState() =>
      _AiPipelineConfigPageState();
}

class _AiPipelineConfigPageState extends ConsumerState<AiPipelineConfigPage> {
  final TextEditingController _wordsCtrl =
      TextEditingController(text: '100000');
  final TextEditingController _chaptersCtrl =
      TextEditingController(text: '40');
  final TextEditingController _genreCtrl =
      TextEditingController(text: '玄幻');
  final TextEditingController _protagonistCtrl =
      TextEditingController(text: '');
  bool _useEditor = true;
  bool _useVerifier = true;

  /// 五角色配置（默认值；可从最近任务配置加载）。
  Map<AiRole, AiRoleConfig> _roles = <AiRole, AiRoleConfig>{
    for (final AiRole r in AiRole.values)
      r: AiRoleConfig(role: r, llm: LlmConfig(temperature: r.defaultTemperature)),
  };

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  /// 加载最近一次任务配置并预填表单。
  Future<void> _loadRecent() async {
    final AiPipelineConfig? cfg =
        await ref.read(pipelineStorageProvider).loadRecentConfig();
    if (cfg == null || !mounted) return;
    setState(() {
      _wordsCtrl.text = cfg.totalWords.toString();
      _chaptersCtrl.text = cfg.maxChapters.toString();
      _genreCtrl.text = cfg.genre;
      _protagonistCtrl.text = cfg.protagonist;
      _useEditor = cfg.useEditor;
      _useVerifier = cfg.useVerifier;
      _roles = <AiRole, AiRoleConfig>{
        for (final AiRole r in AiRole.values) r: cfg.roleOf(r),
      };
    });
  }

  @override
  void dispose() {
    _wordsCtrl.dispose();
    _chaptersCtrl.dispose();
    _genreCtrl.dispose();
    _protagonistCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final int totalWords = int.tryParse(_wordsCtrl.text.trim()) ?? 100000;
    final int maxChapters = int.tryParse(_chaptersCtrl.text.trim()) ?? 40;
    final AiPipelineConfig config = AiPipelineConfig(
      totalWords: totalWords,
      maxChapters: maxChapters,
      genre: _genreCtrl.text.trim().isEmpty ? '玄幻' : _genreCtrl.text.trim(),
      protagonist: _protagonistCtrl.text.trim(),
      useEditor: _useEditor,
      useVerifier: _useVerifier,
      roles: _roles,
    );
    final List<AiRole> missing = AiPipelineService.missingRoles(config);
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '以下角色未配置模型：${missing.map((r) => r.label).join('、')}',
          ),
        ),
      );
      return;
    }
    final AiPipelineTask task = AiPipelineTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      config: config,
      createdAt: DateTime.now(),
    );
    await ref.read(pipelineStorageProvider).saveRecentConfig(config);
    await ref.read(pipelineStorageProvider).saveTask(task);
    if (!context.mounted) return;
    await context.push('/ai-pipeline/run/${task.id}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新建生成任务')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _section('基础设置'),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _wordsCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '目标总字数',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _chaptersCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '最大章节数',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _genreCtrl,
                  decoration: const InputDecoration(
                    labelText: '题材',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _protagonistCtrl,
                  decoration: const InputDecoration(
                    labelText: '主角名（可留空）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('启用去AI味润色'),
            subtitle: const Text('编辑角色整章改写，清除「仿佛/嘴角勾起」等 AI 高频表达'),
            value: _useEditor,
            onChanged: (bool v) => setState(() => _useEditor = v),
          ),
          SwitchListTile(
            title: const Text('启用一致性审校'),
            subtitle: const Text('审校角色每 5 章校验世界观/人物/剧情连贯性'),
            value: _useVerifier,
            onChanged: (bool v) => setState(() => _useVerifier = v),
          ),
          const SizedBox(height: 8),
          _section('角色模型配置（各自填写 API 端点）'),
          for (final AiRole role in AiRole.values) _roleCard(role),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('创建并开始生成'),
            onPressed: _start,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _roleCard(AiRole role) {
    final AiRoleConfig cfg = _roles[role]!;
    final TextEditingController modelCtrl =
        TextEditingController(text: cfg.llm.model);
    final TextEditingController urlCtrl =
        TextEditingController(text: cfg.llm.baseUrl);
    final TextEditingController keyCtrl =
        TextEditingController(text: cfg.llm.apiKey);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  switch (role) {
                    AiRole.planner => Icons.account_tree_outlined,
                    AiRole.writer => Icons.edit_note,
                    AiRole.editor => Icons.brush_outlined,
                    AiRole.titler => Icons.title,
                    AiRole.verifier => Icons.fact_check_outlined,
                  },
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('${role.label} · ${cfg.llm.model}'),
                      Text(
                        role.description,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: cfg.enabled,
                  onChanged: (bool v) => setState(() {
                    _roles[role] = AiRoleConfig(
                      role: role,
                      enabled: v,
                      llm: cfg.llm,
                    );
                  }),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: modelCtrl,
              decoration: const InputDecoration(
                labelText: '模型名',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (String v) => _updateRole(role, cfg, model: v),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: 'Base URL（自动拼接 /chat/completions，填根地址如 https://xxx/v1）',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (String v) => _updateRole(role, cfg, baseUrl: v),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: keyCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (String v) => _updateRole(role, cfg, apiKey: v),
            ),
          ],
        ),
      ),
    );
  }

  void _updateRole(
    AiRole role,
    AiRoleConfig old, {
    String? model,
    String? baseUrl,
    String? apiKey,
  }) {
    setState(() {
      _roles[role] = AiRoleConfig(
        role: role,
        enabled: old.enabled,
        llm: old.llm.copyWith(
          model: model ?? old.llm.model,
          baseUrl: baseUrl ?? old.llm.baseUrl,
          apiKey: apiKey ?? old.llm.apiKey,
        ),
      );
    });
  }
}

// ============================================================
// 运行页：进度 + 日志
// ============================================================

/// 任务运行页。
class AiPipelineRunPage extends ConsumerStatefulWidget {
  /// 构造页面。
  const AiPipelineRunPage({super.key, required this.taskId});

  final String taskId;

  @override
  ConsumerState<AiPipelineRunPage> createState() =>
      _AiPipelineRunPageState();
}

class _AiPipelineRunPageState extends ConsumerState<AiPipelineRunPage> {
  AiPipelineTask? _task;
  bool _running = false;
  bool _cancelRequested = false;
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final AiPipelineTask? t =
        await ref.read(pipelineStorageProvider).loadTask(widget.taskId);
    if (mounted) setState(() => _task = t);
  }

  Future<void> _run() async {
    if (_task == null || _running) return;
    setState(() {
      _running = true;
      _cancelRequested = false;
    });
    final AiPipelineService service =
        ref.read(aiPipelineServiceProvider);
    await service.run(
      _task!,
      isCancelled: () => _cancelRequested,
      onProgress: () {
        if (mounted) setState(() {});
        _scrollToBottom();
      },
    );
    if (mounted) {
      setState(() {
        _running = false;
        _task = _task;
      });
      await _load();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _exportTxt() async {
    final AiPipelineTask task = _task!;
    final List<PipelineChapter> sorted =
        List<PipelineChapter>.from(task.chapters)
          ..sort((a, b) => a.idx.compareTo(b.idx));
    final StringBuffer buf = StringBuffer()
      ..writeln('《${task.title}》')
      ..writeln();
    for (final PipelineChapter c in sorted) {
      buf
        ..writeln()
        ..writeln('第 ${c.idx} 章  ${c.title}')
        ..writeln('—' * 20)
        ..writeln()
        ..writeln(c.content);
    }
    final Directory dir = Directory(
      '${ref.read(pipelineStorageProvider).directory}${Platform.pathSeparator}export',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    final File file = File('${dir.path}${Platform.pathSeparator}${task.id}.txt');
    await file.writeAsString(buf.toString(), flush: true);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导出：${file.path}')),
    );
  }

  Future<void> _importToShelf() async {
    final AiPipelineTask task = _task!;
    final NovelImporter importer = ref.read(novelImporterProvider);
    try {
      final String novelId = await importer.importTask(task);
      task.importedNovelId = novelId;
      await ref.read(pipelineStorageProvider).saveTask(task);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导入书架：《${task.title}》共 ${task.chapterCount} 章'),
          action: SnackBarAction(
            label: '打开',
            onPressed: () => context.push('/novel/$novelId'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AiPipelineTask? task = _task;
    if (task == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final double ratio = task.config.totalWords <= 0
        ? 0
        : (task.totalWords / task.config.totalWords).clamp(0.0, 1.0);

    return Scaffold(
      appBar: AppBar(
        title: Text('《${task.title}》'),
        actions: <Widget>[
          if (task.status == PipelineTaskStatus.done) ...<Widget>[
            if (task.importedNovelId == null || task.importedNovelId!.isEmpty)
              IconButton(
                tooltip: '导入书架（生成章节写入作品库，可继续编辑/导出）',
                icon: const Icon(Icons.library_add_outlined),
                onPressed: _importToShelf,
              )
            else
              IconButton(
                tooltip: '打开作品',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => context.push('/novel/${task.importedNovelId}'),
              ),
            IconButton(
              tooltip: '导出 TXT',
              icon: const Icon(Icons.download),
              onPressed: _exportTxt,
            ),
          ],
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      '${task.chapterCount} 章 / ${task.totalWords} 字',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    _statusChip(task.status),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: ratio),
                const SizedBox(height: 4),
                Text(
                  '目标 ${task.config.totalWords} 字（${(ratio * 100).toStringAsFixed(0)}%）',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: task.log.length,
              itemBuilder: (BuildContext context, int index) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(
                  task.log[index],
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: _running
                        ? OutlinedButton.icon(
                            icon: const Icon(Icons.stop),
                            label: const Text('停止'),
                            onPressed: () => setState(() => _cancelRequested = true),
                          )
                        : FilledButton.icon(
                            icon: const Icon(Icons.play_arrow),
                            label: Text(
                              task.resumable ? '继续生成' : '重新开始',
                            ),
                            onPressed: _run,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(PipelineTaskStatus status) {
    final (String text, Color color) = switch (status) {
      PipelineTaskStatus.running => ('运行中', Colors.blue),
      PipelineTaskStatus.done => ('已完成', Colors.green),
      PipelineTaskStatus.failed => ('失败', Colors.red),
      PipelineTaskStatus.cancelled => ('已取消', Colors.orange),
      PipelineTaskStatus.idle => ('待运行', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}
