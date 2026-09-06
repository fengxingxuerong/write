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

  /// 将任务章节导入为书架项目，返回新项目 id。
  ///
  /// 已导入过的任务会直接返回既有 id（幂等，避免重复建书）。
  Future<String> importTask(AiPipelineTask task) async {
    if (task.importedNovelId != null && task.importedNovelId!.isNotEmpty) {
      return task.importedNovelId!;
    }
    if (task.chapters.isEmpty) {
      throw StateError('任务还没有章节，无法导入书架');
    }
    final Novel novel = await _novelRepo.createNovel(
      title: task.title,
      genre: task.config.genre,
      tone: task.config.genre,
    );
    final List<Chapter> chapters = task.chapters
        .map(
          (PipelineChapter c) => Chapter(
            id: const Uuid().v4(),
            novelId: novel.id,
            title: c.title,
            order: c.idx,
            content: c.content,
            outline: '',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        )
        .toList();
    final Novel updated = novel.copyWith(chapters: chapters);
    await _novelRepo.saveNovel(updated);
    return novel.id;
  }

  /// 检查任务是否已导入（书架中是否有对应项目）。
  Future<bool> isImported(AiPipelineTask task) async {
    final String? id = task.importedNovelId;
    if (id == null || id.isEmpty) return false;
    return _db.exists(id);
  }
}
