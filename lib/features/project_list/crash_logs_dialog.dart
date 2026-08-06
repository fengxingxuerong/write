import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 崩溃日志查看器。
///
/// 列出 `<应用支持目录>/crash_logs/` 下的崩溃日志，支持：
/// - 查看每条日志内容（滚动）
/// - 复制内容到剪贴板
/// - 删除单条 / 全部清除
///
/// 目录操作全部使用同步 IO（崩溃日志数量少、文件小，同步足够快，
/// 且避免测试环境 FakeAsync 下异步 IO 挂起）。
class CrashLogsDialog extends StatefulWidget {
  /// 构造弹窗。
  const CrashLogsDialog({super.key, required this.crashDir});

  /// 崩溃日志目录。
  final Directory crashDir;

  @override
  State<CrashLogsDialog> createState() => _CrashLogsDialogState();
}

class _CrashLogsDialogState extends State<CrashLogsDialog> {
  List<File> _files = <File>[];
  String? _selectedContent;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final List<File> files = <File>[];
    try {
      if (widget.crashDir.existsSync()) {
        for (final FileSystemEntity e
            in widget.crashDir.listSync(followLinks: false)) {
          if (e is File && e.path.endsWith('.log')) {
            files.add(e);
          }
        }
      }
    } catch (_) {
      // 目录不可读时视为空。
    }
    files.sort((a, b) => b.path.compareTo(a.path)); // 最新在前
    setState(() {
      _files = files;
      _selectedContent = null;
    });
  }

  void _readFile(File file) {
    try {
      setState(() => _selectedContent = file.readAsStringSync());
    } catch (e) {
      setState(() => _selectedContent = '读取失败：$e');
    }
  }

  void _deleteFile(File file) {
    try {
      file.deleteSync();
    } catch (_) {}
    _refresh();
  }

  void _clearAll() {
    for (final File f in _files) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    _refresh();
  }

  Future<void> _confirmClearAll() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('清除崩溃日志'),
        content: const Text('确定删除全部崩溃日志？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok == true) _clearAll();
  }

  Future<void> _copySelected(String content) async {
    await Clipboard.setData(ClipboardData(text: content));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制到剪贴板'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('崩溃日志（${_files.length}）'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          children: <Widget>[
            if (_files.isEmpty)
              const Expanded(
                child: Center(child: Text('🎉 暂无崩溃日志，运行一切正常')),
              )
            else
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // 左：日志列表。
                    SizedBox(
                      width: 180,
                      child: ListView.builder(
                        itemCount: _files.length,
                        itemBuilder: (context, i) {
                          final File file = _files[i];
                          final String name =
                              file.uri.pathSegments.isNotEmpty
                                  ? file.uri.pathSegments.last
                                  : file.path;
                          return ListTile(
                            dense: true,
                            title: Text(
                              name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 16),
                              tooltip: '删除',
                              onPressed: () => _deleteFile(file),
                            ),
                            onTap: () => _readFile(file),
                          );
                        },
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    // 右：内容预览。
                    Expanded(
                      child: _selectedContent == null
                          ? const Center(
                              child: Text('点击左侧日志查看内容'),
                            )
                          : SingleChildScrollView(
                              padding: const EdgeInsets.all(8),
                              child: SelectableText(
                                _selectedContent!,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        if (_files.isNotEmpty)
          TextButton(
            onPressed: _confirmClearAll,
            child: const Text('全部清除'),
          ),
        if (_selectedContent != null)
          TextButton(
            onPressed: () => _copySelected(_selectedContent!),
            child: const Text('复制'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 弹出崩溃日志查看器（目录不存在时自动创建）。
Future<void> showCrashLogsDialog(
  BuildContext context,
  Directory crashDir,
) async {
  try {
    crashDir.createSync(recursive: true);
  } catch (_) {}
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => CrashLogsDialog(crashDir: crashDir),
  );
}
