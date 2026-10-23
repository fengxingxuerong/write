import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';

/// 回收站中的一本作品。
class TrashEntry {
  /// 构造回收站条目。
  const TrashEntry({
    required this.id,
    required this.title,
    required this.genre,
    required this.chapterCount,
    required this.wordCount,
    required this.deletedAt,
    required this.folderPath,
  });

  /// 原作品 id（恢复时沿用）。
  final String id;

  /// 书名。
  final String title;

  /// 题材 key。
  final String genre;

  /// 章数。
  final int chapterCount;

  /// 字数。
  final int wordCount;

  /// 删除时间。
  final DateTime deletedAt;

  /// 回收站条目目录（含作品 JSON 与 meta.json）。
  final String folderPath;
}

/// 回收站接口：UI 只依赖它，测试可替换为内存实现。
abstract interface class TrashStore {
  /// 列出可恢复的作品（按删除时间倒序）。
  Future<List<TrashEntry>> list();

  /// 恢复一本作品并重建书架索引。
  Future<Novel> restore(TrashEntry entry);

  /// 永久删除一条回收站记录。
  Future<void> purge(TrashEntry entry);

  /// 清空回收站。
  Future<void> purgeAll();
}

/// 本地作品回收站。
///
/// 删除作品不再直接删文件，而是把主文件与备份文件移动到
/// `novels/trash/<millis>-<id>/`，并写一份 `meta.json` 供列表展示。
/// 默认保留 30 天、最多 50 份；超期/超量自动清理，用户也可以手动永久删除。
///
/// 为什么保留原始 JSON 而不是只存一份摘要：恢复必须做到**逐字还原**，
/// 章节正文、角色、世界观、导出偏好都不能在回收站里被重新序列化一遍。
class TrashService implements TrashStore {
  /// 构造服务。
  const TrashService(this.db);

  final AppDatabase db;

  /// 保留天数。
  static const int retentionDays = 30;

  /// 最多保留条目数。
  static const int maxEntries = 50;

  String get _sep => Platform.pathSeparator;

  /// 回收站根目录。
  Directory get directory => Directory('${db.directory.path}${_sep}trash');

  /// 把一本作品移入回收站。
  ///
  /// 必须在 [AppDatabase.withNovelLock] 内调用：移动主文件期间不能让自动保存
  /// 或另一实例写回同一个项目。
  Future<void> moveToTrash(String id, {Novel? novel}) async {
    final File main = db.novelFile(id);
    final File bak = db.novelBackupFile(id);
    final bool hasMain = await main.exists();
    final bool hasBak = await bak.exists();
    if (!hasMain && !hasBak) return;
    await directory.create(recursive: true);

    final DateTime now = DateTime.now();
    Directory folder = Directory(
      '${directory.path}$_sep${now.millisecondsSinceEpoch}-$id',
    );
    int suffix = 1;
    while (await folder.exists()) {
      folder = Directory(
        '${directory.path}$_sep${now.millisecondsSinceEpoch}-$id-$suffix',
      );
      suffix++;
    }
    await folder.create(recursive: true);

    final Map<String, dynamic> meta = <String, dynamic>{
      'id': id,
      'title': novel?.title ?? '未知作品',
      'genre': novel?.genre ?? '',
      'chapterCount': novel?.chapters.length ?? 0,
      'wordCount': novel?.wordCount() ?? 0,
      'deletedAt': now.toIso8601String(),
    };
    await File(
      '${folder.path}${_sep}meta.json',
    ).writeAsString(jsonEncode(meta), flush: true);

    final File trashMain = File('${folder.path}$_sep$id.json');
    final File trashBak = File('${folder.path}$_sep$id.bak.json');
    bool mainMoved = false;
    bool bakMoved = false;
    try {
      if (hasMain) {
        await main.rename(trashMain.path);
        mainMoved = true;
      }
      if (hasBak) {
        await bak.rename(trashBak.path);
        bakMoved = true;
      }
    } catch (e) {
      // 移动中途失败：能回滚就回滚，回滚不了就保留回收站目录，
      // 让用户还能从回收站里捞回文件，绝不再删一次。
      bool rolledBack = true;
      if (mainMoved) {
        try {
          await trashMain.rename(main.path);
        } catch (_) {
          rolledBack = false;
        }
      }
      if (bakMoved) {
        try {
          await trashBak.rename(bak.path);
        } catch (_) {
          rolledBack = false;
        }
      }
      if (rolledBack) {
        try {
          await folder.delete(recursive: true);
        } catch (_) {}
      }
      throw StorageException('移入回收站失败', e);
    }
    final File tmp = File('${main.path}.tmp');
    if (await tmp.exists()) {
      tmp.delete().ignore();
    }
  }

  @override
  Future<List<TrashEntry>> list() async {
    final DateTime now = DateTime.now();
    await purgeExpired(now: now);
    await _enforceLimit();
    final List<TrashEntry> entries = await _scan();
    entries.sort(
      (TrashEntry a, TrashEntry b) => b.deletedAt.compareTo(a.deletedAt),
    );
    return entries;
  }

