import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/models/chapter_snapshot.dart';

/// 章节版本快照服务：每次保存时留底正文，支持回滚。
///
/// - 存储位置：`{directory}/snapshots/{novelId}/{chapterId}/{millis}.json`；
/// - 内容去重：与最近一次快照相同则跳过（自动保存 3 秒一次不会刷屏）；
/// - 时间节流：非强制模式下两次快照至少间隔 [minInterval]；
/// - 容量上限：每章只保留最近 [keep] 条，超出删除最旧。
///
/// 所有 IO 异常向上抛出，由调用方（ChapterRepository）吞掉——
/// 快照失败绝不能影响正常保存。
class ChapterSnapshotService {
  /// 构造服务。[directory] 为应用数据根目录。
  const ChapterSnapshotService({
    required this.directory,
    this.keep = 20,
    this.minInterval = const Duration(seconds: 60),
  });

  /// 应用数据根目录。
  final String directory;

  /// 每章保留的快照数上限。
  final int keep;

  /// 非强制捕获的最小时间间隔。
  final Duration minInterval;

  /// 某章节的快照目录。
  Directory _dir(String novelId, String chapterId) =>
      Directory('$directory/snapshots/$novelId/$chapterId');

  /// 捕获一次快照。
  ///
  /// [force] 为 true 时跳过时间节流（如 AI 覆盖正文前的强制留底），
  /// 但内容去重仍然生效。
  Future<void> capture(
    String novelId,
    String chapterId, {
    required String title,
    required String content,
    bool force = false,
  }) async {
    final Directory dir = _dir(novelId, chapterId);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final List<ChapterSnapshot> existing = await list(novelId, chapterId);

    // 首次快照：跳过空正文（空章节没有留底价值）。
    if (existing.isEmpty && content.trim().isEmpty) return;

    if (existing.isNotEmpty) {
      final ChapterSnapshot latest = existing.first;
      // 内容未变：跳过。
      if (latest.content == content) return;
      // 时间节流（强制模式除外）。
      if (!force &&
          DateTime.now().difference(latest.savedAt) < minInterval) {
        return;
      }
    }

    final int millis = DateTime.now().millisecondsSinceEpoch;
    final File file = File('${dir.path}/$millis.json');
    final ChapterSnapshot snapshot = ChapterSnapshot(
      savedAt: DateTime.now(),
      title: title,
      content: content,
    );
    await file.writeAsString(snapshot.encode(), flush: true);

    // 裁剪：只保留最近 [keep] 条。
    final List<ChapterSnapshot> all = await list(novelId, chapterId);
    if (all.length > keep) {
      final List<File> files = await _files(dir);
      for (int i = keep; i < files.length; i++) {
        try {
          await files[i].delete();
        } catch (_) {
          // 单个删除失败忽略（下次裁剪重试）。
        }
      }
    }
  }

  /// 列出某章节的快照（按时间倒序，最新在前）。
  Future<List<ChapterSnapshot>> list(String novelId, String chapterId) async {
    final Directory dir = _dir(novelId, chapterId);
    if (!await dir.exists()) return const <ChapterSnapshot>[];
    final List<ChapterSnapshot> out = <ChapterSnapshot>[];
    for (final File f in await _files(dir)) {
      try {
        final String text = await f.readAsString();
        out.add(ChapterSnapshot.fromJson(
          jsonDecode(text) as Map<String, dynamic>,
        ));
      } catch (_) {
        // 单个损坏文件跳过，不影响其余快照。
      }
    }
    return out;
  }

  /// 快照文件列表（按文件名即时间戳倒序）。
  Future<List<File>> _files(Directory dir) async {
    final List<FileSystemEntity> entities = await dir.list().toList();
    final List<File> files = entities
        .whereType<File>()
        .where((File f) => f.path.endsWith('.json'))
        .toList()
      ..sort((File a, File b) => b.path.compareTo(a.path));
    return files;
  }
}
