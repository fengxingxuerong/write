import 'dart:async';

import 'package:uuid/uuid.dart';

import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/chapter_draft.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/chapter_snapshot_service.dart';

/// 章节仓库：在单 json 内对 chapters 做增删改、排序与自动保存。
///
/// 所有写操作均读取整本 [Novel] → 局部修改 → 原子落盘，保证数据一致。
/// 若注入 [ChapterSnapshotService]，内容写入时自动留底版本快照。
class ChapterRepository {
  /// 构造仓库。[snapshots] 可选：注入后启用版本快照。
  const ChapterRepository(this.db, {this.snapshots});

  /// 数据库句柄。
  final AppDatabase db;

  /// 版本快照服务（null 表示禁用快照）。
  final ChapterSnapshotService? snapshots;

  /// 发起一次快照（fire-and-forget：失败不影响保存主流程）。
  void _snap(
    String novelId,
    String chapterId, {
    required String title,
    required String content,
    bool force = false,
  }) {
    final ChapterSnapshotService? s = snapshots;
    if (s == null) return;
    unawaited(
      s.capture(
        novelId,
        chapterId,
        title: title,
        content: content,
        force: force,
      ).catchError((Object _) {
        // 快照失败静默：绝不能影响保存。
      }),
    );
  }

  /// 列出章节（按 order 升序）。
  Future<List<Chapter>> listChapters(String novelId) async {
    final Novel novel = await db.readNovel(novelId);
    final List<Chapter> chapters = List<Chapter>.from(novel.chapters)
      ..sort((a, b) => a.order.compareTo(b.order));
    return chapters;
  }

  /// 读取单个章节。
  Future<Chapter> getChapter(String novelId, String chapterId) async {
    final Novel novel = await db.readNovel(novelId);
    return novel.chapters.firstWhere((c) => c.id == chapterId);
  }

  /// 新增空章节（排在末尾）。
  Future<Chapter> addChapter(String novelId, {String? title}) async {
    final Novel novel = await db.readNovel(novelId);
    final int order = novel.chapters.length;
    final DateTime now = DateTime.now();
    final Chapter chapter = Chapter(
      id: const Uuid().v4(),
      novelId: novelId,
      title: (title?.trim().isNotEmpty ?? false) ? title!.trim() : '第${order + 1}章',
      order: order,
      content: '',
      createdAt: now,
      updatedAt: now,
    );
    final Novel updated = novel.copyWith(chapters: <Chapter>[
      ...novel.chapters,
      chapter,
    ]);
    await db.writeNovel(updated);
    return chapter;
  }

  /// 自动保存：仅更新正文与 updatedAt（主编防抖后调用）。
  Future<void> updateChapterContent(
    String novelId,
    String chapterId,
    String content,
  ) async {
    final Novel novel = await db.readNovel(novelId);
    final Chapter? target =
        novel.chapters.where((c) => c.id == chapterId).firstOrNull;
    final List<Chapter> chapters = novel.chapters.map((c) {
      return c.id == chapterId
          ? c.copyWith(content: content, updatedAt: DateTime.now())
          : c;
    }).toList();
    await db.writeNovel(novel.copyWith(chapters: chapters));
    if (target != null) {
      _snap(novelId, chapterId, title: target.title, content: content);
    }
  }

  /// 更新整个章节对象（标题等）。返回更新后的章节。
  Future<Chapter> updateChapter(String novelId, Chapter chapter) async {
    final Novel novel = await db.readNovel(novelId);
    final List<Chapter> chapters = novel.chapters.map((c) {
      return c.id == chapter.id
          ? chapter.copyWith(updatedAt: DateTime.now())
          : c;
    }).toList();
    await db.writeNovel(novel.copyWith(chapters: chapters));
    return chapter;
  }

  /// 生成结果落库：按 order 覆盖或新增章节。返回落库后的章节。
  ///
  /// 覆盖已有章节时，先把**旧正文**强制留底快照（force：跳过节流）——
  /// AI 重新生成/手动覆盖是内容丢失的最高风险场景。
  Future<Chapter> saveGeneratedChapter(
    String novelId,
    int order,
    String title,
    String content,
  ) async {
    final Novel novel = await db.readNovel(novelId);
    final DateTime now = DateTime.now();
    final Chapter? overwritten =
        novel.chapters.where((c) => c.order == order).firstOrNull;
    if (overwritten != null) {
      _snap(
        novelId,
        overwritten.id,
        title: overwritten.title,
        content: overwritten.content,
        force: true,
      );
    }
    final List<Chapter> chapters = novel.chapters.map((c) {
      return c.order == order
          ? c.copyWith(content: content, title: title, updatedAt: now)
          : c;
    }).toList();

    final bool exists = novel.chapters.any((c) => c.order == order);
    if (!exists) {
      chapters.add(Chapter(
        id: const Uuid().v4(),
        novelId: novelId,
        title: title,
        order: order,
        content: content,
        createdAt: now,
        updatedAt: now,
      ));
    }
    chapters.sort((a, b) => a.order.compareTo(b.order));
    await db.writeNovel(novel.copyWith(chapters: chapters));
    return chapters.firstWhere((c) => c.order == order);
  }

  /// 删除章节，并重新索引 order 保持连续。
  Future<void> deleteChapter(String novelId, String chapterId) async {
    final Novel novel = await db.readNovel(novelId);
    final List<Chapter> remaining = novel.chapters
        .where((c) => c.id != chapterId)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final List<Chapter> reindexed =
        remaining.asMap().entries.map((e) => e.value.copyWith(order: e.key)).toList();
    await db.writeNovel(novel.copyWith(chapters: reindexed));
  }

