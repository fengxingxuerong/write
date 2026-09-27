import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/utils/text_index.dart';

/// [TextIndex] 的契约测试：只允许「多放行」，绝不允许漏判。
void main() {
  const String text = '陈默在擂台把灵力压进指节，听见瓦片在屋脊上碎开，'
      '碎屑落进领口里冰凉。他低声道：“再往前一步，今日就没人有台阶可下了。”'
      '他的嘴角勾起一抹极淡的弧度，眼底闪过一丝冷意。\n'
      '九幽宗盘踞北境雪谷，以炼体术闻名。MVP 数据流 12345 vx:';

  group('TextIndex.mayContain', () {
    test('命中词一律放行（contains 为真 → mayContain 必须为真）', () {
      const List<String> present = <String>[
        '陈默', '擂台', '灵力', '碎开', '冰凉', '台阶', '九幽宗', '雪谷',
        '炼体术', 'MVP', '12345', 'vx:', '“', '。”', '，', 'M', '1',
        '九幽', '幽宗', '嘴', '勾起一抹',
      ];
      final TextIndex index = TextIndex(text);
      for (final String w in present) {
        expect(text.contains(w), isTrue, reason: '用例前提：$w 应在文本里');
        expect(index.mayContain(w), isTrue, reason: '不许漏判：$w');
      }
    });

    test('空串保守放行', () {
      expect(TextIndex(text).mayContain(''), isTrue);
    });

    test('空文本不报命中（除空串外全部挡掉）', () {
      final TextIndex empty = TextIndex('');
      expect(empty.mayContain('陈默'), isFalse);
      expect(empty.mayContain('，'), isFalse);
      expect(empty.mayContain(''), isTrue);
    });

    test('不在文中的词被挡掉（含「首字都在、但组合不在」的诱饵）', () {
      final TextIndex index = TextIndex(text);
      // 首字「陈」在文中，「陈默」也在，但「陈」+「宗」这个组合不在。
      expect(index.mayContain('陈宗'), isFalse);
      // 尾字在文中、首二元组不在。
      expect(index.mayContain('默陈'), isFalse);
      // 词表以外的词。
      expect(index.mayContain('幽冥殿'), isFalse);
      expect(index.mayContain('z'), isFalse);
    });

    test('穷举比对：小样本全子串不得出现漏判', () {
      const String src = '甲乙丙丁甲乙甲丁';
      final TextIndex index = TextIndex(src);
      final Set<String> alphabet = <String>{'甲', '乙', '丙', '丁', '戊'};
      final List<String> words = <String>[];
      for (final String a in alphabet) {
        words.add(a);
        for (final String b in alphabet) {
          words.add('$a$b');
          for (final String c in alphabet) {
            words.add('$a$b$c');
          }
        }
      }
      for (final String w in words) {
        if (src.contains(w)) {
          expect(index.mayContain(w), isTrue, reason: '漏判：$w');
        }
      }
    });
  });
}
