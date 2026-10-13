import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/prompts/pipeline_prompts.dart';
import 'package:novel_writer/ai_pipeline/services/ai_pipeline_service.dart';
import 'package:novel_writer/ai_pipeline/services/llm_router.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/security/secret_store.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 关卡5「编造核查 → 定点修 → 复检 → 采纳/回滚」全闭环测试（_ScriptedRouter 替身，零网络）。
///
/// 为什么单独立一个文件（而不是补进 ai_pipeline_service_run_test.dart）：
/// 该闭环此前 **零覆盖**（run_test.dart 全文未出现 useFactCheck/factCheck，
/// 覆盖率 lcov 里 ai_pipeline_service.dart 的 918–995 行整段未命中）。
/// 它是整条流水线风险最高的一段——三条纪律全是「静默失效会被伪装成通过」的
/// 高危路径（源码注释原话）：
///   ① 没跑成 ≠ 没问题（ok=false 绝不冒充 0 命中的干净结果）；
///   ② 命中即修，但**只有复检命中数确实下降才采纳**，否则回滚原文；
///   ③ 修复稿过不了采纳闸（空产出/超长/题材漂移/与正文重复）则保留原文并记账。
/// 另有 ④ 字数硬下限随 prompt 下发（禁以删代修）。
///
/// 分流要点：核查走 planner 链（factCheckSystemPrompt），定点修走 editor 链
/// （editorSystemPrompt，见源码 928–930 行），scenePlan 也走 planner 链——故
/// 按 system 常量分流即可，无需再按 user 二次分流。**editor 必须进 activeRoles**，
/// 否则 roleOf(editor) 落到未配置的默认 LlmConfig，_call 直接返回空串（静默跳过）。
/// 写手场景正文：够长（过字数闸）且带章末钩子信号词，避免被质量闸打回重写。
/// 「就在这时」是 PipelineQa 认的钩子信号词。
/// 非 const——String 乘法不能进常量表达式，故放文件顶层做普通 final。
final String sceneBody =
    '林舟握紧拳头，迎着血煞盟落下的刀光冲了上去，指节泛白。' * 7 +
        '围观弟子哗然退开，有人失声惊呼。' +
        '就在这时，门外突然传来一阵异动。';

