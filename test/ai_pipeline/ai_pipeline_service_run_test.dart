import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/prompts/pipeline_prompts.dart';
import 'package:novel_writer/ai_pipeline/services/ai_pipeline_service.dart';
import 'package:novel_writer/ai_pipeline/services/llm_router.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/models/llm_config.dart';

/// AiPipelineService.run 编排全流程测试（_FakeRouter 替身，零网络）。
///
/// 覆盖：启动取消、大纲规划失败、单章全流程（场景去重/标题/状态/伏笔台账）、
/// 场景规划失败默认骨架、场景续写、整章扩充、章末钩子补写采纳/被拒本地兜底、
/// 编辑润色采纳/过度压缩拒绝、低分自动重写、评分解析失败、断点续传跳过、
/// 目标字数/最大章数提前收官、每 5 章一致性审校 + 伏笔超时告警、
/// 未配置角色静默跳过。
void main() {
  late Directory tempDir;
  late PipelineStorage storage;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pipeline_svc_test_');
    storage = PipelineStorage(tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  // ---------------- Fake 基础设施 ----------------

  const LlmConfig fakeLlm = LlmConfig(
    provider: LlmProvider.openaiCompatible,
    model: 'fake-local',
    baseUrl: 'http://127.0.0.1:19110', // 本地地址免 Key → isConfigured=true
  );

  Map<AiRole, AiRoleConfig> roles(Iterable<AiRole> rs) =>
      <AiRole, AiRoleConfig>{
        for (final AiRole r in rs) r: AiRoleConfig(role: r, llm: fakeLlm),
      };

  // ---------------- 文本素材 ----------------

  /// 章末钩子尾句（含「就在这时/突然」信号词，PipelineQa 判有钩）。
  const String hookTail = '就在这时，门外突然传来一阵异动。';

  /// 平淡收尾（无钩子信号词）。
  const String blandTail = '林舟收拳而立，夜色归于平静。';

  String body(String tag) =>
      '林舟握紧拳头，迎着血煞盟的刀光冲了上去，$tag。' * 6;

  /// 标准场景 1：钩子尾。
  final String scene1 = '${body('第一幕')}$hookTail';

  /// 标准场景 2：开头复述场景 1 结尾（触发衔接去重），结尾另带钩子。
  final String scene2 =
      '$hookTail${body('第二幕')}他抬头，竟然看见月亮变成了血色。';

  // ---------------- 配置/任务构造 ----------------

  AiPipelineConfig config({
    int totalWords = 100000,
    int maxChapters = 40,
    bool useEditor = false,
    bool useVerifier = false,
    bool useQualityReview = false,
    int qualityReviewEvery = 1,
    bool autoRewriteLowScore = false,
    int rewriteThreshold = 55,
    bool useStateTrack = false,
    Iterable<AiRole> activeRoles = const <AiRole>[
      AiRole.planner,
      AiRole.writer,
      AiRole.titler,
      AiRole.verifier,
    ],
  }) =>
      AiPipelineConfig(
        totalWords: totalWords,
        maxChapters: maxChapters,
        genre: '玄幻',
        protagonist: '林舟',
        useEditor: useEditor,
        useVerifier: useVerifier,
        useQualityReview: useQualityReview,
        qualityReviewEvery: qualityReviewEvery,
        autoRewriteLowScore: autoRewriteLowScore,
        rewriteThreshold: rewriteThreshold,
        useStateTrack: useStateTrack,
        roles: roles(activeRoles),
      );

  AiPipelineTask task(AiPipelineConfig cfg, {String id = 'task-1'}) =>
      AiPipelineTask(id: id, config: cfg, createdAt: DateTime(2026, 9, 1));

  /// 全书大纲（1 章，目标 60 字——小而可控）。
  String outlineJson({int idx = 1, int target = 60, String title = '觉醒'}) =>
      '{"title":"测试之书","world":"玄天大陆","hook":"废柴觉醒",'
      '"chapter_outlines":[{"idx":$idx,"title":"$title","target":$target,'
      '"goal":"林舟觉醒武魂｜钩子=威胁逼近：血煞盟的人影一闪而逝"}]}';

  /// 两场景规划（targetWords 300 → 137 字场景不触发续写阈值 120）。
  const String scenePlanJson =
      '{"scenes":[{"stage":"起","goal":"觉醒异象","targetWords":300},'
      '{"stage":"合","goal":"脱身","targetWords":300}]}';

  /// 常规应答器：按 prompt 标记分发，可用命名参数覆盖个别分支。
  String Function(String, String) baseRespond({
    String outline = '',
    String scenePlan = scenePlanJson,
    List<String>? sceneTexts,
    String hookPatch = '',
    String expansion = '',
    String sceneAdd = '',
    String title = '觉醒之夜',
    String verifierIssues = '{"issues":[]}',
    String quality = '',
    String state = '伤势：无\n境界：觉醒一层',
    String foreshadow =
        '{"foreshadows":[{"desc":"血煞盟的追杀令","status":"open","planted":1}]}',
    List<String>? editorOutputs,
  }) {
    int sceneNo = 0;
    int editorNo = 0;
    final List<String> scenes = sceneTexts ?? <String>[scene1, scene2];
    return (String system, String user) {
      if (system == plannerSystemPrompt) {
        return user.contains('chapter_outlines') ? outline : scenePlan;
      }
      if (system == writerSystemPrompt) {
        if (user.contains('钩子句')) return hookPatch;
        if (user.contains('扩充到')) return expansion;
        if (user.contains('续写 300 字')) return sceneAdd;
        return scenes[(sceneNo++) % scenes.length];
      }
      if (system == titlerSystemPrompt) return title;
      if (system == editorSystemPrompt) {
        final List<String> outs = editorOutputs ?? const <String>[''];
        return outs[(editorNo++) % outs.length];
      }
      if (system == verifierSystemPrompt) {
        if (user.contains('"issues"')) return verifierIssues;
        if (user.contains('opening')) return quality;
        if (user.contains('状态管理员')) return state;
        if (user.contains('伏笔管理员')) return foreshadow;
      }
      return '';
    };
  }

  Future<AiPipelineTask> runTask(
    AiPipelineTask t,
    _FakeRouter router, {
    bool Function()? isCancelled,
  }) async {
    int progress = 0;
    await AiPipelineService(storage, router: router).run(
      t,
      isCancelled: isCancelled ?? () => false,
      onProgress: () => progress++,
    );
    return t;
  }

  String joined(AiPipelineTask t) => t.log.join('\n');

  // ---------------- 编排用例专用素材/辅助 ----------------

  /// 场景正文开头（衔接去重用例：上一段结尾复述本句即被裁剪）。
  const String sceneHead = '林舟握紧拳头，迎着血煞盟的刀光冲了上去，';

  /// 章末补写钩子（含「就在这时/黑影」信号词，且不出现在正文里）。
  const String freshHook = '就在这时，院墙外忽然立着一道黑影，正看着他。';

  /// 平淡收尾场景（结尾无钩子信号词 → 触发章末钩子补写）。
  String blandScene(String tag) => '${body(tag)}$blandTail';

  /// 过短场景（72 字：>50 且 < 场景阈值 120 → 触发写手续写补字）。
  final String shortScene =
      '${'林舟握紧拳头，迎着血煞盟的刀光冲了上去，短幕。' * 3}$blandTail';

  /// 整章扩充产出（>200 字且无钩子信号词）。
  final String expansionText =
      '扩写补丁：林舟提刀向前，脚步压过碎石，雾里的血煞盟退了一步。' * 12;

  /// 多章大纲 JSON（断点续传 / 提前收官类用例）。
  String multiOutlineJson(List<int> idxs, {int target = 60}) =>
      jsonEncode(<String, dynamic>{
        'title': '测试之书',
        'world': '玄天大陆',
        'hook': '废柴觉醒',
        'chapter_outlines': idxs
            .map((int i) => <String, dynamic>{
                  'idx': i,
                  'title': '第$i章标题',
                  'target': target,
                  'goal': '林舟觉醒武魂｜钩子=威胁逼近：血煞盟的人影一闪而逝',
                })
            .toList(),
      });

  /// 预置大纲（不给规划官留活干，直接进逐章阶段）。
  Map<String, dynamic> outlineOf(List<int> idxs) =>
      jsonDecode(multiOutlineJson(idxs)) as Map<String, dynamic>;

  /// 五角色全装配（润色 / 低分重写类用例需要 editor 在位）。
  const List<AiRole> allRoles = <AiRole>[
    AiRole.planner,
    AiRole.writer,
    AiRole.editor,
    AiRole.titler,
    AiRole.verifier,
  ];

  // ---------------- 用例 ----------------

  group('AiPipelineService.run 编排', () {
    test('单章全流程：大纲 → 场景去重 → 标题 → 状态/伏笔台账落盘', () async {
      final AiPipelineConfig cfg = config(useStateTrack: true);
      final _FakeRouter router =
          _FakeRouter(baseRespond(outline: outlineJson()));
      final AiPipelineTask t = await runTask(task(cfg), router);

      expect(t.status, PipelineTaskStatus.done);
      expect(t.chapterCount, 1);
      expect(joined(t), contains('[规划官] 《测试之书》共 1 章'));
      expect(joined(t), contains('[规划] 2 场景：起/合'));

      final PipelineChapter ch = t.chapters.single;
      expect(ch.idx, 1);
      expect(ch.title, '觉醒之夜'); // 标题官产出覆盖章纲里的标题
      expect(ch.content.startsWith(sceneHead), isTrue);
      // 第 2 场景开头复述了第 1 场景结尾（钩子句）→ 裁掉重叠
      expect(joined(t), contains('场景衔接重叠，已裁剪'));
      expect(ch.words, greaterThan(200));

      expect(t.stateTrack, contains('觉醒一层')); // 跨章状态清单
      expect(t.foreshadowLedger, contains('血煞盟的追杀令')); // 伏笔台账
      expect(router.systems, contains(verifierSystemPrompt));

      // 断点落盘：状态 / 章节 / 字数均持久化
      final AiPipelineTask? saved = await storage.loadTask(t.id);
      expect(saved?.status, PipelineTaskStatus.done);
      expect(saved?.chapters.single.content, ch.content);
      expect(saved?.totalWords, t.totalWords);
    });

    test('启动后取消：cancelled 且未生成任何章节', () async {
      final _FakeRouter router =
          _FakeRouter(baseRespond(outline: outlineJson()));
      final AiPipelineTask t =
          await runTask(task(config()), router, isCancelled: () => true);

      expect(t.status, PipelineTaskStatus.cancelled);
      expect(t.chapters, isEmpty);
      expect(joined(t), contains('[流水线] 已取消'));
      expect(router.systems, isNot(contains(writerSystemPrompt)));
      expect((await storage.loadTask(t.id))?.status,
          PipelineTaskStatus.cancelled);
    });

    test('大纲规划失败：failed 并记录原始产出', () async {
      final _FakeRouter router = _FakeRouter(baseRespond(outline: '这不是 JSON'));
      final AiPipelineTask t = await runTask(task(config()), router);

      expect(t.status, PipelineTaskStatus.failed);
      expect(t.error, contains('大纲规划失败'));
      expect(t.chapters, isEmpty);
      expect((await storage.loadTask(t.id))?.error, contains('大纲规划失败'));
    });

    test('场景规划连续失败：默认「起承转合」骨架兜底', () async {
      final _FakeRouter router = _FakeRouter(
          baseRespond(outline: outlineJson(), scenePlan: '规划官今天不在状态'));
      final AiPipelineTask t = await runTask(task(config()), router);

      expect(t.status, PipelineTaskStatus.done);
      expect(joined(t), contains('使用默认「起承转合」骨架'));
      expect(joined(t), contains('[规划] 4 场景：起/承/转/合'));
      expect(t.totalWords, greaterThan(400));
    });

    test('场景字数不足：写手续写补字拼进本章', () async {
      final _FakeRouter router = _FakeRouter(baseRespond(
        outline: outlineJson(),
        sceneTexts: <String>[shortScene, scene2],
        sceneAdd: '续写补丁：血煞盟的刀锋已抵在他喉前。',
      ));
      final AiPipelineTask t = await runTask(task(config()), router);

      expect(t.status, PipelineTaskStatus.done);
      expect(joined(t), contains('[场景 1/2] 起：觉醒异象'));
      expect(t.chapters.single.content, contains('续写补丁'));
    });

    test('整章字数不足半数：向目标字数扩充', () async {
      final _FakeRouter router = _FakeRouter(baseRespond(
        outline: outlineJson(target: 2000),
        expansion: expansionText,
        hookPatch: freshHook,
      ));
      final AiPipelineTask t = await runTask(task(config()), router);

      expect(t.status, PipelineTaskStatus.done);
      expect(joined(t), contains('整章续写'));
      expect(t.chapters.single.content, contains('扩写补丁'));
      // 扩充后仍无钩子 → 钩子补写接手，补在最后
      expect(t.chapters.single.content, endsWith(freshHook));
      expect(t.chapters.single.words, greaterThan(500));
    });

    test('章末缺钩：LLM 补写钩子被采纳', () async {
      final _FakeRouter router = _FakeRouter(baseRespond(
        outline: outlineJson(),
        sceneTexts: <String>[blandScene('第一幕'), blandScene('第二幕')],
        hookPatch: freshHook,
      ));
      final AiPipelineTask t = await runTask(task(config()), router);

      expect(t.status, PipelineTaskStatus.done);
      expect(joined(t), contains('[钩子] 章末缺钩，自动补写钩子...'));
      expect(joined(t), contains('[钩子] 已补写钩子'));
      expect(joined(t), isNot(contains('本地兜底')));
      expect(t.chapters.single.content, endsWith(freshHook));
    });

    test('章末钩子补写被拒（指令残留）→ 章纲钩子本地兜底', () async {
      final _FakeRouter router = _FakeRouter(baseRespond(
        outline: outlineJson(),
        sceneTexts: <String>[blandScene('第一幕'), blandScene('第二幕')],
        hookPatch: '我拿到的指令是补写钩子，不是扩写正文。',
      ));
      final AiPipelineTask t = await runTask(task(config()), router);

      expect(joined(t), contains('LLM 补写被拒'));
      expect(joined(t), contains('本地兜底'));
      final String content = t.chapters.single.content;
      expect(content, contains('血煞盟的人影一闪而逝')); // 章纲钩子原文
      expect(content, endsWith('他还没看清那是什么。')); // 兜底补的钩子信号
      expect(content, isNot(contains('我拿到的指令')));
    });

    test('编辑润色：产出达标（≥85% 字数）即采纳', () async {
      final String polished = '${body('润色幕')}$hookTail';
      final _FakeRouter router = _FakeRouter(baseRespond(
        outline: outlineJson(),
        editorOutputs: <String>['$polished\n\n$polished'],
      ));
      final AiPipelineTask t = await runTask(
          task(config(useEditor: true, activeRoles: allRoles)), router);

      expect(t.status, PipelineTaskStatus.done);
      expect(joined(t), contains('[编辑] 润色完成'));
      expect(t.chapters.single.content, '$polished\n\n$polished');
      expect(t.chapters.single.rawWords, greaterThan(200)); // 润色前字数留档
    });

    test('编辑润色：过度压缩（<85%）拒绝采纳并保留原文', () async {
      final _FakeRouter router = _FakeRouter(baseRespond(
        outline: outlineJson(),
        editorOutputs: <String>['林舟握紧拳头，冲了上去。'],
      ));
      final AiPipelineTask t = await runTask(
          task(config(useEditor: true, activeRoles: allRoles)), router);

      expect(joined(t), contains('过度压缩（<85%），拒绝采纳保留原文'));
      final PipelineChapter ch = t.chapters.single;
      expect(ch.content, contains('第一幕')); // 原文保留
      expect(ch.content, isNot(contains('林舟握紧拳头，冲了上去。')));
      expect(ch.words, greaterThan(200));
    });

    test('编辑无产出：保留原文并记录', () async {
      final _FakeRouter router = _FakeRouter(baseRespond(
        outline: outlineJson(),
        editorOutputs: <String>[''],
      ));
      final AiPipelineTask t = await runTask(
          task(config(useEditor: true, activeRoles: allRoles),
              id: 'task-editor-empty'),
          router);

      expect(t.status, PipelineTaskStatus.done);
      expect(joined(t), contains('[编辑] 润色失败，保留原文'));
      expect(t.chapters.single.content, contains('第一幕'));
    });

    test('低分自动重写：评分 40 < 55 触发编辑定向重写并替换正文', () async {
      const String lowScore = '{"scores":{"opening":30,"thrill":40,"hook":20,'
          '"motivation":50,"rhythm":60},"overall":40,"comment":"开篇迟缓"}';
      final String rewritten = '${body('重写幕')}$hookTail';
      final _FakeRouter router = _FakeRouter(baseRespond(
        outline: outlineJson(),
        quality: lowScore,
        editorOutputs: <String>[rewritten],
      ));
      final AiPipelineTask t = await runTask(
        task(config(
          useQualityReview: true,
          autoRewriteLowScore: true,
          rewriteThreshold: 55,
          activeRoles: allRoles,
        )),
        router,
      );

      expect(t.status, PipelineTaskStatus.done);
      expect(joined(t), contains('[评分] 第 1 章 综合 40 分'));
      expect(joined(t), contains('触发自动重写'));
      expect(t.chapters.single.content, contains('重写幕'));
      expect(t.chapters.single.issues.any((String e) => e.contains('已自动重写')),
          isTrue);
      // 低分告警被「已重写」记录替换，不留重复告警
      expect(
          t.chapters.single.issues.any((String e) => e.contains('语义质量评分')),
          isFalse);
    });

    test('评分解析失败：跳过评分不阻断成书', () async {
      final _FakeRouter router = _FakeRouter(baseRespond(
        outline: outlineJson(),
        quality: '模型今天不吐 JSON',
      ));
      final AiPipelineTask t = await runTask(
          task(config(useQualityReview: true, autoRewriteLowScore: true)),
          router);

      expect(t.status, PipelineTaskStatus.done);
      expect(joined(t), contains('评分解析失败，跳过（不影响生成）'));
      expect(t.chapters.single.content, contains('第一幕'));
    });

    test('质量评审证据注入：verifier 评分 prompt 携带本地质检证据', () async {
      final _FakeRouter router = _FakeRouter(baseRespond(
        outline: outlineJson(),
        quality: '{"scores":{"opening":80,"thrill":70,"hook":85,'
            '"motivation":75,"rhythm":80},"overall":78,"comment":"稳健"}',
      ));
      final AiPipelineTask t =
          await runTask(task(config(useQualityReview: true)), router);

      expect(t.status, PipelineTaskStatus.done);
      // 与 Python 端 qa_ev 同口径：钩子命中 + 爽点/异动密度注入评分 prompt，
      // 治「评审 100 分但钩子无」的评分分裂（证据矛盾时 prompt 明令不得矛盾）。
      final String qrPrompt = router.users.firstWhere(
        (String u) => u.contains('请以网文编辑的眼光'),
        orElse: () => '',
      );
      expect(qrPrompt, isNotEmpty);
      expect(qrPrompt, contains('本地质检证据'));
      expect(qrPrompt, contains('章末钩子检测：命中'));
      expect(qrPrompt, contains('直白爽点'));
      expect(qrPrompt, contains('变强异动'));
    });

    test('断点续传：跳过已完成章节，并裁掉跨章衔接重叠', () async {
      final AiPipelineTask t0 = task(config())
        ..outline = outlineOf(<int>[1, 2])
        ..chapters.add(const PipelineChapter(
          idx: 1,
          title: '旧章',
          content: '旧正文。$sceneHead',
          rawWords: 24,
          words: 24,
        ));
      t0.totalWords = 24;
      final _FakeRouter router = _FakeRouter(baseRespond());
      final AiPipelineTask t = await runTask(t0, router);

      expect(t.status, PipelineTaskStatus.done);
      expect(joined(t), contains('[续传] 《测试之书》已有 1 章'));
      expect(joined(t), isNot(contains('===== 第 1 章'))); // 已完成章节不再重跑
      expect(joined(t), contains('===== 第 2 章'));
      expect(joined(t), contains('章节衔接重叠，已裁剪'));
      // 大纲是预置的：全书规划官一次都不该被叫
      expect(
          router.users.any((String u) => u.contains('chapter_outlines')), isFalse);
      expect(t.chapterCount, 2);
      expect(
          t.chapters.firstWhere((PipelineChapter c) => c.idx == 2).title,
          '觉醒之夜');
      expect(t.totalWords, greaterThan(200));
    });

    test('目标字数达标：提前收官，不再生成后续章', () async {
      final AiPipelineTask t0 = task(config(totalWords: 100))
        ..outline = outlineOf(<int>[1, 2]);
      final AiPipelineTask t = await runTask(t0, _FakeRouter(baseRespond()));

      expect(t.status, PipelineTaskStatus.done);
      expect(t.chapterCount, 1);
      expect(t.totalWords, greaterThanOrEqualTo(100));
      expect(joined(t), contains('[流水线] 完成：1 章'));
      expect(joined(t), isNot(contains('===== 第 2 章')));
    });

    test('最大章数上限：超限章节直接跳过', () async {
      final AiPipelineTask t0 = task(config(maxChapters: 1))
        ..outline = outlineOf(<int>[1, 2]);
      final AiPipelineTask t = await runTask(t0, _FakeRouter(baseRespond()));

      expect(t.status, PipelineTaskStatus.done);
      expect(t.chapterCount, 1);
      expect(joined(t), isNot(contains('===== 第 2 章')));
      expect(joined(t), contains('[流水线] 完成：1 章'));
    });

    test('每 5 章审校官介入：一致性问题入库 + 伏笔超时告警', () async {
      final AiPipelineTask t0 = task(config(useVerifier: true))
        ..outline = outlineOf(<int>[5])
        ..chapters.add(const PipelineChapter(
          idx: 4,
          title: '旧章',
          content: '旧正文。',
          rawWords: 3,
          words: 3,
        ));
      t0.totalWords = 3;
      final _FakeRouter router = _FakeRouter(baseRespond(
        verifierIssues:
            '{"issues":[{"chapter":5,"type":"设定矛盾","desc":"境界忽高忽低"}]}',
        foreshadow:
            '{"foreshadows":[{"desc":"血煞盟的追杀令","status":"open","planted":0}]}',
      ));
      final AiPipelineTask t = await runTask(t0, router);

      expect(t.status, PipelineTaskStatus.done);
      expect(joined(t), contains('[审校] ⚠ 第5章 设定矛盾: 境界忽高忽低'));
      expect(joined(t), contains('伏笔超时未收（已5章）')); // planted=0 → 第 5 章时已超期
      expect(joined(t), contains('血煞盟的追杀令'));
      expect(
          t.chapters.last.issues.any((String e) => e.contains('第5章 设定矛盾')),
          isTrue);
    });

    test('未配置角色静默跳过：标题回退章纲标题', () async {
      final _FakeRouter router =
          _FakeRouter(baseRespond(outline: outlineJson()));
      final AiPipelineTask t = await runTask(
        task(config(activeRoles: <AiRole>[
          AiRole.planner,
          AiRole.writer,
          AiRole.verifier,
        ])),
        router,
      );

      expect(t.status, PipelineTaskStatus.done);
      expect(joined(t), contains('标题官 未配置模型，跳过'));
      expect(router.systems, isNot(contains(titlerSystemPrompt)));
      expect(t.chapters.single.title, '觉醒'); // 章纲标题兜底
    });
  });
}

/// LlmRouter 测试替身：按 (system, user) 直出内容，零网络、零延时。
class _FakeRouter implements LlmRouter {
  /// 构造替身；[respond] 为应答器。
  _FakeRouter(this.respond);

  /// 应答器：system 提示 + user 提示 → 模型产出。
  final String Function(String system, String user) respond;

  /// 全部 system 提示（断言「某角色是否被调用」）。
  final List<String> systems = <String>[];

  /// 全部 user 提示（断言「是否重复规划」等）。
  final List<String> users = <String>[];

  @override
  Future<LlmRouteResult> call(
    List<LlmConfig> chain, {
    required String system,
    required String user,
    double? temperature,
    void Function(String logLine)? onLog,
  }) async {
    systems.add(system);
    users.add(user);
    onLog?.call('替身直出（链长 ${chain.length}）');
    return LlmRouteResult(
      content: respond(system, user),
      used: chain.isEmpty ? null : chain.first,
    );
  }
}

