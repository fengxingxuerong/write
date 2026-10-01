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
///
/// **登记表必须完整**（2026-10-01 修复）：
/// 本文件原先只手工登记 8 张词表 / 7 项阈值，而 JSON 已收编到 29 张 / 9 项
/// （b6e4a27 增 11 张、ad02fbc 再增 8 组）。新增条目未登记 → `dart[id]` 为 null →
/// `expect(have, isNotNull)` 失败，**整个 CI 红**。
///
/// 教训：这份登记表本身就是「需要手工同步的第二份」，是上一轮假绿的同型复发。
/// 故加两道自守卫，让它不可能再悄悄漏：
/// 1. [_declaredInGeneratedFile] 直接解析 `quality_rules.g.dart` 的常量声明，
///    与 JSON 的 id 集合双向比对——手改了生成物（文件头明令禁止）会被抓住；
/// 2. 值比对遍历 **JSON 全集**而非登记表全集，新增 JSON 条目时若忘记登记，
///    会以带 id 的明确 reason 失败，而不是抛一个无上下文的 null。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/quality/quality_rules.g.dart';

/// 词表登记表：JSON `id` ⟷ Dart 常量。Dart 常量名与 id 同形（由 rules_codegen 保证）。
/// 值类型是 `Object`：多数是 `List<String>`，`triadHookOnly` 是 `Set<String>`。
final Map<String, Object> _dartLists = <String, Object>{
  'hookWords': QualityRules.hookWords,
  'openingStrong': QualityRules.openingStrong,
  'openingWeak': QualityRules.openingWeak,
  'thrillWords': QualityRules.thrillWords,
  'powerSurgeWords': QualityRules.powerSurgeWords,
  'sideReactionWords': QualityRules.sideReactionWords,
  'triadEndWords': QualityRules.triadEndWords,
  'triadHookOnly': QualityRules.triadHookOnly,
  'gateClichePhrases': QualityRules.gateClichePhrases,
  'reviewClicheSentences': QualityRules.reviewClicheSentences,
  'redlinePolitics': QualityRules.redlinePolitics,
  'redlineReligion': QualityRules.redlineReligion,
  'redlineMinorRisk': QualityRules.redlineMinorRisk,
  'redlineGore': QualityRules.redlineGore,
  'redlineBrandCelebrity': QualityRules.redlineBrandCelebrity,
  'redlineIllegalDetail': QualityRules.redlineIllegalDetail,
  'sensitiveViolence': QualityRules.sensitiveViolence,
  'sensitiveSexual': QualityRules.sensitiveSexual,
  'sensitiveAbuse': QualityRules.sensitiveAbuse,
  'sensitiveIllegal': QualityRules.sensitiveIllegal,
  'sensitiveAds': QualityRules.sensitiveAds,
  'promptLeak': QualityRules.promptLeak,
  'metaTalk': QualityRules.metaTalk,
  'modernMarkers': QualityRules.modernMarkers,
  'ancientGenres': QualityRules.ancientGenres,
  'negation': QualityRules.negation,
  'aiAdverbs': QualityRules.aiAdverbs,
  'sentenceConnectors': QualityRules.sentenceConnectors,
  'bodyReactionWords': QualityRules.bodyReactionWords,
};

/// 阈值登记表：JSON `id` ⟷ Dart 常量（int / double 统一按 num 比）。
final Map<String, num> _dartScalars = <String, num>{
  'triadEndWindow': QualityRules.triadEndWindow,
  'minDialogueRatio': QualityRules.minDialogueRatio,
  'maxFillerRatio': QualityRules.maxFillerRatio,
  'droughtThrillPerK': QualityRules.droughtThrillPerK,
  'droughtSidePerK': QualityRules.droughtSidePerK,
  'droughtMinRun': QualityRules.droughtMinRun,
  'fixMinRatio': QualityRules.fixMinRatio,
  'intraRepeatMinBlock': QualityRules.intraRepeatMinBlock,
  'intraRepeatGram': QualityRules.intraRepeatGram,
};

const String _rulesPath = 'rules/quality_rules.json';
const String _generatedPath = 'lib/engine/quality/quality_rules.g.dart';

Map<String, dynamic> _loadRules() {
  final File f = File(_rulesPath);
  // 用 expect 而不是 fail()：沿用本仓库既有用例的写法（flutter analyze 已验证），
  // 且文件缺失时 expect 立即抛出，后面的 readAsStringSync 不会执行。
  expect(f.existsSync(), isTrue,
      reason: '缺少 $_rulesPath —— 它是双端质检词表/阈值的唯一数据源，必须入库');
  return json.decode(f.readAsStringSync()) as Map<String, dynamic>;
}

