import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/security/secret_store.dart';
import 'package:novel_writer/core/theme/app_theme.dart';
import 'package:novel_writer/features/ai_pipeline/ai_pipeline_pages.dart';
import 'package:novel_writer/features/ai_pipeline/pipeline_quality_panel.dart';

/// 质量面板与结构化质量记录的行为护栏。
///
/// 重点钉死三条**曾经被违反过**的语义：
/// 1. 「未核查」不得显示成「核查通过 ✅」（Python 端门禁第 16 项的核心教训）；
/// 2. 「未评分」不得用 0 分填充（0 分是「评了但很差」）；
/// 3. 结构化记录必须能往返序列化，否则评分只活在内存里、断点续跑即丢。
void main() {
  AiPipelineTask taskWith(List<PipelineChapter> chapters) => AiPipelineTask(
        id: 't1',
        config: const AiPipelineConfig(),
        outline: const <String, dynamic>{'title': '测试书'},
        chapters: chapters,
        createdAt: DateTime(2026, 10, 2),
      );

  PipelineChapter chapter({
    int idx = 1,
    ChapterQualityReview? review,
    ChapterFactCheck? factCheck,
    List<String> issues = const <String>[],
  }) =>
      PipelineChapter(
        idx: idx,
        title: '第$idx章',
        content: '正文',
        rawWords: 2000,
        words: 2000,
        issues: issues,
        review: review,
        factCheck: factCheck,
      );

  Future<void> pumpPanel(WidgetTester tester, AiPipelineTask task) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: PipelineQualityPanel(task: task)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('结构化质量记录：序列化往返', () {
    test('评分与核查记录能完整往返', () {
      final PipelineChapter c = chapter(
        review: const ChapterQualityReview(
          idx: 1,
          overall: 82,
          dims: <String, int>{'opening': 90, 'hook': 60},
          comment: '钩子偏弱',
          evidence: '章末钩子检测：未命中',
        ),
        factCheck: const ChapterFactCheck(
          idx: 1,
          fabrications: <Fabrication>[
            Fabrication(claim: '老周欠债三年', evidence: '台账无据', type: 'number'),
          ],
          ok: true,
          repaired: true,
          firstRoundCount: 3,
        ),
      );
      final PipelineChapter back = PipelineChapter.fromJson(c.toJson());
      expect(back.review, isNotNull);
      expect(back.review!.overall, 82);
      expect(back.review!.dims['opening'], 90);
      expect(back.review!.comment, '钩子偏弱');
      expect(back.review!.evidence, '章末钩子检测：未命中');
      expect(back.factCheck, isNotNull);
      expect(back.factCheck!.ok, isTrue);
      expect(back.factCheck!.repaired, isTrue);
      expect(back.factCheck!.firstRoundCount, 3);
      expect(back.factCheck!.count, 1);
      expect(back.factCheck!.fabrications.first.claim, '老周欠债三年');
      expect(back.factCheck!.fabrications.first.typeLabel, '数字漂移');
    });

    test('旧任务文件（无新键）读出的是「未评分/未核查」而非 0 分', () {
      // 回归护栏：老 json 里没有 review/factCheck 两个键。若反序列化把缺省
      // 写成 overall=0，UI 会把每章旧任务显示成「评了 0 分」，是凭空捏造数据。
      final PipelineChapter back = PipelineChapter.fromJson(
        <String, dynamic>{
          'idx': 1,
          'title': '旧章',
          'content': '正文',
          'rawWords': 100,
          'words': 100,
        },
      );
      expect(back.review, isNull);
      expect(back.factCheck, isNull);
      expect(back.review?.scored ?? false, isFalse);
    });

    test('核查记录缺 ok 字段时按「未跑成」处理，不谎称已通过', () {
      // fail-open 是这里最危险的默认值：ok 缺失若默认 true，一次静默失效会被
      // 记成「核查通过」。Python 端门禁第 16 项正是为这条语义设的。
      final ChapterFactCheck f = ChapterFactCheck.fromJson(
        <String, dynamic>{'idx': 1, 'fabrications': <dynamic>[]},
      );
      expect(f.ok, isFalse);
    });
  });

group('模型层派生属性', () {
    test('weakestDim 指出最低维度；无维度时为空串', () {
      const ChapterQualityReview r = ChapterQualityReview(
        idx: 1,
        overall: 70,
        dims: <String, int>{'opening': 85, 'hook': 40, 'rhythm': 70},
      );
      expect(r.weakestDim, 'hook');
      expect(const ChapterQualityReview(idx: 1, overall: 90).weakestDim, '');
    });

    test('达线阈值 78：77 不达线、78 达线', () {
      expect(const ChapterQualityReview(idx: 1, overall: 77).pass, isFalse);
      expect(const ChapterQualityReview(idx: 1, overall: 78).pass, isTrue);
    });

    test('dimLabel 覆盖五维；未知键原样返回不吞信息', () {
      expect(ChapterQualityReview.dimLabel('opening'), '开篇');
      expect(ChapterQualityReview.dimLabel('hook'), '钩子');
      expect(ChapterQualityReview.dimLabel('futureDim'), 'futureDim');
    });
  });

  group('汇总口径', () {
    test('未核查与核查未跑成都计入 notChecked，不计入残留编造', () {
      final QualitySummary s = summarize(<PipelineChapter>[
        chapter(idx: 1, factCheck: const ChapterFactCheck(idx: 1, ok: true)),
        chapter(idx: 2),
        chapter(idx: 3, factCheck: const ChapterFactCheck(idx: 3, ok: false)),
      ]);
      expect(s.notChecked, 2, reason: '未核查 + 核查未跑成 都不得算「干净」');
      expect(s.residualFabrications, 0);
    });

    test('残留编造只统计核查成功章的命中数', () {
      final QualitySummary s = summarize(<PipelineChapter>[
        chapter(
          idx: 1,
          factCheck: const ChapterFactCheck(
            idx: 1,
            ok: true,
            fabrications: <Fabrication>[
              Fabrication(claim: 'a', evidence: '', type: 'number'),
              Fabrication(claim: 'b', evidence: '', type: 'state'),
            ],
          ),
        ),
        // 核查未跑成的章即使带命中明细也不进残留统计（结论不可信）。
        chapter(
          idx: 2,
          factCheck: const ChapterFactCheck(
            idx: 2,
            ok: false,
            fabrications: <Fabrication>[
              Fabrication(claim: 'c', evidence: '', type: 'identity'),
            ],
          ),
        ),
      ]);
      expect(s.residualFabrications, 2);
    });

    test('达线章只统计真正评出分的章', () {
      final QualitySummary s = summarize(<PipelineChapter>[
        chapter(
          idx: 1,
          review: const ChapterQualityReview(idx: 1, overall: 90),
        ),
        chapter(
          idx: 2,
          review: const ChapterQualityReview(idx: 2, overall: 60),
        ),
        // 未评分章不得被算成「未达线」。
        chapter(idx: 3),
      ]);
      expect(s.scoredCount, 2);
      expect(s.passCount, 1);
    });
  });

  group('面板渲染', () {
    testWidgets('无章节时展示引导空态而非报错', (WidgetTester tester) async {
      await pumpPanel(tester, taskWith(<PipelineChapter>[]));
      expect(find.text('还没有章节'), findsOneWidget);
      expect(find.textContaining('五维评分'), findsOneWidget);
    });

    testWidgets('未核查不得显示成核查通过（核心语义护栏）',
        (WidgetTester tester) async {
      await pumpPanel(
        tester,
        taskWith(<PipelineChapter>[
          chapter(idx: 1, factCheck: const ChapterFactCheck(idx: 1, ok: false)),
        ]),
      );
      expect(find.textContaining('编造核查未跑成'), findsOneWidget);
      expect(find.textContaining('不能据此认为本章无编造'), findsOneWidget);
      // 关键断言：绝不能出现「通过 ✅」字样。
      expect(find.textContaining('编造核查通过'), findsNothing);
      expect(find.textContaining('0 处无据断言'), findsNothing);
    });

    testWidgets('未核查章节（factCheck 为 null）显示未核查而非通过',
        (WidgetTester tester) async {
      await pumpPanel(tester, taskWith(<PipelineChapter>[chapter(idx: 1)]));
      expect(find.textContaining('未做编造核查'), findsOneWidget);
      expect(find.textContaining('编造核查通过'), findsNothing);
    });

    testWidgets('核查通过显示绿色通过态', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        taskWith(<PipelineChapter>[
          chapter(idx: 1, factCheck: const ChapterFactCheck(idx: 1, ok: true)),
        ]),
      );
      expect(find.textContaining('编造核查通过'), findsOneWidget);
      expect(find.textContaining('0 处无据断言'), findsOneWidget);
    });

    testWidgets('编造命中逐条列出断言与依据', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        taskWith(<PipelineChapter>[
          chapter(
            idx: 1,
            factCheck: const ChapterFactCheck(
              idx: 1,
              ok: true,
              repaired: true,
              firstRoundCount: 3,
              fabrications: <Fabrication>[
                Fabrication(
                  claim: '老周欠债三年',
                  evidence: '台账无此记载',
                  type: 'number',
                ),
              ],
            ),
          ),
        ]),
      );
      expect(find.textContaining('编造核查命中 1 处'), findsOneWidget);
      expect(find.textContaining('首轮 3 处，修复后降至 1 处'), findsOneWidget);
      expect(find.textContaining('数字漂移'), findsOneWidget);
      expect(find.textContaining('老周欠债三年'), findsOneWidget);
      expect(find.textContaining('台账无此记载'), findsOneWidget);
    });

    testWidgets('评分区渲染综合分、五维条与短板维度',
        (WidgetTester tester) async {
      await pumpPanel(
        tester,
        taskWith(<PipelineChapter>[
          chapter(
            idx: 1,
            review: const ChapterQualityReview(
              idx: 1,
              overall: 82,
              dims: <String, int>{
                'opening': 90,
                'thrill': 55,
                'hook': 80,
                'motivation': 75,
                'rhythm': 88,
              },
              comment: '节奏不错但爽点偏少',
            ),
          ),
        ]),
      );
      expect(find.textContaining('综合 82 分'), findsOneWidget);
      expect(find.textContaining('✅ 达线'), findsOneWidget);
      expect(find.textContaining('短板：爽点'), findsOneWidget);
      expect(find.textContaining('点评：'), findsOneWidget);
      expect(find.textContaining('爽点偏少'), findsOneWidget);
      // 五维标签各出现一次。评语里也含「爽点」二字，故用精确匹配而非
      // textContaining——后者会把评语文本一起数进来。
      for (final String d in <String>['开篇', '爽点', '钩子', '动机', '节奏']) {
        expect(find.text(d), findsOneWidget, reason: '维度 $d 应有一个横条');
      }
    });

    testWidgets('未评分显示「未评分」而不是 0 分', (WidgetTester tester) async {
      await pumpPanel(tester, taskWith(<PipelineChapter>[chapter(idx: 1)]));
      expect(find.textContaining('本章未评分'), findsOneWidget);
      expect(find.textContaining('综合 0 分'), findsNothing);
    });

    testWidgets('阻断项逐条列出', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        taskWith(<PipelineChapter>[
          chapter(
            idx: 1,
            issues: const <String>['第 1 章主角 0 次出场', '第 1 章 2/4 个场景未产出正文'],
          ),
        ]),
      );
      expect(find.textContaining('问题 / 阻断项（2）'), findsOneWidget);
      expect(find.textContaining('主角 0 次出场'), findsOneWidget);
      expect(find.textContaining('场景未产出正文'), findsOneWidget);
    });

    testWidgets('总览四个数字正确', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        taskWith(<PipelineChapter>[
          chapter(
            idx: 1,
            review: const ChapterQualityReview(idx: 1, overall: 90),
            factCheck: const ChapterFactCheck(idx: 1, ok: true),
          ),
          chapter(
            idx: 2,
            review: const ChapterQualityReview(idx: 2, overall: 50),
            factCheck: const ChapterFactCheck(
              idx: 2,
              ok: true,
              fabrications: <Fabrication>[
                Fabrication(claim: 'x', evidence: '', type: 'state'),
              ],
            ),
          ),
          chapter(idx: 3),
        ]),
      );
      expect(find.text('质量总览'), findsOneWidget);
      // 已评章 2、达线章 1、未核查章 1、残留编造 1。
      expect(find.text('已评章'), findsOneWidget);
      expect(find.text('达线章'), findsOneWidget);
      expect(find.text('未核查章'), findsOneWidget);
      expect(find.text('残留编造'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsNWidgets(3));
    });
  });

  group('运行页：日志与质量分段切换', () {
    testWidgets('默认显示运行日志，切到质量段显示面板',
        (WidgetTester tester) async {
      final AiPipelineTask task = taskWith(<PipelineChapter>[
        chapter(
          idx: 1,
          review: const ChapterQualityReview(idx: 1, overall: 90),
        ),
      ]);
      task.addLog('[流水线] 启动：目标 100000 字');

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            pipelineStorageProvider.overrideWithValue(_TaskStorage(task)),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: AiPipelineRunPage(taskId: 't1'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 默认落在日志视图。
      expect(find.textContaining('[流水线] 启动'), findsOneWidget);
      expect(find.byType(PipelineQualityPanel), findsNothing);

      // 切到质量视图。
      await tester.tap(find.text('质量'));
      await tester.pumpAndSettle();
      expect(find.byType(PipelineQualityPanel), findsOneWidget);
      expect(find.textContaining('[流水线] 启动'), findsNothing);
      expect(find.text('质量总览'), findsOneWidget);

      // 再切回日志，确认可来回切换。
      await tester.tap(find.text('运行日志'));
      await tester.pumpAndSettle();
      expect(find.byType(PipelineQualityPanel), findsNothing);
      expect(find.textContaining('[流水线] 启动'), findsOneWidget);
    });
  });
}

/// 返回固定任务的存储桩（供运行页分段切换测试用）。
class _TaskStorage extends PipelineStorage {
  /// 构造存储桩。
  _TaskStorage(this.task)
      : super('unused-quality-panel-path', secretStore: InMemorySecretStore());

  /// 桩任务。
  final AiPipelineTask task;

  @override
  Future<AiPipelineTask?> loadTask(String id) async => task;

  @override
  Future<void> saveTask(AiPipelineTask task) async {}
}
