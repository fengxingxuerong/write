import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/world_setting.dart';

/// 覆盖：记忆管线依赖 `==` 判断「是否值得重写落库」，
/// 保证 copyWith 全同字段时值相等（缺省身份比较会导致恒不等 → 写放大）；
/// 任一字段变化时值不等；相等对象的 hashCode 一致。
void main() {
  group('Character 值语义', () {
    const Character base = Character(
      id: 'c1',
      novelId: 'n1',
      name: '林晚',
      role: '女主',
      traits: '冷静',
      background: '出身医学世家',
      relationships: '与男主青梅竹马',
      dialogueStyle: '寡言',
    );

    test('copyWith 全同字段与原型相等（记忆管线去重前提）', () {
      final Character merged = base.copyWith();
      expect(merged, equals(base));
    });

    test('任一字段变化即不相等', () {
      expect(base.copyWith(name: '林晚晚'), isNot(equals(base)));
      expect(base.copyWith(traits: '急躁'), isNot(equals(base)));
      expect(base.copyWith(dialogueStyle: ''), isNot(equals(base)));
      expect(base.copyWith(id: 'c2'), isNot(equals(base)));
      expect(base.copyWith(novelId: 'n2'), isNot(equals(base)));
    });

    test('相等对象 hashCode 一致（Set/Map 可去重）', () {
      expect(base.copyWith().hashCode, base.hashCode);
    });

    test('与非 Character 类型不相等', () {
      expect(base == Object(), isFalse);
      expect(base == const Character(
            id: 'c1',
            novelId: 'n1',
            name: '林晚',
            role: '女主',
            traits: '冷静',
            background: '出身医学世家',
            relationships: '与男主青梅竹马',
          ),
          isFalse);
    });
  });

  group('WorldSetting 值语义', () {
    const WorldSetting base = WorldSetting(
      id: 'w1',
      novelId: 'n1',
      title: '九州',
      category: '地图',
      content: '五国并立，灵力为尊',
    );

    test('copyWith 全同字段与原型相等', () {
      expect(base.copyWith(), equals(base));
    });

    test('任一字段变化即不相等', () {
      expect(base.copyWith(title: '八荒'), isNot(equals(base)));
      expect(base.copyWith(content: '五国并立'), isNot(equals(base)));
      expect(base.copyWith(id: 'w2'), isNot(equals(base)));
    });

    test('相等对象 hashCode 一致', () {
      expect(base.copyWith().hashCode, base.hashCode);
    });
  });
}