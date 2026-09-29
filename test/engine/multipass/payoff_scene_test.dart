import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/multipass/multi_pass_chapter_engine.dart';
import 'package:novel_writer/engine/multipass/scene_builder.dart';
import 'package:novel_writer/engine/multipass/scene_plan.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 爽点场景识别（关键词 **或** 位置双通道）——与 Python
/// `novel_pipeline.is_payoff_scene` 同口径，防双端漂移。
///
/// 实测（2026-09-29）：14 本成书 108 章里仅 16 章 goal 含爽点键，
/// 关键词通道几乎不可用；位置通道用「爽点放章内后半段 + 起承转合」的
/// 既有结构事实兜底。
void main() {
  group('MultiPassChapterEngine.isPayoffScene', () {
    test('关键词通道：三个识别键任一命中即算爽点场景', () {
      for (final String g in <String>[
        '外显爽点：当众打脸',
        '设计一次打脸',
        '当众揭穿真凶',
      ]) {
        expect(MultiPassChapterEngine.isPayoffScene(g, '承', 0, 4), isTrue,
            reason: g);
      }
    });

    test('位置通道：goal 无关键词但后半段「转」仍算爽点场景', () {
      expect(
          MultiPassChapterEngine.isPayoffScene('局势逆转，危机爆发', '转', 2, 4),
          isTrue);
      expect(
          MultiPassChapterEngine.isPayoffScene('局势逆转，危机爆发', '转', 1, 3),
          isTrue);
    });

    test('起/承阶段位置靠前，不因位置误判', () {
      expect(MultiPassChapterEngine.isPayoffScene('场景铺垫', '起', 0, 4),
          isFalse);
      expect(
          MultiPassChapterEngine.isPayoffScene('事件推进，冲突升级', '承', 1, 4),
          isFalse);
    });

    test('进度不足 55% 的「转」不算后半段', () {
      // 2 场景章里 index0 的进度 50%
      expect(MultiPassChapterEngine.isPayoffScene('危机爆发', '转', 0, 2),
          isFalse);
    });

    test('total<=0 关闭位置通道，但关键词仍生效', () {
      expect(MultiPassChapterEngine.isPayoffScene('危机爆发', '转', 2, 0),
          isFalse);
      expect(MultiPassChapterEngine.isPayoffScene('外显爽点：打脸', '转', 2, 0),
          isTrue);
    });

    test('硬约束文案与 Python 同文（含两条底线）', () {
      const String c = MultiPassChapterEngine.payoffSceneConstraint;
      expect(c, contains('外显爽点'));
      expect(c, contains('当众外部反应'));
      expect(c, contains('禁止只写主角内心感受'));
    });
  });

  group('SceneBuilder 兜底骨架', () {
    test('端点不可用 → 骨架含且仅含 1 个外显爽点场景（「转」）', () async {
      // 先绑端口拿到号再关闭，确保该端口无人监听（沿用 scene_builder_test 套路）
      final HttpServer probe =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final int deadPort = probe.port;
      await probe.close(force: true);

      final List<ScenePlan> scenes = await SceneBuilder(
        config: LlmConfig(baseUrl: 'http://127.0.0.1:$deadPort/v1'),
      ).build(
        '章纲：主角被逐出师门。',
        chapterTargetWords: 3000,
        genre: '仙侠',
        tone: '悲壮',
      );

      expect(scenes, isNotEmpty);
      final List<int> hits = <int>[
        for (int i = 0; i < scenes.length; i++)
          if (MultiPassChapterEngine.isPayoffScene(
              scenes[i].goal, scenes[i].stage, i, scenes.length))
            i,
      ];
      // 兜底骨架此前一个爽点场景都没有 → 规划链失败时桌面端必然断供
      expect(hits.length, 1,
          reason: scenes.map((ScenePlan s) => s.goal).toList().toString());
      expect(scenes[hits.first].stage, '转');
      expect(scenes[hits.first].goal, contains('外显爽点'));
    });
  });
}