import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/random/seeded_random.dart';

/// SeededRandom 单元测试
///
/// 覆盖：同种子可复现、next/range/pick/chance 行为、越界与异常。
void main() {
  group('SeededRandom 可复现性', () {
    test('相同种子产生相同序列', () {
      final a = SeededRandom(seed: 12345);
      final b = SeededRandom(seed: 12345);
      final seqA = List<double>.generate(20, (_) => a.next());
      final seqB = List<double>.generate(20, (_) => b.next());
      expect(seqA, equals(seqB));
    });

    test('不同种子产生不同序列', () {
      final a = SeededRandom(seed: 1);
      final b = SeededRandom(seed: 2);
      final seqA = List<double>.generate(20, (_) => a.next());
      final seqB = List<double>.generate(20, (_) => b.next());
      expect(seqA, isNot(equals(seqB)));
    });

    test('next() 取值范围在 [0, 1)', () {
      final rng = SeededRandom(seed: 999);
      for (var i = 0; i < 1000; i++) {
        final v = rng.next();
        expect(v, greaterThanOrEqualTo(0.0));
        expect(v, lessThan(1.0));
      }
    });

    test('负种子被规范到 32 位无符号范围且不抛异常', () {
      final rng = SeededRandom(seed: -1);
      final v = rng.next();
      expect(v, inInclusiveRange(0.0, 1.0));
    });
  });

  group('SeededRandom.range', () {
    test('返回 [min, max) 区间内整数', () {
      final rng = SeededRandom(seed: 7);
      for (var i = 0; i < 500; i++) {
        final v = rng.range(2, 5);
        expect(v, greaterThanOrEqualTo(2));
        expect(v, lessThan(5));
      }
    });

    test('max <= min 时返回 min', () {
      final rng = SeededRandom(seed: 7);
      expect(rng.range(5, 5), equals(5));
      expect(rng.range(10, 3), equals(10));
    });

    test('range 在相同种子下可复现', () {
      final a = SeededRandom(seed: 42);
      final b = SeededRandom(seed: 42);
      final seqA = List<int>.generate(50, (_) => a.range(0, 100));
      final seqB = List<int>.generate(50, (_) => b.range(0, 100));
      expect(seqA, equals(seqB));
    });
  });

  group('SeededRandom.pick', () {
    test('从列表中取样且可复现', () {
      final items = ['甲', '乙', '丙', '丁'];
      final a = SeededRandom(seed: 2024);
      final b = SeededRandom(seed: 2024);
      final pickA = List<String>.generate(30, (_) => a.pick(items));
      final pickB = List<String>.generate(30, (_) => b.pick(items));
      expect(pickA, equals(pickB));
    });

    test('空列表抛 StateError', () {
      final rng = SeededRandom(seed: 1);
      expect(() => rng.pick(<String>[]), throwsStateError);
    });
  });

  group('SeededRandom.chance', () {
    test('p=0 恒为 false，p=1 恒为 true', () {
      final rng = SeededRandom(seed: 55);
      expect(rng.chance(0.0), isFalse);
      expect(rng.chance(1.0), isTrue);
    });

    test('chance 序列可复现', () {
      final a = SeededRandom(seed: 88);
      final b = SeededRandom(seed: 88);
      final cA = List<bool>.generate(40, (_) => a.chance(0.5));
      final cB = List<bool>.generate(40, (_) => b.chance(0.5));
      expect(cA, equals(cB));
    });
  });
}
