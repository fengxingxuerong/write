import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/core/security/secret_store.dart';

/// 流水线任务持久化（断点存储）。
///
/// 每个任务一个 `<id>.json`（含进度：大纲 + 已生成章节 + 日志），
/// 另维护 `index.json` 保存任务列表摘要。写入采用「临时文件 + 原子重命名」。
class PipelineStorage {
  /// 构造存储；凭据保护器必须显式注入，避免生产环境静默退回内存实现。
  PipelineStorage(this.directory, {required this.secretStore});

  /// 存储目录（`applicationSupportDirectory/ai_pipeline`）。
  final String directory;

  /// 流水线配置中的凭据保护器。
  final SecretStore secretStore;

  /// 同一目录的串行写队列键（不同 PipelineStorage 实例也共享）。
  String get _queueKey => directory.replaceAll('\\', '/').toLowerCase();

  /// 同一目录下所有存储实例共用的 FIFO 队列。
  static final Map<String, Future<void>> _queues = <String, Future<void>>{};

  /// 在目录级 FIFO 队列中执行操作。
  Future<T> _exclusive<T>(Future<T> Function() action) async {
    final String key = _queueKey;
    final Future<void>? previous = _queues[key];
    final Completer<void> current = Completer<void>();
    _queues[key] = current.future;
    try {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // 前一个写操作失败不应阻塞后续操作。
        }
      }
      return await action();
    } finally {
      if (identical(_queues[key], current.future)) {
        _queues.remove(key);
      }
      current.complete();
    }
  }

  /// 任务文件。
  File taskFile(String id) => File('$directory/$id.json');

  /// 最近一次任务配置（配置页预填）。
  File get recentConfigFile => File('$directory/recent_config.json');

  /// 索引文件。
  File get indexFile => File('$directory/index.json');

  /// 确保目录存在。
  Future<void> ensureDir() async {
    final Directory dir = Directory(directory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// 保存任务（原子写，目录级串行）。
  Future<void> saveTask(AiPipelineTask task) =>
      _exclusive(() => _saveTaskUnlocked(task));

  /// 判断 JSON 树中是否仍有明文 `apiKey` 字段。
  bool _containsPlainApiKey(Object? value) {
    if (value is Map) {
      for (final MapEntry<Object?, Object?> entry in value.entries) {
        if (entry.key == 'apiKey' && entry.value is String) return true;
        if (_containsPlainApiKey(entry.value)) return true;
      }
    } else if (value is List) {
      for (final Object? child in value) {
        if (_containsPlainApiKey(child)) return true;
      }
    }
    return false;
  }

  /// 读取持久化 JSON 并解密配置中的凭据。
  Future<Map<String, dynamic>> _restoreJson(Object? value) async {
    return Map<String, dynamic>.from(
      (await unprotectJsonSecrets(value, secretStore)) as Map,
    );
  }

  Future<void> _saveTaskUnlocked(AiPipelineTask task) async {
    await ensureDir();
    final File file = taskFile(task.id);
    final File backup = File('${file.path}.bak');
    final File tmp = File('${file.path}.tmp');
    try {
      final Object? protected = await protectJsonSecrets(
        task.toJson(),
        secretStore,
      );
      await tmp.writeAsString(jsonEncode(protected), flush: true);
      if (await file.exists()) {
        final bool backupReady = await _preserveProtectedBackup(file, backup);
        if (!backupReady) {
          throw StateError('无法安全备份现有流水线任务');
        }
        await file.delete();
      }
      await tmp.rename(file.path);
      await _appendIndex(task);
    } catch (e) {
      if (await tmp.exists()) await tmp.delete().ignore();
      throw StorageException('流水线任务保存失败', e);
    }
  }

  /// 迁移旧文件时避免把明文凭据复制到 `.bak`。
  /// 返回 false 表示旧文件无法安全备份，调用方不得删除原文件。
  Future<bool> _preserveProtectedBackup(File file, File backup) async {
    final File backupTmp = File('${backup.path}.tmp');
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      final Object? protected = await protectJsonSecrets(decoded, secretStore);
      await backupTmp.writeAsString(jsonEncode(protected), flush: true);
      if (await backup.exists()) await backup.delete();
      await backupTmp.rename(backup.path);
      return true;
    } catch (_) {
      if (await backupTmp.exists()) await backupTmp.delete().ignore();
      return false;
    }
  }

  /// 读取任务；不存在返回 null（目录级串行）。
  Future<AiPipelineTask?> loadTask(String id) =>
      _exclusive(() => _loadTaskUnlocked(id));

  Future<AiPipelineTask?> _loadTaskUnlocked(String id) async {
    final File file = taskFile(id);
    final File backup = File('${file.path}.bak');
    if (!await file.exists()) {
      if (!await backup.exists()) return null;
      try {
        final Object? decoded = jsonDecode(await backup.readAsString());
        final Map<String, dynamic> json = await _restoreJson(decoded);
        final AiPipelineTask task = AiPipelineTask.fromJson(json);
        await backup.copy(file.path).ignore();
        if (_containsPlainApiKey(decoded)) {
          try {
            await _saveTaskUnlocked(task);
            if (await backup.exists()) await backup.delete().ignore();
          } catch (_) {
            // 迁移失败时仍返回已恢复的任务，保留原文件供下次重试。
          }
        }
        return task;
      } catch (e) {
        throw StorageException('流水线任务读取失败', e);
      }
    }
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      final Map<String, dynamic> json = await _restoreJson(decoded);
      final AiPipelineTask task = AiPipelineTask.fromJson(json);
      if (_containsPlainApiKey(decoded)) {
        try {
          await _saveTaskUnlocked(task);
        } catch (_) {
          // 迁移失败不应阻断已成功读取的任务。
        }
      }
      return task;
    } catch (e) {
      if (await backup.exists()) {
        try {
          final Object? decoded = jsonDecode(await backup.readAsString());
          final Map<String, dynamic> json = await _restoreJson(decoded);
          final AiPipelineTask task = AiPipelineTask.fromJson(json);
          await backup.copy(file.path).ignore();
          if (_containsPlainApiKey(decoded)) {
            try {
              await _saveTaskUnlocked(task);
            } catch (_) {
              // 迁移失败不应阻断备份恢复。
            }
          }
          return task;
        } catch (_) {
          // 备份也损坏时保留主文件错误，不覆盖原始现场。
        }
      }
      throw StorageException('流水线任务读取失败', e);
    }
  }

  /// 列出全部任务（按创建时间倒序，目录级串行）。
  Future<List<AiPipelineTask>> listTasks() => _exclusive(_listTasksUnlocked);

  Future<List<AiPipelineTask>> _listTasksUnlocked() async {
    await ensureDir();
    final Set<String> ids = <String>{};
    final File index = indexFile;
    if (await index.exists()) {
      try {
        final List<dynamic> list =
            jsonDecode(await index.readAsString()) as List<dynamic>;
        for (final dynamic e in list) {
          if (e is Map && e['id'] is String) ids.add(e['id'] as String);
        }
      } catch (_) {
        // 索引损坏不阻断任务恢复，继续扫描任务文件。
      }
    }
    try {
      await for (final FileSystemEntity entity in Directory(directory).list()) {
        if (entity is! File) continue;
        final String name = entity.uri.pathSegments.last;
        if (!name.endsWith('.json') ||
            name == 'index.json' ||
            name == 'recent_config.json') {
          continue;
        }
        ids.add(name.substring(0, name.length - '.json'.length));
      }
    } catch (_) {
      // 目录扫描失败时仍返回索引中可读取的任务。
    }
    final List<AiPipelineTask> tasks = <AiPipelineTask>[];
    for (final String id in ids) {
      try {
        final AiPipelineTask? task = await _loadTaskUnlocked(id);
        if (task != null) tasks.add(task);
      } catch (_) {
        // 单个任务损坏不应阻断其它任务显示。
      }
    }
    tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return tasks;
  }

  /// 保存最近一次任务配置（原子写，目录级串行）。
  Future<void> saveRecentConfig(AiPipelineConfig config) =>
      _exclusive(() => _saveRecentConfigUnlocked(config));

  Future<void> _saveRecentConfigUnlocked(AiPipelineConfig config) async {
    await ensureDir();
    final File file = recentConfigFile;
    final File tmp = File('${file.path}.tmp');
    try {
      final Object? protected = await protectJsonSecrets(
        config.toJson(),
        secretStore,
      );
      await tmp.writeAsString(jsonEncode(protected), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      if (await tmp.exists()) await tmp.delete().ignore();
      // 配置记忆失败不阻塞主流程。
    }
  }

  /// 读取最近一次任务配置；无则返回 null（目录级串行）。
  Future<AiPipelineConfig?> loadRecentConfig() =>
      _exclusive(_loadRecentConfigUnlocked);

  Future<AiPipelineConfig?> _loadRecentConfigUnlocked() async {
    final File file = recentConfigFile;
    if (!await file.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      final Map<String, dynamic> json = await _restoreJson(decoded);
      final AiPipelineConfig config = AiPipelineConfig.fromJson(json);
      if (_containsPlainApiKey(decoded)) {
        await _saveRecentConfigUnlocked(config);
      }
      return config;
    } catch (_) {
      return null;
    }
  }

  /// 删除任务（含索引记录，目录级串行）。
  Future<void> deleteTask(String id) =>
      _exclusive(() => _deleteTaskUnlocked(id));

  Future<void> _deleteTaskUnlocked(String id) async {
    final File file = taskFile(id);
    for (final File extra in <File>[
      file,
      File('${file.path}.bak'),
      File('${file.path}.tmp'),
    ]) {
      if (await extra.exists()) await extra.delete().ignore();
    }
    // 重建索引（去掉该任务）。
    try {
      final List<AiPipelineTask> all = await _listTasksUnlocked();
      final List<Map<String, dynamic>> index = all
          .map((AiPipelineTask t) => <String, dynamic>{'id': t.id})
          .toList();
      final File tmp = File('${indexFile.path}.tmp');
      await tmp.writeAsString(jsonEncode(index), flush: true);
      await tmp.rename(indexFile.path);
    } catch (_) {
      // 索引重建失败不阻塞。
    }
  }

  /// 把任务 id 追加进索引（去重）。
  Future<void> _appendIndex(AiPipelineTask task) async {
    final List<Map<String, dynamic>> index = <Map<String, dynamic>>[];
    final File indexF = indexFile;
    if (await indexF.exists()) {
      try {
        final List<dynamic> list =
            jsonDecode(await indexF.readAsString()) as List<dynamic>;
        for (final dynamic e in list) {
          final Map<String, dynamic> m = e as Map<String, dynamic>;
          if (m['id'] != task.id) index.add(m);
        }
      } catch (_) {
        // 索引损坏时重建。
      }
    }
    index.add(<String, dynamic>{'id': task.id});
    final File tmp = File('${indexF.path}.tmp');
    await tmp.writeAsString(jsonEncode(index), flush: true);
    await tmp.rename(indexF.path);
  }
}

/// 忽略异常的清理扩展。
extension _FutureIgnore<T> on Future<T> {
  /// 吞掉异常。
  Future<void> ignore() async {
    try {
      await this;
    } catch (_) {
      // 忽略。
    }
  }
}
