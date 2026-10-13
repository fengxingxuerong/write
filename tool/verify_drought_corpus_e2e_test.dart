import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';

/// **手动**全链路对账：真机成书 原文 → 密度 → 断供带 与固化基线逐书一致。
///
/// 为什么留在 tool/ 且不进 CI（2026-10-14 维持原判）：本用例依赖
/// `data/generated/*.jsonl`（gitignore 的本机真机产物），新克隆与 CI 上
/// 必然缺失——缺依赖时**直接失败**而非 SKIP 通过，这是本仓库的既定约定。
/// CI 上跑的是它的无语料子集：`tool/verify_payoff_drought_parity_test.dart`
/// （密度→断供带那半截，输入随 rules/payoff_drought_parity.json 固化）。
///
/// 与固化基线的分工：
/// - CI 版钉住 密度→断供带（输入是提交的 Python 侧密度）；
/// - 本用例额外钉住 原文→密度：Dart `thrillPerThousand` / `sideReactionPerThousand`
///   在真机正文上算出的密度必须与基线里的 Python 侧密度一致。
///
/// 密度只做**带容差**比对（±0.05/千字），zones 仍逐值精确比对：
/// Python `round(x, 2)` 有舍入、Dart 不舍入，且双端 countWords 定义本就
/// 有已知差异（见 docs/quality-rules-current.md 第三节）——密度层面的
/// 微差属预期；但微差**不允许大到翻转 zones**（那是精确比对）。
/// 容差被打穿时不要放宽容差——那说明双端 text→密度口径真分叉了，先查根因。
///
/// 刷新基线：`python tool/gen_parity_baselines.py --pinned --only drought`
/// 运行（本机、需语料）：flutter test tool/verify_drought_corpus_e2e_test.dart
void main() {
  test('真机成书 原文→密度→断供带 与固化基线一致（需本地语料）', () {
    final File f = File('rules/payoff_drought_parity.json');
    expect(f.existsSync(), isTrue,
        reason: '基线缺失：${f.path}。生成方式：'
            'python tool/gen_parity_baselines.py --pinned --only drought');
    final Directory gen = Directory('data/generated');
    expect(gen.existsSync(), isTrue,
        reason: '真机成书产物缺失：${gen.path}\n'
            '本用例是本机手动全链路对账（依赖 gitignore 的真机语料）；'
            'CI 侧请改跑无语料版 tool/verify_payoff_drought_parity_test.dart');

    const double densityTolerance = 0.05;
    final Map<String, dynamic> py =
        json.decode(f.readAsStringSync()) as Map<String, dynamic>;

    final List<String> drift = <String>[];
    for (final MapEntry<String, dynamic> e in py.entries) {
      final File j = File('${gen.path}${Platform.pathSeparator}'
          '${e.key}.jsonl');
      if (!j.existsSync()) {
        drift.add('MISSING ${e.key}（基线有此书、语料里已无——语料变了？'
            '重新生成基线）');
        continue;
      }
      final List<(int, String)> chs = <(int, String)>[];
      for (final String line in j.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        Map<String, dynamic> rec;
        try {
          rec = json.decode(line) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if (rec['type'] != 'chapter') continue;
        final Map<String, dynamic> d =
            (rec['data'] ?? rec) as Map<String, dynamic>;
        final String c = (d['content'] ?? '') as String;
        if (c.isEmpty) continue;
        chs.add(((d['idx'] as int?) ?? 0, c));
      }
      // 断点续传产物里 jsonl 章序可能非连续，必须按章号排序后再算连低——
      // 与 Python 侧载入进度时的 sorted(_dedup) 同口径，否则两端断供带不同。
      chs.sort(((int, String) a, (int, String) b) => a.$1.compareTo(b.$1));
      final List<double> t = <double>[
        for (final (int, String) c in chs) PipelineQa.thrillPerThousand(c.$2),
      ];
      final List<double> sd = <double>[
        for (final (int, String) c in chs)
          PipelineQa.sideReactionPerThousand(c.$2),
      ];
      final Map<String, dynamic> rec = e.value as Map<String, dynamic>;
      final List<double> pyT =
          (rec['thrill'] as List).map((dynamic x) => (x as num).toDouble()).toList();
      final List<double> pySd =
          (rec['side'] as List).map((dynamic x) => (x as num).toDouble()).toList();
      if (t.length != pyT.length) {
        drift.add('N ${e.key}: 语料章数 ${t.length} != 基线章数 ${pyT.length}'
            '（语料变了？重新生成基线）');
        continue;
      }
      for (int i = 0; i < t.length; i++) {
        if ((t[i] - pyT[i]).abs() > densityTolerance) {
          drift.add('DENSITY ${e.key} ch$i: dart=${t[i]} py=${pyT[i]}'
              '（💥 密度口径分叉）');
        }
        if ((sd[i] - pySd[i]).abs() > densityTolerance) {
          drift.add('DENSITY ${e.key} ch$i(side): dart=${sd[i]} py=${pySd[i]}'
              '（侧反密度口径分叉）');
        }
      }
      // zones 精确比对：密度的微差不允许翻转断供带判定。
      final List<({int start, int end, int chapters})> z =
          PipelineQa.payoffDroughtZones(t, sidePerK: sd);
      final List<List<int>> zonesDart = z
          .map((({int chapters, int end, int start}) x) =>
              <int>[x.start, x.end, x.chapters])
          .toList();
      if (json.encode(zonesDart) != json.encode(rec['zones'])) {
        drift.add('ZONES ${e.key}: py=${rec['zones']} dart=$zonesDart');
      }
    }
    // ignore: avoid_print
    print('books=${py.length} drift=${drift.length} tol=$densityTolerance');
    for (final String d in drift) {
      // ignore: avoid_print
      print(d);
    }
    expect(drift, isEmpty,
        reason: '真机全链路双端对账出现漂移：密度分叉先查 countWords/词表，'
            'zones 分叉先查 payoffDroughtZones 阈值口径');
  });
}
