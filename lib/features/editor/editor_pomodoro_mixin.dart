import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 编辑器番茄钟（25 分钟专注计时）。
///
/// 混入 [ConsumerState]，提供番茄钟状态与操作。
mixin EditorPomodoroMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  // ---- 番茄钟状态 ----
  Timer? pomodoroTimer;
  int pomodoroRemainSec = 0;
  bool pomodoroRunning = false;
  static const int _pomodoroTotalSec = 25 * 60;

  /// 切换番茄钟启停。
  void togglePomodoro() {
    if (pomodoroRunning) {
      pomodoroTimer?.cancel();
      setState(() => pomodoroRunning = false);
      return;
    }
    setState(() {
      pomodoroRunning = true;
      pomodoroRemainSec = _pomodoroTotalSec;
    });
    pomodoroTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (pomodoroRemainSec <= 1) {
        pomodoroTimer?.cancel();
        setState(() {
          pomodoroRunning = false;
          pomodoroRemainSec = 0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🍅 番茄钟结束，休息一下吧！')),
        );
        return;
      }
      setState(() => pomodoroRemainSec -= 1);
    });
  }

  /// 番茄钟剩余时间文本（mm:ss）。
  String get pomodoroLabel {
    final int m = pomodoroRemainSec ~/ 60;
    final int s = pomodoroRemainSec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// 释放番茄钟计时器。
  void disposePomodoro() {
    pomodoroTimer?.cancel();
  }
}
