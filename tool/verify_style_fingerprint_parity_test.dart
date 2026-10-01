import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';

/// **手动**双端对账：九项文风指纹与 Python 逐值一致。
///
/// 为什么在 tool/ 而不是 test/：依赖 `verify-logs/py_stylefp.json` 与
/// `data/generated/*.txt`（均 gitignore），放 test/ 时 CI 必然「基线缺失 ->
/// SKIP 即通过」，是假绿。缺失依赖时**直接失败**，绝不静默通过。
///
/// 运行：flutter test tool/verify_style_fingerprint_parity_test.dart
void main() {
  test('styleFingerprint 与 Python 逐值一致（需本地基线）', () {
    final File f = File('verify-logs/py_stylefp.json');
    expect(f.existsSync(), isTrue,
        reason: '基线缺失：${f.path}（本地一次性脚本用 Python 侧 '
            'generate_novel.style_fingerprint 对下列三个真实成书复算的产物，不入库）');
    final Map<String, dynamic> py =
        json.decode(f.readAsStringSync()) as Map<String, dynamic>;
    final List<Map<String, dynamic>> cases = <Map<String, dynamic>>[
      py['ref'] as Map<String, dynamic>,
      ...(py['samples'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((Map<String, dynamic> s) => s['fp'] as Map<String, dynamic>),
    ];
    // 顺序必须与基线一致：cases[0] = ref = 第一个文件，其后每个 sample 对应下一个文件。
    const List<String> files = <String>[
      'data/generated/novel_10w_pipeline.txt',
      'data/generated/short_sample.txt',
      'data/generated/smoke_gate_v7.txt',
    ];
    expect(cases.length, files.length,
        reason: '基线样本数与对账文件数不一致：请同步 tool 里的 files 列表');

    int drift = 0;
    for (int i = 0; i < cases.length; i++) {
      final File src = File(files[i]);
      expect(src.existsSync(), isTrue, reason: '真机样本缺失：${src.path}');
      final Map<String, double> dart =
          PipelineQa.styleFingerprint(src.readAsStringSync());
      for (final String k in PipelineQa.styleFingerprintKeys) {
        final Object? v = cases[i][k];
        final double p = v is num ? v.toDouble() : 0.0;
        final double d = dart[k] ?? 0.0;
        // 容差 0.01：实测九项逐值 diff=0.0000，留余量防浮点末位抖动。
        // 注意**不比 words**——双端 countWords 定义本就不同（见
        // docs/quality-rules-current.md 第三节「已知的端间不对称」）。
        if ((p - d).abs() > 0.01) {
          drift++;
          // ignore: avoid_print
          print('DRIFT ${files[i]} $k py=$p dart=$d');
        }
      }
    }
    // ignore: avoid_print
    print('compared=${cases.length} drift=$drift');
    expect(drift, 0, reason: '文风指纹出现双端漂移');
  });
}
