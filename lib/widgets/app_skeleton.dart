import 'package:flutter/material.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';

/// 骨架屏块：加载态用它预告「结果长什么样、有多少」。
///
/// 一个转圈只能说明「没死」；骨架能提前把结构交代清楚，等待感完全不同
/// （首屏打开项目、书架冷启动、生成中预览都适用）。
///
/// **默认不动画**：无限 `repeat` 动画会让 `pumpAndSettle()` 永不返回，
/// 而本项目的 widget 测试大量用它收尾。需要呼吸感的地方显式传 `animate: true`，
/// 并避开 `pumpAndSettle`。
class Skeleton extends StatelessWidget {
  /// 构造骨架块。
  const Skeleton({
    super.key,
    this.width,
    this.height = 12,
    this.radius = AppTokens.r1,
    this.animate = false,
  });

  /// 宽度（为空时撑满可用宽度）。
  final double? width;

  /// 高度。
  final double height;

  /// 圆角。
  final double radius;

  /// 是否呼吸（默认关闭，见类注释）。
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Widget block = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: ink.skeleton,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
    if (!animate) return block;
    return _Breathing(child: block);
  }
}

/// 骨架列表：n 行「序号 + 标题 + 副信息」的轮廓（章节列表的加载占位）。
///
/// 用 [Column] 而非 `ListView`——它常被塞进「高度还没定下来」的父级里，
/// 用可滚动组件会在无界高度下直接抛异常。
class SkeletonList extends StatelessWidget {
  /// 构造骨架列表。
  const SkeletonList({
    super.key,
    this.rows = 6,
    this.rowHeight = 40,
    this.padding = const EdgeInsets.all(AppTokens.s3),
  });

  /// 行数。
  final int rows;

  /// 单行高度。
  final double rowHeight;

  /// 外边距。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < rows; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: AppTokens.s2),
            SizedBox(
              height: rowHeight,
              child: Row(
                children: <Widget>[
                  const Skeleton(width: 18, height: 11, radius: AppTokens.r1),
                  const SizedBox(width: AppTokens.s3),
                  const Expanded(
                    child: Skeleton(height: 12, radius: AppTokens.r1),
                  ),
                  const SizedBox(width: AppTokens.s3),
                  // 右侧宽度按行错落，避免整体看起来像一张网。
                  Skeleton(
                    width: 30.0 + (i % 3) * 8,
                    height: 11,
                    radius: AppTokens.r1,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 段落骨架：宽度递减的若干行（正文 / 报告类加载占位）。
///
/// 末行短一截，像真实段落的收尾，比等宽方块自然。
class SkeletonParagraph extends StatelessWidget {
  /// 构造段落骨架。
  const SkeletonParagraph({
    super.key,
    this.lines = 6,
    this.lineHeight = 12,
    this.spacing = AppTokens.s3,
  });

  /// 行数。
  final int lines;

  /// 单行高度。
  final double lineHeight;

  /// 行间距。
  final double spacing;

  /// 每行的宽度占比（循环取用；末位故意短）。
  static const List<double> _ratios = <double>[1, 1, 0.94, 1, 0.9, 1, 0.66];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < lines; i++) ...<Widget>[
          if (i > 0) SizedBox(height: spacing),
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: _ratios[i % _ratios.length],
            child: Skeleton(height: lineHeight, radius: AppTokens.r1),
          ),
        ],
      ],
    );
  }
}

/// 呼吸动画载体（仅在 [Skeleton.animate] 为 true 时挂载）。
class _Breathing extends StatefulWidget {
  const _Breathing({required this.child});

  final Widget child;

  @override
  State<_Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<_Breathing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween<double>(begin: 0.5, end: 1).animate(
          CurvedAnimation(parent: _c, curve: Curves.easeInOut),
        ),
        child: widget.child,
      );
}
