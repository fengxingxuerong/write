import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/outline_text.dart';

/// 大纲字段文本归一化测试：真实规划官会把 world/protagonist 返回成对象。
void main() {
  group('outlineText', () {
    test('字符串原样返回并去空白', () {
      expect(outlineText('  开篇钩子  '), '开篇钩子');
    });

    test('数字与布尔转字面量', () {
      expect(outlineText(7), '7');
      expect(outlineText(true), 'true');
    });

    test('对象拍平成「键：值」，嵌套递归、空值跳过', () {
      final String text = outlineText(<String, dynamic>{
        'continent': '九霄大陆',
        'power_system': '炼气/筑基/金丹',
        'faction': <String, dynamic>{'main': '剑宗', 'enemy': ''},
        'empty': null,
      });
      expect(text, contains('continent：九霄大陆'));
      expect(text, contains('power_system：炼气/筑基/金丹'));
      expect(text, contains('faction：main：剑宗'));
      expect(text, isNot(contains('empty')));
    });

    test('数组用顿号连接', () {
      expect(outlineText(<String>['打脸', '升级', '收获']), '打脸、升级、收获');
    });

    test('null 与不可识别类型返回空串', () {
      expect(outlineText(null), isEmpty);
      expect(outlineText(<String, dynamic>{'a': null}), isEmpty);
      expect(outlineText(<dynamic>[]), isEmpty);
    });
  });
}