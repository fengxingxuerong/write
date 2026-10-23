import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';

/// 章节回收站中的一章。
class ChapterTrashEntry {
  /// 构造条目。
  const ChapterTrashEntry({
    required this.novelId,
    required this.chapterId,
    required this.title,
    required this.content,
    required this.outline,
    required this.order,
    required this.deletedAt,
    required this.filePath,
  });

  /// 所属作品 id。
  final String novelId;

  /// 原章节 id（恢复时沿用）。
  final String chapterId;

  /// 章节标题。
  final String title;

  /// 正文。
  final String content;

  /// 章节大纲。
  final String outline;

  /// 删除前的顺序（恢复时尽量放回原位置）。
  final int order;

  /// 删除时间。
  final DateTime deletedAt;

  /// 回收站文件路径。
  final String filePath;

  /// 字数。
  int get wordCount => AppConstants.countWords(content);
}

/// 章节回收站接口（UI 与测试依赖它）。
abstract interface class ChapterTrashStore {
  /// 列出某本书的已删章节。
  Future<List<ChapterTrashEntry>> list(String novelId);

  /// 恢复一章。
  Future<Chapter> restore(ChapterTrashEntry entry);

  /// 永久删除一条。
  Future<void> purge(ChapterTrashEntry entry);

  /// 清空某本书的章节回收站。
  Future<void> purgeAll(String novelId);
}

/// 章节级回收站：删除单章时保留正文与大纲，30 天内可恢复。
///
/// 与作品回收站分开存放：
/// - 作品：`novels/trash/projects/`
/// - 章节：`novels/trash/chapters/<novelId>/`
///
/// 这样「清空作品回收站」不会误删仍可恢复的章节。
class ChapterTrashService implements ChapterTrashStore {
  /// 构造服务。
  const ChapterTrashService(this.db);

  final AppDatabase db;

  /// 保留天数。
  static const int retentionDays = 30;

  /// 每本书最多保留的已删章节数。
  static const int maxEntriesPerNovel = 50;

  String get _sep => Platform.pathSeparator;

  /// 章节回收站根目录。
  Directory get root =>
      Directory('${db.directory.path}${_sep}trash${_sep}chapters');

  /// 某本书的章节回收站目录。
  Directory directoryFor(String novelId) =>
      Directory('${root.path}$_sep$novelId');

  /// 把章节写进回收站。
  ///
  /// 调用方（[ChapterRepository.deleteChapter]）已持有该作品的锁；
  /// 写入失败会抛出异常并中止删除，保证「删不掉」而不是「删了找不回」。
  Future<void> moveToTrash(Chapter chapter) async {
    final Directory dir = directoryFor(chapter.novelId);
    await dir.create(recursive: true);
    final DateTime now = DateTime.now();
    File file = File(
      '${dir.path}$_sep${now.millisecondsSinceEpoch}-${chapter.id}.json',
    );
    int suffix = 1;
    while (await file.exists()) {
      file = File(
        '${dir.path}$_sep${now.millisecondsSinceEpoch}-${chapter.id}-$suffix.json',
      );
      suffix++;
    }
    final Map<String, dynamic> payload = chapter.toJson()
      ..['deletedAt'] = now.toIso8601String();
    try {
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (e) {
      if (await file.exists()) {
        file.delete().ignore();
      }
      throw StorageException('章节移入回收站失败', e);
    }
    try {
      await _trim(chapter.novelId);
    } catch (_) {
      // 回收站超出上限的清理失败不应让「删除章节」本身失败。
    }
  }

  @override
  Future<List<ChapterTrashEntry>> list(String novelId) async {
    final DateTime now = DateTime.now();
    await purgeExpired(novelId, now: now);
    await _trim(novelId);
    final Directory dir = directoryFor(novelId);
    if (!await dir.exists()) return <ChapterTrashEntry>[];
    final List<ChapterTrashEntry> entries = <ChapterTrashEntry>[];
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final ChapterTrashEntry? entry = await _read(entity, novelId);
      if (entry != null) entries.add(entry);
    }
    entries.sort(
      (ChapterTrashEntry a, ChapterTrashEntry b) =>
          b.deletedAt.compareTo(a.deletedAt),
    );
    return entries;
  }

