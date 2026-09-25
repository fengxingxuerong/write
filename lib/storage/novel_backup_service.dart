import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/novel_repository.dart';

/// 桌面端 JSON 备份导入服务。
///
/// 备份是项目级完整快照，但导入默认采用「复制恢复」策略：绝不沿用备份中的
/// 项目/实体 ID，避免覆盖现有项目或让导入数据与已有项目发生关联冲突。
class NovelBackupService {
  /// 构造导入服务。
  const NovelBackupService(this._repository);

  /// 单个备份文件大小上限（100 MiB），防止误选超大文件耗尽内存。
  static const int maxBackupBytes = 100 * 1024 * 1024;

  final NovelRepository _repository;

  /// 从 JSON 备份恢复一部作品并返回新作品。
  ///
  /// 恢复失败抛出 [StorageException]；文件格式错误不会写入任何项目数据。
  Future<Novel> importFile(File file) async {
    if (!await file.exists()) {
      throw const StorageException('备份文件不存在');
    }
    final int length = await file.length();
    if (length <= 0) {
      throw const StorageException('备份文件为空');
    }
    if (length > maxBackupBytes) {
      throw const StorageException('备份文件超过 100 MiB，已拒绝导入');
    }

    final String raw = await file.readAsString();
    final String normalized = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
    if (normalized.trim().isEmpty) {
      throw const StorageException('备份文件没有内容');
    }

    final Novel source;
    try {
      final dynamic decoded = jsonDecode(normalized);
      if (decoded is! Map) {
        throw const FormatException('顶层不是 JSON 对象');
      }
      source = Novel.fromJson(Map<String, dynamic>.from(decoded));
    } catch (error) {
      throw StorageException('备份格式无效，无法恢复作品', error);
    }

    final Novel restored = _cloneAsNewProject(source);
    // saveNovel 只写入新生成的 UUID，不会覆盖备份中同 ID 的现有项目。
    return _repository.saveNovel(restored);
  }

  Novel _cloneAsNewProject(Novel source) {
    const Uuid uuid = Uuid();
    final String novelId = uuid.v4();
    final DateTime importedAt = DateTime.now();
    return source.copyWith(
      id: novelId,
      title: source.title.trim().isEmpty ? '未命名作品' : source.title.trim(),
      updatedAt: importedAt,
      chapters: source.chapters
          .map((chapter) => chapter.copyWith(
                id: uuid.v4(),
                novelId: novelId,
              ))
          .toList(),
      characters: source.characters
          .map((character) => character.copyWith(
                id: uuid.v4(),
                novelId: novelId,
              ))
          .toList(),
      worldSettings: source.worldSettings
          .map((setting) => setting.copyWith(
                id: uuid.v4(),
                novelId: novelId,
              ))
          .toList(),
      drafts: source.drafts
          .map((draft) => draft.copyWith(
                id: uuid.v4(),
                novelId: novelId,
              ))
          .toList(),
    );
  }
}
