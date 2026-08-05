import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/engine/constraints/generation_constraints.dart';
import 'package:novel_writer/models/generation_config.dart';

/// ConstraintController 与 GenerationConstraints 单元测试
///
/// 覆盖：字数上限判定、canContinue、truncate 截断与句末断句、
/// GenerationConstraints 的序列化与默认值。
void main() {
  group('ConstraintController 字数上限', () {
    test('maxWords 等于约束上限', () {
      const ctrl = ConstraintController(
        GenerationConstraints(maxWordsPerChapter: 1234),
      );
      expect(ctrl.maxWords, equals(1234));
    });

    test('canContinue 在达到上限前为 true，达到后为 false', () {
      const ctrl = ConstraintController(
        GenerationConstraints(maxWordsPerChapter: 100),
      );
      expect(ctrl.canContinue(0), isTrue);
      expect(ctrl.canContinue(99), isTrue);
      expect(ctrl.canContinue(100), isFalse);
      expect(ctrl.canContinue(200), isFalse);
    });

    test('truncate 对未超限文本原样返回', () {
      const ctrl = ConstraintController(
        GenerationConstraints(maxWordsPerChapter: 200),
      );
      const text = '这是一段明显少于字数上限的中文内容。';
      expect(ctrl.truncate(text, 200), equals(text));
    });

    test('truncate 将超过上限的文本裁剪到上限以内', () {
      const ctrl = ConstraintController(
        GenerationConstraints(maxWordsPerChapter: 50),
      );
      final long = '一' * 200; // 200 个中文字
      final result = ctrl.truncate(long, 50);
      expect(AppConstants.countWords(result), lessThanOrEqualTo(50));
      expect(AppConstants.countWords(result), greaterThan(0));
    });

    test('truncate 在句末标点处断句（接近上限时）', () {
      const ctrl = ConstraintController(
        GenerationConstraints(maxWordsPerChapter: 30),
      );
      const text = '第一行内容在此。第二行内容也在。第三行还有内容。';
      final result = ctrl.truncate(text, 30);
      expect(AppConstants.countWords(result), lessThanOrEqualTo(30));
    });
  });

  group('GenerationConstraints 序列化', () {
    test('默认上限为 20000 且不允许重复', () {
      const c = GenerationConstraints();
      expect(c.maxWordsPerChapter, equals(AppConstants.defaultMaxWordsPerChapter));
      expect(c.allowRepeat, isFalse);
    });

    test('toJson/fromJson 往返一致', () {
      const c = GenerationConstraints(maxWordsPerChapter: 8000, allowRepeat: true);
      final back = GenerationConstraints.fromJson(c.toJson());
      expect(back.maxWordsPerChapter, equals(8000));
      expect(back.allowRepeat, isTrue);
    });

    test('缺字段时回退默认值', () {
      final back = GenerationConstraints.fromJson(<String, dynamic>{});
      expect(back.maxWordsPerChapter, equals(AppConstants.defaultMaxWordsPerChapter));
      expect(back.allowRepeat, isFalse);
    });

    test('copyWith 仅修改指定字段', () {
      const c = GenerationConstraints();
      final updated = c.copyWith(maxWordsPerChapter: 5000);
      expect(updated.maxWordsPerChapter, equals(5000));
      expect(updated.allowRepeat, isFalse);
    });
  });
}
