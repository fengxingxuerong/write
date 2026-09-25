// 固定角色工作流的真实端到端测试（默认跳过，零联网）。
//
// 启用方式（PowerShell）：
//   $env:NOVEL_LIVE = '1'
//   $env:NOVEL_KEY_FILE = 'D:/Desktop/新建 Text Document.txt'   # 可选，默认读仓库 .env.local
//   flutter test test/ai_pipeline/role_workflow_live_test.dart --timeout 20m
//
// 做法：把配置文件里的密钥按「策划/写手/编辑/标题/审校」固定分工装配成端点链，
// 跑软件内置的 AiPipelineService 生成一部短篇（规划→场景→正文→润色→审校），
// 断言成稿字数并落盘到 verify-logs/。密钥只从文件读取，不写入源码。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/fixed_workflow_preset.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/ai_pipeline_service.dart';
import 'package:novel_writer/ai_pipeline/services/llm_router.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/core/security/secret_store.dart';
import 'package:novel_writer/engine/quality/fanqie_gate_checker.dart';

void main() {
  final bool live = Platform.environment['NOVEL_LIVE'] == '1';

  test(
    '固定分工流水线真实生成一部短篇',
    () async {
      // 1) 读取密钥：优先进程环境（只认已知密钥名），其次本机配置文件。
      final Map<String, String> keys = <String, String>{};
      for (final String name in FixedWorkflowPreset.knownEnvKeys) {
        final String v = Platform.environment[name]?.trim() ?? '';
        if (v.isNotEmpty) keys[name] = v;
      }
      if (keys.isEmpty) {
        final String path =
            Platform.environment['NOVEL_KEY_FILE'] ?? '.env.local';
        final File f = File(path);
        expect(
          f.existsSync(),
          isTrue,
          reason: '未找到密钥来源：请设置 NOVEL_KEY_FILE 或准备 .env.local',
        );
        keys.addAll(FixedWorkflowPreset.parseKeys(f.readAsStringSync()));
      }
      expect(keys, isNotEmpty, reason: '未解析到任何 API Key');
      print('密钥来源已就绪：${keys.length} 个');

      // 2) 按固定分工装配五角色端点链（不含未实测端点）。
      final Map<AiRole, AiRoleConfig> roles = FixedWorkflowPreset.roles(keys);
      for (final AiRole r in AiRole.values) {
        final AiRoleConfig c = roles[r]!;
        print(
          '${r.label}: 主=${c.llm.model}（${c.llm.baseUrl}）'
          ' 备=${c.fallbacks.length}',
        );
        expect(c.llm.isConfigured, isTrue, reason: '${r.label} 主模型未配置');
      }

      // 3) 跑内置流水线：3 章、约 4500 字，开启编辑、审校、质量评分和低分重写。
      final Directory out = Directory('verify-logs')
        ..createSync(recursive: true);
      final PipelineStorage storage = PipelineStorage(
        '${out.path}${Platform.pathSeparator}live_pipeline',
        secretStore: InMemorySecretStore(),
      );
      final AiPipelineConfig config = AiPipelineConfig(
        totalWords: 4500,
        maxChapters: 3,
        genre: '玄幻',
        protagonist: '林舟',
        useEditor: true,
        useVerifier: true,
        useQualityReview: true,
        qualityReviewEvery: 1,
        autoRewriteLowScore: true,
        useStateTrack: true,
        roles: roles,
      );
      expect(
        AiPipelineService.missingRoles(config),
        isEmpty,
        reason: '仍有角色缺配置',
      );

      final AiPipelineTask task = AiPipelineTask(
        id: 'live-${DateTime.now().millisecondsSinceEpoch}',
        config: config,
        createdAt: DateTime.now(),
      );
      final AiPipelineService service = AiPipelineService(
        storage,
        // 单次请求 90 秒、连续失败 2 次即冷却：端点限流时快速切链，
        // 不让一次调用拖到默认的 3 分钟 × 多次重试。
        router: ChainLlmRouter(
          timeout: const Duration(seconds: 90),
          maxFailures: 2,
          cooldown: const Duration(minutes: 2),
        ),
      );
      await service.run(
        task,
        isCancelled: () => false,
        onProgress: () => print(
          '进度：${task.chapterCount} 章 / '
          '${task.totalWords} 字（最近日志：${task.log.last}）',
        ),
      );

      for (final String line in task.log.take(40)) {
        print(line);
      }
      print(
        '状态：${task.status.name}  章节：${task.chapterCount}  '
        '字数：${task.totalWords}  书：《${task.title}》',
      );

      // 4) 断言：跑完、有稿、成稿达到基本体量。
      expect(task.status, PipelineTaskStatus.done);
      expect(task.chapters, hasLength(3));
      expect(task.totalWords, greaterThanOrEqualTo(3000));
      for (final PipelineChapter c in task.chapters) {
        final FanqieGateReport gate = FanqieGateChecker(
          genre: config.genre,
          protagonist: config.protagonist,
        ).check(c.content, chapterIndex: c.idx);
        final List<String> commercialIssues = PipelineQa.chapterIssues(c);
        print(
          '质量：第${c.idx}章 ${c.words} 字｜'
          '综合分 ${gate.score.toStringAsFixed(0)}｜'
          '钩子 ${PipelineQa.hasEndingHook(c.content)}｜'
          '商业问题 ${commercialIssues.length}',
        );
        expect(c.content.trim(), isNotEmpty);
        expect(c.content.contains('```'), isFalse);
        expect(
          gate.hasVeto,
          isFalse,
          reason: '第${c.idx}章命中阻断级合规问题：${gate.issues}',
        );
      }

      final StringBuffer buf = StringBuffer()
        ..writeln('《${task.title}》')
        ..writeln()
        ..writeln('题材：${config.genre}　主角：${config.protagonist}')
        ..writeln('角色分工：策划/写手/编辑/标题/审校（固定端点链）')
        ..writeln();
      for (final PipelineChapter c in task.chapters) {
        buf.writeln('第 ${c.idx} 章　${c.title}（${c.words} 字）');
        buf.writeln();
        buf.writeln(c.content);
        buf.writeln();
      }
      final File novelFile = File(
        '${out.path}${Platform.pathSeparator}live_novel.md',
      )..writeAsStringSync(buf.toString(), flush: true);
      print('成稿已落盘：${novelFile.path}（${buf.length} 字符）');
      print('正文预览：${task.chapters.first.content.substring(0, 120)}');
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: live ? null : 'NOVEL_LIVE 未设置（保持离线）',
  );
}
