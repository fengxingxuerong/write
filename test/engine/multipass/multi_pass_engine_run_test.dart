import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/multipass/multi_pass_chapter_engine.dart';
import 'package:novel_writer/engine/multipass/scene_builder.dart';
import 'package:novel_writer/engine/multipass/scene_plan.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/models/world_setting.dart';

import '../../support/fake_http.dart';

/// MultiPassChapterEngine **真实编排**测试（假 HTTP 栈，零网络）。
///
/// 此前 `multi_pass_engine_test.dart` 只测了 ScenePlan 数据结构，
/// 整个 `generate()` 编排（逐场景生成、失败聚合、空内容重试、取消、
/// 爽点补修、prompt 注入）零覆盖——这里补齐。
/// LlmEngine / LlmChatClient 内部的 `HttpClient()` 会走区域覆盖拿到假栈。

LlmConfig _cfg() => const LlmConfig(
      provider: LlmProvider.openaiCompatible,
      model: 'fake-model',
      apiKey: 'k',
      baseUrl: 'http://127.0.0.1:1/v1',
    );

GenerationConfig _chapter({int targetWords = 6000}) => GenerationConfig(
      genre: '玄幻',
      tone: '热血',
      targetWords: targetWords,
      constraints: const GenerationConstraints(maxWordsPerChapter: 20000),
    );

ContextBundle _ctx({String styleBlock = ''}) => ContextBundle(
      characters: const <Character>[],
      worldSettings: const <WorldSetting>[],
      genrePreset: GenrePresets.get('xuanhuan'),
      plotSkeleton: PlotSkeleton.forGenre('xuanhuan'),
      outline: '整章大纲：主角在宗门大比中逆袭。',
      styleBlock: styleBlock,
    );

/// 非流式 chat 成功响应。
FakeHttpResponse _chatReply(String content) => FakeHttpResponse(
      body: utf8.encode(
        jsonEncode(<String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{'content': content},
            },
          ],
        }),
      ),
    );

/// 取本次请求的 user 消息（断言 prompt 注入用）。
String _userMessage(FakeHttpRequest req) {
  final Map<String, dynamic> payload =
      jsonDecode(req.bodyText) as Map<String, dynamic>;
  final List<dynamic> messages = payload['messages'] as List<dynamic>;
  return messages.last['content'] as String;
}

/// 场景规划桩：直接返回预设场景序列（不发请求）。
class _StubScenes implements SceneBuilder {
  _StubScenes(this.scenes);

  final List<ScenePlan> scenes;

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
      scenes;
}

