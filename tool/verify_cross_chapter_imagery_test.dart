
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';

/// 用真机 12.6 万字长篇验证跨章意象复读检测（一次性验证脚本）。
///
/// 背景：真机 33 章长篇里「青苔」出现 138 次、横跨近 30 章，而整句重复率仅
/// 0.26% —— 章内重复检测（intraRepeat / adjacentRepetition）完全看不见。
/// 本脚本喂真实成书，确认新检测器能抓出它，且不把「台阶」这类场景共词误报。
///
/// 运行：flutter test tool/verify_cross_chapter_imagery_test.dart
void main() {
  test('真机 12.6 万字长篇：跨章意象复读检测', () {
    final File f = File('data/generated/novel_10w_pipeline_sorted.txt');
    expect(f.existsSync(), isTrue, reason: '真机长篇产物缺失：${f.path}');

    final String raw = f.readAsStringSync();
    // 按「第 N 章」切章（产物形如「第 1 章  废材之辱」）
    // 注意：Dart 的 RegExp 不支持 (?m) 内联标志，须用 multiLine: true。
    final List<String> chapters = raw
        .split(RegExp(r'^第\s*\d+\s*章', multiLine: true))
        .skip(1)
        .where((String s) => s.trim().length > 200)
        .toList();
    // ignore: avoid_print
    print('真机章节数：${chapters.length}');
    expect(chapters.length, greaterThanOrEqualTo(20),
        reason: '真机长篇应至少 20 章');

    // 排除人名/专名：真机主角「陆沉」298 次、反派「陆天明」122 次，
    // 那是人物名出现频率高，不是意象复用——不排除会挤掉真正该报的意象。
    final hits = PipelineQa.crossChapterImagery(
      chapters,
      exclude: <String>['陆沉', '陆天明'],
    );
    // ignore: avoid_print
    print('命中条目：${hits.length}');
    for (final h in hits.take(12)) {
      // ignore: avoid_print
      print('  ${h.term}\t×${h.total}\t跨${h.chapters}章\t${h.perThousand}/千字');
    }

    // 真机基线：「青苔」138 次，是已知的最严重复读项
    expect(hits, isNotEmpty, reason: '真机长篇应抓出跨章复读意象');
    final mossy = hits.where((h) => h.term.contains('青苔')).toList();
    expect(mossy, isNotEmpty,
        reason: '「青苔」真机出现 138 次，必须被抓出');
    // ignore: avoid_print
    print('青苔：×${mossy.first.total} 跨${mossy.first.chapters}章 '
        '${mossy.first.perThousand}/千字');

    // 场景共词不该混进复读榜（否则这份证据不可信）
    final terms = hits.map((h) => h.term).toList();
    for (final String common in <String>['台阶', '门口', '身上', '眼前']) {
      expect(terms, isNot(contains(common)),
          reason: '「$common」是场景共词，不该被判为意象复读');
    }

    // ignore: avoid_print
    print(PipelineQa.imageryEvFragment(chapters));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
