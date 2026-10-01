import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/multipass/multi_pass_chapter_engine.dart';

/// **手动**双端对账：`isPayoffScene` 与 Python `novel_pipeline.is_payoff_scene`
/// 在 240 例矩阵（goal × stage × 位置）上逐例一致。
///
/// 为什么在 tool/ 而不是 test/：依赖 `verify-logs/py_payscene.json`（gitignore），
/// 放 test/ 时 CI 必然「基线缺失 -> SKIP 即通过」，是假绿。缺失依赖时**直接失败**。
///
/// 运行：flutter test tool/verify_payoff_scene_parity_test.dart
void main() {
  test('isPayoffScene 与 Python 逐例一致（需本地基线）', () {
    final File f = File('verify-logs/py_payscene.json');
    expect(f.existsSync(), isTrue,
        reason: '基线缺失：${f.path}（本地一次性脚本用 Python 侧 '
            'novel_pipeline.is_payoff_scene 枚举 240 例的产物，不入库）');
    final List<dynamic> cases = json.decode(f.readAsStringSync()) as List<dynamic>;
    expect(cases.length, 240, reason: '基线应为 240 例矩阵');

    int drift = 0;
    for (final dynamic c in cases) {
      final Map<String, dynamic> m = c as Map<String, dynamic>;
      final bool dart = MultiPassChapterEngine.isPayoffScene(
          m['g'] as String, m['s'] as String, m['i'] as int, m['t'] as int);
      if (dart != m['r']) {
        drift++;
        if (drift <= 5) {
          // ignore: avoid_print
          print('DRIFT g=${m['g']} s=${m['s']} i=${m['i']} t=${m['t']} '
              'py=${m['r']} dart=$dart');
        }
      }
    }
    // ignore: avoid_print
    print('compared=${cases.length} drift=$drift');
    expect(drift, 0, reason: '爽点场景判定出现双端漂移');
  });
}
