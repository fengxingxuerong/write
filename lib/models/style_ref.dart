/// 文风参考（P1-1 Dart 侧）：从一篇参考文抽出的**文风指纹**。
///
/// 与 Python 侧 `--style-ref` 存的东西同构：**只存九项分布数值，不存原文、
/// 不存可照抄的句子**——防「文风仿写」在数据层面就滑向「抄袭」。原文由用户自己
/// 保管，本项目只记「像哪一篇的文风」。
///
/// 指纹由调用方用 `PipelineQa.styleFingerprint(正文)` 现算后传入——本文件**不
/// import 质检层**：`models/` 不反向依赖 `ai_pipeline/`（否则与 pipeline_qa 对
/// `models/character.dart` 的依赖构成环）。
///
/// 键名与 `PipelineQa.styleFingerprintKeys` 一致（下划线风格），便于双端对账。
class StyleRef {
  /// 参考文来源标识（通常是文件名，注入提示词时显示为「《xxx》」）。
  final String source;

  /// 九项分布指标（见 `PipelineQa.styleFingerprintKeys`）。
  final Map<String, double> fingerprint;

  /// 导入时间。
  final DateTime savedAt;

  /// 构造。
  const StyleRef({
    required this.source,
    required this.fingerprint,
    required this.savedAt,
  });

  /// 参考文总字数（0 表示未取到指纹）。
  double get words => fingerprint['words'] ?? 0;

  /// 指纹有效所需的最小字数。
  ///
  /// 500 字以下句子样本太少，句长 CV / 段落均长等分布指标噪声过大，宁可不注入
  /// ——与 Python 侧 `load_style_block` 对空/过短文返回空串的降级语义一致。
  static const int minWords = 500;

  /// 是否是可用指纹（字数过少则分布无意义，视为无效）。
  bool get isUsable => words >= minWords;

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        'fingerprint': fingerprint,
        'savedAt': savedAt.toIso8601String(),
      };

  /// 反序列化；坏数据（缺键/类型错）一律返回 null。
  ///
  /// **不让一份脏数据毁掉整个项目的加载**——项目 JSON 是单文件聚合根，任一子结构
  /// 解析抛异常都会导致整本打不开。
  static StyleRef? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? src = raw['source'];
    final Object? fp = raw['fingerprint'];
    if (src is! String || fp is! Map) return null;
    final Map<String, double> out = <String, double>{};
    fp.forEach((Object? k, Object? v) {
      if (k is String && v is num) out[k] = v.toDouble();
    });
    DateTime saved = DateTime.fromMillisecondsSinceEpoch(0);
    final Object? at = raw['savedAt'];
    if (at is String) saved = DateTime.tryParse(at) ?? saved;
    return StyleRef(source: src, fingerprint: out, savedAt: saved);
  }

  @override
  String toString() => 'StyleRef($source, ${words.round()}字)';
}