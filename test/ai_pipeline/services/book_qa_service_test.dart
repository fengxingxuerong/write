import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/book_qa_service.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';

/// BookQaService 全书体检单元测试。
///
/// 纯本地构造 Novel 输入（零 LLM / 零网络），与 test/ai_pipeline 下
/// composite_quality_gate_test 的组织方式一致：group + test 直接调用服务。
void main() {
  final DateTime t = DateTime(2026, 1, 1);
  const BookQaService service = BookQaService();

  Novel novel({
    List<Chapter> chapters = const <Chapter>[],
    List<Character> characters = const <Character>[],
    List<WorldSetting> worlds = const <WorldSetting>[],
    String genre = '玄幻',
  }) {
    return Novel(
      id: 'n1',
      title: '测试之书',
      genre: genre,
      tone: '热血',
      targetWordsPerChapter: 2000,
      createdAt: t,
      updatedAt: t,
      chapters: chapters,
      characters: characters,
      worldSettings: worlds,
    );
  }

  Chapter chapter(int order, String content, {String title = ''}) {
    return Chapter(
      id: 'c$order',
      novelId: 'n1',
      title: title.isEmpty ? '第$order章' : title,
      order: order,
      content: content,
      createdAt: t,
      updatedAt: t,
    );
  }

  Character character(String name, {String role = ''}) {
    return Character(
      id: 'id-$name',
      novelId: 'n1',
      name: name,
      role: role,
      traits: '',
      background: '',
      relationships: '',
    );
  }

  /// 达标长文（探针实测：score≈88.5、pass=true、无红线、无 extra 告警）。
  String passText() {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 30; i++) {
      b.writeln('第$i回合，陈默怒吼道：「这一局，我不会再退，输的只会是你！」');
      b.writeln('擂台四周的看客尽皆目瞪口呆，却谁也不敢上前。');
      b.writeln('丹田里的灵力忽然温热流转，仿佛一层暖流涌遍全身。');
      b.writeln('周扬在远处说道：「陈默，这一战之后，没人敢再小看你。」');
    }
    b.write('就在这时，台下忽然传来一阵急促的脚步——来的那个人，竟然是他。');
    return b.toString();
  }

  /// 短文本（无钩子、无爽点、分数低、不达标）。
  String hooklessText() => '他走在路上，风很大。';

  group('BookQaService.check', () {
    test('空书 → 空报告：平均分 0、无达线、allPass false', () {
      final BookQaReport r = service.check(novel());
      expect(r.rows, isEmpty);
      expect(r.avgScore, 0);
      expect(r.passCount, 0);
      expect(r.totalChapters, 0);
      expect(r.vetoCount, 0);
      expect(r.totalWords, 0);
      // 空书：无红线且 0/0 达线 → allPass 恒真（钉住现状语义）。
      expect(r.allPass, isTrue);
      expect(r.failing, isEmpty);
    });

    test('空章 → BookChapterQa.empty：不参与平均分、正文为空问题', () {
      final BookQaReport r = service.check(novel(
        chapters: <Chapter>[
          chapter(1, '   '),
          chapter(2, passText()),
        ],
      ));
      expect(r.totalChapters, 2);
      final BookChapterQa empty = r.rows[0];
      expect(empty.words, 0);
      expect(empty.pass, isFalse);
      expect(empty.novelIssues, contains('正文为空'));
      expect(empty.gateSummary, '正文为空');
      expect(empty.fixPrompt, '');
      expect(empty.statusLabel, '不达标');
      expect(empty.hasHook, isFalse);
      // 平均分只统计有文字的章。
      expect(r.avgScore, greaterThan(0));
    });

    test('章节乱序输入 → 按 order 升序返回', () {
      final BookQaReport r = service.check(novel(
        chapters: <Chapter>[
          chapter(3, hooklessText()),
          chapter(1, hooklessText()),
          chapter(2, hooklessText()),
        ],
      ));
      expect(
        r.rows.map((BookChapterQa x) => x.chapter.order),
        <int>[1, 2, 3],
      );
    });

    test('无角色 → 不传主角名、不报主角缺席', () {
      final BookQaReport r = service.check(novel(
        chapters: <Chapter>[chapter(1, hooklessText())],
      ));
      expect(
        r.rows[0].gateIssues.any((String s) => s.contains('大纲主角')),
        isFalse,
      );
    });

    test("主角检测：role == '主角' 优先（即使不在首位）", () {
      final BookQaReport r = service.check(novel(
        characters: <Character>[
          character('陈风'),
          character('陈默', role: '主角'),
        ],
        chapters: <Chapter>[chapter(1, hooklessText())],
      ));
      expect(
        r.rows[0].gateIssues.any((String s) => s.contains('大纲主角「陈默」')),
        isTrue,
      );
    });

    test('主角检测：无「主角」时退化为第一个角色', () {
      final BookQaReport r = service.check(novel(
        characters: <Character>[character('陈风'), character('陈河')],
        chapters: <Chapter>[chapter(1, hooklessText())],
      ));
      expect(
        r.rows[0].gateIssues.any((String s) => s.contains('大纲主角「陈风」')),
        isTrue,
      );
    });

    test('世界设定专名过滤：有效 title 传入闸门，空/超短被剔除', () {
      // 「 天玄大陆 」trim 后 ≥2 字 → 进入 worldTerms；空 title 与单字被过滤。
      final BookQaReport r = service.check(novel(
        worlds: <WorldSetting>[
          const WorldSetting(
            id: 'w1',
            novelId: 'n1',
            title: ' 天玄大陆 ',
            category: '地理',
            content: '一片古老的大陆。',
          ),
          const WorldSetting(
            id: 'w2',
            novelId: 'n1',
            title: '   ',
            category: '规则',
            content: '空标题。',
          ),
          const WorldSetting(
            id: 'w3',
            novelId: 'n1',
            title: '一',
            category: '规则',
            content: '单字标题。',
          ),
        ],
        chapters: <Chapter>[chapter(1, hooklessText())],
      ));
      expect(
        r.rows[0].gateIssues.any((String s) => s.contains('世界观专名 1 个')),
        isTrue,
      );
    });

    test('世界设定过滤全无效 → 不产生世界观专名问题', () {
      final BookQaReport r = service.check(novel(
        worlds: <WorldSetting>[
          const WorldSetting(
            id: 'w1',
            novelId: 'n1',
            title: '',
            category: '规则',
            content: 'x',
          ),
          const WorldSetting(
            id: 'w2',
            novelId: 'n1',
            title: '。',
            category: '规则',
            content: 'y',
          ),
        ],
        chapters: <Chapter>[chapter(1, hooklessText())],
      ));
      expect(
        r.rows[0].gateIssues.any((String s) => s.contains('世界观专名')),
        isFalse,
      );
    });

    test('章末无钩子 → extraIssues 含钩子告警', () {
      final BookQaReport r = service.check(novel(
        chapters: <Chapter>[chapter(1, hooklessText())],
      ));
      expect(
        r.rows[0].extraIssues.any((String s) => s.contains('钩子')),
        isTrue,
      );
    });

    test('长文低爽点 → extraIssues 含「爽点过淡」告警', () {
      final StringBuffer b = StringBuffer();
      for (int i = 0; i < 80; i++) {
        b.writeln('第$i天，山道蜿蜒向前，他独自走着，脚印在雪里一深一浅。');
      }
      final BookQaReport r = service.check(novel(
        chapters: <Chapter>[chapter(1, b.toString())],
      ));
      final BookChapterQa row = r.rows[0];
      expect(row.words, greaterThan(1500));
      expect(
        row.extraIssues.any((String s) => s.contains('爽点过淡')),
        isTrue,
      );
    });

    test('达标长文 → pass true、无 extra 告警、状态「达线」', () {
      final BookQaReport r = service.check(novel(
        chapters: <Chapter>[chapter(1, passText())],
      ));
      final BookChapterQa row = r.rows[0];
      expect(row.hasVeto, isFalse);
      expect(row.pass, isTrue);
      expect(row.statusLabel, '达线');
      expect(row.extraIssues, isEmpty);
      expect(row.hasHook, isTrue);
      expect(row.score, inInclusiveRange(0, 100));
      // 达线章允许存在「仅提示」级问题（探针实测：整句重复 1 条但分仍 88.5）。
      expect(row.novelIssues, isEmpty);
      expect(row.extraIssues, isEmpty);
      expect(r.avgScore, greaterThan(0));
      expect(r.allPass, isTrue);
      expect(r.failing, isEmpty);
    });

    test('红线章 → veto、分数封顶 60、不达线、状态「红线」', () {
      final BookQaReport r = service.check(novel(
        chapters: <Chapter>[
          chapter(1, '${passText()}\n本文教你制作炸药的方法，步骤如下。'),
        ],
      ));
      final BookChapterQa row = r.rows[0];
      expect(row.hasVeto, isTrue);
      expect(row.score, lessThanOrEqualTo(60));
      expect(row.pass, isFalse);
      expect(row.statusLabel, '红线');
      expect(row.gateIssues, isNotEmpty);
      expect(r.vetoCount, 1);
      expect(r.passCount, 0);
      expect(r.allPass, isFalse);
      expect(r.failing.length, 1);
    });

    test('低分红线章 → 分数低于 60、不走封顶钳制', () {
      final BookQaReport r = service.check(novel(
        chapters: <Chapter>[chapter(1, '教你制作炸药的方法，步骤如下。')],
      ));
      final BookChapterQa row = r.rows[0];
      expect(row.hasVeto, isTrue);
      expect(row.score, lessThan(60));
      expect(row.pass, isFalse);
    });

    test('AI 腔文本 → novelIssues 携带文笔卫生违规（enum 名）', () {
      final BookQaReport r = service.check(novel(
        chapters: <Chapter>[
          chapter(
            1,
            '他的嘴角勾起一抹弧度，眼底闪过一丝精光，空气仿佛凝固了。',
          ),
        ],
      ));
      expect(r.rows[0].novelIssues, isNotEmpty);
      expect(r.rows[0].novelIssues.every((String s) => s.startsWith('[')),
          isTrue);
    });
  });

  group('BookQaReport.exportText', () {
    test('导出 txt：含报告头、平均分、达线/不达标标记与定点修建议', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'bookqa_export_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final String path =
          '${dir.path}${Platform.pathSeparator}report.txt';

      final BookQaReport r = service.check(novel(
        chapters: <Chapter>[
          chapter(1, passText()), // 达线
          chapter(2, hooklessText()), // 不达标且 fixPrompt 非空
          chapter(3, '   '), // 空章
        ],
      ));
      await r.exportText(path);

      final File f = File(path);
      expect(await f.exists(), isTrue);
      final String content = await f.readAsString();
      expect(content, contains('《测试之书》全书体检报告'));
      expect(content, contains('全书平均分'));
      expect(content, contains('达线 1/3 章'));
      expect(content, contains('✅ 达线'));
      expect(content, contains('⚠️ 不达标'));
      expect(content, contains('[定点修建议]'));
      expect(content, contains('第 2 章'));
    });
  });
}