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
7. 成长与异象必须「落地可感」：不写总结（不直说「他突破了」），写题材内部可验证的反馈——在场者的反应、物件的位移、伤势与资源的增减、身体最诚实的一处反应；具体比喻只从本书题材取，不得拿别的题材的术语与意象填空。
8. 反重复：章末禁止用「醒了／苏醒／发烫／亮起来」这类「身体异动 + 发光物件」收束；开场禁止以天气起手；同一比喻全书只用一次。

【网文商业结构（番茄签约级）】
- 黄金三章：第 1 章前 300 字内必须发生变故/异象/羞辱/获得，让主角立刻陷入非解决不可的局面；前三章各埋一个「必须往下看」的理由。
- 爽点优先：每章至少 1 个爽点——打脸、升级、收获、秘密揭露四选一，放在章内后半段（先抑后扬）。玄幻/仙侠可用本题材专属的身体意象承载升级（不得外溢到其他题材），直白词（突破/觉醒）至多出现 1 次。
- 章末钩子强制：每一章结尾必须落在未落地的悬念上（敌人逼近、秘密将揭、奖励未取、威胁升级），禁止平稳收尾。

【反AI腔自查】全篇「仿佛/似乎/宛如」合计不超过 2 次；禁用万能描写「嘴角勾起」「眼底闪过」「空气凝固」；禁用空泛总结「命运的车轮」「人生的轨迹」。

【番茄过审硬门槛】
- 移动端排版：一段不超过 3 行（约 80 字）；一句尽量不超过 25 字；每 3~5 段插一个只有一行的「喘气段」。
- 对白占比 25%~45%：对白独立成段，每句必须给新信息、施加压力或暴露性格；禁止寒暄与复述已知事实。
- 每章四件套（缺一项即不合格）：一个新信息、一次局势变化（力量/关系/资源/名声可指认的改变）、一次主角主动选择且当场付出代价、一个未落地钩子。
- 首屏 300 字：主角在场、正在做事、有东西可失去；第一句就有异常或压力，第二段出现对白或动作冲突；背景只能以「正在被使用的形式」出现。
- 可替换性自检：删掉不影响剧情的段落一律重写，禁止用环境/回忆/心理凑字数。

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
/// genreOpening[genre] 提供题材专属开场变故提示（与 Python 端 GENRE_SPECS.opening 对齐）。
const Map<String, String> genreOpening = <String, String>{
  '玄幻': '前 300 字内主角当众受辱（被踩/被斥/被夺机缘），或异象降临（灵脉觉醒/天降传承）。',
  '仙侠': '前 300 字内主角遭遇灭门/逐出师门/灵根被废/大比败北，或天降机缘（残卷/古玉认主）。',
  '都市': '前 300 字内主角被当众羞辱（被上司/前任/势利眼打脸、被裁员、被催债逼到墙角），用具体场景快速立住卑微处境。',
  '都市异能': '前 300 字内主角遭遇致命危机（车祸/坠楼/被袭击）并触发异能觉醒。',
  '科幻': '前 300 字内主角遭遇突发事件（舰船遇袭/殖民站告急/被AI判定异常/收到来历不明信号），危机具象到物件与数值。',
  '末世': '前 300 字内末日爆发（变异体破门/丧尸潮/营地被劫），或主角在废土被欺压抢掠，生存危机立即显性化。',
  '游戏': '前 300 字内主角穿越/进入游戏即遭险境（新手村异变/被NPC围攻/系统异常），金手指与危机同时登场。',
  '悬疑': '前 300 字内主角接到异样委托/匿名电话/发现异常现场，立即抛出一个必须回答的核心疑问。',
  '武侠': '前 300 字内主角当众受辱、遭灭门/逐出师门/被废武功，恩怨立即点燃。',
  '历史': '前 300 字内主角遭遇家变（抄家/贬谪/通婚逼嫁/被构陷下狱）或朝堂风波，权谋冲突必须立即显性化，忌慢热铺陈。',
  '军事': '前 300 字内主角陷入战场绝境（被包围/任务失败/遭诬陷叛国/队友牺牲），立即进入生死关头。',
  '体育': '前 300 字内主角当众受辱（被对手碾压/被教练放弃/选拔赛被刷），或关键比赛开场即落后。',
};

