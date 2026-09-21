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
  });

}