  /// 将一个章节按分隔块拆分为多个章节（自动章节分割）。
  ///
  /// [parts] 为分割后的正文列表（按顺序），第一个块保留在当前章节，
  /// 其余块作为新章节插入到原章节之后；所有章节重新索引 order。
  /// 返回分割后的章节列表（按 order 升序）。
  Future<List<Chapter>> splitChapter(
    String novelId,
    String chapterId,
    List<String> parts,
  ) async {
    if (parts.isEmpty) return listChapters(novelId);
    final Novel novel = await db.readNovel(novelId);
    final List<Chapter> chapters = List<Chapter>.from(novel.chapters)
      ..sort((a, b) => a.order.compareTo(b.order));
    final int idx = chapters.indexWhere((c) => c.id == chapterId);
    if (idx < 0) return chapters;

    final Chapter origin = chapters[idx];
    final DateTime now = DateTime.now();
    // 原章节保留第一块。
    final Chapter first = origin.copyWith(
      content: parts.first.trim(),
      title: origin.title.trim().isNotEmpty ? origin.title : '第${idx + 1}章',
      updatedAt: now,
    );
    final List<Chapter> newOnes = <Chapter>[
      for (int i = 1; i < parts.length; i++)
        Chapter(
          id: const Uuid().v4(),
          novelId: novelId,
          title: '第${idx + i + 1}章',
          order: 0, // 稍后重排。
          content: parts[i].trim(),
          createdAt: now,
          updatedAt: now,
        ),
    ];
    final List<Chapter> rebuilt = <Chapter>[
      ...chapters.take(idx),
      first,
      ...newOnes,
      ...chapters.skip(idx + 1),
    ];
    final List<Chapter> reindexed = rebuilt
        .asMap()
        .entries
        .map((e) => e.value.copyWith(order: e.key))
        .toList();
    await db.writeNovel(novel.copyWith(chapters: reindexed));
    return reindexed;
  }

  /// 列出存稿箱条目（按创建时间倒序）。
  Future<List<ChapterDraft>> listDrafts(String novelId) async {
    final Novel novel = await db.readNovel(novelId);
    final List<ChapterDraft> drafts = List<ChapterDraft>.from(novel.drafts)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return drafts;
  }

  /// 新增存稿（不满意的 AI 生成结果或手动暂存）。
  Future<ChapterDraft> addDraft(
    String novelId, {
    String title = '未命名草稿',
    required String content,
  }) async {
    final Novel novel = await db.readNovel(novelId);
    final ChapterDraft draft = ChapterDraft(
      id: const Uuid().v4(),
      novelId: novelId,
      title: title.trim().isEmpty ? '未命名草稿' : title.trim(),
      content: content,
      createdAt: DateTime.now(),
    );
    final Novel updated = novel.copyWith(drafts: <ChapterDraft>[
      ...novel.drafts,
      draft,
    ]);
    await db.writeNovel(updated);
    return draft;
  }

  /// 删除存稿条目。
  Future<void> deleteDraft(String novelId, String draftId) async {
    final Novel novel = await db.readNovel(novelId);
    final Novel updated = novel.copyWith(
      drafts: novel.drafts.where((d) => d.id != draftId).toList(),
    );
    await db.writeNovel(updated);
  }

  /// 存稿转正：把存稿内容作为新章节追加到末尾，并删除该存稿。
  /// 返回新增的正式章节。
  Future<Chapter> promoteDraft(
    String novelId,
    String draftId, {
    String? title,
  }) async {
    final Novel novel = await db.readNovel(novelId);
    final ChapterDraft? draft =
        novel.drafts.where((d) => d.id == draftId).firstOrNull;
    if (draft == null) {
      throw StateError('存稿不存在：$draftId');
    }
    final int order = novel.chapters.length;
    final DateTime now = DateTime.now();
    final Chapter chapter = Chapter(
      id: const Uuid().v4(),
      novelId: novelId,
      title: (title?.trim().isNotEmpty ?? false)
          ? title!.trim()
          : (draft.title.trim().isNotEmpty ? draft.title : '第${order + 1}章'),
      order: order,
      content: draft.content,
      createdAt: now,
      updatedAt: now,
    );
    final Novel updated = novel.copyWith(
      chapters: <Chapter>[...novel.chapters, chapter],
      drafts: novel.drafts.where((d) => d.id != draftId).toList(),
    );
    await db.writeNovel(updated);
    return chapter;
  }

  /// 按给定 id 顺序重排章节（拖拽 / 上移下移后调用）。
  Future<void> reorderChapters(String novelId, List<String> orderedIds) async {
    final Novel novel = await db.readNovel(novelId);
    final Map<String, Chapter> byId = <String, Chapter>{
      for (final c in novel.chapters) c.id: c,
    };
    final List<Chapter> chapters = <Chapter>[];
    for (int i = 0; i < orderedIds.length; i++) {
      final Chapter? c = byId[orderedIds[i]];
      if (c != null) chapters.add(c.copyWith(order: i));
    }
    // 兜底：把未在 orderedIds 中的章节追加在末尾。
    for (final c in novel.chapters) {
      if (!orderedIds.contains(c.id)) {
        chapters.add(c.copyWith(order: chapters.length));
      }
    }
    chapters.sort((a, b) => a.order.compareTo(b.order));
    await db.writeNovel(novel.copyWith(chapters: chapters));
  }
}
