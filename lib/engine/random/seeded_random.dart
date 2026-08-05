/// 可控（种子化）伪随机数发生器。
///
/// 采用 Mulberry32 算法，保证**同种子同输出**，跨平台可复现，
/// 便于「重生成 / 调试」。不依赖 Dart 自带 [Random]，避免不同 VM 版本间差异。
///
/// [randomLevel]（0~1）由上层映射为种子扰动，实现「保守↔随机」的可控随机。
class SeededRandom {
  int _state;

  /// 以整数种子构造。负种子会被规范到 32 位无符号范围。
  SeededRandom({int seed = 0}) : _state = seed & 0xFFFFFFFF;

  /// 返回 [0, 1) 区间的浮点数。
  double next() {
    _state = (_state + 0x6D2B79F5) & 0xFFFFFFFF;
    int z = _state;
    z = ((z ^ (z >> 15)) * (1 | z)) & 0xFFFFFFFF;
    z ^= z + ((z ^ (z >> 7)) * (61 | z)) & 0xFFFFFFFF;
    z ^= z >> 14;
    return (z >>> 0) / 4294967296;
  }

  /// 返回 [min, max) 区间的整数；若 max <= min 则返回 min。
  int range(int min, int max) {
    if (max <= min) return min;
    return min + (next() * (max - min)).floor();
  }

  /// 从列表中随机取一个元素。列表为空时抛 [StateError]。
  T pick<T>(List<T> items) {
    if (items.isEmpty) {
      throw StateError('SeededRandom.pick：列表为空，无法取样');
    }
    return items[range(0, items.length)];
  }

  /// 以概率 [p]（0~1）返回 true。
  bool chance(double p) => next() < p;
}
