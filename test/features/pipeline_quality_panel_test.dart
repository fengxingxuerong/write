import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/prompts/pipeline_prompts.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/security/secret_store.dart';
import 'package:novel_writer/core/theme/app_theme.dart';
import 'package:novel_writer/features/ai_pipeline/ai_pipeline_pages.dart';
import 'package:novel_writer/features/ai_pipeline/pipeline_quality_panel.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/models/llm_usage.dart';

/// 质量面板与结构化质量记录的行为护栏。
///
/// 重点钉死三条**曾经被违反过**的语义：
/// 1. 「未核查」不得显示成「核查通过 ✅」（Python 端门禁第 16 项的核心教训）；
/// 2. 「未评分」不得用 0 分填充（0 分是「评了但很差」）；
/// 3. 结构化记录必须能往返序列化，否则评分只活在内存里、断点续跑即丢。
void main() {
  AiPipelineTask taskWith(
    List<PipelineChapter> chapters, {
    LlmLedger? llmLedger,
  }) =>
      AiPipelineTask(
        id: 't1',
        config: const AiPipelineConfig(),
        outline: const <String, dynamic>{'title': '测试书'},
        chapters: chapters,
        llmLedger: llmLedger,
        createdAt: DateTime(2026, 10, 2),
      );

  PipelineChapter chapter({
    int idx = 1,
    ChapterQualityReview? review,
    ChapterFactCheck? factCheck,
    List<PromiseCheck>? promiseChecks,
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
        promiseChecks: promiseChecks,
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

  group('伏笔台账模型', () {
    const ForeshadowEntry a = ForeshadowEntry(desc: '银鱼来历', planted: 1);
    const ForeshadowEntry b = ForeshadowEntry(desc: '断剑秘密', planted: 3);

    test('解析：丢弃 desc 为空的条目与坏 JSON', () {
      final ForeshadowLedger l = ForeshadowLedger.parse(
        '{"foreshadows":[{"desc":"银鱼来历","planted":1,"status":"open"},'
        '{"desc":"  ","planted":2},{"desc":"断剑","planted":3,"status":"closed"}]}',
      );
      expect(l.items.length, 2, reason: 'desc 为空的条目无法验收，必须丢弃');
      expect(l.open.length, 1);
      expect(l.closed.length, 1);
      expect(ForeshadowLedger.parse('not json').items, isEmpty);
      expect(ForeshadowLedger.parse('').items, isEmpty);
      expect(ForeshadowLedger.parse('[]').items, isEmpty);
    });

    test('非法 status 按 open 处理（不虚报已回收）', () {
      final ForeshadowEntry e = ForeshadowEntry.fromJson(
        <String, dynamic>{'desc': 'x', 'status': 'CLOSED'},
      );
      expect(e.closed, isFalse, reason: '大写 CLOSED 不是合法值，不得当已回收');
    });

    test('isStale：埋设满 5 章仍 open 才算超时', () {
      expect(a.isStale(5), isFalse, reason: '1→5 恰 4 章，未到阈值');
      expect(a.isStale(6), isTrue, reason: '1→6 恰 5 章，超时');
      expect(b.isStale(20), isTrue);
      expect(
        a.markClosed(6, '他终于认了').isStale(20),
        isFalse,
        reason: '已回收不参与超时判定',
      );
      // 脏台账：埋设章号大于当前章号 → 不告警（宁可漏报不误伤）。
      expect(
        const ForeshadowEntry(desc: 'x', planted: 99).isStale(10),
        isFalse,
      );
      expect(const ForeshadowEntry(desc: 'x', planted: 0).isStale(10), isFalse);
    });

    test('promiseBlock：普通章只取超时条目，收尾章取全部 open', () {
      const ForeshadowLedger l = ForeshadowLedger(<ForeshadowEntry>[a, b]);
      // 普通章（staleAfter=5）：到第 10 章，a（埋于 1）已过 9 章、b（埋于 3）
      // 已过 7 章，**两条都超时**——这里用第 6 章才能只命中 a（1→6 恰 5 章）。
      expect(l.promiseBlock(6, staleAfter: 5).length, 1);
      expect(l.promiseBlock(6, staleAfter: 5).first.desc, '银鱼来历');
      // 超时阈值内（3→6 恰 3 章）一条都不该进清单。
      expect(l.promiseBlock(3, staleAfter: 5).isEmpty, isTrue);
      // 收尾章（staleAfter=0）：全部 open。
      expect(l.promiseBlock(10, staleAfter: 0).length, 2);
    });

    test('打勾联动：✅ 标记 closed 并记证据句', () {
      const ForeshadowLedger l = ForeshadowLedger(<ForeshadowEntry>[a, b]);
      final List<ForeshadowEntry> block = l.promiseBlock(10, staleAfter: 0);
      final (ForeshadowLedger next, int n) = l.applyClosures(
        block,
        const <PromiseCheck>[
          PromiseCheck(id: 1, fulfilled: true, evidence: '他终于认了'),
          PromiseCheck(id: 2, fulfilled: false, evidence: '只留了悬念'),
        ],
        10,
      );
      expect(n, 1);
      expect(next.items[0].closed, isTrue);
      expect(next.items[0].recovered, 10);
      expect(next.items[0].evidence, '他终于认了');
      expect(next.items[1].closed, isFalse, reason: '❌ 未兑现必须留在 open');
      // 原台账不可变（失败可回滚）。
      expect(l.items[0].closed, isFalse);
    });

    test('打勾联动：验收环节失败时一条都不联动（核心语义护栏）', () {
      // 这是最容易骗过作者的一种状态：验收调用挂了，若照样联动台账，
      // 一次静默失效会被记成 N 条伏笔已回收，终审再也看不出真相。
      const ForeshadowLedger l = ForeshadowLedger(<ForeshadowEntry>[a, b]);
      final List<ForeshadowEntry> block = l.promiseBlock(10, staleAfter: 0);
      final (ForeshadowLedger next, int n) = l.applyClosures(
        block,
        const <PromiseCheck>[PromiseCheck.failure],
        10,
      );
      expect(n, 0);
      expect(next.open.length, 2, reason: '验收失败不得关闭任何条目');
    });

    test('打勾联动：序号越界不联动（不误伤别的条目）', () {
      const ForeshadowLedger l = ForeshadowLedger(<ForeshadowEntry>[a]);
      final (ForeshadowLedger next, int n) = l.applyClosures(
        l.open,
        const <PromiseCheck>[
          PromiseCheck(id: 9, fulfilled: true, evidence: 'x'),
          PromiseCheck(id: 0, fulfilled: true, evidence: 'y'),
        ],
        10,
      );
      expect(n, 0);
      expect(next.open.length, 1);
    });

    test('打勾联动：空清单/空结果原样返回', () {
      const ForeshadowLedger l = ForeshadowLedger(<ForeshadowEntry>[a]);
      expect(l.applyClosures(<ForeshadowEntry>[], const <PromiseCheck>[], 10).$2, 0);
      expect(l.applyClosures(l.open, const <PromiseCheck>[], 10).$2, 0);
    });
  });

  group('打勾结果序列化与面板渲染', () {
    test('promiseChecks 往返：null 与空列表严格区分', () {
      // null = 没打勾；[] = 打过勾但清单为空。两者在 UI 上结论完全不同。
      const PipelineChapter none = PipelineChapter(
        idx: 1,
        title: 'a',
        content: 'x',
        rawWords: 1,
        words: 1,
      );
      expect(PipelineChapter.fromJson(none.toJson()).promiseChecks, isNull);

      const PipelineChapter empty = PipelineChapter(
        idx: 1,
        title: 'a',
        content: 'x',
        rawWords: 1,
        words: 1,
        promiseChecks: <PromiseCheck>[],
      );
      expect(PipelineChapter.fromJson(empty.toJson()).promiseChecks, isEmpty);
    });

    test('打勾结果往返保留 ✅/❌/☠ 与证据句', () {
      const PipelineChapter c = PipelineChapter(
        idx: 1,
        title: 'a',
        content: 'x',
        rawWords: 1,
        words: 1,
        promiseChecks: <PromiseCheck>[
          PromiseCheck(id: 1, fulfilled: true, evidence: '他终于认了'),
          PromiseCheck(id: 2, fulfilled: false, evidence: '只留了悬念'),
          PromiseCheck.failure,
        ],
      );
      final List<PromiseCheck>? back =
          PipelineChapter.fromJson(c.toJson()).promiseChecks;
      expect(back, isNotNull);
      expect(back!.length, 3);
      expect(back[0].mark, '✅');
      expect(back[1].mark, '❌');
      expect(back[2].mark, '☠');
      expect(back[2].failed, isTrue);
      expect(back[0].evidence, '他终于认了');
    });

    testWidgets('面板显示打勾明细与证据句', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        taskWith(<PipelineChapter>[
          chapter(
            idx: 1,
            promiseChecks: const <PromiseCheck>[
              PromiseCheck(id: 1, fulfilled: true, evidence: '他把银鱼递了回来'),
              PromiseCheck(id: 2, fulfilled: false, evidence: '只留了悬念没交代'),
            ],
          ),
        ]),
      );
      expect(find.textContaining('回收清单打勾'), findsOneWidget);
      expect(find.textContaining('1/2 条兑现'), findsOneWidget);
      expect(find.textContaining('他把银鱼递了回来'), findsOneWidget);
      expect(find.textContaining('只留了悬念没交代'), findsOneWidget);
    });

    testWidgets('打勾失败显示「未执行」而非「0 条兑现」',
        (WidgetTester tester) async {
      await pumpPanel(
        tester,
        taskWith(<PipelineChapter>[
          chapter(
            idx: 1,
            promiseChecks: const <PromiseCheck>[PromiseCheck.failure],
          ),
        ]),
      );
      // 提示行与逐条明细都会出现「未执行」字样，故断言精确文案而非子串。
      expect(find.textContaining('回收清单打勾未执行（验收调用失败）'),
          findsOneWidget);
      expect(find.textContaining('请人工复核'), findsOneWidget);
      // 关键断言：不得显示成「0/1 条兑现」——那会被读成「验过了，都没兑现」。
      expect(find.textContaining('条兑现'), findsNothing);
    });

    test('汇总区分兑现/未兑现/打勾失败三者', () {
      final QualitySummary s = summarize(<PipelineChapter>[
        chapter(
          idx: 1,
          promiseChecks: const <PromiseCheck>[
            PromiseCheck(id: 1, fulfilled: true, evidence: 'a'),
          ],
        ),
        chapter(
          idx: 2,
          promiseChecks: const <PromiseCheck>[
            PromiseCheck(id: 1, fulfilled: false, evidence: 'b'),
          ],
        ),
        chapter(
          idx: 3,
          promiseChecks: const <PromiseCheck>[PromiseCheck.failure],
        ),
      ]);
      expect(s.promiseFulfilled, 1);
      expect(s.promiseUnfulfilled, 1);
      expect(
        s.promiseCheckFailed,
        1,
        reason: '打勾失败必须单独计数，不能混进未兑现',
      );
    });

    test('汇总统计伏笔未收与超时（传入台账与当前章号）', () {
      final QualitySummary s = summarize(
        <PipelineChapter>[chapter(idx: 10)],
        ledger: const ForeshadowLedger(<ForeshadowEntry>[
          ForeshadowEntry(desc: '银鱼来历', planted: 1),
          ForeshadowEntry(desc: '断剑', planted: 3),
          ForeshadowEntry(
            desc: '旧约',
            planted: 2,
            recovered: 4,
            status: 'closed',
          ),
        ]),
        lastIdx: 10,
      );
      expect(s.openForeshadows, 2, reason: '已回收的不计入未收');
      // 到第 10 章：planted=1 已 9 章、planted=3 已 7 章，两条都超 5 章阈值。
      expect(s.staleForeshadows, 2);
    });
  });

  group('打勾 prompt', () {
    test('验收 prompt 含清单编号与「只暗示不算兑现」判据', () {
      final String p = promiseVerifyPrompt(
        '正文内容',
        const <ForeshadowLine>[
          ForeshadowLine('银鱼来历'),
          ForeshadowLine('断剑'),
        ],
        7,
      );
      expect(p, contains('1. 银鱼来历'));
      expect(p, contains('2. 断剑'));
      expect(p, contains('第 7 章'));
      expect(p, contains('只暗示/留白/远景铺陈不算兑现'));
      expect(p, contains('evidence'));
    });

    test('补写 prompt 点名未兑现条目、给字数下限、禁止暗示代替', () {
      final String p = promiseRepairPrompt(
        '原正文内容',
        const <UnfulfilledPromise>[
          UnfulfilledPromise(desc: '银鱼来历', reason: '只留悬念'),
        ],
        3,
        minWords: 1800,
      );
      expect(p, contains('银鱼来历'));
      expect(p, contains('只留悬念'));
      expect(p, contains('第 3 章'));
      expect(p, contains('不得少于 1800 字'));
      expect(p, contains('只增补不删减'));
      expect(p, contains('不得用「似乎 / 也许 / 据说 / 留待后文」'));
    });
  });

  group('终审官模型', () {
    test('hardDimensions 抓出 ≤40 的硬伤维（防总分掩盖）', () {
      // 「总分 83 但伏笔回收 30」是这类评审最危险的漏报——总分好看，
      // 作者就不会去看那一维，直到投稿被退才发现。
      const ChiefReview r = ChiefReview(
        round: 1,
        overall: 83,
        dimensions: <String, int>{
          '开篇钩子': 90,
          '节奏曲线': 75,
          '伏笔回收': 30,
          '结局力度': 41,
        },
      );
      expect(r.hardDimensions.keys.toList(), <String>['伏笔回收'],
          reason: '40 是硬伤线，41 不算');
      expect(r.ok, isTrue);
    });

    test('无结论（overall=-1）与 0 分严格区分', () {
      expect(const ChiefReview(round: 1).ok, isFalse);
      expect(const ChiefReview(round: 1, overall: 0).ok, isTrue,
          reason: '评了 0 分是结论，没跑出来不是');
    });

    test('verdictOf 本地判档：同分必同档', () {
      expect(AiPipelineTask.verdictOf(85), '高潜可投');
      expect(AiPipelineTask.verdictOf(80), '高潜可投');
      expect(AiPipelineTask.verdictOf(79), '可投');
      expect(AiPipelineTask.verdictOf(70), '可投');
      expect(AiPipelineTask.verdictOf(69), '需打磨');
      expect(AiPipelineTask.verdictOf(60), '需打磨');
      expect(AiPipelineTask.verdictOf(59), '不建议');
      expect(AiPipelineTask.verdictOf(0), '不建议');
    });

    test('终审记录与打回轨迹往返序列化', () {
      final AiPipelineTask t = AiPipelineTask(
        id: 't1',
        config: const AiPipelineConfig(),
        createdAt: DateTime(2026, 10, 2),
        chiefReviews: const <ChiefReview>[
          ChiefReview(
            round: 2,
            overall: 76,
            dimensions: <String, int>{'节奏曲线': 62},
            verdict: '可投',
            topIssues: <ChiefIssue>[
              ChiefIssue(chapter: 7, issue: '节奏塌陷', evidence: '第7章爽点0'),
            ],
            fixPriority: <String>['补一处打脸'],
            samples: 3,
          ),
        ],
        chiefRewrites: const <ChiefRewriteRecord>[
          ChiefRewriteRecord(
            chapterIdx: 7,
            reason: '节奏塌陷',
            oldWords: 3000,
            newWords: 3100,
            rescore: 70,
          ),
        ],
      );
      final AiPipelineTask back = AiPipelineTask.fromJson(t.toJson());
      expect(back.chiefReviews.length, 1);
      expect(back.latestChiefReview!.overall, 76);
      expect(back.latestChiefReview!.round, 2);
      expect(back.latestChiefReview!.dimensions['节奏曲线'], 62);
      expect(back.latestChiefReview!.topIssues.first.issue, '节奏塌陷');
      expect(back.latestChiefReview!.samples, 3);
      expect(back.chiefRewrote, isTrue);
      expect(back.chiefRewrites.first.chapterIdx, 7);
      expect(back.chiefRewrites.first.delta, 100);
    });

    test('旧任务文件无终审键 → 空列表（= 尚未终审），非 0 分', () {
      final AiPipelineTask back = AiPipelineTask.fromJson(
        <String, dynamic>{'id': 'x', 'createdAt': '2026-10-02T00:00:00'},
      );
      expect(back.chiefReviews, isEmpty);
      expect(back.chiefRewrites, isEmpty);
      expect(back.latestChiefReview, isNull);
      expect(back.chiefRewrote, isFalse);
      expect(back.chiefSamples, 3);
    });
  });

  group('终审 prompt', () {
    test('含逐章指标、未收伏笔与三段样本，判据要求具体到章', () {
      final String p = chiefEditorPrompt(
        title: '逆鳞焚天',
        genre: '玄幻',
        totalWords: 120000,
        chapterCount: 40,
        rows: '第1章《开局》3000字｜评审82分｜钩子有｜AI味3%｜问题0处',
        openForeshadows: '第1章埋：银鱼来历',
        stateTrack: '主角断左臂',
        first: '首章开头',
        last: '末章开头',
        worstIdx: 7,
        worstText: '最低分章开头',
      );
      expect(p, contains('《逆鳞焚天》'));
      expect(p, contains('总字数：120000'));
      expect(p, contains('章节数：40'));
      expect(p, contains('第1章《开局》3000字'));
      expect(p, contains('第1章埋：银鱼来历'));
      expect(p, contains('主角断左臂'));
      expect(p, contains('评分最低的第 7 章'));
      expect(p, contains('问题要具体到章'));
    });

    test('空输入降级为「（无…）」而不是空白让模型自行猜测', () {
      final String p = chiefEditorPrompt(
        title: 'x',
        genre: '玄幻',
        totalWords: 0,
        chapterCount: 0,
        rows: '   ',
        openForeshadows: '',
        stateTrack: '',
        first: '',
        last: '',
        worstIdx: 0,
        worstText: '',
      );
      expect(p, contains('（无章节数据）'));
      expect(p, contains('（无未收伏笔）'));
      expect(p, contains('（无）'));
    });

    test('打回 prompt 点名问题、证据与优先级，要求实质性修改', () {
      final String p = chiefRewritePrompt(
        text: '原正文',
        issue: '节奏塌陷，第7章无爽点',
        evidence: '第7章爽点 0.00/千字',
        fixes: '补一处当众打脸',
      );
      expect(p, contains('节奏塌陷，第7章无爽点'));
      expect(p, contains('第7章爽点 0.00/千字'));
      expect(p, contains('补一处当众打脸'));
      expect(p, contains('实质性修改'));
      expect(p, contains('不要重写全章'));
      expect(p, contains('原章节正文'));
    });
  });

  group('终审官面板渲染', () {
    testWidgets('未终审显示空态而非报错', (WidgetTester tester) async {
      await pumpPanel(tester, taskWith(<PipelineChapter>[chapter(idx: 1)]));
      expect(find.text('终审官'), findsOneWidget);
      expect(find.textContaining('尚未终审'), findsOneWidget);
    });

    testWidgets('终审无结论时不得显示成 0 分', (WidgetTester tester) async {
      final AiPipelineTask t = taskWith(<PipelineChapter>[chapter(idx: 1)])
        ..chiefReviews.add(const ChiefReview(round: 1));
      await pumpPanel(tester, t);
      expect(find.textContaining('终审本轮无结论'), findsOneWidget);
      expect(find.textContaining('不等于「0 分」'), findsOneWidget);
      expect(find.textContaining('综合 0 分'), findsNothing);
    });

    testWidgets('显示判档、六维、硬伤告警与问题清单',
        (WidgetTester tester) async {
      final AiPipelineTask t = taskWith(<PipelineChapter>[chapter(idx: 7)])
        ..chiefReviews.add(const ChiefReview(
          round: 2,
          overall: 76,
          dimensions: <String, int>{
            '开篇钩子': 88,
            '节奏曲线': 62,
            '伏笔回收': 30,
          },
          verdict: '可投',
          topIssues: <ChiefIssue>[
            ChiefIssue(
              chapter: 7,
              issue: '节奏塌陷',
              evidence: '第7章爽点 0.00/千字',
            ),
          ],
          samples: 3,
        ));
      await pumpPanel(tester, t);
      expect(find.textContaining('第 2 轮'), findsOneWidget);
      expect(find.textContaining('二审为准'), findsOneWidget);
      expect(find.textContaining('综合 76 分'), findsOneWidget);
      expect(find.text('可投'), findsOneWidget);
      expect(find.textContaining('3 次采样中位数'), findsOneWidget);
      // 硬伤维度必须单独告警。
      expect(find.textContaining('硬伤维度'), findsOneWidget);
      expect(find.textContaining('伏笔回收'), findsWidgets);
      expect(find.textContaining('节奏塌陷'), findsOneWidget);
      expect(find.textContaining('第7章爽点 0.00/千字'), findsOneWidget);
    });

    testWidgets('打回轨迹逐条展示，含未过闸的记录',
        (WidgetTester tester) async {
      final AiPipelineTask t = taskWith(<PipelineChapter>[chapter(idx: 7)])
        ..chiefReviews.add(const ChiefReview(
          round: 2,
          overall: 76,
          verdict: '可投',
        ))
        ..chiefRewrites.addAll(const <ChiefRewriteRecord>[
          ChiefRewriteRecord(
            chapterIdx: 7,
            reason: '节奏塌陷',
            oldWords: 3000,
            newWords: 3100,
          ),
          ChiefRewriteRecord(
            chapterIdx: 9,
            reason: '钩子缺失',
            oldWords: 2800,
            newWords: 2800,
            applied: false,
          ),
        ]);
      await pumpPanel(tester, t);
      expect(find.textContaining('打回重写轨迹'), findsOneWidget);
      expect(find.textContaining('✅ 第7章：节奏塌陷｜3000→3100 字'), findsOneWidget);
      expect(find.textContaining('☠ 第9章：钩子缺失'), findsOneWidget);
      expect(find.textContaining('未过采纳闸，保留原文'), findsOneWidget);
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
            home: const AiPipelineRunPage(taskId: 't1'),
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

  group('AI 用量条', () {
    testWidgets('已知用量显示调用次数、token 与估算成本', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        taskWith(
          <PipelineChapter>[chapter()],
          llmLedger: LlmLedger(<LlmLedgerEntry>[
            const LlmLedgerEntry(
              role: '正文写手',
              model: 'deepseek-v4-flash',
              chapterIdx: 1,
              usage: LlmUsage(inputTokens: 1000000, outputTokens: 1000000),
            ),
          ]),
        ),
      );

      expect(find.text('AI 用量'), findsOneWidget);
      expect(find.text('1'), findsWidgets);
      expect(find.text('1,000,000'), findsNWidgets(2));
      expect(find.text('\$0.50'), findsOneWidget);
    });

    testWidgets('端点未返回 usage 时显示未知而不是 0', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        taskWith(
          <PipelineChapter>[chapter()],
          llmLedger: LlmLedger(<LlmLedgerEntry>[
            const LlmLedgerEntry(role: '正文写手', model: 'some-model'),
          ]),
        ),
      );

      // 输入 / 输出 / 成本三处都未知；不能出现「0 token / $0.00」。
      expect(find.text('未知'), findsNWidgets(3));
      expect(find.text('\$0.00'), findsNothing);
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
