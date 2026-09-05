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

要求输出以下 JSON（不要 Markdown 包裹）：
{
  "title": "小说名（4~8 字）",
  "protagonist": {"name": "$hero", "trait": "性格特征", "origin": "出身"},
  "world": {"continent": "大陆/背景名", "power_system": "境界/体系（6~8 阶）", "faction": "主要势力"},
  "hook": "开篇钩子（一句话，制造好奇）",
  "chapter_outlines": [
    {"idx": 1, "title": "第1章标题", "goal": "本章核心节拍（40字以内）", "target": $perChapter},
    ...至少 $chapters 章，总目标字数 $totalWords 字
  ]
}''';
}

/// 章节场景规划。
String scenePlanningPrompt(String outline, String prevSummary) {
  final StringBuffer s = StringBuffer()
    ..writeln('下面是一章的纲。请把它拆成 3~5 个「各有结构目标的」场景（起承转合）。')
    ..writeln()
    ..writeln('章纲：$outline');
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
}) {
  final StringBuffer s = StringBuffer()
    ..writeln('这是本章第 $sceneNo/$totalScenes 个场景（$stage）。本场景任务：$goal。');
  if (beats.isNotEmpty) {
    s.writeln('必须完成的节拍：${beats.join(' → ')}');
  }
  s.writeln('用具体物件承载设定（如一枚玉简的裂纹、第三级台阶上的青苔），不要说明文。');
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

/// 整章去AI味润色。
String editorPrompt(String text) {
  return '''
请把下面的小说章节改写得更像真人网文作者的手笔：

1. 全篇「仿佛/似乎/宛如」合计不超过 2 次；清除「嘴角勾起」「眼底闪过」「空气凝固」「深吸一口气」「空气像是被人抽走」等 AI 高频表达
2. 情节、人物、伏笔、章节结尾的钩子必须全部保留，不新增、不删减剧情
3. 对话更口语化、更有潜台词；描写更具体（数字、颜色、气味、声响），允许更「糙」、更有网文节奏
4. 保持原有段落结构

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
      'goal': '收束本章并埋下钩子',
      'beats': <String>[],
      'targetWords': (targetWords * 0.2).round().clamp(300, 900),
    },
  ];
}
