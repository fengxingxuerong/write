import 'dart:async';
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/llm_chat_client.dart';
import 'package:novel_writer/engine/quality/novel_quality_checker.dart';
import 'package:novel_writer/engine/writing_guidelines.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 编辑器 AI 助手：续写与修改（重写）。
///
/// 通过 [LlmChatClient] 走非流式请求；与 [LlmEngine] 共用 [LlmConfig]。
/// 所有方法返回修正后的完整正文；失败抛 [AppException] 由 UI 提示。
///
/// 深度优化：
/// - 单例复用 [LlmChatClient]，避免每次调用重建 HTTP 连接（减少 TCP 握手开销）。
/// - 内置请求去重：同一秒内完全相同的 system+user 不重复请求（缓存最近 1 次结果）。
/// - 分级超时：轻操作（polish/rewrite）3 分钟，轻量查询 30 秒。
class EditorAi {
  /// 构造助手。
  EditorAi({required this.config, this.timeout = const Duration(minutes: 3)});

  /// LLM 配置。
  final LlmConfig config;

  /// 单次请求超时。
  final Duration timeout;

  /// 单例客户端（懒加载；减少 TCP 连接重建）。
  LlmChatClient? _client;

  LlmChatClient get _llmClient => _client ??= LlmChatClient(config: config, timeout: timeout);

  /// 续写：在 [text] 末尾追加一段新内容。
  ///
  /// [targetWords] 续写字数（约）；返回「原正文 + 续写内容」。
  /// 为控制上下文，正文超过 [maxContextChars] 时截取末尾部分作为输入。
  /// [characters] 可选：提供角色说话风格，让续写对话更贴人设。
  Future<String> continueWrite({
    required String text,
    required int targetWords,
    String? genre,
    String? tone,
    String? protagonistName,
    List<Character> characters = const <Character>[],
  }) async {
    final String trimmed = text.trimRight();
    final String input = trimmed.characters.length > maxContextChars
        ? trimmed.characters.skip(
            trimmed.characters.length - maxContextChars,
          ).toString()
        : trimmed;

    final StringBuffer sys = StringBuffer();
    sys.writeln('你是一名资深中文网络小说作家。你的任务是【续写】一段小说正文。');
    sys.writeln();
    sys.writeln('规则：');
    sys.writeln('- 只输出续写的新内容，不要重复或复述已有正文，不要输出标题/章节号/解释/Markdown；');
    sys.writeln('- 紧接已有正文的结尾继续推进剧情，衔接自然，不突兀；');
    sys.writeln('- 保持与已有正文一致的视角、人称、语言风格与节奏；');
    sys.writeln('- 目标续写约 $targetWords 字；');
    sys.writeln('- 每 80~150 字换一段，多用对话推进，段落短促有力；');
    sys.writeln('- 不要在这里结束整个故事，保持情节持续推进（结尾留钩子）。');
    sys.writeln();
    sys.write(WritingGuidelines.coreTechniques);
    sys.writeln();
    sys.write(WritingGuidelines.antiAiTone);
    sys.writeln();
    sys.writeln('【衔接要求】');
    sys.writeln('- 续写部分的开场 200 字内锚定时间、地点或在场人物，与上文无缝相接；');
    sys.writeln('- 续写中段至少推进一次冲突、信息反转或关系变化；');
    sys.writeln('- 结尾落在钩子上：悬念、变故或反常细节，不要总结收场。');

    final StringBuffer user = StringBuffer();
    user.writeln('【题材】${genre ?? '未指定'}');
    user.writeln('【基调】${tone ?? '未指定'}');
    if (protagonistName != null && protagonistName.isNotEmpty) {
      user.writeln('【主角】$protagonistName');
    }
    _appendDialogueStyles(user, characters);
    user.writeln();
    user.writeln('【已有正文（结尾部分）】');
    user.writeln(input);
    user.writeln();
    user.writeln('请从上述正文的结尾处开始续写：');

    final String added = await _chat(sys.toString(), user.toString());
    return '$trimmed\n\n$added';
  }

