import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';

/// 双端对账：Dart 与 Python 的「外显爽点断供带」判定在**入库固化基线**上
/// 逐书一致（CI 跑，零语料依赖）。
///
/// 基线来源（2026-10-14 改）：`rules/payoff_drought_parity.json`（已入库）。
/// 每本书记录 Python 侧逐章输入（thrill/side 密度）与期望输出（zones/in_zone），
/// Dart 从**提交的输入**用本端实现重算断供带，再与提交的期望比对——
/// 因此不再需要 `data/generated/` 语料（那是 gitignore 的本机产物，
/// 此前正是它让这份对账在新克隆与 CI 上永远不跑）。
///
/// 真机成书全链路（原文 → 密度 → 断供带）的对账仍在
/// `tool/verify_drought_corpus_e2e_test.dart`（需本地语料，手动跑）；
/// 那半截覆盖的是 text→密度，本文件覆盖的是 密度→断供带。
///
/// Python 侧的机器校验见 `scripts/test_drought_parity.py`（CI 会跑）：
/// 它钉「基线 == 当前 Python 重算」（防基线过期后 Dart 与旧 JSON 假绿）+
/// 阈值单一数据源 + side 逃生通道语义，三者合起来才完整。
///
/// 刷新基线：`python tool/gen_parity_baselines.py --pinned --only drought`
/// 运行：flutter test tool/verify_payoff_drought_parity_test.dart
void main() {
  test('Dart 与 Python 断供带判定逐书一致（入库基线）', () {
    final File f = File('rules/payoff_drought_parity.json');
    expect(f.existsSync(), isTrue,
        reason: '基线缺失：${f.path}。生成方式（需本机 data/generated/ 真机产物）：\n'
            'python tool/gen_parity_baselines.py --pinned --only drought\n'
            '基线含 Python 侧逐章密度输入与期望断供带，勿手改。');

    final Map<String, dynamic> py =
        json.decode(f.readAsStringSync()) as Map<String, dynamic>;
    expect(py.length, greaterThan(10),
        reason: '基线样本过少（<10 本），断供带几乎恒空，对账不携带信息');

    final List<String> drift = <String>[];
    for (final MapEntry<String, dynamic> e in py.entries) {
      final Map<String, dynamic> rec = e.value as Map<String, dynamic>;
      final List<double> t =
          (rec['thrill'] as List).map((dynamic x) => (x as num).toDouble()).toList();
      final List<double> sd =
          (rec['side'] as List).map((dynamic x) => (x as num).toDouble()).toList();
      if (rec['n'] != t.length || t.length != sd.length) {
        drift.add('SHAPE ${e.key}: n=${rec['n']} thrill=${t.length} side=${sd.length}');
        continue;
      }
      final List<({int start, int end, int chapters})> z =
          PipelineQa.payoffDroughtZones(t, sidePerK: sd);
      final Map<String, dynamic> dart = <String, dynamic>{
        'n': t.length,
        'zones': z
            .map((({int chapters, int end, int start}) x) =>
                <int>[x.start, x.end, x.chapters])
            .toList(),
        'in_zone': z.fold<int>(
            0, (int s, ({int chapters, int end, int start}) x) => s + x.chapters),
      };
      final Map<String, dynamic> expected = <String, dynamic>{
        'n': rec['n'],
        'zones': rec['zones'],
        'in_zone': rec['in_zone'],
      };
      if (json.encode(expected) != json.encode(dart)) {
        drift.add('DRIFT ${e.key}: py=$expected dart=$dart');
      }
    }
    // ignore: avoid_print
    print('books=${py.length} drift=${drift.length}');
    for (final String d in drift) {
      // ignore: avoid_print
      print(d);
    }
    expect(drift, isEmpty,
        reason: 'Dart 与 Python 断供带判定出现漂移——若系有意改算法，请用 '
            'gen_parity_baselines.py --pinned --only drought 刷新基线，'
            '并同步 scripts/test_drought_parity.py 的断言');
  });
}

