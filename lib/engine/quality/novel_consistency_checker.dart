import 'dart:math' as math;

import 'package:characters/characters.dart';

import 'package:novel_writer/models/chapter.dart';

/// 跨章节一致性检查结果。
class ConsistencyReport {
  /// 构造。
  const ConsistencyReport({
    this.nameIssues = const <NameIssue>[],
    this.worldIssues = const <WorldIssue>[],
    this.plotIssues = const <PlotIssue>[],
  });

  /// 人名不一致问题。
  final List<NameIssue> nameIssues;

  /// 世界观设定冲突。
  final List<WorldIssue> worldIssues;

  /// 剧情逻辑矛盾。
  final List<PlotIssue> plotIssues;

  /// 总问题数。
  int get totalIssues =>
      nameIssues.length + worldIssues.length + plotIssues.length;

  /// 是否有问题。
  bool get hasIssues => totalIssues > 0;

  /// 人类可读摘要。
  String get summary {
    if (!hasIssues) return '一致性检测通过，未发现跨章矛盾。';
    return '检测到 $totalIssues 处跨章矛盾：'
        '人名 ${nameIssues.length} 处、'
        '世界观 ${worldIssues.length} 处、'
        '剧情 ${plotIssues.length} 处。';
  }
}

/// 人名不一致。
class NameIssue {
  /// 构造。
  const NameIssue({
    this.nameA,
    this.chapterA,
    this.nameB,
    this.chapterB,
    required this.reason,
    this.recommendation,
  });

  /// 第一个名称。
  final String? nameA;

  /// 第一个名称出现的章节。
  final int? chapterA;

  /// 第二个名称。
  final String? nameB;

  /// 第二个名称出现的章节。
  final int? chapterB;

  /// 问题描述。
  final String reason;

  /// 修复建议。
  final String? recommendation;
}

/// 世界观冲突。
class WorldIssue {
  /// 构造。
  const WorldIssue({
    required this.chapterX,
    required this.sentenceX,
    required this.chapterY,
    required this.sentenceY,
    required this.reason,
  });

  /// 章节 X。
  final int chapterX;

  /// X 中的句子。
  final String sentenceX;

  /// 章节 Y。
  final int chapterY;

  /// Y 中的句子。
  final String sentenceY;

  /// 问题描述。
  final String reason;
}

/// 剧情矛盾。
class PlotIssue {
  /// 构造。
  const PlotIssue({
    required this.chapterX,
    required this.sentenceX,
    required this.chapterY,
    required this.sentenceY,
    required this.reason,
  });

  final int chapterX;
  final String sentenceX;
  final int chapterY;
  final String sentenceY;
  final String reason;
}

/// 跨章节一致性检查器（本地算法 + 正则推理，无需 LLM）。
///
/// 检测三类常见问题：
/// 1. 同一角色在不同章节名字不同（别字/混用/临时改名未说明）
/// 2. 世界观基础设定前后矛盾（灵气是否存在/修炼体系/货币/地名）
/// 3. 剧情逻辑冲突（角色已死又出现、师父变徒弟等）
class NovelConsistencyChecker {
  /// 私有构造。
  const NovelConsistencyChecker._();

  /// 对整本小说运行一致性检查。
  static ConsistencyReport check(List<Chapter> chapters) {
    // 按 order 排序后逐章分析。
    final List<Chapter> sorted = List<Chapter>.from(chapters)
      ..sort((a, b) => a.order.compareTo(b.order));

    return ConsistencyReport(
      nameIssues: _checkNames(sorted),
      worldIssues: _checkWorldSettings(sorted),
      plotIssues: _checkPlot(sorted),
    );
  }

