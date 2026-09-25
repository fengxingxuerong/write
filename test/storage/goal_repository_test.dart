import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/errors/app_exceptions.dart';
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
    final Novel novel = novelWithChapters(<Chapter>[
      chapter('c1', 0, '一' * 1200, now),
    ], 'n1');
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
    final Novel novel = novelWithChapters(<Chapter>[
      chapter('c1', 0, '一' * 200, now),
    ], 'n1');
    final WritingGoal updated = await repo.refreshFromChapters(novel, base);
    expect(updated.streak, 5);
  });

  test('损坏 goal.json 抛 StorageException', () async {
    File('${tempDir.path}/goal.json').writeAsStringSync('{broken');
    await expectLater(repo.load(), throwsA(isA<StorageException>()));
  });

  test('goal.json 类型错误导致 load() 包装为 StorageException', () async {
    File(
      '${tempDir.path}/goal.json',
    ).writeAsStringSync('{"dailyGoal":"not-an-int"}');
    await expectLater(repo.load(), throwsA(isA<StorageException>()));
  });

  test('save 自动创建嵌套目录且成功后不残留 .tmp', () async {
    final Directory nested = Directory('${tempDir.path}/deep/app');
    final GoalRepository nestedRepo = GoalRepository(nested.path);
    final DateTime start = DateTime.now();
    await nestedRepo.save(WritingGoal(dailyGoal: 1234, startDate: start));
    expect(File('${nested.path}/goal.json').existsSync(), isTrue);
    expect(File('${nested.path}/goal.json.tmp').existsSync(), isFalse);
    expect((await nestedRepo.load()).dailyGoal, 1234);
  });

  test('dailyGoal=0 时刷新日志但不推进 streak', () async {
    final DateTime now = DateTime.now();
    final WritingGoal base = WritingGoal(
      dailyGoal: 0,
      startDate: now,
      streak: 9,
      lastCheckDate: '',
    );
    final Novel novel = novelWithChapters(<Chapter>[
      chapter('c1', 0, '一' * 50, now),
    ], 'n1');
    final WritingGoal updated = await repo.refreshFromChapters(novel, base);
    expect(updated.streak, 9);
    expect(updated.lastCheckDate, isEmpty);
    expect(updated.dailyLog[_key(now)], greaterThan(0));
  });

  test('WritingGoal.copyWith 只更新传入字段', () {
    final DateTime start = DateTime(2026, 1, 1);
    final WritingGoal base = WritingGoal(
      dailyGoal: 1000,
      startDate: start,
      streak: 4,
      lastCheckDate: '2026-07-30',
      dailyLog: const <String, int>{'2026-07-30': 1200},
    );

    final WritingGoal onlyGoal = base.copyWith(dailyGoal: 2500);
    expect(onlyGoal.dailyGoal, 2500);
    expect(onlyGoal.startDate, start);
    expect(onlyGoal.streak, 4);
    expect(onlyGoal.lastCheckDate, '2026-07-30');
    expect(onlyGoal.dailyLog, base.dailyLog);

    final DateTime nextStart = DateTime(2026, 8, 1);
    final WritingGoal reset = base.copyWith(
      startDate: nextStart,
      streak: 0,
      lastCheckDate: '',
      dailyLog: const <String, int>{},
    );
    expect(reset.startDate, nextStart);
    expect(reset.streak, 0);
    expect(reset.lastCheckDate, isEmpty);
    expect(reset.dailyLog, isEmpty);
    expect(reset.dailyGoal, 1000);
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
    final Novel novel = novelWithChapters(<Chapter>[
      chapter('c1', 0, '', now),
    ], 'n1');
    final WritingGoal updated = await repo.refreshFromChapters(novel, base);
    expect(updated.streak, 0);
  });
}

String _key(DateTime dt) {
  final String m = dt.month.toString().padLeft(2, '0');
  final String d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}
