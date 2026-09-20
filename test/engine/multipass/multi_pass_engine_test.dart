import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/multipass/scene_builder.dart';
import 'package:novel_writer/engine/multipass/scene_plan.dart';
import 'package:novel_writer/models/llm_config.dart';

/// MultiPass 模块单元测试（全程假数据，无网络）。
void main() {
  group('ChapterScenes 基础', () {
    test('totalTargetWords 求和正确', () {
      const ChapterScenes cs = ChapterScenes(
        chapterOutline: 'o',
        scenes: <ScenePlan>[
          ScenePlan(
              index: 0, stage: 'a', goal: '', beats: <String>[], targetWords: 100),
          ScenePlan(
              index: 1, stage: 'b', goal: '', beats: <String>[], targetWords: 200),
          ScenePlan(
              index: 2, stage: 'c', goal: '', beats: <String>[], targetWords: 300),
        ],
      );
      expect(cs.totalTargetWords, 600);
    });

    test('fromJson 空输入不报错', () {
      final ChapterScenes cs = ChapterScenes.fromJson(<String, dynamic>{});
      expect(cs.scenes, isEmpty);
      expect(cs.totalTargetWords, 0);
    });
  });

  group('SceneBuilder 包装', () {
    test('回调 builder 被正确调用', () async {
      final _StubBuilder builder = _StubBuilder(<ScenePlan>[
        const ScenePlan(
            index: 0,
            stage: '起',
            goal: '开场',
            beats: <String>['节拍'],
            targetWords: 500),
      ]);
      final List<ScenePlan> scenes = await builder.build(
        '大纲内容',
        chapterTargetWords: 2000,
        genre: '玄幻',
        tone: '热血',
      );
      expect(scenes.length, 1);
      expect(scenes.first.targetWords, 500);
    });
  });

  group('ScenePlan JSON 往返', () {
    test('toJson / fromJson 保持数据一致', () {
      const ScenePlan s = ScenePlan(
        index: 2,
        stage: '转',
        goal: '反转',
        beats: <String>['危机', '高潮'],
        targetWords: 800,
      );
      final ScenePlan restored = ScenePlan.fromJson(s.toJson());
      expect(restored.index, s.index);
      expect(restored.stage, s.stage);
      expect(restored.goal, s.goal);
      expect(restored.beats, s.beats);
      expect(restored.targetWords, s.targetWords);
    });
  });
}

/// 测试用 Builder：直接返回预定 LLM 解析后的场景列表。
class _StubBuilder implements SceneBuilder {
  _StubBuilder(this._scenes);
  final List<ScenePlan> _scenes;

  @override
  LlmConfig get config => const LlmConfig(model: 'fake');

  @override
  Future<List<ScenePlan>> build(
    String chapterOutline, {
    required int chapterTargetWords,
    required String genre,
    required String tone,
    String? prevSceneSummary,
    String storyContext = '',
  }) async =>
      _scenes;
}
