import 'dart:async';
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

  /// per-novelId 异步锁，保证同一小说的读写串行化、不同小说可并发。
  static final Map<String, Completer<void>> _locks = <String, Completer<void>>{};

  /// 获取指定 novelId 的排他锁并执行 [action]。
  ///
  /// 锁粒度为 per-novelId：不同小说的 [action] 可并发，同一小说的 [action] 严格串行。
  /// 实现「登记-等待」链：每个调用者先登记自己的 [Completer]，再等待**前一个**
  /// 持有者完成——锁释放瞬间只有一个等待者被唤醒，严格 FIFO 排队。
  /// （旧实现是 while 轮询队尾，锁释放瞬间全部等待者同时醒来竞争去抢
  /// `_locks[novelId]`，先到先得，顺序并不保证。）避免 read-modify-write
  /// 竞争导致数据丢失。
  Future<T> withNovelLock<T>(String novelId, Future<T> Function() action) async {
    final Completer<void>? prev = _locks[novelId];
    final Completer<void> current = Completer<void>();
    _locks[novelId] = current;
    try {
      if (prev != null) {
        try {
          await prev.future;
        } catch (_) {
          // 前一持锁者异常不应卡住队列。
        }
      }
      return await action();
    } finally {
      // 防御：只有自己仍是队尾时才移除，避免误删后来者的登记。
      if (identical(_locks[novelId], current)) {
        _locks.remove(novelId);
      }
      current.complete();
    }
  }

  /// 索引写入队尾（全局单锁）。index.json 是跨项目共享的单个文件，
  /// per-novelId 锁罩不住它：两个不同项目同时落库会各自 readIndex →
  /// writeIndex，后写者把前者的条目抹掉。
  static Completer<void>? _indexTail;

  /// 获取索引排他锁并执行 [action]（所有 index.json 的 read-modify-write 都该走这里）。
  ///
  /// 与 [withNovelLock] 相同的「登记-等待」链实现，严格 FIFO。
  /// 加锁顺序约定：**先 [withNovelLock] 再本方法**；不得反向嵌套，否则死锁。
  Future<T> withIndexLock<T>(Future<T> Function() action) async {
    final Completer<void>? prev = _indexTail;
    final Completer<void> done = Completer<void>();
    _indexTail = done;
    try {
      if (prev != null) {
        try {
          await prev.future;
        } catch (_) {
          // 前一个持锁者失败不应卡住排队者。
        }
      }
      return await action();
    } finally {
      if (identical(_indexTail, done)) {
        _indexTail = null;
      }
      done.complete();
    }
  }

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

  /// 应用支持目录（品牌路径根，不含 novels 子目录）。
  ///
  /// 用于崩溃日志等需要独立于数据目录的场景；
  /// 即使 [init] 失败也可安全调用（只依赖 path_provider）。
  static Future<Directory> supportDirectory() async {
    return getApplicationSupportDirectory();
  }

  /// 初始化失败时的兜底实例（使用系统临时目录，保证 UI 可启动）。
  ///
  /// 数据不可持久化，但应用不会因数据库初始化失败而崩溃。
  static AppDatabase fallback() {
    final Directory dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}novel_writer_fallback',
    );
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
  /// 主文件缺失（如上次原子替换中断）或损坏时自动尝试备份文件
  /// （`<id>.bak.json`）自愈：备份可用则返回备份数据并把备份恢复为主文件；
  /// 均不可用才抛异常。
  Future<Novel> readNovel(String id) async {
    final File file = novelFile(id);
    if (!await file.exists()) {
      final File bak = novelBackupFile(id);
      if (!await bak.exists()) {
        throw const StorageException('项目文件不存在');
      }
      // 主文件缺失但备份在：先恢复主文件再走正常读取。
      try {
        await bak.copy(file.path);
      } catch (_) {
        throw const StorageException('项目文件不存在');
      }
    }
    Novel? fallback;
    try {
      final Novel novel = await decodeNovel(await file.readAsString());
      return novel;
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
  /// 供主文件损坏时自愈。JSON 序列化按体量自动分流（见 [encodeNovel]）。
  Future<void> writeNovel(Novel novel) async {
    final File file = novelFile(novel.id);
    final File tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(
        await encodeNovel(novel),
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

  /// 刷新索引里该项目的摘要（章数/字数/标题/归档态）。
  ///
  /// index.json 是首页列表的唯一数据源：章节写完不刷它，首页会一直显示旧字数。
  /// 调用方若已持有该项目的 [withNovelLock]，锁顺序天然满足「先 novel 后 index」。
  Future<void> refreshIndexEntry(Novel novel) {
    return withIndexLock(() async {
      final List<NovelSummary> index = await readIndex();
      index.removeWhere((NovelSummary e) => e.id == novel.id);
      index.add(NovelSummary(
        id: novel.id,
        title: novel.title,
        genre: novel.genre,
        updatedAt: novel.updatedAt,
        archived: novel.archived,
        wordCount: novel.wordCount(),
        chapterCount: novel.chapters.length,
      ));
      index.sort((NovelSummary a, NovelSummary b) =>
          b.updatedAt.compareTo(a.updatedAt));
      await writeIndex(index);
    });
  }

  /// 判断项目文件是否存在。
  Future<bool> exists(String id) => novelFile(id).exists();

  /// 整本小说序列化：体量大时下沉后台 isolate，避免主线程掉帧。
  ///
  /// 数百章 × 2 万字的整本 `jsonEncode` 输入可达数 MB，纯主 isolate 编码
  /// 会卡 UI（自动保存每 3 秒一次）。内容字符量超过
  /// [AppConstants.isolateJsonThresholdChars] 时用 `compute` 在后台
  /// isolate 编码；小于阈值直接同步编，省掉 isolate 往返开销。
  /// Web 平台无 isolate 支持，恒走同步路径。
  static Future<String> encodeNovel(Novel novel) {
    if (kIsWeb || _novelCharSize(novel) < AppConstants.isolateJsonThresholdChars) {
      return Future<String>.value(_encodeNovelJson(novel));
    }
    return compute(_encodeNovelJson, novel);
  }

  /// 整本小说反序列化：分流策略同 [encodeNovel]。
  ///
  /// 解码 + `Novel.fromJson` 一起放进 isolate，大书解析同样不占主线程。
  static Future<Novel> decodeNovel(String raw) {
    if (kIsWeb || raw.length < AppConstants.isolateJsonThresholdChars) {
      return Future<Novel>.value(_decodeNovelJson(raw));
    }
    return compute(_decodeNovelJson, raw);
  }

  /// 估算小说内容的字符量（正文/存稿为主），作为 isolate 分流依据。
  static int _novelCharSize(Novel novel) {
    int size = novel.title.length + novel.chapters.length * 64;
    for (final c in novel.chapters) {
      size += c.content.length + c.title.length;
    }
    for (final d in novel.drafts) {
      size += d.content.length;
    }
    return size;
  }

  /// 顶层可序列化编码（compute 跨 isolate 只能调静态/顶层函数）。
  static String _encodeNovelJson(Novel novel) => jsonEncode(novel.toJson());

  /// 顶层可序列化解码（compute 跨 isolate 只能调静态/顶层函数）。
  static Novel _decodeNovelJson(String raw) =>
      Novel.fromJson(jsonDecode(raw) as Map<String, dynamic>);
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
