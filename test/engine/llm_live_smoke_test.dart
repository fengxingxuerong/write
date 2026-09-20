// 真实端点冒烟测试（默认跳过、零联网；设环境变量 NOVEL_LIVE=1 才启用）。
//
// 「用 .env.local 里的端点测试」的入口：
//   1. 对 4 家服务商各发一次 ping（maxTokens 16，只验连通，不生成正文）；
//   2. 用首个可用端点各跑一次真实生成：单章（LlmEngine）与
//      多场景（MultiPassChapterEngine，含场景规划），验证上下文注入链路
//      （人物关系 / 世界观 / 前情提要 / 伏笔 / 场景承接）在真实模型下成立。
//
// 运行（PowerShell，先把 .env.local 装载进进程环境）：
//   Get-Content .env.local | ForEach-Object {
//     if ($_ -match '^\s*([^#=]+?)\s*=\s*(.+?)\s*$') {
//       [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') } }
//   $env:NOVEL_LIVE = '1'
//   flutter test test/engine/llm_live_smoke_test.dart --timeout 15m
//
// 安全约定：密钥只从环境变量读取；任何输出不含密钥明文。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/llm_chat_client.dart';
import 'package:novel_writer/engine/llm_engine.dart';
import 'package:novel_writer/engine/multipass/multi_pass_chapter_engine.dart';
import 'package:novel_writer/engine/multipass/scene_builder.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/models/world_setting.dart';

/// 候选端点（来源：用户提供的 .env.local / 桌面配置文件）。
class _Ep {
  const _Ep(this.name, this.base, this.model, this.keyEnv);
  final String name;
  final String base;
  final String model;
  final String keyEnv;
}

const List<_Ep> _eps = <_Ep>[
  _Ep('AMD', 'https://developer.amd.com.cn/radeon/api/v1',
      'DeepSeek-V4-Flash', 'NOVEL_KEY_AMD'),
  _Ep('SenseNova', 'https://token.sensenova.cn/v1',
      'deepseek-v4-flash', 'NOVEL_KEY_SENSE_K1'),
  _Ep('NVIDIA', 'https://integrate.api.nvidia.com/v1',
      'deepseek-v4-flash', 'NOVEL_KEY_NVIDIA'),
  _Ep('OpenRouter', 'https://openrouter.ai/api/v1',
      'stealth/ox-alpha', 'NOVEL_KEY_OPENROUTER'),
];

/// ping 阶段选出的首个可用端点（测试顺序执行，跨用例共享）。
_Ep? _firstOk;

LlmConfig _configFor(_Ep ep) => LlmConfig(
      provider: LlmProvider.openaiCompatible,
      model: ep.model,
      apiKey: Platform.environment[ep.keyEnv] ?? '',
      baseUrl: ep.base,
    );

GenerationConfig _genConfig({int targetWords = 600}) => GenerationConfig(
      genre: 'xuanhuan',
      tone: '热血',
      targetWords: targetWords,
      protagonistName: '林舟',
      continuation: '林舟攥着那半枚铜钥匙，城门在他身后缓缓合拢。',
      expandOutline: false,
      constraints: const GenerationConstraints(),
    );

ContextBundle _ctx() => ContextBundle(
      characters: const <Character>[
        Character(
          id: 'c1',
          novelId: 'n1',
          name: '林舟',
          role: '主角',
          traits: '谨慎，嘴硬心软',
          background: '旧城守卫出身',
          relationships: '苏晚是林舟失散多年的姐姐',
          dialogueStyle: '短句，从不说敬语',
        ),
      ],
      worldSettings: const <WorldSetting>[
        WorldSetting(
          id: 'w1',
          novelId: 'n1',
          title: '封印规则',
          category: '规则',
          content: '城门只在退潮时开启，强开者会失去昨夜的记忆',
        ),
      ],
      genrePreset: GenrePresets.get('xuanhuan'),
      plotSkeleton: PlotSkeleton.forGenre('xuanhuan'),
      outline: '林舟用钥匙开启城门，遭遇守门人，险胜后夺回信物',
      plotSummary: '苏晚带走了另一半钥匙，留下字条警告他不要开城门。',
      foreshadowing: '失踪守卫的怀表尚未找到',
    );

void main() {
  final bool live = Platform.environment['NOVEL_LIVE'] == '1';

  test(
    'ping 四家真实端点',
    () async {
      for (final _Ep ep in _eps) {
        if ((Platform.environment[ep.keyEnv] ?? '').isEmpty) {
          print('${ep.name}: SKIP（缺 ${ep.keyEnv}）');
          continue;
        }
        final LlmChatClient client = LlmChatClient(config: _configFor(ep));
        final Stopwatch sw = Stopwatch()..start();
        final LlmPingResult r =
            await client.ping(timeout: const Duration(seconds: 25));
        print('${ep.name} [${ep.model}]: '
            '${r.ok ? "OK" : "FAIL"} ${sw.elapsedMilliseconds}ms ${r.message}');
        if (r.ok) {
          _firstOk ??= ep;
        }
      }
      expect(_firstOk, isNotNull,
          reason: '全部端点不可用，无法继续真实生成冒烟');
    },
    timeout: const Timeout(Duration(minutes: 4)),
    skip: live ? null : 'NOVEL_LIVE 未设置（保持离线）',
  );

  test(
    '真实单章生成（首个可用端点）',
    () async {
      final _Ep? ep = _firstOk;
      if (ep == null) {
        print('SKIP: 无可用端点');
        return;
      }
      final LlmEngine engine = LlmEngine(config: _configFor(ep));
      final GenerationResult r = await engine.generate(_genConfig(), _ctx());
      print('单章 ${ep.name} [${ep.model}]: '
          '${AppConstants.countWords(r.content)} 字');
      print('预览: ${r.content.characters.take(120).toString()}');
      expect(r.content.trim(), isNotEmpty);
      expect(AppConstants.countWords(r.content), greaterThanOrEqualTo(50));
      expect(r.content.contains('```'), isFalse,
          reason: '输出规则要求纯正文，不应出现 Markdown 记号');
      engine.dispose();
    },
    timeout: const Timeout(Duration(minutes: 8)),
    skip: live ? null : 'NOVEL_LIVE 未设置（保持离线）',
  );

  test(
    '真实多场景生成（规划 + 逐场景，首个可用端点）',
    () async {
      final _Ep? ep = _firstOk;
      if (ep == null) {
        print('SKIP: 无可用端点');
        return;
      }
      final LlmConfig llm = _configFor(ep);
      final GenerationResult r = await MultiPassChapterEngine(
        config: llm,
        sceneBuilder: SceneBuilder(config: llm),
      ).generate(_genConfig(targetWords: 800), _ctx());
      print('多场景 ${ep.name} [${ep.model}]: '
          '${AppConstants.countWords(r.content)} 字');
      print('预览: ${r.content.characters.take(120).toString()}');
      expect(r.content.trim(), isNotEmpty);
      expect(AppConstants.countWords(r.content), greaterThanOrEqualTo(120));
      expect(r.content.contains('```'), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: live ? null : 'NOVEL_LIVE 未设置（保持离线）',
  );
}