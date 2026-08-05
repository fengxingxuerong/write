import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/llm_engine.dart';
import 'package:novel_writer/engine/template_engine.dart';
import 'package:novel_writer/features/generate/generate_viewmodel.dart';
import 'package:novel_writer/features/project_list/project_list_viewmodel.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/models/reader_settings.dart';
import 'package:novel_writer/services/sensitive_words.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/storage/goal_repository.dart';
import 'package:novel_writer/storage/novel_repository.dart';
import 'package:novel_writer/storage/setting_repository.dart';

/// 主题模式（浅色/深色/跟随系统），全局可切换。
final StateProvider<ThemeMode> themeModeProvider =
    StateProvider<ThemeMode>((ref) => ThemeMode.system);

/// 本地存储数据库句柄。
///
/// 必须由 [main] 在 `runApp` 前通过 `overrideWithValue` 注入已初始化的实例；
/// 默认实现抛 [UnimplementedError]，防止误用未初始化实例。
final Provider<AppDatabase> appDatabaseProvider =
    Provider<AppDatabase>((ref) {
  throw UnimplementedError(
    'appDatabaseProvider 必须在 runApp 前通过 overrideWithValue 注入 AppDatabase 实例',
  );
});

/// 敏感词检测服务（内置词库 + 用户词持久化到应用目录）。
final Provider<SensitiveWordsService> sensitiveWordsProvider =
    Provider<SensitiveWordsService>((ref) {
  final String dir = ref.watch(appDatabaseProvider).directory.path;
  return SensitiveWordsService(
    customPath: '$dir${Platform.pathSeparator}sensitive_words.json',
    statsPath: '$dir${Platform.pathSeparator}sensitive_stats.json',
  );
});

/// 项目（Novel）仓库：负责单 json 文件的读写与索引维护。
final Provider<NovelRepository> novelRepositoryProvider =
    Provider<NovelRepository>((ref) {
  return NovelRepository(ref.watch(appDatabaseProvider));
});

/// 章节仓库：在单 json 内对 chapters 做增删改与排序、自动保存。
final Provider<ChapterRepository> chapterRepositoryProvider =
    Provider<ChapterRepository>((ref) {
  return ChapterRepository(ref.watch(appDatabaseProvider));
});

/// 设定仓库：角色 / 世界观的 CRUD（同样落盘到单 json）。
final Provider<SettingRepository> settingRepositoryProvider =
    Provider<SettingRepository>((ref) {
  return SettingRepository(ref.watch(appDatabaseProvider));
});

/// 写作目标仓库（应用目录 goal.json）。
final Provider<GoalRepository> goalRepositoryProvider =
    Provider<GoalRepository>((ref) {
  return GoalRepository(ref.watch(appDatabaseProvider).directory.path);
});

/// 生成引擎（可插拔）。默认使用 [TemplateEngine]（纯离线模板），
/// 用户可在设置页切换为 [LlmEngine]（云端 API / 本地 Ollama）。
final Provider<GenerationEngine> generationEngineProvider =
    Provider<GenerationEngine>((ref) {
  // 引擎类型按全局设置选择；LlmEngine 需注入最新 LLM 配置。
  final LlmSettingsState settings = ref.watch(llmSettingsProvider);
  if (settings.useLlm) {
    return LlmEngine(config: settings.config);
  }
  return const TemplateEngine();
});

/// LLM 设置状态。
class LlmSettingsState {
  /// 是否启用 AI 生成（false = 纯模板）。
  final bool useLlm;

  /// LLM 连接配置。
  final LlmConfig config;

  /// 是否自动维护设定（生成后 AI 提取角色/世界观并落库）。
  final bool autoMemory;

  /// 构造状态。
  const LlmSettingsState({
    this.useLlm = false,
    this.config = const LlmConfig(),
    this.autoMemory = true,
  });

  /// 不可变更新副本。
  LlmSettingsState copyWith({bool? useLlm, LlmConfig? config, bool? autoMemory}) {
    return LlmSettingsState(
      useLlm: useLlm ?? this.useLlm,
      config: config ?? this.config,
      autoMemory: autoMemory ?? this.autoMemory,
    );
  }
}

