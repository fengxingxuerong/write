/// 番茄过审闸门 —— 结论模型层（从 fanqie_gate_checker.dart 抽出）。
///
/// 拆分只移动代码、不改符号契约：checker 文件用 `export` 转发本文件，
/// 所有既有 `import fanqie_gate_checker.dart` 的消费者无需改动即可继续
/// 取用 FanqieGateAction / FanqieGateIssue / FanqieRedlineHit / FanqieGateReport。
///
/// 本层是**纯数据 + 结论派生**（blockers/pass/fixPrompt 等 getter 只读自身
/// 字段，不触碰 checker 的任何私有成员），与 `scripts/fanqie_review.py` 的
/// 结论结构同口径。
import 'package:novel_writer/engine/quality/quality_rules.g.dart';

/// 定点修字数下限（与 Python 侧 `fanqie_review.FIX_MIN_RATIO` 同值同源）。
///
/// 低于此比例整份产出会被采纳守卫拒绝（守卫阈值为 `QualityRules.editorMinRatio`
/// =0.85，Python 侧 apply_text_patch 同值）——提示词必须比守卫更严一档，并写明
/// 「评审的压缩诉求让位于本下限」，否则模型会照
/// 【改写要求】的「删水段/短句」把整章压掉三成，产出全被拒、定点修白跑
/// （门禁 v7 实测 4 次：4087→2847 / 3465→2718 / 4176→2707 / 5983→1517）。
const double fixMinRatio = QualityRules.fixMinRatio;

class FanqieGateAction {
  const FanqieGateAction._(this.label, this.penalty);

  /// 展示名。
  final String label;

  /// 扣分。
  final double penalty;

  /// 必须重写（结构性问题）。
  static const FanqieGateAction rewrite =
      FanqieGateAction._('重写', 8.0);

  /// 需要修改（格式/节奏问题）。
  static const FanqieGateAction revise = FanqieGateAction._('修改', 4.0);

  /// 仅提示。
  static const FanqieGateAction note = FanqieGateAction._('建议', 1.5);
}

/// 一条不达标项。
class FanqieGateIssue {
  const FanqieGateIssue(this.type, this.message, this.action);

  /// 类别（首屏/对白/一致性…）。
  final String type;

  /// 人读说明。
  final String message;

  /// 处置等级。
  final FanqieGateAction action;

  @override
  String toString() => '[${action.label}] $type：$message';
}

/// 红线命中。
class FanqieRedlineHit {
  const FanqieRedlineHit(this.category, this.word, this.context, this.veto);

  final String category;
  final String word;
  final String context;

  /// true = 一票否决；false = 仅提示（情节性使用）。
  final bool veto;
}

/// 闸门结论。
class FanqieGateReport {
  const FanqieGateReport({
    required this.score,
    required this.issues,
    required this.redlines,
    required this.dialogueRatio,
    required this.fillerRatio,
    this.fillerCounted = 0,
    required this.worldHit,
    required this.worldTotal,
    this.worldMissing = const <String>[],
    this.words = 0,
  });

  /// 0~100 分。
  final double score;

  /// 不达标项。
  final List<FanqieGateIssue> issues;

  /// 红线命中。
  final List<FanqieRedlineHit> redlines;

  final double dialogueRatio;
  final double fillerRatio;

  /// 参与水段统计的长段数（<8 时百分比仅供参考）。
  final int fillerCounted;
  final int worldHit;
  final int worldTotal;

  /// 正文里尚未出现的大纲世界观专名（≤8 个展示用）。
  ///
  /// 定点修指令要靠它点名：只报「专名一个都没出现」而不给清单，模型无从下手
  /// （门禁 v7 第 13 项「世界观未落地」定点修一轮后仍残留的直接原因）。
  final List<String> worldMissing;

  /// 正文汉字数（0 = 未知；阻断项判定需要它）。
  final int words;

  /// 阻断级硬伤（不修完不给「可投」）。与 Python 侧 `blocking_reasons` 同口径。
  ///
  /// 与「扣分项」分开的原因：分数只回答「这一章写得好不好」，阻断项回答
  /// 「这本书现在能不能投」。实测事故：92 分的章里混着补写模型的操作说明
  /// （元话语残留），旧的 `pass` 只看分数 → 判「可投」且 fixPrompt 返回空串，
  /// 那一章再也没被修，脏文本一路留到成书。
  List<String> get blockers {
    final List<String> out = <String>[];
    for (final FanqieGateIssue e in issues) {
      if (e.type == '泄漏') {
        out.add('提示词/元话语残留');
      } else if (e.type == '重复' && e.message.contains('章内大段重复')) {
        out.add('章内大段重复');
      } else if (e.type == '一致性' && e.message.contains('题材漂移')) {
        out.add('题材漂移');
      } else if (e.type == '一致性' && e.message.contains('没接住主角')) {
        out.add('主角缺席');
      } else if (e.type == '一致性' && e.message.contains('没接住设定')) {
        out.add('世界观未落地');
      }
    }
    if (words > 0 && words < 1500) out.add('单章仅 $words 字');
    return out;
  }

