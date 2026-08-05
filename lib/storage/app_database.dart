import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/novel.dart';

/// 本地存储数据库（基于 JSON 文件）。
///
/// 设计要点（主理人裁定）：
/// - 每个项目存为**单个 JSON 文件** `<id>.json`，内含 meta + chapters + characters + worldSettings；
/// - 另维护一个 `index.json` 索引，记录所有项目的摘要（用于首页列表，避免整本反序列化）；
/// - 写入采用「临时文件 + 原子重命名」，降低中途崩溃导致文件损坏的概率；
/// - 使用 [path_provider] 的 `applicationSupportDirectory`，各平台天然隔离，且单文件可拷贝迁移。
class AppDatabase {
  AppDatabase._(this.directory);

  /// 项目文件所在目录。
  final Directory directory;

  static AppDatabase? _instance;

  /// 初始化并缓存单例。确保目录存在。必须在 [runApp] 前调用。
  static Future<AppDatabase> init() async {
    if (_instance != null) return _instance!;
    final Directory base = await getApplicationSupportDirectory();
    final Directory dir =
        Directory('${base.path}/${AppConstants.novelsDirName}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // 品牌化迁移：旧版本（com.example 或无公司名）数据目录迁入新路径。
    await migrateLegacyData(base, dir);
    _instance = AppDatabase._(dir);
    return _instance!;
  }

  /// 将旧版（Runner.rc 未品牌化时期）的数据目录迁移到当前品牌路径。
  ///
  /// 旧版 getApplicationSupportDirectory() 返回 `%APPDATA%/com.example/novel_writer`
  /// 或 `%APPDATA%/novel_writer`（无 CompanyName 时）。品牌化后路径变为
  /// `%APPDATA%/InkSmith/墨匠`。仅当新目录为空且旧目录存在时执行搬迁，
  /// 失败不阻塞启动（下次启动重试）。
  @visibleForTesting
  static Future<void> migrateLegacyData(
      Directory base, Directory newDir) async {
    try {
      // 旧版数据目录位于 %APPDATA% 根下，而非 base 内：
      //   %APPDATA%/com.example/novel_writer 或 %APPDATA%/novel_writer。
      // 品牌路径固定为 CompanyName/ProductName 两级，故 base.parent.parent 即 %APPDATA%。
      final String appDataRoot = base.parent.parent.path;
      final List<Directory> legacyCandidates = <Directory>[
        Directory(
            '$appDataRoot${Platform.pathSeparator}com.example${Platform.pathSeparator}novel_writer'),
        Directory('$appDataRoot${Platform.pathSeparator}novel_writer'),
      ];
      for (final Directory legacy in legacyCandidates) {
        final Directory legacyNovels =
            Directory('${legacy.path}${Platform.pathSeparator}${AppConstants.novelsDirName}');
        if (!await legacyNovels.exists()) continue;
        // 新目录已有数据则跳过（防止覆盖）。
        final List<FileSystemEntity> newContent =
            await newDir.list().toList();
        if (newContent.isNotEmpty) continue;
        // 递归拷贝旧 novels 内容到新目录。
        await for (final FileSystemEntity entity in legacyNovels.list()) {
          final String target =
              '${newDir.path}${Platform.pathSeparator}${entity.uri.pathSegments.last}';
          if (entity is File) {
            await entity.copy(target);
          } else if (entity is Directory) {
            await _copyDirectory(entity, Directory(target));
          }
        }
        // 拷贝成功后删除旧数据（避免下次重复迁移）。
        try {
          await legacyNovels.delete(recursive: true);
        } catch (_) {
          // 删除失败不阻塞（下次启动会再迁，拷贝目标存在则跳过）。
        }
        return;
      }
    } catch (_) {
      // 迁移失败不阻塞启动；下次启动重试。
    }
  }

  /// 递归拷贝目录（含子目录与文件）。
  static Future<void> _copyDirectory(
      Directory source, Directory target) async {
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    await for (final FileSystemEntity entity in source.list()) {
      final String name = entity.uri.pathSegments.last;
      final String dest = '${target.path}${Platform.pathSeparator}$name';
      if (entity is File) {
        await entity.copy(dest);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(dest));
      }
    }
  }

  /// 测试专用：使用指定目录创建实例（不碰全局单例、不依赖 path_provider）。
  @visibleForTesting
  static AppDatabase initForTest(String path) {
    final Directory dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return AppDatabase._(dir);
  }

  /// 项目 json 文件。
  File novelFile(String id) => File('${directory.path}/$id.json');

