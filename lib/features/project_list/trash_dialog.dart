import 'package:flutter/material.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/core/utils/text_fmt.dart';
import 'package:novel_writer/storage/trash_service.dart';
import 'package:novel_writer/widgets/app_feedback.dart';
import 'package:novel_writer/widgets/app_skeleton.dart';
import 'package:novel_writer/widgets/common.dart';

/// 回收站弹窗：列出可恢复的作品，支持恢复、永久删除与清空。
Future<void> showTrashDialog(BuildContext context, TrashStore store) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => _TrashDialog(store),
  );
}

class _TrashDialog extends StatefulWidget {
  const _TrashDialog(this.store);

  final TrashStore store;

  @override
  State<_TrashDialog> createState() => _TrashDialogState();
}

class _TrashDialogState extends State<_TrashDialog> {
  List<TrashEntry> _entries = const <TrashEntry>[];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<TrashEntry> entries = await widget.store.list();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _restore(TrashEntry entry) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.store.restore(entry);
      if (!mounted) return;
      AppToast.success(context, '《${entry.title}》已恢复到书架');
      await _load();
    } catch (e) {
      if (mounted) AppToast.error(context, '恢复失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purge(TrashEntry entry) async {
    if (_busy) return;
    final bool ok = await showConfirmDialog(
      context,
      title: '永久删除',
      content:
          '永久删除《${entry.title}》？\n'
          '这本作品的正文与设定会从本机彻底移除，无法恢复。',
      confirmLabel: '永久删除',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.store.purge(entry);
      if (!mounted) return;
      AppToast.info(context, '已永久删除《${entry.title}》');
      await _load();
    } catch (e) {
      if (mounted) AppToast.error(context, '永久删除失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purgeAll() async {
    if (_busy || _entries.isEmpty) return;
    final bool ok = await showConfirmDialog(
      context,
      title: '清空回收站',
      content: '永久删除回收站中的 ${_entries.length} 本作品？\n该操作无法恢复。',
      confirmLabel: '全部删除',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.store.purgeAll();
      if (!mounted) return;
      AppToast.info(context, '回收站已清空');
      await _load();
    } catch (e) {
      if (mounted) AppToast.error(context, '清空回收站失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _date(DateTime dt) {
    final String mm = dt.month.toString().padLeft(2, '0');
    final String dd = dt.day.toString().padLeft(2, '0');
    final String hh = dt.hour.toString().padLeft(2, '0');
    final String mi = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}-$mm-$dd $hh:$mi';
  }

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final double availableWidth = MediaQuery.sizeOf(context).width - 96;
    final double availableHeight = MediaQuery.sizeOf(context).height - 240;
    final double width = availableWidth < 560 ? availableWidth : 560;
    final double height = availableHeight < 240
        ? 240
        : (availableHeight > 430 ? 430 : availableHeight);
    return AlertDialog(
      title: Row(
        children: <Widget>[
          Icon(Icons.restore_from_trash_outlined, size: 20, color: ink.primary),
          const SizedBox(width: AppTokens.s2),
          const Text('回收站'),
        ],
      ),
      content: SizedBox(width: width, height: height, child: _buildBody(ink)),
      actions: <Widget>[
        if (!_loading && _error == null && _entries.isNotEmpty)
          TextButton(
            onPressed: _busy ? null : _purgeAll,
            child: Text('清空回收站', style: TextStyle(color: ink.danger)),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildBody(AppInk ink) {
    if (_loading) {
      return const SingleChildScrollView(child: SkeletonList(rows: 4));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('回收站读取失败', style: AppFonts.text(ink.ink, size: 14)),
            const SizedBox(height: AppTokens.s2),
            Text(_error!, style: AppFonts.text(ink.inkFaint, size: 12)),
            const SizedBox(height: AppTokens.s3),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return const EmptyState(
        icon: Icons.restore_from_trash_outlined,
        message: '回收站是空的',
        hint: '删除的作品会在这里保留 30 天（最多 50 份），期间可以随时恢复。',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '删除的作品会保留 30 天（最多 50 份），可随时恢复；清空后无法找回。',
          style: AppFonts.text(ink.inkFaint, size: 12, height: 1.5),
        ),
        const SizedBox(height: AppTokens.s2),
        Expanded(
          child: ListView.separated(
            itemCount: _entries.length,
            separatorBuilder: (_, __) => Divider(height: 1, color: ink.divider),
            itemBuilder: (BuildContext context, int index) {
              final TrashEntry entry = _entries[index];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.menu_book_outlined,
                  size: 20,
                  color: ink.inkSoft,
                ),
                title: Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.text(
                    ink.ink,
                    size: 13.5,
                    weight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '${entry.chapterCount} 章 · ${TextFmt.words(entry.wordCount)} 字'
                  ' · ${_date(entry.deletedAt)} 删除',
                  style: AppFonts.text(ink.inkFaint, size: 11.5, height: 1.5),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      tooltip: '恢复',
                      icon: const Icon(Icons.restore, size: 18),
                      onPressed: _busy ? null : () => _restore(entry),
                    ),
                    IconButton(
                      tooltip: '永久删除',
                      icon: Icon(
                        Icons.delete_forever_outlined,
                        size: 18,
                        color: ink.danger,
                      ),
                      onPressed: _busy ? null : () => _purge(entry),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
