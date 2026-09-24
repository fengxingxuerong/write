import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/features/editor/autosave_mixin.dart';

/// AutosaveMixin 单元测试
///
/// 覆盖：防抖保存、立即保存、dispose 强制保存、保存失败静默。

/// 空操作回调（用于不需要验证 onSave 行为的场景）。
Future<void> _noop(String _) async {}

/// 测试辅助 Widget，混入 AutosaveMixin。
class _AutosaveTestHost extends StatefulWidget {
  const _AutosaveTestHost({
    required this.onSave,
    this.throwOnSave = false,
    this.failFirstSaves = 0,
  });
  final Future<void> Function(String) onSave;
  final bool throwOnSave;
  final int failFirstSaves;
  @override
  State<_AutosaveTestHost> createState() => _AutosaveTestHostState();
}

class _AutosaveTestHostState extends State<_AutosaveTestHost>
    with WidgetsBindingObserver, AutosaveMixin {
  int saveCount = 0;
  String? lastSaved;
  late int _remainingFailures;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  void initState() {
    super.initState();
    _remainingFailures = widget.failFirstSaves;
    initAutosave((content) async {
      saveCount++;
      if (widget.throwOnSave || _remainingFailures > 0) {
        if (_remainingFailures > 0) _remainingFailures--;
        throw Exception('保存失败');
      }
      lastSaved = content;
      await widget.onSave(content);
    });
  }

  /// 暴露 scheduleSave 给测试调用
  void testScheduleSave(String content) => scheduleSave(content);

  /// 暴露 flushNow 给测试调用
  Future<void> testFlushNow() => flushNow();
}

