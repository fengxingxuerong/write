import 'package:flutter/material.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/widgets/app_card.dart';

/// 页面外壳：统一最大宽度、外边距与滚动节奏。
///
/// 桌面窗口可以拉得很宽，正文/列表不约束宽度会出现一行 120 字的情况；
/// 所有非编辑器页面都应走这个壳。
class PageShell extends StatelessWidget {
  /// 构造。
  const PageShell({
    super.key,
    required this.child,
    this.maxWidth = AppTokens.maxWidthPanel,
    this.padding = AppTokens.padPage,
    this.scrollable = false,
    this.centerWhenEmpty = false,
  });

  /// 内容。
  final Widget child;

  /// 内容最大宽度。
  final double maxWidth;

  /// 外边距。
  final EdgeInsetsGeometry padding;

  /// 是否整体可滚动（简单页面用；复杂页面自带 ListView 时保持 false）。
  final bool scrollable;

  /// 窄屏时是否居中留白。
  final bool centerWhenEmpty;

  @override
  Widget build(BuildContext context) {
    Widget body = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(padding: padding, child: child),
      ),
    );
    if (scrollable) {
      body = SingleChildScrollView(child: body);
    }
    if (centerWhenEmpty) {
      body = Center(child: body);
    }
    return body;
  }
}

/// 可拖拽分栏（桌面端写作界面的骨架）。
///
/// 三栏：左（章节）/ 中（编辑器）/ 右（设定）。左右栏可拖宽、可折叠，
/// 分隔条 hover 时高亮并给出左右拖拽光标——不写这个，用户根本不知道能拖。
class ResizablePanes extends StatefulWidget {
  /// 构造。
  const ResizablePanes({
    super.key,
    required this.left,
    required this.center,
    this.right,
    this.initialLeftWidth = 268,
    this.initialRightWidth = 300,
    this.minPaneWidth = 200,
    this.maxPaneWidth = 460,
    this.onLeftWidthChanged,
    this.onRightWidthChanged,
  });

  /// 左栏。
  final Widget left;

  /// 中栏（自适应剩余宽度）。
  final Widget center;

  /// 右栏（可为空）。
  final Widget? right;

  /// 左栏初始宽度。
  final double initialLeftWidth;

  /// 右栏初始宽度。
  final double initialRightWidth;

  /// 单栏最小宽度。
  final double minPaneWidth;

  /// 单栏最大宽度。
  final double maxPaneWidth;

  /// 左栏宽度变化回调（供上层持久化）。
  final ValueChanged<double>? onLeftWidthChanged;

  /// 右栏宽度变化回调。
  final ValueChanged<double>? onRightWidthChanged;

  @override
  State<ResizablePanes> createState() => _ResizablePanesState();
}

class _ResizablePanesState extends State<ResizablePanes> {
  late double _left = widget.initialLeftWidth;
  late double _right = widget.initialRightWidth;

  void _resize({required bool leftSide, required double delta}) {
    setState(() {
      if (leftSide) {
        _left = (_left + delta).clamp(widget.minPaneWidth, widget.maxPaneWidth);
        widget.onLeftWidthChanged?.call(_left);
      } else {
        _right =
            (_right - delta).clamp(widget.minPaneWidth, widget.maxPaneWidth);
        widget.onRightWidthChanged?.call(_right);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 窄屏（<900）不再分栏：交给上层自己降级为单栏 + 底部导航。
        if (c.maxWidth < 900) {
          return Row(children: <Widget>[Expanded(child: widget.center)]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(width: _left, child: widget.left),
            _PaneDivider(
              ink: ink,
              onDrag: (double dx) => _resize(leftSide: true, delta: dx),
            ),
            Expanded(child: widget.center),
            if (widget.right != null) ...<Widget>[
              _PaneDivider(
                ink: ink,
                onDrag: (double dx) => _resize(leftSide: false, delta: dx),
              ),
              SizedBox(width: _right, child: widget.right),
            ],
          ],
        );
      },
    );
  }
}

/// 分栏拖拽条：6px 命中区 + hover 高亮 + 双击复位由上层处理。
class _PaneDivider extends StatefulWidget {
  const _PaneDivider({required this.ink, required this.onDrag});

  final AppInk ink;
  final ValueChanged<double> onDrag;

  @override
  State<_PaneDivider> createState() => _PaneDividerState();
}

class _PaneDividerState extends State<_PaneDivider> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (DragUpdateDetails d) =>
            widget.onDrag(d.delta.dx),
        child: AnimatedContainer(
          duration: AppTokens.fast,
          width: 6,
          color: _hover
              ? widget.ink.primary.withValues(alpha: 0.30)
              : widget.ink.divider,
        ),
      ),
    );
  }
}

/// 工具条分组容器：把同一类动作装进一个圆角容器，替代 AppBar 上散开的 12 个图标。
class ActionGroup extends StatelessWidget {
  /// 构造。
  const ActionGroup({super.key, required this.children, this.padding});

  /// 组内控件。
  final List<Widget> children;

  /// 内边距。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return Container(
      padding: padding ?? const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: ink.surfaceRaised.withValues(alpha: ink.dark ? 0.6 : 0.8),
        borderRadius: BorderRadius.circular(AppTokens.r2),
        border: Border.all(color: ink.border, width: AppTokens.hairline),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// 图标 + 文字的工具按钮（顶栏用；比裸 IconButton 多一个可读标签）。
class ToolButton extends StatelessWidget {
  /// 构造。
  const ToolButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.tooltip,
    this.showLabel = false,
    this.active = false,
    this.tone,
  });

  /// 图标。
  final IconData icon;

  /// 标签。
  final String label;

  /// 点击。
  final VoidCallback? onPressed;

  /// 悬浮提示（不显示标签时自动用 label）。
  final String? tooltip;

  /// 是否显示文字。
  final bool showLabel;

  /// 选中态。
  final bool active;

  /// 强调色（默认主色）。
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Color c = active ? (tone ?? ink.primary) : ink.inkSoft;
    final Widget child = showLabel
        ? Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.s3, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 16, color: c),
                const SizedBox(width: AppTokens.s2),
                Text(label,
                    style: AppFonts.text(c,
                        size: 13,
                        weight: active ? FontWeight.w600 : FontWeight.w500,
                        height: 1.3)),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 18, color: c),
          );
    return Tooltip(
      message: tooltip ?? label,
      child: Hoverable(
        onTap: onPressed,
        selected: active,
        borderRadius: BorderRadius.circular(AppTokens.r2 - 2),
        child: child,
      ),
    );
  }
}