  /// 是否达线（无否决红线、无阻断级硬伤且分数 >= 80）。
  bool get pass => !hasVeto && blockers.isEmpty && score >= 80;

  /// 是否存在一票否决级红线。
  bool get hasVeto => redlines.any((FanqieRedlineHit h) => h.veto);

  /// 一句话摘要（进生成日志/提示）。
  String get summary {
    if (hasVeto) return '番茄闸门：命中 ${redlines.length} 处合规红线，需人工复核';
    if (pass) return '番茄闸门：$score 分 达线';
    return '番茄闸门：$score 分，${issues.length} 项不达标';
  }

  /// 不达标项里需要模型动手的那些（排除「仅建议」）。
  List<FanqieGateIssue> get blockingIssues => issues
      .where((FanqieGateIssue e) => e.action != FanqieGateAction.note)
      .toList();

  /// 把不达标项转成「只改问题处」的定点修指令（与 Python 侧 fix_prompt 同语义）。
  /// 达线且无阻断项时返回空串——调用方据此跳过一轮 LLM 调用。
  /// 有阻断项时即使分数达标也要出单（阻断项不修完不算过关）。
  String get fixPrompt {
    final List<FanqieGateIssue> todo = blockingIssues;
    if (todo.isEmpty || (pass && blockers.isEmpty)) return '';
    final StringBuffer b = StringBuffer()
      ..writeln('这一章要过番茄初审，评审器给出以下硬伤。请**只针对这些点改写**，'
          '保持人物名、事件顺序、已埋伏笔完全不变，不要重写无关段落：');
    for (final FanqieGateIssue e in todo) {
      b.writeln('- ${e.type}：${e.message}');
    }
    for (final FanqieRedlineHit h in redlines.where((x) => x.veto)) {
      b.writeln('- 合规红线：出现「${h.word}」（${h.category}），换成不点名的写法');
    }
    // 字数硬约束：没有它时，模型会把【改写要求】的「删水段/25 字句/3 行段」整章执行，
    // 产出低于采纳下限被整份拒绝 → 定点修白跑（与 Python fix_prompt 同款条款）
    if (words > 0) {
      final int floor = (words * fixMinRatio).floor();
      b
        ..writeln()
        ..writeln('【字数硬约束·先看这条】改写后正文不得少于 $floor 字（原文 $words 字，'
            '最多允许压缩 ${((1 - fixMinRatio) * 100).round()}%）。'
            '「删水段」只许删与剧情无关的段落，且删掉多少就要用冲突/对白/动作/细节'
            '补足同等篇幅——**总字数不得下降**。若评审意见（如「篇幅偏长」）与本下限冲突，'
            '以本下限为准：压缩诉求请用「改写」（并句、去修饰、换更短的表达）满足，不靠删段。');
    }
    // 世界观专名缺失清单：与 Python 侧 fix_prompt 同口径——不点名缺哪些，模型改不动
    if (worldMissing.isNotEmpty &&
        todo.any((FanqieGateIssue e) => e.message.contains('世界观专名'))) {
      final int need = worldMissing.length < 5 ? worldMissing.length : 5;
      final String state =
          worldHit == 0 ? '一个都没出现' : '仅命中 $worldHit/$worldTotal';
      b
        ..writeln()
        ..writeln('【世界观专名·本条为阻断项，必须解决】下列专名取自本书大纲，'
            '当前正文$state，还缺 ${worldMissing.length} 个：'
            '${worldMissing.take(8).join('、')}')
        ..writeln('改写时必须把其中至少 $need 个自然织进正文（地名/机构/功法/器物/称谓皆可）：'
            '经由对白称呼、路牌招牌、他人提及、物件来历描写带出；专名按字面照抄，'
            '禁止换成近义词/简称/拼音（初审按字面命中判定）；'
            '禁止把专名列成清单、禁止整段解释设定、禁止为塞专名插入无关段落。');
    }
    b
      ..writeln()
      ..writeln('【改写要求】首屏 300 字必须有主角在场、正在发生的冲突、至少一句对白；'
          '主角本章至少做一次有代价的主动选择；对话占比提到 25%~45%；'
          '只删与剧情无关的水段（删多少就补多少，见上文【字数硬约束】）；句子尽量 25 字内，段落不超过 3 行。')
      ..writeln('**题材与世界观必须与本作一致**：不得出现现代词汇、不得更换主角、不得引入新故事线。')
      ..writeln('**只输出改写后的正文**：不要任何解释、说明、前言、字数报告或操作描述（写进正文即判废）。');
    return b.toString();
  }
}
