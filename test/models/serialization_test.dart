import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/chapter_draft.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/export_prefs.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/reader_settings.dart';
import 'package:novel_writer/models/world_setting.dart';

/// 模型序列化单元测试
///
/// 覆盖：Novel / Chapter / Character / WorldSetting / GenerationConfig /
/// GenerationConstraints / GenrePreset / NovelSummary 的 toJson/fromJson 往返一致，
/// 以及缺字段时的默认值回退与 copyWith 不可变更新。
void main() {
  group('模型 toJson/fromJson 往返一致', () {
    test('Chapter', () {
      final c = Chapter(
        id: 'c1',
        novelId: 'n1',
        title: '第一章',
        order: 0,
        content: '这是正文内容。',
        createdAt: DateTime(2026, 1, 1, 12, 0, 0),
        updatedAt: DateTime(2026, 1, 2, 12, 0, 0),
      );
      final back = Chapter.fromJson(c.toJson());
      expect(back.id, equals(c.id));
      expect(back.novelId, equals(c.novelId));
      expect(back.title, equals(c.title));
      expect(back.order, equals(c.order));
      expect(back.content, equals(c.content));
      expect(back.createdAt, equals(c.createdAt));
      expect(back.updatedAt, equals(c.updatedAt));
    });

    test('Chapter 缺 content 回退空串', () {
      final back = Chapter.fromJson(<String, dynamic>{
        'id': 'c2',
        'novelId': 'n1',
        'title': '第二章',
        'order': 1,
        'createdAt': '2026-01-01T00:00:00.000',
        'updatedAt': '2026-01-01T00:00:00.000',
      });
      expect(back.content, equals(''));
    });

    test('Character', () {
      const ch = Character(
        id: 'ch1',
        novelId: 'n1',
        name: '云澈',
        role: '男主',
        traits: '坚毅',
        background: '废脉少年',
        relationships: '与苏璃为友',
        dialogueStyle: '寡言冷峻，说话简短有力',
      );
      final back = Character.fromJson(ch.toJson());
      expect(back.name, equals('云澈'));
      expect(back.role, equals('男主'));
      expect(back.traits, equals('坚毅'));
      expect(back.background, equals('废脉少年'));
      expect(back.relationships, equals('与苏璃为友'));
      expect(back.dialogueStyle, equals('寡言冷峻，说话简短有力'));
    });

    test('Character 缺字段回退空串', () {
      final back = Character.fromJson(<String, dynamic>{
        'id': 'ch2',
        'novelId': 'n1',
      });
      expect(back.name, equals(''));
      expect(back.dialogueStyle, equals(''));
    });

    test('WorldSetting', () {
      const w = WorldSetting(
        id: 'w1',
        novelId: 'n1',
        title: '修炼体系',
        category: '规则',
        content: '灵气充盈天地间。',
      );
      final back = WorldSetting.fromJson(w.toJson());
      expect(back.title, equals('修炼体系'));
      expect(back.category, equals('规则'));
      expect(back.content, equals('灵气充盈天地间。'));
    });

    test('GenerationConstraints', () {
      const c = GenerationConstraints(maxWordsPerChapter: 5000, allowRepeat: true);
      final back = GenerationConstraints.fromJson(c.toJson());
      expect(back.maxWordsPerChapter, equals(5000));
      expect(back.allowRepeat, isTrue);
    });

    test('GenerationConfig（含 constraints 嵌套）', () {
      const cfg = GenerationConfig(
        genre: 'xuanhuan',
        tone: '热血',
        targetWords: 3000,
        useExistingSettings: false,
        protagonistName: '林玄',
        randomLevel: 0.7,
        chapterCount: 5,
        volumeOutline: '逃离险境\n前往宗门',
        expandOutline: false,
        constraints: GenerationConstraints(maxWordsPerChapter: 15000),
      );
      final back = GenerationConfig.fromJson(cfg.toJson());
      expect(back.genre, equals('xuanhuan'));
      expect(back.tone, equals('热血'));
      expect(back.targetWords, equals(3000));
      expect(back.useExistingSettings, isFalse);
      expect(back.protagonistName, equals('林玄'));
      expect(back.randomLevel, equals(0.7));
      expect(back.chapterCount, equals(5));
      expect(back.volumeOutline, equals('逃离险境\n前往宗门'));
      expect(back.expandOutline, isFalse);
      expect(back.constraints.maxWordsPerChapter, equals(15000));
    });

    test('GenerationConfig 缺字段回退默认值', () {
      final back = GenerationConfig.fromJson(<String, dynamic>{
        'genre': 'dushi',
        'tone': '日常',
        'targetWords': 1000,
      });
      expect(back.useExistingSettings, isTrue);
      expect(back.protagonistName, isNull);
      expect(back.randomLevel, equals(0.5));
      expect(back.chapterCount, equals(1));
      expect(back.volumeOutline, isEmpty);
      expect(back.expandOutline, isTrue);
      expect(
        back.constraints.maxWordsPerChapter,
        equals(AppConstants.defaultMaxWordsPerChapter),
      );
    });

    test('GenrePreset', () {
      const p = GenrePreset(
        key: 'kehuan',
        label: '科幻',
        tones: ['硬核', '悬疑'],
        skeletonRef: {'起': '设定未来'},
      );
      final back = GenrePreset.fromJson(p.toJson());
      expect(back.key, equals('kehuan'));
      expect(back.label, equals('科幻'));
      expect(back.tones, equals(['硬核', '悬疑']));
      expect(back.skeletonRef['起'], equals('设定未来'));
    });

    test('Novel 聚合根（含章节/角色/世界观）', () {
      final novel = Novel(
        id: 'n1',
        title: '测试小说',
        genre: 'xuanhuan',
        tone: '热血',
        targetWordsPerChapter: 2000,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 3),
        chapters: [
          Chapter(
            id: 'c1',
            novelId: 'n1',
            title: '第一章',
            order: 0,
            content: '内容一。',
            createdAt: DateTime(2026, 1, 1),
            updatedAt: DateTime(2026, 1, 1),
          ),
          Chapter(
            id: 'c2',
            novelId: 'n1',
            title: '第二章',
            order: 1,
            content: '内容二。',
            createdAt: DateTime(2026, 1, 2),
            updatedAt: DateTime(2026, 1, 2),
          ),
        ],
        characters: [
          const Character(
            id: 'ch1',
            novelId: 'n1',
            name: '云澈',
            role: '男主',
            traits: '坚毅',
            background: '孤儿',
            relationships: '与师傅情同父子',
          ),
        ],
        worldSettings: [
          const WorldSetting(
            id: 'w1',
            novelId: 'n1',
            title: '修炼体系',
            category: '规则',
            content: '以灵气为基，分九重天',
          ),
        ],
      );
      final back = Novel.fromJson(novel.toJson());
      expect(back.archived, isFalse);
      expect(back.preferredStyle, equals('standard'));
      expect(back.preferredProseStyle, equals('web'));
      expect(back.id, equals('n1'));
      expect(back.title, equals('测试小说'));
      expect(back.chapters.length, equals(2));
      expect(back.chapters[1].title, equals('第二章'));
      expect(back.characters.first.name, equals('云澈'));
      expect(back.worldSettings.first.category, equals('规则'));
      expect(back.createdAt, equals(novel.createdAt));
      expect(back.updatedAt, equals(novel.updatedAt));
      expect(back.wordCount(), equals(novel.wordCount()));
    });

    test('Novel 缺字段回退默认值', () {
      final back = Novel.fromJson(<String, dynamic>{
        'id': 'n2',
        'title': '未命名',
        'createdAt': '2026-01-01T00:00:00.000',
        'updatedAt': '2026-01-01T00:00:00.000',
      });
      expect(back.genre, equals(AppConstants.defaultGenre));
      expect(back.tone, equals(AppConstants.defaultTone));
      expect(
        back.targetWordsPerChapter,
        equals(AppConstants.defaultMaxWordsPerChapter),
      );
      expect(back.chapters, isEmpty);
      expect(back.characters, isEmpty);
    });

    test('Novel 偏好风格/文风往返', () {
      final novel = Novel(
        id: 'n1',
        title: '测试小说',
        genre: 'xuanhuan',
        tone: '热血',
        targetWordsPerChapter: 2000,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 3),
        preferredStyle: 'crisp',
        preferredProseStyle: 'guluo',
        chapters: <Chapter>[],
        characters: <Character>[],
        worldSettings: <WorldSetting>[],
      );
      final back = Novel.fromJson(novel.toJson());
      expect(back.preferredStyle, equals('crisp'));
      expect(back.preferredProseStyle, equals('guluo'));
      // 缺字段回退默认。
      final fallback = Novel.fromJson(<String, dynamic>{
        'id': 'n2',
        'title': 'x',
        'genre': 'x',
        'tone': 'y',
        'targetWordsPerChapter': 2000,
        'createdAt': '2026-01-01T00:00:00.000',
        'updatedAt': '2026-01-01T00:00:00.000',
        'chapters': <dynamic>[],
        'characters': <dynamic>[],
        'worldSettings': <dynamic>[],
      });
      expect(fallback.preferredStyle, equals('standard'));
      expect(fallback.preferredProseStyle, equals('web'));
    });

    test('NovelSummary', () {
      final s = NovelSummary(
        id: 'n1',
        title: '测试',
        genre: 'xuanhuan',
        updatedAt: DateTime(2026, 1, 5),
      );
      final back = NovelSummary.fromJson(s.toJson());
      expect(back.id, equals('n1'));
      expect(back.title, equals('测试'));
      expect(back.genre, equals('xuanhuan'));
      expect(back.updatedAt, equals(s.updatedAt));
      expect(back.archived, isFalse);
      expect(back.wordCount, equals(0));
      expect(back.chapterCount, equals(0));
    });

    test('NovelSummary archived 往返', () {
      final s = NovelSummary(
        id: 'n2',
        title: '已归档',
        genre: 'xianxia',
        updatedAt: DateTime(2026, 2, 1),
        archived: true,
        wordCount: 12345,
        chapterCount: 7,
      );
      final back = NovelSummary.fromJson(s.toJson());
      expect(back.archived, isTrue);
      expect(back.wordCount, equals(12345));
      expect(back.chapterCount, equals(7));
    });
  });

  group('copyWith 不可变更新', () {
    test('Chapter.copyWith 仅修改指定字段', () {
      final c = Chapter(
        id: 'c1',
        novelId: 'n1',
        title: '旧',
        order: 0,
        content: 'x',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      final u = c.copyWith(title: '新');
      expect(u.title, equals('新'));
      expect(u.content, equals('x'));
    });

    test('Novel.copyWith 保留未指定字段', () {
      final novel = Novel(
        id: 'n1',
        title: 'T',
        genre: 'xuanhuan',
        tone: '热血',
        targetWordsPerChapter: 2000,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        chapters: const [],
        characters: const [],
        worldSettings: const [],
      );
      final u = novel.copyWith(title: 'T2');
      expect(u.title, equals('T2'));
      expect(u.genre, equals('xuanhuan'));
    });
  });

  group('ReaderSettings', () {
    test('toJson/fromJson 往返一致', () {
      const s = ReaderSettings(
        theme: ReaderTheme.dark,
        fontSize: 22,
        lineHeight: 2.2,
        serif: true,
      );
      final back = ReaderSettings.fromJson(s.toJson());
      expect(back.theme, equals(ReaderTheme.dark));
      expect(back.fontSize, equals(22));
      expect(back.lineHeight, equals(2.2));
      expect(back.serif, isTrue);
    });

    test('缺字段回退默认值', () {
      final back = ReaderSettings.fromJson(<String, dynamic>{});
      expect(back.theme, equals(ReaderTheme.light));
      expect(back.fontSize, equals(18));
      expect(back.lineHeight, equals(1.9));
      expect(back.serif, isFalse);
    });

    test('未知主题名回退 light', () {
      final back =
          ReaderSettings.fromJson(<String, dynamic>{'theme': 'neon'});
      expect(back.theme, equals(ReaderTheme.light));
    });

    test('copyWith 保留未指定字段', () {
      const s = ReaderSettings(theme: ReaderTheme.sepia, fontSize: 20);
      final u = s.copyWith(serif: true);
      expect(u.theme, equals(ReaderTheme.sepia));
      expect(u.fontSize, equals(20));
      expect(u.serif, isTrue);
    });
  });

  group('存稿箱 ChapterDraft', () {
    test('toJson/fromJson 往返一致', () {
      final d = ChapterDraft(
        id: 'd1',
        novelId: 'n1',
        title: '废稿',
        content: '一些未定稿内容。',
        createdAt: DateTime(2026, 1, 1, 12, 30),
      );
      final back = ChapterDraft.fromJson(d.toJson());
      expect(back.id, equals('d1'));
      expect(back.title, equals('废稿'));
      expect(back.content, equals('一些未定稿内容。'));
      expect(back.createdAt, equals(d.createdAt));
      expect(back.wordCount(), equals(8));
    });

    test('缺字段回退默认值', () {
      final back = ChapterDraft.fromJson(<String, dynamic>{
        'id': 'd2',
        'novelId': 'n1',
        'createdAt': '2026-01-01T00:00:00.000',
      });
      expect(back.title, equals(''));
      expect(back.content, equals(''));
    });
  });

  group('一键导出配置 ExportPrefs', () {
    test('toJson/fromJson 往返一致', () {
      const p = ExportPrefs(includeSettings: false, lastFormat: 'epub');
      final back = ExportPrefs.fromJson(p.toJson());
      expect(back.includeSettings, isFalse);
      expect(back.lastFormat, equals('epub'));
    });

    test('缺字段回退默认值', () {
      final back = ExportPrefs.fromJson(<String, dynamic>{});
      expect(back.includeSettings, isTrue);
      expect(back.lastFormat, isNull);
    });

    test('copyWith 保留未指定字段', () {
      const p = ExportPrefs(includeSettings: true);
      final updated = p.copyWith(includeSettings: false);
      expect(updated.includeSettings, isFalse);
      expect(updated.lastFormat, isNull);
    });
  });

  group('Novel 存稿箱与导出偏好字段', () {
    test('drafts/exportPrefs 序列化往返', () {
      final novel = Novel(
        id: 'n1',
        title: '测试',
        genre: 'xuanhuan',
        tone: '热血',
        targetWordsPerChapter: 2000,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        chapters: <Chapter>[],
        characters: <Character>[],
        worldSettings: <WorldSetting>[],
        drafts: <ChapterDraft>[
          ChapterDraft(
            id: 'd1',
            novelId: 'n1',
            title: '废稿一',
            content: '草稿内容。',
            createdAt: DateTime(2026, 1, 1),
          ),
        ],
        exportPrefs: const ExportPrefs(
          includeSettings: false,
          lastFormat: 'docx',
        ),
      );
      final back = Novel.fromJson(novel.toJson());
      expect(back.drafts.length, equals(1));
      expect(back.drafts.first.title, equals('废稿一'));
      expect(back.exportPrefs.includeSettings, isFalse);
      expect(back.exportPrefs.lastFormat, equals('docx'));
    });

    test('缺 drafts/exportPrefs 时回退默认', () {
      final back = Novel.fromJson(<String, dynamic>{
        'id': 'n1',
        'title': '测试',
        'genre': 'xuanhuan',
        'tone': '热血',
        'targetWordsPerChapter': 2000,
        'createdAt': '2026-01-01T00:00:00.000',
        'updatedAt': '2026-01-01T00:00:00.000',
        'chapters': <dynamic>[],
        'characters': <dynamic>[],
        'worldSettings': <dynamic>[],
      });
      expect(back.drafts, isEmpty);
      expect(back.exportPrefs.includeSettings, isTrue);
      expect(back.exportPrefs.lastFormat, isNull);
    });
  });
}
