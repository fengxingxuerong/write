#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""各角色提示词（Prompt）层：纯字符串构建，无 I/O、无网络。

2026-10-10 从 novel_pipeline.py 拆出（该文件 2587 行，属「上帝文件」；此前已拆出
pipeline_llm「LLM 调用层」与 foreshadow「伏笔台账」）。拆分依据是**内聚性边界**：
本模块只负责把结构化输入拼成给模型看的系统/用户提示词，不含任何调用、判据或
流水线状态；导入本模块不触网、不读文件，可独立单测。

对外接口：调用方仍从 novel_pipeline 取同名转发（见该文件 import 处）。

⚠ 拆分红线（与 pipeline_llm / foreshadow 同一条）：只降低维护成本，**不改对外契约**；
函数体逐字搬运、未做任何改写。
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from generate_novel import count_words, registry_block, facts_block  # noqa: E402
from fanqie_review import FIX_MIN_RATIO  # noqa: E402


PLANNER_SYS = "你是一位资深网文总编，擅长长篇小说的框架规划。输出严格遵循要求的 JSON 格式。"


EDITOR_SYS = "你是一位资深网文编辑，专精「去AI味」改写。"


TITLER_SYS = "你是一位网文章名提炼师，擅长从章节内容提炼短而带悬念的章名，只输出章名本身。"


VERIFIER_SYS = "你是一位严谨的长篇小说一致性审校编辑。"


OUTLINE_REVIEWER_SYS = "你是番茄/起点资深内容主编，在大纲阶段就为签约稿把关。只输出严格 JSON。"


def payoff_repair_prompt(full_text, registry="", facts="", drought_len=0):
    """情绪强化定点修提示词：只补外显爽点，其余一律不许动。

    与 `generate_novel.emotion_fix_prompt` 同款要求（保持主线/姓名/数字不变），
    此处补一条**断供语境**：跨章连续缺外显爽点时点明章数，让模型知道
    「不是本章没写爽点，是连着若干章都没有」，处方更对症。
    """
    ctx = ""
    if drought_len >= 3:
        ctx = (f"\n【背景】本书已连续 {drought_len} 章没有出现读者可感知的"
               f"「外显爽点」（打脸/收获/揭露/当众反应），追读正在流失——"
               f"本章必须补上一处，且要外部可见。\n")
    reg = f"\n【配角户籍表】\n{registry}\n" if registry else ""
    num = f"\n【数字台账】\n{facts}\n" if facts else ""
    return f"""下面这章小说情节完整，但缺少读者可感知的「外显爽点」，移动端读者会弃书。
{ctx}请输出强化后的全章正文，要求：
- 主线情节、人物姓名、数字设定一律不变；
- 选章内一个冲突场景，补一处「外部可见」的爽点：对手当众吃瘪的反应 / 关键物件入手的触感细节 / 真相反转时在众人的震惊，三选一；
- 禁止只写主角内心感受充当爽点（如「他感到修为精进」）；
- 保持原有字数规模（±20% 内），不要另起新情节。
{reg}{num}
【原章正文】
{full_text}

只输出强化后的全章正文："""


def editor_prompt(text, style_block=""):
    keep = ""
    if style_block:
        keep = ("\n5. 下列文风分布必须保持（改稿同样向其靠拢，不得把这些指标"
                "改离参考文）：\n" + style_block)
    return f"""请把下面的小说章节改写得更像真人网文作者的手笔：

1. 全篇「仿佛/似乎/宛如」合计不超过 2 次；清除「嘴角勾起」「眼底闪过」「空气凝固」「深吸一口气」「空气像是被人抽走」等 AI 高频表达
2. 情节、人物、伏笔、章节结尾的钩子必须全部保留，不新增、不删减剧情
3. 对话更口语化、更有潜台词；描写更具体（数字、颜色、气味、声响），允许更「糙」、更有网文节奏
4. 保持原有段落结构
{keep}
只输出改写后的完整正文，不要任何解释或前缀。

【章节正文】
{text}"""


