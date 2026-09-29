import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/multipass/multi_pass_chapter_engine.dart';

void main() {
  test('isPayoffScene 与 Python 逐例一致（240 例矩阵，防双端漂移）', () {
    final File f = File('verify-logs/py_payscene.json');
    if (!f.existsSync()) {
      // ignore: avoid_print
      print('SKIP: 基线不存在');
      return;
    }
    final List<dynamic> cases = json.decode(f.readAsStringSync()) as List<dynamic>;
    int drift = 0;
    for (final dynamic c in cases) {
      final Map<String, dynamic> m = c as Map<String, dynamic>;
      final bool dart = MultiPassChapterEngine.isPayoffScene(
          m['g'] as String, m['s'] as String,
          m['i'] as int, m['t'] as int);
      if (dart != m['r']) {
        drift++;
        if (drift <= 5) {
          // ignore: avoid_print
          print('DRIFT g=${m['g']} s=${m['s']} i=${m['i']} t=${m['t']} py=${m['r']} dart=$dart');
        }
      }
    }
    // ignore: avoid_print
    print('compared=${cases.length} drift=$drift');
    expect(drift, 0);
    expect(cases.length, 240);
  });
}