String planningPrompt({
  required int totalWords,
  required String genre,
  String protagonist = '',
}) {
  final int chapters = totalWords ~/ 3000 < 20 ? 20 : totalWords ~/ 3000;
  final int perChapter = totalWords ~/ chapters;
  final String hero = protagonist.trim().isEmpty ? '主角名' : protagonist;
  final String opening = genreOpening[genre] ?? '前 300 字内让主角遭遇变故（受辱/穿越/异象/危机临头）。';
  return '''
请构思一本长篇$genre小说（$totalWords字量级）的完整框架。${protagonist.trim().isEmpty ? '主角名你来定。' : '主角名：$hero。'}

【商业结构要求（番茄签约级）】
- 黄金三章：第 1~3 章必须完成「身份落差展示 → 金手指/机缘获得 → 第一个威胁或目标确立」，
  每章结尾都要留钩子；第 1 章在 300 字内让主角遭遇变故。
- 第 1 章开场变故（$genre专属，必须严格执行）：$opening
- 主角名必须原创且贴合题材：禁止「林尘/陈默/林峰/林浩/苏婉/陈昆/周野」等烂大街名；优先 2 字冷门姓氏+生僻组合，避免林/陈/李/王/张/刘六大大姓。
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
  String worldHint = '',
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
    ..writeln('- 【禁止重复线】状态清单中标注「已完成」的物品获得/事件（如已取走遗物、已获传承、')
    ..writeln('  已对峙过某反派），本章不得重复设计同一情节；收获类场景必须换新机缘或推进原线。')
    ..writeln()
    ..writeln('章纲：$outline');
  if (worldHint.trim().isNotEmpty) {
    s
      ..writeln()
      ..writeln('【全书世界观（规划官设定，本章场景必须严格遵循，不得另起体系/改名换设定）】')
      ..writeln(worldHint.trim());
  }
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
  String genre = '',
  String protagonist = '',
  String world = '',
  bool isOpening = false,
}) {
  final StringBuffer s = StringBuffer();
  if (genre.isNotEmpty) {
    s.writeln('本书题材：$genre。');
  }
  if (world.isNotEmpty) {
    s.writeln('本书世界观（必须沿用，不得改写或另起设定）：$world');
  }
  if (protagonist.isNotEmpty) {
    s
      ..writeln('本章主角：$protagonist。全章只用这个名字，禁止改名、别名或新增有名字的角色。')
      ..writeln('【主角名片】场景中首次出现主角时必须自然带出名字（对话称呼/名牌/他人介绍/身份描写均可），'
          '让读者在前 300 字内记住「$protagonist」这个名字及其处境；禁止长时间用「他/她」指代。');
  }
  if (isOpening && genre.isNotEmpty) {
    final String opening = genreOpening[genre] ?? '前 300 字内让主角遭遇变故（受辱/穿越/异象/危机临头）。';
    s.writeln('【开场变故·硬约束】这是全书第 1 章第 1 场景：前 300 字内必须发生「$opening」，事件先行，禁止慢热铺陈环境。');
  }
  s.writeln('这是本章第 $sceneNo/$totalScenes 个场景（$stage）。本场景任务：$goal。');
  if (beats.isNotEmpty) {
    s.writeln('必须完成的节拍：${beats.join(' → ')}');
  }
  s.writeln('用具体物件承载设定（如一枚玉简的裂纹、第三级台阶上的青苔），不要说明文。');
  s.writeln('若本场景是爽点场景：爽点必须「落地可见且带震惊环」——'
      '① 打脸写对手当众绝望崩溃（哑口无言/脸色惨白/难以置信）；'
      '② 写吃瓜围观者的侧面反响（倒吸冷气/失声惊呼/认知颠覆）；'
      '③ 收获写具体物件入手的细节（触感/光泽/重量），揭露写在场上位者的重新审视；'
      '禁止只用内心感受充当爽点（如「他感到修为精进」）而没有外部反馈。');
  s.writeln('【新设定锚点】本章若首次引入新设定（怪物/神器/地名/体系），必须自带解释锚点'
      '（角色传闻/物件来历/回忆闪回一句即可），禁止裸奔抛出新名词让读者摸不着头脑。');
  if (state.trim().isNotEmpty) {
    s.writeln();
    s.writeln('【跨章状态（人物伤势/修为/物品/承诺必须与此一致，不得自相矛盾）】');
    s.writeln(state.trim());
  }
  if (sceneNo == totalScenes) {
    s.writeln('这是本章最后一个场景：结尾必须留下未落地的钩子'
        '（悬念/变故/威胁逼近/秘密将揭），让读者必须看下一章；禁止用发热/发光/苏醒类身体异动收束。');
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
/// 只提取硬状态（伤势/修为/物品/关系/承诺/地点），不写心理活动。
/// 输出纯文本（3~10 行），非 JSON，避免解析失败风险。
String stateExtractPrompt(String text, String prevState) {  return '''
你是长篇小说状态管理员。请根据本章内容，维护一份「跨章状态清单」，供下一章写作时遵守，防止人物状态断片（如上一章断腿、下一章健步如飞），并防止剧情重复线（如上一章已取走遗物、下一章又设计一次取遗物）。

只记录硬状态：
- 人物伤势（含恢复情况）、修为/境界变化
- 人物关系（谁是谁的父亲/师父/仇家等——关系确立后不得改写换人，防关系张冠李戴）
- 随身物品的获得/丢失（含具体物名：玉简/银戒/灰布/断剑/钥匙等）
- 承诺、恩怨、伪装身份
- 关键地点变化
- 已发生的关键事件（探秘/寻宝/获传承/对峙等，注明已完成，下章不得重复设计同一事件）

要求：
1. 在旧状态基础上增删改，不要整段重写
2. 每条一行，格式：人物：状态；关系：A是B的师父；物品：xxx；事件：xxx（已完成）
3. 输出 3~10 行，简洁具体
4. 只输出状态清单文本，不要任何解释或 Markdown

【旧状态】（首次为空）
${prevState.isEmpty ? '（无）' : prevState}

【本章内容】
$text''';
}

/// 伏笔台账提取：从本章内容维护「伏笔台账」，防止长篇丢伏笔/改设定。
///
/// 只记录设定级伏笔（神秘物件/预言/身份谜团/异常现象/承诺恩怨），
/// 输出严格 JSON（非纯文本，便于结构化检查回收状态）。
String foreshadowExtractPrompt(String text, String prevLedger, int idx) {
  final String prev = prevLedger.trim().isEmpty ? '[]' : prevLedger;
  return '''
你是长篇小说伏笔管理员。请根据本章内容（第 $idx 章），维护一份「伏笔台账」，防止长篇写作丢伏笔/改设定。

只记录设定级伏笔（后文必须回收的）：
- 神秘物件/信物（银鱼/断剑/古玉等）及其来源谜团
- 预言/警告/神秘声音（"记住这个形状"类）
- 身份谜团（某人真实身份/来历）
- 异常现象（异象/异动/神秘组织行动）
- 角色承诺/恩怨（欠债/血仇/约定）

规则：
1. 本章新埋的伏笔 → 新增条目（planted=当前章号, status=open）
2. 本章回收/揭晓的伏笔 → 对应条目标 recovered=当前章号, status=closed
3. 在旧台账基础上增删改，不要重写无关条目
4. 只输出 JSON（不要 Markdown），格式：
{"foreshadows":[{"desc":"伏笔描述（一句话）","planted":1,"recovered":null,"status":"open"}]}

【旧台账】
$prev

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
///
/// [qaEvidence]：本地质检证据（钩子命中/爽点密度等，与 Python 端
/// quality_review_prompt 的 qa_evidence 参数同口径）。注入后 LLM 评审
/// 带证据打分，避免与本地规则引擎互相矛盾（「100 分无钩子」类分裂）。
String qualityReviewPrompt(String text, {String qaEvidence = ''}) {
  final String ev = qaEvidence.isEmpty
      ? ''
      : '\n【本地质检证据（规则引擎实测，评分时必须与之对照，不得与证据矛盾）】\n$qaEvidence\n';
  return '''
请以网文编辑的眼光为下面的章节打分（每项 0~100）：
1. opening：开篇是否快速进入事件、有代入感（黄金三章标准）
2. thrill：爽点密度与强度（打脸/升级/收获/秘密揭露，以及三视角侧面反响/震惊链闭环）
3. hook：章末钩子是否让人想看下一章（悬念/变故/威胁）
4. motivation：人物动机是否清晰、行为是否合理
5. rhythm：节奏是否张弛有度、无注水、无流水账（压抑蓄水后是否及时释放打脸）
$ev
严格输出 JSON（不要 Markdown 包裹）：
{"scores":{"opening":85,"thrill":60,"hook":90,"motivation":75,"rhythm":80},"overall":78,"comment":"一句话点评（30字内）"}

【章节正文】
$text''';
}

/// 独立事实核查员的系统提示（关卡5）。
///
/// 与 Python `novel_pipeline.FACT_CHECK_SYS` 逐字一致：「只输出 JSON，不要解释」。
const String factCheckSystemPrompt = '你是独立事实核查员，只输出 JSON，不要任何解释。';

/// 编造核查 prompt（关卡5）：对照已确立事实核查本章正文的编造/篡改。
///
/// 四类判据与 Python `fabrication_check_prompt` 完全一致——身份矛盾 / 数字漂移 /
/// 状态矛盾 / 无中生有，**新事项首次出现的数字不算问题**（否则第一章必被误判满屏
/// 编造）。[registry] 是配角户籍表，[facts] 是数字台账，[stateTrack] 是跨章状态清单。
String fabricationCheckPrompt(
  String text,
  int idx, {
  String registry = '',
  String facts = '',
  String stateTrack = '',
}) {
  final String reg = registry.trim().isEmpty ? '（空）' : registry;
  final String fact = facts.trim().isEmpty ? '（无已确立数字）' : facts;
  final String st = stateTrack.trim().isEmpty ? '（无）' : stateTrack;
  return '''
对照下列已确立事实，核查第 $idx 章正文是否编造/篡改了事实：
1. 身份矛盾：给户籍表内姓名安排了不同身份/职业/立场
2. 数字漂移：同一事项的金额/期限/数量与数字台账不一致（新事项首次出现的数字不算问题）
3. 状态矛盾：与跨章状态清单冲突的伤势/修为/物品得失
4. 无中生有：把前文从未确立的细节当前文既定事实引用（凭空师门/恩怨/旧约）

只输出 JSON：
{"fabrications":[{"claim":"正文问题断言原句节选（30字内）","evidence":"对照依据","type":"identity|number|state|fabricated"}]}
没有问题就输出 {"fabrications":[]}。

【配角户籍表】
$reg

【数字台账】
$fact

【跨章状态清单】
$st

【第 $idx 章正文】
$text''';
}

/// 编造定点修 prompt：只处置核查命中的断言，其余段落一字不动。
///
/// 三条处置路径（优先删/弱化）：无据断言要么删，要么改成非断言（传闻/未证实），
/// 要么在本章内补出「谁、何时、为何、在哪」变成本章首次确立的设定。
/// [minWords] 是字数硬下限（对齐 Python `FIX_MIN_RATIO=0.92` 的意图）——
/// 删掉的断言必须用等量铺陈补回，**禁止「以删代修」**（Python 端实测：定点修
/// 若无字数下限，模型会把整章压掉 30%~75%，产出被 0.85 守卫整份拒绝、白跑一轮）。
String factFixPrompt(
  String text,
  List<FabricationSpec> fabrications,
  int idx, {
  required int minWords,
}) {
  final StringBuffer items = StringBuffer();
  int n = 0;
  for (final FabricationSpec fb in fabrications) {
    if (n >= 8) break;
    final String claim = fb.claim.trim();
    if (claim.isEmpty) continue;
    items.writeln(
      '- [${fb.typeLabel}] 断言「$claim」｜核查依据：'
      '${fb.evidence.trim().isEmpty ? '台账/前文无据' : fb.evidence.trim()}',
    );
    n++;
  }
  final String listing = n == 0 ? '- （无明细，按「无据断言」类型自行定位）' : '$items';
  final int words = _hanCount(text);
  final String floorLine = minWords > 0
      ? '【字数硬约束·先看这条】改写后正文不得少于 $minWords 字（原文 $words 字）：'
            '删掉的断言要用等量的铺陈/对白补回，禁止整段删除凑字数差。\n'
      : '';
  return '''
第 $idx 章被独立事实核查员判出 ${fabrications.length} 处与户籍表/数字台账/跨章状态无据的断言。

【待处置清单】
$listing

【处置要求】
- 逐条处置，每条三选一：① 删掉该断言；② 改写成非断言（传闻/未证实/疑似）；
  ③ 在本章内补出「谁、何时、为何、在哪」，使它变成本章首次确立的设定。
- **只处置上述命中**，其余段落一字不动，不要重写全章、不要改变已成立的情节走向。
- 不要用「以删代修」：字数下限让位于评审的压缩诉求。
$floorLine
【第 $idx 章正文】
$text''';
}

/// 定点修提示词用的一条编造命中（与模型层 [Fabrication] 解耦，
/// 免得 prompt 层反向依赖 `ai_pipeline_models.dart`）。
class FabricationSpec {
  /// 断言原句节选。
  final String claim;

  /// 对照依据。
  final String evidence;

  /// 原始类型标识（identity/number/state/fabricated）。
  final String type;

  /// 构造一条命中。
  const FabricationSpec({
    required this.claim,
    required this.evidence,
    required this.type,
  });

  /// 类型中文名（未知类型原样返回）。
  String get typeLabel => switch (type) {
        'identity' => '身份矛盾',
        'number' => '数字漂移',
        'state' => '状态矛盾',
        'fabricated' => '无中生有',
        _ => type,
      };
}

/// 统计文本中的汉字数（与流水线正文字数口径一致：只数汉字，不数标点空白）。
int _hanCount(String s) {
  int n = 0;
  for (final int c in s.codeUnits) {
    if (c >= 0x4E00 && c <= 0x9FFF) n++;
  }
  return n;
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
