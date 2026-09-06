/// 多模型协作流水线 —— Prompt 模板。
///
/// 与 `scripts/novel_pipeline.py` / `generate_novel.py` 对齐，
/// 写作准则已在 10 万字实测中验证有效。
library;

/// 正文写手的系统准则（「让读者看见、听见、感受到」）。
const String writerSystemPrompt = '''
你是一位笔力深厚的中文小说作家，信条是「让读者看见、听见、感受到」。

【核心技法】
1. 展示而非陈述：情绪一律通过动作、微表情、生理反应与物件细节外化。
2. 具体战胜抽象：数字、颜色、气味、声响越具体越好。
3. 对话即交锋：每段对话都有潜台词，禁止「他愤怒地说」式情绪标注。
4. 五感轮换：每个场景至少调动视觉之外的两种感官。
5. 节奏张弛：紧张处短句急推，舒缓处长句舒展。
6. 结尾留钩：收尾必须落在悬念、变故、反常细节或未落地的威胁上。
7. 变强具象化（含蓄爽点）：主角成长不写总结（不直说「他突破了」），写身体异动——丹田那团温热像种子顶开土、掌心旧疤开始发烫、经脉深处有什么东西苏醒、第一圈周天成了。金手指要有生命感：像鱼翻了个身、像沉睡的东西睁开眼。

【网文商业结构（番茄签约级）】
- 黄金三章：第 1 章前 300 字内必须发生变故/异象/羞辱/获得，让主角立刻陷入非解决不可的局面；前三章各埋一个「必须往下看」的理由。
- 爽点优先：每章至少 1 个爽点——打脸、升级、收获、秘密揭露四选一，放在章内后半段（先抑后扬）。玄幻/仙侠升级爽点优先用「变强具象化」含蓄写法，直白词（突破/觉醒）至多出现 1 次，其余靠身体异动承载。
- 章末钩子强制：每一章结尾必须落在未落地的悬念上（敌人逼近、秘密将揭、奖励未取、威胁升级），禁止平稳收尾。

【反AI腔自查】全篇「仿佛/似乎/宛如」合计不超过 2 次；禁用万能描写「嘴角勾起」「眼底闪过」「空气凝固」；禁用空泛总结「命运的车轮」「人生的轨迹」。

【输出规则】只输出小说正文，不带标题/章节号/Markdown；段与段之间用空行分隔。''';

/// 总规划官系统提示。
const String plannerSystemPrompt =
    '你是一位资深网文总编，擅长长篇${'{genre}'}小说的框架规划。'
    '输出严格遵循要求的 JSON 格式，不要 Markdown 包裹。';

/// 去AI味编辑系统提示。
const String editorSystemPrompt = '你是一位资深网文编辑，专精「去AI味」改写。';

/// 标题官系统提示。
const String titlerSystemPrompt =
    '你是一位网文标题专家，擅长提炼有悬念感、点击欲的章名。';

/// 一致性审校系统提示。
const String verifierSystemPrompt =
    '你是一位严谨的长篇小说一致性审校编辑。';

/// 第一步：全书大纲规划。
String planningPrompt({
  required int totalWords,
  required String genre,
  String protagonist = '',
}) {
  final int chapters = totalWords ~/ 3000 < 20 ? 20 : totalWords ~/ 3000;
  final int perChapter = totalWords ~/ chapters;
  final String hero = protagonist.trim().isEmpty ? '主角名' : protagonist;
  return '''
请构思一本长篇$genre小说（$totalWords字量级）的完整框架。${protagonist.trim().isEmpty ? '主角名你来定。' : '主角名：$hero。'}

【商业结构要求（番茄签约级）】
- 黄金三章：第 1~3 章必须完成「身份落差展示 → 金手指/机缘获得 → 第一个威胁或目标确立」，
  每章结尾都要留钩子；第 1 章在 300 字内让主角遭遇变故（废柴受辱/穿越/异象降临/危机临头）。
- 每章节拍 goal 必须写明「本章爽点」（打脸/升级/收获/秘密揭露四选一）与「本章钩子」（未落地悬念）。
- 全书要有明确的升级主线与阶段目标，每 3~5 章一个「小高潮」。

要求输出以下 JSON（不要 Markdown 包裹）：
{
  "title": "小说名（4~8 字）",
  "protagonist": {"name": "$hero", "trait": "性格特征", "origin": "出身"},
  "world": {"continent": "大陆/背景名", "power_system": "境界/体系（6~8 阶）", "faction": "主要势力"},
  "hook": "开篇钩子（一句话，制造好奇）",
  "chapter_outlines": [
    {"idx": 1, "title": "第1章标题", "goal": "本章核心节拍（40字以内，含爽点+钩子）", "target": $perChapter},
    ...至少 $chapters 章，总目标字数 $totalWords 字
  ]
}''';
}

