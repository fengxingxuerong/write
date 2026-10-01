import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/quality/quality_rules.g.dart';

/// Dart 侧质检常量 ⟷ 数据源 `rules/quality_rules.json` 的逐值、逐序对账。
///
/// 为什么需要它（2026-10-01）：
/// 词表与阈值原先在 Dart 与 Python 各写一份，靠注释约定「改一处同步另一处」。
/// 仓库里原有三个 parity 测试，但它们在基线文件缺失时 `print('SKIP') + return`
/// ——即**通过**；而基线放在 gitignore 的 verify-logs/ 下，CI 上永远缺失，
/// 于是「防标准漂移」在 CI 里实际是假绿（2026-10-01 评审确认）。
///
/// 本测试**不依赖任何本地基线与数据产物**，只读入库的规则 JSON，因此在 CI 中
/// 真正生效；配合 Python 侧 scripts/test_quality_rules_parity.py 与
/// `python scripts/rules_codegen.py --check`，双端词表漂移在结构上不再可能。
void main() {
  const String path = 'rules/quality_rules.json';

  Map<String, dynamic> load() {
    final File f = File(path);
    // 用 expect 而不是 fail()：沿用本仓库既有用例的写法（flutter analyze 已验证），
    // 且文件缺失时 expect 立即抛出，后面的 readAsStringSync 不会执行。
    expect(f.existsSync(), isTrue,
        reason: '缺少 $path —— 它是双端质检词表/阈值的唯一数据源，必须入库');
    return json.decode(f.readAsStringSync()) as Map<String, dynamic>;
  }

  test('词表：Dart 常量与 JSON 逐值、逐序一致', () {
    final Map<String, dynamic> rules = load();
    // 集合先展开排序，避免在 map 字面量里用级联（保证语法无歧义）。
    final List<String> triadHookOnly =
        QualityRules.triadHookOnly.toList()..sort();
    final Map<String, List<String>> dart = <String, List<String>>{
      'hookWords': QualityRules.hookWords,
      'openingStrong': QualityRules.openingStrong,
      'openingWeak': QualityRules.openingWeak,
      'thrillWords': QualityRules.thrillWords,
      'powerSurgeWords': QualityRules.powerSurgeWords,
      'sideReactionWords': QualityRules.sideReactionWords,
      'triadEndWords': QualityRules.triadEndWords,
      'triadHookOnly': triadHookOnly,
    };
    final List<String> ids = <String>[];
    for (final dynamic raw in rules['lists'] as List<dynamic>) {
      final Map<String, dynamic> item = raw as Map<String, dynamic>;
      final String id = item['id'] as String;
      ids.add(id);
      final List<String> values =
          (item['values'] as List<dynamic>).cast<String>();
      final List<String>? have = dart[id];
      expect(have, isNotNull,
          reason: 'JSON 有词表 $id，但 Dart 侧没有对应常量（漏跑 rules_codegen？）');
      if (item['kind'] == 'set') {
        expect(have, <String>[...values]..sort(),
            reason: '$id 与 JSON 不一致（集合，忽略顺序）');
      } else {
        // 顺序敏感：endingTriad 返回首个命中词，长词必须在短词之前。
        expect(have, values, reason: '$id 与 JSON 不一致（列表，顺序敏感）');
        expect(values.toSet().length, values.length,
            reason: '$id 内有重复项——命中数会被记两次，双端密度必然不同');
      }
    }
    expect(dart.keys.toSet().difference(ids.toSet()), isEmpty,
        reason: 'Dart 有 JSON 未登记的词表常量（先改 JSON 再跑 rules_codegen）');
  });

  test('阈值：Dart 常量与 JSON 一致', () {
    final Map<String, dynamic> rules = load();
    final Map<String, num> dart = <String, num>{
      'triadEndWindow': QualityRules.triadEndWindow,
      'minDialogueRatio': QualityRules.minDialogueRatio,
      'maxFillerRatio': QualityRules.maxFillerRatio,
      'droughtThrillPerK': QualityRules.droughtThrillPerK,
      'droughtSidePerK': QualityRules.droughtSidePerK,
      'droughtMinRun': QualityRules.droughtMinRun,
      'fixMinRatio': QualityRules.fixMinRatio,
    };
    final List<String> ids = <String>[];
    for (final dynamic raw in rules['scalars'] as List<dynamic>) {
      final Map<String, dynamic> item = raw as Map<String, dynamic>;
      final String id = item['id'] as String;
      ids.add(id);
      final num expected = item['value'] as num;
      expect(dart[id], isNotNull, reason: 'JSON 有阈值 $id，但 Dart 侧没有对应常量');
      expect(dart[id]!.toDouble(), expected.toDouble(),
          reason: '$id 阈值与 JSON 不一致');
    }
    expect(dart.keys.toSet().difference(ids.toSet()), isEmpty,
        reason: 'Dart 有 JSON 未登记的阈值常量（先改 JSON 再跑 rules_codegen）');
  });
}
