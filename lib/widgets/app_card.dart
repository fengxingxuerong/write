import 'package:flutter/material.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';

/// 桌面端 hover / 按下反馈容器。
///
/// Flutter 默认只在 Ink 系列组件上有 hover；列表卡片、封面块这类自定义容器
/// 需要它，否则鼠标在桌面端「点不到东西」的错觉很强。
class Hoverable extends StatefulWidget {
  /// 构造。
  const Hoverable({
    super.key,
    required this.child,
    this.onTap,
    this.onSecondaryTap,
    this.selected = false,
    this.borderRadius,
    this.padding,
    this.hoverColor,
    this.selectedColor,
    this.tooltip,
    this.lift = false,
  });

  /// 子内容。
  final Widget child;

  /// 主点击。
  final VoidCallback? onTap;

  /// 右键菜单。
  final VoidCallback? onSecondaryTap;

  /// 是否处于选中态。
  final bool selected;

  /// 圆角（默认取 [AppTokens.r2]）。
  final BorderRadius? borderRadius;

  /// 内边距。
  final EdgeInsetsGeometry? padding;

  /// 自定义 hover 底色。
  final Color? hoverColor;

  /// 自定义选中底色。
  final Color? selectedColor;

  /// 悬浮提示（包一层 Tooltip，省得调用方到处套）。
  final String? tooltip;

  /// 是否在悬浮时轻微上浮并抬升投影（卡片类内容用；工具条按钮不要开）。
  final bool lift;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final BorderRadius radius =
        widget.borderRadius ?? BorderRadius.circular(AppTokens.r2);
    final Color? bg = _pressed
        ? ink.hoverTint
        : widget.selected
            ? (widget.selectedColor ?? ink.selectTint)
            : _hover
                ? (widget.hoverColor ?? ink.hoverTint)
                : null;
    final bool tappable = widget.onTap != null || widget.onSecondaryTap != null;

    final bool lifted = widget.lift && tappable && _hover && !_pressed;
    Widget body = AnimatedContainer(
      duration: AppTokens.fast,
      curve: AppTokens.curve,
      padding: widget.padding,
      transform: lifted ? Matrix4.translationValues(0, -2, 0) : null,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: radius,
        boxShadow: lifted ? ink.shadow(raised: true) : null,
      ),
      child: widget.child,
    );

    if (widget.tooltip != null) {
      body = Tooltip(message: widget.tooltip!, child: body);
    }

    if (!tappable) {
      return MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: body,
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        onSecondaryTap: widget.onSecondaryTap,
        child: body,
      ),
    );
  }
}

/// 语义色小标签：达标 / 警告 / 红线 / 计数。
///
/// 只在「一眼要看到状态」的地方用；正文描述请回到文字，不要让界面变成彩灯板。
class TintBadge extends StatelessWidget {
  /// 构造。
  const TintBadge(
    this.label, {
    super.key,
    this.icon,
    this.tone = BadgeTone.neutral,
    this.dense = false,
  });

  /// 文案。
  final String label;

  /// 可选图标。
  final IconData? icon;

  /// 色调。
  final BadgeTone tone;

  /// 紧凑模式（列表行内）。
  final bool dense;

  /// 解析色调对应的颜色。
  static Color colorOf(BadgeTone tone, AppInk ink) => switch (tone) {
        BadgeTone.success => ink.success,
        BadgeTone.warn => ink.warn,
        BadgeTone.danger => ink.danger,
        BadgeTone.accent => ink.accent,
        BadgeTone.primary => ink.primary,
        BadgeTone.neutral => ink.inkFaint,
      };

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Color c = colorOf(tone, ink);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: dense ? AppTokens.s2 : AppTokens.s2 + 1,
          vertical: dense ? 1 : 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: ink.dark ? 0.20 : 0.11),
        borderRadius: BorderRadius.circular(AppTokens.r1),
        border: Border.all(color: c.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: dense ? 11 : 13, color: c),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: AppFonts.text(
              c,
              size: dense ? 11 : 12,
              weight: FontWeight.w600,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

/// [TintBadge] 的色调枚举（语义化，避免调用方到处传 Color）。
enum BadgeTone { neutral, primary, accent, success, warn, danger }

/// 内容卡片：描边 + 可选标题栏 + 可选左侧色条。
///
/// 替代裸 [Card]：统一圆角、边框、内边距和标题节奏，避免每页各写一套 padding。
class AppCard extends StatelessWidget {
  /// 构造。
  const AppCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.icon,
    this.actions,
    this.onTap,
    this.accent,
    this.padding,
    this.dense = false,
    this.selected = false,
    this.footer,
    this.fill = false,
  });

  /// 内容。
  final Widget child;

  /// 标题。
  final String? title;

  /// 副标题（一行说明）。
  final String? subtitle;

  /// 标题左侧图标。
  final IconData? icon;

  /// 右上角操作区。
  final List<Widget>? actions;

  /// 整卡可点。
  final VoidCallback? onTap;

  /// 左侧色条（题材色 / 状态色）。
  final Color? accent;

  /// 自定义内边距。
  final EdgeInsetsGeometry? padding;

  /// 紧凑模式。
  final bool dense;

  /// 选中态（描边换成主色）。
  final bool selected;

  /// 底部区（按钮行等），与内容之间自动加分隔线。
  final Widget? footer;

  /// 撑满父高：内容区吃掉多余空间，footer 天然贴底（网格对齐用）。
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final double pad = dense ? AppTokens.s3 : AppTokens.s4;
    const BorderRadius radius = AppTokens.radiusCard;

    Widget content = Padding(
      padding: padding ?? EdgeInsets.all(pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: <Widget>[
          if (title != null) ...<Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 16, color: ink.inkSoft),
                  const SizedBox(width: AppTokens.s2),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        title!,
                        style: AppFonts.text(
                          ink.ink,
                          size: 14.5,
                          weight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            subtitle!,
                            style: AppFonts.text(ink.inkSoft,
                                size: 12.5, height: 1.5),
                          ),
                        ),
                    ],
                  ),
                ),
                if (actions != null) ...<Widget>[
                  const SizedBox(width: AppTokens.s2),
                  Row(mainAxisSize: MainAxisSize.min, children: actions!),
                ],
              ],
            ),
            SizedBox(height: title != null ? (dense ? AppTokens.s2 : AppTokens.s3) : 0),
          ],
          if (fill) Expanded(child: child) else child,
          if (footer != null) ...<Widget>[
            const SizedBox(height: 6),
            const Divider(height: AppTokens.hairline, thickness: AppTokens.hairline),
            const SizedBox(height: 2),
            footer!,
          ],
        ],
      ),
    );

    if (accent != null) {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(width: 3, decoration: BoxDecoration(color: accent)),
          Expanded(child: content),
        ],
      );
    }

    Widget card = Container(
      decoration: BoxDecoration(
        color: ink.surface,
        borderRadius: radius,
        border: Border.all(
          color: selected ? ink.primary.withValues(alpha: 0.55) : ink.border,
          width: selected ? 1.4 : AppTokens.cardBorder,
        ),
        boxShadow: ink.shadow(),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );

    if (onTap == null) return card;
    return Hoverable(
      onTap: onTap,
      borderRadius: radius,
      // 可点卡片悬浮时轻微抬升（与 web 端书卡 hover 一致）。
      lift: true,
      child: card,
    );
  }
}

