import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/features/generate/generate_viewmodel.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/services/sensitive_words.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/setting_repository.dart';

/// 记录引擎收到的 continuation 与 plotSummary（验证多章承接/前情提要传递）。
class _EngineCall {
  _EngineCall(this.index, this.continuation, this.config, this.ctx);
  final int index;
  final String? continuation;
  final GenerationConfig config;
  final ContextBundle ctx;

  /// 引擎收到的前情提要文本。
  String get plotSummary => ctx.plotSummary;
}

/// 可编程的假引擎：记录每次调用的 continuation，返回固定内容。
class _FakeEngine implements GenerationEngine {
  _FakeEngine({this.failAt = -1, this.cancelledAt = -1});

  final int failAt;
  final int cancelledAt;
  final List<_EngineCall> calls = <_EngineCall>[];
  int _callCount = 0;

  @override
  Future<GenerationResult> generate(
    GenerationConfig config,
    ContextBundle ctx, {
    CancelToken? cancelToken,
    void Function(GenerationProgress)? onProgress,
  }) async {
    final int i = _callCount++;
    calls.add(_EngineCall(i, config.continuation, config, ctx));
    onProgress?.call(const GenerationProgress(
      charsWritten: 2,
      targetWords: 4,
      stage: '写中',
    ));
    if (i == failAt) {
      throw const EngineException('引擎失败');
    }
    if (i == cancelledAt) {
      throw const GenerationCancelledException();
    }
    return GenerationResult(
      content: '第${i + 1}章正文',
      actualWords: 5,
      usedConfig: config,
    );
  }
}

/// 流式预览引擎：onProgress 逐段回报 previewText。
class _StreamPreviewEngine implements GenerationEngine {
  final List<String> sentPreviews = <String>[];

  @override
  Future<GenerationResult> generate(
    GenerationConfig config,
    ContextBundle ctx, {
    CancelToken? cancelToken,
    void Function(GenerationProgress)? onProgress,
  }) async {
    final StringBuffer buf = StringBuffer();
    for (int k = 0; k < 3; k++) {
      buf.write('段${k + 1}');
      sentPreviews.add(buf.toString());
      onProgress?.call(GenerationProgress(
        charsWritten: buf.length,
        targetWords: 4,
        stage: '写中',
        previewText: buf.toString(),
      ));
    }
    return GenerationResult(
      content: buf.toString(),
      actualWords: buf.length,
      usedConfig: config,
    );
  }
}

/// 内存仓储：记录保存的章节，可被外部断言。
/// 用 implements 而非 extends——db 字段不可伪造，
/// 只需在测试路径上提供 saveGeneratedChapter，其余成员 noSuchMethod 兜底。
class _FakeChapterRepo implements ChapterRepository {
  _FakeChapterRepo() {
    // 空构造：无 db 依赖。
  }

  final List<Chapter> saved = <Chapter>[];

  @override
  AppDatabase get db => throw UnimplementedError('测试不应访问 db');

