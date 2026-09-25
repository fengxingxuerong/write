import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/ai_pipeline_service.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/security/secret_store.dart';
import 'package:novel_writer/core/theme/app_theme.dart';
import 'package:novel_writer/features/ai_pipeline/ai_pipeline_pages.dart';

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