def titler_prompt(text):
    return f"""为下面的章节内容提炼一个章名。要求：
1. 字数严格控制在 4~10 字，越短越好；
2. 要有悬念感、点击欲，符合网文章名习惯（如「废柴之辱」「残魂入体」「血玉现世」）；
3. 禁止整句照抄正文，禁止带引号、冒号、逗号等标点的长句（如「送餐遇前任，桌上压着百元钞」不合格）；
4. 只输出章名本身，不要任何解释、引号或序号。

【章节内容】
{text[:500]}"""


def verifier_prompt(outline, chapters):
    return f"""以下是本书的大纲设定与已生成章节的标题列表。请检查：1) 世界观设定是否自相矛盾；2) 人物名称/身份是否混乱；3) 剧情是否有明显断裂或逻辑硬伤。

只输出 JSON（不要 Markdown 包裹）：{{"issues":[{{"chapter":N,"type":"矛盾类型","desc":"一句话说明"}}]}}
无问题则输出：{{"issues":[]}}

【大纲设定】
{json.dumps(outline, ensure_ascii=False)[:1500]}

【已生成章节】
{chapters}"""


def quality_review_prompt(text, qa_evidence=""):
    """语义级五维评分（开篇/爽点/钩子/动机/节奏），输出 JSON。

    qa_evidence：本地质检证据（钩子有无/爽点密度/AI 味/爽点落点），注入后 LLM 评审带证据打分，
    避免与本地检测互相矛盾（终审官实测抓到「评审 100 分但钩子无」的分裂案例）。"""
    ev = ""
    if qa_evidence:
        ev = f"\n【本地质检证据（规则引擎实测，评分时必须与之对照，不得与证据矛盾）】\n{qa_evidence}\n"
    return f"""请以网文编辑的眼光为下面的章节打分（每项 0~100）：
1. opening：开篇是否快速进入事件、有代入感（黄金三章标准）
2. thrill：爽点密度与强度（打脸/升级/收获/秘密揭露，以及三视角侧面反响/震惊链闭环）
3. hook：章末钩子是否让人想看下一章（悬念/变故/威胁）
4. motivation：人物动机是否清晰、行为是否合理
5. rhythm：节奏是否张弛有度、无注水、无流水账（压抑蓄水后是否及时释放打脸）
{ev}
严格输出 JSON（不要 Markdown 包裹）：
{{"scores":{{"opening":85,"thrill":60,"hook":90,"motivation":75,"rhythm":80}},"overall":78,"comment":"一句话点评（30字内）"}}

【章节正文】
{text}"""


def rewrite_prompt(text, comment, scores):
    """低分章节定向重写（保留情节与钩子，针对薄弱维度改进）。"""
    dims = ""
    if scores:
        dims = "薄弱维度参考：" + " ".join(f"{k}={v}" for k, v in scores.items())
    return f"""你是资深网文编辑。下面的章节质量评分偏低，请重写以提升质量：

- 保留原情节、人物、伏笔、章末钩子，不新增、不删减剧情
- 针对薄弱维度重点改进：开篇快速进入事件 / 爽点密度 / 章末钩子 / 人物动机 / 节奏
- 反AI腔：全篇「仿佛/似乎/宛如」合计不超过 2 次，禁用万能描写
- 保持原有段落结构，总字数与原作相当（只多不少）

原评语：{comment}
{dims}

【章节正文】
{text}

只输出重写后的完整正文，不要任何解释或前缀。"""


def state_extract_prompt(text, prev_state):
    """跨章状态提取：维护状态清单供下一章写作遵守（防人物状态断片 + 防剧情重复线）。"""
    prev = prev_state if prev_state and prev_state.strip() else "（无）"
    return f"""你是长篇小说状态管理员。请根据本章内容，维护一份「跨章状态清单」，供下一章写作时遵守，防止人物状态断片（如上一章断腿、下一章健步如飞），并防止剧情重复线（如上一章已取走遗物、下一章又设计一次取遗物）。

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
{prev}

【本章内容】
{text}"""


