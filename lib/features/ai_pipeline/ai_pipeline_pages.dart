import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:file_picker/file_picker.dart';
import 'package:novel_writer/ai_pipeline/fixed_workflow_preset.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/ai_pipeline_service.dart';
import 'package:novel_writer/ai_pipeline/services/novel_importer.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/features/ai_pipeline/pipeline_quality_panel.dart';
import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/core/security/secret_store.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/widgets/app_feedback.dart';

/// 流水线存储 provider（应用支持目录 /ai_pipeline）。
final Provider<PipelineStorage> pipelineStorageProvider =
    Provider<PipelineStorage>((ref) {
      final String dir = ref.watch(appDatabaseProvider).directory.path;
      return PipelineStorage(
        '$dir${Platform.pathSeparator}ai_pipeline',
        secretStore: const DpapiSecretStore(),
      );
    });

/// 流水线服务 provider。
final Provider<AiPipelineService> aiPipelineServiceProvider =
    Provider<AiPipelineService>((ref) {
      return AiPipelineService(ref.watch(pipelineStorageProvider));
    });

/// 书架导入 provider。
final Provider<NovelImporter> novelImporterProvider = Provider<NovelImporter>((
  ref,
) {
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
  ConsumerState<AiPipelineHomePage> createState() => _AiPipelineHomePageState();
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
        builder:
            (BuildContext context, AsyncSnapshot<List<AiPipelineTask>> snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final List<AiPipelineTask> tasks =
                  snap.data ?? <AiPipelineTask>[];
              if (tasks.isEmpty) {
                return _buildEmpty(context);
              }
              return ListView.builder(
                padding: const EdgeInsets.all(AppTokens.s3),
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
          Icon(
            Icons.auto_stories_outlined,
            size: 64,
            color: AppInk.of(context).inkFaint,
          ),
          const SizedBox(height: AppTokens.s3),
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
    final AppInk ink = AppInk.of(context);
    final Color statusColor = switch (task.status) {
      PipelineTaskStatus.running => ink.primary,
      PipelineTaskStatus.done => ink.success,
      PipelineTaskStatus.failed => ink.danger,
      PipelineTaskStatus.cancelled => ink.warn,
      _ => ink.inkFaint,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.s2),
      child: ListTile(
        title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
                borderRadius: BorderRadius.circular(AppTokens.r3),
              ),
              child: Text(
                statusText,
                style: AppFonts.text(statusColor, size: 12),
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (String v) async {
                final PipelineStorage storage = ref.read(
                  pipelineStorageProvider,
                );
                switch (v) {
                  case 'run':
                    await context.push('/ai-pipeline/run/${task.id}');
                    onChanged();
                  case 'report':
                    _showReport(context, task);
                  case 'import':
                    final NovelImporter importer = ref.read(
                      novelImporterProvider,
                    );
                    try {
                      final String id = await importer.importTask(task);
                      task.importedNovelId = id;
                      await ref.read(pipelineStorageProvider).saveTask(task);
                      if (context.mounted) {
                        AppToast.success(context, '已导入书架：《${task.title}》');
                      }
                      onChanged();
                    } catch (e) {
                      if (context.mounted) {
                        AppToast.error(context, '导入失败：$e');
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
                  const PopupMenuItem<String>(value: 'run', child: Text('查看')),
                if (task.chapterCount > 0 &&
                    task.status == PipelineTaskStatus.done)
                  PopupMenuItem<String>(
                    value: task.importedNovelId == null ? 'import' : 'open',
                    child: Text(task.importedNovelId == null ? '导入书架' : '打开作品'),
                  ),
                if (task.chapterCount > 0)
                  const PopupMenuItem<String>(
                    value: 'report',
                    child: Text('质检报告'),
                  ),
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
        final List<PipelineChapter> sorted = List<PipelineChapter>.from(
          task.chapters,
        )..sort((a, b) => a.idx.compareTo(b.idx));
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
                        style: AppFonts.text(
                          AppInk.of(context).inkSoft,
                          size: 12,
                        ),
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
  final TextEditingController _wordsCtrl = TextEditingController(
    text: '100000',
  );
  final TextEditingController _chaptersCtrl = TextEditingController(text: '40');
  final TextEditingController _genreCtrl = TextEditingController(text: '玄幻');
  final TextEditingController _protagonistCtrl = TextEditingController(
    text: '',
  );
  bool _useEditor = true;
  bool _useVerifier = true;
  bool _useFactCheck = true;
  bool _usePromiseCheck = true;
  bool _useChiefReview = true;

  /// 是否把未实测的候选端点（NVIDIA / OpenRouter）也纳入备用链。
  bool _useUnverified = false;

  /// 角色路由覆盖（JSON 文本，如 `{"writer":{"model":"glm-5.3"}}`）。
  ///
  /// 让「换模型」不必改代码：真实链路里模型换代极快（实测 NVIDIA
  /// `z-ai/glm-5.2` 已 410 EOL、`stealth/ox-alpha` 更名 `z-ai/glm-5.3-flash`），
  /// 硬编码的映射必然跟不上。空串 = 用预设。
  final TextEditingController _roleRoutingCtrl = TextEditingController();

  /// 最近一次导入的密钥映射（`FixedWorkflowPreset.parseKeys` 的结果）。
  ///
  /// 保留它是为了让「按路由覆盖重新装配」能复用**完全相同的装配路径**：
  /// 不必从已装配的角色表里反推密钥（那是绕路，且一旦某角色被手工改过端点，
  /// 反推出来的 key 名就对不上预设的 `NOVEL_KEY_*`，会静默装配出空链）。
  /// 密钥只在内存里，不落盘、不回显。
  Map<String, String> _lastKeys = <String, String>{};

  /// 五角色配置（默认值；可从最近任务配置加载）。
  Map<AiRole, AiRoleConfig> _roles = <AiRole, AiRoleConfig>{
    for (final AiRole r in AiRole.values)
      r: AiRoleConfig(
        role: r,
        llm: LlmConfig(temperature: r.defaultTemperature),
      ),
  };

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  /// 加载最近一次任务配置并预填表单。
  Future<void> _loadRecent() async {
    final AiPipelineConfig? cfg = await ref
        .read(pipelineStorageProvider)
        .loadRecentConfig();
    if (cfg == null || !mounted) return;
    setState(() {
      _wordsCtrl.text = cfg.totalWords.toString();
      _chaptersCtrl.text = cfg.maxChapters.toString();
      _genreCtrl.text = cfg.genre;
      _protagonistCtrl.text = cfg.protagonist;
      _useEditor = cfg.useEditor;
      _useVerifier = cfg.useVerifier;
    _useFactCheck = cfg.useFactCheck;
    _usePromiseCheck = cfg.usePromiseCheck;
    _useChiefReview = cfg.useChiefReview;
      _roles = <AiRole, AiRoleConfig>{
        for (final AiRole r in AiRole.values) r: cfg.roleOf(r),
      };
    });
  }

  /// 按当前路由覆盖重新装配角色表。
  ///
  /// 复用导入密钥时的**同一条**装配路径（[FixedWorkflowPreset.roles]），只是多传
  /// 一次覆盖表——不另开一条装配逻辑，否则两条路径迟早会漂移。
  void _applyRoleRouting() {
    if (_lastKeys.isEmpty) {
      _snack('还没有导入过密钥：先「导入本机 API 配置」，再按路由装配');
      return;
    }
    final Map<AiRole, AiRoleConfig> next = FixedWorkflowPreset.roles(
      _lastKeys,
      includeCandidates: _useUnverified,
      roleOverrides:
          FixedWorkflowPreset.parseOverrides(_roleRoutingCtrl.text),
    );
    setState(() => _roles = next);
    final int n = FixedWorkflowPreset.parseOverrides(_roleRoutingCtrl.text).length;
    _snack(n == 0 ? '路由覆盖为空，已回退预设装配' : '已按 $n 个角色覆盖重新装配');
  }

  @override
  void dispose() {
    _wordsCtrl.dispose();
    _chaptersCtrl.dispose();
    _genreCtrl.dispose();
    _protagonistCtrl.dispose();
    _roleRoutingCtrl.dispose();
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
      useFactCheck: _useFactCheck,
      usePromiseCheck: _usePromiseCheck,
      useChiefReview: _useChiefReview,
      roles: _roles,
    );
    final List<AiRole> missing = AiPipelineService.missingRoles(config);
    if (missing.isNotEmpty) {
      AppToast.warn(
        context,
        '以下角色未配置模型：${missing.map((r) => r.label).join('、')}',
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
    if (!mounted) return;
    await context.push('/ai-pipeline/run/${task.id}');
  }

  /// 提示条。
  void _snack(String msg) {
    if (!mounted) return;
    AppToast.info(context, msg);
  }

  /// 导入本机 API 配置并按固定分工装配五角色端点链。
  ///
  /// 密钥只落在本机任务配置里（随 pipeline 存储），不进源码；调用远程服务时会作为鉴权凭据发送。
  Future<void> _importLocalKeys() async {
    String? text;
    try {
      final FilePickerResult? res = await FilePicker.platform.pickFiles(
        dialogTitle: '选择 API 配置文件（.env.local / txt）',
      );
      final String? path = res?.files.singleOrNull?.path;
      if (path != null) text = await File(path).readAsString();
    } catch (_) {
      text = null;
    }
    if (!mounted) return;

    if (text == null || text.trim().isEmpty) {
      final TextEditingController ctrl = TextEditingController();
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext c) => AlertDialog(
          title: const Text('粘贴 API 配置'),
          content: TextField(
            controller: ctrl,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText:
                  'Base URL / 模型名 / API Key 混排即可，'
                  '会自动识别 rc- / sk- / nvapi- / sk-or-v1- 开头的密钥',
              border: OutlineInputBorder(),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('导入'),
            ),
          ],
        ),
      );
      text = ok == true ? ctrl.text : null;
      ctrl.dispose();
      if (text == null || text.trim().isEmpty) return;
    }

    final Map<String, String> keys = FixedWorkflowPreset.parseKeys(text);
    if (keys.isEmpty) {
      _snack('未识别到 API Key（支持 rc- / sk- / nvapi- / sk-or-v1- 开头）');
      return;
    }
    setState(() {
      _lastKeys = keys;
      _roles = FixedWorkflowPreset.roles(
        keys,
        includeCandidates: _useUnverified,
        roleOverrides: FixedWorkflowPreset.parseOverrides(_roleRoutingCtrl.text),
      );
    });
    _snack(
      '已按固定分工导入 ${keys.length} 个密钥（'
      '策划/写手/编辑/标题/审校 各自的主备链已自动排序；'
      '调用远程服务时会发送给对应服务商）',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新建生成任务')),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.s4),
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
              const SizedBox(width: AppTokens.s3),
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
          const SizedBox(height: AppTokens.s3),
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
              const SizedBox(width: AppTokens.s3),
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
          SwitchListTile(
            title: const Text('启用编造核查（关卡5）'),
            subtitle: const Text('对照已确立事实核查每章，凭空补的细节会被定点修掉。'
                '每章多一次模型调用，配额紧张可关'),
            value: _useFactCheck,
            onChanged: (bool v) => setState(() => _useFactCheck = v),
          ),
          SwitchListTile(
            title: const Text('启用回收清单打勾'),
            subtitle: const Text('必兑现清单逐条验收，未兑现定向补写，通过即联动台账。'
                '仅在有伏笔埋设超 5 章时才产生调用'),
            value: _usePromiseCheck,
            onChanged: (bool v) => setState(() => _usePromiseCheck = v),
          ),
          SwitchListTile(
            title: const Text('启用终审官（通读级总评 + 打回权）'),
            subtitle: const Text('全书收官后跑六维通读总评（节奏曲线/人物弧光/结局力度），'
                '低于打回线自动重写问题章并二审。默认 3 次采样，成本较高'),
            value: _useChiefReview,
            onChanged: (bool v) => setState(() => _useChiefReview = v),
          ),
          const SizedBox(height: 8),
          _section('固定角色分工'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.s3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '把本机 API 配置导入后，软件会按固定分工自动装配：'
                    '策划/写手/编辑/标题/审校 五岗各自的主模型与备用链、'
                    '各自温度一次到位，无需逐个手填。',
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '密钥只写入本机任务配置，不进入源码，也不随导出外发。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('同时纳入未实测候选端点'),
                    subtitle: const Text(
                      'NVIDIA（z-ai/glm-5.2）与 OpenRouter（stealth/ox-alpha）'
                      '仅作链尾兜底',
                    ),
                    value: _useUnverified,
                    onChanged: (bool v) => setState(() => _useUnverified = v),
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.upload_file),
                    label: const Text('导入本机 API 配置并固定分工'),
                    onPressed: _importLocalKeys,
                  ),
                ],
              ),
            ),
          ),
          _section('角色模型配置（各自填写 API 端点）'),
          for (final AiRole role in AiRole.values) _roleCard(role),
          const SizedBox(height: 8),
          _section('角色路由覆盖（按角色换主模型）'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.s3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '换模型不必改代码。填 JSON 后点「装配固定分工」生效；'
                    '只改每个角色的**主位**模型，备用链保持预设不变（多级降级不能丢）。',
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _roleRoutingCtrl,
                    maxLines: 6,
                    minLines: 3,
                    style: AppFonts.text(AppInk.of(context).ink,
                        size: 12.5, monoFace: true),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: '{\n  "writer": {"model": "glm-5.3", "temperature": 0.9},\n'
                          '  "planner": {"model": "z-ai/glm-5.3", "maxTokens": 8000}\n}',
                      helperText: '可用角色：planner / writer / editor / titler / verifier；'
                          '可用字段：model / temperature / maxTokens / baseUrl / apiKey。'
                          '写错会被静默忽略并回退默认，不会崩。',
                      helperMaxLines: 3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _applyRoleRouting,
                    icon: const Icon(Icons.route_outlined, size: 16),
                    label: const Text('按当前路由覆盖重新装配'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppTokens.s4),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('创建并开始生成'),
            onPressed: _start,
          ),
          const SizedBox(height: AppTokens.s6),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: AppTokens.s2, bottom: AppTokens.s2),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _roleCard(AiRole role) {
    final AiRoleConfig cfg = _roles[role]!;
    final TextEditingController modelCtrl = TextEditingController(
      text: cfg.llm.model,
    );
    final TextEditingController urlCtrl = TextEditingController(
      text: cfg.llm.baseUrl,
    );
    final TextEditingController keyCtrl = TextEditingController(
      text: cfg.llm.apiKey,
    );

    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.s2),
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(switch (role) {
                  AiRole.planner => Icons.account_tree_outlined,
                  AiRole.writer => Icons.edit_note,
                  AiRole.editor => Icons.brush_outlined,
                  AiRole.titler => Icons.title,
                  AiRole.verifier => Icons.fact_check_outlined,
                }, size: 20),
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
                      fallbacks: cfg.fallbacks,
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
                labelText:
                    'Base URL（自动拼接 /chat/completions，填根地址如 https://xxx/v1）',
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
        fallbacks: old.fallbacks,
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
  ConsumerState<AiPipelineRunPage> createState() => _AiPipelineRunPageState();
}

class _AiPipelineRunPageState extends ConsumerState<AiPipelineRunPage> {
  AiPipelineTask? _task;
  bool _running = false;
  bool _cancelRequested = false;
  // 0 = 运行日志（时间序流水），1 = 质量面板（书级横切面）。
  // 两者并列成视图而不是混在一起：日志是「刚才发生了什么」，质量是
  // 「这本书哪一章有问题」，混排会让作者永远找不到后者。
  int _view = 0;
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
    final AiPipelineTask? t = await ref
        .read(pipelineStorageProvider)
        .loadTask(widget.taskId);
    if (mounted) setState(() => _task = t);
  }

  Future<void> _run() async {
    final AiPipelineTask? task = _task;
    if (task == null || _running) return;
    setState(() {
      _running = true;
      _cancelRequested = false;
    });
    try {
      final AiPipelineService service = ref.read(aiPipelineServiceProvider);
      await service.run(
        task,
        isCancelled: () => _cancelRequested,
        onProgress: () {
          if (mounted) setState(() {});
          _scrollToBottom();
        },
      );
    } catch (error) {
      if (mounted) {
        AppToast.error(context, '流水线运行失败：$error');
      }
    } finally {
      _running = false;
      if (mounted) {
        setState(() {});
        try {
          await _load();
        } catch (error) {
          if (mounted) {
            AppToast.error(context, '任务状态刷新失败：$error');
          }
        }
      }
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
    final List<PipelineChapter> sorted = List<PipelineChapter>.from(
      task.chapters,
    )..sort((a, b) => a.idx.compareTo(b.idx));
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
    final File file = File(
      '${dir.path}${Platform.pathSeparator}${task.id}.txt',
    );
    await file.writeAsString(buf.toString(), flush: true);
    if (!mounted) return;
    AppToast.success(context, '已导出：${file.path}');
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
      AppToast.error(context, '导入失败：$e');
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
            padding: const EdgeInsets.all(AppTokens.s3),
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
          // 分段切换：日志 ↔ 质量。质量视图与日志平级，不是日志的一部分。
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.s3,
              AppTokens.s2,
              AppTokens.s3,
              0,
            ),
            child: SegmentedButton<int>(
              segments: const <ButtonSegment<int>>[
                ButtonSegment<int>(
                  value: 0,
                  icon: Icon(Icons.terminal, size: 15),
                  label: Text('运行日志'),
                ),
                ButtonSegment<int>(
                  value: 1,
                  icon: Icon(Icons.fact_check_outlined, size: 15),
                  label: Text('质量'),
                ),
              ],
              selected: <int>{_view},
              showSelectedIcon: false,
              onSelectionChanged: (Set<int> s) => setState(() => _view = s.first),
            ),
          ),
          Expanded(
            child: _view == 0
                ? ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: task.log.length,
                    itemBuilder: (BuildContext context, int index) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        task.log[index],
                        style: AppFonts.text(
                          AppInk.of(context).inkSoft,
                          size: 12,
                          monoFace: true,
                        ),
                      ),
                    ),
                  )
                : PipelineQualityPanel(task: task),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.s3),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: _running
                        ? OutlinedButton.icon(
                            icon: const Icon(Icons.stop),
                            label: const Text('停止'),
                            onPressed: () =>
                                setState(() => _cancelRequested = true),
                          )
                        : FilledButton.icon(
                            icon: const Icon(Icons.play_arrow),
                            label: Text(task.resumable ? '继续生成' : '重新开始'),
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
    final AppInk ink = AppInk.of(context);
    final (String text, Color color) = switch (status) {
      PipelineTaskStatus.running => ('运行中', ink.primary),
      PipelineTaskStatus.done => ('已完成', ink.success),
      PipelineTaskStatus.failed => ('失败', ink.danger),
      PipelineTaskStatus.cancelled => ('已取消', ink.warn),
      PipelineTaskStatus.idle => ('待运行', ink.inkFaint),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppTokens.r3),
      ),
      child: Text(text, style: AppFonts.text(color, size: 12)),
    );
  }
}