/// 解析生成物 `quality_rules.g.dart` 里实际声明的常量名。
///
/// 目的：登记表（[_dartLists] / [_dartScalars]）与生成物、JSON 三者互为对照。
/// 手改生成物是文件头明令禁止的行为，但「禁止」不如「可检测」——这里把它变成可检测。
Set<String> _declaredInGeneratedFile() {
  final File f = File(_generatedPath);
  expect(f.existsSync(), isTrue,
      reason: '缺少 $_generatedPath —— 请跑 python scripts/rules_codegen.py');
  final RegExp re = RegExp(
    r'static const (?:List<String>|Set<String>|int|double) (\w+) =',
  );
  return re
      .allMatches(f.readAsStringSync())
      .map((RegExpMatch m) => m.group(1)!)
      .toSet();
}

/// `Object`（List / Set）统一摊平成有序 `List<String>`。
List<String> _flatten(Object v) => (v as Iterable<dynamic>).cast<String>().toList();

Set<String> _idsOf(Map<String, dynamic> rules, String section) => <String>{
      for (final dynamic raw in rules[section] as List<dynamic>)
        (raw as Map<String, dynamic>)['id'] as String,
    };

void main() {
  test('生成物常量集合与 JSON 条目双向一致（防手改生成物 / 漏跑 codegen）', () {
    final Set<String> declared = _declaredInGeneratedFile();
    final Set<String> ids = <String>{
      ..._idsOf(_loadRules(), 'lists'),
      ..._idsOf(_loadRules(), 'scalars'),
    };
    expect(declared.difference(ids), isEmpty,
        reason: '生成物里有 JSON 未登记的常量（禁止手改 quality_rules.g.dart；'
            '请先改 JSON 再跑 python scripts/rules_codegen.py）：'
            '${(declared.difference(ids).toList()..sort()).join(', ')}');
    expect(ids.difference(declared), isEmpty,
        reason: 'JSON 有条目但生成物缺对应常量（漏跑 rules_codegen）：'
            '${(ids.difference(declared).toList()..sort()).join(', ')}');
  });

  test('词表：Dart 常量与 JSON 逐值、逐序一致', () {
    final Map<String, dynamic> rules = _loadRules();
    for (final dynamic raw in rules['lists'] as List<dynamic>) {
      final Map<String, dynamic> item = raw as Map<String, dynamic>;
      final String id = item['id'] as String;
      final List<String> values = (item['values'] as List<dynamic>).cast<String>();
      expect(_dartLists.containsKey(id), isTrue,
          reason: 'JSON 有词表 $id，但本测试未登记（补一行 '
              "'$id': QualityRules.$id,）——漏登记会让本用例失败，属预期守卫");
      final List<String> have = _flatten(_dartLists[id]!);
      if (item['kind'] == 'set') {
        expect(have..sort(), values..sort(),
            reason: '$id 与 JSON 不一致（集合，忽略顺序）');
      } else {
        // 顺序敏感：endingTriad 返回首个命中词，长词必须在短词之前。
        expect(have, values, reason: '$id 与 JSON 不一致（列表，顺序敏感）');
        expect(values.toSet().length, values.length,
            reason: '$id 内有重复项——命中数会被记两次，双端密度必然不同');
      }
    }
    expect(_dartLists.keys.toSet().difference(_idsOf(rules, 'lists')), isEmpty,
        reason: '本测试登记了 JSON 没有的词表（先改 JSON 再跑 rules_codegen）');
  });

  test('阈值：Dart 常量与 JSON 一致', () {
    final Map<String, dynamic> rules = _loadRules();
    for (final dynamic raw in rules['scalars'] as List<dynamic>) {
      final Map<String, dynamic> item = raw as Map<String, dynamic>;
      final String id = item['id'] as String;
      final num expected = item['value'] as num;
      expect(_dartScalars.containsKey(id), isTrue,
          reason: 'JSON 有阈值 $id，但本测试未登记（补一行 '
              "'$id': QualityRules.$id,）——漏登记会让本用例失败，属预期守卫");
      expect(_dartScalars[id]!.toDouble(), expected.toDouble(),
          reason: '$id 阈值与 JSON 不一致');
    }
    expect(_dartScalars.keys.toSet().difference(_idsOf(rules, 'scalars')), isEmpty,
        reason: '本测试登记了 JSON 没有的阈值（先改 JSON 再跑 rules_codegen）');
  });
}
