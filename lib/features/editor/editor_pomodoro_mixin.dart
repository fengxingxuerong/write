import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/widgets/app_feedback.dart';

/// 编辑器番茄钟（25 分钟专注计时）。
///
/// 混入 [ConsumerState]，提供番茄钟状态与操作。
///
/// 修复：使用 [ValueNotifier] 隔离计时器回调，避免每秒 setState 导致整页重建；
/// 消费端通过 [ValueListenableBuilder] 仅刷新时间标签。
mixin EditorPomodoroMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  // ---- 番茄钟状态 ----
  Timer? _pomodoroTimer;
  static const int _pomodoroTotalSec = 25 * 60;

  /// 剩余秒数通知器（值变化仅触发时间标签重建，不触发整个页面重建）。
  final ValueNotifier<int> _pomodoroRemainNotifier = ValueNotifier<int>(0);

  /// 运行状态通知器。
  final ValueNotifier<bool> _pomodoroRunningNotifier =
      ValueNotifier<bool>(false);

  /// 是否正在运行。
  bool get pomodoroRunning => _pomodoroRunningNotifier.value;

  /// 剩余秒数。
  int get pomodoroRemainSec => _pomodoroRemainNotifier.value;

  /// 剩余秒数通知器（供 ValueListenableBuilder 使用）。
  ValueNotifier<int> get podomoroRemainNotifier => _pomodoroRemainNotifier;

  /// 运行状态通知器。
  ValueNotifier<bool> get podomoroRunningNotifier => _pomodoroRunningNotifier;

  /// 切换番茄钟启停。
  void togglePomodoro() {
    if (pomodoroRunning) {
      _pomodoroTimer?.cancel();
      _pomodoroRunningNotifier.value = false;
      return;
    }
    _pomodoroRunningNotifier.value = true;
    _pomodoroRemainNotifier.value = _pomodoroTotalSec;
    _pomodoroTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_pomodoroRemainNotifier.value <= 1) {
        _pomodoroTimer?.cancel();
        _pomodoroRunningNotifier.value = false;
        _pomodoroRemainNotifier.value = 0;
        // 使用 addPostFrameCallback 避免在 build 期间触发 SnackBar
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            AppToast.info(context, '🍅 番茄钟结束，休息一下吧！');
          }
        });
        return;
      }
      _pomodoroRemainNotifier.value = _pomodoroRemainNotifier.value - 1;
    });
  }

  /// 番茄钟剩余时间文本（mm:ss）。
  String get pomodoroLabel {
    final int m = _pomodoroRemainNotifier.value ~/ 60;
    final int s = _pomodoroRemainNotifier.value % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// 释放番茄钟计时器。
  void disposePomodoro() {
    _pomodoroTimer?.cancel();
    _pomodoroRemainNotifier.dispose();
    _pomodoroRunningNotifier.dispose();
  }
}
