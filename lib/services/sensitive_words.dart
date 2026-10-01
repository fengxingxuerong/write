import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/core/utils/text_index.dart';
import 'package:novel_writer/engine/quality/quality_rules.g.dart';

/// 敏感词命中。
class SensitiveHit {
  /// 命中的词。
  final String word;

  /// 分类。
  final String category;

  /// 在原文中的起始位置（字符索引）。
  final int start;

  /// 所在行的上下文（前后各取若干字符）。
  final String context;

  /// 构造命中。
  const SensitiveHit({
    required this.word,
    required this.category,
    required this.start,
    required this.context,
  });
}

/// 检测结果。
class SensitiveCheckResult {
  /// 命中列表（按位置排序）。
  final List<SensitiveHit> hits;

  /// 构造结果。
  const SensitiveCheckResult(this.hits);

  /// 是否干净（无命中）。
  bool get clean => hits.isEmpty;

  /// 总命中数。
  int get count => hits.length;

  /// 按分类统计（category → 数量）。
  Map<String, int> get byCategory {
    final Map<String, int> m = <String, int>{};
    for (final SensitiveHit h in hits) {
      m[h.category] = (m[h.category] ?? 0) + 1;
    }
    return m;
  }
}

/// 敏感词检测服务。
///
/// 纯本地词库匹配（零网络），用于发布前自查。词库分内置与用户自定义
/// 两部分：内置覆盖常见内容安全类别，用户词存本地 JSON 可扩展。
class SensitiveWordsService {
  /// 内置词库：类别 → 词列表。
  static const Map<String, List<String>> builtinWords = <String, List<String>>{
    '暴力血腥': QualityRules.sensitiveViolence,
    '色情低俗': QualityRules.sensitiveSexual,
    '脏话辱骂': QualityRules.sensitiveAbuse,
    '违法违规': QualityRules.sensitiveIllegal,
    '广告引流': QualityRules.sensitiveAds,
  };

  /// 上下文白名单：词 → 允许出现的正则（匹配时跳过命中）。
  ///
  /// 格式：key 为敏感词（必须出现在 [builtinWords] 中），
  /// value 为「命中词出现在该上下文时跳过」的正则。
  ///
  /// 适用场景：某些敏感词在小说叙事中可能以合法形式出现
  /// （如「赌博」作为场景道具、「绑架」作为案件描写、「鸦片」作为历史名词）。
  // RegExp 无 const 构造，只能 final。
  static final Map<String, RegExp> contextWhitelist = <String, RegExp>{
    // 赌博：场景道具（赌博场、赌博机、赌场）→ 纯叙事描写非教唆
    '赌博': RegExp(r'赌博[场机]'),
    // 绑架：案件描写（绑架案、绑架事件）→ 非教唆
    '绑架': RegExp(r'绑架[案事件]'),
    // 鸦片：历史名词（鸦片战争、鸦片贸易）→ 历史题材合法词
    '鸦片': RegExp(r'鸦片[战争贸易]'),
    // 卖淫：案件描写（卖淫案、卖淫团伙）→ 新闻报道式描写非教唆
    '卖淫': RegExp(r'卖淫[案团伙]'),
    // 嫖娼：案件描写（嫖娼被拘、嫖娼被抓）
    '嫖娼': RegExp(r'嫖娼[被处罚]'),
  };

  /// 用户自定义词（内存缓存；文件加载）。
  List<String> _customWords = <String>[];

  /// 用户词文件路径。
  final String? _customPath;

  /// 命中统计文件路径（可空，空则不持久化统计）。
  final String? _statsPath;

  /// 历史累计命中统计：词 → 累计命中次数。
  Map<String, int> _hitStats = <String, int>{};

  /// 构造服务。customPath 为用户词 JSON 文件（可空，空则不持久化）。
  SensitiveWordsService({this._customPath, this._statsPath}) {
    _loadCustom();
    _loadStats();
  }

  /// 内置词库的「原文 + 归一化」缓存（含所属类别，保持 builtinWords 的声明顺序）。
  ///
  /// 词库是 const、归一化是纯函数，算一次即可常驻；旧实现在**每次** `check` 里
  /// 对 ~130 个内置词逐个 `_normalize`（各建一次 StringBuffer 并 toLowerCase），
  /// 全书体检按章调用时纯属重复劳动（实测该项占闸门耗时 18%）。
  static final List<({String raw, String norm, String category})> _builtinNorm =
      <({String raw, String norm, String category})>[
    for (final MapEntry<String, List<String>> e in builtinWords.entries)
      for (final String w in e.value)
        (raw: w, norm: _normalize(w), category: e.key),
  ];

  /// 历史累计命中统计（只读快照，按次数降序）。
  Map<String, int> get hitStats => Map<String, int>.unmodifiable(_hitStats);

  /// 全部词（内置 + 自定义）。
  List<String> get allWords =>
      <String>[...builtinWords.values.expand((l) => l), ..._customWords];

  void _loadCustom() {
    if (_customPath == null) return;
    try {
      final File file = File(_customPath);
      if (!file.existsSync()) return;
      final String raw = file.readAsStringSync();
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      _customWords = list.whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    } catch (_) {
      // 加载失败忽略（用内置词库）。
    }
  }