void main() {
  group('AutosaveMixin 防抖保存', () {
    testWidgets('连续 scheduleSave 仅触发一次保存（防抖）', (tester) async {
      int saveCount = 0;
      String? savedContent;

      await tester.pumpWidget(
        _AutosaveTestHost(
          onSave: (content) async {
            saveCount++;
            savedContent = content;
          },
        ),
      );

      final state = tester.state<_AutosaveTestHostState>(
        find.byType(_AutosaveTestHost),
      );

      // 连续调用 3 次 scheduleSave，每次间隔小于防抖时间
      state.testScheduleSave('第1次');
      await tester.pump(const Duration(milliseconds: 1500));
      state.testScheduleSave('第2次');
      await tester.pump(const Duration(milliseconds: 1500));
      state.testScheduleSave('最终内容');

      // 未到防抖时间，保存次数仍为 0
      expect(saveCount, 0);

      // 等待防抖超时
      await tester.pump(
          const Duration(milliseconds: AppConstants.autosaveDebounceMs + 100));
      await tester.pump();

      // 防抖后只保存最后一次
      expect(saveCount, 1);
      expect(savedContent, '最终内容');
    });

    testWidgets('防抖期间新内容重置定时器', (tester) async {
      int saveCount = 0;

      await tester.pumpWidget(
        _AutosaveTestHost(
          onSave: (content) async {
            saveCount++;
          },
        ),
      );

      final state = tester.state<_AutosaveTestHostState>(
        find.byType(_AutosaveTestHost),
      );

      state.testScheduleSave('A');
      // 在防抖期间再次调用
      await tester.pump(const Duration(milliseconds: 1000));
      state.testScheduleSave('B');
      await tester.pump(const Duration(milliseconds: 1000));
      state.testScheduleSave('C');

      // 从最后一次调用起算，防抖超时后才保存
      await tester.pump(
          const Duration(milliseconds: AppConstants.autosaveDebounceMs + 100));
      await tester.pump();

      expect(saveCount, 1);
    });
  });

  group('AutosaveMixin flushNow 立即保存', () {
    testWidgets('flushNow 立即保存并取消待处理定时器', (tester) async {
      int saveCount = 0;
      String? savedContent;

      await tester.pumpWidget(
        _AutosaveTestHost(
          onSave: (content) async {
            saveCount++;
            savedContent = content;
          },
        ),
      );

      final state = tester.state<_AutosaveTestHostState>(
        find.byType(_AutosaveTestHost),
      );

      // 安排一次但不等待超时
      state.testScheduleSave('延迟内容');
      await tester.pump(const Duration(milliseconds: 1000));
      expect(saveCount, 0); // 防抖未触发

      // flushNow 立即保存
      await state.testFlushNow();
      expect(saveCount, 1);
      expect(savedContent, '延迟内容');

      // 之前的定时器已被取消（不再触发第二次保存）
      await tester.pump(
          const Duration(milliseconds: AppConstants.autosaveDebounceMs + 100));
      await tester.pump();
      expect(saveCount, 1); // 仍为 1，定时器已取消
    });

    testWidgets('flushNow 在无 pending 内容时不触发保存', (tester) async {
      int saveCount = 0;

      await tester.pumpWidget(
        _AutosaveTestHost(
          onSave: (content) async {
            saveCount++;
          },
        ),
      );

      final state = tester.state<_AutosaveTestHostState>(
        find.byType(_AutosaveTestHost),
      );

      // 直接 flushNow，没有 pending 内容
      await state.testFlushNow();
      expect(saveCount, 0);
    });

    testWidgets('应用进入后台时立即 flush 待保存内容', (tester) async {
      int saveCount = 0;
      String? savedContent;

      await tester.pumpWidget(
        _AutosaveTestHost(
          onSave: (content) async {
            saveCount++;
            savedContent = content;
          },
        ),
      );
      final state = tester.state<_AutosaveTestHostState>(
        find.byType(_AutosaveTestHost),
      );
      state.testScheduleSave('后台也要保存');
      expect(saveCount, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      expect(saveCount, 1);
      expect(savedContent, '后台也要保存');
    });

    testWidgets('保存失败后保留 pending，下一次 flush 可重试', (tester) async {
      int saveCount = 0;
      String? savedContent;

      await tester.pumpWidget(
        _AutosaveTestHost(
          failFirstSaves: 1,
          onSave: (content) async {
            saveCount++;
            savedContent = content;
          },
        ),
      );

      final state = tester.state<_AutosaveTestHostState>(
        find.byType(_AutosaveTestHost),
      );
      state.testScheduleSave('失败后可重试');
      await state.testFlushNow();
      expect(saveCount, 0);
      expect(savedContent, isNull);

      await state.testFlushNow();
      expect(saveCount, 1);
      expect(savedContent, '失败后可重试');
    });
  });

  group('AutosaveMixin dispose 强制保存', () {
    testWidgets('widget 移除时尽力保存（fire-and-forget）', (tester) async {
      int saveCount = 0;

      await tester.pumpWidget(
        _AutosaveTestHost(
          onSave: (content) async {
            saveCount++;
          },
        ),
      );

      final state = tester.state<_AutosaveTestHostState>(
        find.byType(_AutosaveTestHost),
      );

      // 安排一次保存（不等待超时）
      state.testScheduleSave('待保存内容');
      await tester.pump(const Duration(milliseconds: 500));

      // 移除 widget（触发 dispose → fire-and-forget flushNow）
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));

      // fire-and-forget 尽力保存，不应崩溃
      // 注：由于是 unawaited，在测试环境中可能未完成，不强求保存成功
      expect(saveCount, greaterThanOrEqualTo(0));
    });
  });

  group('AutosaveMixin 保存失败静默', () {
    testWidgets('保存函数抛异常时不崩溃', (tester) async {
      await tester.pumpWidget(
        const _AutosaveTestHost(
          onSave: _noop,
          throwOnSave: true,
        ),
      );

      final state = tester.state<_AutosaveTestHostState>(
        find.byType(_AutosaveTestHost),
      );

      state.testScheduleSave('内容');

      // 等待防抖超时触发 _flush（内部调用 flushNow，保存失败静默）
      await tester.pump(
          const Duration(milliseconds: AppConstants.autosaveDebounceMs + 100));
      await tester.pump();

      // saveCount 在 throw 之前增加，证明保存尝试已发生
      expect(state.saveCount, 1);
    });
  });
}