  /// ============================================================
  /// 1. 人名一致性：找类似名字（编辑距离 ≤ 1）
  /// ============================================================
  static List<NameIssue> _checkNames(List<Chapter> chapters) {
    // 候选名提取：每章找出 2~4 字"人名模式"高频词。
    // 简化：按"姓氏 + 1~3 字"列出在 ≥ 2 章中出现的 token。
    final Map<String, _NameTracker> tracker = <String, _NameTracker>{};

    for (final Chapter ch in chapters) {
      final Set<String> namesInChapter = _extractPersonNames(ch.content);
      for (final String name in namesInChapter) {
        tracker.putIfAbsent(name, () => _NameTracker(name, <int>{}))
            .chapters.add(ch.order);
      }
    }

    // 两两比对：编辑距离 ≤ 1 的两个名字若都跨章出现 → 疑似统一人名笔误
    final List<NameIssue> issues = <NameIssue>[];
    final List<String> names = tracker.keys.toList();
    for (int i = 0; i < names.length; i++) {
      for (int j = i + 1; j < names.length; j++) {
        if (_editDistance(names[i], names[j]) == 1) {
          final _NameTracker a = tracker[names[i]]!;
          final _NameTracker b = tracker[names[j]]!;
          // 两边都跨至少 2 章 → 更可能是笔误
          if (a.chapters.length >= 2 && b.chapters.length >= 2) {
            issues.add(NameIssue(
              nameA: a.name,
              chapterA: a.chapters.first,
              nameB: b.name,
              chapterB: b.chapters.first,
              reason: '「${a.name}」与「${b.name}」仅差一字，疑为同一人名笔误',
              recommendation: '确认正确名字，全书统一',
            ));
          }
        }
      }
    }
    return issues;
  }

  /// 提取可能的人名 token（2~4 字 CJK 高频片段 + 上下文线索）。
  /// 简化：连续 2~4 个 CJK 且不在停用表的片段，且出现 ≥ 2 次，视为候选。
  static Set<String> _extractPersonNames(String text) {
    final Map<String, int> freq = <String, int>{};
    final List<String> chars = text.characters.toList();

    // 第一遍：纯频次统计（不依赖上下文）。
    for (int len = 2; len <= 4; len++) {
      for (int i = 0; i <= chars.length - len; i++) {
        final String token = chars.sublist(i, i + len).join();
        if (!_allCjk(token)) continue;
        if (_isStopName(token)) continue;
        freq[token] = (freq[token] ?? 0) + 1;
      }
    }

    // 第二遍：对频次 ≥ 2 的候选检查是否有上下文线索（任一出现位置即可）。
    final Set<String> candidates = <String>{};
    for (final MapEntry<String, int> e in freq.entries) {
      if (e.value < 2) continue;
      final List<String> contentChars = text.characters.toList();
      // 遍历所有出现位置，任一位置上下文成立即采纳
      int searchFrom = 0;
      while (true) {
        final int idx = text.indexOf(e.key, searchFrom);
        if (idx < 0) break;
        if (_byteIndexToCharPos(text, idx) >= 0 &&
            _hasNameContext(
                contentChars, _byteIndexToCharPos(text, idx), e.key.characters.length)) {
          candidates.add(e.key);
          break;
        }
        searchFrom = idx + 1;
      }
    }
    return candidates;
  }

  /// String.indexOf 返回 UTF-16 code unit 偏移，需转换到 characters 索引。
  static int _byteIndexToCharPos(String text, int byteIndex) {
    if (byteIndex <= 0) return 0;
    int codeUnitCount = 0;
    int charPos = 0;
    for (final String ch in text.characters) {
      if (codeUnitCount >= byteIndex) return charPos;
      codeUnitCount += ch.length;
      charPos++;
    }
    return charPos;
  }

  /// 片段周围是否有"称呼上下文"（前缀后缀线索）。
  static bool _hasNameContext(List<String> chars, int start, int len) {
    // 前缀线索：姓氏 / 小 / 老
    if (start > 0) {
      final String prev = chars[start - 1];
      if (prev == '小' || prev == '老' || _isSurname(prev)) return true;
    }
    // 后缀线索：说/道/笑/看/来/去/走/回/进/出/站/坐
    final int after = start + len;
    if (after < chars.length) {
      final String next = chars[after];
      if (<String>[
        '说', '道', '笑', '看', '来', '去', '走', '回', '进', '出', '站',
        '坐', '叫', '问', '想', '听', '吃', '喝', '躺', '跪', '飞',
      ].contains(next)) {
        return true;
      }
    }
    return false;
  }

