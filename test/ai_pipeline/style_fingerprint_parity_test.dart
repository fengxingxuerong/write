import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';

void main() {
  test('styleFingerprint 与 Python 逐值一致（真实成书，防双端漂移）', () {
    final File f = File('verify-logs/py_stylefp.json');
    if (!f.existsSync()) {
      // ignore: avoid_print
      print('SKIP: 基线不存在');
      return;
    }
    final Map<String, dynamic> py =
        json.decode(f.readAsStringSync()) as Map<String, dynamic>;
    final List<Map<String, dynamic>> cases = <Map<String, dynamic>>[
      py['ref'] as Map<String, dynamic>,
      ...(py['samples'] as List<dynamic>).cast<Map<String, dynamic>>()
          .map((Map<String, dynamic> s) => s['fp'] as Map<String, dynamic>),
    ];
    const List<String> files = <String>[
      'data/generated/novel_10w_pipeline.txt',
      'data/generated/short_sample.txt',
      'data/generated/smoke_gate_v7.txt',
    ];
    int drift = 0;
    for (int i = 0; i < cases.length; i++) {
      final Map<String, double> dart =
          PipelineQa.styleFingerprint(File(files[i]).readAsStringSync());
      for (final String k in PipelineQa.styleFingerprintKeys) {
        final double p = (pyCase(cases[i], k));
        final double d = dart[k] ?? 0.0;
        // 容差 0.01：实测九项逐值 diff=0.0000（完全一致），留一点余量防
        // 浮点末位抖动。注意**不比 words**——它两端定义本就不同（见下方注释）。
        if ((p - d).abs() > 0.01) {
          drift++;
          // ignore: avoid_print
          print('DRIFT ${files[i]} $k py=$p dart=$d');
        }
      }
      // words 不参与比对：双端 countWords 定义存在既有差异（Python 侧把
      // 字母->数字的转换算新词、Dart 算同一个词；Python 还缺 CJK 扩展 A 区），
      // 本轮只做指纹对账，不动字数口径——那是影响全书显示的产品级决定。
      // 见 docs/quality-enhancement-log.md 第 31 节。
    }
    // ignore: avoid_print
    print('compared=${cases.length} drift=$drift');
    expect(drift, 0);
  });
}

double pyCase(Map<String, dynamic> fp, String key) {
  final Object? v = fp[key];
  return v is num ? v.toDouble() : 0.0;
}