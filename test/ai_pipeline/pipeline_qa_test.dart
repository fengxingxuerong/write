import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/core/constants/app_constants.dart';

void main() {
  group('PipelineQa.aiEchoPct', () {
    test('AI 味密集文本密度高', () {
      const String text = '他仿佛看到了希望，嘴角勾起一抹笑意，眼底闪过一道光，似乎一切都有了转机。';
      final double pct = PipelineQa.aiEchoPct(text);
      expect(pct, greaterThan(1.0));
    });

    test('干净文本密度极低', () {
      const String text = '青苔顺着砖缝爬了半指长，边缘泛着干枯的白。他攥紧令牌，指节发白。';
      final double pct = PipelineQa.aiEchoPct(text);
      expect(pct, lessThan(1.0));
    });

    test('空文本返回 0', () {
      expect(PipelineQa.aiEchoPct(''), 0.0);
    });
  });

  group('PipelineQa.adjacentRepetition', () {
    test('完全重复段落相似度高', () {
      const String text = '他走过长街，风裹着雨。\n\n他走过长街，风裹着雨。\n\n他走过长街，风裹着雨。';
      expect(PipelineQa.adjacentRepetition(text), greaterThan(0.5));
    });

    test('不同段落相似度低', () {
      const String text = '他走过长街，风裹着雨。\n\n她推开窗，看见远处的山。\n\n天色渐暗，灯火次第亮起。';
      expect(PipelineQa.adjacentRepetition(text), lessThan(0.3));
    });

    test('少于两段返回 0', () {
      expect(PipelineQa.adjacentRepetition('只有一段内容。'), 0.0);
    });

    test('段尾无标点时末尾缓冲仍参与相似度', () {
      expect(
        PipelineQa.adjacentRepetition(
            '他走过长街风裹着雨吹落檐角灯笼\n\n他走过长街风裹着雨吹落檐角灯笼'),
        greaterThan(0.5),
      );
      // 末尾只剩单字（缓冲 <2 字）也应安全清空，不参与成词。
      expect(
        PipelineQa.adjacentRepetition(
            '他走过长街风裹着雨吹落檐角灯笼\n\n他走过长街风裹着雨吹落檐角灯笼。甲'),
        greaterThan(0.5),
      );
      // 分隔符紧跟 0~1 个汉字（缓冲 <2 字）→ 走清空分支而非入集。
      expect(
        PipelineQa.adjacentRepetition(
            '风，停在了长街的尽头，灯还亮着。\n\n风，停在了长街的尽头，灯还亮着。'),
        greaterThan(0.5),
      );
    });
  });

  group('PipelineQa.rhythmScore', () {
    test('长短失衡段落占比高', () {
      final StringBuffer buf = StringBuffer();
      buf.writeln('极短。');
      for (int i = 0; i < 20; i++) {
        buf.writeln('这是一个足够长的段落，用来测试节奏检测的逻辑是否正常工作，内容要超过三十个汉字。');
      }
      final double score = PipelineQa.rhythmScore(buf.toString());
      expect(score, greaterThan(0.5));
    });
  });

  group('PipelineQa.worldConflicts', () {
    test('前后肯定/否定相反检测为冲突', () {
      const PipelineChapter ch1 = PipelineChapter(
        idx: 1,
        title: '一',
        content: '宗门里人人都在说，他身怀灵气。',
        rawWords: 0,
        words: 0,
      );
      const PipelineChapter ch2 = PipelineChapter(
        idx: 2,
        title: '二',
        content: '检测发现此人身上毫无灵气。',
        rawWords: 0,
        words: 0,
      );
      final List<String> conflicts = PipelineQa.worldConflicts(
        <PipelineChapter>[ch1],
        ch2,
      );
      expect(conflicts, isNotEmpty);
      expect(conflicts.first, contains('灵气'));
    });

    test('表述一致不报冲突', () {
      const PipelineChapter ch1 = PipelineChapter(
        idx: 1,
        title: '一',
        content: '他身怀灵气，踏上仙途。',
        rawWords: 0,
        words: 0,
      );
      const PipelineChapter ch2 = PipelineChapter(
        idx: 2,
        title: '二',
        content: '灵气在他经脉中流转。',
        rawWords: 0,
        words: 0,
      );
      expect(PipelineQa.worldConflicts(<PipelineChapter>[ch1], ch2), isEmpty);
    });
  });

  // ---------------- 报告 / 深度统计 / 商业向告警 ----------------

  /// AI 腔样板文本：等长句 + 高「的」密度 + 叠词 + 句首连接词 +
  /// 比喻 + 单句成段 + 身体反应，一次把统计层指纹全踩满。
  String aiHeavyText() {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 6; i++) {
      b.writeln('然而他的瞳的孔的神色在灯下微微的变了。'
          '因此他的心的底的念头在这一刻轻轻的散了。'
          '于是他的肩的线的轮廓在风里缓缓的暗了。');
      b.writeln();
      b.writeln(i.isEven ? '他的眼底的光淡淡的浮起。' : '他的掌心发烫的厉害。');
      b.writeln();
      b.writeln('仿佛那张网一样。');
      b.writeln();
    }
    return b.toString();
  }

  /// 平淡长文（无爽点、无变强异动、无钩子信号、无开场变故信号）。
  String blandLongText({int paras = 90}) =>
      '他沿着长街走了一程，风从巷口吹过来，带着潮气。\n\n' * paras;

  PipelineChapter chapter(String content, {int idx = 1}) => PipelineChapter(
        idx: idx,
        title: '第$idx章',
        content: content,
        rawWords: 0,
        words: AppConstants.countWords(content),
      );

  group('PipelineQa.chapterReport', () {
    test('干净文本：字段齐全且判定不需润色', () {
      final Map<String, dynamic> r = PipelineQa.chapterReport(chapter(
        '他沿着长街走了一程，风从巷口吹过来，带着潮气。他数着砖缝，一共三百二十一道。',
        idx: 2,
      ));
      expect(r['idx'], 2);
      expect(r['words'], isA<int>());
      expect(r['hasHook'], isFalse);
      expect(r['aiEcho'], isA<String>());
      expect(r['repetition'], isA<String>());
      expect(r['rhythm'], isA<String>());
      expect(r['thrillPerK'], isA<String>());
      expect(r['surgePerK'], isA<String>());
      expect(r['sideReactionPerK'], isA<String>());
      // 落点判定（无爽点命中）→ none；字段必在，供 UI/报告展示。
      expect(r['release'], 'none');
      // 三件套收尾（干净文本无命中）→ 空串。
      expect(r['endingTriad'], '');

      expect(r['aiDeepLevel'], isA<int>());
      expect(r['needsPolish'], isFalse);
    });

    test('AI 腔长文：档位 ≥3 且判定需要润色', () {
      final Map<String, dynamic> r = PipelineQa.chapterReport(chapter(aiHeavyText()));
      expect(r['aiDeepLevel'] as int, greaterThanOrEqualTo(3));
      expect(r['needsPolish'], isTrue);
    });
  });

  group('PipelineQa.styleFingerprintMetrics', () {
    test('空文本三项全 0', () {
      expect(
        PipelineQa.styleFingerprintMetrics(''),
        <String, double>{
          'metaphorDensity': 0.0,
          'singleParaRate': 0.0,
          'bodyReactionDensity': 0.0,
        },
      );
    });

    test('AI 腔样板：比喻 / 单句成段 / 身体反应三项均超标', () {
      final Map<String, double> m = PipelineQa.styleFingerprintMetrics(aiHeavyText());
      expect(m['metaphorDensity']!,
          greaterThan(PipelineQa.styleFpLimits['metaphorDensity']!));
      expect(m['singleParaRate']!,
          greaterThan(PipelineQa.styleFpLimits['singleParaRate']!));
      expect(m['bodyReactionDensity']!,
          greaterThan(PipelineQa.styleFpLimits['bodyReactionDensity']!));
    });
  });

  group('PipelineQa.deepAiMetrics / deepAiIssues', () {
    test('AI 腔样板：连接词与句式指纹推高档位，告警逐项列出', () {
      final String text = aiHeavyText();
      final Map<String, dynamic> m = PipelineQa.deepAiMetrics(text);
      expect(m['connectorRate'] as double, greaterThan(0.15));
      expect(m['level'] as int, greaterThanOrEqualTo(3));

      final String issues = PipelineQa.deepAiIssues(text).join('｜');
      expect(issues, contains('句长过于均匀'));
      expect(issues, contains('「的」字密度偏高'));
      expect(issues, contains('叠词修饰偏多'));
      expect(issues, contains('句首连接词偏多'));
      expect(issues, contains('比喻密度偏高'));
      expect(issues, contains('单句成段过密'));
      expect(issues, contains('身体反应描写过密'));
    });

    test('干净短文：档位低且不产出深度告警', () {
      const String text = '他数着砖缝，一共三百二十一道。';
      expect(PipelineQa.deepAiMetrics(text)['level'] as int, lessThan(3));
      expect(PipelineQa.deepAiIssues(text), isEmpty);
    });
  });

  group('PipelineQa.chapterIssues', () {
    test('缺钩 + 开场迟缓 + 爽点过淡：三类告警同时出现', () {
      final List<String> issues =
          PipelineQa.chapterIssues(chapter(blandLongText()));
      expect(issues.any((String e) => e.contains('章末疑似缺少钩子')), isTrue);
      expect(
          issues.any((String e) => e.contains('开场 300 字未检测到变故')), isTrue);
      expect(issues.any((String e) => e.contains('爽点过淡')), isTrue);
    });

    test('含蓄变强流：有异动无直白爽点 → 只提示外显爽点偏少', () {
      final List<String> issues =
          PipelineQa.chapterIssues(chapter(aiHeavyText() * 4, idx: 2));
      expect(issues.any((String e) => e.contains('含蓄变强流')), isTrue);
      expect(issues.any((String e) => e.contains('爽点过淡')), isFalse);
      expect(issues.any((String e) => e.contains('AI 腔偏重')), isTrue);
    });
    test('爽点存在但侧面反响偏弱：提示补齐三视角震惊环', () {
      final String thrillWithoutReaction =
          '系统激活！恭喜宿主获得神级奖励！\n\n' * 120;
      final List<String> issues =
          PipelineQa.chapterIssues(chapter(thrillWithoutReaction, idx: 2));
      expect(issues.any((String e) => e.contains('侧面反响偏弱')), isTrue);
    });

    test('侧面反响充足时不报侧面反响偏弱', () {
      final String thrillWithReaction =
          '系统激活！周围众人倒吸一口凉气，失声惊呼：“这怎么可能？！”\n\n' * 120;
      final List<String> issues =
          PipelineQa.chapterIssues(chapter(thrillWithReaction, idx: 2));
      expect(issues.any((String e) => e.contains('侧面反响偏弱')), isFalse);
    });

    test('爽点前置泄洪：爽点全在前半段 → 落点告警', () {
      // 命中 2 处且都落在前半段；汉字 >1500 过落点判定的字数门。
      final String front =
          '顿悟。${'文字填充。' * 80}识破。${'文字填充。' * 320}';
      final List<String> issues =
          PipelineQa.chapterIssues(chapter(front, idx: 2));
      expect(issues.any((String e) => e.contains('爽点前置泄洪')), isTrue);
      expect(issues.any((String e) => e.contains('压抑过长')), isFalse);
    });

    test('压抑过长：首个爽点晚于全章 60% → 落点告警', () {
      final String late =
          '${'文字填充。' * 400}顿悟。${'文字填充。' * 100}识破。';
      final List<String> issues =
          PipelineQa.chapterIssues(chapter(late, idx: 2));
      expect(issues.any((String e) => e.contains('压抑过长')), isTrue);
      expect(issues.any((String e) => e.contains('爽点前置泄洪')), isFalse);
    });

    test('章末三件套收尾 → 三件套告警 + 无钩告警（降级生效）', () {
      const String filler = '他数着砖缝，一共三百二十一道。';
      final List<String> issues = PipelineQa.chapterIssues(
          chapter('${filler * 8}掌心发烫。', idx: 2));
      expect(issues.any((String e) => e.contains('章末三件套收尾')), isTrue);
      expect(issues.any((String e) => e.contains('章末疑似缺少钩子')), isTrue);
    });
  });

  group('PipelineQa.releaseProfile（爽点落点·压抑释放结构）', () {
    // 中性填充：不含任何 thrillWords，保证只测落点不测密度。
    const String filler = '文字填充。';

    test('空文本 / 无命中 → none', () {
      expect(PipelineQa.releaseProfile('').verdict, 'none');
      expect(PipelineQa.releaseProfile(filler * 200).verdict, 'none');
    });

    test('单点命中 → single（单点无结构，密度指标负责）', () {
      final ({String verdict, int hits, double first, double last}) p =
          PipelineQa.releaseProfile('${filler * 180}顿悟。${filler * 10}');
      expect(p.verdict, 'single');
      expect(p.hits, 1);
    });

    test('全部爽点在前半段 → front_loaded', () {
      final ({String verdict, int hits, double first, double last}) p =
          PipelineQa.releaseProfile(
              '顿悟。${filler * 60}识破。${filler * 150}');
      expect(p.verdict, 'front_loaded');
      expect(p.hits, 2);
      expect(p.last, lessThan(0.5));
    });

    test('首个爽点晚于 60% → late_start', () {
      final ({String verdict, int hits, double first, double last}) p =
          PipelineQa.releaseProfile(
              '${filler * 160}顿悟。${filler * 40}识破。');
      expect(p.verdict, 'late_start');
      expect(p.first, greaterThan(0.6));
    });

    test('爽点跨越后半段 → ok', () {
      final ({String verdict, int hits, double first, double last}) p =
          PipelineQa.releaseProfile(
              '${filler * 70}顿悟。${filler * 60}识破。${filler * 60}');
      expect(p.verdict, 'ok');
      expect(p.first, lessThanOrEqualTo(0.6));
      expect(p.last, greaterThanOrEqualTo(0.5));
    });

    test('评审证据串：异常档带 rhythm 限分，正常档带 ✅（与 Python 同文）', () {
      final String ok =
          '${filler * 70}顿悟。${filler * 60}识破。${filler * 60}';
      expect(PipelineQa.releaseEvFragment(ok), contains('结构正常'));
      final String late = '${filler * 160}顿悟。${filler * 40}识破。';
      expect(PipelineQa.releaseEvFragment(late),
          contains('rhythm 维度不应高于 60'));
      final String front = '顿悟。${filler * 60}识破。${filler * 150}';
      expect(PipelineQa.releaseEvFragment(front), contains('前置泄洪'));
      expect(PipelineQa.releaseEvFragment(filler * 200),
          contains('落点不适用'));
    });
  });

  group('PipelineQa.endingTriad（章末三件套收尾·规则20）', () {
    const String filler = '他数着砖缝，一共三百二十一道。';

    test('末句命中 → 返回词；窗口（末 60 字）外 → 空串', () {
      expect(PipelineQa.endingTriad('他摊开手一看，掌心发烫。'), '发烫');
      expect(PipelineQa.endingTriad('掌心发烫。$filler${filler * 10}'), '');
    });

    test('天亮了排除（时间过渡）、玉符亮了命中（发光物件）', () {
      expect(PipelineQa.endingTriad('他收剑回鞘，天亮了。'), '');
      expect(PipelineQa.endingTriad('他摊开手，玉符亮了。'), '亮了');
      expect(PipelineQa.endingTriad('他摊开手，玉符亮了起来。'), '亮了起来');
    });

    test('空文本 → 空串', () {
      expect(PipelineQa.endingTriad(''), '');
    });
  });

  group('PipelineQa.hasEndingHook 三件套降级（检测矛盾修正）', () {
    const String filler = '他数着砖缝，一共三百二十一道。';

    test('三件套是唯一尾钩信号 → 判无钩（旧逻辑误判有钩）', () {
      expect(PipelineQa.hasEndingHook('${filler * 8}掌心发烫。'), isFalse);
    });

    test('三件套 + 真实钩子词 → 仍有钩', () {
      expect(
        PipelineQa.hasEndingHook('${filler * 8}掌心发烫，脚步声骤然逼近。'),
        isTrue,
      );
    });

    test('三件套 + 问号悬念 → 仍有钩（悬念通道优先）', () {
      expect(
        PipelineQa.hasEndingHook('${filler * 8}掌心发烫，是谁？'),
        isTrue,
      );
    });

    test('常规钩子词不受降级影响', () {
      expect(
        PipelineQa.hasEndingHook('${filler * 8}就在这时，门外传来一阵脚步声。'),
        isTrue,
      );
      expect(PipelineQa.hasEndingHook(filler * 8), isFalse);
    });
  });

  group('PipelineQa.repetitionAndRhythm（合并入口）', () {
    test('与两个单指标入口逐值一致（共用同一份段落切分）', () {
      const String text = '他走进院子，看见屋檐下挂着两盏灯笼。\n\n'
          '他走进院子，看见屋檐下挂着两盏灯笼。\n\n'
          '雪落下来，压弯了枝头，远处有人喊了一声。';
      final ({double repetition, double rhythm}) rr =
          PipelineQa.repetitionAndRhythm(text);
      expect(rr.repetition, PipelineQa.adjacentRepetition(text));
      expect(rr.rhythm, PipelineQa.rhythmScore(text));
    });

    test('不足两段时重复率为 0，节奏仍按同一批段落算', () {
      const String one = '只有一段内容，长度超过十个字符以便进入统计口径。';
      final ({double repetition, double rhythm}) rr =
          PipelineQa.repetitionAndRhythm(one);
      expect(rr.repetition, 0.0);
      expect(rr.rhythm, PipelineQa.rhythmScore(one));
    });

    test('空文本两个指标都是 0', () {
      final ({double repetition, double rhythm}) rr =
          PipelineQa.repetitionAndRhythm('');
      expect(rr.repetition, 0.0);
      expect(rr.rhythm, 0.0);
    });
  });

  group('PipelineQa.payoffDroughtZones', () {
    // 与 Python `payoff_drought_zones` 同口径同阈值：只判 💥 连低（不看 ✨），
    // 抓「含蓄异动把外显爽点断供掩盖」——既有「双低」闸门对此结构性漏检
    // （真实成书 14 本里 ✨ 恒高 ~2.2/千字，双低几乎永不成立）。
    test('全书有外显爽点则无断供带', () {
      expect(PipelineQa.payoffDroughtZones(<double>[0.67, 0.79, 0.60]),
          isEmpty);
    });

    test('连续 2 章不算断供（正常节奏起伏，不误报）', () {
      expect(
          PipelineQa.payoffDroughtZones(
              <double>[0.2, 0.3, 0.9, 0.2, 0.25]),
          isEmpty);
    });

    test('连续 3 章判为断供带', () {
      final List<({int start, int end, int chapters})> z =
          PipelineQa.payoffDroughtZones(<double>[0.9, 0.2, 0.3, 0.4, 0.9]);
      expect(z.length, 1);
      expect(z.first.start, 1);
      expect(z.first.end, 3);
      expect(z.first.chapters, 3);
    });

    test('多段断供 + 末尾连低收口', () {
      final List<({int start, int end, int chapters})> z =
          PipelineQa.payoffDroughtZones(
              <double>[0.2, 0.2, 0.2, 1.2, 0.1, 0.1, 0.1, 0.1]);
      expect(z.length, 2);
      expect(z[0].chapters, 3);
      expect(z[1].start, 4);
      expect(z[1].chapters, 4);
    });

    test('阈值边界：等于 0.5 不算低', () {
      expect(PipelineQa.payoffDroughtZones(<double>[0.5, 0.5, 0.5]), isEmpty);
      expect(PipelineQa.payoffDroughtZones(<double>[0.49, 0.49, 0.49]).length,
          1);
    });

    test('minRun 可调 + 空/短输入安全', () {
      expect(PipelineQa.payoffDroughtZones(<double>[0.1, 0.1], minRun: 3),
          isEmpty);
      expect(PipelineQa.payoffDroughtZones(<double>[0.1, 0.1], minRun: 2).length,
          1);
      expect(PipelineQa.payoffDroughtZones(<double>[]), isEmpty);
      expect(PipelineQa.payoffDroughtZones(<double>[0.1]), isEmpty);
    });

    test('长跑断供形态可检出（真实成书 33 章 18 章连低）', () {
      final List<double> series = <double>[
        1.2,
        ...List<double>.filled(5, 0.2),
        ...List<double>.filled(5, 1.2),
        ...List<double>.filled(14, 0.2),
        ...List<double>.filled(3, 1.2),
        ...List<double>.filled(4, 0.2),
        1.2,
      ];
      final List<({int start, int end, int chapters})> z =
          PipelineQa.payoffDroughtZones(series);
      expect(z, isNotEmpty);
      final int inZone =
          z.fold<int>(0, (int s, ({int chapters, int end, int start}) v) =>
              s + v.chapters);
      expect(inZone / series.length, greaterThan(0.5));
    });
  });

  group('PipelineQa.payoffDroughtEvFragment', () {
    test('无断供带返回空串（不污染评审证据）', () {
      expect(PipelineQa.payoffDroughtEvFragment(<double>[1.0, 1.2, 0.9]),
          isEmpty);
    });

    test('含断供带时给出章数、区间与判档指引', () {
      final String ev =
          PipelineQa.payoffDroughtEvFragment(<double>[0.2, 0.2, 0.2, 0.2]);
      expect(ev, contains('外显爽点断供'));
      expect(ev, contains('连续 4 章'));
      expect(ev, contains('第1-4章(4章)'));
      // 评审可执行的判档指引（否则评审仍会把断供判成「节奏紧凑」）
      expect(ev, contains('不应高于 40 分'));
      // 点明根因：含蓄异动不能替代外显兑现
      expect(ev, contains('含蓄异动不能替代外显兑现'));
    });
  });

  // ================================================================
  // 跨章意象复读（2026-09-30 新增）
  //
  // 真机 12.6 万字长篇里「青苔」出现 138 次、横跨近 30 章，而**整句重复率
  // 仅 0.26%** —— 章内重复检测（intraRepeat / adjacentRepetition）完全
  // 看不见这类「同一意象换着句式反复用」。只有跨章视角才抓得到。
  // ================================================================
  group('PipelineQa.crossChapterImagery', () {
    /// 10 章全用「青苔」的构造样本。
    ///
    /// 阈值按**真机 12.6 万字 / 31 章**定标（minTotal=40、minPerThousand=1.0、
    /// spreadChapters=8），所以夹具必须给足量级才可能命中——这与真机口径一致。
    final List<String> mossyBook = <String>[
      for (int c = 0; c < 10; c++)
        '台阶边缘的青苔泛着湿意，青苔被雨泡开。\n\n'
            '墙根的青苔往砖缝里钻，青苔的气味发苦。\n\n'
            '他蹲下，指尖蹭过一层青苔，青苔碎成粉末。\n\n'
            '风把青苔吹干了，青苔边缘卷起。\n\n'
            '井栏边也有青苔，青苔下藏着一枚铁钉。'
            '${'石阶的青苔被踩出一个湿脚印。' * (c + 2)}',
    ];

    test('抓出跨多章反复出现的意象，并给出总频次与章分布', () {
      final hits = PipelineQa.crossChapterImagery(mossyBook);
      expect(hits, isNotEmpty, reason: '10 章全用青苔，应被判为复读');
      expect(hits.first.term, contains('青苔'));
      expect(hits.first.chapters, greaterThanOrEqualTo(10));
      expect(hits.first.total, greaterThan(100));
    });

    test('结果按总频次降序（复读最重的排最前）', () {
      final hits = PipelineQa.crossChapterImagery(mossyBook);
      expect(hits.length, greaterThan(1));
      for (int i = 1; i < hits.length; i++) {
        expect(hits[i - 1].total, greaterThanOrEqualTo(hits[i].total));
      }
    });

    test('虚词不会被当成意象（噪声防护）', () {
      final noisy = <String>[
        for (int c = 0; c < 8; c++) '这样一个地方，他就是这样走过。\n\n' * 20,
      ];
      for (final h in PipelineQa.crossChapterImagery(noisy)) {
        expect(h.term, isNot(contains('一个')));
        expect(h.term, isNot(contains('这样')));
        expect(h.term, isNot(contains('了他')));
      }
    });

    test('集中在单章的刷屏不算跨章复读（章分布按章去重）', () {
      // 一章内刷很多次但只出现在 1 章 → 章分布 = 1，不该判复读
      final singleChapter = <String>[
        for (int c = 0; c < 8; c++) '青苔。\n\n${'石砖与风灌进巷子。' * 200}',
      ];
      final terms = PipelineQa.crossChapterImagery(singleChapter)
          .map((h) => h.term)
          .toList();
      expect(terms, isNot(contains('青苔')));
    });

    test('章数不足 spreadChapters 时不判（样本太小无统计意义）', () {
      final few = List<String>.generate(
          2, (int _) => '青苔。\n\n${'石砖。' * 200}');
      expect(PipelineQa.crossChapterImagery(few), isEmpty);
    });

    test('意象多样的正常书不该被误报', () {
      // 「意象多样」= 每章用**不同**的物象，且章内不重复同一句式。
      const List<List<String>> banks = <List<String>>[
        <String>['炉火', '铁匠', '淬火的水'],
        <String>['芭蕉', '雨点', '檐沟'],
        <String>['卤水', '巷口', '陶罐'],
        <String>['铜钱', '算盘', '油灯'],
        <String>['更鼓', '梆子', '长街'],
        <String>['木屑', '铁砧', '风箱'],
        <String>['井绳', '水桶', '苔痕'],
        <String>['纸伞', '油纸', '青石'],
      ];
      final varied = <String>[
        for (int c = 0; c < banks.length; c++)
            '${banks[c][0]}映着光。\n\n'
            '${banks[c][1]}压出影子。\n\n'
            '${banks[c][2]}渗进水痕。',
      ];
      for (final h in PipelineQa.crossChapterImagery(varied)) {
        expect(h.chapters, lessThan(6),
            reason: '「${h.term}」x${h.total} 不该被判为跨章复读');
      }
    });

    test('场景共词（台阶/门口）跨章高频不算意象复读', () {
      // 「台阶」在真机 12.6 万字里高频出现，但它是场景共词不是意象——
      // 与「青苔」性质完全不同，故必须被 imageryCommonStop 拦掉。
      final commonWord = <String>[
        for (int c = 0; c < 10; c++)
            '他走上台阶。\n\n'
            '台阶下站着人。\n\n'
            '台阶很窄。\n\n'
            '扶着台阶站住。\n\n'
            '台阶尽头有光。'
            '${'台阶一级一级往上。' * 4}',
      ];
      final terms = PipelineQa.crossChapterImagery(commonWord)
          .map((h) => h.term)
          .toList();
      expect(terms, isNot(contains('台阶')));
    });

    test('人名可经 exclude 排除（真机「陆沉」298 次不是意象）', () {
      // 夹具按真机量级构造：青苔 30 次 → 提到 ~60 次（跨 10 章、~3.4/千字），
      // 人名陆沉保持高频。第一版夹具青苔只有 30 次，低于 minTotal=40 被正确挡掉，
      // 那是夹具密度不够，不是检测器漏报。
      final withHero = <String>[
        for (int c = 0; c < 10; c++)
            '青苔爬上墙根，青苔很滑，青苔发苦。\n\n'
            '青苔沿着裂缝长，青苔边缘发白，青苔下藏着一枚钉。\n\n'
            '陆沉走进巷子，陆沉抬头，陆沉停下。\n\n'
            '风从巷口灌进来，陆沉咳了一声，陆沉退了半步。\n\n'
            '灯灭了，陆沉站在原地，陆沉没动。'
            '${'陆沉的影子被拉长，陆沉抬手，陆沉咬牙。' * (c + 2)}',
      ];
      // 不排除：人名也在候选里（频次远高于青苔，会排在前面）
      final withName = PipelineQa.crossChapterImagery(withHero)
          .map((h) => h.term)
          .toList();
      expect(withName, contains('陆沉'),
          reason: '未排除时人名应出现在候选里（频次够高）');

      // 排除人名后：人名消失，真正的意象复读浮出水面
      final withoutName = PipelineQa.crossChapterImagery(withHero,
              exclude: <String>['陆沉'])
          .map((h) => h.term)
          .toList();
      expect(withoutName, isNot(contains('陆沉')),
          reason: 'exclude 应把人名剔出候选');
      expect(withoutName, contains('青苔'),
          reason: '排除人名后应抓出真正的意象复读');
    });

    test('空书不抛异常', () {
      expect(PipelineQa.crossChapterImagery(<String>[]), isEmpty);
      expect(PipelineQa.crossChapterImagery(<String>['', '', '', '']), isEmpty);
    });
  });

  // ================================================================
  // 跨章对白塌陷（2026-09-30 新增）
  //
  // 实测：真机 12.6 万字长篇 30 章里有 29 章对白占比 <15%（番茄要求
  // 25%~45%），其中第 5、9 章一个引号都没有。这不是个别章问题，是
  // 全书性对白不足——写手在用连续叙述推进，读者在移动端缺少代入抓手。
  // ================================================================
  group('PipelineQa.dialogueCollapseChapters', () {
    // 夹具须过 minWords=800 的门槛（与真机章 2500~4000 字同量级），
    // 否则会被「短章不判」的护栏挡掉——那不是缺陷，是刻意的降噪。
    // 30 段 ×22 汉字 = 660，不够；40 段才过线，故这里用 40。
    String narration() => List<String>.filled(
        40, '他沿着长廊慢慢走下来，青砖在脚下发出沉闷的声响。').join();

    String talky() => List<String>.filled(
        20, '“你到底想做什么？”他问。“我没想做什么。”她答。').join();

    test('抓出零对白章（真机第 5/9 章形态）', () {
      // 先确认夹具规模达标，避免误判成「没抓到」实为「被护栏挡掉」。
      // 门槛 minWords 判的是**汉字数**（AppConstants.countWords），
      // 故此处用汉字数自查，不能用 String.length（含标点会偏大）。
      final int nan = AppConstants.countWords(narration());
      expect(nan, greaterThan(800),
          reason: '夹具需过 minWords=800（汉字数），否则零对白章会被护栏挡掉');
      final List<({int idx, String content})> chapters =
          <({int idx, String content})>[
        for (int i = 1; i <= 4; i++)
          (idx: i, content: i.isEven ? narration() : talky()),
      ];
      final hits = PipelineQa.dialogueCollapseChapters(chapters);
      expect(hits.map((h) => h.idx), <int>[2, 4]);
    });

    test('对白充足的章不判塌陷', () {
      final List<({int idx, String content})> chapters = <({int idx, String content})>[
        for (int i = 1; i <= 3; i++) (idx: i, content: talky()),
      ];
      expect(PipelineQa.dialogueCollapseChapters(chapters), isEmpty);
    });

    test('短章不判（样本太小，对白占比天然低）', () {
      final List<({int idx, String content})> chapters = <({int idx, String content})>[
        (idx: 1, content: '他走。'),
        (idx: 2, content: '又走了。'),
        (idx: 3, content: '还在走。'),
      ];
      expect(PipelineQa.dialogueCollapseChapters(chapters), isEmpty,
          reason: '不足 minWords 的章不该判塌陷');
    });

    test('空书不抛异常', () {
      expect(PipelineQa.dialogueCollapseChapters(<({int idx, String content})>[]),
          isEmpty);
    });
  });

  group('PipelineQa.dialogueCollapseEvFragment', () {
    test('无塌陷时返回空串，不污染 qaEvidence', () {
      final String talky =
          List<String>.filled(20, '“你到底想做什么？”他问。“我没想做什么。”她答。').join();
      expect(
        PipelineQa.dialogueCollapseEvFragment(<({int idx, String content})>[
          (idx: 1, content: talky),
          (idx: 2, content: talky),
        ]),
        '',
      );
    });

    test('有塌陷时给出章号与占比，并带可执行的判档指引', () {
      // 同样要过 800 汉字门槛（30 段只有 660，不够）
      final String narration = List<String>.filled(
          40, '他沿着长廊慢慢走下来，青砖在脚下发出沉闷的声响。').join();
      final String ev = PipelineQa.dialogueCollapseEvFragment(
        <({int idx, String content})>[
          (idx: 1, content: narration),
          (idx: 2, content: narration),
          (idx: 3, content: narration),
        ],
      );
      expect(ev, contains('对白塌陷'));
      expect(ev, contains('第1章'));
      expect(ev, contains('3/3'));
      // 必须给评审明确的上限，否则证据只是摆设
      expect(ev, contains('不应高于 50 分'));
    });
  });

  group('PipelineQa.imageryEvFragment', () {
    test('无命中时返回空串，不污染 qaEvidence', () {
      expect(PipelineQa.imageryEvFragment(<String>['风。', '雨。']), '');
    });

    test('有命中时给出可执行的评审指引', () {
      final String ev = PipelineQa.imageryEvFragment(<String>[
        for (int c = 0; c < 10; c++)
          '台阶的青苔泛着湿意。\n\n'
              '墙根青苔往砖缝里钻。\n\n'
              '他指尖蹭过一层青苔。\n\n'
              '风把青苔吹干了。\n\n'
              '井栏边也有青苔。'
              '${'石阶的青苔被踩出湿脚印。' * (c + 2)}',
      ]);
      expect(ev, contains('跨章意象复读'));
      expect(ev, contains('氛围描写'));
      expect(ev, contains('青苔'));
      // 必须给评审一个明确的下调指令，否则证据只是摆设
      expect(ev, contains('应下调'));
    });
  });
}
