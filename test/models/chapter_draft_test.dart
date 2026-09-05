import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/models/chapter_draft.dart';

/// ChapterDraft 模型单元测试
///
/// 覆盖：wordCount、序列化/反序列化、copyWith、字段默认值。

void main() {
  group('ChapterDraft.wordCount', () {
    test('中文按字符计', () {
      final draft = ChapterDraft(
        id: '1',
        novelId: 'n1',
        title: '测试',
        content: '今天天气很好',
        createdAt: DateTime.now(),
      );
      expect(draft.wordCount(), 6);
    });

    test('英文单词按空格分隔计', () {
      final draft = ChapterDraft(
        id: '1',
        novelId: 'n1',
        title: '测试',
        content: 'hello world test',
        createdAt: DateTime.now(),
      );
      // wordCount 只去除空白字符，保留所有非空白字符
      // "hello world test" 去除空格后 = "helloworldtest" = 14 字符
      expect(draft.wordCount(), 14);
    });

    test('空内容为 0', () {
      final draft = ChapterDraft(
        id: '1',
        novelId: 'n1',
        title: '测试',
        content: '',
        createdAt: DateTime.now(),
      );
      expect(draft.wordCount(), 0);
    });

    test('混合内容去除空白后计', () {
      final draft = ChapterDraft(
        id: '1',
        novelId: 'n1',
        title: '测试',
        content: '  中 文 和 English 混杂  ',
        createdAt: DateTime.now(),
      );
      // "中文和English混杂" = 12 字符
      expect(draft.wordCount(), 12);
    });
  });

  group('ChapterDraft 序列化', () {
    test('toJson 包含所有字段', () {
      final DateTime now = DateTime(2024, 1, 15, 10, 30);
      final draft = ChapterDraft(
        id: 'draft-1',
        novelId: 'novel-1',
        title: '草稿标题',
        content: '草稿内容',
        createdAt: now,
      );
      final json = draft.toJson();
      expect(json['id'], 'draft-1');
      expect(json['novelId'], 'novel-1');
      expect(json['title'], '草稿标题');
      expect(json['content'], '草稿内容');
      expect(json['createdAt'], now.toIso8601String());
    });

    test('fromJson 完整字段', () {
      final DateTime now = DateTime(2024, 6, 1, 12, 0);
      final json = {
        'id': 'd-1',
        'novelId': 'n-1',
        'title': '标题',
        'content': '正文内容',
        'createdAt': now.toIso8601String(),
      };
      final draft = ChapterDraft.fromJson(json);
      expect(draft.id, 'd-1');
      expect(draft.novelId, 'n-1');
      expect(draft.title, '标题');
      expect(draft.content, '正文内容');
      expect(draft.createdAt, now);
    });

    test('fromJson 缺失可选字段使用默认值', () {
      final json = {
        'id': 'd-1',
        'novelId': 'n-1',
        'createdAt': '2024-01-01T00:00:00.000',
      };
      final draft = ChapterDraft.fromJson(json);
      expect(draft.title, '');
      expect(draft.content, '');
    });

    test('toJson/fromJson 往返一致', () {
      final original = ChapterDraft(
        id: 'test-id',
        novelId: 'test-novel',
        title: '测试标题',
        content: '测试正文内容很长',
        createdAt: DateTime(2024, 3, 15, 8, 30),
      );
      final restored = ChapterDraft.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.novelId, original.novelId);
      expect(restored.title, original.title);
      expect(restored.content, original.content);
      expect(restored.createdAt, original.createdAt);
    });
  });

  group('ChapterDraft.copyWith', () {
    late ChapterDraft original;

    setUp(() {
      original = ChapterDraft(
        id: 'original-id',
        novelId: 'original-novel',
        title: '原标题',
        content: '原内容',
        createdAt: DateTime(2024, 1, 1),
      );
    });

    test('未传参返回等价副本', () {
      final copy = original.copyWith();
      expect(copy.id, original.id);
      expect(copy.novelId, original.novelId);
      expect(copy.title, original.title);
      expect(copy.content, original.content);
      expect(copy.createdAt, original.createdAt);
    });

    test('仅修改指定字段', () {
      final copy = original.copyWith(title: '新标题', content: '新内容');
      expect(copy.title, '新标题');
      expect(copy.content, '新内容');
      expect(copy.id, original.id);
      expect(copy.novelId, original.novelId);
      expect(copy.createdAt, original.createdAt);
    });
  });

  group('ChapterDraft 字段验证', () {
    test('id 和 novelId 为必需字段', () {
      final draft = ChapterDraft(
        id: 'unique-id',
        novelId: 'novel-id',
        title: '',
        content: '',
        createdAt: DateTime.now(),
      );
      expect(draft.id, 'unique-id');
      expect(draft.novelId, 'novel-id');
    });
  });
}
