import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/novel_repository.dart';

/// 项目列表视图状态。
class ProjectListState {
  /// 是否加载中。
  final bool isLoading;

  /// 项目摘要列表。
  final List<NovelSummary> novels;

  /// 错误信息。
  final String? error;

  /// 当前筛选：all / active / archived。
  final String filter;

  /// 搜索关键词（按标题过滤）。
  final String query;

  /// 构造状态。
  const ProjectListState({
    this.isLoading = false,
    this.novels = const <NovelSummary>[],
    this.error,
    this.filter = 'all',
    this.query = '',
  });

  /// 不可变更新副本。
  ProjectListState copyWith({
    bool? isLoading,
    List<NovelSummary>? novels,
    String? error,
    String? filter,
    String? query,
  }) {
    return ProjectListState(
      isLoading: isLoading ?? this.isLoading,
      novels: novels ?? this.novels,
      error: error,
      filter: filter ?? this.filter,
      query: query ?? this.query,
    );
  }

  /// 按当前筛选与搜索词过滤后的列表。
  List<NovelSummary> get visibleNovels {
    final List<NovelSummary> filtered = novels
        .where((n) => filter == 'all' || (filter == 'archived') == n.archived)
        .where((n) =>
            query.isEmpty || n.title.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return filtered;
  }
}

/// 项目列表视图模型。
///
/// 负责首页项目的新建、删除、重命名、归档与列表加载，统一捕获 [AppException]。
class ProjectListViewModel extends StateNotifier<ProjectListState> {
  /// 构造视图模型。
  ProjectListViewModel(this._repo) : super(const ProjectListState());

  final NovelRepository _repo;

  /// 加载项目列表。
  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final List<NovelSummary> novels = await _repo.listNovels();
      state = state.copyWith(isLoading: false, novels: novels);
    } on AppException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '加载失败：$e');
    }
  }

  /// 新建项目并刷新列表。
  Future<void> create(String title, String genre, String tone) async {
    try {
      await _repo.createNovel(title: title, genre: genre, tone: tone);
      await load();
    } on AppException catch (e) {
      state = state.copyWith(error: e.message);
    }
  }

  /// 删除项目并刷新列表。
  Future<void> delete(String id) async {
    try {
      await _repo.deleteNovel(id);
      await load();
    } on AppException catch (e) {
      state = state.copyWith(error: e.message);
    }
  }

  /// 重命名项目并刷新列表。
  Future<void> rename(String id, String title) async {
    try {
      await _repo.renameNovel(id, title);
      await load();
    } on AppException catch (e) {
      state = state.copyWith(error: e.message);
    }
  }

  /// 归档 / 取消归档项目并刷新列表。
  Future<void> setArchived(String id, bool archived) async {
    try {
      await _repo.setArchived(id, archived);
      await load();
    } on AppException catch (e) {
      state = state.copyWith(error: e.message);
    }
  }

  /// 设置筛选条件。
  void setFilter(String filter) => state = state.copyWith(filter: filter);

  /// 设置搜索关键词。
  void setQuery(String query) => state = state.copyWith(query: query);
}
