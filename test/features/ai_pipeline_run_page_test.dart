import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/ai_pipeline_service.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/security/secret_store.dart';
import 'package:novel_writer/core/theme/app_theme.dart';
import 'package:novel_writer/features/ai_pipeline/ai_pipeline_pages.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 构造一个已配置好的角色配置（missingRoles 守卫要求链上至少一个已配置端点）。
AiRoleConfig configuredRole(AiRole role) => AiRoleConfig(
      role: role,
      llm: const LlmConfig(
        provider: LlmProvider.openaiCompatible,
        baseUrl: 'https://api.example.com/v1',
        model: 'test-model',
        apiKey: 'sk-test',
      ),
    );

/// 五角色全部配置好的流水线配置。
AiPipelineConfig allConfigured() => AiPipelineConfig(
      totalWords: 100000,
      maxChapters: 40,
      roles: <AiRole, AiRoleConfig>{
        for (final AiRole r in AiRole.values) r: configuredRole(r),
      },
    );

/// 最小可挂载的 GoRouter。
///
/// 注意 `initialLocation: '/'` 必须映射到真实的 [AiPipelineHomePage]——若像
/// 占位 SizedBox 那样返回空组件，被测页面根本不会进树，所有断言都会「0 命中」
/// 而看起来像功能坏了。
GoRouter _stubRouter() => GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(path: '/', builder: (_, __) => const AiPipelineHomePage()),
        GoRoute(
          path: '/ai-pipeline',
          builder: (_, __) => const AiPipelineHomePage(),
        ),
        GoRoute(
          path: '/ai-pipeline/config',
          builder: (_, __) => const AiPipelineConfigPage(),
        ),
        GoRoute(
          path: '/ai-pipeline/run/:id',
          builder: (_, __) => const SizedBox.shrink(),
        ),
        GoRoute(path: '/novel/:id', builder: (_, __) => const SizedBox.shrink()),
      ],
    );