/// LLM 设置控制器：持状态 + 自动落盘。
class LlmSettingsController extends StateNotifier<LlmSettingsState> {
  /// 构造控制器。
  LlmSettingsController(this._repo) : super(const LlmSettingsState(useLlm: false)) {
    _load();
  }

  final LlmSettingsRepository _repo;

  Future<void> _load() async {
    try {
      final LlmConfig config = await _repo.load();
      if (!mounted) return;
      state = state.copyWith(config: config);
    } catch (_) {
      // 读取失败用默认配置，不阻塞 UI。
    }
  }

  /// 启用/禁用 AI 引擎。
  Future<void> setUseLlm(bool use) async {
    state = state.copyWith(useLlm: use);
    await _repo.save(state.config);
  }

  /// 更新配置并保存。
  Future<void> updateConfig(LlmConfig config) async {
    state = state.copyWith(config: config);
    await _repo.save(config);
  }

  /// 切换自动维护设定开关。
  Future<void> setAutoMemory(bool v) async {
    state = state.copyWith(autoMemory: v);
    await _repo.save(state.config);
  }
}

/// LLM 设置（引擎开关 + 连接配置），全局唯一。
final StateNotifierProvider<LlmSettingsController, LlmSettingsState>
    llmSettingsProvider =
    StateNotifierProvider<LlmSettingsController, LlmSettingsState>((ref) {
  final AppDatabase db = ref.watch(appDatabaseProvider);
  return LlmSettingsController(
    LlmSettingsRepository(db.directory.path),
  );
});

/// 快捷读取：当前是否使用 AI 引擎。
final Provider<bool> useLlmProvider = Provider<bool>((ref) {
  return ref.watch(llmSettingsProvider).useLlm;
});

/// 阅读器设置：全局唯一，启动自动加载、变更自动落盘。
final StateNotifierProvider<ReaderSettingsController, ReaderSettings>
    readerSettingsProvider =
    StateNotifierProvider<ReaderSettingsController, ReaderSettings>((ref) {
  final AppDatabase db = ref.watch(appDatabaseProvider);
  return ReaderSettingsController(ReaderSettingsRepository(db.directory.path));
});

/// 阅读器设置控制器：持状态 + 自动落盘。
class ReaderSettingsController extends StateNotifier<ReaderSettings> {
  /// 构造控制器。
  ReaderSettingsController(this._repo)
      : super(const ReaderSettings()) {
    _load();
  }

  final ReaderSettingsRepository _repo;

  Future<void> _load() async {
    try {
      final ReaderSettings s = await _repo.load();
      if (!mounted) return;
      state = s;
    } catch (_) {
      // 读取失败用默认，不阻塞 UI。
    }
  }

  /// 更新设置并保存。
  Future<void> update(ReaderSettings s) async {
    state = s;
    await _repo.save(s);
  }
}

/// 快速读取：当前阅读器设置。
final Provider<ReaderSettings> readerSettingsStateProvider =
    Provider<ReaderSettings>((ref) {
  return ref.watch(readerSettingsProvider);
});

/// 项目列表视图模型。
final StateNotifierProvider<ProjectListViewModel, ProjectListState>
    projectListViewModelProvider =
    StateNotifierProvider<ProjectListViewModel, ProjectListState>((ref) {
  return ProjectListViewModel(ref.watch(novelRepositoryProvider));
});

/// 一键生成视图模型（按 novelId 区分，便于在各自工作区持有独立状态）。
final StateNotifierProviderFamily<GenerateViewModel, GenerateState, String>
    generateViewModelProvider =
    StateNotifierProvider.family<GenerateViewModel, GenerateState, String>(
  (ref, String novelId) => GenerateViewModel(
    ref.watch(generationEngineProvider),
    ref.watch(chapterRepositoryProvider),
    ref.watch(settingRepositoryProvider),
    novelId,
    ref,
  ),
);
