import 'dart:io';

import 'package:uuid/uuid.dart';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';

/// 项目仓库：负责单 json 文件的读写与索引维护。
///
/// 作为章节/设定仓库的「单一数据源」——它们都通过 [AppDatabase] 读取整本小说后局部修改再落盘。
///
/// **并发约定**：所有读-改-写都跑在 [AppDatabase.withNovelLock] 内，
/// 索引更新再套一层 [AppDatabase.withIndexLock]（index.json 跨项目共享）。
/// 加锁顺序恒为「先 novel、后 index」，反向嵌套会死锁。
class NovelRepository {
  /// 构造仓库。
  const NovelRepository(this.db);

  /// 数据库句柄。
  final AppDatabase db;

  /// 列出所有项目摘要（按最近更新倒序）。
  Future<List<NovelSummary>> listNovels() async {
    final List<NovelSummary> index = await db.readIndex();
    index.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return index;
  }

  /// 读取整本小说（含章节/角色/世界观）。
  Future<Novel> getNovel(String id) => db.readNovel(id);

  /// 新建项目（默认空章节/角色/世界观）。
  Future<Novel> createNovel({
    required String title,
    required String genre,
    required String tone,
  }) async {
    final DateTime now = DateTime.now();
    final Novel novel = Novel(
      id: const Uuid().v4(),
      title: title.trim().isEmpty ? '未命名作品' : title.trim(),
      genre: genre,
      tone: tone,
      targetWordsPerChapter: AppConstants.defaultMaxWordsPerChapter,
      createdAt: now,
      updatedAt: now,
      chapters: <Chapter>[],
      characters: <Character>[],
      worldSettings: <WorldSetting>[],
    );
    // 全新 id 不存在竞争，但索引写入必须与别的落库串行。
    await db.writeNovel(novel);
    await _upsertIndex(novel);
    return novel;
  }

  /// 整体保存（会刷新 updatedAt 并更新索引）。
  ///
  /// 供外部直接持有整本 [Novel] 时调用；只改元信息请优先用 [renameNovel]
  /// 等细粒度方法，它们自带锁内读-改-写，不会用旧快照覆盖并发的正文写入。
  Future<Novel> saveNovel(Novel novel) async {
    return db.withNovelLock(novel.id, () async {
      final Novel updated = novel.copyWith(updatedAt: DateTime.now());
      await db.writeNovel(updated);
      await _upsertIndex(updated);
      return updated;
    });
  }

  /// 锁内读-改-写整本小说：调用方只描述「怎么改」，不自己拿快照。
  ///
  /// 任何「先 getNovel → copyWith → saveNovel」的写法在并发生成/自动保存下
  /// 都可能用旧快照抹掉别人的写入，请改用本方法。
  Future<Novel> mutateNovel(
    String id,
    Novel Function(Novel novel) transform,
  ) {
    return db.withNovelLock(id, () async {
      final Novel novel = await db.readNovel(id);
      return _saveLocked(transform(novel));
    });
  }

  /// 重命名项目。
  Future<Novel> renameNovel(String id, String title) {
    final String t = title.trim().isEmpty ? '未命名作品' : title.trim();
    return mutateNovel(id, (Novel novel) => novel.copyWith(title: t));
  }

  /// 归档 / 取消归档项目。
  Future<Novel> setArchived(String id, bool archived) {
    return mutateNovel(id, (Novel novel) => novel.copyWith(archived: archived));
  }

  /// 删除项目（删除 json 文件并从索引移除）。
  Future<void> deleteNovel(String id) async {
    final File file = db.novelFile(id);
    if (await file.exists()) {
      await file.delete();
    }
    await db.withIndexLock(() async {
      final List<NovelSummary> index = await db.readIndex();
      index.removeWhere((e) => e.id == id);
      await db.writeIndex(index);
    });
  }

  /// 锁内保存（调用方已持有该 novel 的锁，故不再套一层 [saveNovel]）。
  Future<Novel> _saveLocked(Novel novel) async {
    final Novel updated = novel.copyWith(updatedAt: DateTime.now());
    await db.writeNovel(updated);
    await _upsertIndex(updated);
    return updated;
  }

  /// 在索引中插入或更新该项目的摘要（实现见 [AppDatabase.refreshIndexEntry]）。
  Future<void> _upsertIndex(Novel novel) => db.refreshIndexEntry(novel);
}
