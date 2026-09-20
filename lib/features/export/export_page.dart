import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/features/export/export_service.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/widgets/app_feedback.dart';

/// 打开导出对话框（TXT / Markdown / Word / EPUB / JSON 备份）。
Future<void> showExportDialog(BuildContext context, Novel novel) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => _ExportDialog(novel: novel),
  );
}

/// 格式卡片配置（图标 / 名称 / 说明）。
class _FormatInfo {
  const _FormatInfo(this.icon, this.label, this.desc);
  final IconData icon;
  final String label;
  final String desc;
}

const List<_FormatInfo> _formats = <_FormatInfo>[
  _FormatInfo(Icons.notes_rounded, '纯文本 TXT', '通用文本，任何设备可读'),
  _FormatInfo(Icons.mark_chat_unread_rounded, 'Markdown', '带标题层级，适配笔记工具'),
  _FormatInfo(Icons.description_rounded, 'Word 文档', '.docx 格式，Office/WPS 打开'),
  _FormatInfo(Icons.menu_book_rounded, 'EPUB 电子书', '标准电子书，可导入阅读器'),
  _FormatInfo(Icons.backup_rounded, 'JSON 备份', '完整项目数据，可恢复'),
];

class _ExportDialog extends ConsumerStatefulWidget {
  const _ExportDialog({required this.novel});

  final Novel novel;

  @override
  ConsumerState<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends ConsumerState<_ExportDialog> {
  bool _includeSettings = false;
  bool _exporting = false;

  Novel get novel => widget.novel;

  @override
  void initState() {
    super.initState();
    // 记住上次导出偏好（方向⑥：一键导出配置）。
    _includeSettings = widget.novel.exportPrefs.includeSettings;
  }

  /// 导出成功后把本次偏好回写到项目（下次打开自动记住）。
  Future<void> _savePrefs() async {
    try {
      final novelRepository =
          ref.read(novelRepositoryProvider);
      final bool includeSettings = _includeSettings;
      await novelRepository.mutateNovel(
        widget.novel.id,
        (Novel latest) => latest.copyWith(
          exportPrefs: latest.exportPrefs.copyWith(
            includeSettings: includeSettings,
          ),
        ),
      );
    } catch (_) {
      // 偏好保存失败不影响导出主流程。
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导出作品'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '选择导出格式，将打开系统路径选择器保存文件。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppTokens.s3),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _formats.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (BuildContext context, int index) {
                  final _FormatInfo info = _formats[index];
                  final ExportFormat format = ExportFormat.values[index];
                  return ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTokens.r3),
                      side: BorderSide(
                        color: Theme.of(context).dividerColor,
                      ),
                    ),
                    leading: Icon(info.icon),
                    title: Text(info.label),
                    subtitle: Text(info.desc),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: _exporting
                        ? null
                        : () => _doExport(context, format),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('附带角色与世界观设定'),
              subtitle: const Text('追加到正文末尾（TXT / Markdown / Word）'),
              value: _includeSettings,
              onChanged: _exporting
                  ? null
                  : (bool v) => setState(() => _includeSettings = v),
            ),
            const SizedBox(height: 4),
            if (_exporting)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              OutlinedButton.icon(
                onPressed: () => _exportAll(context),
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('一键导出全部格式'),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _exporting ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }

  /// 按顺序导出全部 5 种格式（跳过用户取消的项）。
  Future<void> _exportAll(BuildContext context) async {
    setState(() => _exporting = true);
    final ExportService service =
        ExportService(ref.read(novelRepositoryProvider));
    int done = 0;
    for (final ExportFormat format in ExportFormat.values) {
      try {
        await service.export(novel, format, includeSettings: _includeSettings);
        done++;
      } on ExportException {
        // 用户取消某一项：跳过继续。
      } catch (e) {
        if (context.mounted) {
          AppToast.error(context, '${format.label} 导出失败：$e');
        }
      }
    }
    if (!context.mounted) return;
    setState(() => _exporting = false);
    final int doneCount = done;
    Navigator.of(context).pop();
    AppToast.success(context, '已导出 $doneCount 种格式（跳过取消项）');
    unawaited(_savePrefs());
  }

  Future<void> _doExport(
    BuildContext context,
    ExportFormat format,
  ) async {
    setState(() => _exporting = true);
    final ExportService service =
        ExportService(ref.read(novelRepositoryProvider));
    try {
      final String path = await service.export(
        novel,
        format,
        includeSettings: _includeSettings,
      );
      await _savePrefs();
      if (context.mounted) {
        setState(() => _exporting = false);
        Navigator.of(context).pop();
        AppToast.success(context, '已导出：$path');
      }
    } on ExportException catch (e) {
      final String msg = e.message;
      if (context.mounted) {
        setState(() => _exporting = false);
        AppToast.error(context, msg);
      }
    } catch (e) {
      final String msg = '导出失败：$e';
      if (context.mounted) {
        setState(() => _exporting = false);
        AppToast.error(context, msg);
      }
    }
  }
}
