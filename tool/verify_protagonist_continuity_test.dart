
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/quality/novel_consistency_checker.dart';
import 'package:novel_writer/models/chapter.dart';

/// 用真机 12.6 万字长篇验证主角连续性检测（一次性验证脚本）。
///
/// 实测事故：主角「陆沉」在第 1~29 章正常出场，自第 30 章起**完全消失**
/// （陆沉 0 次），POV 被换成另一个人物「齐」（34 次）。后 4 章脱离主线，
/// 成书等于换了主角。既有检查全都看不见（详见 protagonistContinuity 注释）。
///
/// 运行：flutter test tool/verify_protagonist_continuity_test.dart
void main() {
  test('真机 12.6 万字长篇：主角连续性检测', () {
    final File f = File('data/generated/novel_10w_pipeline_sorted.txt');
    expect(f.existsSync(), isTrue, reason: '真机长篇产物缺失：${f.path}');

    final String raw = f.readAsStringSync();
    // Dart 的 RegExp 不支持 (?m)，须用 multiLine: true
    final List<String> bodies = raw
        .split(RegExp(r'^第\s*\d+\s*章', multiLine: true))
        .skip(1)
        .where((String s) => s.trim().length > 200)
        .toList();
    // ignore: avoid_print
    print('真机章节数：${bodies.length}');
    expect(bodies.length, greaterThanOrEqualTo(20), reason: '应至少 20 章');

    // 事实核对：陆沉 只在前段出现，后段彻底消失（第 30~33 章 陆沉 = 0）
    int luCount = 0;
    final List<int> luPerChapter = <int>[];
    for (int i = 0; i < bodies.length; i++) {
      final int n = bodies[i].split('陆沉').length - 1;
      luCount += n;
      luPerChapter.add(n);
    }
    // ignore: avoid_print
    print('陆沉 全书 $luCount 次；末 4 章 = ${luPerChapter.sublist(luPerChapter.length - 4)}');
    expect(luPerChapter.sublist(luPerChapter.length - 4).every((int n) => n == 0),
        isTrue,
        reason: '前提核对：真机第 30~33 章主角陆沉应为 0 次');

    final List<Chapter> chapters = <Chapter>[
      for (int i = 0; i < bodies.length; i++)
        Chapter(
          id: 'c$i',
          novelId: 'n1',
          title: '第${i + 1}章',
          order: i,
          content: bodies[i],
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
    ];

    final Stopwatch sw = Stopwatch()..start();
    final ConsistencyReport r =
        NovelConsistencyChecker.check(chapters, protagonist: '陆沉');
    sw.stop();
    // ignore: avoid_print
    print('一致性检测耗时：${sw.elapsedMilliseconds} ms');
    // 性能基线（2026-09-30 优化前为 25128 ms，优化后约 1.4 s）：
    // 这里钉一个宽松上限防回归——不是精确基准，是「不该再卡到几十秒」的护栏。
    expect(sw.elapsedMilliseconds, lessThan(8000),
        reason: '33 章 / 12.6 万字的一致性检测不应超过 8 秒');

    for (final h in r.protagonistIssues) {
      // ignore: avoid_print
      print('命中：${h.reason}');
      // ignore: avoid_print
      print('      建议：${h.recommendation}');
    }
    // ignore: avoid_print
    print('主角连续性问题：${r.protagonistIssues.length} 处');
    // ignore: avoid_print
    print('摘要：${r.summary}');

    // 核心断言：必须抓出主角从第 30 章起消失
    expect(r.protagonistIssues, isNotEmpty,
        reason: '真机长篇主角陆沉自第 30 章起消失，必须被抓出');
    final ProtagonistIssue top = r.protagonistIssues.first;
    expect(top.protagonist, '陆沉');
    expect(top.absentChapters, greaterThanOrEqualTo(2));
    expect(top.totalChapters, bodies.length);
    // 摘要必须把主角连续性单独点出，不能被人名项淹没
    expect(r.summary, contains('主角连续性'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
