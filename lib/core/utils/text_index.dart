/// 大词表 × 长文本的「会不会命中」预筛索引。
///
/// 适用场景：本工程多处要拿几十~上百个词把整章正文扫一遍数命中
/// （爽点词表 / 变强异动词表 / AI 味词表 / 敏感词库 / 现代词漂移词表…）。
/// 旧写法是每个词各自 `indexOf` 扫全文，代价是 O(词数 × 文本长)——实测
/// 20 章样本里 `thrillPerThousand` 一项就占全书体检的 11%（52.5ms/60 次）。
///
/// 这里先对文本做一遍 O(文本长) 的建索引（出现过的码元 + 相邻码元对），
/// 之后每个词只花 O(1) 判断「首码元或首二元组不在文中 → 必然不命中」，
/// 把绝大多数词直接挡掉；命中判定与计数循环本身保持原样，**口径零变化**。
///
/// 安全契约：`mayContain(w) == false` 必然推出 `text.contains(w) == false`，
/// 即只可能多算（放行后再由原逻辑判定），绝不可能漏算。单测
/// `test/core/utils/text_index_test.dart` 用穷举比对钉住了这条契约。
///
/// 索引按 UTF-16 码元建立，与 `String.contains` / `indexOf` 的码元语义一致
/// （代理对按两个码元参与，不会把跨代理对的窗口误判为命中）。
class TextIndex {
  /// 对 [text] 建索引。
  TextIndex(String text) {
    final int n = text.length;
    if (n == 0) return;
    int prev = text.codeUnitAt(0);
    _units.add(prev);
    for (int i = 1; i < n; i++) {
      final int c = text.codeUnitAt(i);
      _units.add(c);
      _pairs.add((prev << 16) | c);
      prev = c;
    }
  }

  /// 文中出现过的码元。
  final Set<int> _units = <int>{};

  /// 文中出现过的相邻码元对（高 16 位前码元，低 16 位后码元）。
  final Set<int> _pairs = <int>{};

  /// [word] 是否**可能**出现在文本里（false = 一定不出现，调用方可直接跳过）。
  ///
  /// 空串返回 true：`indexOf('')` 恒为 0 这类边界交给调用方自己的空串守卫，
  /// 此处不做语义假设（保守放行）。
  bool mayContain(String word) {
    final int n = word.length;
    if (n == 0) return true;
    final int first = word.codeUnitAt(0);
    if (!_units.contains(first)) return false;
    if (n == 1) return true;
    if (!_units.contains(word.codeUnitAt(n - 1))) return false;
    return _pairs.contains((first << 16) | word.codeUnitAt(1));
  }
}
