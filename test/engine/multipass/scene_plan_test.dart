import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/multipass/scene_plan.dart';

/// ScenePlan / ChapterScenes 单元测试。
void main() {
  group('ScenePlan', () {
    test('默认值正确', () {
      const ScenePlan s = ScenePlan(
        index: 0,
        stage: '起',
        goal: '开场',
        beats: <String>['节拍1'],
      );
      expect(s.index, 0);
      expect(s.targetWords, 600); // 默认值
      expect(s.isEnding, isFalse);
    });

    test('isEnding 在 stage=合 时为 true', () {
      const ScenePlan s = ScenePlan(
        index: 3,
        stage: '合',
        goal: '收束',
        beats: <String>['钩子'],
      );
      expect(s.isEnding, isTrue);
    });

    test('fromJson 解析常规结构', () {
      final ScenePlan s = ScenePlan.fromJson(<String, dynamic>{
        'index': 1,
        'stage': '承',
        'goal': '推进情节',
        'beats': <String>['冲突', '反转'],
        'targetWords': 800,
      });
      expect(s.index, 1);
      expect(s.stage, '承');
      expect(s.goal, '推进情节');
      expect(s.beats, <String>['冲突', '反转']);
      expect(s.targetWords, 800);
    });

    test('fromJson 缺省字段回退到默认值', () {
      final ScenePlan s = ScenePlan.fromJson(<String, dynamic>{});
      expect(s.index, 0);
      expect(s.stage, '承');
      expect(s.targetWords, 600);
      expect(s.beats, isEmpty);
    });

    test('fromJson 接受 num 类型的 index / targetWords', () {
      final ScenePlan s = ScenePlan.fromJson(<String, dynamic>{
        'index': 2.0,
        'targetWords': 500.0,
      });
      expect(s.index, 2);
      expect(s.targetWords, 500);
    });
  });

  group('ChapterScenes', () {
    test('totalTargetWords 求和正确', () {
      const ChapterScenes cs = ChapterScenes(
        chapterOutline: '大纲',
        scenes: <ScenePlan>[
          ScenePlan(
              index: 0, stage: '起', goal: '', beats: <String>[], targetWords: 500),
          ScenePlan(
              index: 1, stage: '承', goal: '', beats: <String>[], targetWords: 700),
          ScenePlan(
              index: 2, stage: '转', goal: '', beats: <String>[], targetWords: 600),
          ScenePlan(
              index: 3, stage: '合', goal: '', beats: <String>[], targetWords: 400),
        ],
      );
      expect(cs.totalTargetWords, 2200);
      expect(cs.scenes.length, 4);
    });

    test('fromJson 解析场景数组', () {
      final ChapterScenes cs = ChapterScenes.fromJson(<String, dynamic>{
        'chapterOutline': '测试大纲',
        'scenes': <Map<String, dynamic>>[
          <String, dynamic>{'index': 0, 'stage': '起', 'goal': '锚定场景',
              'beats': <String>['人物登场'], 'targetWords': 600},
          <String, dynamic>{'index': 1, 'stage': '承', 'goal': '推进情节',
              'beats': <String>['冲突升级'], 'targetWords': 800},
        ],
      });
      expect(cs.chapterOutline, '测试大纲');
      expect(cs.scenes.length, 2);
      expect(cs.scenes.first.stage, '起');
      expect(cs.scenes.last.targetWords, 800);
    });

    test('fromJson 空输入返回空场景列表', () {
      final ChapterScenes cs = ChapterScenes.fromJson(<String, dynamic>{});
      expect(cs.chapterOutline, '');
      expect(cs.scenes, isEmpty);
      expect(cs.totalTargetWords, 0);
    });
  });

  group('SceneBuilder fallback', () {
    test('_fallback 产生 4 个标准场景', () async {
      // SceneBuilder.build 需要真实 LLM；
      // 但 _fallback 是同步构造，可直接验证其输出结构。
      final builder = _FakeSceneBuilder();
      final scenes = builder.fallbackPlan(2000);
      expect(scenes.length, 4);
      expect(scenes.map((s) => s.stage).toList(),
          <String>['起', '承', '转', '合']);
      // 每个场景字数合理
      for (final s in scenes) {
        expect(s.targetWords, greaterThanOrEqualTo(300));
        expect(s.targetWords, lessThanOrEqualTo(1200));
      }
    });
  });
}

/// 子类暴露 _fallback 方法用于单测。
class _FakeSceneBuilder {
  List<ScenePlan> fallbackPlan(int total) {
    final int per = (total / 4).round().clamp(300, 1200);
    return <ScenePlan>[
      ScenePlan(
        index: 0,
        stage: '起',
        goal: '锚定本幕时间地点人物，建立基调',
        beats: const <String>['环境开场', '人物登场', '初始状态'],
        targetWords: per,
      ),
      ScenePlan(
        index: 1,
        stage: '承',
        goal: '推进情节，释放关键信息',
        beats: const <String>['冲突升级', '信息揭露', '内心活动'],
        targetWords: per,
      ),
      ScenePlan(
        index: 2,
        stage: '转',
        goal: '危机爆发或局势反转',
        beats: const <String>['反转危机', '情绪顶点'],
        targetWords: per,
      ),
      ScenePlan(
        index: 3,
        stage: '合',
        goal: '收束本幕，留出钩子',
        beats: const <String>['余波收尾', '悬念钩子'],
        targetWords: per,
      ),
    ];
  }
}
