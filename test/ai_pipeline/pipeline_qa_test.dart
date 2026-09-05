import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';

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
}
