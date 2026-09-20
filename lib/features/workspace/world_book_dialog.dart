import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:math' as math;

import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/widgets/app_feedback.dart';
import 'package:novel_writer/widgets/common.dart';

/// 世界书弹窗：可视化展示角色关系网与世界观设定，支持一键注入上下文。
class WorldBookDialog extends ConsumerStatefulWidget {
  const WorldBookDialog({super.key, required this.novel});

  final Novel novel;

  /// 打开世界书弹窗（静态入口）。
  static Future<void> show(BuildContext context, Novel novel) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).dialogLabel,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (_, __, ___) => Dialog(
        insetPadding: const EdgeInsets.all(AppTokens.s6),
        child: SizedBox(
          width: 900,
          height: MediaQuery.of(context).size.height * 0.85,
          child: WorldBookDialog(novel: novel),
        ),
      ),
      // 自定义弹出动画：由下往上的滑入 + 淡入
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInQuint,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.05),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
  }

  @override
  ConsumerState<WorldBookDialog> createState() => _WorldBookDialogState();
}

class _WorldBookDialogState extends ConsumerState<WorldBookDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtl;
  String _injectedContext = '';

  @override
  void initState() {
    super.initState();
    _tabCtl = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabCtl.dispose();
    super.dispose();
  }

  /// 将全部角色与世界观拼接为一段注入文本。
  String _buildContextInjection() {
    final StringBuffer b = StringBuffer();
    b.writeln('## 角色档案');
    for (final c in widget.novel.characters) {
      b.writeln('- ${c.name}（${c.role}）：${c.traits}。背景：${c.background}。关系：${c.relationships}。');
      if (c.dialogueStyle.isNotEmpty) {
        b.writeln('  说话风格：${c.dialogueStyle}');
      }
    }
    b.writeln();
    b.writeln('## 世界观设定');
    final Map<String, List<WorldSetting>> grouped = {};
    for (final w in widget.novel.worldSettings) {
      grouped.putIfAbsent(w.category, () => []).add(w);
    }
    for (final entry in grouped.entries) {
      b.writeln('### ${entry.key}');
      for (final w in entry.value) {
        b.writeln('- ${w.title}：${w.content}');
      }
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 标题栏 + 关闭按钮
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              const Icon(Icons.menu_book, size: 22),
              const SizedBox(width: 8),
              Text(
                '《${widget.novel.title}》世界书',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              if (_injectedContext.isNotEmpty)
                Chip(
                  label: Text(
                    '已生成上下文',
                    style: AppFonts.text(AppInk.of(context).success, size: 11),
                  ),
                  backgroundColor:
                      AppInk.of(context).success.withValues(alpha: 0.15),
                  side: BorderSide.none,
                  visualDensity: VisualDensity.compact,
                ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        TabBar(
          controller: _tabCtl,
          tabs: const [
            Tab(text: '角色'),
            Tab(text: '关系图谱'),
            Tab(text: '世界观'),
            Tab(text: '注入上下文'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabCtl,
            children: [
              _charactersTab(),
              _relationshipGraphTab(),
              _worldTab(),
              _injectionTab(),
            ],
          ),
        ),
      ],
    );
  }

  // ========== 角色标签页（卡片列表） ==========
  Widget _charactersTab() {
    final novel = widget.novel;
    if (novel.characters.isEmpty) {
      return const EmptyState(message: '暂无角色，请在右侧栏「+」添加');
    }
    return ListView(
      padding: const EdgeInsets.all(AppTokens.s3),
      children: novel.characters.map((c) => _characterCard(c)).toList(),
    );
  }

  Widget _characterCard(Character c) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.s2 + 2),
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.s3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 角色头像占位（首字圆形）
            CircleAvatar(
              radius: 22,
              child: Text(
                c.name.isNotEmpty ? c.name[0] : '?',
                style: AppFonts.text(AppInk.of(context).ink, size: 18),
              ),
            ),
            const SizedBox(width: AppTokens.s3),
            // 角色信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        c.name.isEmpty ? '未命名' : c.name,
                        style: AppFonts.text(AppInk.of(context).ink, size: 15, weight: FontWeight.bold),
                      ),
                      if (c.role.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Chip(
                          label: Text(c.role, style: AppFonts.text(AppInk.of(context).ink, size: 11)),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          side: BorderSide.none,
                          backgroundColor: _roleColor(c.role).withValues(alpha: 0.18),
                        ),
                      ],
                    ],
                  ),
                  if (c.traits.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(c.traits, style: AppFonts.text(AppInk.of(context).inkSoft, size: 13)),
                  ],
                  if (c.background.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _infoRow(Icons.history, c.background, AppInk.of(context).inkFaint),
                  ],
                  if (c.relationships.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _infoRow(Icons.link, c.relationships, AppInk.of(context).inkSoft),
                  ],
                  if (c.dialogueStyle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _infoRow(Icons.record_voice_over, c.dialogueStyle, AppInk.of(context).accent),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _roleColor(String role) {
    final r = role.toLowerCase();
    final AppInk ink = AppInk.of(context);
    if (r.contains('主') || r.contains('hero')) return ink.warn;
    if (r.contains('反') || r.contains('邪恶') || r.contains('villain')) return ink.danger;
    if (r.contains('师') || r.contains('长') || r.contains('mentor')) return ink.primary;
    return ink.inkSoft;
  }

  Widget _infoRow(IconData icon, String text, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            text,
            style: AppFonts.text(color.withValues(alpha: 0.9), size: 12),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  // ========== 关系图谱标签页 ==========
  Widget _relationshipGraphTab() {
    final characters = widget.novel.characters;
    if (characters.isEmpty) {
      return const EmptyState(message: '暂无角色，无法生成关系图谱');
    }
    final edges = _parseRelationships(characters);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppTokens.s3),
          child: Row(
            children: [
              const Icon(Icons.hub_outlined, size: 18),
              const SizedBox(width: 8),
              Text('${characters.length} 个角色，${edges.length} 条关系',
                  style: AppFonts.text(AppInk.of(context).inkFaint, size: 12)),
              const Spacer(),
              _legendDot(AppInk.of(context).warn, '主角'),
              const SizedBox(width: AppTokens.s3),
              _legendDot(AppInk.of(context).danger, '反派'),
              const SizedBox(width: AppTokens.s3),
              _legendDot(AppInk.of(context).primary, '师长'),
              const SizedBox(width: AppTokens.s3),
              _legendDot(AppInk.of(context).inkSoft, '其他'),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return _RelationshipGraphCanvas(
                characters: characters,
                edges: edges,
                size: Size(constraints.maxWidth, constraints.maxHeight),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 2),
        Text(label, style: AppFonts.text(AppInk.of(context).inkFaint, size: 10)),
      ],
    );
  }

  List<_RoleEdge> _parseRelationships(List<Character> characters) {
    final Map<String, Character> byName = {
      for (final c in characters) c.name: c,
    };
    final List<_RoleEdge> edges = [];
    final Set<String> seen = {};
    for (final c in characters) {
      if (c.relationships.isEmpty) continue;
      // 解析格式："对象：关系；对象：关系"
      for (final segment in c.relationships.split(RegExp(r'[；;，,]'))) {
        final trimmed = segment.trim();
        if (trimmed.isEmpty) continue;
        final parts = trimmed.split(RegExp(r'[：:]'));
        if (parts.length < 2) continue;
        final targetName = parts[0].trim();
        final relation = parts.sublist(1).join('：').trim();
        if (byName.containsKey(targetName)) {
          final key = '${c.name}-$targetName';
          final reverseKey = '$targetName-${c.name}';
          if (!seen.contains(key) && !seen.contains(reverseKey)) {
            seen.add(key);
            edges.add(_RoleEdge(
              from: c,
              to: byName[targetName]!,
              label: relation.isEmpty ? '关联' : relation,
            ));
          }
        }
      }
    }
    return edges;
  }

  // ========== 世界观标签页（按分类分组） ==========
  Widget _worldTab() {
    final novel = widget.novel;
    if (novel.worldSettings.isEmpty) {
      return const EmptyState(message: '暂无世界观设定');
    }
    final Map<String, List<WorldSetting>> grouped = {};
    for (final w in novel.worldSettings) {
      grouped.putIfAbsent(w.category.isNotEmpty ? w.category : '其他', () => []).add(w);
    }
    return ListView(
      padding: const EdgeInsets.all(AppTokens.s3),
      children: grouped.entries.map((entry) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: AppTokens.s1 + 2, top: 4),
              child: Text(
                entry.key,
                style: AppFonts.text(AppInk.of(context).inkSoft,
                    size: 13, weight: FontWeight.bold),
              ),
            ),
            ...entry.value.map((w) => Card(
                  margin: const EdgeInsets.only(bottom: AppTokens.s2),
                  child: ListTile(
                    dense: true,
                    title: Text(w.title, style: AppFonts.text(AppInk.of(context).ink, weight: FontWeight.w600)),
                    subtitle: Text(
                      w.content,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.text(AppInk.of(context).inkSoft, size: 12),
                    ),
                  ),
                )),
            const SizedBox(height: 8),
          ],
        );
      }).toList(),
    );
  }

  // ========== 上下文注入标签页 ==========
  Widget _injectionTab() {
    final ctx = _injectedContext.isNotEmpty ? _injectedContext : _buildContextInjection();
    _injectedContext = ctx;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppTokens.s3),
          child: Row(
            children: [
              const Icon(Icons.content_paste, size: 18),
              const SizedBox(width: 8),
              const Text('复制以下文本粘贴到编辑器「设定」或 AI 提示词中即可注入'),
              const Spacer(),
              FilledButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制全部'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: ctx));
                  if (mounted) {
                    AppToast.success(context, '已复制到剪贴板');
                  }
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            padding: const EdgeInsets.all(AppTokens.s3),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppTokens.r2),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                ctx,
                style: AppFonts.text(AppInk.of(context).ink, size: 13, height: 1.6),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 关系边。
class _RoleEdge {
  final Character from;
  final Character to;
  final String label;

  const _RoleEdge({
    required this.from,
    required this.to,
    required this.label,
  });
}

/// 角色关系图谱画布：自动环形布局 + CustomPaint 连线 + 可点击角色节点。
class _RelationshipGraphCanvas extends StatefulWidget {
  const _RelationshipGraphCanvas({
    required this.characters,
    required this.edges,
    required this.size,
  });

  final List<Character> characters;
  final List<_RoleEdge> edges;
  final Size size;

  @override
  State<_RelationshipGraphCanvas> createState() => _RelationshipGraphCanvasState();
}

class _RelationshipGraphCanvasState extends State<_RelationshipGraphCanvas> {
  final Map<String, int> _tapCount = {};

  @override
  Widget build(BuildContext context) {
    final center = Offset(widget.size.width / 2, widget.size.height / 2);
    final radius = math.min(widget.size.width, widget.size.height) * 0.35;
    final angleStep = 2 * math.pi / math.max(widget.characters.length, 1);

    final Map<String, Offset> positions = {};
    for (int i = 0; i < widget.characters.length; i++) {
      final angle = -math.pi / 2 + i * angleStep;
      final x = center.dx + radius * math.cos(angle);
      final y = center.dy + radius * math.sin(angle);
      positions[widget.characters[i].name] = Offset(x, y);
    }

    return GestureDetector(
      onTapUp: (details) {
        // 点击连线附近显示关系
        for (final edge in widget.edges) {
          final p1 = positions[edge.from.name];
          final p2 = positions[edge.to.name];
          if (p1 == null || p2 == null) continue;
          final dist = _pointToSegmentDistance(details.localPosition, p1, p2);
          if (dist < 20) {
            setState(() {
              _tapCount[edge.label] = (_tapCount[edge.label] ?? 0) + 1;
            });
            AppToast.info(context,
                '${edge.from.name} ↔ ${edge.to.name}：${edge.label}');
            break;
          }
        }
      },
      child: Stack(
        children: [
          // 连线层
          CustomPaint(
            size: widget.size,
            painter: _RelationshipPainter(
              edges: widget.edges,
              positions: positions,
              lineColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
              labelColor: Theme.of(context).textTheme.bodySmall?.color ?? AppInk.of(context).inkFaint,
            ),
          ),
          // 节点层 (角色头像)
          ...widget.characters.map((c) {
            final pos = positions[c.name] ?? Offset.zero;
            return Positioned(
              left: pos.dx - 16,
              top: pos.dy - 16,
              child: _NodeChip(
                name: c.name,
                role: c.role,
                onTap: () => AppToast.info(
                    context, '${c.name}（${c.role}）'),
              ),
            );
          }),
        ],
      ),
    );
  }

  double _pointToSegmentDistance(Offset p, Offset a, Offset b) {
    final abx = b.dx - a.dx;
    final aby = b.dy - a.dy;
    final apx = p.dx - a.dx;
    final apy = p.dy - a.dy;
    final abLenSq = abx * abx + aby * aby;
    if (abLenSq == 0) return math.sqrt(apx * apx + apy * apy);
    final t = ((apx * abx + apy * aby) / abLenSq).clamp(0.0, 1.0);
    final cx = a.dx + t * abx;
    final cy = a.dy + t * aby;
    return math.sqrt((p.dx - cx) * (p.dx - cx) + (p.dy - cy) * (p.dy - cy));
  }
}

/// 图谱连线 CustomPainter。
class _RelationshipPainter extends CustomPainter {
  _RelationshipPainter({
    required this.edges,
    required this.positions,
    required this.lineColor,
    required this.labelColor,
  });

  final List<_RoleEdge> edges;
  final Map<String, Offset> positions;
  final Color lineColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (final edge in edges) {
      final p1 = positions[edge.from.name];
      final p2 = positions[edge.to.name];
      if (p1 == null || p2 == null) continue;
      canvas.drawLine(p1, p2, paint);

      // 中点画关系标签
      final midX = (p1.dx + p2.dx) / 2;
      final midY = (p1.dy + p2.dy) / 2;
      final textPainter = TextPainter(
        text: TextSpan(
          text: edge.label,
          style: AppFonts.text(labelColor, size: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 60);
      final bgPaint = Paint()
        ..color = (lineColor).withValues(alpha: 0.06)
        ..style = PaintingStyle.fill;
      canvas.drawRect(
        Rect.fromCenter(center: Offset(midX, midY), width: textPainter.width + 6, height: textPainter.height + 4),
        bgPaint,
      );
      textPainter.paint(canvas, Offset(midX - textPainter.width / 2, midY - textPainter.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _RelationshipPainter oldDelegate) =>
      edges != oldDelegate.edges || positions != oldDelegate.positions;
}

/// 角色节点 chip（圆形头像加名字）。
class _NodeChip extends StatefulWidget {
  const _NodeChip({
    required this.name,
    required this.role,
    required this.onTap,
  });

  final String name;
  final String role;
  final VoidCallback onTap;

  @override
  State<_NodeChip> createState() => _NodeChipState();
}

class _NodeChipState extends State<_NodeChip> {
  bool _hovering = false;

  Color _colorForRole(String role) {
    final r = role.toLowerCase();
    final AppInk ink = AppInk.of(context);
    if (r.contains('主') || r.contains('hero')) return ink.warn;
    if (r.contains('反') || r.contains('邪恶') || r.contains('villain')) return ink.danger;
    if (r.contains('师') || r.contains('长') || r.contains('mentor')) return ink.primary;
    return ink.inkSoft;
  }

  @override
  Widget build(BuildContext context) {
    final color = _colorForRole(widget.role);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          transform: Matrix4.identity()
            ..scaleByDouble(_hovering ? 1.2 : 1.0, _hovering ? 1.2 : 1.0, 1.0, 1.0),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: _hovering ? Colors.white : Colors.transparent,
                width: 2,
              ),
              boxShadow: _hovering
                  ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 8)]
                  : [],
            ),
            child: Center(
              child: Text(
                widget.name.isNotEmpty ? widget.name[0] : '?',
                style: AppFonts.text(Colors.white, size: 11, weight: FontWeight.bold),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