FACT_CHECK_SYS = "你是独立事实核查员，只输出 JSON，不要任何解释。"


def fabrication_check_prompt(chapter_text, registry, state_track, idx):
    """编造核查 prompt：对照已确立事实核查本章正文的编造/篡改。"""
    reg = registry_block(registry) or "（空）"
    facts = facts_block(registry) or "（无已确立数字）"
    return f"""对照下列已确立事实，核查第 {idx} 章正文是否编造/篡改了事实：
1. 身份矛盾：给户籍表内姓名安排了不同身份/职业/立场
2. 数字漂移：同一事项的金额/期限/数量与数字台账不一致（新事项首次出现的数字不算问题）
3. 状态矛盾：与跨章状态清单冲突的伤势/修为/物品得失
4. 无中生有：把前文从未确立的细节当前文既定事实引用（凭空师门/恩怨/旧约）

只输出 JSON：
{{"fabrications":[{{"claim":"正文问题断言原句节选（30字内）","evidence":"对照依据","type":"identity|number|state|fabricated"}}]}}
没有问题就输出 {{"fabrications":[]}}。

【配角户籍表】
{reg}

【数字台账】
{facts}

【跨章状态清单】
{state_track or "（无）"}

【第 {idx} 章正文】
{chapter_text}"""


def fact_fix_prompt(chapter_text, fabrications, idx):
    """编造定点修 prompt：只处置核查命中的断言，其余段落一字不动。

    三条处置路径（优先删/弱化）：无据断言要么删，要么改成非断言（传闻/未证实），
    要么在本章内补出「谁、何时、为何、在哪」变成本章首次确立的设定。
    字数下限沿用 FIX_MIN_RATIO——删掉的部分必须用等量铺陈补回，禁止「以删代修」。
    """
    words = count_words(chapter_text or "")
    floor = int(words * FIX_MIN_RATIO)
    items = []
    for fb in fabrications[:8]:
        claim = str(fb.get("claim", "")).strip()
        if not claim:
            continue
        ev = str(fb.get("evidence", "")).strip() or "台账/前文无据"
        items.append(f"- [{fb.get('type', 'fabricated')}] 断言「{claim}」｜核查依据：{ev}")
    listing = "\n".join(items) or "- （无明细，按「无据断言」类型自行定位）"
    floor_line = ""
    if floor:
        floor_line = (f"【字数硬约束】改写后正文不得少于 {floor} 字（原文 {words} 字）："
                      "删掉的断言要用等量的铺陈/对白补回，禁止整段删除凑字数差。\n")
    return f"""第 {idx} 章被独立事实核查员判出 {len(fabrications)} 处与户籍表/数字台账/跨章状态无据的断言。
请**只处置下列断言**，其余段落一字不改；人名、事件顺序、已确立的台账数字、章末钩子必须原样保留：
{listing}

每处断言按优先级三选一：
1. 删掉该断言；或
2. 改写成非断言（传闻/猜测/未证实的口气，如「据说…」「他也不确定…」），确保后续章节不会把它当既定事实；或
3. 确为剧情必需时，在本章内补出来龙去脉（谁在何时为何、在哪儿），让它成为本章首次确立的设定。
{floor_line}
只输出改写后的完整正文，不要任何解释、说明或前言。

【第 {idx} 章正文】
{chapter_text}"""


