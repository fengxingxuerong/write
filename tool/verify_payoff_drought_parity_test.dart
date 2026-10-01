import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';

/// **手动**双端对账：Dart 与 Python 的「外显爽点断供带」判定逐书一致。
///
/// 为什么在 tool/ 而不是 test/（2026-10-01 评审结论）：
/// 本检查依赖 `verify-logs/py_drought2.json` 与 `data/generated/*.jsonl`，
/// 两者都被 .gitignore —— 放在 test/ 时 CI 上必然走到「基线缺失 -> print SKIP
/// -> 用例通过」，是**假绿**：`flutter test` 全绿并不代表双端口径一致。
/// 故移出 CI 测试集，改为按需手动执行；缺失依赖时**直接失败**，不再静默通过。
///
/// 数据侧的漂移已由 CI 真正拦住：
/// - `python scripts/rules_codegen.py --check`（生成物 vs 数据源）
/// - `test/engine/quality/quality_rules_parity_test.dart`（Dart 常量 vs JSON）
/// - `scripts/test_quality_rules_parity.py`（Python 常量 vs JSON）
/// 本脚本负责剩下的一半：**算法**与真实成书上的逐书对账。
///
/// 基线生成：`python tool/gen_parity_baselines.py`（写入 verify-logs/），
/// `--check` 可重算比对，确认基线与当前代码/产物一致。
///
/// 运行：flutter test tool/verify_payoff_drought_parity_test.dart
void main() {
  test('Dart 与 Python 断供带判定逐书一致（需本地基线）', () {
    final File f = File('verify-logs/py_drought2.json');
    expect(f.existsSync(), isTrue,
        reason: '基线缺失：${f.path}。生成方式：python tool/gen_parity_baselines.py --only drought\n'
            '它按章逐章算 Python 侧 💥/侧反密度后调 payoff_drought_zones（阈值同 '
            'rules/quality_rules.json），依赖本机 gitignore 的 data/generated/*.jsonl。');
    final Directory gen = Directory('data/generated');
    expect(gen.existsSync(), isTrue, reason: '真机成书产物缺失：${gen.path}');

    final Map<String, dynamic> py =
        json.decode(f.readAsStringSync()) as Map<String, dynamic>;
    expect(py.length, greaterThan(10),
        reason: '基线样本过少（<10 本），对账没有意义');

    final Map<String, dynamic> dart = <String, dynamic>{};
    for (final File j in gen.listSync().whereType<File>()) {
      if (!j.path.endsWith('.jsonl')) continue;
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
      if (t.length < 3) continue;
      final List<({int start, int end, int chapters})> z =
          PipelineQa.payoffDroughtZones(t, sidePerK: sd);
      dart[j.uri.pathSegments.last.replaceAll('.jsonl', '')] = <String, dynamic>{
        'n': t.length,
        'zones': z
            .map((({int chapters, int end, int start}) e) =>
                <int>[e.start, e.end, e.chapters])
            .toList(),
        'in_zone': z.fold<int>(
            0, (int s, ({int chapters, int end, int start}) e) => s + e.chapters),
      };
    }

    final List<String> drift = <String>[];
    for (final String k in py.keys) {
      if (!dart.containsKey(k)) {
        drift.add('MISSING $k');
        continue;
      }
      final Map<String, dynamic> a = <String, dynamic>{
        'n': py[k]['n'],
        'zones': py[k]['zones'],
        'in_zone': py[k]['in_zone'],
      };
      if (json.encode(a) != json.encode(dart[k])) {
        drift.add('DRIFT $k: py=$a dart=${dart[k]}');
      }
    }
    // ignore: avoid_print
    print('compared=${py.length} drift=${drift.length}');
    for (final String d in drift) {
      // ignore: avoid_print
      print(d);
    }
    expect(drift, isEmpty, reason: 'Dart 与 Python 断供带判定出现漂移');
  });
}
