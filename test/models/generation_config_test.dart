import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/models/generation_config.dart';

/// GenerationConfig / GenerationConstraints / WritingStyle / ProseStyle 单元测试
///
/// 覆盖：默认值、序列化/反序列化、copyWith、枚举 label/instruction。

void main() {
  group('GenerationConstraints', () {
    test('默认值', () {
      const c = GenerationConstraints();
      expect(c.maxWordsPerChapter, AppConstants.defaultMaxWordsPerChapter);
      expect(c.allowRepeat, isFalse);
    });

    test('toJson/fromJson 往返', () {
      const original = GenerationConstraints(maxWordsPerChapter: 5000, allowRepeat: true);
      final restored = GenerationConstraints.fromJson(original.toJson());
      expect(restored.maxWordsPerChapter, 5000);
      expect(restored.allowRepeat, isTrue);
    });

    test('fromJson 缺失字段使用默认值', () {
      final c = GenerationConstraints.fromJson(<String, dynamic>{});
      expect(c.maxWordsPerChapter, AppConstants.defaultMaxWordsPerChapter);
      expect(c.allowRepeat, isFalse);
    });

    test('copyWith 仅修改指定字段', () {
      const original = GenerationConstraints();
      final copy = original.copyWith(allowRepeat: true);
      expect(copy.allowRepeat, isTrue);
      expect(copy.maxWordsPerChapter, original.maxWordsPerChapter);
    });
  });

  group('GenerationConfig 默认值', () {
    test('必需字段初始化', () {
      const config = GenerationConfig(
        genre: 'xuanhuan',
        tone: 'hot',
        targetWords: 3000,
        constraints: GenerationConstraints(),
      );
      expect(config.genre, 'xuanhuan');
      expect(config.tone, 'hot');
      expect(config.targetWords, 3000);
      expect(config.useExistingSettings, isTrue);
      expect(config.randomLevel, 0.5);
      expect(config.chapterCount, 1);
      expect(config.expandOutline, isTrue);
      expect(config.style, WritingStyle.standard);
      expect(config.proseStyle, ProseStyle.web);
    });
  });

  group('GenerationConfig 序列化', () {
    test('toJson 包含所有字段', () {
      const config = GenerationConfig(
        genre: 'dushi',
        tone: 'warm',
        targetWords: 5000,
        useExistingSettings: false,
        protagonistName: '张三',
        randomLevel: 0.8,
        continuation: '上文内容',
        chapterCount: 3,
        volumeOutline: '大纲内容',
        expandOutline: false,
        style: WritingStyle.crisp,
        proseStyle: ProseStyle.guluo,
        constraints: GenerationConstraints(maxWordsPerChapter: 8000, allowRepeat: true),
      );
      final json = config.toJson();
      expect(json['genre'], 'dushi');
      expect(json['tone'], 'warm');
      expect(json['targetWords'], 5000);
      expect(json['useExistingSettings'], false);
      expect(json['protagonistName'], '张三');
      expect(json['randomLevel'], 0.8);
      expect(json['continuation'], '上文内容');
      expect(json['chapterCount'], 3);
      expect(json['volumeOutline'], '大纲内容');
      expect(json['expandOutline'], false);
      expect(json['style'], 'crisp');
      expect(json['proseStyle'], 'guluo');
      expect(json['constraints']['maxWordsPerChapter'], 8000);
      expect(json['constraints']['allowRepeat'], true);
    });

    test('fromJson 完整字段', () {
      final json = {
        'genre': 'kehuan',
        'tone': 'serious',
        'targetWords': 4000,
        'useExistingSettings': false,
        'protagonistName': '李四',
        'randomLevel': 0.3,
        'continuation': null,
        'chapterCount': 2,
        'volumeOutline': '',
        'expandOutline': false,
        'style': 'detailed',
        'proseStyle': 'jinyong',
        'constraints': {'maxWordsPerChapter': 6000, 'allowRepeat': false},
      };
      final config = GenerationConfig.fromJson(json);
      expect(config.genre, 'kehuan');
      expect(config.tone, 'serious');
      expect(config.targetWords, 4000);
      expect(config.useExistingSettings, isFalse);
      expect(config.protagonistName, '李四');
      expect(config.randomLevel, 0.3);
      expect(config.chapterCount, 2);
      expect(config.expandOutline, isFalse);
      expect(config.style, WritingStyle.detailed);
      expect(config.proseStyle, ProseStyle.jinyong);
    });

    test('fromJson 缺失可选字段使用默认值', () {
      final json = <String, dynamic>{
        'genre': 'test',
        'tone': 'test',
        'targetWords': 1000,
        'constraints': <String, dynamic>{},
      };
      final config = GenerationConfig.fromJson(json);
      expect(config.useExistingSettings, isTrue);
      expect(config.protagonistName, isNull);
      expect(config.randomLevel, 0.5);
      expect(config.chapterCount, 1);
      expect(config.expandOutline, isTrue);
      expect(config.style, WritingStyle.standard);
      expect(config.proseStyle, ProseStyle.web);
    });

    test('toJson/fromJson 往返一致', () {
      const original = GenerationConfig(
        genre: 'test',
        tone: 'test',
        targetWords: 2000,
        protagonistName: '主角',
        randomLevel: 0.7,
        chapterCount: 5,
        constraints: GenerationConstraints(maxWordsPerChapter: 10000),
      );
      final restored = GenerationConfig.fromJson(original.toJson());
      expect(restored.genre, original.genre);
      expect(restored.tone, original.tone);
      expect(restored.targetWords, original.targetWords);
      expect(restored.protagonistName, original.protagonistName);
      expect(restored.randomLevel, original.randomLevel);
      expect(restored.chapterCount, original.chapterCount);
      expect(restored.constraints.maxWordsPerChapter, 10000);
    });
  });

  group('WritingStyle 枚举', () {
    test('所有枚举值存在', () {
      expect(WritingStyle.values, hasLength(4));
      expect(WritingStyle.values, contains(WritingStyle.standard));
      expect(WritingStyle.values, contains(WritingStyle.crisp));
      expect(WritingStyle.values, contains(WritingStyle.detailed));
      expect(WritingStyle.values, contains(WritingStyle.dialogue));
    });

    test('label 返回中文名', () {
      expect(WritingStyle.standard.label, '标准');
      expect(WritingStyle.crisp.label, '精炼短句（快节奏）');
      expect(WritingStyle.detailed.label, '绵长细腻（慢节奏）');
      expect(WritingStyle.dialogue.label, '对话密集');
    });

    test('instruction 非空', () {
      for (final style in WritingStyle.values) {
        expect(style.instruction, isNotEmpty);
      }
    });
  });

  group('ProseStyle 枚举', () {
    test('所有枚举值存在', () {
      expect(ProseStyle.values, hasLength(4));
      expect(ProseStyle.values, contains(ProseStyle.web));
      expect(ProseStyle.values, contains(ProseStyle.guluo));
      expect(ProseStyle.values, contains(ProseStyle.jinyong));
      expect(ProseStyle.values, contains(ProseStyle.lightNovel));
    });

    test('label 返回中文名', () {
      expect(ProseStyle.web.label, '现代网文（爽感）');
      expect(ProseStyle.guluo.label, '古龙简洁（短句留白）');
      expect(ProseStyle.jinyong.label, '金庸古典（半文半白）');
      expect(ProseStyle.lightNovel.label, '日轻细腻（心理吐槽）');
    });

    test('instruction 非空', () {
      for (final style in ProseStyle.values) {
        expect(style.instruction, isNotEmpty);
      }
    });
  });
}
