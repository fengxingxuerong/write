import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/engine/editor_ai.dart';

/// EditorAi 校对逻辑的单元测试。
///
/// 覆盖：问题解析容错、客户端修正应用（original -> suggestion 替换）。
void main() {
  group('ProofreadIssue.applicable', () {
    test('suggestion 为空时不可应用', () {
      const ProofreadIssue issue = ProofreadIssue(
        type: '逻辑矛盾',
        original: '',
        suggestion: '',
        reason: '前后时间不一致，建议人工复核',
      );
      expect(issue.applicable, isFalse);
    });

    test('suggestion 非空时可应用', () {
      const ProofreadIssue issue = ProofreadIssue(
        type: '错别字',
        original: '光茫',
        suggestion: '光芒',
        reason: '错别字',
      );
      expect(issue.applicable, isTrue);
    });
  });

  group('ProofreadResult.applyFixes（客户端修正引擎）', () {
    test('按 original -> suggestion 替换首个出现处', () {
      const String text = '他握着剑，剑身泛着光茫。光茫很冷。';
      const List<ProofreadIssue> issues = <ProofreadIssue>[
        ProofreadIssue(
          type: '错别字',
          original: '光茫',
          suggestion: '光芒',
          reason: '错别字',
        ),
      ];
      final ProofreadResult r =
          ProofreadResult.applyFixes(text, issues);
      expect(r.revised, equals('他握着剑，剑身泛着光芒。光茫很冷。'));
      expect(r.issues.length, equals(1));
      expect(r.hasIssues, isTrue);
    });

    test('多条修正依次应用', () {
      const String text = '光茫在夜风中显的格外坚定。';
      const List<ProofreadIssue> issues = <ProofreadIssue>[
        ProofreadIssue(
          type: '错别字',
          original: '光茫',
          suggestion: '光芒',
          reason: '错别字',
        ),
        ProofreadIssue(
          type: '病句',
          original: '显的',
          suggestion: '显得',
          reason: '助词错误',
        ),
      ];
      final ProofreadResult r =
          ProofreadResult.applyFixes(text, issues);
      expect(r.revised, equals('光芒在夜风中显得格外坚定。'));
    });

    test('无问题时 revised 与原文一致', () {
      const String text = '全文流畅，没有错误。';
      final ProofreadResult r =
          ProofreadResult.applyFixes(text, const <ProofreadIssue>[]);
      expect(r.hasIssues, isFalse);
      expect(r.revised, equals(text));
    });

    test('跳过空 original / 空 suggestion 的条目', () {
      const String text = '原文内容。';
      const List<ProofreadIssue> issues = <ProofreadIssue>[
        ProofreadIssue(
          type: '逻辑矛盾',
          original: '',
          suggestion: '',
          reason: '需人工复核',
        ),
        ProofreadIssue(
          type: '重复啰嗦',
          original: '原文',
          suggestion: '',
          reason: '建议精简',
        ),
      ];
      final ProofreadResult r =
          ProofreadResult.applyFixes(text, issues);
      expect(r.revised, equals(text));
    });

    test('跳过修正与原文相同的条目（模型凑数）', () {
      const String text = '他握着剑，剑身泛着光茫。';
      const List<ProofreadIssue> issues = <ProofreadIssue>[
        ProofreadIssue(
          type: '重复啰嗦',
          original: '他握着剑',
          suggestion: '他握着剑',
          reason: '凑数条目',
        ),
        ProofreadIssue(
          type: '错别字',
          original: '光茫',
          suggestion: '光芒',
          reason: '错别字',
        ),
      ];
      final ProofreadResult r =
          ProofreadResult.applyFixes(text, issues);
      expect(r.revised, equals('他握着剑，剑身泛着光芒。'));
    });
  });
}
