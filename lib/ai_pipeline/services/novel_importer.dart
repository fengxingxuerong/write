import 'package:uuid/uuid.dart';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/novel_repository.dart';

/// 把流水线任务生成的书导入书架（创建 Novel 项目 + 写入章节）。
///
/// 导入后用户可在书架中继续编辑、导出 epub/docx 等。
class NovelImporter {
  /// 构造导入器。
  NovelImporter(this._novelRepo, this._db);

  final NovelRepository _novelRepo;
  final AppDatabase _db;
  final Map<String, Future<String>> _importsInFlight =
      <String, Future<String>>{};
  final Map<String, String> _importedIdsByTaskId = <String, String>{};

  /// 将任务章节导入为书架项目，返回新项目 id。
  ///
  /// 导入使用由任务 id 派生的稳定作品 id：即使应用在“创建作品”和“回写
  /// importedNovelId”之间退出，重试也会命中原作品而不会重复建书。同一进程
  /// 内共享进行中的 Future，避免并发点击重复执行。
  Future<String> importTask(AiPipelineTask task) async {
    final String stableNovelId = _stableNovelId(task.id);
    final String? importedId = task.importedNovelId;
    if (importedId != null && importedId.isNotEmpty) {
      if (await _db.exists(importedId)) {
        _importedIdsByTaskId[task.id] = importedId;
        return importedId;
      }
      // 作品可能被用户删除；不要把已经不存在的旧 id 当成成功结果。
      task.importedNovelId = null;
      _importedIdsByTaskId.remove(task.id);
    }
    final String? cachedId = _importedIdsByTaskId[task.id];
    if (cachedId != null) {
      if (await _db.exists(cachedId)) {
        task.importedNovelId = cachedId;
        return cachedId;
      }
      _importedIdsByTaskId.remove(task.id);
    }
    final Future<String>? inFlight = _importsInFlight[task.id];
    if (inFlight != null) {
      final String id = await inFlight;
      task.importedNovelId = id;
      return id;
    }

    final Future<String> operation = _importTaskUnlocked(task, stableNovelId);
    _importsInFlight[task.id] = operation;
    try {
      final String id = await operation;
      _importedIdsByTaskId[task.id] = id;
      task.importedNovelId = id;
      return id;
    } finally {
      if (identical(_importsInFlight[task.id], operation)) {
        _importsInFlight.remove(task.id);
      }
    }
  }

  /// 同一任务始终映射到同一个作品 id；不依赖进程内缓存即可恢复幂等性。
  String _stableNovelId(String taskId) {
    const String prefix = 'inksmith-pipeline:';
    return const Uuid().v5(Namespace.url.value, '$prefix$taskId');
  }

  Future<String> _importTaskUnlocked(
    AiPipelineTask task,
    String stableNovelId,
  ) async {
    if (task.chapters.isEmpty) {
      throw StateError('任务还没有章节，无法导入书架');
    }
    // 处理进程重启或另一实例已完成导入的情况。
    if (await _db.exists(stableNovelId)) {
      final Novel existing = await _novelRepo.getNovel(stableNovelId);
      // createNovel 成功但写入章节前进程退出时，稳定 id 已存在但作品为空；
      // 仅在空作品上继续补写，避免覆盖用户已经编辑过的章节。
      if (existing.chapters.isNotEmpty) {
        return stableNovelId;
      }
      final List<Chapter> recovered = _buildChapters(task, stableNovelId);
      await _novelRepo.saveNovel(existing.copyWith(chapters: recovered));
      return stableNovelId;
    }
    final Novel novel = await _novelRepo.createNovel(
      id: stableNovelId,
      title: task.title,
      genre: task.config.genre,
      tone: task.config.genre,
    );
    final List<Chapter> chapters = _buildChapters(task, novel.id);
    final Novel updated = novel.copyWith(chapters: chapters);
    await _novelRepo.saveNovel(updated);
    return novel.id;
  }

  List<Chapter> _buildChapters(AiPipelineTask task, String novelId) {
    final DateTime now = DateTime.now();
    return task.chapters
        .map(
          (PipelineChapter c) => Chapter(
            id: const Uuid().v4(),
            novelId: novelId,
            title: c.title,
            order: c.idx,
            content: c.content,
            outline: '',
            createdAt: now,
            updatedAt: now,
          ),
        )
        .toList();
  }

  /// 检查任务是否已导入（书架中是否有对应项目）。
  Future<bool> isImported(AiPipelineTask task) async {
    final String? id = task.importedNovelId;
    if (id != null && id.isNotEmpty && await _db.exists(id)) {
      return true;
    }
    // 任务状态可能尚未回写 importedNovelId，但稳定 id 对应的作品已经存在。
    return _db.exists(_stableNovelId(task.id));
  }
}
