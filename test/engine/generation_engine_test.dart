import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/world_setting.dart';

/// ContextBundle 单元测试
///
/// 覆盖：copyWith 不可变更新（多章连写时替换大纲用）。
void main() {
  group('ContextBundle.copyWith', () {
    final bundle = ContextBundle(
      characters: const <Character>[
        Character(
          id: 'c1',
          novelId: 'n1',
          name: '林玄',
          role: '主角',
          traits: '坚韧',
          background: '',
          relationships: '',
        ),
      ],
      worldSettings: const <WorldSetting>[
        WorldSetting(
          id: 'w1',
          novelId: 'n1',
          title: '天玄大陆',
          category: '地理',
          content: '灵气复苏',
        ),
      ],
      genrePreset: GenrePresets.get('xuanhuan'),
      plotSkeleton: PlotSkeleton.forGenre('xuanhuan'),
      outline: '原大纲',
    );

    test('不传参返回等价副本', () {
      final copy = bundle.copyWith();
      expect(copy.characters, same(bundle.characters));
      expect(copy.worldSettings, same(bundle.worldSettings));
      expect(copy.genrePreset, same(bundle.genrePreset));
      expect(copy.plotSkeleton, same(bundle.plotSkeleton));
      expect(copy.outline, equals('原大纲'));
    });

    test('替换 outline 后原对象不变', () {
      final copy = bundle.copyWith(outline: '新大纲');
      expect(copy.outline, equals('新大纲'));
      expect(bundle.outline, equals('原大纲'));
    });
  });
}
