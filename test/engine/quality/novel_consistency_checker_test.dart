import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/quality/novel_consistency_checker.dart';
import 'package:novel_writer/models/chapter.dart';

/// NovelConsistencyChecker 单元测试。
void main() {
  group('NovelConsistencyChecker', () {
    test('空列表不报错', () {
      final ConsistencyReport r = NovelConsistencyChecker.check(<Chapter>[]);
      expect(r.hasIssues, isFalse);
      expect(r.totalIssues, 0);
    });

    test('单章无需跨章检查', () {
      final ConsistencyReport r = NovelConsistencyChecker.check(<Chapter>[
        makeChapter(0, '张三走进院落。李四说了几句话。'),
      ]);
      expect(r.hasIssues, isFalse);
    });

    test('检测到人名笔误（编辑距离=1）', () {
      final ConsistencyReport r = NovelConsistencyChecker.check(<Chapter>[
        makeChapter(0, '王小明走进院落。王小明不太高兴。'),
        makeChapter(1, '另一天，王小明继续走。王小明说话了。'),
        makeChapter(2, '第三天，王晓明出现了。王晓明回头看了一眼。'),
        makeChapter(3, '第四天，王晓明继续赶路。王晓明走了过去。'),
      ]);
      // 「王小明」与「王晓明」编辑距离 = 1，且各自跨 ≥ 2 章
      expect(r.nameIssues.isNotEmpty, isTrue);
      expect(
        r.nameIssues.any((i) =>
            i.reason.contains('王小明') && i.reason.contains('王晓明')),
        isTrue,
      );
    });

    test('动词碎片不得被判成人名笔误（2026-10-02 真实误报回归）', () {
      // 真机事故：都市题材正文「陈越把…」「陈越听…」「陈越不是…」被滑窗切成
      // 越把/越听/越不（前一字「陈」是姓氏 → 命中前缀线索），「笑了出来」
      // 「看了看」切出笑了/看了（后一字在后缀线索表里）。这些碎片两两编辑
      // 距离＝1，把一本正文毫无问题的书报成「人名不一致 6 处」。
      //
      // 修复：候选名以虚词/动作动词收尾的一律视为碎片，不当人名比对。
      final ConsistencyReport r = NovelConsistencyChecker.check(<Chapter>[
        makeChapter(0, '陈越把便利店的门锁上。陈越听了一会儿。'
            '陈越不是不想继续。她笑了出来。他看了看天。'),
        makeChapter(1, '陈越把货搬到里屋。陈越听完了整段。'
            '陈越不再犹豫。她笑了。他又看了看表。'),
        makeChapter(2, '陈越把账本合上。陈越听完没有说话。'
            '陈越不在意这些。她笑了起来。他看了看窗外。'),
        makeChapter(3, '陈越把门推开。陈越听着雨声。'
            '陈越不是第一次来。她笑了一声。他看了看手机。'),
      ]);
      expect(r.nameIssues, isEmpty,
          reason: '动词碎片被误判成人名笔误：'
              '${r.nameIssues.map((i) => '${i.nameA}/${i.nameB}').toList()}'
              '——正文本身毫无问题，检查器不该造谣');
    });

    test('世界观冲突检测', () {
      final ConsistencyReport r = NovelConsistencyChecker.check(<Chapter>[
        makeChapter(0, '这片大陆灵气充沛，修炼者无处不在。'),
        makeChapter(1, '主角开始修炼灵气。灵气涌入体内。'),
        makeChapter(5, '这片大陆根本没有灵气，所有人都是普通人。'),
      ]);
      // 第 0/1 章说"灵气"存在，第 5 章说"没有灵气" → 冲突
      expect(r.worldIssues.isNotEmpty, isTrue);
    });

    test('死者复活矛盾检测', () {
      final ConsistencyReport r = NovelConsistencyChecker.check(<Chapter>[
        makeChapter(0, '张三在战斗中牺牲，倒在地上。'),
        makeChapter(1, '李四走过去查看。'),
        makeChapter(2, '张三站起来说话了。'),
      ]);
      expect(r.plotIssues.isNotEmpty, isTrue);
      expect(r.plotIssues.first.reason, contains('张三'));
    });

    test('有回忆标记不报复活矛盾', () {
      final ConsistencyReport r = NovelConsistencyChecker.check(<Chapter>[
        makeChapter(0, '王五在筑基时陨落。'),
        makeChapter(1, '回忆起过去的时光，王五又出现了。'),
      ]);
      // 第 1 章含"回忆"标记 → 闪回合法
      expect(r.plotIssues, isEmpty);
    });

    test('summary 文字包含数字', () {
      final ConsistencyReport r = NovelConsistencyChecker.check(<Chapter>[
        makeChapter(0, '陈大和陈大都在。'),
        makeChapter(1, '赵二。'),
      ]);
      expect(r.summary, isNotEmpty);
    });
  });

  // ================================================================
  // 主角连续性（2026-09-30 新增）
  //
  // 实测事故：真机 33 章长篇里主角「陆沉」自第 30 章起连续 4 章完全消失
  // （陆沉 0 次），POV 被换成他人；另有 3 段中段缺席。书级体检此前
  // 完全没有这个维度——「人名」查的只是「两名字差一字」的笔误。
  // ================================================================
  group('NovelConsistencyChecker.protagonistContinuity', () {
    /// 构造一本「前 3 章有主角、后 2 章彻底没主角」的书。
    List<Chapter> heroThenVanish() => <Chapter>[
          for (int i = 0; i < 3; i++)
            makeChapter(i, '陆沉走进院子。陆沉抬头看了看天。陆沉握紧了拳。'),
          for (int i = 3; i < 5; i++)
            makeChapter(i, '齐的刀已经收回。齐没有停。齐转身走开。'),
        ];

    test('主角自第 4 章起连续消失 2 章 → 告警（真机事故形态）', () {
      final List<ProtagonistIssue> issues = NovelConsistencyChecker
          .protagonistContinuity(heroThenVanish(), protagonist: '陆沉');
      expect(issues, isNotEmpty);
      expect(issues.first.protagonist, '陆沉');
      expect(issues.first.absentChapters, 2);
    });

    test('章号用 1 基口径（不得报「第 0 章」）', () {
      final List<ProtagonistIssue> issues = NovelConsistencyChecker
          .protagonistContinuity(heroThenVanish(), protagonist: '陆沉');
      // 缺席段是 order 3、4（0 基）→ 对外应报第 4~5 章
      expect(issues.first.absentFrom, 4);
      expect(issues.first.absentTo, 5);
      expect(issues.first.reason, isNot(contains('第 0 章')));
    });

    test('未传主角名时不报（宁可不报也不误报）', () {
      expect(
        NovelConsistencyChecker.protagonistContinuity(heroThenVanish()),
        isEmpty,
      );
    });

    test('主角贯穿全书时不报', () {
      final List<Chapter> all = <Chapter>[
        for (int i = 0; i < 5; i++)
          makeChapter(i, '陆沉走进院子。陆沉抬头看了看天。陆沉握紧了拳。'),
      ];
      expect(
        NovelConsistencyChecker.protagonistContinuity(all, protagonist: '陆沉'),
        isEmpty,
      );
    });

    test('单章缺席（未达连续 2 章）不报', () {
      final List<Chapter> chapters = <Chapter>[
        makeChapter(0, '陆沉走进院子。陆沉抬头。陆沉握拳。'),
        makeChapter(1, '陆沉走进院子。陆沉抬头。陆沉握拳。'),
        makeChapter(2, '齐的刀收回。齐没有停。齐转身。'),
        makeChapter(3, '陆沉走进院子。陆沉抬头。陆沉握拳。'),
        makeChapter(4, '陆沉走进院子。陆沉抬头。陆沉握拳。'),
      ];
      expect(
        NovelConsistencyChecker.protagonistContinuity(chapters,
            protagonist: '陆沉'),
        isEmpty,
        reason: '只缺席 1 章属正常（他人视角章），不该报',
      );
    });

    test('主角在每章只出现 1 次也算出场（不依赖章内频次）', () {
      // 真机很多章里主角只被提及一次；若按「章内 ≥2 次」判定会整片漏报，
      // 那个口径曾让检测恒返回 0 条。
      final List<Chapter> chapters = <Chapter>[
        for (int i = 0; i < 4; i++)
          makeChapter(i, '陆沉走进院子，天色暗了下来。'),
        for (int i = 4; i < 6; i++)
          makeChapter(i, '齐的刀收回。齐没有停。齐转身走开。'),
      ];
      final List<ProtagonistIssue> issues = NovelConsistencyChecker
          .protagonistContinuity(chapters, protagonist: '陆沉', minChapterHits: 1);
      expect(issues, isNotEmpty);
    });

    test('check() 传入主角名时填充 protagonistIssues', () {
      final ConsistencyReport r = NovelConsistencyChecker.check(
        heroThenVanish(),
        protagonist: '陆沉',
      );
      expect(r.protagonistIssues, isNotEmpty);
      expect(r.totalIssues, greaterThanOrEqualTo(r.protagonistIssues.length));
      // 摘要必须把主角连续性单独点出，不能被人名项淹没
      expect(r.summary, contains('主角连续性'));
    });

    test('短书不报（样本不足）', () {
      expect(
        NovelConsistencyChecker.protagonistContinuity(<Chapter>[
          makeChapter(0, '陆沉走进来。陆沉停下。'),
        ], protagonist: '陆沉'),
        isEmpty,
      );
    });
  });
}

Chapter makeChapter(int order, String content) => Chapter(
      id: 'c$order',
      novelId: 'n1',
      title: '第$order章',
      order: order,
      content: content,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