/// 章节场景规划。
String scenePlanningPrompt(
  String outline,
  String prevSummary, {
  String state = '',
}) {
  final StringBuffer s = StringBuffer()
    ..writeln('下面是一章的纲。请把它拆成 3~5 个「各有结构目标的」场景（起承转合）。')
    ..writeln()
    ..writeln('【规划要求】')
    ..writeln('- 本章至少安排 1 个「外显爽点」场景（优先级：打脸 > 收获 > 秘密揭露 > 升级）：')
    ..writeln('  · 打脸：冲突对方当众吃瘪（哑口无言/脸色铁青/颜面扫地）；')
    ..writeln('  · 收获：具体宝物/机缘/情报到手，有可感知的细节（触感/光泽/重量）；')
    ..writeln('  · 秘密揭露：关键身份或真相反转，在场人物震惊；')
    ..writeln('  · 若选升级：必须写出外部可见反应（威压外放/众人震惊/对手变色/境界显化），')
    ..writeln('    不能只停留在内心与身体感受；')
    ..writeln('- 爽点场景放在章内后半段（先抑后扬，压抑后释放）；')
    ..writeln('- 最后一个场景必须是「合」：负责收束本章并埋下章末钩子（未落地悬念）；')
    ..writeln('- 黄金三章：若这是全书第 1 章，第一个场景必须在 300 字内触发变故/异象/羞辱/获得。')
    ..writeln()
    ..writeln('章纲：$outline');
  if (state.trim().isNotEmpty) {
    s
      ..writeln()
      ..writeln('【跨章状态（场景必须遵守，不可与此矛盾）】')
      ..writeln(state.trim());
  }
  if (prevSummary.isNotEmpty) {
    s
      ..writeln()
      ..writeln('上一章结尾的情境（本场景必须承接，不可矛盾）：')
      ..writeln(prevSummary);
  }
  s
    ..writeln()
    ..writeln('每场景 400~800 字，总目标 2000~3000 字。严格输出 JSON：')
    ..writeln(
        '{"scenes":[{"index":0,"stage":"起","goal":"本场景任务（20字内）","beats":["节拍1","节拍2"],"targetWords":600}]}');
  return s.toString();
}

/// 单场景正文生成。
String scenePrompt({
  required int sceneNo,
  required int totalScenes,
  required String stage,
  required String goal,
  required List<String> beats,
  required String prevText,
  String state = '',
}) {
  final StringBuffer s = StringBuffer()
    ..writeln('这是本章第 $sceneNo/$totalScenes 个场景（$stage）。本场景任务：$goal。');
  if (beats.isNotEmpty) {
    s.writeln('必须完成的节拍：${beats.join(' → ')}');
  }
  s.writeln('用具体物件承载设定（如一枚玉简的裂纹、第三级台阶上的青苔），不要说明文。');
  s.writeln('若本场景是爽点场景：爽点必须「落地可见」——打脸写对手当众反应'
      '（哑口无言/脸色铁青/颜面扫地），收获写具体物件入手的细节（触感/光泽/重量），'
      '揭露写在场人物的震惊与连锁反应；禁止只用内心感受充当爽点'
      '（如「他感到修为精进」）而没有外部反馈。');
  if (state.trim().isNotEmpty) {
    s.writeln();
    s.writeln('【跨章状态（人物伤势/修为/物品/承诺必须与此一致，不得自相矛盾）】');
    s.writeln(state.trim());
  }
  if (sceneNo == totalScenes) {
    s.writeln('这是本章最后一个场景：结尾必须留下未落地的钩子'
        '（悬念/变故/威胁逼近/秘密将揭），让读者必须看下一章。');
  }
  if (prevText.isNotEmpty) {
    s
      ..writeln()
      ..writeln('上一段的情境（必须承接）：')
      ..writeln(prevText.length > 150 ? prevText.substring(prevText.length - 150) : prevText);
  }
  s
    ..writeln()
    ..writeln('只输出场景正文：');
  return s.toString();
}

/// 跨章状态提取：从本章内容维护「跨章状态清单」，供下一章写作遵守。
///
/// 只提取硬状态（伤势/修为/物品/承诺/地点），不写心理活动。
/// 输出纯文本（3~8 行），非 JSON，避免解析失败风险。
String stateExtractPrompt(String text, String prevState) {
  return '''
你是长篇小说状态管理员。请根据本章内容，维护一份「跨章状态清单」，供下一章写作时遵守，防止人物状态断片（如上一章断腿、下一章健步如飞）。

只记录硬状态：
- 人物伤势（含恢复情况）、修为/境界变化
- 随身物品的获得/丢失
- 承诺、恩怨、伪装身份
- 关键地点变化

要求：
1. 在旧状态基础上增删改，不要整段重写
2. 每条一行，格式：人物：状态；物品：xxx
3. 输出 3~8 行，简洁具体
4. 只输出状态清单文本，不要任何解释或 Markdown

【旧状态】（首次为空）
${prevState.isEmpty ? '（无）' : prevState}

【本章内容】
$text''';
}