void main() {
  testWidgets('service.run 异常后恢复按钮、显示错误并刷新任务状态', (WidgetTester tester) async {
    final AiPipelineTask task = AiPipelineTask(
      id: 'ui-run-error',
      config: const AiPipelineConfig(totalWords: 100),
      outline: const <String, dynamic>{'title': '异常恢复测试'},
      createdAt: DateTime(2026, 9, 25),
    );
    final _FakePipelineStorage storage = _FakePipelineStorage(task);
    final _ControlledPipelineService service = _ControlledPipelineService(
      storage,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          pipelineStorageProvider.overrideWithValue(storage),
          aiPipelineServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const AiPipelineRunPage(taskId: 'ui-run-error'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('继续生成'), findsOneWidget);
    await tester.tap(find.text('继续生成'));
    await tester.pump();
    expect(find.text('停止'), findsOneWidget);
    expect(service.runCount, 1);

    service.runs.single.completeError(StateError('模拟运行异常'));
    await tester.pump();
    await tester.pump();

    expect(find.text('停止'), findsNothing);
    expect(find.text('继续生成'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    expect(find.textContaining('流水线运行失败：Bad state: 模拟运行异常'), findsOneWidget);
    expect(storage.loadCount, 2, reason: '异常结束后也必须刷新持久化状态');

    // 可再次运行，证明 _running 确实已复位。
    await tester.tap(find.text('继续生成'));
    await tester.pump();
    expect(service.runCount, 2);
    expect(find.text('停止'), findsOneWidget);
    service.runs.last.complete();
    await tester.pump();
  });

  group('首页：无任务时的空态', () {
    testWidgets('没有任何流水线任务时展示引导文案而非报错',
        (WidgetTester tester) async {
      final _ListPipelineStorage storage = _ListPipelineStorage(<AiPipelineTask>[]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[pipelineStorageProvider.overrideWithValue(storage)],
          child: MaterialApp.router(
            theme: AppTheme.light,
            routerConfig: _stubRouter(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('还没有生成任务'), findsOneWidget);
      expect(
        find.text('配置多模型角色，一键生成完整长篇小说'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('首页：任务列表与状态徽标', () {
    testWidgets('各状态映射到正确的中文徽标（守卫文案与状态枚举一致）',
        (WidgetTester tester) async {
      // 五种状态全覆盖：任一状态漏映射都会在此失败（switch 写错分支即红）。
      final Map<PipelineTaskStatus, String> expected =
          <PipelineTaskStatus, String>{
        PipelineTaskStatus.idle: '待运行',
        PipelineTaskStatus.running: '运行中',
        PipelineTaskStatus.done: '已完成',
        PipelineTaskStatus.failed: '失败',
        PipelineTaskStatus.cancelled: '已取消',
      };
      for (final MapEntry<PipelineTaskStatus, String> e in expected.entries) {
        final AiPipelineTask task = AiPipelineTask(
          id: 'task-${e.key.name}',
          config: allConfigured(),
          status: e.key,
          outline: <String, dynamic>{'title': '《${e.key.name}》'},
          createdAt: DateTime(2026, 10, 1),
        );
        final _ListPipelineStorage storage =
            _ListPipelineStorage(<AiPipelineTask>[task]);
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              pipelineStorageProvider.overrideWithValue(storage),
            ],
            child: MaterialApp.router(
              theme: AppTheme.light,
              routerConfig: _stubRouter(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text(e.value), findsOneWidget,
            reason: '状态 ${e.key.name} 应显示「${e.value}」');
        expect(find.textContaining('0 章'), findsOneWidget,
            reason: '无正文的任务应显示 0 章');
      }
    });

    testWidgets('刷新按钮重新拉取任务列表', (WidgetTester tester) async {
      final _ListPipelineStorage storage = _ListPipelineStorage(<AiPipelineTask>[]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[pipelineStorageProvider.overrideWithValue(storage)],
          child: MaterialApp.router(
            theme: AppTheme.light,
            routerConfig: _stubRouter(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(storage.listCount, 1);

      // 第一次查询后新增一个任务，再点刷新——列表应重新拉取并出现该任务。
      storage.tasks.add(
        AiPipelineTask(
          id: 'later',
          config: allConfigured(),
          outline: const <String, dynamic>{'title': '后加入的任务'},
          createdAt: DateTime(2026, 10, 2),
        ),
      );
      await tester.tap(find.byTooltip('刷新'));
      await tester.pump();
      await tester.pump();

      expect(storage.listCount, 2, reason: '点刷新必须重新查询');
      expect(find.text('后加入的任务'), findsOneWidget);
    });
  });

  group('配置页：未配置模型时的守卫', () {
    testWidgets('角色未配置模型时给出警告且不创建任务',
        (WidgetTester tester) async {
      // 构造一个「角色全都没配端点」的存储，验证 _start 的守卫拦得住。
      final _ListPipelineStorage storage = _ListPipelineStorage(<AiPipelineTask>[]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[pipelineStorageProvider.overrideWithValue(storage)],
          child: MaterialApp.router(
            theme: AppTheme.light,
            routerConfig: _stubRouter(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 直接以配置页为根（不靠路由跳转，避免留下未完成的 push future）。
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[pipelineStorageProvider.overrideWithValue(storage)],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const AiPipelineConfigPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(AiPipelineConfigPage), findsOneWidget);
      // 「创建并开始生成」在 ListView 末尾。ListView 默认懒构建，未滚到的
      // 子树根本不存在（finder 会 No element），故先把列表滚到底再定位按钮。
      await tester.dragUntilVisible(
        find.text('创建并开始生成'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建并开始生成'));
      await tester.pump();
      await tester.pump();

      expect(storage.savedCount, 0, reason: '守卫拦截时不得落盘任何任务');
      expect(storage.savedRecentCount, 0,
          reason: '守卫拦截时不得写最近配置');
      expect(find.textContaining('未配置模型'), findsOneWidget);
    });
  });
}

/// 可控的 [PipelineStorage]：记录调用次数，支持增删任务。
class _ListPipelineStorage extends PipelineStorage {
  _ListPipelineStorage(this.tasks)
      : super('unused-pipeline-test-path', secretStore: InMemorySecretStore());

  final List<AiPipelineTask> tasks;
  int listCount = 0;
  int savedCount = 0;
  int savedRecentCount = 0;
  final List<String> deletedIds = <String>[];

  @override
  Future<List<AiPipelineTask>> listTasks() async {
    listCount++;
    return List<AiPipelineTask>.from(tasks);
  }

  @override
  Future<void> saveTask(AiPipelineTask task) async {
    savedCount++;
  }

  @override
  Future<void> saveRecentConfig(AiPipelineConfig config) async {
    savedRecentCount++;
  }

  @override
  Future<void> deleteTask(String id) async {
    deletedIds.add(id);
    tasks.removeWhere((AiPipelineTask e) => e.id == id);
  }

  @override
  Future<AiPipelineConfig?> loadRecentConfig() async => null;
}

class _FakePipelineStorage extends PipelineStorage {
  _FakePipelineStorage(this.task)
    : super('unused-pipeline-test-path', secretStore: InMemorySecretStore());

  final AiPipelineTask task;
  int loadCount = 0;

  @override
  Future<AiPipelineTask?> loadTask(String id) async {
    loadCount++;
    return task;
  }

  @override
  Future<void> saveTask(AiPipelineTask task) async {}
}

class _ControlledPipelineService extends AiPipelineService {
  _ControlledPipelineService(super.storage);

  final List<Completer<void>> runs = <Completer<void>>[];
  int runCount = 0;

  @override
  Future<void> run(
    AiPipelineTask task, {
    required bool Function() isCancelled,
    required void Function() onProgress,
  }) {
    runCount++;
    task
      ..status = PipelineTaskStatus.failed
      ..error = '模拟运行异常';
    final Completer<void> run = Completer<void>();
    runs.add(run);
    return run.future;
  }
}
