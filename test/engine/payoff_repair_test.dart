import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/models/character.dart';

/// 桌面端「外显爽点断供」闭环的纯逻辑回归（与 Python 同口径）。
///
/// 背景：桌面端此前是无状态单章引擎（拿不到前序章爽点密度），断供这一**跨章**
/// 形态无人可见；本轮用 `ContextBundle.payoffHistory` 把历史送进引擎，补上
/// `trailingDroughtLen` / `needsPayoffRepair` / `payoffRepairPrompt` /
/// `acceptPayoffRepair` 四件套。
void main() {
  Character charOf(String name) => Character(
        id: name,
        novelId: 'n1',
        name: name,
        role: '配角',
        traits: '',
        background: '',
        relationships: '',
      );

  ChapterPayoff p(double t, double s) =>
      ChapterPayoff(thrillPerK: t, sidePerK: s);

  group('ChapterPayoff', () {
    test('由正文现算两通道', () {
      final ChapterPayoff c = ChapterPayoff.of('满堂哗然，众人惊呼。' * 40);
      expect(c.sidePerK, greaterThan(0.0));
      expect(c.toString(), contains('侧反'));
    });

    test('序列化往返一致 + 坏数据不崩', () {
      final ChapterPayoff c = p(0.3, 0.8);
      final ChapterPayoff r = ChapterPayoff.fromJson(c.toJson());
      expect(r.thrillPerK, 0.3);
      expect(r.sidePerK, 0.8);
      final ChapterPayoff bad = ChapterPayoff.fromJson(<String, dynamic>{});
      expect(bad.thrillPerK, 0.0);
      expect(bad.sidePerK, 0.0);
    });
  });

  group('PipelineQa.trailingDroughtLen', () {
    test('末尾连续无兑现才计数', () {
      expect(PipelineQa.trailingDroughtLen(<ChapterPayoff>[]), 0);
      expect(PipelineQa.trailingDroughtLen(
          <ChapterPayoff>[p(0.1, 0.0), p(0.1, 0.0), p(0.1, 0.0)]), 3);
      expect(PipelineQa.trailingDroughtLen(
          <ChapterPayoff>[p(0.1, 0.0), p(0.1, 0.0), p(1.2, 0.8)]), 0);
    });

    test('侧面反响逃生：末章有在场者反应则不算断供', () {
      // 真机实测形态：不写套话的好稿 💥=0 但侧反达标
      expect(PipelineQa.trailingDroughtLen(
          <ChapterPayoff>[p(0.0, 0.0), p(0.0, 0.0), p(0.0, 0.79)]), 0);
    });
  });

  group('PipelineQa.needsPayoffRepair', () {
    test('单章双低仍触发（保留旧行为，零回归）', () {
      expect(PipelineQa.needsPayoffRepair(thrill: 0.2, surge: 0.5), isTrue);
    });

    test('断供通道抓高✨（旧口径漏修的形态）', () {
      expect(PipelineQa.needsPayoffRepair(thrill: 0.2, surge: 2.2), isFalse);
      expect(PipelineQa.needsPayoffRepair(thrill: 0.2, surge: 2.2, droughtLen: 3),
          isTrue);
    });

    test('无历史时行为与旧版一致', () {
      expect(PipelineQa.needsPayoffRepair(thrill: 0.2, surge: 2.2, droughtLen: 0),
          isFalse);
    });

    test('侧面反响达标直接跳过（不白烧 LLM 调用）', () {
      expect(
          PipelineQa.needsPayoffRepair(
              thrill: 0.0, surge: 2.4, droughtLen: 5, side: 0.79),
          isFalse);
    });

    test('健康章不修 + 过短章不修', () {
      expect(PipelineQa.needsPayoffRepair(thrill: 1.2, surge: 2.0, droughtLen: 9),
          isFalse);
      expect(
          PipelineQa.needsPayoffRepair(
              thrill: 0.1, surge: 0.1, minWordsOk: false),
          isFalse);
    });
  });

  group('PipelineQa.payoffRepairPrompt', () {
    test('断供语境按需出现，且始终保留两条底线', () {
      final String on = PipelineQa.payoffRepairPrompt('正文', droughtLen: 5);
      expect(on, contains('连续 5 章'));
      final String off = PipelineQa.payoffRepairPrompt('正文', droughtLen: 0);
      expect(off, isNot(contains('【背景】')));
      for (final String p in <String>[on, off]) {
        expect(p, contains('不要另起新情节'));
        expect(p, contains('禁止只写主角内心感受'));
        expect(p, contains('【原章正文】'));
      }
    });

    test('角色名册注入后姓名出现在提示词里', () {
      final String p = PipelineQa.payoffRepairPrompt(
        '正文',
        characters: <Character>[
          charOf('荆寒骨'),
        ],
      );
      expect(p, contains('荆寒骨'));
    });
  });

  group('PipelineQa.acceptPayoffRepair', () {
    final String orig = '他推开门。屋里空无一人。' * 60;
    final String withCliche = '他推开门。众人哑口无言，鸦雀无声。' * 60;
    final String surgeOnly = '他掌心发烫，丹田温热，气流涌动。' * 60;
    final String withSide = '满堂哗然，众人惊呼，他推开门。' * 60;

    test('真补上外显兑现则采纳', () {
      final (bool ok, String why) =
          PipelineQa.acceptPayoffRepair(orig, withCliche);
      expect(ok, isTrue, reason: why);
    });

    test('只涨✨（含蓄异动）不算修好', () {
      final (bool ok, String why) =
          PipelineQa.acceptPayoffRepair(orig, surgeOnly);
      expect(ok, isFalse);
      // ✨ 确实涨了，故「未提升」不成立；真正拦下它的是「未补上外显爽点」——
      // 💥 仍 0 且侧反 0，拿含蓄异动冒充外显兑现正是断供成因本身。
      expect(why, contains('未补上外显爽点'));
    });

    test('只涨侧反也算修好（真机好稿形态）', () {
      final (bool ok, String why) =
          PipelineQa.acceptPayoffRepair(orig, withSide);
      expect(ok, isTrue, reason: why);
    });

    test('字数越界拒绝', () {
      final (bool ok, String why) = PipelineQa.acceptPayoffRepair(orig, '打脸。' * 5);
      expect(ok, isFalse);
      expect(why, contains('字数越界'));
    });

    test('角色丢失拒绝', () {
      final (bool ok, String why) = PipelineQa.acceptPayoffRepair(
        orig,
        withCliche,
        characters: <Character>[
          charOf('薛启'),
        ],
      );
      expect(ok, isFalse);
      expect(why, contains('角色丢失'));
    });

    test('无变化拒绝', () {
      final (bool ok, _) =
          PipelineQa.acceptPayoffRepair(withCliche, withCliche);
      expect(ok, isFalse);
    });
  });
}