/// 分区标题：小标题 + 说明 + 右侧动作 + 细分隔线。
class SectionHeader extends StatelessWidget {
  /// 构造。
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions,
    this.icon,
    this.padding = const EdgeInsets.only(
        bottom: AppTokens.s2, top: AppTokens.s6),
    this.divider = true,
  });

  /// 标题。
  final String title;

  /// 说明文字。
  final String? subtitle;

  /// 右侧动作。
  final List<Widget>? actions;

  /// 图标。
  final IconData? icon;

  /// 外边距。
  final EdgeInsetsGeometry padding;

  /// 是否画底部分隔线。
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 15, color: ink.inkSoft),
                const SizedBox(width: AppTokens.s2),
              ],
              Text(
                title,
                style: AppFonts.text(ink.ink,
                    size: 14, weight: FontWeight.w700, height: 1.35),
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(width: AppTokens.s2),
                Flexible(
                  child: Text(
                    subtitle!,
                    style: AppFonts.text(ink.inkFaint, size: 12, height: 1.4),
                  ),
                ),
              ],
              const Spacer(),
              if (actions != null) ...actions!,
            ],
          ),
          if (divider)
            const Padding(
              padding: EdgeInsets.only(top: AppTokens.s2),
              child: Divider(
                  height: AppTokens.hairline, thickness: AppTokens.hairline),
            ),
        ],
      ),
    );
  }
}

/// 统计数字块：标签 + 数字 + 说明/趋势。
///
/// 数字用等宽字体，避免字数跳动时整块左右抖。
class StatTile extends StatelessWidget {
  /// 构造。
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.icon,
    this.tone = BadgeTone.neutral,
    this.onTap,
  });

  /// 标签。
  final String label;

  /// 数值文本（调用方格式化）。
  final String value;

  /// 说明（如「目标 20 万」）。
  final String? hint;

  /// 图标。
  final IconData? icon;

  /// 数值色调。
  final BadgeTone tone;

  /// 点击（如跳到对应面板）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Color c = TintBadge.colorOf(tone, ink);
    Widget body = Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.s3, vertical: AppTokens.s3 + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 13, color: ink.inkFaint),
                const SizedBox(width: AppTokens.s1),
              ],
              Text(
                label,
                style: AppFonts.text(ink.inkFaint,
                    size: 12, weight: FontWeight.w500, height: 1.3),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: AppFonts.text(c,
                size: 21,
                weight: FontWeight.w700,
                height: 1.2,
                monoFace: true),
          ),
          if (hint != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              hint!,
              style: AppFonts.text(ink.inkSoft, size: 12, height: 1.4),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return body;
    body = Hoverable(onTap: onTap, child: body);
    return body;
  }
}

/// 标签—值行（设定面板、详情区常用，替代手排 Row+Padding）。
class InfoRow extends StatelessWidget {
  /// 构造。
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.trailing,
    this.labelWidth = 76,
  });

  /// 左标签。
  final String label;

  /// 右值（字符串或数字）。
  final String value;

  /// 尾部控件。
  final Widget? trailing;

  /// 标签列宽。
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: AppFonts.text(ink.inkFaint, size: 12.5, height: 1.6),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppFonts.text(ink.ink, size: 13.5, height: 1.6),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
