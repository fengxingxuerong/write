import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:novel_writer/core/constants/app_constants.dart';

/// 自动保存混入。
///
/// 为编辑器提供**防抖自动保存**能力：输入变化后延时 [AppConstants.autosaveDebounceMs]
/// （主理人裁定 3 秒）落盘；[flushNow] 用于失焦 / 退出时立即保存。
///
/// 用法：
/// 1. 在 State.initState 中调用 [initAutosave] 传入保存函数；
/// 2. 文本变化时调用 [scheduleSave]；
/// 3. 失焦 / dispose 时调用 [flushNow]。
mixin AutosaveMixin<T extends StatefulWidget> on State<T> {
  Timer? _saveTimer;
  String? _pending;

  /// 保存函数（由宿主注入），接收待保存的正文。
  Future<void> Function(String)? _saveFn;

  /// 初始化自动保存（注入保存函数）。
  void initAutosave(Future<void> Function(String) saveFn) {
    _saveFn = saveFn;
  }

  /// 安排一次防抖保存。
  void scheduleSave(String content) {
    _pending = content;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: AppConstants.autosaveDebounceMs),
      _flush,
    );
  }

  /// 立即保存（失焦 / 退出时调用）。
  Future<void> flushNow() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final String? content = _pending;
    _pending = null;
    if (content != null && _saveFn != null) {
      try {
        await _saveFn!(content);
      } catch (e) {
        // 保存失败时静默，避免中断交互；上层可在下次输入重试。
        debugPrint('自动保存失败：$e');
      }
    }
  }

  Future<void> _flush() async {
    await flushNow();
  }

  @override
  void dispose() {
    // 退出时尽力保存（fire-and-forget，因 dispose 无法 await）。
    unawaited(flushNow());
    _saveTimer?.cancel();
    super.dispose();
  }
}
