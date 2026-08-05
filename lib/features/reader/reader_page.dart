import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/reader_settings.dart';

/// 阅读模式 / 排版预览。
///
/// 模拟电子书阅读器排版：三主题（白/米黄/夜间）、章节导航、字号/行距调节、
/// 衬线字体。设置全局持久化（app_settings.json）。纯本地渲染，零依赖。
class ReaderPage extends ConsumerStatefulWidget {
  /// 构造阅读页。
  const ReaderPage({super.key, required this.novel});

  /// 目标项目。
  final Novel novel;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  int _chapterIndex = 0;

  List<Chapter> get _chapters => widget.novel.chapters;

  ReaderSettings get _settings => ref.watch(readerSettingsProvider);

  void _prev() {
    if (_chapterIndex > 0) setState(() => _chapterIndex -= 1);
  }

  void _next() {
    if (_chapterIndex < _chapters.length - 1) {
      setState(() => _chapterIndex += 1);
    }
  }

  void _update(ReaderSettings s) {
    ref.read(readerSettingsProvider.notifier).update(s);
  }

  /// 主题 → 背景 / 前景色。
  (Color, Color) _palette(ReaderTheme theme) {
    switch (theme) {
      case ReaderTheme.light:
        return (Colors.white, const Color(0xFF1A1A1A));
      case ReaderTheme.sepia:
        return (const Color(0xFFF5EFE0), const Color(0xFF4A3F2F));
      case ReaderTheme.dark:
        return (const Color(0xFF121212), const Color(0xFFCFCFCF));
    }
  }

  @override
  Widget build(BuildContext context) {
    final Chapter? current =
        _chapters.isEmpty ? null : _chapters[_chapterIndex];
    final (Color bg, Color fg) = _palette(_settings.theme);
    final Color barBg = switch (_settings.theme) {
      ReaderTheme.light => const Color(0xFFF7F7F7),
      ReaderTheme.sepia => const Color(0xFFEDE4CE),
      ReaderTheme.dark => const Color(0xFF1E1E1E),
    };
    // 夜间模式 AppBar 用深色，避免白底闪屏。
    final Color appBarBg = _settings.theme == ReaderTheme.dark
        ? const Color(0xFF1E1E1E)
        : bg;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: appBarBg,
        foregroundColor: fg,
        title: Text('阅读模式 — ${widget.novel.title}'),
        actions: <Widget>[
          // 主题循环：白 → 米黄 → 夜间。
          IconButton(
            tooltip: '主题（白/米黄/夜间）',
            icon: const Icon(Icons.palette_outlined),
            onPressed: () {
              final ReaderTheme next = switch (_settings.theme) {
                ReaderTheme.light => ReaderTheme.sepia,
                ReaderTheme.sepia => ReaderTheme.dark,
                ReaderTheme.dark => ReaderTheme.light,
              };
              _update(_settings.copyWith(theme: next));
            },
          ),
          IconButton(
            tooltip: '衬线字体',
            icon: Icon(
              _settings.serif ? Icons.font_download : Icons.font_download_outlined,
            ),
            onPressed: () =>
                _update(_settings.copyWith(serif: !_settings.serif)),
          ),
          IconButton(
            tooltip: '减小字号',
            icon: const Icon(Icons.text_decrease),
            onPressed: () {
              if (_settings.fontSize > 12) {
                _update(_settings.copyWith(fontSize: _settings.fontSize - 1));
              }
            },
          ),
          IconButton(
            tooltip: '增大字号',
            icon: const Icon(Icons.text_increase),
            onPressed: () {
              if (_settings.fontSize < 32) {
                _update(_settings.copyWith(fontSize: _settings.fontSize + 1));
              }
            },
          ),
          // 行距循环：1.6 → 1.9 → 2.2。
          IconButton(
            tooltip: '行距（1.6/1.9/2.2）',
            icon: const Icon(Icons.format_line_spacing),
            onPressed: () {
              final double next = switch (_settings.lineHeight) {
                <= 1.7 => 1.9,
                <= 2.0 => 2.2,
                _ => 1.6,
              };
              _update(_settings.copyWith(lineHeight: next));
            },
          ),
        ],
      ),
      body: current == null
          ? Center(
              child: Text(
                '暂无章节',
                style: TextStyle(color: fg),
              ),
            )
          : SafeArea(
              child: Column(
                children: <Widget>[
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 20,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            current.title,
                            style: TextStyle(
                              fontSize: _settings.fontSize + 8,
                              fontWeight: FontWeight.bold,
                              color: fg,
                              height: 1.5,
                              fontFamily: _settings.serif
                                  ? 'serif'
                                  : null,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            current.content.isEmpty
                                ? '（本章暂无内容）'
                                : current.content,
                            style: TextStyle(
                              fontSize: _settings.fontSize,
                              color: fg,
                              height: _settings.lineHeight,
                              letterSpacing: 0.5,
                              fontFamily:
                                  _settings.serif ? 'serif' : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 底部导航。
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    color: barBg,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        IconButton(
                          tooltip: '上一章',
                          icon: const Icon(Icons.chevron_left),
                          onPressed: _chapterIndex > 0 ? _prev : null,
                        ),
                        Text(
                          '${_chapterIndex + 1} / ${_chapters.length} 章',
                          style: TextStyle(color: fg),
                        ),
                        IconButton(
                          tooltip: '下一章',
                          icon: const Icon(Icons.chevron_right),
                          onPressed: _chapterIndex < _chapters.length - 1
                              ? _next
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
