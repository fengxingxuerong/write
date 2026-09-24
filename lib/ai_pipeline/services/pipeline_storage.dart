import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';

/// 流水线任务持久化（断点存储）。
///
/// 每个任务一个 `<id>.json`（含进度：大纲 + 已生成章节 + 日志），
/// 另维护 `index.json` 保存任务列表摘要。写入采用「临时文件 + 原子重命名」。
class PipelineStorage {
  /// 构造存储。
  PipelineStorage(this.directory);

  /// 存储目录（`applicationSupportDirectory/ai_pipeline`）。
  final String directory;

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

  Future<void> _saveTaskUnlocked(AiPipelineTask task) async {
    await ensureDir();
    final File file = taskFile(task.id);
    final File tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(
        jsonEncode(task.toJson()),
        flush: true,
      );
      await tmp.rename(file.path);
      await _appendIndex(task);
    } catch (e) {
      if (await tmp.exists()) await tmp.delete().ignore();
      throw StorageException('流水线任务保存失败', e);
    }
  }

  /// 读取任务；不存在返回 null（目录级串行）。
  Future<AiPipelineTask?> loadTask(String id) =>
      _exclusive(() => _loadTaskUnlocked(id));

  Future<AiPipelineTask?> _loadTaskUnlocked(String id) async {
    final File file = taskFile(id);
    if (!await file.exists()) return null;
    try {
      final Map<String, dynamic> json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return AiPipelineTask.fromJson(json);
    } catch (e) {
      throw StorageException('流水线任务读取失败', e);
    }
  }

  /// 列出全部任务（按创建时间倒序，目录级串行）。
  Future<List<AiPipelineTask>> listTasks() =>
      _exclusive(_listTasksUnlocked);

  Future<List<AiPipelineTask>> _listTasksUnlocked() async {
    await ensureDir();
    final File index = indexFile;
    if (!await index.exists()) return <AiPipelineTask>[];
    try {
      final List<dynamic> list =
          jsonDecode(await index.readAsString()) as List<dynamic>;
      final List<AiPipelineTask> tasks = <AiPipelineTask>[];
      for (final dynamic e in list) {
        final Map<String, dynamic> m = e as Map<String, dynamic>;
        final AiPipelineTask? task =
            await _loadTaskUnlocked(m['id'] as String? ?? '');
        if (task != null) tasks.add(task);
      }
      tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return tasks;
    } catch (_) {
      return <AiPipelineTask>[];
    }
  }

  /// 保存最近一次任务配置（原子写，目录级串行）。
  Future<void> saveRecentConfig(AiPipelineConfig config) =>
      _exclusive(() => _saveRecentConfigUnlocked(config));

  Future<void> _saveRecentConfigUnlocked(AiPipelineConfig config) async {
    await ensureDir();
    final File file = recentConfigFile;
    final File tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(jsonEncode(config.toJson()), flush: true);
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
      final Map<String, dynamic> json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return AiPipelineConfig.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// 删除任务（含索引记录，目录级串行）。
  Future<void> deleteTask(String id) =>
      _exclusive(() => _deleteTaskUnlocked(id));

  Future<void> _deleteTaskUnlocked(String id) async {
    final File file = taskFile(id);
    if (await file.exists()) await file.delete().ignore();
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
