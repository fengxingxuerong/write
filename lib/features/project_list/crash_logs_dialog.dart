import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:novel_writer/core/crash_reporter.dart';

/// 崩溃日志查看器。
///
/// 列出 `<应用支持目录>/crash_logs/` 下的崩溃日志，支持：
/// - 查看每条日志内容（滚动）
/// - 复制内容到剪贴板
/// - 手动上报到远程服务器（需先配置上报 URL）
/// - 删除单条 / 全部清除
///
/// 目录操作全部使用同步 IO（崩溃日志数量少、文件小，同步足够快，
/// 且避免测试环境 FakeAsync 下异步 IO 挂起）。
class CrashLogsDialog extends StatefulWidget {
  /// 构造弹窗。
  const CrashLogsDialog({
    super.key,
    required this.crashDir,
    required this.supportDir,
  });

  /// 崩溃日志目录。
  final Directory crashDir;

  /// 应用支持目录（存放上报配置）。
  final Directory supportDir;

  @override
  State<CrashLogsDialog> createState() => _CrashLogsDialogState();
}

class _CrashLogsDialogState extends State<CrashLogsDialog> {
  List<File> _files = <File>[];
  String? _selectedContent;
  CrashReporterConfig _config = const CrashReporterConfig();
  bool _reporting = false;
  String? _reportStatus;

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _refresh();
  }

  Future<void> _loadConfig() async {
    final CrashReporterConfig config =
        loadCrashReporterConfigSync(widget.supportDir);
    if (mounted) setState(() => _config = config);
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

  /// 上报单条日志；返回 true 表示成功。
  Future<bool> _reportFile(File file) async {
    if (!_config.enabled) return false;
    setState(() {
      _reporting = true;
      _reportStatus = null;
    });
    try {
      final String machineId = await _readMachineId(widget.supportDir);
      final String fileName = file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : file.path;
      final bool ok = await uploadCrashLog(
        crashDir: widget.crashDir,
        fileName: fileName,
        config: _config,
        machineId: machineId,
      );
      if (mounted) {
        setState(() {
          _reportStatus = ok ? '✅ 上报成功' : '上报失败';  
        });
      }
      return ok;
    } catch (e) {
      if (mounted) {
        setState(() => _reportStatus = '上报失败：$e');
      }
      return false;
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
  }

  /// 读取设备标识（文件不存在时返回空串）。
  Future<String> _readMachineId(Directory supportDir) async {
    try {
      final File f = File(
        '${supportDir.path}${Platform.pathSeparator}machine_id',
      );
      if (await f.exists()) return (await f.readAsString()).trim();
    } catch (_) {}
    return '';
  }

  /// 上报设置弹窗。
  Future<void> _showReportSettings() async {
    final TextEditingController urlCtrl =
        TextEditingController(text: _config.uploadUrl);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('崩溃上报设置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              '配置崩溃日志上报服务器地址。留空 = 不上报，仅本地保存。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: '上报 URL（POST JSON）',
                hintText: 'https://example.com/api/crash',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final CrashReporterConfig next = CrashReporterConfig(
        uploadUrl: urlCtrl.text.trim(),
      );
      saveCrashReporterConfigSync(widget.supportDir, next);
      if (mounted) {
        setState(() {
          _config = next;
          _reportStatus = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              next.enabled ? '已保存，崩溃后自动上报' : '已关闭远程上报（仅本地日志）',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
    // 注意：不在 pop 动画完成前 dispose urlCtrl，
    // 否则对话框 TextField 仍引用已释放的 controller 会抛异常。
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
            // 顶部：上报状态条。
            if (_reporting)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('正在上报…', style: TextStyle(fontSize: 12)),
                  ],
                ),
              )
            else if (_reportStatus != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        _reportStatus!,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
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
                            onLongPress: () => _reportFile(file),
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
        // 上报设置（含已配置状态）。
        TextButton(
          onPressed: _showReportSettings,
          child: Text(
            _config.enabled ? '上报设置 ✓' : '上报设置',
          ),
        ),
        // 上报当前选中的日志（未配置 URL 时点击提示）。
        if (_selectedContent != null)
          TextButton(
            onPressed: () async {
              if (!_config.enabled) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('请先点击「上报设置」配置上报 URL'),
                    duration: Duration(seconds: 2),
                  ),
                );
                return;
              }
              // 上报当前选中文件（列表第一个？不——取当前选中）。
              // 简单处理：上报最近选中的文件，通过文件列表匹配内容。
              for (final File f in _files) {
                if (f.readAsStringSync() == _selectedContent) {
                  await _reportFile(f);
                  break;
                }
              }
            },
            child: const Text('上报'),
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
  Directory supportDir,
) async {
  try {
    crashDir.createSync(recursive: true);
  } catch (_) {}
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => CrashLogsDialog(
      crashDir: crashDir,
      supportDir: supportDir,
    ),
  );
}
