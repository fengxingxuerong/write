import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/goal_repository.dart';

void main() {
  late Directory tempDir;
  late GoalRepository repo;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('goal_test_');
    repo = GoalRepository(tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Novel novelWithChapters(List<Chapter> chapters, String novelId) {
    return Novel(
      id: novelId,
      title: '测试书',
      genre: '玄幻',
      tone: '轻松',
      targetWordsPerChapter: 2000,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      characters: const [],
      worldSettings: const [],
      chapters: chapters,
    );
  }

  Chapter chapter(String id, int order, String content, DateTime updated) {
    return Chapter(
      id: id,
      novelId: 'n1',
      title: '第${order + 1}章',
      order: order,
      content: content,
      createdAt: updated,
      updatedAt: updated,
    );
  }

  test('默认目标：dailyGoal=0，未设置', () async {
    final WritingGoal goal = await repo.load();
    expect(goal.dailyGoal, 0);
    expect(goal.streak, 0);
  });

  test('保存 / 读取往返', () async {
    final WritingGoal goal = WritingGoal(
      dailyGoal: 2000,
      startDate: DateTime.now(),
      streak: 3,
      lastCheckDate: '2026-07-30',
      dailyLog: const <String, int>{'2026-07-30': 2100},
    );
    await repo.save(goal);
    final WritingGoal loaded = await repo.load();
    expect(loaded.dailyGoal, 2000);
    expect(loaded.streak, 3);
    expect(loaded.dailyLog['2026-07-30'], 2100);
  });

  test('今日达标 → streak +1', () async {
    final DateTime now = DateTime.now();
    final WritingGoal base = WritingGoal(
      dailyGoal: 1000,
      startDate: now,
      streak: 5,
      lastCheckDate: '2000-01-01', // 避免重复计数误判
    );
    final Novel novel = novelWithChapters(
      <Chapter>[chapter('c1', 0, '一' * 1200, now)],
      'n1',
    );
    final WritingGoal updated = await repo.refreshFromChapters(novel, base);
    expect(updated.streak, 6);
    expect(updated.lastCheckDate, isNotEmpty);
  });

  test('今日未达标 → streak 不变', () async {
    final DateTime now = DateTime.now();
    final WritingGoal base = WritingGoal(
      dailyGoal: 1000,
      startDate: now,
      streak: 5,
      lastCheckDate: '2000-01-01',
    );
    final Novel novel = novelWithChapters(
      <Chapter>[chapter('c1', 0, '一' * 200, now)],
      'n1',
    );
    final WritingGoal updated = await repo.refreshFromChapters(novel, base);
    expect(updated.streak, 5);
  });

  test('昨天断更 → 重置 streak', () async {
    final DateTime now = DateTime.now();
    final DateTime yesterday = now.subtract(const Duration(days: 1));
    final WritingGoal base = WritingGoal(
      dailyGoal: 1000,
      startDate: now,
      streak: 7,
      lastCheckDate: _key(now),
      dailyLog: <String, int>{
        _key(yesterday): 100, // 昨天未达标
        _key(now): 0,
      },
    );
    final Novel novel = novelWithChapters(
      <Chapter>[chapter('c1', 0, '', now)],
      'n1',
    );
    final WritingGoal updated = await repo.refreshFromChapters(novel, base);
    expect(updated.streak, 0);
  });
}

String _key(DateTime dt) {
  final String m = dt.month.toString().padLeft(2, '0');
  final String d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}
