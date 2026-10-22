import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/core/utils/manuscript_parser.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/storage/novel_repository.dart';

/// 原稿读取结果：解析完成、尚未入库。
///
/// 预览阶段就把整篇正文留在内存里，用户确认后直接写入，避免二次读文件时
/// 文件被外部程序改动，导致「预览的章数」和「实际导入的章数」不一致。
class ManuscriptImportPreview {
  /// 构造预览结果。
  const ManuscriptImportPreview({
    required this.fileName,
    required this.suggestedTitle,
    required this.manuscript,
  });

  /// 源文件名（只用于展示）。
  final String fileName;

  /// 建议作品名（默认取文件名，去掉扩展名）。
  final String suggestedTitle;

  /// 解析出的章节。
  final ParsedManuscript manuscript;
}

/// 把 TXT / Markdown 原稿导入为书架作品。
///
/// 设计约束：
/// - 只读取、不修改源文件；
/// - 解析失败不落任何项目数据（不会留下半本空书）；
/// - 章节 ID 全部新生成，书内顺序取原文出现顺序。
class ManuscriptImportService {
  /// 构造导入服务。
  const ManuscriptImportService(this._repository);

  final NovelRepository _repository;

  /// 读取并解析原稿文件。
  Future<ManuscriptImportPreview> readFile(File file) async {
    if (!await file.exists()) {
      throw const StorageException('原稿文件不存在');
    }
    final int length = await file.length();
    if (length <= 0) {
      throw const StorageException('原稿文件为空');
    }
    if (length > ManuscriptParser.maxBytes) {
      throw const StorageException('原稿超过 50 MiB，已拒绝导入');
    }

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException catch (error) {
      throw StorageException('读取原稿失败', error);
    }

    final ParsedManuscript manuscript;
    try {
      manuscript = ManuscriptParser.parse(ManuscriptParser.decodeBytes(bytes));
    } on FormatException catch (error) {
      throw StorageException('原稿解析失败：${error.message}');
    } on StorageException {
      rethrow;
    } catch (error) {
      throw StorageException('原稿解析失败', error);
    }

    if (manuscript.totalWords <= 0) {
      throw const StorageException('原稿没有可导入的正文');
    }

    return ManuscriptImportPreview(
      fileName: _fileName(file.path),
      suggestedTitle: ManuscriptParser.suggestTitle(file.path),
      manuscript: manuscript,
    );
  }

  /// 把预览结果保存为新作品。
  Future<Novel> save(
    ManuscriptImportPreview preview, {
    required String title,
    required String genre,
    required String tone,
  }) async {
    const Uuid uuid = Uuid();
    final String novelId = uuid.v4();
    final DateTime now = DateTime.now();
    final String cleanTitle = title.trim().isEmpty ? '未命名作品' : title.trim();

    final List<Chapter> chapters = <Chapter>[
      for (int i = 0; i < preview.manuscript.chapters.length; i++)
        Chapter(
          id: uuid.v4(),
          novelId: novelId,
          title: preview.manuscript.chapters[i].title.trim().isEmpty
              ? '第${i + 1}章'
              : preview.manuscript.chapters[i].title.trim(),
          order: i,
          content: preview.manuscript.chapters[i].content,
          createdAt: now,
          updatedAt: now,
        ),
    ];

    // 导入的是已有成稿：用它的章均字数做写作目标，比统一 2000/20000 更贴近
    // 作者的实际情况。上下限防止极短样章或整本单章把进度条做成无意义刻度。
    final int averageWords = preview.manuscript.totalWords ~/ chapters.length;
    final int targetWords = averageWords < 500
        ? 500
        : (averageWords > AppConstants.defaultMaxWordsPerChapter
              ? AppConstants.defaultMaxWordsPerChapter
              : averageWords);

    final Novel novel = Novel(
      id: novelId,
      title: cleanTitle,
      genre: genre.trim().isEmpty ? AppConstants.defaultGenre : genre,
      tone: tone.trim().isEmpty ? AppConstants.defaultTone : tone,
      targetWordsPerChapter: targetWords,
      createdAt: now,
      updatedAt: now,
      chapters: chapters,
      characters: const <Character>[],
      worldSettings: const <WorldSetting>[],
    );
    return _repository.saveNovel(novel);
  }

  static String _fileName(String path) {
    final int index = path.lastIndexOf(RegExp(r'[\\/]'));
    return index < 0 ? path : path.substring(index + 1);
  }
}