def reader_proxy_prompt(text, genre):
    """读者官 prompt（第 12 角色）：以追读读者视角回答三问。

    输出纯文本 3 行（非 JSON，与状态提取同理——轻任务避免解析失败）：
    追不追 / 哪里想划走 / 下一章最想看到什么。反馈注入下一章场景规划。"""
    return f"""你是一位番茄小说的重度读者，正在追一本{genre}小说。你刚看完下面这一章，
凭真实读感回答三个问题（每问一行，共 3 行，每行不超过 40 字，直说不客气）：

1. 追：下一章你点不点？【追 / 犹豫 / 弃】，加半句原因
2. 弃点：本章哪一段你想划走或快进（没有写"无"）
3. 期待：下一章你最想看到什么（具体到情节，不写空话）

只输出这 3 行，不要任何解释、序号以外的格式。

【本章正文】
{text}"""


def chief_editor_prompt(outline, chapters, reviews, state_track,
                        foreshadow_ledger, genre, total_words):
    """终审官 prompt：全书收官总评。输入结构化摘要 + 样本正文，避免整本塞不下。"""
    rev_map = {r["idx"]: r for r in reviews}
    lines = []
    for c in chapters:
        r = rev_map.get(c["idx"], {})
        lines.append(
            f"第{c['idx']}章《{c.get('title', '')}》{c.get('words', 0)}字｜"
            f"评审{r.get('score', '-')}分｜钩子{'有' if c.get('_has_hook') else '无'}｜"
            f"AI味{c.get('_ai_echo_pct', 0)}%｜问题{len(c.get('issues', []))}处")
    chapter_table = "\n".join(lines) if lines else "（无章节数据）"

    first = chapters[0].get("content", "")[:1200] if chapters else ""
    last = chapters[-1].get("content", "")[:1200] if chapters else ""
    worst_idx = min(reviews, key=lambda r: r.get("score", 100))["idx"] if reviews else 0
    worst_ch = next((c for c in chapters if c["idx"] == worst_idx), None)
    worst_text = (worst_ch.get("content", "")[:800] if worst_ch else "（无）")

    open_fs = []
    try:
        ledger = json.loads(foreshadow_ledger) if foreshadow_ledger else {}
        for it in ledger.get("foreshadows", []):
            if it.get("status") == "open":
                open_fs.append(f"第{it.get('planted', '?')}章埋：{it.get('desc', '')[:40]}")
    except Exception:
        pass
    fs_text = "\n".join(open_fs[:12]) if open_fs else "（无未收伏笔）"
    state_text = state_track if state_track and state_track.strip() else "（无）"

    return f"""你是番茄/起点的资深签约终审编辑。这本书已完稿，请你像审签约稿一样给出最终总评。
你看到的是全书结构化摘要（逐章指标）+ 关键样本正文（首章/末章/评分最低章），不是全文——
请基于这些证据判断，不要臆造没出现的问题。

【书籍信息】
书名：《{outline.get('title', '')}》｜题材：{genre}｜总字数：{total_words}｜章节数：{len(chapters)}

【逐章指标】
{chapter_table}

【跨章状态清单（最终版）】
{state_text}

【未收伏笔台账】
{fs_text}

【样本正文一：第 1 章开头 1200 字】
{first}

【样本正文二：末章开头 1200 字】
{last}

【样本正文三：评分最低的第 {worst_idx} 章开头 800 字】
{worst_text}

【终审要求】
从签约编辑视角评估六个维度（各 0-100）：开篇钩子、节奏曲线（是否有中期塌陷）、
人物弧光（主角动机-成长-代价是否完整）、爽点与期待感（追读动力）、
伏笔回收（结合台账判断悬空风险）、结局力度（末章样本是否给读者交代与余韵）。
问题要具体到章（引用逐章指标里的证据），修改建议要可执行（改哪章、怎么改）。

只输出 JSON（不要 Markdown 代码块）：
{{"overall": 0-100总分, "verdict": "高潜可投|可投|需打磨|不建议",
 "dimensions": {{"开篇钩子": n, "节奏曲线": n, "人物弧光": n, "爽点与期待感": n, "伏笔回收": n, "结局力度": n}},
 "top_issues": [{{"chapter": n, "issue": "问题", "evidence": "指标证据"}}],
 "fix_priority": ["修改建议1", "修改建议2", "修改建议3"],
 "对标": "一句话说明这本书对标番茄哪类成功作品/差距在哪"}}"""