void main() {
  late Directory tempDir;
  late PipelineStorage storage;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pipeline_factcheck_test_');
    storage = PipelineStorage(tempDir.path, secretStore: InMemorySecretStore());
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  const LlmConfig fakeLlm = LlmConfig(
    provider: LlmProvider.openaiCompatible,
    model: 'fake-local',
    baseUrl: 'http://127.0.0.1:19110', // 本地地址免 Key → isConfigured=true
  );

  Map<AiRole, AiRoleConfig> roles(Iterable<AiRole> rs) =>
      <AiRole, AiRoleConfig>{
        for (final AiRole r in rs) r: AiRoleConfig(role: r, llm: fakeLlm),
      };

  ///
  /// `target: 60` 是关键：成章门槛是 `minWords = (target * 0.5).ceil()`
  /// （见 ai_pipeline_service.dart「章节最低正文门槛」），60 字目标 → 门槛 30 字。
  /// 不写 target 时目标章字数很大，短素材会撞上「正文不足」直接失败，用例根本
  /// 走不到编造核查那一段。同目录 ai_pipeline_service_run_test.dart 同款做法。
  /// 大纲 JSON（planner 首轮，user 含 'chapter_outlines'）。
  String outlineJson({int chapters = 1, int target = 60}) {
    final List<String> chs = <String>[
      for (int i = 1; i <= chapters; i++)
        '{"idx":$i,"title":"第 $i 章","target":$target,"goal":"外显爽点：当众打脸","beats":["起","承","转","合"]}'
    ];
    return '{"chapter_outlines":[${chs.join(',')}]}';
  }

  /// 场景规划 JSON（planner 第二轮）。
  String scenePlanJson() =>
      '{"scenes":[{"stage":"起","goal":"林舟觉醒废灵根，血煞盟的刀光落下","targetWords":300},'
      '{"stage":"合","goal":"林舟硬抗刀光，围观弟子哗然","targetWords":300}]}';

  /// 核查结果 JSON：命中 [n] 处编造（0 → 空数组）。
  String factCheckJson(int n) {
    if (n <= 0) return '{"fabrications":[]}';
    final List<String> items = <String>[
      for (int i = 1; i <= n; i++)
        '{"claim":"老周欠债三年","evidence":"台账无据","type":"fabricated"}'
    ];
    return '{"fabrications":[${items.join(',')}]}';
  }

  /// 定点修产出：改写成非断言（传闻），使复检可判下降。
  const String fixText = '林舟改口说这只是传闻，老周的债据说并非三年，此事无人证实。';

  AiPipelineTask makeTask({bool useFactCheck = true}) => AiPipelineTask(
        id: 'task-fc-1',
        config: AiPipelineConfig(
          totalWords: 100000,
          maxChapters: 40,
          genre: '玄幻',
          protagonist: '林舟',
          useFactCheck: useFactCheck,
          // editor 必须在内：定点修走 editor 链（源码 call(AiRole.editor, ...)）。
          roles: roles(const <AiRole>[
            AiRole.planner,
            AiRole.writer,
            AiRole.titler,
            AiRole.verifier,
            AiRole.editor,
          ]),
        ),
        createdAt: DateTime(2026, 9, 1),
      );

  Future<AiPipelineTask> runTask(AiPipelineTask t, LlmRouter router) async {
    await AiPipelineService(storage, router: router).run(
      t,
      isCancelled: () => false,
      onProgress: () {},
    );
    return t;
  }

  String joined(AiPipelineTask t) => t.log.join('\n');

  // MARK: - 用例（四条分支 + 口径钉 + 关闭钉） -

  test('DIAG: 打印流水线实际日志，定位为何没有成章', () async {
    final _ScriptedRouter router = _ScriptedRouter(
      outline: outlineJson(),
      scenePlan: scenePlanJson(),
      factCheckResults: <String>[factCheckJson(0)],
    );
    final AiPipelineTask t = await runTask(makeTask(), router);
    // ignore: avoid_print
    print('--- chapters=${t.chapters.length} '
        'status=${t.status} error=${t.error} totalWords=${t.totalWords} ---');
    // ignore: avoid_print
    print('--- LOG START ---\n${t.log.join('\n')}\n--- LOG END ---');
    expect(t.chapters.length, 1);
  });

  test('核查未跑成（planner 空响应）：ok=false 单独标记，绝不冒充 0 命中', () async {
    final _ScriptedRouter router = _ScriptedRouter(
      outline: outlineJson(),
      scenePlan: scenePlanJson(),
      factCheckResults: <String>[''], // 空响应 → _parseJsonObject=null → ok=false
    );
    final AiPipelineTask t = await runTask(makeTask(), router);

    final ChapterFactCheck fc = t.chapters.single.factCheck!;
    expect(fc.ok, isFalse, reason: '没跑成必须 ok=false，不能当干净结果');
    expect(fc.fabrications, isEmpty);
    expect(joined(t), contains('核查未跑成'),
        reason: '必须显式告知「不能据此认为本章无编造」');
    expect(t.chapters.single.issues.any((String s) => s.contains('编造核查未跑成')),
        isTrue,
        reason: 'issues 里必须留人工核对提示');
    expect(t.chapters.single.content, isNotEmpty, reason: '没跑成不应改动正文');
    expect(router.fixCalls, 0, reason: '没跑成不该走定点修');
  });

  test('0 命中：ok=true 且 fabrications 为空，不触发定点修', () async {
    final _ScriptedRouter router = _ScriptedRouter(
      outline: outlineJson(),
      scenePlan: scenePlanJson(),
      factCheckResults: <String>[factCheckJson(0)],
    );
    final AiPipelineTask t = await runTask(makeTask(), router);

    final ChapterFactCheck fc = t.chapters.single.factCheck!;
    expect(fc.ok, isTrue);
    expect(fc.fabrications, isEmpty);
    expect(fc.repaired, isFalse);
    expect(joined(t), contains('编造核查通过'));
    expect(router.fixCalls, 0, reason: '0 命中不应调用定点修');
  });

  test('命中 → 定点修 → 复检命中下降 → 采纳修复稿', () async {
    final _ScriptedRouter router = _ScriptedRouter(
      outline: outlineJson(),
      scenePlan: scenePlanJson(),
      factCheckResults: <String>[
        factCheckJson(2), // 首轮 2 处
        factCheckJson(1), // 复检 1 处（下降 → 采纳）
      ],
      fixOutput: fixText,
    );
    final AiPipelineTask t = await runTask(makeTask(), router);

    final ChapterFactCheck fc = t.chapters.single.factCheck!;
    expect(fc.ok, isTrue);
    expect(fc.repaired, isTrue, reason: '复检下降必须采纳');
    expect(fc.firstRoundCount, 2);
    expect(fc.fabrications.length, 1, reason: '采纳后记复检命中数');
    expect(joined(t), contains('复检 2 → 1'),
        reason: '日志必须记录首轮到复检的下降');
    expect(t.chapters.single.content, contains('传闻'),
        reason: '修复稿必须拼进成书');
  });

  test('命中 → 定点修 → 复检未下降 → 回滚原文（首轮命中照记）', () async {
    final _ScriptedRouter router = _ScriptedRouter(
      outline: outlineJson(),
      scenePlan: scenePlanJson(),
      factCheckResults: <String>[
        factCheckJson(2), // 首轮 2 处
        factCheckJson(2), // 复检仍 2 处（未下降 → 回滚）
      ],
      fixOutput: fixText,
    );
    final AiPipelineTask t = await runTask(makeTask(), router);

    final ChapterFactCheck fc = t.chapters.single.factCheck!;
    expect(fc.ok, isTrue);
    expect(fc.repaired, isFalse, reason: '未下降绝不采纳');
    expect(fc.firstRoundCount, 2, reason: '首轮命中数必须照记');
    expect(joined(t), contains('回滚'),
        reason: '必须记录「复检未改善，回滚保留原文」');
    expect(t.chapters.single.content, isNot(contains('传闻')),
        reason: '修复稿不得拼进成书');
  });

  test('修复稿被采纳闸拒绝（空产出）：保留原文但照记编造问题', () async {
    final _ScriptedRouter router = _ScriptedRouter(
      outline: outlineJson(),
      scenePlan: scenePlanJson(),
      factCheckResults: <String>[factCheckJson(1), factCheckJson(1)],
      fixOutput: '', // 空产出 → patchReject '空产出'
    );
    final AiPipelineTask t = await runTask(makeTask(), router);

    final ChapterFactCheck fc = t.chapters.single.factCheck!;
    expect(fc.ok, isTrue);
    expect(fc.repaired, isFalse, reason: '空产出绝不采纳');
    expect(joined(t), contains('未过采纳闸'),
        reason: '必须记录「修复稿未过采纳闸」');
    expect(t.chapters.single.issues.any((String s) => s.contains('编造')), isTrue,
        reason: '编造问题必须留痕，不能被静默吞掉');
  });

  test('定点修 prompt 携带字数硬下限（禁以删代修）', () async {
    final List<String> captured = <String>[];
    final _ScriptedRouter router = _ScriptedRouter(
      outline: outlineJson(),
      scenePlan: scenePlanJson(),
      factCheckResults: <String>[factCheckJson(1), factCheckJson(1)],
      fixOutput: fixText,
      capturedFixUser: captured,
    );
    await runTask(makeTask(), router);

    expect(captured, isNotEmpty, reason: '必须捕获到定点修 prompt');
    expect(captured.first, contains('字数硬约束'),
        reason: '修复 prompt 必须下发字数硬下限');
    expect(captured.first, contains('不得少于'),
        reason: '下限必须显式给出字数');
  });

  test('useFactCheck=false：整段闭环完全跳过，不调用核查', () async {
    final _ScriptedRouter router = _ScriptedRouter(
      outline: outlineJson(),
      scenePlan: scenePlanJson(),
      factCheckResults: <String>[],
    );
    final AiPipelineTask t = await runTask(makeTask(useFactCheck: false), router);

    expect(t.chapters.single.factCheck, isNull,
        reason: '关闭时不应有任何核查记录');
    expect(router.factCalls, 0, reason: '关闭时一次核查都不该调');
    expect(joined(t), isNot(contains('编造核查')));
  });
}

