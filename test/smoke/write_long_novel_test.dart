// 一万字（五章连写）端到端写作验证（零网络、零 API 费）。
//
// 驱动方式与原因同 test/smoke/write_demo_novel_test.dart：链路依赖
// package:flutter -> dart:ui，只能 `flutter test` 跑，不能 `dart run`。
//
// 与三章冒烟的分工：冒烟验「能成书」，本测试验 **1 万字量级的稳定性**——
//   ① 五章全部成章（每章 ≥1200 汉字）且全书 ≥9500 汉字（2000×5 目标的下限）；
//   ② 双质检逐章跑通并达线（阈值与 writing_ability_test.dart / 三章冒烟同源：
//      文笔 ≥75、番茄闸门 ≥80，实测留有余量）；
//   ③ 产物落盘 verify-logs/（gitignore）。
//
// 本测试**会**被 CI 收到：它位于 test/ 下，而 CI 的 `flutter test --coverage`
// 会递归收 test/ 全部 *_test.dart（约 1 分钟、零网络零 API 费），
// 即 CI 自带一道「1 万字量级写作能力」门禁。
// 也可本地单跑：flutter test test/smoke/write_long_novel_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/write_long_novel.dart';

void main() {
  test('模板引擎五章连写 ≈1 万字 + 双质检端到端', () async {
    final LongWriteResult r = await runLongNovel();

    expect(r.chapters.length, 5, reason: '应产出五章');
    for (int i = 0; i < r.chapters.length; i++) {
      expect(r.chapters[i].trim(), isNotEmpty,
          reason: '第 ${i + 1} 章正文为空——模板引擎没跑通');
      expect(hanCount(r.chapters[i]), greaterThanOrEqualTo(1200),
          reason: '第 ${i + 1} 章仅 ${hanCount(r.chapters[i])} 字，未达成章线');
    }
    // 全书 1 万字线：2000×5 目标下限留 5% 余量（模板引擎实际每章约 2030~2050）。
    expect(r.totalHanWords, greaterThanOrEqualTo(9500),
        reason: '全书仅 ${r.totalHanWords} 汉字，未达 1 万字量级');

    // 双质检都要出结论。
    expect(r.qaReport, contains('文笔'));
    expect(r.qaReport, contains('番茄闸门'));
    expect(r.qaReport, contains('全书总字数'));

    // 质量分数逐章达线（与三章冒烟同源阈值）。
    final List<double> prose = _allMatches(r.qaReport, r'文笔\s*([\d.]+)/100')
        .map(double.parse)
        .toList();
    final List<double> gate = _allMatches(r.qaReport, r'番茄闸门\s*([\d.]+)\s*分')
        .map(double.parse)
        .toList();
    expect(prose.length, 5, reason: '应逐章解析出 5 个文笔分，实际 $prose');
    expect(gate.length, 5, reason: '应逐章解析出 5 个闸门分，实际 $gate');
    for (int i = 0; i < 5; i++) {
      expect(prose[i], greaterThanOrEqualTo(75),
          reason: '第 ${i + 1} 章文笔 ${prose[i]} 低于能力线 75');
      expect(gate[i], greaterThanOrEqualTo(80),
          reason: '第 ${i + 1} 章番茄闸门 ${gate[i]} 未达 80 分线');
    }
    expect(RegExp(r'（达线）').allMatches(r.qaReport).length, 5,
        reason: '应有 5 章判定为「达线」，报告：\n${r.qaReport}');
    expect(r.qaReport, isNot(contains('（未达线）')),
        reason: '存在未达线章节——1 万字量级下写作能力跌出下限');

    // 产物落盘（verify-logs 已 gitignore）。
    for (final String name
        in <String>['long_novel_10k.txt', 'long_novel_10k_qa.txt']) {
      final File f = File('verify-logs${Platform.pathSeparator}$name');
      expect(f.existsSync(), isTrue, reason: '产物缺失：${f.path}');
      expect(f.lengthSync(), greaterThan(0), reason: '产物为空：${f.path}');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// 取正则在 [src] 中的全部捕获组 1。
List<String> _allMatches(String src, String pattern) => RegExp(pattern)
    .allMatches(src)
    .map((Match m) => m.group(1)!)
    .toList();