def chief_rewrite_prompt(chapter_text, issue, evidence, fix_hint):
    """终审打回重写 prompt：定向修复终审官指出的问题，其余不动。"""
    issue_text = (issue or {}).get("issue", "") if isinstance(issue, dict) else str(issue or "")
    evidence_text = (issue or {}).get("evidence", "") if isinstance(issue, dict) else ""
    return f"""你是资深网文编辑。终审编辑审读全书后，把本章打回重写。请定向修复下述问题：

【终审官指出的问题】{issue_text}
【指标证据】{evidence_text}
【修改方向参考】{fix_hint or '（无，按问题自行判断）'}

重写要求：
- 只修复上述问题，保留原有情节走向、人物、已埋伏笔、章末钩子，不新增不删减剧情
- 修复处要自然融入上下文，不要出现"补丁感"
- 反AI腔：全篇「仿佛/似乎/宛如」合计不超过 2 次，禁用万能描写
- 总字数与原章相当（只多不少）

【本章正文】
{chapter_text}

只输出重写后的完整正文，不要任何解释或前缀。"""


def structure_fix_prompt(outline, chapters, state_track, foreshadow_ledger, genre,
                         chief_report, max_new):
    """结构打回 prompt：终审官二审不达标后，交规划官决定是否增补收尾章。

    与写前守门（大纲终审官）互补：守门在动笔前拦结构缺陷，结构打回在收官后
    补救"伏笔悬空/缺结局"这类修章治不了的病。"""
    ch_lines = []
    for c in chapters:
        ch_lines.append(f"第{c['idx']}章《{c.get('title', '')}》：{str(c.get('goal', ''))[:60]}")
    ch_table = "\n".join(ch_lines) if ch_lines else "（无）"
    open_fs = []
    try:
        ledger = json.loads(foreshadow_ledger) if foreshadow_ledger else {}
        for it in ledger.get("foreshadows", []):
            if it.get("status") == "open":
                open_fs.append(f"- 第{it.get('planted', '?')}章埋：{str(it.get('desc', ''))[:50]}")
    except Exception:
        pass
    fs_text = "\n".join(open_fs) if open_fs else "（无未收伏笔）"
    issues = chief_report.get("top_issues") or []
    issue_text = "\n".join(f"- 第{it.get('chapter', '?')}章：{it.get('issue', '')}" for it in issues[:6]) or "（无）"
    fixes = "\n".join(f"- {x}" for x in (chief_report.get("fix_priority") or [])[:4]) or "（无）"
    last_idx = max((c.get("idx", 0) for c in chapters), default=0)
    return f"""你是网文总规划官。终审编辑审读全书后给出了结构级问题，请你决定：是否增补收尾章。

【全书信息】书名《{outline.get('title', '')}》｜题材：{genre}｜当前 {len(chapters)} 章（第 1~{last_idx} 章）

【已有章节】
{ch_table}

【未收伏笔台账】
{fs_text}

【终审官指出的问题】
{issue_text}

【终审官修改建议】
{fixes}

【跨章状态清单（最终版）】
{state_track or '（无）'}

【规划要求】
1. 若「伏笔悬空/缺结局/主线未收束」确需收尾：输出 1~{max_new} 个收尾章章纲。收尾章必须：
   - 自然回收上面列出的主要伏笔（goal 里点名回收哪几条、怎么收）
   - 给主线冲突一个阶段性交代（大典/决战/摊牌），并留续作余韵
   - idx 从 {last_idx + 1} 顺延；title 不超过 8 字；goal 按四元组
  （新信息=…｜变化=…｜主角选择=…｜钩子=…，各键值 15~40 字）外加「回收伏笔=…」键，
  缺任一四元组键视为不合格
2. 若判定现有章节已能自洽收尾、加章反而注水：输出空数组，并给出一句话理由。
3. 严格沿用已有世界观、人物与设定，不得新增主角、不改已有设定。
4. 只输出 JSON（不要 Markdown 代码块）：
{{"new_chapters": [{{"idx": {last_idx + 1}, "title": "不超过8字", "goal": "新信息=…｜变化=…｜主角选择=…｜钩子=…｜回收伏笔=…", "hook": "章末钩子一句话"}}], "reason": "一句话理由"}}"""


