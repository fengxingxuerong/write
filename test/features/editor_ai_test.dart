import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/editor_ai.dart';

/// EditorAi 纯逻辑单元测试（无需 LLM 网络调用）
///
/// 覆盖：ProofreadIssue.applicable、ProofreadResult.applyFixes 各种场景。

void main() {
  group('ProofreadIssue.applicable', () {
    test('suggestion 非空时 applicable 为 true', () {
      const issue = ProofreadIssue(
        type: '错别字',
        original: '他己经',
        suggestion: '他已经',
        reason: '别字',
      );
      expect(issue.applicable, isTrue);
    });

    test('suggestion 为空字符串时 applicable 为 false', () {
      const issue = ProofreadIssue(
        type: '病句',
        original: '今天天气很好',
        suggestion: '',
        reason: '缺少主语',
      );
      expect(issue.applicable, isFalse);
    });

    test('suggestion 仅含空白字符时 applicable 为 false', () {
      const issue = ProofreadIssue(
        type: '重复啰嗦',
        original: '他非常非常高兴',
        suggestion: '   ',
        reason: '重复',
      );
      expect(issue.applicable, isFalse);
    });
  });

  group('ProofreadResult.applyFixes', () {
    test('正常替换：按 original 找到首个出现并替换为 suggestion', () {
      const text = '今天天气很好，阳光明媚。';
      final issues = [
        const ProofreadIssue(
          type: '用词不当',
          original: '阳光明媚',
          suggestion: '阳光灿烂',
          reason: '搭配更自然',
        ),
      ];

      final result = ProofreadResult.applyFixes(text, issues);
      expect(result.revised, '今天天气很好，阳光灿烂。');
      expect(result.issues, hasLength(1));
    });

    test('多个问题：逐条替换', () {
      const text = '他己经走了，而且己经走远了。';
      final issues = [
        const ProofreadIssue(
          type: '错别字',
          original: '己经',
          suggestion: '已经',
          reason: '别字',
        ),
      ];

      // replaceFirst 只替换首个出现
      final result = ProofreadResult.applyFixes(text, issues);
      expect(result.revised, '他已经走了，而且己经走远了。');
    });

    test('空 original 的条目被跳过', () {
      const text = '原文内容不变。';
      final issues = [
        const ProofreadIssue(
          type: '问题',
          original: '',
          suggestion: '修正',
          reason: '说明',
        ),
      ];

      final result = ProofreadResult.applyFixes(text, issues);
      expect(result.revised, '原文内容不变。');
    });

    test('空 suggestion 的条目被跳过', () {
      const text = '原文内容不变。';
      final issues = [
        const ProofreadIssue(
          type: '问题',
          original: '原文',
          suggestion: '',
          reason: '说明',
        ),
      ];

      final result = ProofreadResult.applyFixes(text, issues);
      expect(result.revised, '原文内容不变。');
    });

    test('original == suggestion 的条目被跳过（避免无限替换）', () {
      const text = '无需修改的文本。';
      final issues = [
        const ProofreadIssue(
          type: '无变化',
          original: '无需修改',
          suggestion: '无需修改',
          reason: '相同',
        ),
      ];

      final result = ProofreadResult.applyFixes(text, issues);
      expect(result.revised, '无需修改的文本。');
    });

    test('original 不在原文中时不替换', () {
      const text = '完全不同的内容。';
      final issues = [
        const ProofreadIssue(
          type: '错别字',
          original: '不存在',
          suggestion: '修正',
          reason: '说明',
        ),
      ];

      final result = ProofreadResult.applyFixes(text, issues);
      expect(result.revised, '完全不同的内容。');
    });

    test('空 issues 列表返回原文', () {
      const text = '没有任何问题。';
      final result = ProofreadResult.applyFixes(text, []);
      expect(result.revised, '没有任何问题。');
      expect(result.issues, isEmpty);
    });

    test('混合场景：部分条目被跳过，部分被应用', () {
      const text = '他己经到家了，心情非常好。';
      final issues = [
        const ProofreadIssue(
          type: '错别字',
          original: '己经',
          suggestion: '已经',
          reason: '别字',
        ),
        const ProofreadIssue(
          type: '无效',
          original: '',
          suggestion: '修正',
          reason: '空 original',
        ),
        const ProofreadIssue(
          type: '重复',
          original: '非常好',
          suggestion: '极好',
          reason: '用词优化',
        ),
      ];

      final result = ProofreadResult.applyFixes(text, issues);
      expect(result.revised, '他已经到家了，心情极好。');
      expect(result.issues, hasLength(3));
    });
  });

  group('ProofreadResult 基本属性', () {
    test('hasIssues 反映 issues 是否为空', () {
      const emptyResult = ProofreadResult(issues: [], revised: '文本');
      expect(emptyResult.hasIssues, isFalse);

      const nonEmptyResult = ProofreadResult(
        issues: [
          ProofreadIssue(
            type: '错别字',
            original: 'abc',
            suggestion: 'def',
            reason: '说明',
          ),
        ],
        revised: '文本',
      );
      expect(nonEmptyResult.hasIssues, isTrue);
    });
  });
}