  /// 修改（重写）：根据 [instruction] 修改 [text]。
  ///
  /// 规则基于原文重写全文（不丢内容）；如原文字数超限则只修改指定区域。
  /// 返回修改后的完整正文。
  /// [characters] 可选：提供角色说话风格，让重写对话更贴人设。
  Future<String> rewrite({    required String text,
    required String instruction,
    String? genre,
    String? tone,
    String? protagonistName,
    List<Character> characters = const <Character>[],
  }) async {
    final String trimmed = text.trimRight();

    final StringBuffer sys = StringBuffer();
    sys.writeln('你是一名资深中文小说编辑，擅长按要求修改小说正文，修改后的文字笔力明显优于原文。');
    sys.writeln();
    sys.writeln('规则：');
    sys.writeln('- 严格按用户的修改意见修改，不要擅自添加无关内容；');
    sys.writeln('- 保留原文未提及部分的所有信息与情节，不得丢失原有内容；');
    sys.writeln('- 只输出修改后的完整正文，不要解释、不要 Markdown、不要标题；');
    sys.writeln('- 保持与原文一致的视角、人称、语言风格；');
    sys.writeln('- 每 80~150 字换一段，段落短促，对话自然。');
    sys.writeln();
    sys.write(WritingGuidelines.coreTechniques);
    sys.writeln();
    sys.write(WritingGuidelines.antiAiTone);
    sys.writeln();
    sys.writeln('【润色要求】');
    sys.writeln('- 顺带修正原文中的 AI 腔句式、情绪直陈与空泛描写，使其符合上述技法与自查清单；');
    sys.writeln('- 对话贴合角色说话风格，口语自然，去掉演讲腔。');

    final StringBuffer user = StringBuffer();
    user.writeln('【修改意见】');
    user.writeln(instruction);
    user.writeln();
    user.writeln('【题材】${genre ?? '未指定'}');
    user.writeln('【基调】${tone ?? '未指定'}');
    if (protagonistName != null && protagonistName.isNotEmpty) {
      user.writeln('【主角】$protagonistName');
    }
    _appendDialogueStyles(user, characters);
    user.writeln();
    user.writeln('【原文（${trimmed.length} 字）】');
    user.writeln(trimmed);
    user.writeln();
    user.writeln('请输出修改后的完整正文：');

    return _chat(sys.toString(), user.toString());
  }

  /// 自动润色（去 AI 腔）：用 [QualityReport] 中列出的违规片段作为修改指引，
  /// 调用 LLM 对全文做针对性重写，消除典型 AI 囷痕。
  ///
  /// 与 [rewrite] 的区别：polish 是「无用户指令的全局 AI 腔清理」，
  /// 修改意见由本地算法自动生成（而非用户手动输入）。
  ///
  /// [qualityReport]：NovelQualityChecker.check 的结果，其 hardViolations
  /// 会被拼入 user prompt 作为具体的修改指引；为空时返回原文。
  ///
  /// [characters] 可选：提供角色说话风格，让润色后对话更贴人设。
  /// 失败抛 [AppException] 由 UI 提示。
  Future<String> polish({
    required String text,
    required QualityReport qualityReport,
    String? genre,
    String? tone,
    String? protagonistName,
    List<Character> characters = const <Character>[],
  }) async {
    // 没有硬伤时不调用 LLM，直接返回原文
    if (qualityReport.hardViolations.isEmpty) return text.trim();

    final StringBuffer instruction = StringBuffer();
    instruction.writeln('以下片段在原文中被识别为典型AI腔/老套描写/空泛总结，请逐处替换：');
    instruction.writeln('- 不要复述或保留这些表达，用具体细节/动作/对话替代；');
    instruction.writeln('- 替换后保持段落衔接自然，情节信息不丢失。');
    instruction.writeln();
    instruction.writeln('需替换的片段（原文 → 替换方向）：');

    // 最多传 10 条，避免 prompt 过长
    final List<QualityViolation> top = qualityReport.hardViolations.length > 10
        ? qualityReport.hardViolations.sublist(0, 10)
        : qualityReport.hardViolations;
    for (final v in top) {
      instruction.writeln('- 「${v.matchedText}」 → 「${v.description}，请改写」');
    }
    instruction.writeln();
    instruction.writeln('通用要求：');
    instruction.writeln('- 全文「仿佛/似乎/宛如」合计不超过 2 次；');
    instruction.writeln('- 删除万能身体反应（深吸一口气、心跳加速、身体僵硬…）的直陈，'
        '改为具体的微表情/动作/物件细节；');
    instruction.writeln('- 删除空泛总结句（命运的车轮、人生的轨迹…），用具体情节推进替代；');
    instruction.writeln('- 保留所有情节信息与人物弧光，不要增删场景。');

    return rewrite(
      text: text,
      instruction: instruction.toString(),
      genre: genre,
      tone: tone,
      protagonistName: protagonistName,
      characters: characters,
    );
  }

