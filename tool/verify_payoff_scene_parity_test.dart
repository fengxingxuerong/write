import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/multipass/multi_pass_chapter_engine.dart';

/// 双端对账：`isPayoffScene` 与 Python `pipeline_quality.is_payoff_scene`
/// 在 240 例矩阵（goal × stage × 位置）上逐例一致。
///
/// 基线来源（2026-10-14 改）：`rules/payoff_scene_parity.json`（**已入库**）。
/// 此前只读 `verify-logs/py_payscene.json`，而 `verify-logs/` 与 `data/` 均被
/// gitignore → 这份唯一的双端算法对账在新克隆与 CI 上**永远不跑**。作者为
/// 避开「基线缺失 -> SKIP 即通过」的假绿把它移出 test/，代价是失去 CI 保护。
///
/// 但 payscene 这份**根本不需要语料**：`is_payoff_scene` 是纯函数，240 例枚举
/// 口径自持。故把期望值固化成入库基线，既能进 CI 也不必依赖本机 verify-logs/。
/// Python 侧的机器校验见 `scripts/test_payoff_scene_parity.py`（CI 会跑）：
/// 它钉 Python 行为 + 双端词表一致 + 基线自身自洽，三者合起来才完整。
///
/// 仍保留 `verify-logs/py_payscene.json` 回退：作者本机重跑
/// `python tool/gen_parity_baselines.py --only payscene` 后，可对比入库基线。
///
/// 运行：flutter test tool/verify_payoff_scene_parity_test.dart
void main() {
  test('isPayoffScene 与 Python 逐例一致', () {
    // 优先用入库基线（CI / 新克隆可用）；回退到本机 verify-logs/。
    final File pinned = File('rules/payoff_scene_parity.json');
    final File local = File('verify-logs/py_payscene.json');
    final File f = pinned.existsSync() ? pinned : local;
    expect(f.existsSync(), isTrue,
        reason: '基线缺失：${pinned.path} 与 ${local.path} 均不存在。\n'
            '入库基线 rules/payoff_scene_parity.json 是固化期望（勿手改）。\n'
            '若需用本机重算值对比：python tool/gen_parity_baselines.py '
            '--only payscene（枚举 10 目标 × 4 场景拍 × 6 位置 = 240 例，'
            '逐例调 Python 侧 is_payoff_scene 记录判定）。');
    final List<dynamic> cases =
        json.decode(f.readAsStringSync()) as List<dynamic>;
    expect(cases.length, 240, reason: '基线应为 240 例矩阵，实为 ${cases.length}');

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
    print('compared=${cases.length} drift=$drift source=${f.path}');
    expect(drift, 0, reason: '爽点场景判定出现双端漂移（Dart 与 Python 不一致）');
  });
}
