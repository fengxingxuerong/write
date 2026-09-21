import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/features/editor/writing_stats_dialog.dart';

/// computeWritingStats 函数单元测试
///
/// 覆盖：字数统计、段落数、句子数、本次新增、平均句长。

void main() {
  group('computeWritingStats 基本统计', () {
    test('空文本返回全 0', () {
      final stats = computeWritingStats('');
      expect(stats.wordCount, 0);
      expect(stats.paragraphCount, 0);
      expect(stats.sentenceCount, 0);
      expect(stats.sessionAdded, 0);
      expect(stats.avgSentenceLength, 0);
    });

    test('纯句号和段落统计', () {
      const text = '今天天气很好。阳光明媚。';
      final stats = computeWritingStats(text);
      expect(stats.sentenceCount, 2);
      expect(stats.paragraphCount, 1);
    });

    test('多段落统计', () {
      const text = '第一段内容。\n\n第二段内容。\n\n第三段内容。';
      final stats = computeWritingStats(text);
      expect(stats.paragraphCount, 3);
      expect(stats.sentenceCount, 3);
    });

    test('按换行符也分隔段落', () {
      const text = '第一行。\n第二行。\n第三行。';
      final stats = computeWritingStats(text);
      expect(stats.paragraphCount, 3);
    });
  });

  group('computeWritingStats 句子识别', () {
    test('识别中文句号', () {
      const text = '今天天气很好。我们出去玩。';
      final stats = computeWritingStats(text);
      expect(stats.sentenceCount, 2);
    });

    test('识别感叹号', () {
      const text = '太美了！真的太棒了！';
      final stats = computeWritingStats(text);
      expect(stats.sentenceCount, 2);
    });

    test('识别问号', () {
      const text = '你是谁？你来做什么？';
      final stats = computeWritingStats(text);
      expect(stats.sentenceCount, 2);
    });

    test('识别省略号', () {
      const text = '她想了想…然后点了点头…';
      final stats = computeWritingStats(text);
      expect(stats.sentenceCount, 2);
    });

    test('混合标点统计', () {
      const text = '你好吗？我很好！谢谢。再见…';
      final stats = computeWritingStats(text);
      expect(stats.sentenceCount, 4);
    });
  });

  group('computeWritingStats 本次新增字数', () {
    test('无初始值时新增等于总字数', () {
      const text = '今天天气很好。';
      final stats = computeWritingStats(text, initialWords: 0);
      expect(stats.sessionAdded, stats.wordCount);
    });

    test('有初始值时新增为差值', () {
      const text = '今天天气很好。阳光明媚，微风不燥，适合出游。';
      final stats = computeWritingStats(text, initialWords: 10);
      expect(stats.sessionAdded, stats.wordCount - 10);
    });

    test('负值归零（删除了文字）', () {
      const text = '短文本。';
      final stats = computeWritingStats(text, initialWords: 100);
      expect(stats.sessionAdded, 0);
    });
  });

  group('computeWritingStats 平均句长', () {
    test('无句子时为 0', () {
      const text = '没有标点的文本';
      final stats = computeWritingStats(text);
      expect(stats.avgSentenceLength, 0);
    });

    test('平均句长保留一位小数', () {
      // 总字数 10，句子数 2，平均 5.0
      const text = '一二三四五。六七八九十。';
      final stats = computeWritingStats(text);
      expect(stats.avgSentenceLength, 5.0);
    });

    test('平均句长大于 0', () {
      const text = '短句测试。另一个。还有一个。';
      final stats = computeWritingStats(text);
      expect(stats.avgSentenceLength, greaterThan(0));
    });
  });


  group('WritingStats 不可变性', () {
    test('所有字段为 final', () {
      const stats = WritingStats(
        wordCount: 100,
        paragraphCount: 5,
        sentenceCount: 10,
        sessionAdded: 50,
        avgSentenceLength: 10.0,
      );
      expect(stats.wordCount, 100);
      expect(stats.paragraphCount, 5);
      expect(stats.sentenceCount, 10);
      expect(stats.sessionAdded, 50);
      expect(stats.avgSentenceLength, 10.0);
    });
  });


  group('showWritingStatsDialog 弹窗', () {
    const WritingStats stats = WritingStats(
      wordCount: 500,
      paragraphCount: 3,
      sentenceCount: 10,
      sessionAdded: 120,
      avgSentenceLength: 50.0,
    );

    Future<void> openDialog(
      WidgetTester tester, {
      WritingStats s = stats,
      required int targetWords,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => TextButton(
                onPressed: () => showWritingStatsDialog(
                  ctx,
                  stats: s,
                  targetWords: targetWords,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('未达标：显示目标进度与差值，关闭按钮退出弹窗', (tester) async {
      await openDialog(tester, targetWords: 2000);
      expect(find.text('📊 写作统计'), findsOneWidget);
      expect(find.text('字数目标：500 / 2000 字'), findsOneWidget);
      expect(find.text('还差 1500 字达标'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // 明细行
      expect(find.text('当前字数'), findsOneWidget);
      expect(find.text('500 字'), findsOneWidget);
      expect(find.text('+120 字'), findsOneWidget);
      expect(find.text('3 段'), findsOneWidget);
      expect(find.text('10 句'), findsOneWidget);
      expect(find.textContaining('字/句'), findsOneWidget);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('📊 写作统计'), findsNothing);
    });

    testWidgets('已达标：显示庆祝文案', (tester) async {
      const WritingStats done = WritingStats(
        wordCount: 2000,
        paragraphCount: 8,
        sentenceCount: 40,
        sessionAdded: 600,
        avgSentenceLength: 50.0,
      );
      await openDialog(tester, s: done, targetWords: 2000);
      expect(find.text('🎉 已达成本章字数目标！'), findsOneWidget);
      expect(find.text('字数目标：2000 / 2000 字'), findsOneWidget);
    });

    testWidgets('无目标（targetWords<=0）：只显纯字数，不出进度条与差值',
        (tester) async {
      await openDialog(tester, targetWords: 0);
      expect(find.text('字数：500 字'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('还差'), findsNothing,
          reason: '无目标时不应出现「还差 -N 字」这类错误文案');
      // 明细行仍完整
      expect(find.text('当前字数'), findsOneWidget);
    });
  });
}

