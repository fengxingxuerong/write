// 离线三章成书端到端冒烟（零网络、零 API 费）。
//
// 为什么不放在 tool/ 用 `dart run` 跑：那条链路传递依赖到 package:flutter，
// 而 `dart run` 用的是不带 dart:ui 的纯 Dart VM，必然报
// "Dart library 'dart:ui' is not available on this platform"。
// 早期 CI 正是这么写的，从加入那天起就没绿过（该提交长期未推送，所以没人发现）。
// `flutter test` 能加载 dart:ui，故改为测试驱动——见
// tool/write_demo_novel.dart 文件头的完整说明。
//
// 断言目标（对应 CI 步骤「Offline demo write smoke」的原始意图）：
//   ① 模板引擎连写三章，每章正文非空且成章（≥1200 字）；
//   ② NovelQualityChecker + FanqieGateChecker 两套质检都跑得出结果；
//   ③ **质量分数达线**——此前只断言报告里含「文笔」三个字，质检给 0 分也照样绿；
//   ④ 产物落到 verify-logs/（gitignore，不污染工作区）。
//
// 阈值与 writing_ability_test.dart 同源（见其文件头「阈值来源」）：实测闸门
// 96~100、文笔 90（封顶）、对白 42%~54%，留余量只拦能力塌陷。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/write_demo_novel.dart';

void main() {
  test('模板引擎连写三章 + 双质检端到端冒烟', () async {
    final DemoWriteResult r = await runDemo();

    expect(r.chapters.length, 3, reason: '应产出三章');
    for (int i = 0; i < r.chapters.length; i++) {
      expect(r.chapters[i].trim(), isNotEmpty,
          reason: '第 ${i + 1} 章正文为空——模板引擎没跑通');
      expect(r.chapters[i].length, greaterThan(200),
          reason: '第 ${i + 1} 章只有 ${r.chapters[i].length} 字符，明显不成章');
      expect(_hanCount(r.chapters[i]), greaterThanOrEqualTo(1200),
          reason: '第 ${i + 1} 章仅 ${_hanCount(r.chapters[i])} 字，未达成章线');
    }

    // 双质检都要出结论：报告里应同时出现文笔分与番茄闸门分
    expect(r.qaReport, contains('文笔'));
    expect(r.qaReport, contains('番茄闸门'));
    expect(r.qaReport, contains('全书均分'));

    // ---- 质量分数达线（此前缺失的核心断言）----
    // 报告形如「文笔 90/100」「番茄闸门 100.0 分（达线）」，这里把分抽出来钉下限，
    // 避免「报告有字就算过」的空转断言。
    final List<double> prose = _allMatches(r.qaReport, r'文笔\s*([\d.]+)/100')
        .map(double.parse)
        .toList();
    final List<double> gate = _allMatches(r.qaReport, r'番茄闸门\s*([\d.]+)\s*分')
        .map(double.parse)
        .toList();
    expect(prose.length, 3, reason: '应逐章解析出 3 个文笔分，实际 $prose');
    expect(gate.length, 3, reason: '应逐章解析出 3 个闸门分，实际 $gate');
    for (int i = 0; i < 3; i++) {
      expect(prose[i], greaterThanOrEqualTo(75),
          reason: '第 ${i + 1} 章文笔 ${prose[i]} 低于能力线 75');
      expect(gate[i], greaterThanOrEqualTo(80),
          reason: '第 ${i + 1} 章番茄闸门 ${gate[i]} 未达 80 分线');
    }
    // 逐章都必须是「达线」结论（闸门 pass 含无阻断项、无否决）。
    expect(RegExp(r'（达线）').allMatches(r.qaReport).length, 3,
        reason: '应有 3 章判定为「达线」，报告：\n${r.qaReport}');
    expect(r.qaReport, isNot(contains('（未达线）')),
        reason: '存在未达线章节——写作能力跌出下限');

    // 产物落盘（verify-logs 已 gitignore）
    for (final String name in <String>['demo_novel.txt', 'demo_novel_qa.txt']) {
      final File f = File('verify-logs${Platform.pathSeparator}$name');
      expect(f.existsSync(), isTrue, reason: '产物缺失：${f.path}');
      expect(f.lengthSync(), greaterThan(0), reason: '产物为空：${f.path}');
    }
  });
}

/// 报告里的汉字数（与质检器口径一致：只数 CJK）。
int _hanCount(String s) =>
    RegExp(r'[一-鿿]').allMatches(s).length;

/// 取正则在 [src] 中的全部捕获组 1。
List<String> _allMatches(String src, String pattern) => RegExp(pattern)
    .allMatches(src)
    .map((Match m) => m.group(1)!)
    .toList();