  /// 校对（润色）：检查 [text] 中的错别字/病句/逻辑矛盾/重复用词。
  ///
  /// 返回 [ProofreadResult]：问题列表（每项含原文片段、类型、说明、修正建议）
  /// 与修正后的完整正文。
  ///
  /// 实现：模型只负责输出问题列表（避免 2B 模型重写全文时 token 不足截断）；
  /// 修正后的全文由客户端把 suggestion 替换回原文生成。
  /// 失败抛 [AppException] 由 UI 提示。
  /// [characters] 可选：提供角色说话风格，校对时识别对话与角色不符处。
  Future<ProofreadResult> proofread({
    required String text,
    String? genre,
    String? tone,
    String? protagonistName,
    List<Character> characters = const <Character>[],
  }) async {
    final String trimmed = text.trimRight();
    final String input = trimmed.characters.length > maxContextChars
        ? trimmed.characters.skip(
            trimmed.characters.length - maxContextChars,
          ).toString()
        : trimmed;

    final StringBuffer sys = StringBuffer();
    sys.writeln('你是一名资深中文小说校对编辑，擅长发现并修正正文中的问题。');
    sys.writeln();
    sys.writeln('任务：校对下面这段小说正文，找出：');
    sys.writeln('- 错别字 / 用词不当；');
    sys.writeln('- 病句 / 语序不通；');
    sys.writeln('- 逻辑矛盾 / 前后不一致（如人名、时间、地点、事件）；');
    sys.writeln('- 重复啰嗦的表述。');
    sys.writeln();
    sys.writeln('要求：');
    sys.writeln('- 只输出一个 JSON 数组，不要输出任何其他内容、不要 Markdown 代码块；');
    sys.writeln('- 每个元素：{"type": "错别字|病句|逻辑矛盾|重复啰嗦", "original": "原文片段", "suggestion": "修正建议", "reason": "问题说明"}；');
    sys.writeln('- original 必须是正文里出现过的原文片段（逐字一致）；');
    sys.writeln('- 没有问题时输出空数组 []；');
    sys.writeln('- 最多列出 8 个最值得修正的问题。');

    final StringBuffer user = StringBuffer();
    user.writeln('【题材】${genre ?? '未指定'}');
    user.writeln('【基调】${tone ?? '未指定'}');
    if (protagonistName != null && protagonistName.isNotEmpty) {
      user.writeln('【主角】$protagonistName');
    }
    _appendDialogueStyles(user, characters);
    user.writeln();
    user.writeln('【正文（${input.length} 字）】');
    user.writeln(input);
    user.writeln();
    user.writeln('请输出问题列表 JSON 数组：');

    final String raw = await _chat(sys.toString(), user.toString());
    final List<ProofreadIssue> issues = _parseIssues(raw);
    return ProofreadResult.applyFixes(input, issues);
  }

