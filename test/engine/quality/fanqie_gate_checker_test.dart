import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/quality/fanqie_gate_checker.dart';

/// 番茄过审闸门单元测试
///
/// 覆盖：首屏、对白/水段/句长/段长、整句重复、提示词泄漏、主角漂移与世界观一致性、
/// 红线否决 vs 情节性提示、fixPrompt 内容、静态工具函数。
/// 与 scripts/fanqie_review.py 的口径对齐——两边任一改动都应让对侧测试同步。

/// 拼一段「格式上应达线」的正文：对白足量、句子短、有冲突词、有人名动作。
String buildPassableChapter({int blocks = 26}) {
  final List<String> parts = <String>[
    '邬曜把除名通知撕成两半，纸屑砸在塑胶跑道上。',
  ];
  for (int i = 0; i < blocks; i++) {
    parts.add('“第 ${i + 1} 组， twenty 秒内回来。少一秒都不算。”魏铁山把秒表举到他眼前。');
    parts.add('“你凭什么定规矩？”邬曜喘着气，声音却稳。');
    parts.add('“凭你这条跟腱。”魏铁山把秒表收回口袋，转身，不再看他。');
  }
  return parts.join('\n\n');
}

void main() {
  const FanqieGateChecker plain = FanqieGateChecker();

  group('空文与字数', () {
    test('空正文直接 0 分并给出重写项', () {
      final FanqieGateReport r = plain.check('   ');
      expect(r.score, 0);
      expect(r.issues, hasLength(1));
      expect(r.issues.single.type, '结构');
      expect(r.pass, isFalse);
    });

    test('不足 1800 字会被标为结构问题', () {
      final FanqieGateReport r = plain.check('邬曜撕了通知。' * 40);
      expect(r.issues.map((FanqieGateIssue e) => e.message).join(),
          contains('番茄单章建议'));
    });
  });

  group('首屏', () {
    test('天气起手被记为修改项（不是重写项）', () {
      final String body = buildPassableChapter();
      final FanqieGateReport r = plain.check('雨下了整夜。\n\n$body');
      final FanqieGateIssue issue = r.issues.firstWhere(
          (FanqieGateIssue e) => e.message.contains('天气'),
          orElse: () => const FanqieGateIssue('无', '无', FanqieGateAction.note));
      expect(issue.message, contains('天气'));
      expect(issue.action, FanqieGateAction.revise);
    });

    test('首屏无对白会被判重写', () {
      final String body = buildPassableChapter().replaceFirst('“第 1 组', '第 1 组');
      final FanqieGateReport r =
          plain.check('他站在原地。' * 60 + '\n\n${body.substring(0, 200)}');
      expect(r.issues.any((FanqieGateIssue e) => e.message.contains('无对白')),
          isTrue);
    });

    test('首屏无冲突信号被记为修改项', () {
      final FanqieGateReport r = plain.check(
        '${'他看着远处，很久没有动。' * 30}\n\n${buildPassableChapter()}',
      );
      expect(
          r.issues.any((FanqieGateIssue e) => e.message.contains('冲突信号')),
          isTrue);
    });
  });

  group('完读率格式', () {
    test('对白占比过低时给出具体百分比与建议区间', () {
      final String noQuote =
          List<String>.generate(60, (i) => '邬曜跑完第 $i 组，腿上的旧伤又胀起来。').join('\n\n');
      final FanqieGateReport r = plain.check(noQuote);
      expect(r.dialogueRatio, lessThan(0.18));
      expect(r.issues.map((e) => e.message).join(), contains('对话占比'));
    });

    test('整句重复率超标会被抓（模板引擎的典型病症）', () {
      final String dup = List<String>.filled(
          40, '他抬起头，看见远方有一座塔。塔下站着一个人，那人也在看他。').join('\n\n');
      final FanqieGateReport r = plain.check(
          '邬曜被除名，队友抢走了他的鞋。“拿来。”他说。“你配吗？”对方笑着把鞋举高。\n\n'
          '$dup\n\n$dup');
      expect(r.issues.map((e) => e.message).join(), contains('整句重复率'));
    });

    test('骨架提示词漏进正文 = 直接判废', () {
      final FanqieGateReport r = plain.check(
          '本场景任务：主角当众受罚。\n\n${buildPassableChapter(blocks: 8)}');
      expect(
          r.issues.any((FanqieGateIssue e) => e.type == '泄漏'), isTrue);
    });
  });

  group('一致性（本项目历史上最大的质量事故）', () {
    test('大纲世界观专名一个都没命中 → 重写级', () {
      const FanqieGateChecker c = FanqieGateChecker(
          worldTerms: <String>['北辰体育馆', '雷霆青训', '全国青年联赛', '星髓']);
      final FanqieGateReport r = c.check(buildPassableChapter());
      expect(r.issues.any((e) => e.message.contains('没接住设定')), isTrue);
    });

    test('世界观专名命中 2 个以上即不再报一致性', () {
      const FanqieGateChecker c = FanqieGateChecker(
          worldTerms: <String>['北辰体育馆', '雷霆青训', '省队候补']);
      final String text =
          '北辰体育馆的灯还没关，雷霆青训的名单已经贴出来了。\n\n${buildPassableChapter()}';
      final FanqieGateReport r = c.check(text);
      expect(r.worldHit, greaterThanOrEqualTo(2));
      expect(r.issues.any((e) => e.message.contains('没接住设定')), isFalse);
    });

    test('大纲主角名缺席会被点名', () {
      const FanqieGateChecker c = FanqieGateChecker(protagonist: '贺兰铮');
      final FanqieGateReport r = c.check(buildPassableChapter());
      expect(
          r.issues.map((e) => e.message).join(), contains('大纲主角「贺兰铮」'));
    });
  });

  group('红线', () {
    test('情节性使用只提示、不否决（如"高利贷"作为欠债设定）', () {
      const FanqieGateChecker c = FanqieGateChecker(genre: '都市');
      final FanqieGateReport r = c.check(
          '他妹妹欠下高利贷，钱是被人抢走之后才开始滚的。“今晚之前，把钱送来。”那人说。\n\n${buildPassableChapter(blocks: 6)}');
      expect(r.redlines, isNotEmpty);
      expect(r.redlines.every((FanqieRedlineHit h) => h.veto == false), isTrue,
          reason: '无教唆语境时不应升级为否决');
    });

    test('出现教唆语境即一票否决，且 pass 必为 false', () {
      final FanqieGateReport r = plain.check(
          '他把教程摊在桌上：制作炸药的方法，第一步是配比。 "照着做就行。"他说。\n\n${buildPassableChapter(blocks: 6)}');
      expect(r.hasVeto, isTrue);
      expect(r.pass, isFalse);
      expect(r.score, lessThan(60));
    });

    test('露骨色情类词汇始终是否决级', () {
      final FanqieGateReport r = plain.check(
          '她脱了衣服，镜头拍下裸体。 "别动。"那人说。\n\n${buildPassableChapter(blocks: 6)}');
      expect(r.redlines.any((FanqieRedlineHit h) => h.veto), isTrue);
    });
  });

  group('结论与定点修指令', () {
    test('达线样本：pass=true 且 fixPrompt 为空', () {
      final FanqieGateReport r = plain.check(buildPassableChapter());
      expect(r.score, greaterThanOrEqualTo(80),
          reason: '合规格式的样章不应被判不达标：$r.issues');
      expect(r.pass, isTrue);
      expect(r.fixPrompt, isEmpty);
      expect(r.summary, contains('达线'));
    });

    test('不达标时 fixPrompt 列出问题类别与改写要求', () {
      const FanqieGateChecker c = FanqieGateChecker(
          worldTerms: <String>['星髓', '裂隙星域', '曲速']);
      final FanqieGateReport r =
          c.check('雨下了一整夜。${'他很愤怒，心中一凛，仿佛周围空气凝固。' * 60}');
      expect(r.pass, isFalse);
      expect(r.fixPrompt, contains('只针对这些点改写'));
      expect(r.fixPrompt, contains('对白'));
      expect(r.fixPrompt, contains('只输出改写后的正文'));
    });
  });

  group('补丁卫生与题材漂移（2026-09 事故回归）', () {
    test('元话语/操作说明残留被判重写，且成为阻断项', () {
      final FanqieGateReport r = plain.check(
          '${buildPassableChapter(blocks: 6)}\n\n我拿到的指令是补写钩子，不是扩写。');
      expect(
          r.issues.any((FanqieGateIssue e) =>
              e.type == '泄漏' && e.message.contains('元话语')),
          isTrue);
      expect(r.blockers, contains('提示词/元话语残留'));
      expect(r.pass, isFalse);
    });

    test('玄幻正文出现现代标志词 → 题材漂移（重写级 + 阻断项）', () {
      const FanqieGateChecker c = FanqieGateChecker(genre: '玄幻');
      final String body = '手机屏幕亮了。不是短信。是一个陌生号码的来电，路灯下有人影一闪。' * 20;
      final FanqieGateReport r = c.check(body);
      expect(r.issues.any((FanqieGateIssue e) => e.message.contains('题材漂移')),
          isTrue);
      expect(r.blockers, contains('题材漂移'));
      expect(r.pass, isFalse);
    });

    test('都市题材不做现代词漂移判定', () {
      expect(FanqieGateChecker.genreDrift('他掏出手机打车，路过便利店。', '都市').level,
          isEmpty);
      expect(FanqieGateChecker.genreDrift('', '玄幻').level, isEmpty);
    });

    test('章内大段重复会被抓（复制粘贴级事故）', () {
      final String block =
          '脚步声从巷子另一头传来，一下，又一下，像有人拿钝器敲着地面，震得墙皮簌簌往下掉。' * 4;
      final FanqieGateReport r = plain.check('$block\n\n中间正常推进的一句。\n\n$block');
      expect(r.issues.any((FanqieGateIssue e) => e.message.contains('章内大段重复')),
          isTrue);
      expect(r.blockers, contains('章内大段重复'));
    });

    test('patchReject：拦元话语 / 题材漂移 / 与正文尾部重复，放行正常补写', () {
      expect(FanqieGateChecker.patchReject('我拿到的指令是补写钩子。', genre: '玄幻'),
          isNotNull);
      expect(
          FanqieGateChecker.patchReject(
              '手机屏幕亮了。不是短信。是一个陌生号码的来电，他接了起来。',
              genre: '玄幻'),
          isNotNull);
      const String dupTail =
          '巷子深处传来一声极轻的哨响，三长一短，像有人在数着他的脚步，一步一步逼近。';
      expect(
          FanqieGateChecker.patchReject('$dupTail他没停。',
              baseText: '$dupTail风又灌进来。'),
          isNotNull);
      expect(
          FanqieGateChecker.patchReject(
              '季渊回头。血煞盟的人影在人群中一闪而逝——他还没看清那是什么。',
              genre: '玄幻'),
          isNull);
    });

    test('字数不足 1500 是阻断项（单章 671 字事故）', () {
      final FanqieGateReport r = plain.check('季渊把玉简推回原位。' * 40);
      expect(r.blockers.any((String b) => b.contains('单章仅')), isTrue);
      expect(r.pass, isFalse);
    });
  });

  group('静态工具', () {
    test('dialogueRatioOf 只统计引号内字数', () {
      expect(FanqieGateChecker.dialogueRatioOf('"走。"他说。走。再说一遍。'),
          greaterThan(0.0));
      expect(FanqieGateChecker.dialogueRatioOf('没有对白的纯叙述段落'), 0);
    });

    test('fillerRatioOf 只把 ≥40 字且无对白无推进词的段落算水段', () {
      // 造段时要避开 DRIVE_WORDS（门/窗/走/看/点/图 都会被当成推进词）
      const String longFiller =
          '远山很青，田里的水安静，晨光铺在草尖上，一切都显得遥远而缓慢，'
          '空气里发凉，草叶挂着露，一直挂到太阳升高。';
      expect(FanqieGateChecker.fillerStats(longFiller).counted, 1);
      expect(FanqieGateChecker.fillerRatioOf('$longFiller\n\n他说了声：“走。”'),
          greaterThan(0.0));
      // 短段不参统计：否则会把准则要求的「喘气段」当水段惩罚。
      expect(FanqieGateChecker.fillerRatioOf('天很蓝。云很低。他顿了顿。'), 0);
      expect(FanqieGateChecker.fillerRatioOf(''), 0);
    });

    test('专名允许局部命中：正文写「老韩」也算接住「体能师老韩」', () {
      const FanqieGateChecker c =
          FanqieGateChecker(worldTerms: <String>['体能师老韩']);
      final FanqieGateReport hit = c.check('老韩把秒表递过来。他伸手接住。' * 40);
      expect(hit.worldHit, 1);
      expect(hit.issues.any((e) => e.message.contains('没接住设定')), isFalse);

      final FanqieGateReport miss = c.check('他抬头看云，云不动。' * 40);
      expect(miss.worldHit, 0);
      expect(miss.issues.any((e) => e.message.contains('没接住设定')), isTrue);
    });

    test('worldTermsFrom 会剔除了类别名以外的占位词', () {
      final List<String> terms = FanqieGateChecker.worldTermsFrom(
          <String>['大陆名', '北辰体育馆与雷霆青训', '等级']);
      expect(terms, contains('北辰体育馆'));
      expect(terms, contains('雷霆青训'));
      expect(terms, isNot(contains('大陆名')));
      expect(terms, isNot(contains('等级')));
    });

    test('worldTermsFrom 不收 JSON 键名，也不收 2 字普通词', () {
      final List<String> terms = FanqieGateChecker.worldTermsFrom(
          <String>['galaxy: 猎户旋臂 · 裂隙星域，faction：三大势力（秩序）、伏『星髓』'],
      );
      expect(terms, contains('猎户旋臂'));
      expect(terms, contains('裂隙星域'));
      expect(terms, isNot(contains('galaxy')));
      expect(terms, isNot(contains('秩序')));
      expect(terms, contains('星髓'), reason: '引号内的 2 字专名要收到');
    });

    test('扣分随严重度递增：重写项比建议项扣得多', () {
      expect(FanqieGateAction.rewrite.penalty,
          greaterThan(FanqieGateAction.revise.penalty));
      expect(FanqieGateAction.revise.penalty,
          greaterThan(FanqieGateAction.note.penalty));
    });
  });
}
