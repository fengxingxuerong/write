import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';

/// Dart 与 Python 双端「外显爽点断供带」判定一致性（防标准漂移）。
///
/// 基线由 `tool/_py_drift.py` 之类脚本从真实成书 jsonl 算出后写入
/// `verify-logs/py_drought2.json`；本测试用 Dart 同口径重算并逐书比对。
/// 基线缺失时跳过（保持 CI 不依赖本地 verify-logs 产物）。
void main() {
  test('Dart 与 Python 断供带判定逐书一致（无双端漂移）', () {
    final File f = File('verify-logs/py_drought2.json');
    if (!f.existsSync()) {
      // ignore: avoid_print
      print('SKIP: 基线 verify-logs/py_drought2.json 不存在');
      return;
    }
    final Map<String, dynamic> py =
        json.decode(f.readAsStringSync()) as Map<String, dynamic>;
    final Map<String, dynamic> dart = <String, dynamic>{};
    for (final File j
        in Directory('data/generated').listSync().whereType<File>()) {
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
      // 断点续传产物里 jsonl 章序可能非连续（如 novel_10w_pipeline 文件序为
      // 1..9,12,13...），必须按章号排序后再算连低——与 Python 侧载入进度时的
      // sorted(_dedup) 同口径，否则两端会算出不同的断供带。
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
      // 只比对 n/zones/in_zone 三项：py 侧另存了 ev 评审证据文本，
      // 证据文案一致性由两端各自的单测断言。
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
    expect(drift, isEmpty);
    expect(py.length, greaterThan(10));
  });
}