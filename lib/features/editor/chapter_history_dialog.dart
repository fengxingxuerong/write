import 'package:flutter/material.dart';

import 'package:novel_writer/models/chapter_snapshot.dart';
import 'package:novel_writer/storage/chapter_snapshot_service.dart';

/// 章节历史版本弹窗：列出快照，选择一条恢复。
///
/// 返回选中的 [ChapterSnapshot]；取消返回 null。
/// 恢复动作由调用方执行（写回编辑器并保存）。
Future<ChapterSnapshot?> showChapterHistoryDialog(
  BuildContext context, {
  required ChapterSnapshotService service,
  required String novelId,
  required String chapterId,
}) {
  return showDialog<ChapterSnapshot>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: const Text('🕘 历史版本'),
      content: SizedBox(
        width: 460,
        height: 360,
        child: FutureBuilder<List<ChapterSnapshot>>(
          future: service.list(novelId, chapterId),
          builder: (BuildContext c, AsyncSnapshot<List<ChapterSnapshot>> s) {
            if (s.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final List<ChapterSnapshot> snaps = s.data ?? const <ChapterSnapshot>[];
            if (snaps.isEmpty) {
              return const Center(child: Text('暂无历史版本\n\n编辑保存后自动留底'));
            }
            return ListView.builder(
              itemCount: snaps.length,
              itemBuilder: (BuildContext c, int i) {
                final ChapterSnapshot snap = snaps[i];
                final String time =
                    '${snap.savedAt.month}/${snap.savedAt.day} '
                    '${snap.savedAt.hour.toString().padLeft(2, '0')}:'
                    '${snap.savedAt.minute.toString().padLeft(2, '0')}';
                final String preview =
                    snap.content.replaceAll(RegExp(r'\s+'), ' ');
                return ListTile(
                  dense: true,
                  leading: Text(
                    time,
                    style: Theme.of(c).textTheme.bodySmall,
                  ),
                  title: Text(
                    '${snap.title}（${snap.content.length} 字）',
                    style: Theme.of(c).textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    preview.isEmpty ? '（空）' : preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(c).textTheme.bodySmall,
                  ),
                  trailing: const Icon(Icons.restore, size: 18),
                  onTap: () => Navigator.of(ctx).pop(snap),
                );
              },
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
