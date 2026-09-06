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
