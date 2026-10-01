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
//   ① 模板引擎连写三章，每章正文非空；
//   ② NovelQualityChecker + FanqieGateChecker 两套质检都跑得出结果；
//   ③ 产物落到 verify-logs/（gitignore，不污染工作区）。
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
    }

    // 双质检都要出结论：报告里应同时出现文笔分与番茄闸门分
    expect(r.qaReport, contains('文笔'));
    expect(r.qaReport, contains('番茄闸门'));
    expect(r.qaReport, contains('全书均分'));

    // 产物落盘（verify-logs 已 gitignore）
    for (final String name in <String>['demo_novel.txt', 'demo_novel_qa.txt']) {
      final File f = File('verify-logs${Platform.pathSeparator}$name');
      expect(f.existsSync(), isTrue, reason: '产物缺失：${f.path}');
      expect(f.lengthSync(), greaterThan(0), reason: '产物为空：${f.path}');
    }
  });
}