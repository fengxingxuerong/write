import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';

/// 用真机 12.6 万字长篇验证对白塌陷检测（一次性验证脚本）。
///
/// 实测事故：第 5、9、25 章**一个引号都没有**（0 对白），第 7 章仅 3 对——
/// 全是三千字左右的纯叙述独白。移动端读者靠对白推进，这类章完读率明显掉。
///
/// 运行：flutter test tool/verify_dialogue_collapse_test.dart
void main() {
  test('真机 12.6 万字长篇：对白塌陷检测', () {
    final File f = File('data/generated/novel_10w_pipeline_sorted.txt');
    expect(f.existsSync(), isTrue, reason: '真机长篇产物缺失：${f.path}');

    final String raw = f.readAsStringSync();
    // 章节标题与正文分属不同捕获组，需用 matchAll 逐个配对。
    // 注意真机产物**缺第 26 章**（物理顺序 24 → 25 → 27），所以必须靠
    // 「下一个章节标题」作边界，不能按 idx 连续性推算，否则会把两章并成一体
    // （并章会让对白占比被稀释，掩盖真正的零对白章）。
    final List<({int idx, String content})> chapters = <({int idx, String content})>[];
    for (final RegExpMatch m
        in RegExp(r'^第\s*(\d+)\s*章[^\n]*\n([\s\S]*?)(?=^第\s*\d+\s*章|\z)', multiLine: true)
            .allMatches(raw)) {
      final int idx = int.tryParse(m.group(1)!) ?? 0;
      final String body = m.group(2) ?? '';
      if (body.trim().length > 200) chapters.add((idx: idx, content: body));
    }
    // ignore: avoid_print
    print('真机章号：${chapters.map((c) => c.idx).join(',')}');
    // ignore: avoid_print
    print('真机章节数：${chapters.length}');
    expect(chapters.length, greaterThanOrEqualTo(20), reason: '应至少 20 章');

    // 逐章对白占比（用项目自身的 dialogueRatioOf，与生产同口径）
    for (final c in chapters) {
      final double r = PipelineQa.dialogueRatioOf(c.content);
      // ignore: avoid_print
      print('  第${c.idx}章 对白 ${(r * 100).toStringAsFixed(1)}%');
    }

    final hits = PipelineQa.dialogueCollapseChapters(chapters);
    // ignore: avoid_print
    print('塌陷章：${hits.map((h) => '第${h.idx}章(${(h.ratio * 100).toStringAsFixed(1)}%)').join('、')}');
    // ignore: avoid_print
    print(PipelineQa.dialogueCollapseEvFragment(chapters));

    // 核心断言：必须抓出真机的零对白章（第 5、9 章）
    expect(hits, isNotEmpty, reason: '真机长篇应抓出对白塌陷章');
    for (final int target in <int>[5, 9]) {
      expect(hits.any((h) => h.idx == target), isTrue,
          reason: '真机第 $target 章一个引号都没有，必须被抓出');
      final hit = hits.firstWhere((h) => h.idx == target);
      // 第 5/9 章引号数为 0（Python 独立核算 0.0%），这里只断言「远低于塌陷线」，
      // 不断言精确 0——切章边界差异会带来极小抖动。
      expect(hit.ratio, lessThan(0.02),
          reason: '第$target章对白应接近 0，实际 ${(hit.ratio * 100).toStringAsFixed(1)}%');
    }
    // 口径澄清（实测）：第 25 章虽有 36 段直角引号对白（11.7%），但仍低于 15% 塌陷线，
    // 故它**应该**出现在塌陷名单里——但占比不是 0，不能按零对白断言。
    final h25 = hits.firstWhere((h) => h.idx == 25);
    expect(h25.ratio, greaterThan(0.05),
        reason: '第25章有 36 段真实对白，占比不该是 0');

    // 更大的发现：真机全书对白严重不足，不是个别章塌陷。
    // 番茄要求 25%~45%，实测绝大多数章低于 15% —— 这是**系统性**问题。
    // ignore: avoid_print
    print('塌陷占比：${hits.length}/${chapters.length} 章');
    expect(hits.length * 2, greaterThan(chapters.length),
        reason: '真机长篇对白塌陷是系统性问题（远超半数章节）');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