  @override
  Future<Chapter> restore(ChapterTrashEntry entry) {
    return db.withNovelLock(entry.novelId, () async {
      final Novel novel = await db.readNovel(entry.novelId);
      if (novel.chapters.any((Chapter c) => c.id == entry.chapterId)) {
        throw const StorageException('这一章已经存在，无需恢复');
      }
      final DateTime now = DateTime.now();
      final List<Chapter> chapters = List<Chapter>.from(novel.chapters)
        ..sort((Chapter a, Chapter b) => a.order.compareTo(b.order));
      final int insertAt = entry.order.clamp(0, chapters.length).toInt();
      chapters.insert(
        insertAt,
        Chapter(
          id: entry.chapterId,
          novelId: entry.novelId,
          title: entry.title.trim().isEmpty ? '恢复的章节' : entry.title,
          order: insertAt,
          content: entry.content,
          outline: entry.outline,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final List<Chapter> reindexed = chapters
          .asMap()
          .entries
          .map((MapEntry<int, Chapter> e) => e.value.copyWith(order: e.key))
          .toList();
      final Novel updated = novel.copyWith(chapters: reindexed, updatedAt: now);
      await db.writeNovel(updated);
      await db.refreshIndexEntry(updated);
      try {
        await _deleteFile(entry.filePath);
      } catch (_) {
        // 正文已恢复；回收站文件清理失败不影响恢复结果。
      }
      return reindexed[insertAt];
    });
  }

  @override
  Future<void> purge(ChapterTrashEntry entry) async {
    await _deleteFile(entry.filePath);
  }

  @override
  Future<void> purgeAll(String novelId) async {
    final Directory dir = directoryFor(novelId);
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      throw StorageException('清空章节回收站失败', e);
    }
  }

  /// 清理过期的章节记录。
  Future<void> purgeExpired(String novelId, {DateTime? now}) async {
    final Directory dir = directoryFor(novelId);
    if (!await dir.exists()) return;
    final DateTime reference = now ?? DateTime.now();
    final DateTime cutoff = reference.subtract(
      const Duration(days: retentionDays),
    );
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final ChapterTrashEntry? entry = await _read(entity, novelId);
      if (entry == null) continue;
      if (entry.deletedAt.isBefore(cutoff)) {
        try {
          await entity.delete();
        } catch (_) {
          // 自动清理失败不阻塞列表。
        }
      }
    }
  }

  Future<void> _trim(String novelId) async {
    final Directory dir = directoryFor(novelId);
    if (!await dir.exists()) return;
    final List<ChapterTrashEntry> entries = <ChapterTrashEntry>[];
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final ChapterTrashEntry? entry = await _read(entity, novelId);
      if (entry != null) entries.add(entry);
    }
    if (entries.length <= maxEntriesPerNovel) return;
    entries.sort(
      (ChapterTrashEntry a, ChapterTrashEntry b) =>
          a.deletedAt.compareTo(b.deletedAt),
    );
    for (int i = 0; i < entries.length - maxEntriesPerNovel; i++) {
      try {
        await _deleteFile(entries[i].filePath);
      } catch (_) {
        // 自动清理失败不阻塞删除。
      }
    }
  }

  Future<ChapterTrashEntry?> _read(File file, String novelId) async {
    try {
      final Map<String, dynamic> json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final Chapter chapter = Chapter.fromJson(json);
      if (chapter.novelId != novelId) return null;
      return ChapterTrashEntry(
        novelId: novelId,
        chapterId: chapter.id,
        title: chapter.title,
        content: chapter.content,
        outline: chapter.outline,
        order: chapter.order,
        deletedAt:
            DateTime.tryParse(json['deletedAt'] as String? ?? '') ??
            file.statSync().modified,
        filePath: file.path,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteFile(String path) async {
    final File file = File(path);
    try {
      if (await file.exists()) {
        await file.delete();
      }
      final Directory parent = file.parent;
      if (await parent.exists()) {
        final bool empty = await parent.list().isEmpty;
        if (empty) await parent.delete();
      }
    } catch (e) {
      throw StorageException('清理章节回收站失败', e);
    }
  }
}