/// 按 (system, user) 分流的假 router（零网络、零延时）。
///
/// **按 user 内容分流，不只按 system**——这是踩过坑之后的做法：`editorSystemPrompt`
/// 被两处复用（去AI味编辑一轮 + 定点修），只按 system 分流会把去AI味那轮的
/// prompt 当成「定点修 prompt」捕获，断言于是跑到错误的文本上（第一版实测如此）。
///
/// - user 含 '被独立事实核查员判出' → 定点修：返回 [fixOutput]，捕获 user，计数 fixCalls；
/// - factCheckSystemPrompt → 依次返回 [factCheckResults]（首轮、复检…），计数 factCalls；
/// - plannerSystemPrompt → user 含 'chapter_outlines' 出大纲，否则出场景规划；
/// - writerSystemPrompt → 场景正文（带章末钩子，字数够过闸）；
/// - titlerSystemPrompt → 标题；
/// - 其余（含去AI味编辑）→ 原样返回空串，让调用方按「无产出」路径走。
class _ScriptedRouter implements LlmRouter {
  _ScriptedRouter({
    required this.outline,
    required this.scenePlan,
    required this.factCheckResults,
    this.fixOutput = '',
    this.capturedFixUser,
  });

  final String outline;
  final String scenePlan;
  final List<String> factCheckResults;
  final String fixOutput;
  final List<String>? capturedFixUser;

  int factCalls = 0;
  int fixCalls = 0;

  /// 是否为「定点修」调用（与去AI味编辑区分，见类注释）。
  static bool _isFactFix(String user) => user.contains('被独立事实核查员判出');

  @override
  Future<LlmRouteResult> call(
    List<LlmConfig> chain, {
    required String system,
    required String user,
    double? temperature,
    void Function(String logLine)? onLog,
    bool Function()? isCancelled,
  }) async {
    String content = '';
    if (_isFactFix(user)) {
      content = fixOutput;
      fixCalls++;
      capturedFixUser?.add(user);
    } else if (system == factCheckSystemPrompt) {
      content = factCheckResults.isEmpty
          ? ''
          : factCheckResults[factCalls % factCheckResults.length];
      factCalls++;
    } else if (system == plannerSystemPrompt) {
      content = user.contains('chapter_outlines') ? outline : scenePlan;
    } else if (system == writerSystemPrompt) {
      content = sceneBody;
    } else if (system == titlerSystemPrompt) {
      content = '第 1 章';
    }
    return LlmRouteResult(
      content: content,
      used: chain.isEmpty ? null : chain.first,
    );
  }
}