  /// 归一化文本用于匹配：全角 ASCII → 半角、全角空格 → 空格、统一小写。
  ///
  /// 所有映射均为 1:1 字符（不改变字符数），因此归一化后的命中索引
  /// 可直接映射回原文位置，无需额外的索引重建。
  static String _normalize(String s) {
    final StringBuffer sb = StringBuffer();
    for (final int code in s.runes) {
      if (code >= 0xFF01 && code <= 0xFF5E) {
        sb.writeCharCode(code - 0xFEE0);
      } else if (code == 0x3000) {
        sb.write(' ');
      } else {
        sb.writeCharCode(code);
      }
    }
    return sb.toString().toLowerCase();
  }

  /// 添加用户词并持久化（按归一化结果去重）。
  Future<void> addCustomWord(String word) async {
    final String w = word.trim();
    if (w.isEmpty) return;
    final String norm = _normalize(w);
    if (_customWords.any((String x) => _normalize(x) == norm)) return;
    _customWords = <String>[..._customWords, w];
    await _saveCustom();
  }

  /// 移除用户词并持久化。
  Future<void> removeCustomWord(String word) async {
    _customWords = _customWords.where((w) => w != word).toList();
    await _saveCustom();
  }

  Future<void> _saveCustom() async {
    if (_customPath == null) return;
    try {
      final File file = File(_customPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_customWords), flush: true);
    } catch (e) {
      throw StorageException('自定义敏感词保存失败', e);
    }
  }

  void _loadStats() {
    if (_statsPath == null) return;
    try {
      final File file = File(_statsPath);
      if (!file.existsSync()) return;
      final String raw = file.readAsStringSync();
      final Map<String, dynamic> map =
          jsonDecode(raw) as Map<String, dynamic>;
      _hitStats = map.map((String k, dynamic v) =>
          MapEntry<String, int>(k, (v as num?)?.toInt() ?? 0));
    } catch (_) {
      // 统计加载失败忽略。
    }
  }

  Future<void> _saveStats() async {
    if (_statsPath == null) return;
    try {
      final File file = File(_statsPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_hitStats), flush: true);
    } catch (_) {
      // 统计保存失败不影响主流程。
    }
  }

  /// 记录本次命中到历史统计并落盘（不等待）。
  /// 内存统计始终累计；仅当配置了 [statsPath] 时才持久化。
  void recordStats(SensitiveCheckResult result) {
    for (final SensitiveHit h in result.hits) {
      _hitStats[h.word] = (_hitStats[h.word] ?? 0) + 1;
    }
    if (_statsPath != null) {
      unawaited(_saveStats());
    }
  }

  /// 检测文本中的敏感词。
  ///
  /// 匹配前对文本与词表做大小写/全半角归一化（1:1 字符映射，索引不漂移），
  /// 因此「ＶＸ：」也能命中内置词「vx:」，但存储原文与词表原文均不被改写。
  SensitiveCheckResult check(String text) {
    if (text.isEmpty) return const SensitiveCheckResult(<SensitiveHit>[]);
    final String normText = _normalize(text);
    // 归一化文本的码元/二元组索引：130 个内置词里绝大多数首二元组根本不在文中，
    // 先 O(1) 挡掉，避免逐词 indexOf 扫全文（口径与命中顺序都不变）。
    final TextIndex index = TextIndex(normText);
    final List<SensitiveHit> hits = <SensitiveHit>[];

    void scan(String word, String normWord, String category) {
      if (word.isEmpty || normWord.isEmpty) return;
      if (!index.mayContain(normWord)) return;
      int idx = normText.indexOf(normWord);
      while (idx >= 0) {
        // 白名单校验用原文（归一化为 1:1 映射，索引一致）。
        if (_isWhitelisted(text, idx, word.length, word)) {
          idx = normText.indexOf(normWord, idx + normWord.length);
          continue;
        }
        hits.add(SensitiveHit(
          word: word,
          category: category,
          start: idx,
          context: _contextAround(text, idx, word.length),
        ));
        idx = normText.indexOf(normWord, idx + normWord.length);
      }
    }

    for (final ({String raw, String norm, String category}) w in _builtinNorm) {
      scan(w.raw, w.norm, w.category);
    }
    for (final String w in _customWords) {
      scan(w, _normalize(w), '自定义');
    }
    hits.sort((a, b) => a.start.compareTo(b.start));
    return SensitiveCheckResult(hits);
  }

  /// 判断命中 [word] 在 [text] 的 [start] 位置是否被上下文白名单覆盖。
  ///
  /// 规则：在命中词前后各 6 字符窗口内拼接出上下文片段，若 [word] 注册了
  /// 白名单正则且匹配该片段 → 返回 true（跳过命中）。
  static bool _isWhitelisted(
      String text, int start, int len, String word) {
    final RegExp? rule = contextWhitelist[word];
    if (rule == null) return false;
    final int from = start - 6 < 0 ? 0 : start - 6;
    final int to = start + len + 6 > text.length ? text.length : start + len + 6;
    final String window = text.substring(from, to);
    return rule.hasMatch(window);
  }

  /// 取命中词附近的上下文（前后各 12 字符，用 … 截断）。
  String _contextAround(String text, int start, int len) {
    final int from = start - 12 < 0 ? 0 : start - 12;
    final int to = start + len + 12 > text.length ? text.length : start + len + 12;
    final String prefix = from > 0 ? '…' : '';
    final String suffix = to < text.length ? '…' : '';
    return '$prefix${text.substring(from, to)}$suffix';
  }
}
