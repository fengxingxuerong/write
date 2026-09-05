import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/core/errors/app_exceptions.dart';

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
    '暴力血腥': <String>[
      '碎尸', '肢解', '凌迟', '剥皮', '活埋', '分尸', '虐杀', '鞭尸',
      '开膛', '挖眼', '割喉', '斩首', '腰斩', '五马分尸', '千刀万剐',
      '人彘', '烹杀', '车裂', '炮烙', '剜心', '掏心', '剔骨', '拔指甲',
      '砍头', '枪决', '凌辱致死', '虐童', '家暴', '施暴', '围殴', '斗殴致死',
      '血肉模糊', '尸横遍野', '血流成河', '残肢断臂', '肠子', '脑浆',
    ],
    '色情低俗': <String>[
      '裸体', '裸照', '偷拍', '露点', '淫秽', '情色', '色情', '下体',
      '强奸', '轮奸', '迷奸', '乱伦', '嫖娼', '卖淫', '援交',
      '做爱', '性交', '口交', '自慰', '一夜情', '约炮', '发情', '春药',
      '淫荡', '骚货', '荡妇', '奶子', '生殖器', '阴部', '阴茎', '阴道',
      '儿童色情', '恋童',
    ],
    '脏话辱骂': <String>[
      '傻逼', '妈的', '操你妈', '草泥马', '去死', '贱人', '婊子',
      '王八蛋', '混蛋', '废物', '蠢货', '白痴',
      '他妈的', '去你妈的', '你妈逼', '煞笔', '沙雕', '脑残', '智障',
      '狗日的', '杂种', '畜生', '滚蛋', '滚开', '找死', '尼玛', '卧槽',
    ],
    '违法违规': <String>[
      '枪支', '贩毒', '吸毒', '冰毒', '海洛因', '制毒', '炸弹', '炸药',
      '杀人越货', '绑架', '诈骗', '洗钱', '赌博', '高利贷',
      '杀人放火', '持刀行凶', '投毒', '下毒', '枪支弹药', '军火', '走私',
      '偷税漏税', '传销', '非法集资', '校园贷', '裸贷', '代孕', '器官买卖',
      '人体试验', '邪教', '恐怖袭击', '制造恐慌',
    ],
    '广告引流': <String>[
      '加微信', '加qq', '私聊我', '扫码', '点击链接', 'vx:', 'qq群',
      '代写', '刷单', '兼职日结', '彩票', '博彩',
      '加V', '加vx', '威信', '薇信', '扣扣', '企鹅号', '公众号',
      '私信我', '联系我', '点击下方', '链接在评论区', '搜索关注', '关注领取',
      '免费领取', '限时秒杀', '进群领取',
    ],
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

  /// 构造服务。[_customPath] 为用户词 JSON 文件（可空，空则不持久化）。
  SensitiveWordsService({String? customPath, String? statsPath})
      : _customPath = customPath,
        _statsPath = statsPath {
    _loadCustom();
    _loadStats();
  }

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

  /// 添加用户词并持久化。
  Future<void> addCustomWord(String word) async {
    final String w = word.trim();
    if (w.isEmpty || _customWords.contains(w)) return;
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
  SensitiveCheckResult check(String text) {
    if (text.isEmpty) return const SensitiveCheckResult(<SensitiveHit>[]);
    final List<SensitiveHit> hits = <SensitiveHit>[];

    void scan(String word, String category) {
      if (word.isEmpty) return;
      int idx = text.indexOf(word);
      while (idx >= 0) {
        // 白名单校验：若命中位置的上下文匹配白名单正则 → 跳过
        if (_isWhitelisted(text, idx, word.length, word)) {
          idx = text.indexOf(word, idx + word.length);
          continue;
        }
        hits.add(SensitiveHit(
          word: word,
          category: category,
          start: idx,
          context: _contextAround(text, idx, word.length),
        ));
        idx = text.indexOf(word, idx + word.length);
      }
    }

    builtinWords.forEach((String category, List<String> words) {
      for (final String w in words) {
        scan(w, category);
      }
    });
    for (final String w in _customWords) {
      scan(w, '自定义');
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