  @override
  Future<Novel> restore(TrashEntry entry) {
    return db.withNovelLock(entry.id, () async {
      final Directory folder = Directory(entry.folderPath);
      final File source = File('${folder.path}$_sep${entry.id}.json');
      final File sourceBak = File('${folder.path}$_sep${entry.id}.bak.json');
      final bool hasMain = await source.exists();
      final bool hasBak = await sourceBak.exists();
      if (!hasMain && !hasBak) {
        throw const StorageException('回收站里的作品文件已丢失，无法恢复');
      }
      final File target = db.novelFile(entry.id);
      if (await target.exists()) {
        throw const StorageException('同 ID 的作品已存在，未恢复；请先处理现有作品');
      }

      if (hasMain) {
        await source.rename(target.path);
      } else {
        // 极端情况下只剩备份：用备份重建主文件，至少把正文救回来。
        await sourceBak.copy(target.path);
      }
      final File targetBak = db.novelBackupFile(entry.id);
      bool bakMoved = false;
      if (hasBak) {
        try {
          if (await targetBak.exists()) {
            targetBak.delete().ignore();
          }
          await sourceBak.rename(targetBak.path);
          bakMoved = true;
        } catch (_) {
          // 备份复制失败不影响主文件恢复；正文已在主文件里。
        }
      }

      final Novel novel;
      try {
        novel = await db.readNovel(entry.id);
        await db.refreshIndexEntry(novel);
      } catch (e) {
        // 恢复失败时把文件退回回收站，避免留下「文件在、索引里没有」的幽灵项目。
        try {
          if (hasMain) {
            if (await target.exists()) {
              await target.rename(source.path);
            }
          } else if (await target.exists()) {
            await target.delete();
          }
          if (bakMoved && await targetBak.exists()) {
            await targetBak.rename(sourceBak.path);
          }
          await db.withIndexLock(() async {
            final List<NovelSummary> index = await db.readIndex();
            index.removeWhere((NovelSummary e) => e.id == entry.id);
            await db.writeIndex(index);
          });
        } catch (_) {
          // 回滚失败不掩盖原始错误。
        }
        if (e is AppException) rethrow;
        throw StorageException('恢复作品失败', e);
      }

      // 恢复成功后清理回收站目录；删除失败不影响已恢复的作品，先删 meta
      // 让它从列表消失，避免出现「已恢复但仍可再次恢复」的重复项。
      try {
        const String metaName = 'meta.json';
        final File metaFile = File('${folder.path}$_sep$metaName');
        if (await metaFile.exists()) {
          await metaFile.delete();
        }
      } catch (_) {}
      try {
        if (await folder.exists()) {
          await folder.delete(recursive: true);
        }
      } catch (_) {}
      return novel;
    });
  }

  @override
  Future<void> purge(TrashEntry entry) async {
    await _deleteFolder(Directory(entry.folderPath));
  }

  @override
  Future<void> purgeAll() async {
    if (!await directory.exists()) return;
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is Directory) {
        await _deleteFolder(entity);
      }
    }
  }

  /// 清理超过保留期的条目（UI 打开回收站时调用）。
  Future<void> purgeExpired({DateTime? now}) async {
    if (!await directory.exists()) return;
    final DateTime reference = now ?? DateTime.now();
    final DateTime cutoff = reference.subtract(
      const Duration(days: retentionDays),
    );
    final List<TrashEntry> entries = await _scan();
    for (final TrashEntry entry in entries) {
      if (entry.deletedAt.isBefore(cutoff)) {
        try {
          await _deleteFolder(Directory(entry.folderPath));
        } catch (_) {
          // 自动清理失败不应让整个回收站打不开（可能是杀软短暂占用）。
        }
      }
    }
  }

  /// 超过上限时删最旧的条目，避免回收站无限增长。
  Future<void> _enforceLimit() async {
    final List<TrashEntry> entries = await _scan();
    if (entries.length <= maxEntries) return;
    entries.sort(
      (TrashEntry a, TrashEntry b) => a.deletedAt.compareTo(b.deletedAt),
    );
    final int removeCount = entries.length - maxEntries;
    for (int i = 0; i < removeCount; i++) {
      try {
        await _deleteFolder(Directory(entries[i].folderPath));
      } catch (_) {
        // 同上：自动清理失败不阻塞列表。
      }
    }
  }

  Future<List<TrashEntry>> _scan() async {
    if (!await directory.exists()) return <TrashEntry>[];
    final List<TrashEntry> entries = <TrashEntry>[];
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! Directory) continue;
      final TrashEntry? entry = await _readEntry(entity);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  Future<TrashEntry?> _readEntry(Directory folder) async {
    final File metaFile = File('${folder.path}${_sep}meta.json');
    try {
      final Map<String, dynamic> meta =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      final String id = meta['id'] as String;
      final bool hasMain = await File('${folder.path}$_sep$id.json').exists();
      final bool hasBak = await File(
        '${folder.path}$_sep$id.bak.json',
      ).exists();
      if (!hasMain && !hasBak) return null;
      return TrashEntry(
        id: id,
        title: (meta['title'] as String?)?.trim().isNotEmpty == true
            ? meta['title'] as String
            : '未知作品',
        genre: (meta['genre'] as String?) ?? '',
        chapterCount: (meta['chapterCount'] as num?)?.toInt() ?? 0,
        wordCount: (meta['wordCount'] as num?)?.toInt() ?? 0,
        deletedAt:
            DateTime.tryParse(meta['deletedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        folderPath: folder.path,
      );
    } catch (_) {
      // meta 损坏时仍尝试用目录名恢复，不能因为摘要坏了就把作品从列表里藏掉。
      final String name = folder.path.split(_sep).last;
      final int dash = name.indexOf('-');
      if (dash <= 0) return null;
      final String id = name.substring(dash + 1);
      if (!await File('${folder.path}$_sep$id.json').exists()) return null;
      final int millis = int.tryParse(name.substring(0, dash)) ?? 0;
      return TrashEntry(
        id: id,
        title: '未知作品',
        genre: '',
        chapterCount: 0,
        wordCount: 0,
        deletedAt: DateTime.fromMillisecondsSinceEpoch(millis),
        folderPath: folder.path,
      );
    }
  }

  Future<void> _deleteFolder(Directory folder) async {
    try {
      if (await folder.exists()) {
        await folder.delete(recursive: true);
      }
    } catch (e) {
      throw StorageException('清理回收站失败', e);
    }
  }
}