  /// ============================================================
  /// 2. 世界观设定冲突：找否定模式反转（"有 X" vs "没有 X"）
  /// ============================================================
  static List<WorldIssue> _checkWorldSettings(List<Chapter> chapters) {
    final List<WorldIssue> issues = <WorldIssue>[];

    // 关键设定关键词表
    const List<String> keywords = <String>[
      '灵气', '斗气', '魔力', '元力', '真元', '灵石', '炼气', '筑基',
      '金丹', '宗门', '大陆', '帝国',
    ];

    // 提取每章关键句：含关键词及否定词的句子
    final Map<int, List<_Claim>> claims = <int, List<_Claim>>{};
    for (final Chapter ch in chapters) {
      final List<_Claim> chClaims = <_Claim>[];
      final List<String> sentences = ch.content.split(RegExp(r'[。！？\n]+'));
      for (final String sent in sentences) {
        for (final String kw in keywords) {
          if (sent.contains(kw)) {
            final bool negated = _isNegated(sent, kw);
            chClaims.add(_Claim(sentence: sent, keyword: kw, negated: negated));
          }
        }
      }
      claims[ch.order] = chClaims;
    }

    // 跨章节比对同一 keyword 的否定/肯定是否冲突
    for (int i = 0; i < chapters.length; i++) {
      for (int j = i + 1; j < chapters.length; j++) {
        final int oi = chapters[i].order;
        final int oj = chapters[j].order;
        for (final _Claim ci in claims[oi] ?? <_Claim>[]) {
          for (final _Claim cj in claims[oj] ?? <_Claim>[]) {
            if (ci.keyword == cj.keyword && ci.negated != cj.negated) {
              issues.add(WorldIssue(
                chapterX: oi,
                sentenceX: ci.sentence,
                chapterY: oj,
                sentenceY: cj.sentence,
                reason:
                    '第 $oi 章「${ci.keyword}」(${ci.negated ? "否定" : "肯定"}) '
                    '与第 $oj 章「${cj.keyword}」(${cj.negated ? "否定" : "肯定"})设定相反',
              ));
              // 每对 keyword 只报一次，避免爆炸
              break;
            }
          }
        }
      }
    }
    return issues.take(10).toList(); // 限制数量避免溢出
  }

  /// ============================================================
  /// 3. 剧情矛盾：检测已死角色/已发生事件的时间线反转
  /// ============================================================
  static List<PlotIssue> _checkPlot(List<Chapter> chapters) {
    final List<PlotIssue> issues = <PlotIssue>[];

    // 死/活/伤 状态动词的正则
    const List<String> deathPatterns = <String>['死', '牺牲', '陨落', '殒命', '身亡', '毙命'];

    for (int i = 0; i < chapters.length; i++) {
      for (int j = i + 1; j < chapters.length; j++) {
        final Chapter a = chapters[i];
        final Chapter b = chapters[j];
        // 检查 A 中的死角色 在 B 中是否还活着（直接出现且无复活/回忆标记）
        final Set<String> deadInA = _extractDeadCharacters(a.content, deathPatterns);
        for (final String name in deadInA) {
          // B 含此人 + 活的标记，且无"回忆""墓""灵位"等标记 → 报错
          if (b.content.contains(name) && !_hasFlashbackTag(b.content)) {
            issues.add(PlotIssue(
              chapterX: a.order,
              sentenceX: '第 ${a.order} 章「$name」已死',
              chapterY: b.order,
              sentenceY: '第 ${b.order} 章「$name」出现（无复活/回忆标记）',
              reason: '「$name」在第 ${a.order} 章已死亡，但第 ${b.order} 章仍作为活人出现',
            ));
            if (issues.length >= 5) return issues; // 限制数量
          }
        }
      }
    }
    return issues;
  }

  /// 提取某章中"已死"的角色名（XX 死了 / 杀死了 XX）。
  static Set<String> _extractDeadCharacters(
      String content, List<String> patterns) {
    final Set<String> result = <String>{};
    for (final String pat in patterns) {
      // 搜索所有出现位置
      int searchFrom = 0;
      while (true) {
        final int idx = content.indexOf(pat, searchFrom);
        if (idx < 0) break;
        // 取该位置之前的 15 字符作窗口
        final int from = math.max(0, idx - 15);
        final String window = content.substring(from, idx);
        final List<String> chars = window.characters.toList();
        // 依次从前向后滑动，寻找可能的 CJK 2~4 字人名候选
        for (int startPos = 0; startPos < chars.length; startPos++) {
          for (int len = 2; len <= 4 && startPos + len <= chars.length; len++) {
            final String candidate = chars.sublist(startPos, startPos + len).join();
            if (_allCjk(candidate) && !_isStopName(candidate)) {
              result.add(candidate);
            }
          }
        }
        searchFrom = idx + 1;
      }
    }
    return result;
  }

