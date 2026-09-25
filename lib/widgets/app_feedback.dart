import 'dart:async';

import 'package:flutter/material.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/widgets/app_card.dart';

/// 统一的消息条出口。
///
/// 全仓原来有 20+ 处手写 `ScaffoldMessenger.of(context).showSnackBar(SnackBar(...))`，
/// 时长、颜色、图标各写一套；收敛到这里，成功/警告/错误一眼分得清。
class AppToast {
  const AppToast._();

  /// 默认停留时长：短到不打断打字，长到看得清。
  static const Duration _short = Duration(seconds: 2);
  static const Duration _long = Duration(seconds: 4);

  /// 提示（中性）。
  static void info(BuildContext context, String message,
          {Duration? duration}) =>
      _show(context, message, BadgeTone.neutral, null, null, duration);

  /// 成功。
  static void success(BuildContext context, String message,
          {Duration? duration}) =>
      _show(context, message, BadgeTone.success, null, null, duration);

  /// 警告（可以继续，但要留意）。
  static void warn(BuildContext context, String message,
          {Duration? duration}) =>
      _show(context, message, BadgeTone.warn, null, null, duration);

  /// 错误（默认停留更久，并允许「重试」动作）。
  static void error(BuildContext context, String message,
          {String? actionLabel, VoidCallback? onAction}) =>
      _show(context, message, BadgeTone.danger, actionLabel, onAction, null);

  static void _show(
    BuildContext context,
    String message,
    BadgeTone tone,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  ) {
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: duration ?? (tone == BadgeTone.danger ? _long : _short),
          content: _ToastBody(
            message: message,
            tone: tone,
            actionLabel: actionLabel,
            onAction: onAction,
          ),
        ),
      );
  }
}

class _ToastBody extends StatelessWidget {
  const _ToastBody({
    required this.message,
    required this.tone,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final BadgeTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Color c = TintBadge.colorOf(tone, ink);
    final IconData icon = switch (tone) {
      BadgeTone.success => Icons.check_circle_outline,
      BadgeTone.warn => Icons.warning_amber_rounded,
      BadgeTone.danger => Icons.error_outline,
      BadgeTone.accent => Icons.auto_awesome,
      BadgeTone.primary => Icons.info_outline,
      BadgeTone.neutral => Icons.info_outline,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Container(
          width: 3,
          height: 20,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: AppTokens.s3),
        Icon(icon, size: 17, color: c),
        const SizedBox(width: AppTokens.s2 + 2),
        Expanded(
          child: Text(
            message,
            style: AppFonts.text(ink.paper, size: 13.5, height: 1.45),
          ),
        ),
        if (actionLabel != null && onAction != null)
          Padding(
            padding: const EdgeInsets.only(left: AppTokens.s3),
            child: InkWell(
              onTap: onAction,
              borderRadius: BorderRadius.circular(AppTokens.r1),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.s2, vertical: AppTokens.s1),
                child: Text(
                  actionLabel!,
                  style: AppFonts.text(c,
                      size: 13, weight: FontWeight.w700, height: 1.3),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 行内状态行：图标 + 文案 + 可选耗时/进度，用于生成过程与质检结果。
class StatusLine extends StatelessWidget {
  /// 构造。
  const StatusLine({
    super.key,
    required this.text,
    this.tone = BadgeTone.neutral,
    this.trailing,
    this.busy = false,
    this.dense = false,
  });

  /// 文案。
  final String text;

  /// 色调。
  final BadgeTone tone;

  /// 右侧控件（耗时、分数、按钮）。
  final Widget? trailing;

  /// 转圈（进行中）。
  final bool busy;

  /// 紧凑。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Color c = TintBadge.colorOf(tone, ink);
    return Padding(
      padding: EdgeInsets.symmetric(
          vertical: dense ? 2 : AppTokens.s2 - 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 18,
            child: busy
                ? Padding(
                    padding: const EdgeInsets.only(top: 2, right: 3),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.8, color: c),
                    ),
                  )
                : Icon(_iconOf(tone), size: 14, color: c),
          ),
          const SizedBox(width: AppTokens.s2),
          Expanded(
            child: Text(
              text,
              style: AppFonts.text(
                ink.inkSoft,
                size: dense ? 12.5 : 13.5,
                height: 1.55,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }

  static IconData _iconOf(BadgeTone tone) => switch (tone) {
        BadgeTone.success => Icons.check,
        BadgeTone.warn => Icons.priority_high_rounded,
        BadgeTone.danger => Icons.close,
        BadgeTone.accent => Icons.auto_awesome,
        BadgeTone.primary => Icons.radio_button_unchecked,
        BadgeTone.neutral => Icons.remove,
      };
}

/// 细进度条 + 百分比（生成进度用，替代默认那条粗线）。
class ThinProgress extends StatelessWidget {
  /// 构造。
  const ThinProgress({
    super.key,
    required this.value,
    this.label,
    this.color,
    this.indeterminate = false,
  });

  /// 进度 0~1（indeterminate 时忽略）。
  final double value;

  /// 右侧标签。
  final String? label;

  /// 覆盖颜色。
  final Color? color;

  /// 不确定进度。
  final bool indeterminate;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Color c = color ?? ink.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 5,
            child: indeterminate
                ? LinearProgressIndicator(
                    color: c,
                    backgroundColor: ink.divider,
                    minHeight: 5,
                  )
                : TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                        begin: 0, end: value.clamp(0.0, 1.0).toDouble()),
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    builder: (BuildContext context, double v, Widget? _) {
                      return Stack(
                        children: <Widget>[
                          Container(
                              height: 5,
                              color: ink.divider,
                              width: double.infinity),
                          FractionallySizedBox(
                            widthFactor: v,
                            child: Container(height: 5, color: c),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ),
        if (label != null) ...<Widget>[
          const SizedBox(height: AppTokens.s2 - 2),
          Text(
            label!,
            style: AppFonts.text(ink.inkSoft, size: 12, height: 1.4),
          ),
        ],
      ],
    );
  }
}

/// 计时器：给「AI 正在写」这类操作用，避免用户以为卡死。
class ElapsedTicker extends StatefulWidget {
  /// 构造。
  const ElapsedTicker({
    super.key,
    required this.running,
    this.prefix = '已用',
    this.onElapsed,
  });

  /// 是否计时中。
  final bool running;

  /// 前缀。
  final String prefix;

  /// 每秒回调（秒数）。
  final ValueChanged<int>? onElapsed;

  @override
  State<ElapsedTicker> createState() => _ElapsedTickerState();
}

class _ElapsedTickerState extends State<ElapsedTicker> {
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    // 首次挂载即 running=true 时必须立刻计时；旧实现只在 didUpdateWidget
    // 启动定时器，导致「AI 正在写」第一次出现时计时不走。
    if (widget.running) _startTimer();
  }

  void _startTimer() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) return;
      setState(() => _seconds = t.tick);
      widget.onElapsed?.call(t.tick);
    });
  }

  @override
  void didUpdateWidget(covariant ElapsedTicker old) {
    super.didUpdateWidget(old);
    if (widget.running) {
      _startTimer();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    if (_seconds <= 0) return const SizedBox.shrink();
    final String text = _seconds < 60
        ? '${widget.prefix} ${_seconds}s'
        : '${widget.prefix} ${_seconds ~/ 60}m${(_seconds % 60).toString().padLeft(2, '0')}s';
    return Text(
      text,
      style: AppFonts.text(ink.inkFaint,
          size: 12, height: 1.3, monoFace: true),
    );
  }
}