  /// 项目备份文件（写入时保留上一份完好数据，损坏时可自愈）。
  File novelBackupFile(String id) => File('${directory.path}/$id.bak.json');

  /// 索引文件。
  File get indexFile => File('${directory.path}/index.json');

  /// 索引备份文件。
  File get indexBackupFile => File('${directory.path}/index.bak.json');

  /// 读取整本小说（单 json）。
  ///
  /// 主文件损坏时自动尝试备份文件（`<id>.bak.json`）自愈：
  /// 备份可用则返回备份数据并把备份恢复为主文件；均不可用才抛异常。
  Future<Novel> readNovel(String id) async {
    final File file = novelFile(id);
    if (!await file.exists()) {
      throw const StorageException('项目文件不存在');
    }
    Novel? fallback;
    try {
      final Map<String, dynamic> json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return Novel.fromJson(json);
    } on StorageException {
      rethrow;
    } catch (e) {
      // 主文件损坏：尝试备份自愈。
      final File bak = novelBackupFile(id);
      if (await bak.exists()) {
        try {
          final Map<String, dynamic> json =
              jsonDecode(await bak.readAsString()) as Map<String, dynamic>;
          fallback = Novel.fromJson(json);
        } catch (_) {
          fallback = null;
        }
      }
      if (fallback != null) {
        // 用备份恢复主文件。
        try {
          await bak.copy(file.path);
        } catch (_) {
          // 恢复失败不阻塞读取（内存中仍返回备份数据）。
        }
        return fallback;
      }
      throw StorageException('项目文件解析失败且无可用备份', e);
    }
  }

  /// 写入整本小说（原子写：先写临时文件再重命名）。
  ///
  /// 写入成功后把新文件备份为 `<id>.bak.json`（备份永远是最新完好数据），
  /// 供主文件损坏时自愈。
  Future<void> writeNovel(Novel novel) async {
    final File file = novelFile(novel.id);
    final File tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(
        jsonEncode(novel.toJson()),
        flush: true,
      );
      await tmp.rename(file.path);
      // 原子替换成功后，把新文件复制为备份。
      final File bak = novelBackupFile(novel.id);
      try {
        if (await bak.exists()) {
          await bak.delete().ignore();
        }
        await file.copy(bak.path);
      } catch (_) {
        // 备份失败不阻塞写入（主流程照常）。
      }
    } catch (e) {
      // 清理可能残留的临时文件。
      if (await tmp.exists()) {
        await tmp.delete().ignore();
      }
      throw StorageException('项目文件写入失败', e);
    }
  }

  /// 读取项目索引（首页列表用）。
  ///
  /// 主索引损坏时尝试备份自愈；均不可用时返回空列表（不阻塞首页）。
  Future<List<NovelSummary>> readIndex() async {
    final File file = indexFile;
    if (!await file.exists()) return <NovelSummary>[];
    try {
      final List<dynamic> list =
          jsonDecode(await file.readAsString()) as List<dynamic>;
      return list
          .map((e) => NovelSummary.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // 主索引损坏：尝试备份。
      try {
        final File bak = indexBackupFile;
        if (await bak.exists()) {
          final List<dynamic> list =
              jsonDecode(await bak.readAsString()) as List<dynamic>;
          final items = list
              .map((e) => NovelSummary.fromJson(e as Map<String, dynamic>))
              .toList();
          // 恢复主索引。
          await bak.copy(file.path).ignore();
          return items;
        }
      } catch (_) {
        // 备份也不可用，忽略。
      }
      return <NovelSummary>[];
    }
  }

  /// 写入项目索引（原子写 + 写后备份）。
  Future<void> writeIndex(List<NovelSummary> items) async {
    final File file = indexFile;
    final File tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(
        jsonEncode(items.map((e) => e.toJson()).toList()),
        flush: true,
      );
      await tmp.rename(file.path);
      final File bak = indexBackupFile;
      try {
        if (await bak.exists()) {
          await bak.delete().ignore();
        }
        await file.copy(bak.path);
      } catch (_) {
        // 备份失败不阻塞写入。
      }
    } catch (e) {
      if (await tmp.exists()) {
        await tmp.delete().ignore();
      }
      throw StorageException('索引文件写入失败', e);
    }
  }

  /// 判断项目文件是否存在。
  Future<bool> exists(String id) => novelFile(id).exists();
}

/// 忽略异步异常的便捷扩展。
extension _FutureIgnore<T> on Future<T> {
  /// 吞掉异常（用于清理型删除）。
  Future<void> ignore() async {
    try {
      await this;
    } catch (_) {
      // 忽略：清理操作失败不应影响主流程。
    }
  }
}
