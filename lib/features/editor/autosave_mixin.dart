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
mixin AutosaveMixin<T extends StatefulWidget> on State<T>, WidgetsBindingObserver {
  Timer? _saveTimer;
  String? _pending;
  Future<void>? _saveInFlight;
  bool _disposed = false;

  /// 保存函数（由宿主注入），接收待保存的正文。
  Future<void> Function(String)? _saveFn;

  /// 初始化自动保存（注入保存函数）。
  void initAutosave(Future<void> Function(String) saveFn) {
    _saveFn = saveFn;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(flushNow());
    }
  }

  /// 安排一次防抖保存。
  void scheduleSave(String content) {
    if (_disposed) return;
    _pending = content;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: AppConstants.autosaveDebounceMs),
      _flush,
    );
  }

  /// 立即保存（失焦 / 退出时调用）。
  ///
  /// 保存失败时保留 [_pending]，下一次防抖触发或显式 flush 会重试，避免失败后
  /// 静默丢掉尚未落盘的内容。并发 flush 共用同一个 in-flight Future。
  Future<void> flushNow({bool allowDisposed = false}) async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final Future<void>? active = _saveInFlight;
    if (active != null) {
      try {
        await active;
      } catch (_) {
        // 失败内容仍在 _pending 中，下面继续尝试一次。
      }
    }
    if (_disposed && !allowDisposed) return;
    final String? content = _pending;
    if (content == null || _saveFn == null) return;
    final Future<void> save = _saveFn!(content);
    _saveInFlight = save;
    try {
      await save;
      if (identical(_pending, content)) _pending = null;
    } catch (e) {
      // 保留 content，下一次 flush/定时器会重试。
      debugPrint('自动保存失败：$e');
    } finally {
      if (identical(_saveInFlight, save)) _saveInFlight = null;
    }
  }

  Future<void> _flush() async {
    await flushNow();
  }

  @override
  void dispose() {
    // 退出时尽力保存（fire-and-forget，因 dispose 无法 await）。
    final Future<void> pendingFlush = flushNow(allowDisposed: true);
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    unawaited(pendingFlush);
    super.dispose();
  }
}
