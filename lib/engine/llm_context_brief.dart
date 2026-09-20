import 'package:characters/characters.dart';

import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/world_setting.dart';

/// LLM 生成路径的上下文拼装库（user 消息共享段）。
///
/// 单 pass（LlmEngine 章节简报）与多 pass（MultiPassChapterEngine
/// 场景提示）共用同一套块级拼装，保证两条路径注入的设定信息一致：
/// 此前多 pass 场景提示缺世界观/人物关系/说话风格/上一章结尾/前情提要，
/// 单 pass 角色块漏人物关系，导致两条路径成稿的连贯性不同。
///
/// 纯静态纯函数，无 IO，便于单测覆盖。
class LlmContextBrief {
  const LlmContextBrief._();

  /// 角色块：姓名（定位）+ 性格 + 背景/关系/说话风格（空字段不输出）。
  ///
  /// 空列表返回空串；调用方据此跳过段落头。
  static String charactersBlock(List<Character> characters) {
    if (characters.isEmpty) return '';
    final StringBuffer b = StringBuffer();
    b.writeln('【已有角色】');
    for (final Character c in characters) {
      b.writeln('- ${c.name}（${c.role}）：${c.traits}');
      if (c.background.isNotEmpty) b.writeln('  背景：${c.background}');
      if (c.relationships.isNotEmpty) b.writeln('  关系：${c.relationships}');
      if (c.dialogueStyle.isNotEmpty) {
        b.writeln('  说话风格：${c.dialogueStyle}');
      }
    }
    return b.toString();
  }

  /// 世界观设定块：`- 标题（分类）：内容`，每条一行。
  static String worldSettingsBlock(List<WorldSetting> settings) {
    if (settings.isEmpty) return '';
    final StringBuffer b = StringBuffer();
    b.writeln('【世界观设定】');
    for (final WorldSetting w in settings) {
      b.writeln('- ${w.title}（${w.category}）：${w.content}');
    }
    return b.toString();
  }

  /// 上一章结尾块（承接锚点）。
  static String continuationBlock(String? continuation) {
    final String c = (continuation ?? '').trim();
    if (c.isEmpty) return '';
    return '【上一章结尾（请承接此情节继续，不要复述）】\n$c\n';
  }

  /// 前情提要块（跨章剧情摘要）。
  static String plotSummaryBlock(String plotSummary) {
    final String s = plotSummary.trim();
    if (s.isEmpty) return '';
    return '【前情提要（最近的剧情进展，保持伏笔与人物弧光一致）】\n$s\n';
  }

  /// 伏笔账本块（未回收伏笔 + 推进/回收约束）。
  static String foreshadowingBlock(String foreshadowing) {
    final String f = foreshadowing.trim();
    if (f.isEmpty) return '';
    final StringBuffer b = StringBuffer();
    b.writeln('【伏笔账本（未回收的伏笔，按埋设顺序）】');
    b.writeln(f);
    b.writeln('- 若本章大纲与某条伏笔相关，应自然推进或回收该伏笔；');
    b.writeln('- 其余伏笔不得与之矛盾，也不要强行提前回收；');
    b.writeln('- 本章埋设的新悬念须清晰可追踪，不要随手弃坑。');
    return b.toString();
  }

  /// 两条生成路径共享的设定与跨章记忆；每次请求独立携带。
  /// 后续场景用就近生成的正文承接，不再从上一章结尾重新起笔。
  static String contextBlock(
    GenerationConfig config,
    ContextBundle ctx, {
    bool includeContinuation = true,
  }) {
    final StringBuffer b = StringBuffer();
    _appendBlock(b, charactersBlock(ctx.characters));
    _appendBlock(b, worldSettingsBlock(ctx.worldSettings));
    if (includeContinuation) {
      _appendBlock(b, continuationBlock(config.continuation));
    }
    _appendBlock(b, plotSummaryBlock(ctx.plotSummary));
    _appendBlock(b, foreshadowingBlock(ctx.foreshadowing));
    return b.toString();
  }

  /// 场景间承接片段（不是语义摘要），最多保留 [tailChars] 个字素。
  /// 优先从句首开始；若预算内只有一个长句尾部，则保留尾部而非清空。
  /// 句末连续标点和右引号一并跳过，所有截取均在字素边界进行。
  /// [tailChars] 为零时返回空串，负数抛出 [RangeError]。
  static String sceneHandoff(String text, {int tailChars = 120}) {
    RangeError.checkNotNegative(tailChars, 'tailChars');
    if (tailChars == 0) return '';
    final String trimmed = text.trim();
    final List<String> graphemes = trimmed.characters.toList();
    if (graphemes.length <= tailChars) return trimmed;
    final int start = graphemes.length - tailChars;
    const endings = <String>{'。', '！', '？', '…', '!', '?', '\n', '\r\n'};
    const closers = <String>{'”', '’', '」', '』', '"', "'"};

    String afterBoundary(int index) {
      while (index < graphemes.length &&
          (endings.contains(graphemes[index]) ||
              closers.contains(graphemes[index]) ||
              graphemes[index].trim().isEmpty)) {
        index++;
      }
      return graphemes.skip(index).join().trim();
    }

    final String tail = graphemes.skip(start).join().trim();
    // 已落在句首时，不再误删首个完整句子（含句末右引号之后）。
    int previous = start - 1;
    while (previous >= 0 &&
        !endings.contains(graphemes[previous]) &&
        (closers.contains(graphemes[previous]) ||
            graphemes[previous].trim().isEmpty)) {
      previous--;
    }
    if (previous >= 0 && endings.contains(graphemes[previous])) {
      final String cut = afterBoundary(start);
      return cut.isEmpty ? tail : cut;
    }
    for (int i = start; i < graphemes.length; i++) {
      if (endings.contains(graphemes[i])) {
        final String cut = afterBoundary(i + 1);
        return cut.isEmpty ? tail : cut;
      }
    }
    return tail;
  }

  /// 追加非空块：先空一行再写块内容（块自带段落头与换行）。
  static void _appendBlock(StringBuffer b, String block) {
    if (block.isEmpty) return;
    b.writeln();
    b.write(block);
  }
}
