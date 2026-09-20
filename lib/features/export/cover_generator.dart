import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/widgets/app_feedback.dart';

/// 封面生成器：用 Flutter 绘制一张竖版封面（书名 + 题材 + 装饰渐变），
/// 并保存为 PNG。纯本地，零网络。
class CoverGenerator {
  /// 题材 → 主色调（用于封面背景）。
  static const Map<String, Color> _genreColors = <String, Color>{
    'xuanhuan': Color(0xFF7B4397), // 玄幻紫
    'dushi': Color(0xFF1E3C72), // 都市深蓝
    'kehuan': Color(0xFF0F2027), // 科幻暗青
    'yanqing': Color(0xFFD4145A), // 言情玫红
    'xuanyi': Color(0xFF232526), // 悬疑暗灰
    'xianxia': Color(0xFF2C7744), // 仙侠青绿
    'lishi': Color(0xFF8D5524), // 历史棕
    'youxi': Color(0xFF3A1C71), // 游戏紫蓝
    'jingji': Color(0xFFB71C1C), // 竞技红
    'kongbu': Color(0xFF1A1A2E), // 恐怖暗紫
  };

  /// 生成封面 PNG 字节。
  ///
  /// 尺寸默认 600×800（竖版书籍比例）。
  static Future<Uint8List> generate(Novel novel,
      {int width = 600, int height = 800}) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);

    // 背景渐变（题材色系）。
    final Color base = _genreColors[novel.genre] ?? const Color(0xFF6750A4);
    final Paint bg = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[base, base.withValues(alpha: 0.65)],
      ).createShader(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
    canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), bg);

    // 装饰圆环（左上 + 右下）。
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white.withValues(alpha: 0.35);
    canvas.drawCircle(
        Offset(width * 0.12, height * 0.10), width * 0.16, ring);
    canvas.drawCircle(
        Offset(width * 0.88, height * 0.90), width * 0.20, ring);

    // 题材标签。
    final TextPainter tag = TextPainter(
      text: TextSpan(
        text: GenrePresets.get(novel.genre).label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.9),
          fontSize: width * 0.05,
          letterSpacing: 4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tag.paint(canvas, Offset(width * 0.5 - tag.width / 2, height * 0.16));

    // 分隔线。
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(width * 0.5, height * 0.24),
        width: width * 0.28,
        height: 2,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.6),
    );

    // 书名（自动换行居中）。
    final TextPainter title = TextPainter(
      text: TextSpan(
        text: novel.title,
        style: TextStyle(
          color: Colors.white,
          fontSize: width * 0.095,
          fontWeight: FontWeight.bold,
          height: 1.3,
          shadows: <Shadow>[
            Shadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: width * 0.78);
    title.paint(
      canvas,
      Offset(width * 0.5 - title.width / 2, height * 0.34),
    );

    // 底部作者占位。
    final TextPainter author = TextPainter(
      text: const TextSpan(
        text: '墨匠 InkSmith',
        style: TextStyle(color: Colors.white70, fontSize: 16),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    author.paint(canvas, Offset(width * 0.5 - author.width / 2, height * 0.88));

    final ui.Image image = await recorder.endRecording().toImage(width, height);
    final ByteData? bytes =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) {
      throw StateError('封面渲染失败');
    }
    return bytes.buffer.asUint8List();
  }

  /// 生成并让用户选择保存路径。返回保存路径，取消时返回 null。
  static Future<String?> saveCover(Novel novel) async {
    final Uint8List png = await generate(novel);
    final String suggested =
        '${AppConstants.safeFileName(novel.title)}_cover_${AppConstants.timestamp()}.png';
    final String? path = await FilePicker.platform.saveFile(
      fileName: suggested,
      type: FileType.custom,
      bytes: png,
      allowedExtensions: <String>['png'],
    );
    return path;
  }

  /// 在 UI 中预览封面（生成后弹窗展示，可另存）。
  static Future<void> showCoverPreview(BuildContext context, Novel novel) async {
    final Uint8List png = await generate(novel, width: 300, height: 400);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('封面预览'),
        content: Image.memory(
          png,
          width: 260,
          height: 347,
          fit: BoxFit.cover,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            onPressed: () async {
              final String? path = await saveCover(novel);
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
                if (path != null && context.mounted) {
                  AppToast.success(context, '封面已保存：$path');
                }
              }
            },
            icon: const Icon(Icons.download),
            label: const Text('另存为 PNG'),
          ),
        ],
      ),
    );
  }
}