  @override
  Future<Chapter> saveGeneratedChapter(
    String novelId,
    int order,
    String title,
    String content,
  ) async {
    final Chapter c = Chapter(
      id: 'ch$order',
      novelId: novelId,
      title: title,
      order: order,
      content: content,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    saved.add(c);
    return c;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不应在测试中调用');
}

/// 假设置仓储：测试不触碰 db。
class _FakeSettingRepo implements SettingRepository {
  @override
  AppDatabase get db => throw UnimplementedError('测试不应访问 db');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不应在测试中调用');
}

void main() {
  group('GenerateViewModel 多章连写', () {
    test('按 chapterCount 逐章生成并逐章落库', () async {
      final engine = _FakeEngine();
      final repo = _FakeChapterRepo();
      final vm = GenerateViewModel(
        engine,
        repo,
        _FakeSettingRepo(),
        'n1',
        _fakeRef(),
      );

      await vm.generate(
        _cfg(chapterCount: 3),
        _bundle(),
        1,
        '第1章',
      );

      expect(engine.calls.length, equals(3));
      expect(repo.saved.length, equals(3));
      expect(repo.saved[0].title, contains('第1章'));
      expect(repo.saved[2].order, equals(3));
      expect(vm.state.isGenerating, isFalse);
      expect(vm.state.error, isNull);
    });

    test('每章 continuation 承接上一章正文（多章串联）', () async {
      final engine = _FakeEngine();
      final vm = GenerateViewModel(
        engine,
        _FakeChapterRepo(),
        _FakeSettingRepo(),
        'n1',
        _fakeRef(),
      );

      await vm.generate(
        _cfg(chapterCount: 3),
        _bundle(),
        1,
        '第1章',
      );

      // 第 1 章：无承接（或传入的 config.continuation）。
      // 第 2 章起：承接上一章正文结尾。
      expect(engine.calls[1].continuation, isNotNull);
      expect(engine.calls[2].continuation, isNotNull);
      expect(
        engine.calls[2].continuation,
        isNot(equals(engine.calls[1].continuation)),
      );
    });

    test('中途引擎失败：已生成章节保留，状态报错', () async {
      final engine = _FakeEngine(failAt: 1); // 第 2 章失败
      final repo = _FakeChapterRepo();
      final vm = GenerateViewModel(
        engine,
        repo,
        _FakeSettingRepo(),
        'n1',
        _fakeRef(),
      );

      await vm.generate(
        _cfg(chapterCount: 3),
        _bundle(),
        1,
        '第1章',
      );

      expect(repo.saved.length, equals(1)); // 只保住第 1 章
      expect(vm.state.isGenerating, isFalse);
      expect(vm.state.error, contains('引擎失败'));
    });

    test('取消：已保存章节保留，状态为已取消', () async {
      final engine = _FakeEngine(cancelledAt: 1);
      final repo = _FakeChapterRepo();
      final vm = GenerateViewModel(
        engine,
        repo,
        _FakeSettingRepo(),
        'n1',
        _fakeRef(),
      );

      await vm.generate(
        _cfg(chapterCount: 3),
        _bundle(),
        1,
        '第1章',
      );

      expect(repo.saved.length, equals(1));
      expect(vm.state.error, contains('已取消'));
    });

    test('卷纲按行拆分为各章分配（config 传递）', () async {
      final engine = _FakeEngine();
      final vm = GenerateViewModel(
        engine,
        _FakeChapterRepo(),
        _FakeSettingRepo(),
        'n1',
        _fakeRef(),
      );

      await vm.generate(
        _cfg(chapterCount: 2, volumeOutline: '逃离险境\n前往宗门'),
        _bundle(),
        1,
        '第1章',
      );

      // 引擎收到的 config 应包含卷纲（View 层按章节切分后替换 outline）。
      expect(engine.calls.length, equals(2));
      expect(engine.calls[0].config.volumeOutline, contains('逃离险境'));
    });

    test('单章（默认 chapterCount=1）只生成一次', () async {
      final engine = _FakeEngine();
      final vm = GenerateViewModel(
        engine,
        _FakeChapterRepo(),
        _FakeSettingRepo(),
        'n1',
        _fakeRef(),
      );

      await vm.generate(
        _cfg(),
        _bundle(),
        1,
        '第1章',
      );

      expect(engine.calls.length, equals(1));
      expect(vm.state.isGenerating, isFalse);
    });

    test('流式 previewText 透传到状态（生成中可实时预览）', () async {
      final engine = _StreamPreviewEngine();
      final vm = GenerateViewModel(
        engine,
        _FakeChapterRepo(),
        _FakeSettingRepo(),
        'n1',
        _fakeRef(),
      );

      await vm.generate(
        _cfg(),
        _bundle(),
        1,
        '第1章',
      );

      // 引擎回报的 previewText 应出现在 state（供 UI 实时显示）。
      expect(engine.sentPreviews.length, greaterThan(0));
      expect(vm.state.previewText, equals(engine.sentPreviews.last));
    });

    test('生成开始时清除上次 previewText（无新回报时保持 null，避免残留）', () async {
      final vm = GenerateViewModel(
        _FakeEngine(),
        _FakeChapterRepo(),
        _FakeSettingRepo(),
        'n1',
        _fakeRef(),
      );
      // 伪造上次残留预览。
      vm.state = vm.state.copyWith(previewText: '残留旧文');

      await vm.generate(
        _cfg(),
        _bundle(),
        1,
        '第1章',
      );

      // _FakeEngine 不回报 previewText：清除后应保持 null（无残留旧文）。
      expect(vm.state.previewText, isNull);
    });

    test('reset 恢复初始状态', () {
      final vm = GenerateViewModel(
        _FakeEngine(),
        _FakeChapterRepo(),
        _FakeSettingRepo(),
        'n1',
        _fakeRef(),
      );
      vm.state = vm.state.copyWith(isGenerating: true, progress: 0.7);
      vm.reset();
      expect(vm.state.isGenerating, isFalse);
      expect(vm.state.progress, equals(0));
      expect(vm.state.error, isNull);
    });

    test('单章生成不注入前情提要（无下一章需要承接）', () async {
      final engine = _FakeEngine();
      final vm = GenerateViewModel(
        engine,
        _FakeChapterRepo(),
        _FakeSettingRepo(),
        'n1',
        _fakeRef(),
      );

      await vm.generate(_cfg(), _bundle(), 1, '第1章');

      expect(engine.calls, hasLength(1));
      expect(engine.calls.single.plotSummary, isEmpty);
    });

    test('多章连写：从第2章起注入前情提要（本地摘要兜底路径）', () async {
      final engine = _FakeEngine();
      final vm = GenerateViewModel(
        engine,
        _FakeChapterRepo(),
        _FakeSettingRepo(),
        'n1',
        _fakeRef(),
      );

      await vm.generate(_cfg(chapterCount: 3), _bundle(), 1, '第1章');

      expect(engine.calls, hasLength(3));
      // 第1章：无前情提要。
      expect(engine.calls[0].plotSummary, isEmpty);
      // 第2章：承接第1章摘要（LLM 未启用 → 本地启发式摘要）。
      expect(engine.calls[1].plotSummary, contains('第1章：第1章正文'));
      // 第3章：累积第1、2章摘要，按行分隔。
      expect(engine.calls[2].plotSummary, contains('第1章：第1章正文'));
      expect(engine.calls[2].plotSummary, contains('第2章：第2章正文'));
      expect(engine.calls[2].plotSummary, isNot(contains('\n第0章')));
    });

    test('前情提要仅保留最近3条（控制注入 prompt 体积）', () async {
      final engine = _FakeEngine();
      final vm = GenerateViewModel(
        engine,
        _FakeChapterRepo(),
        _FakeSettingRepo(),
        'n1',
        _fakeRef(),
      );

      await vm.generate(_cfg(chapterCount: 5), _bundle(), 1, '第1章');

      // 生成 5 章 → 积累第 1~4 章摘要，末章只看到最近 3 条（2/3/4）。
      final String last = engine.calls[4].plotSummary;
      expect(last, contains('第2章：'));
      expect(last, contains('第3章：'));
      expect(last, contains('第4章：'));
      expect(last, isNot(contains('第1章：')));
    });
  });
}

/// 构造最小 GenerationConfig（genre/tone/targetWords/constraints 必填）。
GenerationConfig _cfg({
  int chapterCount = 1,
  String volumeOutline = '',
}) {
  return GenerationConfig(
    genre: 'xuanhuan',
    tone: '热血',
    targetWords: 1000,
    chapterCount: chapterCount,
    volumeOutline: volumeOutline,
    constraints: const GenerationConstraints(maxWordsPerChapter: 20000),
  );
}

/// 构造一个最小 ContextBundle。
ContextBundle _bundle() {
  return ContextBundle(
    characters: const <Character>[],
    worldSettings: const <WorldSetting>[],
    genrePreset: GenrePresets.get('xuanhuan'),
    plotSkeleton: PlotSkeleton.forGenre('xuanhuan'),
    outline: '测试大纲',
  );
}

/// 用真 ProviderContainer 提供 llmSettingsProvider（useLlm=false → 不触发记忆）
/// 与 sensitiveWordsProvider（敏感词检查不炸）。
/// riverpod 2.6 的 ProviderContainer 不 implements Ref，用 _ContainerRef 包装。
Ref _fakeRef() {
  final container = ProviderContainer(
    overrides: [
      llmSettingsProvider.overrideWith(
        (ref) => LlmSettingsController(LlmSettingsRepository(
          // 测试不落盘：controller 只被 read，不触发持久化路径。
          '.',
        )),
      ),
      sensitiveWordsProvider.overrideWithValue(SensitiveWordsService()),
    ],
  );
  addTearDown(container.dispose);
  return _ContainerRef(container);
}

/// 最小 Ref 包装：只把 read 委托给 container（ViewModel 仅用 read）。
class _ContainerRef implements Ref {
  _ContainerRef(this._container);

  final ProviderContainer _container;

  @override
  T read<T>(ProviderListenable<T> provider) => _container.read(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不应被调用');
}
