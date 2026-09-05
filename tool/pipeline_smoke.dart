// 端到端冒烟：用集成进墨匠的 AiPipelineService 真实调用云端 API 生成小篇幅小说。
// 用法：设置 NOVEL_KEY_AMD / NOVEL_KEY_SENSE_K1 / K2 / K3 后 `dart run tool/pipeline_smoke.dart`
import 'dart:io';

import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/ai_pipeline_service.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_storage.dart';
import 'package:novel_writer/models/llm_config.dart';

Future<void> main() async {
  final String amd = Platform.environment['NOVEL_KEY_AMD'] ?? '';
  final String k1 = Platform.environment['NOVEL_KEY_SENSE_K1'] ?? '';
  final String k2 = Platform.environment['NOVEL_KEY_SENSE_K2'] ?? '';
  final String k3 = Platform.environment['NOVEL_KEY_SENSE_K3'] ?? '';
  if (amd.isEmpty || k1.isEmpty || k2.isEmpty || k3.isEmpty) {
    stdout.writeln('[SMOKE] 缺少环境变量 key，退出');
    exitCode = 2;
    return;
  }

  // 注意：LlmChatClient 会自动拼接 /chat/completions，这里传「根 URL」。
  const String sense = 'https://token.sensenova.cn/v1';
  const String amdUrl = 'https://developer.amd.com.cn/radeon/api/v1';

  final AiPipelineConfig config = AiPipelineConfig(
    totalWords: 4000,
    maxChapters: 2,
    genre: '玄幻',
    protagonist: '陆沉',
    useEditor: true,
    useVerifier: true,
    roles: <AiRole, AiRoleConfig>{
      AiRole.planner: AiRoleConfig(
        role: AiRole.planner,
        llm: LlmConfig(
          provider: LlmProvider.openaiCompatible,
          model: 'deepseek-v4-flash',
          apiKey: k2,
          baseUrl: sense,
          temperature: 0.8,
        ),
      ),
      AiRole.writer: AiRoleConfig(
        role: AiRole.writer,
        llm: LlmConfig(
          provider: LlmProvider.openaiCompatible,
          model: 'DeepSeek-V4-Flash',
          apiKey: amd,
          baseUrl: amdUrl,
          temperature: 0.8,
        ),
      ),
      AiRole.editor: AiRoleConfig(
        role: AiRole.editor,
        llm: LlmConfig(
          provider: LlmProvider.openaiCompatible,
          model: 'kimi-k3',
          apiKey: k1,
          baseUrl: sense,
          temperature: 1.0,
        ),
      ),
      AiRole.titler: AiRoleConfig(
        role: AiRole.titler,
        llm: LlmConfig(
          provider: LlmProvider.openaiCompatible,
          model: 'sensenova-6.8-flash-lite',
          apiKey: k3,
          baseUrl: sense,
          temperature: 0.8,
        ),
      ),
      AiRole.verifier: AiRoleConfig(
        role: AiRole.verifier,
        llm: LlmConfig(
          provider: LlmProvider.openaiCompatible,
          model: 'deepseek-v4-flash',
          apiKey: k2,
          baseUrl: sense,
          temperature: 0.8,
        ),
      ),
    },
  );

  final String dirPath =
      '${Directory.systemTemp.path}${Platform.pathSeparator}ink_smoke';
  final PipelineStorage storage = PipelineStorage(dirPath);
  final AiPipelineTask task = AiPipelineTask(
    id: 'smoke${DateTime.now().millisecondsSinceEpoch}',
    config: config,
    createdAt: DateTime.now(),
  );
  final AiPipelineService service = AiPipelineService(storage);

  final StringBuffer log = StringBuffer()
    ..writeln('[SMOKE] 启动：目标 ${config.totalWords} 字')
    ..writeln('[SMOKE] 角色：'
        '规划=${config.roleOf(AiRole.planner).llm.model} '
        '写手=${config.roleOf(AiRole.writer).llm.model} '
        '编辑=${config.roleOf(AiRole.editor).llm.model} '
        '标题=${config.roleOf(AiRole.titler).llm.model} '
        '审校=${config.roleOf(AiRole.verifier).llm.model}');

  await service.run(
    task,
    isCancelled: () => false,
    onProgress: () {
      log.writeln(
          '[SMOKE] 进度：${task.chapterCount} 章 / ${task.totalWords} 字');
    },
  );

  log.writeln('[SMOKE] 状态：${task.status.name}'
      '${task.status == PipelineTaskStatus.failed ? ' | 错误: ${task.error}' : ''}');
  // 失败时附上任务日志尾部，便于诊断
  if (task.status == PipelineTaskStatus.failed) {
    final List<String> tail = task.log.length > 15
        ? task.log.sublist(task.log.length - 15)
        : task.log;
    for (final String line in tail) {
      log.writeln('  | $line');
    }
  }
  log.writeln('[SMOKE] 书名：《${task.title}》');
  for (final PipelineChapter ch in task.chapters) {
    final Map<String, dynamic> qa = PipelineQa.chapterReport(ch);
    log.writeln(
        '  第${ch.idx}章《${ch.title}》${ch.words}字(raw=${ch.rawWords}) '
        'AI味=${qa['aiEcho']}% 重复=${qa['repetition']} 节奏=${qa['rhythm']}');
    if (ch.issues.isNotEmpty) {
      for (final String iss in ch.issues) {
        log.writeln('    ⚠ $iss');
      }
    }
  }

  // 导出 txt 验证
  final StringBuffer txt = StringBuffer()..writeln('《${task.title}》');
  for (final PipelineChapter ch in task.chapters) {
    txt
      ..writeln()
      ..writeln('第 ${ch.idx} 章  ${ch.title}')
      ..writeln('${'-' * 20}')
      ..writeln()
      ..writeln(ch.content);
  }
  final File out = File('$dirPath${Platform.pathSeparator}smoke_out.txt');
  await out.writeAsString(txt.toString(), flush: true);
  log.writeln('[SMOKE] 导出：${out.path}');

  // 结果写入文件（避免控制台编码问题）
  final File result = File('$dirPath${Platform.pathSeparator}smoke_result.txt');
  await result.writeAsString(log.toString(), flush: true);
  stdout.writeln('[SMOKE] 完成，详见 $dirPath${Platform.pathSeparator}smoke_result.txt');
}