def verify_promises_prompt(text, promise_lines, chapter_idx):
    return f"""你是伏笔回收验收员。下面是第 {chapter_idx} 章正文和「必兑现清单」，
请逐条核验正文是否真的兑现了清单要求（答案是否落到纸面；只暗示/留白/远景铺陈不算兑现）。

【必兑现清单】
{promise_lines}

【章节正文】
{text}

只输出 JSON（不要 Markdown 代码块）：
{{"results": [{{"id": 序号, "fulfilled": true或false, "evidence": "正文证据句，不超过20字（未兑现则填缺失原因，不超过20字）"}}]}}"""


def outline_review_prompt(outline, genre, total_words, max_chapters):
    """大纲终审官 prompt：写前守门。只查「写进正文后修章治不了」的结构级缺陷。
    检查清单由真实成书教训沉淀（《断脉逆命诀》：第 1 章 6 条伏笔全悬、末章停"大典前夕"）。"""
    o = json.dumps(outline, ensure_ascii=False, indent=1)
    return f"""你是番茄/起点资深内容主编。规划编辑刚交来一部长篇网文的大纲，
动笔前请你做结构级把关——只看大纲本身，判断这本书"按此大纲写下去"会不会出结构性硬伤。

【书籍信息】题材：{genre}｜目标总字数：{total_words}｜章数上限：{max_chapters}｜实际规划章数：{len(outline.get('chapter_outlines', []))}

【大纲全文】
{o}

【结构级检查清单（逐项过）】
1. 伏笔分布：单章新埋伏笔不得超过 2 条；第 1 章只允许埋 1-2 条核心伏笔，
   严禁把全书伏笔塞进第 1 章（真实教训：某书第 1 章埋 6 条伏笔、全书仅 6 章，终审时全部悬空）。
   每条伏笔必须在后续章节章纲里有对应的回收/推进安排；伏笔总数不超过章节数 × 0.8。
2. 末章必须有结局：最后一章章纲必须是决战/收尾/回收型，要写出结果与余韵；
   严禁停在大典前夕/出发前夜/计划进行中这类"前夕态"（真实教训：某书末章停"大典前夕"，
   终审官二审以 66 分打回且无法用修章解决）。
3. 单章信息密度：每章新增设定（新势力/新规则/新人物关系）不超过 2 个，超载章列出来。
4. 钩子链：每章章纲的"钩子"要素是否存在且类型有变化；连续两章同型钩子（如连续"威胁逼近"）算弱。
5. 主线闭环：主角动机-目标-障碍-代价在大纲层面是否闭环；金手指是否带代价约束。
6. 节奏分布：是否存在连续 2 章无冲突推进/纯铺垫的中段塌陷区。

【输出要求】
只输出 JSON（不要 Markdown 代码块）。发现问题（pass=false）时必须给出修订后的完整大纲：
结构键与原大纲完全一致（title/blurb/tags/protagonist/world/hook/chapter_outlines），
只修问题，不改书名/主角名/世界观主干/题材，章节数不得减少：

{{"pass": true或false,
 "overall": 0到100的整数,
 "issues": [{{"chapter": "全局或章号", "issue": "问题", "evidence": "大纲中的证据"}}],
 "advice": ["一句话修改方向1", "方向2"],
 "revised_outline": {{...仅 pass=false 时必填，修订版全量大纲 JSON...}}}}

pass=true 时可省略 revised_outline。"""
