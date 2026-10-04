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
      // ⚠ 这里刻意用 const **局部变量**（而不是 const 前缀访问静态字段）。
      // `const QualityValidation.unknown` 在 Dart 里不合法——const 只能修饰
      // 构造调用，不能修饰字段访问。而 `const QualityValidation v =
      // QualityValidation.unknown;` 才是真正的「可用于 const 上下文」探测：
      // 若哪天有人去掉构造器的 const，这里会**编译失败**而不是静默退化。
      //
      // 2026-10-03 曾有人把本用例原本的 const 去掉（疑似为绕开某个 lint），
      // 那等于悄悄撤掉了这道编译期守卫：测试照过，但常量性已丢。
      const QualityValidation v = QualityValidation.unknown;
      expect(v.minConclusion, cfg['minSamplesForConclusion']);
      expect(v.minStrong, cfg['minSamplesForStrongConclusion']);
    });

    // 2026-10-03 补：以下三档状态的文案此前**零覆盖**（quality_validation.dart
    // 第 118/128/130/132/149/150/152/155/157 行未执行）。文案是「效度声明」
    // 的载体——写错会直接误导作者对自身结论的判断，故必须逐档钉住。
    //
    // ⚠ 关键区分：parse() **到不了** validated（源码明确「桌面端不判定
    // validated，无从得知是否真跑过实验」），所以 validated 档只能用
    // 构造器直接造。用例必须反映这个差异，不能为了「跑通 parse」去改
    // parse 的判定逻辑——那等于为了让测试通过而改动产品语义。
    group('三档状态的限定文案（此前零覆盖）', () {
      QualityValidation make(QualityValidationStatus s, int ratings) =>
          QualityValidation(
            status: s,
            ratings: ratings,
            totalRows: ratings,
          );

      test('insufficient：样本不足，只能作方向性参考', () {
        final QualityValidation v =
            make(QualityValidationStatus.insufficient, 3);
        expect(v.needsCaveat, isTrue,
            reason: '样本不足同样必须披露限定，不能只对 none 披露');
        expect(v.isValidated, isFalse);
        expect(v.caveatLabel, contains('样本不足'));
        expect(v.detail, contains('样本不足'));
        expect(v.detail, contains('方向性参考'));
        expect(v.detail, contains('3/3'), reason: '必须带上真实标注计数');
        expect(v.detail, contains('10'), reason: '必须带上结论所需样本线');
        expect(v.detail, contains('30'), reason: '必须带上建议样本量');
      });

      test('provisional：样本够但未跑实验，提示须重跑复核', () {
        final QualityValidation v =
            make(QualityValidationStatus.provisional, 12);
        expect(v.needsCaveat, isFalse,
            reason: '样本量已够，不必再强调「样本不足」');
        expect(v.isValidated, isFalse,
            reason: '样本够 ≠ 跑过实验，绝不能判为已验证');
        expect(v.caveatLabel, contains('待复验'));
        expect(v.detail, contains('重跑人评实验'));
        expect(v.detail, contains('12/12'));
      });

      test('validated：唯一可称「已对齐」的档，且不需披露限定', () {
        final QualityValidation v =
            make(QualityValidationStatus.validated, 30);
        expect(v.isValidated, isTrue);
        expect(v.needsCaveat, isFalse);
        expect(v.caveatLabel, contains('已与人评对齐'));
        expect(v.detail, contains('已完成人评相关性实验'));
        expect(v.detail, contains('report-'), reason: '须指明报告位置');
      });

      test('三档 detail 的措辞互不相同（防复制粘贴退化）', () {
        final Set<String> details = <String>{
          make(QualityValidationStatus.none, 0).detail,
          make(QualityValidationStatus.insufficient, 3).detail,
          make(QualityValidationStatus.provisional, 12).detail,
          make(QualityValidationStatus.validated, 30).detail,
        };
        expect(details.length, 4,
            reason: '四档 detail 出现重复，说明某档文案被写成了另一档——'
                '作者会因此误判自己的结论');
      });

      test('caveatLabel 四档也互不相同', () {
        final Set<String> labels = <String>{
          make(QualityValidationStatus.none, 0).caveatLabel,
          make(QualityValidationStatus.insufficient, 3).caveatLabel,
          make(QualityValidationStatus.provisional, 12).caveatLabel,
          make(QualityValidationStatus.validated, 30).caveatLabel,
        };
        expect(labels.length, 4);
      });

      test('parse 无论多少标注都不产出 validated', () {
        // 钉住「桌面端不判定 validated」这条设计：它无从得知是否真跑过实验。
        final QualityValidation v = QualityValidation.parse(
          List<String>.filled(50, _row('x', 80)).join('\n'),
        );
        expect(v.ratings, 50);
        expect(v.status, QualityValidationStatus.provisional,
            reason: '样本再多也不该判 validated——没有报告就无法确认实验真跑过');
        expect(v.isValidated, isFalse);
      });

      test('toString 含状态名与计数（调试用）', () {
        expect(
          make(QualityValidationStatus.insufficient, 4).toString(),
          allOf(contains('insufficient'), contains('4/4')),
        );
      });
    });

    test('unknown 是编译期常量（可作 const 上下文）', () {
      // 与上一条互为对照：上一条验证「值对得上」，这条验证「它还能是常量」。
      // 两者是不同的失效模式——去掉 const 只破坏后者，而后者正是上面
      // 那个改动悄悄破坏的东西。
      const QualityValidation a = QualityValidation.unknown;
      const QualityValidation b = QualityValidation.unknown;
      expect(identical(a, b), isTrue,
          reason: 'unknown 必须是编译期常量；失去常量性会让依赖它的 '
              'const 上下文静默退化');
    });
  });
}