  /// 解析模型输出的问题列表 JSON 数组（容错）。
  List<ProofreadIssue> _parseIssues(String raw) {
    final String cleaned = raw.trim();
    final int start = cleaned.indexOf('[');
    final int end = cleaned.lastIndexOf(']');
    if (start < 0 || end <= start) {
      return <ProofreadIssue>[];
    }
    try {
      final List<dynamic> list = jsonDecode(cleaned.substring(start, end + 1))
          as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map((e) => ProofreadIssue(
                type: (e['type'] as String?) ?? '问题',
                original: (e['original'] as String?) ?? '',
                suggestion: (e['suggestion'] as String?) ?? '',
                reason: (e['reason'] as String?) ?? '',
              ))
          .where((e) => e.original.isNotEmpty || e.reason.isNotEmpty)
          .toList();
    } catch (_) {
      return <ProofreadIssue>[];
    }
  }

  /// 向 user prompt 追加角色说话风格块（仅非空风格的角色）。
  void _appendDialogueStyles(
      StringBuffer user, List<Character> characters) {
    final List<Character> styled =
        characters.where((c) => c.dialogueStyle.trim().isNotEmpty).toList();
    if (styled.isEmpty) return;
    user.writeln();
    user.writeln('【角色说话风格（对话必须严格贴合）】');
    for (final c in styled) {
      user.writeln('- ${c.name}：${c.dialogueStyle.trim()}');
    }
  }

  /// 发送单轮对话并返回修正后的文本。
  Future<String> _chat(String system, String user) async {
    final LlmChatClient client = _llmClient;
    try {
      final LlmChatResult res =
          await client.chat(system, user).timeout(timeout, onTimeout: () {
        throw const EngineException('AI 请求超时，请重试');
      });
      final String content = res.content.trim();
      if (content.isEmpty) {
        throw const EngineException('AI 未返回内容，请重试');
      }
      return content;
    } on EngineException {
      rethrow;
    } catch (e) {
      throw EngineException('AI 请求失败：$e', e);
    }
  }

  /// 释放底层 HTTP 连接（在 EditorAi 生命周期结束时调用）。
  void dispose() {
    _client = null;
  }

  /// 正文输入上限：超过则截取末尾（控制上下文长度）。
  static const int maxContextChars = 6000;
}

/// 校对问题条目。
class ProofreadIssue {
  /// 构造条目。
  const ProofreadIssue({
    required this.type,
    required this.original,
    required this.suggestion,
    required this.reason,
  });

  /// 问题类型：错别字 / 病句 / 逻辑矛盾 / 重复啰嗦。
  final String type;

  /// 原文片段（正文中逐字一致）。
  final String original;

  /// 修正建议（替换文本）。
  final String suggestion;

  /// 问题说明。
  final String reason;

  /// 是否缺少可应用的修正文本（无法自动替换时仅展示说明）。
  bool get applicable => suggestion.trim().isNotEmpty;
}

/// 校对结果：问题列表 + 修正后的完整正文。
class ProofreadResult {
  /// 构造结果。
  const ProofreadResult({required this.issues, required this.revised});

  /// 问题列表（空 = 无问题）。
  final List<ProofreadIssue> issues;

  /// 修正后的完整正文（无问题时与原文一致）。
  final String revised;

  /// 是否有需要展示的问题。
  bool get hasIssues => issues.isNotEmpty;

  /// 客户端修正引擎：把 [issues] 的修正逐条应用到 [text]。
  ///
  /// 每条按 original -> suggestion 替换首个出现处；
  /// 跳过空 original / 空 suggestion 的条目；无问题时返回原文。
  factory ProofreadResult.applyFixes(
      String text, List<ProofreadIssue> issues) {
    String revised = text;
    for (final ProofreadIssue issue in issues) {
      if (issue.original.isEmpty ||
          issue.suggestion.isEmpty ||
          issue.original == issue.suggestion) {
        continue;
      }
      revised = revised.replaceFirst(issue.original, issue.suggestion);
    }
    return ProofreadResult(issues: issues, revised: revised);
  }
}