/// 整章去AI味润色。
String editorPrompt(String text) {
  return '''
请把下面的小说章节改写得更像真人网文作者的手笔：

1. 全篇「仿佛/似乎/宛如」合计不超过 2 次；清除「嘴角勾起」「眼底闪过」「空气凝固」「深吸一口气」「空气像是被人抽走」等 AI 高频表达
2. 情节、人物、伏笔、章节结尾的钩子必须全部保留，不新增、不删减剧情
3. 对话更口语化、更有潜台词；描写更具体（数字、颜色、气味、声响），允许更「糙」、更有网文节奏
4. 保持原有段落结构
5. 检查章节结尾：如果结尾平淡收尾，微调最后 1~2 句，让悬念/变故/威胁更醒目（不新增剧情，只强化钩子）

只输出改写后的完整正文，不要任何解释或前缀。

【章节正文】
$text''';
}

/// 章节标题提炼。
String titlerPrompt(String text) {
  final String head = text.length > 500 ? text.substring(0, 500) : text;
  return '''
为下面的章节内容提炼一个 8~15 字的章名，要有悬念感和网文味。只输出章名本身。

【章节内容】
$head''';
}

/// 章节语义级质量评分（五维：开篇/爽点/章末钩子/人物动机/节奏）。
///
/// 由审校官（verifier）执行，输出结构化 JSON，低于 60 分的章节
/// 在流水线中标记告警（只记录不阻塞）。
String qualityReviewPrompt(String text) {
  return '''
请以网文编辑的眼光为下面的章节打分（每项 0~100）：
1. opening：开篇是否快速进入事件、有代入感（黄金三章标准）
2. thrill：爽点密度与强度（打脸/升级/收获/秘密揭露；含蓄变强具象化也算）
3. hook：章末钩子是否让人想看下一章（悬念/变故/威胁）
4. motivation：人物动机是否清晰、行为是否合理
5. rhythm：节奏是否张弛有度、无注水、无流水账

严格输出 JSON（不要 Markdown 包裹）：
{"scores":{"opening":85,"thrill":60,"hook":90,"motivation":75,"rhythm":80},"overall":78,"comment":"一句话点评（30字内）"}

【章节正文】
$text''';
}

/// 低分章节定向重写（针对薄弱维度提升质量，保留情节与钩子）。
String rewritePrompt({
  required String text,
  required String reviewComment,
  required Map<String, dynamic>? scores,
}) {
  final String dims = (scores == null || scores.isEmpty)
      ? ''
      : '薄弱维度参考：${scores.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
  return '''
你是资深网文编辑。下面的章节质量评分偏低，请重写以提升质量：

- 保留原情节、人物、伏笔、章末钩子，不新增、不删减剧情
- 针对薄弱维度重点改进：开篇快速进入事件 / 爽点密度 / 章末钩子 / 人物动机 / 节奏
- 反AI腔：全篇「仿佛/似乎/宛如」合计不超过 2 次，禁用万能描写
- 保持原有段落结构，总字数与原作相当（只多不少）

原评语：$reviewComment
$dims

【章节正文】
$text

只输出重写后的完整正文，不要任何解释或前缀。''';
}

/// 跨章一致性审校。
String verifierPrompt(String outlineJson, String chapterList) {
  return '''
以下是本书的大纲设定与已生成章节的标题列表。请检查：1) 世界观设定是否自相矛盾；2) 人物名称/身份是否混乱；3) 剧情是否有明显断裂或逻辑硬伤。

只输出 JSON（不要 Markdown 包裹）：{"issues":[{"chapter":N,"type":"矛盾类型","desc":"一句话说明"}]}
无问题则输出：{"issues":[]}

【大纲设定】
${outlineJson.length > 1500 ? outlineJson.substring(0, 1500) : outlineJson}

【已生成章节】
$chapterList''';
}

/// 默认场景骨架（LLM 场景规划失败时兜底）。
///
/// 返回「起承转合」四场景的默认规划，保证任何情况下章节都能生成。
List<Map<String, dynamic>> defaultScenePlan(int targetWords) {
  return <Map<String, dynamic>>[
    <String, dynamic>{
      'stage': '起',
      'goal': '场景铺垫：进入本章情境，确立目标',
      'beats': <String>[],
      'targetWords': (targetWords * 0.3).round().clamp(400, 1200),
    },
    <String, dynamic>{
      'stage': '承',
      'goal': '事件推进，冲突升级',
      'beats': <String>[],
      'targetWords': (targetWords * 0.25).round().clamp(400, 1000),
    },
    <String, dynamic>{
      'stage': '转',
      'goal': '局势逆转，危机爆发',
      'beats': <String>[],
      'targetWords': (targetWords * 0.25).round().clamp(400, 1000),
    },
    <String, dynamic>{
      'stage': '合',
      'goal': '收束本章并留下章末钩子（悬念/变故/未落地威胁）',
      'beats': <String>[],
      'targetWords': (targetWords * 0.2).round().clamp(300, 900),
    },
  ];
}
