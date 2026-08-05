import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';

/// 写作目标 / 日更打卡数据。
///
/// 持久化为单 JSON：`{dailyGoal, startDate, streak, lastCheckDate, dailyLog}`。
/// - [dailyGoal] 每日目标字数（0 = 未设置目标）；
/// - [streak] 连续达标天数；
/// - [lastCheckDate] 最近一次打卡日期（yyyy-MM-dd）；
/// - [dailyLog] 日期 → 当日新增字数。
class WritingGoal {
  /// 每日目标字数（0 = 未设置）。
  final int dailyGoal;

  /// 目标开始日期。
  final DateTime startDate;

  /// 连续达标天数。
  final int streak;

  /// 最近一次达标日期（yyyy-MM-dd，用于断更判断）。
  final String lastCheckDate;

  /// 每日新增字数记录（date → words）。
  final Map<String, int> dailyLog;

  /// 构造目标。
  const WritingGoal({
    this.dailyGoal = 0,
    required this.startDate,
    this.streak = 0,
    this.lastCheckDate = '',
    this.dailyLog = const <String, int>{},
  });

  /// 从 JSON 反序列化。
  factory WritingGoal.fromJson(Map<String, dynamic> json) {
    return WritingGoal(
      dailyGoal: (json['dailyGoal'] as int?) ?? 0,
      startDate: DateTime.tryParse(json['startDate'] as String? ?? '') ??
          DateTime.now(),
      streak: (json['streak'] as int?) ?? 0,
      lastCheckDate: (json['lastCheckDate'] as String?) ?? '',
      dailyLog: (json['dailyLog'] as Map<String, dynamic>? ?? <String, dynamic>{})
          .map((k, v) => MapEntry<String, int>(k, (v as num?)?.toInt() ?? 0)),
    );
  }

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'dailyGoal': dailyGoal,
        'startDate': startDate.toIso8601String(),
        'streak': streak,
        'lastCheckDate': lastCheckDate,
        'dailyLog': dailyLog,
      };

  /// 不可变更新副本。
  WritingGoal copyWith({
    int? dailyGoal,
    DateTime? startDate,
    int? streak,
    String? lastCheckDate,
    Map<String, int>? dailyLog,
  }) {
    return WritingGoal(
      dailyGoal: dailyGoal ?? this.dailyGoal,
      startDate: startDate ?? this.startDate,
      streak: streak ?? this.streak,
      lastCheckDate: lastCheckDate ?? this.lastCheckDate,
      dailyLog: dailyLog ?? this.dailyLog,
    );
  }
}

/// 写作目标仓库：读写 [WritingGoal]（应用目录 goal.json）。
class GoalRepository {
  /// 构造仓库。
  GoalRepository(this.directoryPath);

  /// 应用数据目录。
  final String directoryPath;

  /// 目标文件路径。
  String get _filePath => '$directoryPath${_sep}goal.json';

  String get _sep => directoryPath.contains('\\') ? '\\' : '/';

  /// 读取目标（不存在返回默认）。
  Future<WritingGoal> load() async {
    final File file = File(_filePath);
    if (!await file.exists()) {
      return WritingGoal(startDate: DateTime.now());
    }
    try {
      final String raw = await file.readAsString();
      return WritingGoal.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      throw StorageException('写作目标读取失败', e);
    }
  }

  /// 保存目标。
  Future<void> save(WritingGoal goal) async {
    try {
      final File file = File(_filePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(goal.toJson()), flush: true);
    } catch (e) {
      throw StorageException('写作目标保存失败', e);
    }
  }

  /// 从章节列表统计每日新增字数并更新打卡状态。
  ///
  /// 规则：按章节 updatedAt 聚合当日新增字数（正文长度），
  /// 当日新增 ≥ dailyGoal 视为达标；连续达标 streak +1；
  /// 若昨天未达标（断更）则重置 streak。
  Future<WritingGoal> refreshFromChapters(
    Novel novel,
    WritingGoal goal,
  ) async {
    final DateTime today = DateTime.now();
    final String todayKey = _dateKey(today);
    // 聚合当日新增字数：取各章 updatedAt 为今天的正文长度之和。
    int todayWords = 0;
    for (final Chapter c in novel.chapters) {
      if (_dateKey(c.updatedAt) == todayKey) {
        todayWords += c.wordCount();
      }
    }
    final Map<String, int> log = Map<String, int>.from(goal.dailyLog);
    log[todayKey] = todayWords;

    // 断更判断：昨天有记录且未达标 → 重置 streak。
    final DateTime yesterday = today.subtract(const Duration(days: 1));
    final String yesterdayKey = _dateKey(yesterday);
    final int? yesterdayWords = log[yesterdayKey];
    int streak = goal.streak;
    if (goal.dailyGoal > 0 && yesterdayWords != null && yesterdayWords < goal.dailyGoal) {
      streak = 0;
    }
    // 今日达标 → streak +1。
    if (goal.dailyGoal > 0 && todayWords >= goal.dailyGoal) {
      final bool alreadyCounted =
          goal.lastCheckDate == todayKey && goal.streak == streak;
      if (!alreadyCounted) streak += 1;
      return goal.copyWith(
        dailyLog: log,
        streak: streak,
        lastCheckDate: todayKey,
      );
    }
    return goal.copyWith(dailyLog: log, streak: streak);
  }

  /// 格式化日期键（yyyy-MM-dd）。
  String _dateKey(DateTime dt) {
    final String m = dt.month.toString().padLeft(2, '0');
    final String d = dt.day.toString().padLeft(2, '0');
    return '${dt.year}-$m-$d';
  }
}
