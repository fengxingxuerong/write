/// 外部效度状态（Dart 侧）的离线回归测试。
///
/// 与 scripts/test_quality_validation.py 成对：两侧语义必须一致
/// （同一份 rules/quality_validation.json 数据源 + 同一套判定规则）。
///
/// 关键性质：状态从**真实标注数据**推导，不是写死的常量——人评补上后自动升级。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/quality/quality_validation.dart';

/// 构造一行标注。
String _row(String id, Object? human) =>
    jsonEncode(<String, Object?>{'id': id, 'human': human});

void main() {
  group('QualityValidation.parse 判定「真实标注」', () {
    test('数值分数计入，空与 null 不计入', () {
      final QualityValidation v = QualityValidation.parse(
        <String>[
          '# 注释行',
          '',
          _row('a', 82),
          _row('b', null),
          _row('c', 90),
        ].join('\n'),
      );
      expect(v.ratings, 2);
      expect(v.totalRows, 3);
    });

    test('字符串分数不算人评（多半是机器批量生成的）', () {
      final QualityValidation v =
          QualityValidation.parse(_row('a', '85'));
      expect(v.ratings, 0);
      expect(v.status, QualityValidationStatus.none);
    });

    test('bool 不算人评（bool 是 int 子类，必须显式排除）', () {
      expect(QualityValidation.parse(_row('a', true)).ratings, 0);
    });

    test('坏行跳过而不抛错（标注是人手工维护的，需容错）', () {
      final QualityValidation v = QualityValidation.parse(
        <String>[_row('a', 70), '{坏行', '[]', '纯字符串'].join('\n'),
      );
      expect(v.ratings, 1);
      expect(v.totalRows, 1);
    });

    test('空输入不崩且判为未验证', () {
      final QualityValidation v = QualityValidation.parse('');
      expect(v.ratings, 0);
      expect(v.status, QualityValidationStatus.none);
      expect(v.needsCaveat, isTrue);
    });
  });

  group('状态随真实数据升级（防「永远停在 none」）', () {
    String many(int n) =>
        List<String>.generate(n, (int i) => _row('c$i', 80 + i % 10))
            .join('\n');

    test('0 条 -> none', () {
      expect(QualityValidation.parse(many(0)).status,
          QualityValidationStatus.none);
    });

    test('少于样本线 -> insufficient', () {
      expect(QualityValidation.parse(many(5)).status,
          QualityValidationStatus.insufficient);
    });

    test('达到样本线但无报告 -> provisional（不越级判 validated）', () {
      final QualityValidation v = QualityValidation.parse(many(12));
      expect(v.status, QualityValidationStatus.provisional);
      expect(v.isValidated, isFalse);
    });

    test('升级序列单调，不会把「有标注」误判成 none', () {
      final List<QualityValidationStatus> seq = <QualityValidationStatus>[
        QualityValidation.parse(many(0)).status,
        QualityValidation.parse(many(5)).status,
        QualityValidation.parse(many(12)).status,
      ];
      expect(seq, <QualityValidationStatus>[
        QualityValidationStatus.none,
        QualityValidationStatus.insufficient,
        QualityValidationStatus.provisional,
      ]);
    });
  });

  group('默认值是「保守」而非「信任」', () {
    test('unknown 判为未验证并要求披露', () {
      // 桌面端读不到标注文件时用这个默认值——绝不能因为读不到就默认可信。
      expect(QualityValidation.unknown.status, QualityValidationStatus.none);
      expect(QualityValidation.unknown.needsCaveat, isTrue);
      expect(QualityValidation.unknown.isValidated, isFalse);
    });
  });

  group('文案必须说清「达线 ≠ 好看」', () {
    test('none 状态的 label 与 detail 都点明未与人评对齐', () {
      final QualityValidation v = QualityValidation.parse('');
      expect(v.caveatLabel, contains('未与人评对齐'));
      expect(v.detail, contains('不代表读者认可'));
      expect(v.detail, contains('刷分'));
    });

    test('detail 始终带上真实标注计数', () {
      final QualityValidation v =
          QualityValidation.parse(<String>[_row('a', 80)].join('\n'));
      expect(v.detail, contains('1/1'));
    });
  });

  group('与 Python 侧数据源一致', () {
    test('rules/quality_validation.json 必须在库且含必要键', () {
      final File f = File('rules/quality_validation.json');
      expect(f.existsSync(), isTrue,
          reason: '外部效度状态的数据源必须入库，否则双端无从对齐');
      final Map<String, dynamic> cfg =
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      expect(cfg.containsKey('minSamplesForConclusion'), isTrue);
      expect(cfg.containsKey('minSamplesForStrongConclusion'), isTrue);
      expect(cfg.containsKey('annotationsPath'), isTrue);
      expect(cfg.containsKey('statusVocabulary'), isTrue);
    });

    test('Dart 默认样本线与 Python 数据源一致', () {
      // Dart 侧 parse() 用的硬编码 10/30 必须与 JSON 对齐，否则双端会分叉。
      final File f = File('rules/quality_validation.json');
      final Map<String, dynamic> cfg =
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      expect(const QualityValidation.unknown.minConclusion,
          cfg['minSamplesForConclusion']);
      expect(const QualityValidation.unknown.minStrong,
          cfg['minSamplesForStrongConclusion']);
    });
  });
}