void main() {
  group('逐场景编排与 prompt 注入', () {
    test('三场景拼装 + 进度回报 + 爽点约束/文风块/章末钩子注入', () async {
      final List<ScenePlan> scenes = <ScenePlan>[
        const ScenePlan(
            index: 0, stage: '起', goal: '开场：主角登场', beats: <String>['雨夜']),
        const ScenePlan(index: 1, stage: '转', goal: '局势逆转', beats: <String>['反杀']),
        const ScenePlan(index: 2, stage: '合', goal: '收尾留钩', beats: <String>['新信']),
      ];
      int hits = 0;
      final FakeHttpClient client = FakeHttpClient(
        respond: (FakeHttpRequest req, Uri url) async {
          hits++;
          return _chatReply('场景$hits 的正文。');
        },
      );
      final MultiPassChapterEngine engine = MultiPassChapterEngine(
        config: _cfg(),
        sceneBuilder: _StubScenes(scenes),
        retrySleep: (Duration d) async {},
      );
      final List<String> progress = <String>[];

      final GenerationResult result = await withFakeHttpClient(
        client,
        () => engine.generate(
          _chapter(),
          _ctx(styleBlock: '【文风指纹】句长均长 24.5，对白 31%'),
          onProgress: (GenerationProgress p) => progress.add(p.stage),
        ),
      );

      expect(
        result.content,
        '场景1 的正文。\n\n场景2 的正文。\n\n场景3 的正文。',
      );
      expect(hits, 3);
      expect(progress, hasLength(3), reason: '每场景一次进度回报，不得静默');
      expect(progress.first, contains('第 1/3 场景'));
      expect(progress.last, contains('第 3/3 场景'));

      final List<String> prompts =
          client.requests.map(_userMessage).toList(growable: false);
      expect(prompts[0], isNot(contains('外显爽点')),
          reason: '「起」场景不该被强加爽点约束');
      expect(prompts[1], contains('【本场景硬约束·外显爽点】'),
          reason: '后半段「转」场景必须强制注入爽点约束');
      expect(prompts[2], contains('这是本章最后一个场景'),
          reason: '「合」场景必须要求章末钩子收尾');
      for (final String p in prompts) {
        expect(p, contains('【文风指纹】句长均长 24.5'),
            reason: '文风块要注入每个场景，否则学分布只学了一段');
        expect(p, contains('整章大纲：主角在宗门大比中逆袭。'),
            reason: '整章大纲作为背景注入每个场景');
      }
    });

    test('场景返回空内容 → 退避重试后成功（空内容是可重试错误）', () async {
      final List<ScenePlan> scenes = <ScenePlan>[
        const ScenePlan(index: 0, stage: '起', goal: '开场', beats: <String>[]),
      ];
      int hits = 0;
      final List<Duration> waits = <Duration>[];
      final FakeHttpClient client = FakeHttpClient(
        respond: (FakeHttpRequest req, Uri url) async {
          hits++;
          if (hits == 1) return _chatReply('   ');
          return _chatReply('重试后的场景正文。');
        },
      );
      final MultiPassChapterEngine engine = MultiPassChapterEngine(
        config: _cfg(),
        sceneBuilder: _StubScenes(scenes),
        retrySleep: (Duration d) async => waits.add(d),
      );

      final GenerationResult result = await withFakeHttpClient(
        client,
        () => engine.generate(_chapter(), _ctx()),
      );

      expect(result.content, '重试后的场景正文。');
      expect(hits, 2, reason: '第一次空响应应触发重试');
      expect(waits, isNotEmpty, reason: '重试必须走退避（注入的 sleep 被调用）');
    });
  });

  group('失败聚合与取消', () {
    test('全部场景失败 → 抛 EngineException，不吐空章节给 UI', () async {
      final List<ScenePlan> scenes = <ScenePlan>[
        const ScenePlan(index: 0, stage: '起', goal: '开场', beats: <String>[]),
        const ScenePlan(index: 1, stage: '合', goal: '收尾', beats: <String>[]),
      ];
      final FakeHttpClient client = FakeHttpClient(
        respond: (FakeHttpRequest req, Uri url) async => FakeHttpResponse(),
        postError: const SocketException('Connection refused'),
      );
      final MultiPassChapterEngine engine = MultiPassChapterEngine(
        config: _cfg(),
        sceneBuilder: _StubScenes(scenes),
        retrySleep: (Duration d) async {},
      );

      await expectLater(
        withFakeHttpClient(client, () => engine.generate(_chapter(), _ctx())),
        throwsA(
          isA<EngineException>().having(
            (EngineException e) => e.message,
            'message',
            contains('全部失败'),
          ),
        ),
      );
    });

    test('单场景失败但其余成功 → 正文保留 + 进度提示缺席场景', () async {
      final List<ScenePlan> scenes = <ScenePlan>[
        const ScenePlan(index: 0, stage: '起', goal: '开场', beats: <String>[]),
        const ScenePlan(index: 1, stage: '合', goal: '收尾', beats: <String>[]),
      ];
      int hits = 0;
      final FakeHttpClient client = FakeHttpClient(
        respond: (FakeHttpRequest req, Uri url) async {
          hits++;
          if (hits == 1) return _chatReply('第一幕正文。');
          return FakeHttpResponse(statusCode: 500);
        },
      );
      final MultiPassChapterEngine engine = MultiPassChapterEngine(
        config: _cfg(),
        sceneBuilder: _StubScenes(scenes),
        retrySleep: (Duration d) async {},
      );
      final List<String> progress = <String>[];

      final GenerationResult result = await withFakeHttpClient(
        client,
        () => engine.generate(
          _chapter(),
          _ctx(),
          onProgress: (GenerationProgress p) => progress.add(p.stage),
        ),
      );

      expect(result.content, '第一幕正文。',
          reason: '部分失败必须保正文（此前静默丢整章）');
      expect(progress.join('|'), contains('缺席'),
          reason: '必须告诉作者哪几个场景缺席，可重跑补回');
      expect(hits, 4, reason: '成功 1 次 + 失败场景按退避重试共 3 次');
    });

    test('场景间取消 → 立即停止，不再请求后续场景', () async {
      final List<ScenePlan> scenes = <ScenePlan>[
        const ScenePlan(index: 0, stage: '起', goal: '开场', beats: <String>[]),
        const ScenePlan(index: 1, stage: '承', goal: '推进', beats: <String>[]),
      ];
      int hits = 0;
      final FakeHttpClient client = FakeHttpClient(
        respond: (FakeHttpRequest req, Uri url) async {
          hits++;
          return _chatReply('已生成的场景正文。');
        },
      );
      final MultiPassChapterEngine engine = MultiPassChapterEngine(
        config: _cfg(),
        sceneBuilder: _StubScenes(scenes),
        retrySleep: (Duration d) async {},
      );
      final CancelToken token = CancelToken();

      final GenerationResult result = await withFakeHttpClient(
        client,
        () => engine.generate(
          _chapter(),
          _ctx(),
          cancelToken: token,
          onProgress: (GenerationProgress p) {
            // 第一次进度回报（场景 1 之前）就取消。
            token.cancel();
          },
        ),
      );

      expect(hits, 1, reason: '取消后不得再打第二个场景的请求');
      expect(result.content, '已生成的场景正文。');
    });
  });

  group('外显爽点补修（不劣化闸门）', () {
    /// 双低正文：无💥/✨/侧反词，长度足以过 minWordsOk。
    const String bland =
        '雨下了一整夜。他把书页翻到昨夜折角的地方，端起已经凉透的茶，'
        '看了看院门的方向，又低头把那行小字重新抄了一遍。窗外的水汽慢慢散开，'
        '屋檐下的影子一寸寸挪过台阶。他数着更声，直到第三响落下去，才把笔搁在砚台上。';

    List<ScenePlan> oneScene() => <ScenePlan>[
          const ScenePlan(index: 0, stage: '起', goal: '日常推进', beats: <String>[]),
        ];

    test('补修稿被拒（字数越界）→ 保留原文，不劣化', () async {
      int sceneHits = 0;
      int repairHits = 0;
      final FakeHttpClient client = FakeHttpClient(
        respond: (FakeHttpRequest req, Uri url) async {
          if (_userMessage(req).contains('只输出强化后的全章正文')) {
            repairHits++;
            return _chatReply('太短了。');
          }
          sceneHits++;
          return _chatReply(bland);
        },
      );
      final MultiPassChapterEngine engine = MultiPassChapterEngine(
        config: _cfg(),
        sceneBuilder: _StubScenes(oneScene()),
        retrySleep: (Duration d) async {},
      );
      final List<String> progress = <String>[];

      final GenerationResult result = await withFakeHttpClient(
        client,
        () => engine.generate(
          _chapter(targetWords: 100),
          _ctx(),
          onProgress: (GenerationProgress p) => progress.add(p.stage),
        ),
      );

      expect(sceneHits, 1);
      expect(repairHits, 1, reason: '双低正文必须触发补修（否则该闸门是死代码）');
      expect(progress.join('|'), contains('外显爽点补修'));
      expect(result.content, bland,
          reason: '验收不过必须原样保留——补修绝不能把正文改短改没');
    });

    test('补修稿达标（补上外显兑现且字数在区间）→ 采纳新稿', () async {
      int repairHits = 0;
      const String improved = '$bland'
          '他猛地一拍案几，当众把那张假契摔在众人面前——这记打脸来得又快又狠，'
          '满屋子的人都愣住了。';
      final FakeHttpClient client = FakeHttpClient(
        respond: (FakeHttpRequest req, Uri url) async {
          if (_userMessage(req).contains('只输出强化后的全章正文')) {
            repairHits++;
            return _chatReply(improved);
          }
          return _chatReply(bland);
        },
      );
      final MultiPassChapterEngine engine = MultiPassChapterEngine(
        config: _cfg(),
        sceneBuilder: _StubScenes(oneScene()),
        retrySleep: (Duration d) async {},
      );

      final GenerationResult result = await withFakeHttpClient(
        client,
        () => engine.generate(_chapter(targetWords: 100), _ctx()),
      );

      expect(repairHits, 1);
      expect(result.content, improved,
          reason: '达标稿必须被采纳（拒收好稿同样是坏闸门）');
      expect(result.content, isNot(bland));
    });

    test('补修失败（端点挂了）→ 静默保原文，不抛错', () async {
      int repairHits = 0;
      final FakeHttpClient client = FakeHttpClient(
        respond: (FakeHttpRequest req, Uri url) async {
          if (_userMessage(req).contains('只输出强化后的全章正文')) {
            repairHits++;
            return FakeHttpResponse(statusCode: 500);
          }
          return _chatReply(bland);
        },
      );
      final MultiPassChapterEngine engine = MultiPassChapterEngine(
        config: _cfg(),
        sceneBuilder: _StubScenes(oneScene()),
        retrySleep: (Duration d) async {},
      );

      final GenerationResult result = await withFakeHttpClient(
        client,
        () => engine.generate(_chapter(targetWords: 100), _ctx()),
      );

      expect(repairHits, 1);
      expect(result.content, bland, reason: '补修失败不阻塞：成稿照常返回');
    });
  });
}
