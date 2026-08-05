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
    await db.writeNovel(novel);
    await _upsertIndex(novel);
    return novel;
  }

  /// 整体保存（会刷新 updatedAt 并更新索引）。
  Future<Novel> saveNovel(Novel novel) async {
    final Novel updated = novel.copyWith(updatedAt: DateTime.now());
    await db.writeNovel(updated);
    await _upsertIndex(updated);
    return updated;
  }

  /// 重命名项目。
  Future<Novel> renameNovel(String id, String title) async {
    final Novel novel = await db.readNovel(id);
    return saveNovel(novel.copyWith(title: title.trim().isEmpty ? '未命名作品' : title.trim()));
  }

  /// 归档 / 取消归档项目。
  Future<Novel> setArchived(String id, bool archived) async {
    final Novel novel = await db.readNovel(id);
    return saveNovel(novel.copyWith(archived: archived));
  }

  /// 删除项目（删除 json 文件并从索引移除）。
  Future<void> deleteNovel(String id) async {
    final File file = db.novelFile(id);
    if (await file.exists()) {
      await file.delete();
    }
    final List<NovelSummary> index = await db.readIndex();
    index.removeWhere((e) => e.id == id);
    await db.writeIndex(index);
  }

  /// 在索引中插入或更新该项目的摘要。
  Future<void> _upsertIndex(Novel novel) async {
    final List<NovelSummary> index = await db.readIndex();
    index.removeWhere((e) => e.id == novel.id);
    index.add(NovelSummary(
      id: novel.id,
      title: novel.title,
      genre: novel.genre,
      updatedAt: novel.updatedAt,
      archived: novel.archived,
      wordCount: novel.wordCount(),
      chapterCount: novel.chapters.length,
    ));
    index.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await db.writeIndex(index);
  }
}