  /// 判断句子是否含有回忆/过去标记（闪回时出现的死人不算矛盾）。
  static bool _hasFlashbackTag(String content) {
    const List<String> tags = <String>['回忆', '想起', '过去', '曾经', '那时', '当年',
      '墓', '灵位', '遗像', '梦中', '幻觉'];
    return tags.any((String t) => content.contains(t));
  }

  /// ============================================================
  /// 工具方法
  /// ============================================================

  /// Levenshtein 编辑距离。
  static int _editDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final List<int> prev = List<int>.generate(b.length + 1, (int i) => i);
    final List<int> curr = List<int>.filled(b.length + 1, 0);
    for (int i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (int j = 1; j <= b.length; j++) {
        final int cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = math.min(math.min(curr[j - 1] + 1, prev[j] + 1),
            prev[j - 1] + cost);
      }
      for (int j = 0; j <= b.length; j++) {
        prev[j] = curr[j];
      }
    }
    return curr[b.length];
  }

  /// 判断字符串是否全部由 CJK 构成。
  static bool _allCjk(String s) {
    for (final String ch in s.characters) {
      final int c = ch.codeUnitAt(0);
      final bool isCjk =
          (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF);
      if (!isCjk) return false;
    }
    return true;
  }

  /// 名字停用词（明显不是名字的 2~4 字组合）。
  static bool _isStopName(String s) {
    const Set<String> stops = <String>{
      '自己', '什么', '这个', '那个', '他们', '她们', '我们', '你们',
      '可是', '但是', '然后', '只是', '所以', '因为', '虽然',
      '不是', '已经', '可以', '没', '有',
    };
    return stops.contains(s);
  }

  /// 常用姓氏（简化表）。
  static final Set<String> _surnames = <String>{
    '赵', '钱', '孙', '李', '周', '吴', '郑', '王', '冯', '陈',
    '褚', '卫', '蒋', '沈', '韩', '杨', '朱', '秦', '尤', '许',
    '何', '吕', '施', '张', '孔', '曹', '严', '华', '金', '魏',
    '陶', '姜', '戚', '谢', '邹', '苏', '潘', '葛', '范', '彭',
    '郎', '鲁', '马', '苗', '凤', '花', '方', '俞', '任', '袁',
    '柳', '唐', '罗', '薛', '雷', '贺', '倪', '汤', '滕', '殷',
    '毕', '郝', '安', '常', '乐', '于', '时', '傅', '皮',
    '齐', '康', '伍', '余', '元', '卜', '顾', '孟', '平', '黄',
    '和', '穆', '萧', '尹', '司马', '上官', '欧阳', '诸葛',
  };

  static bool _isSurname(String s) => _surnames.contains(s);

  /// 句子是否为否定形式（关键 setting 前有 "不"/"没"/"无"/"没有"）。
  static bool _isNegated(String sentence, String keyword) {
    final int idx = sentence.indexOf(keyword);
    if (idx < 0) return false;
    // 取关键词前 6 字符看是否有否定词
    final int from = math.max(0, idx - 6);
    final String prefix = sentence.substring(from, idx);
    const List<String> negs = <String>['不', '没', '无', '没有', '并未', '不曾', '决不', '毫无'];
    return negs.any((String n) => prefix.contains(n));
  }
}

/// 追踪某名字出现的章节。
class _NameTracker {
  _NameTracker(this.name, this.chapters);
  final String name;
  final Set<int> chapters;
}

/// 某章节中关于关键词的一条主张。
class _Claim {
  const _Claim({
    required this.sentence,
    required this.keyword,
    required this.negated,
  });
  final String sentence;
  final String keyword;
  final bool negated;
}
