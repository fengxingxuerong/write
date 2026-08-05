import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/models/generation_config.dart';

/// 约束控制器：在生成过程中执行字数上限与重复抑制等规则。
///
/// 数据载体 [GenerationConstraints] 定义在 `models/generation_config.dart`；
/// 本类负责「约束控制」逻辑，供 [TemplateEngine] 在 Isolate 中调用。
class ConstraintController {
  /// 构造控制器。
  const ConstraintController(this.constraints);

  /// 约束数据。
  final GenerationConstraints constraints;

  /// 单章硬上限（性能安全线）。
  int get maxWords => constraints.maxWordsPerChapter;

  /// 当前字数是否仍在允许范围内（可继续生成）。
  bool canContinue(int currentWords) => currentWords < maxWords;

  /// 将文本裁剪到不超过字数上限，并尽量在句末断开（最后的标点处）。
  ///
  /// 作为生成主循环的**安全兜底**：主循环每句后已用精确 [AppConstants.countWords]
  /// 校验，此处仅在极端情况下二次截断，避免超出 20000 字上限。
  String truncate(String text, int limit) {
    if (AppConstants.countWords(text) <= limit) return text;
    final List<int> runes = text.runes.toList();
    final StringBuffer buffer = StringBuffer();
    int count = 0;
    for (int i = 0; i < runes.length; i++) {
      final String ch = String.fromCharCode(runes[i]);
      final int w = _charWeight(ch);
      if (count + w > limit) {
        break;
      }
      count += w;
      buffer.write(ch);
    }
    String result = buffer.toString();
    // 尽量在最近的句末标点处断开，避免出现半截句子。
    final int lastPunct = result.lastIndexOf(RegExp(r'[。！？」]'));
    if (lastPunct > result.length - 40 && lastPunct > 0) {
      result = result.substring(0, lastPunct + 1);
    }
    return result;
  }

  /// 单个字符的字数权重（CJK 计 1，ASCII 字母数字计 1，其余 0）。
  int _charWeight(String ch) {
    if (RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]').hasMatch(ch)) {
      return 1;
    }
    if (RegExp(r'[A-Za-z0-9]').hasMatch(ch)) return 1;
    return 0;
  }
}
