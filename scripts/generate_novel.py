#!/usr/bin/env python3
"""墨匠长篇小说生成器 —— 多 pass + 跨章质检 + 断点续传

用法:
  python generate_novel.py --provider openai \
    --base-url "https://developer.amd.com.cn/radeon/api/v1/chat/completions" \
    --model "DeepSeek-V4-Flash" \
    --api-key <你的AMD API Key，或设置环境变量 NOVEL_LLM_API_KEY> \
    --total-words 8000 \
    --output my_novel.jsonl

按 Ctrl+C 中断后再次运行同一命令即可断点续传。
"""

import argparse
import json
import os
import re
import sys
import time

# 强制 print 实时刷新
_real_print = print
def print(*args, **kwargs):
    kwargs.setdefault("flush", True)
    _real_print(*args, **kwargs)

# 支持 `python -m scripts.generate_novel` 与直接脚本执行两种入口。
# 放在 fanqie_* 相对导入之前，避免模块方式运行时找不到同目录文件。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Windows 控制台默认 GBK：质检报告含 ✓/✗ 等字符会 UnicodeEncodeError
# 直接把 stdout/stderr 重配为 UTF-8（失败时退化为 replace，绝不让报告打印炸掉主流程）
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# ============================================================
# Prompts（与 Dart WritingGuidelines + 多 pass 引擎对齐）
# ============================================================
# 写作准则已迁到 fanqie_prompts.py：每一条都能被 fanqie_review.py 量化检查，
# 避免旧版「准则教套路、质检数词表」的自相矛盾。
from fanqie_prompts import FANQIE_SYSTEM_PROMPT as SYSTEM_PROMPT  # noqa: E402
from fanqie_review import (  # noqa: E402
    dialogue_ratio,
    ending_triad,
    extract_world_terms,
    filler_ratio,
    fix_prompt,
    review_chapter,
    self_repeat_ratio,
)
# 字数唯一定义在 fanqie_review（下方 count_words 只做薄转发，见该处说明）。
from fanqie_review import count_words as _count_words  # noqa: E402

# 词表/阈值单一数据源（rules/quality_rules.json 的生成物，与 Dart QualityRules 同源）。
# ⚠ 以下词表在 generate_novel 内部已无直接消费点（消费方随拆分迁到 gen_quality），
# 但为保持 `from generate_novel import HOOK_WORDS` 的对外契约（tool/probe_ending_triad
# 等脚本）仍继续转发，故标 noqa: F401。AI_ADVERBS/NEGATION/BODY_REACTION_WORDS/
# SENTENCE_CONNECTORS 改由 gen_quality 转发（见下方 gen_quality import 块）。
from quality_rules_generated import (  # noqa: E402,F401
    HOOK_WORDS,
    OPENING_STRONG,
    OPENING_WEAK,
    POWER_SURGE_WORDS,
    SIDE_REACTION_WORDS,
    THRILL_WORDS,
    TRIAD_HOOK_ONLY,
)


from fanqie_prompts import GOLDEN3_SPEC as _GOLDEN3, GOAL_FORMAT as _GOAL_FORMAT  # noqa: E402

# ============================================================
# 通用流式 LLM 调用 + JSON 解析（2026-10-10 从本文件拆出 -> gen_llm.py）
# ============================================================
# 转发导入而非直接定义，是为了让调用点（本文件 main 及仓库内 15+ 个
# `from generate_novel import ...` / `import generate_novel as gn` 的脚本与测试）
# 零改动——拆分只降低维护成本，不改对外契约；函数体逐字搬运、未改写。
from gen_llm import (  # noqa: E402,F401
    is_reasoning_model, call_llm, repair_json, _sanitize_ctrl,
    parse_json_from_llm,
)

# ============================================================
# 质检指标 + 文本卫生（2026-10-10 从本文件拆出 -> gen_quality.py）
# ============================================================
# 转发导入而非直接定义，是为了让调用点（本文件 main 及仓库内 15+ 个
# `from generate_novel import ...` / `import generate_novel as gn` 的脚本与测试）
# 零改动——拆分只降低维护成本，不改对外契约；函数体逐字搬运、未改写。
from gen_quality import (  # noqa: E402,F401
    AI_CLICHE, NEGATION, OPENING_ACTION_WORDS, GENRE_THRILL_EXTRA,
    GENRE_THRILL_ALL, thrill_per_thousand, GENRE_SURGE_EXTRA, GENRE_SURGE_ALL,
    surge_per_thousand, side_reaction_per_thousand, release_profile, payoff_drought_zones,
    payoff_drought_ev_fragment, release_ev_fragment, AI_ADVERBS, SENTENCE_CONNECTORS,
    METAPHOR_PAT, BODY_REACTION_WORDS, SINGLE_PARA_MAX_CHARS, _style_fingerprint_metrics,
    STYLE_FP_LIMITS, _split_sentences, deep_ai_metrics, style_fingerprint,
    style_fingerprint_block, fingerprint_distance, load_style_block, style_ev_fragment,
    has_ending_hook, has_quick_opening,
)

# 题材规格表（新增题材只需在此登记；planning/scene 两处 prompt 自动生效）
# label: 题材定位（进规划官 prompt）| world: 世界观 JSON 字段提示 | anchor: 场景物件锚点
# opening: 开场变故提示（黄金三章第 1 章前 300 字必须触发的变故类型，题材专属）
GENRE_SPECS = {
    "玄幻": {
        "label": "废柴逆袭·东方修仙",
        "world": '"continent": "自拟大陆专名（例：渊陆）", "power_system": "自拟 6~8 阶境界链，每阶要有名字（例：淬体→开脉→凝罡→化神→归一）", "faction": "自拟 2~3 个具名势力（例：太衍宗／北镇司／漕帮）"',
        "anchor": "用具体物件承载设定（如一枚玉简的裂纹、第三级台阶上的青苔），不要说明文。写「变强」可用题材专属的身体意象：丹田那团温热像种子顶开土、掌心旧疤发烫、经脉深处苏醒、第一圈周天成了（仅此题材可用，不得外溢到其他题材）。",
        "opening": "前 300 字内主角当众受辱（被踩/被斥/被夺机缘），或异象降临（灵脉觉醒/天降传承），必须让读者立刻意识到主角处于低谷且有上升空间。",
    },
    "仙侠": {
        "label": "凡人修仙·问道长生",
        "world": '"continent": "自拟州名（例：云州·赤县）", "power_system": "沿用炼气→筑基→金丹→元婴→化神→渡劫，并为每阶自拟别称与寿数", "faction": "自拟宗门专名（例：青冥剑宗／洗髓阁）"',
        "anchor": "用具体物件承载设定（如一枚磨损的传功玉简、洞府门口被踩亮的青石阶、丹炉底的焦痕），不要说明文。写气机可用「像鱼在水底翻了个身」「沉睡的东西睁开眼」一类意象，但全书不得重复同一句。",
        "opening": "前 300 字内主角遭遇灭门/逐出师门/灵根被废/宗门大比当众败北等变故，或天降机缘（捡到残卷/古玉认主），让读者立即进入危机或机遇。",
    },
    "都市": {
        "label": "都市逆袭·草根崛起",
        "world": '"city": "自拟城市+区（例：津港市·北仑区）", "power_system": "自拟具体职级与金额阶梯（例：外卖员→片区代理→股东，欠款 47 万）", "faction": "自拟公司/家族专名（例：恒川资本·周家）"',
        "anchor": "用具体物件承载设定（如出租屋的墙皮、工牌上的照片、一张旧名片、写字楼的电梯按钮），不要说明文。",
        "opening": "前 300 字内主角被当众羞辱（被上司/前任/势利眼打脸、被裁员、被催债逼到墙角），用具体场景（办公室/餐厅/出租屋）快速立住卑微处境。",
    },
    "都市异能": {
        "label": "都市觉醒·异能入世",
        "world": '"city": "自拟城市+区（例：临江市·纱厂商住区）", "power_system": "自拟异能等级与考核机构（例：D→C→B→A→S，由「九处」评级）", "faction": "自拟组织专名（例：拂晓会／特别事故管理局）"',
        "anchor": "用具体物件承载设定（如异能徽章、基地的合金门、监控屏上的异常数值、一管试剂），不要说明文。",
        "opening": "前 300 字内主角遭遇致命危机（车祸/坠楼/被袭击）并触发异能觉醒，或发现自己与常人的异常差异，立即进入『为什么是我』的悬念。",
    },
    "科幻": {
        "label": "星际征途·硬核科幻",
        "world": '"galaxy": "自拟星域+站点（例：猎户旋臂·裂隙星域／灰港 7 号船坞）", "power_system": "自拟技术等级与能源专名（例：曲速 C~S，能源「星髓」结晶）", "faction": "自拟 2~3 个具名势力（例：星环联邦／灰潮财阀／深渊教会）"',
        "anchor": "用具体物件承载设定（如船舱壁的划痕、能源核心的读数、旧殖民地的锈蚀警示牌），不要说明文。",
        "opening": "前 300 字内主角遭遇突发事件（舰船遇袭/殖民站告急/被AI判定异常/收到来历不明的信号），危机必须具象到物件与数值。",
    },
    "末世": {
        "label": "末世求生·废土重建",
        "world": '"zone": "自拟幸存区编号+地名（例：第 9 幸存区·水泥厂）", "power_system": "自拟进化序列与检测手段（例：一阶·抗侵蚀，凭针剂配额判定）", "faction": "自拟据点/商队专名（例：铁栅哨站／南运队）"',
        "anchor": "用具体物件承载设定（如最后一罐净水、墙上的血字、变异体的齿痕、废弃超市的货架），不要说明文。",
        "opening": "前 300 字内末日爆发（变异体破门/丧尸潮涌来/幸存者营地被劫），或主角在废土被欺压抢掠，生存危机必须立即显性化。",
    },
    "游戏": {
        "label": "游戏穿越·全息争霸",
        "world": '"server": "自拟游戏名+服务器（例：《深渊回廊》S17）", "power_system": "自拟职业+等级+关键数值（例：47 级狂战，战力 1200，金币 3 枚 200 铜）", "faction": "自拟公会/阵营名（例：赤旗会／拍卖行）"',
        "anchor": "用具体物件承载设定（如技能面板的裂纹、掉落的稀有装备、NPC 的固定台词、仓库里的旧头盔），不要说明文。",
        "opening": "前 300 字内主角穿越/进入游戏即遭险境（新手村异变/被NPC围攻/系统异常/死亡惩罚异常），金手指与危机同时登场。",
    },
    "悬疑": {
        "label": "迷雾追凶·悬疑探案",
        "world": '"city": "自拟城市+案发点（例：临江市·城东废弃冷库）", "power_system": "自拟办案链条与权限层级（刑警→支队长→检方批捕，48 小时时限）", "faction": "自拟单位/组织专名（例：城南分局二队／周氏物流）"',
        "anchor": "用具体物件承载设定（如一张泛黄的旧照片、案卷上的指纹、被雨水泡皱的报纸、一把生锈的钥匙），不要说明文。",
        "opening": "前 300 字内主角接到异样委托/匿名电话/发现异常现场（尸体/信物/失踪者遗留物），立即抛出一个必须回答的核心疑问。",
    },
    "武侠": {
        "label": "快意恩仇·江湖风云",
        "world": '"jianghu": "自拟地名+镖号/门派（例：雁门关·听雨镖局）", "power_system": "自拟内功层次名（例：易骨→换血→归元）", "faction": "自拟门派/世家专名（例：点苍派／晏家）"',
        "anchor": "用具体物件承载设定（如一把缺口的长刀、客栈的烫金匾额、旧镖局的旗子、磨破的绑腿），不要说明文。",
        "opening": "前 300 字内主角当众受辱（被恶少/同门/仇家踩踏）、遭灭门/逐出师门/被废武功，恩怨立即点燃，读者须马上站队。",
    },
    "历史": {
        "label": "权谋天下·架空历史",
        "world": '"dynasty": "自拟朝代+年号（例：大靖·承平三年）", "power_system": "自拟官阶与俸禄/债额（例：从九品·月俸三两；欠银三百两，一文不能少）", "faction": "自拟衙门与门阀（例：户部清吏司／陈氏）"',
        "anchor": "用具体物件承载设定（如一封蜡封的密信、朝服上的补子、官印的缺角、旧城墙上的箭痕），不要说明文。",
        "opening": "前 300 字内主角遭遇家变（抄家/贬谪/通婚逼嫁/被构陷下狱）或朝堂风波（殿前对质/夺嫡暗流），权谋冲突必须立即显性化，忌慢热铺陈。",
    },
    "军事": {
        "label": "铁血军魂·现代战争",
        "world": '"battlefield": "自拟会战名+地形天气（例：302 高地·雨季泥沼）", "power_system": "自拟军衔、装备型号与基数（例：上士，7.62 机枪，一个基数 250 发）", "faction": "自拟番号（例：侦察连／独立营）"',
        "anchor": "用具体物件承载设定（如一枚磨损的军牌、弹匣上的刻痕、作战靴的泥渍、残缺的战旗），不要说明文。",
        "opening": "前 300 字内主角陷入战场绝境（被包围/任务失败/遭诬陷叛国/队友牺牲），立即进入生死关头，军人的硬核技能当场显性化。",
    },
    "体育": {
        "label": "热血赛场·冠军之路",
        "world": '"arena": "自拟赛事+场馆（例：全国青年联赛·北辰体育馆）", "power_system": "自拟段位/排名与技术指标（例：省队候补，纵跳 62cm，12 分钟跑 3100m）", "faction": "自拟俱乐部/教练组（例：雷霆青训／体能教练老穆）"',
        "anchor": "用具体物件承载设定（如一双磨破的球鞋、更衣室的战术板、老旧的奖杯、缠胶带的护腕），不要说明文。",
        "opening": "前 300 字内主角当众受辱（被对手碾压/被教练放弃/选拔赛被刷/旧伤复发被嘲笑），或关键比赛开场即落后，热血与屈辱同时点燃。",
    },
}

def planning_prompt_idea(total_words=200000, prev_summary="", genre="玄幻", used_names=None):
    """第一步：生成整体构思。根据目标总字数自动推算章数与每章目标字数。
    prev_summary 非空时要求新大纲承接已发生剧情（续写模式）。genre 为题材（见 GENRE_SPECS）。
    used_names 为既有书籍已用主角名列表（跨书查重，避免规划官惯性起名）。"""
    spec = GENRE_SPECS.get(genre, GENRE_SPECS["玄幻"])
    GOLDEN3 = _GOLDEN3
    GOAL_FORMAT = _GOAL_FORMAT
    # 每章容量下限 2000 字：番茄单章 2000~3000，旧写法在 short run（--total-words 小）
    # 时会算出 per_chapter=200，导致章纲与实际正文差 10 倍、节奏分配整层失效。
    chapters = max(3, total_words // 3000)
    per_chapter = max(2000, total_words // chapters)
    s = f"""请构思一本长篇{genre}小说（{total_words}字量级）的完整框架。题材：{spec['label']}。

【商业结构要求（番茄签约级）】
{GOLDEN3}
- 第 1 章开场变故（{genre}专属，必须严格执行）：{spec['opening']}
{GOAL_FORMAT}
- 全书要有明确的升级主线与阶段目标，每 3~5 章一个「小高潮」。
- world 的每个值必须是**自拟的具体专名或数值**。禁止照抄类别名——
  写「大陆名」「朝代名」「星域名」「联赛舞台」这类占位词视为不合格，
  因为写手与评审器据此都拿不到任何可用设定。
- 主角名必须原创且贴合题材：禁止使用「林尘/陈默/林峰/林浩/苏婉/陈昆/周野」等烂大街或已被占用的名字；优先取 2 字冷门姓氏 + 生僻但不拗口的组合（如裴照/顾沉舟/霍去病式），避免林/陈/李/王/张/刘六大大姓；同一本书内所有角色名互不重复。
"""
    if used_names:
        s += f"- 跨书查重：以下主角名已被其他书籍使用，本次【绝对禁止】再使用（包括同音字、近形字变体）：「{'/'.join(used_names)}」。必须另起一个全新的冷门名。\n"
    s += f"""要求输出以下 JSON（不要 Markdown 包裹）。重要：所有字符串值内禁止出现换行符（blurb 的"三行式"用句号分隔，不要真的换行）：
{{
  "title": "小说名（6~12 字，含题材关键词与爽点承诺）",
  "title_candidates": ["书名1", "书名2", "书名3"],
  "blurb": "120~160 字简介（三行式：处境 / 机遇与代价 / 悬念反问）",
  "tags": ["题材标签", "爽点标签", "情绪标签"],
  "protagonist": {{"name": "主角名", "trait": "性格特征", "origin": "出身"}},
  "world": {{ {spec['world']} }},
  "hook": "开篇钩子（一句话，制造好奇）",
  "chapter_outlines": [
    {{"idx": 1, "title": "第1章标题", "goal": "新信息=…｜变化=…｜主角选择=…｜钩子=…（四元组，缺一项视为不合格）", "target": {per_chapter}}},
    ...至少 {chapters} 章，总目标字数 {total_words} 字
  ]
}}"""
    if prev_summary:
        s += f"\n【前情提要（新大纲必须承接以上已发生剧情，主角/世界观延续，不得与既有剧情矛盾）】\n{prev_summary}\n"
    return s


def scene_planning_prompt(outline, prev_summary, state="", protagonist="", genre="玄幻", world_hint="",
                          registry="", facts=""):
    """为每一章拆场景。state 为跨章状态清单（人物伤势/修为/物品/承诺）。
    protagonist 非空时强制场景只使用该主角名，禁止另起别名/新角色名。
    genre 为题材（见 GENRE_SPECS）。world_hint 为全书大纲世界观（JSON 片段），
    防止正文写手脱离规划官设定的世界体系自由发挥（历史事故：大纲裴照系统流、
    正文写成赵铁柱超自然流）。"""
    spec = GENRE_SPECS.get(genre, GENRE_SPECS["玄幻"])
    s = f"""下面是一章的纲。请把它拆成 3~5 个「各有结构目标的」场景（起承转合）。题材：{spec['label']}。

【规划要求】
- 本章至少安排 1 个「外显爽点」场景（优先级：打脸 > 收获 > 秘密揭露 > 升级）：
  · **该场景的 goal 必须以「外显爽点：」开头**（下游写手按此关键词触发硬约束，
    goal 被限死 20 字内，若不写这四个字则写手收不到「必须写外部反应」的要求）：
  · 打脸：冲突对方当众吃瘪（哑口无言/脸色铁青/颜面扫地）；
  · 收获：具体宝物/机缘/情报到手，有可感知的细节（触感/光泽/重量）；
  · 秘密揭露：关键身份或真相反转，在场人物震惊；
  · 若选升级：必须写出外部可见反应（威压外放/众人震惊/对手变色/境界显化），
    不能只停留在内心与身体感受；
- 爽点场景放在章内后半段：先抑后扬，压抑蓄水不超过全章 60%，全章最后一个爽点必须落在 50% 之后（质检按「爽点落点」核对）；
- 最后一个场景必须是「合」：负责收束本章并埋下章末钩子（未落地悬念）；
- 黄金三章：若这是全书第 1 章，第一个场景必须在 300 字内触发变故/异象/羞辱/获得；
- 【禁止重复线】状态清单中标注「已完成」的物品获得/事件（如已取走遗物、已获传承、已对峙过某反派），本章不得重复设计同一情节；收获类场景必须换新机缘或推进原线。

章纲：{outline}
"""
    if protagonist:
        s = f"本章主角：{protagonist}。所有场景必须使用「{protagonist}」为主角名，禁止另起别名、改名或新增命名角色（章纲明确提到的角色除外）。\n\n" + s
    if world_hint and world_hint.strip():
        s += f"\n【全书世界观（规划官设定，本章场景必须严格遵循，不得另起体系/改名换设定）】\n{world_hint.strip()}\n"
    if state and state.strip():
        s += f"\n【跨章状态（场景必须遵守，不可与此矛盾）】\n{state.strip()}\n"
    if registry:
        s += (f"\n【配角户籍表（已登场角色身份固定：禁止给表内姓名安排不同身份/职业；"
              f"章纲要求的新角色可以登场，但同一姓名全章只能有一个身份）】\n{registry}\n")
    if facts:
        s += f"\n【数字台账·硬约束】\n{facts}\n"
    if prev_summary:
        s += f"\n上一章结尾的情境（本场景必须承接，不可矛盾）：\n{prev_summary}\n"
    s += """
每场景 400~800 字，总目标 2000~3000 字。严格输出 JSON：
{"scenes":[{"index":0,"stage":"起","goal":"本场景任务（20字内）","beats":["节拍1","节拍2"],"targetWords":600}]}"""
    return s


# 章末钩子类型轮换：实测 52% 的章节都落在「发光物件 + 苏醒」一种钩子上，
# 按章号强制轮换比在 prompt 里写「不要重复」管用。
HOOK_TYPES = [
    "威胁逼近（危险已在门外，但尚未与主角接触）",
    "信息反转（一句新事实推翻读者此前的判断）",
    "选择困境（两个选项都要付出代价，被迫当场二选一）",
    "反常细节（一个说不通的小物件或小动作，只陈述不解释）",
    "承诺未兑（已定下的时限或约定出现违约迹象）",
]


def hook_for(chapter_idx):
    """按章号取本章指定的钩子类型。"""
    return HOOK_TYPES[int(chapter_idx) % len(HOOK_TYPES)]


# ============================================================
# 配角户籍表 + 数字台账（2026-09-22 质量事故复盘新增）
# 历史事故：同一配角名跨章换身份（公司经理→当铺老板→收破烂）；
# 金额/期限跨章漂移（47万→23万、三个月→两个月）。
# 机制：每章生成后由 LLM 提取新登场/身份变动角色，登记入册；
# 首见即锁定，后续场景 prompt 强注入，发现冲突只记警示不改原籍。
# ============================================================
def registry_block(registry):
    """把户籍表渲染成 prompt 注入块；空表返回空串。"""
    chars = (registry or {}).get("characters", [])
    if not chars:
        return ""
    lines = ["姓名｜身份（固定，禁止改换职业/身份/立场）｜首次登场｜备注"]
    for c in chars:
        lines.append(f"{c['name']}｜{c.get('identity', '')}｜"
                     f"第 {c.get('first_seen', '?')} 章｜{c.get('note', '')}")
    return "\n".join(lines)


def facts_block(registry):
    """把数字台账渲染成 prompt 注入块；空台账返回空串。"""
    facts = (registry or {}).get("facts", [])
    if not facts:
        return ""
    items = "、".join(f"{f['value']}（第 {f.get('first_seen', '?')} 章确立）" for f in facts)
    return ("以下金额/期限/数量在前文已确立，涉及同一事项时必须沿用原值，"
            "禁止漂移成其他数字：\n" + items)


def extract_registry_prompt(chapter_text, idx, registry):
    """章节生成后提取新登场/身份变动角色。只关心「有名字的角色」。"""
    known = registry_block(registry) or "（空）"
    return f"""你是小说设定整理员。下面是第 {idx} 章正文与既有户籍表。

【既有户籍表】
{known}

【第 {idx} 章正文（节选尾部）】
{chapter_text[-3000:]}

任务：只输出 JSON，不要多余文字。
1. new_characters：本章首次登场的有名字角色（户籍表里没有的），给出身份一句话；
2. changed：户籍表已有、但本章身份/职业/立场明显不同的角色（疑似穿帮），给出本章写法。
{{"new_characters":[{{"name":"...","identity":"..."}}],"changed":[{{"name":"...","identity":"...","note":"..."}}]}}
没有就返回空数组。"""


def merge_registry(registry, extracted, idx):
    """合并提取结果。首见锁定：身份冲突不改原籍，只追加警示备注。返回冲突列表。"""
    registry.setdefault("characters", [])
    by_name = {c["name"]: c for c in registry["characters"]}
    conflicts = []
    for nc in (extracted or {}).get("new_characters", []):
        name = (nc.get("name") or "").strip()
        identity = (nc.get("identity") or "").strip()
        if not name or name in by_name:
            continue
        entry = {"name": name, "identity": identity, "first_seen": idx, "note": ""}
        registry["characters"].append(entry)
        by_name[name] = entry
    for chg in (extracted or {}).get("changed", []):
        name = (chg.get("name") or "").strip()
        old = by_name.get(name)
        if not old:
            continue
        new_id = (chg.get("identity") or "").strip()
        if not new_id or new_id == old.get("identity"):
            continue
        conflicts.append(f"「{name}」户籍身份「{old.get('identity')}」，第 {idx} 章写成「{new_id}」")
        warn = f"⚠第{idx}章曾写成「{new_id}」（穿帮，已按原籍纠正）"
        if warn not in old.get("note", ""):
            old["note"] = (old.get("note", "") + "；" + warn).strip("；")
    return conflicts


# 金额 / 数量 / 期限（阿拉伯与中文数字）
NUM_PAT = re.compile(
    r"[一二三四五六七八九十半\d]+\s*个?(?:月|周|天|日|年|小时|时辰)|"
    r"[\d一二三四五六七八九十百千万]+(?:\.\d+)?\s*(?:万|亿|千|百|块|元|两|枚|条|名|个)")


def extract_key_numbers(text):
    """从文本抽取金额/期限/数量台账项（去重保序）。"""
    seen, out = set(), []
    for m in NUM_PAT.finditer(text or ""):
        v = re.sub(r"\s+", "", m.group(0))
        if v and v not in seen:
            seen.add(v)
            out.append(v)
    return out


def merge_facts(registry, text, idx, cap=40):
    """把本章出现的金额/期限并入数字台账（首见即锁定，cap 防爆）。"""
    registry.setdefault("facts", [])
    known = {f["value"] for f in registry["facts"]}
    for v in extract_key_numbers(text):
        if v not in known:
            registry["facts"].append({"value": v, "first_seen": idx})
            known.add(v)
        if len(registry["facts"]) >= cap:
            break


def emotion_fix_prompt(full_text, registry):
    """零爽点章的情绪强化定点修：只加外部可见爽点，其余一律不许动。"""
    lock = registry_block(registry)
    nums = facts_block(registry)
    reg_section = f"【配角户籍表】\n{lock}\n" if lock else ""
    num_section = f"【数字台账】\n{nums}\n" if nums else ""
    return f"""下面这章小说情节完整，但全程压抑、没有任何外显爽点，移动端读者会弃书。
请输出强化后的全章正文，要求：
- 主线情节、人物姓名、数字设定一律不变；
- 选章内一个冲突场景，补一处「外部可见」的爽点：对手当众吃瘪的反应 / 关键物件入手的触感细节 / 真相反转时在众人的震惊，三选一；
- 禁止只写主角内心感受充当爽点；
- 保持原有字数规模（±20% 内），不要另起新情节。
{reg_section}{num_section}
【原章正文】
{full_text}

只输出强化后的全章正文："""


def scene_prompt(scene_no, total_scenes, stage, goal, beats, prev_text, genre_hint="玄幻",
                 state="", protagonist="", world="", hook="", is_opening=False,
                 registry="", facts="", world_terms=(), style_block=""):
    """单场景生成。state 为跨章状态清单（人物伤势/修为/物品/承诺）。
    genre_hint 为题材（见 GENRE_SPECS）；protagonist/world 为本书已确立的主角名与世界观，
    必须显式注入——缺这两项时写手会自己另起一个故事。
    world_terms 为大纲世界观专名清单：评审按**字面命中**判定「世界观是否落地」，
    只给整段 world 描述时写手会自由转述、专名一个都不落纸面（门禁 v7 第 13 项
    三章连挂「世界观未落地」）。给了清单要求逐场景带出。
    is_opening 为全书第 1 章第 1 场景标记，强制开场变故硬约束。
    style_block 为文风指纹注入块（novel_pipeline --style-ref 模式；空串=不注入）。"""
    spec = GENRE_SPECS.get(genre_hint, GENRE_SPECS["玄幻"])
    s = ""
    if genre_hint:
        s += f"本书题材：{genre_hint}（{spec['label']}）。\n"
    if world:
        s += f"本书世界观（必须沿用，不得改写或另起设定）：{world}\n"
    if world_terms:
        shown = "、".join(world_terms[:10])
        more = "" if len(world_terms) <= 10 else f"（另 {len(world_terms) - 10} 个见大纲）"
        # 名额按下发清单长度收敛：专名池可能只切出 1-2 个（v7 实测《废柴修仙》只有 1 个），
        # 写死「≥2/≥4」会给出做不到的指令，反而诱发堆砌或整段解释设定。
        per_scene = min(2, len(world_terms))
        per_chapter = min(4, len(world_terms))
        # 评审按专名字面命中判定「世界观是否落地」：只给整段世界观描述时，写手会自由转述、
        # 专名一个都不落纸面（门禁 v7 第 13 项连续三章判「世界观未落地」）。
        s += (f"【世界观专名·本章必须落地】本书专名：{shown}{more}。"
              f"本场景至少自然带出其中 {per_scene} 个（全章合计不少于 {per_chapter} 个）："
              "对白称呼、地名/机构/功法/器物名、他人提及、路牌招牌皆可；"
              "专名按字面照抄，禁止改成近义词或简称（评审按字面命中判定「世界观是否落地」）；"
              "禁止把专名列成清单、禁止整段解释设定。\n")
    if protagonist:
        s += f"本章主角：{protagonist}。全章只用这个名字，禁止改名、别名。\n"
        s += (f"【主角名片】场景中首次出现主角时必须自然带出名字（对话称呼/名牌/他人介绍/身份描写均可），"
              f"让读者在前 300 字内记住「{protagonist}」这个名字及其处境；禁止长时间用「他/她」指代。\n")
    if registry:
        s += (f"【配角户籍表】已登场角色的身份/职业/立场固定如下，禁止给表中姓名安排不同身份；"
              f"剧情需要的新角色可以登场，但同一姓名在本场景只能对应一个身份：\n{registry}\n")
    if facts:
        s += f"【数字台账·硬约束】{facts}\n"
    # 预防优于修复：v7 六处编造（老周债务/守夜年数/宽限三天/灵雪被监视/命火令凹槽/地契存放处）
    # 全是「把没确立的细节写成既定事实」——台账里没有的东西，写手必须先建立再引用。
    s += ("【事实与数字硬约束】金额/期限/数量只准取自数字台账，台账没有的数字一律不许凭空写；"
          "身份、关系、物品得失只准取自配角户籍表与跨章状态。"
          "背景细节（债务、年份、地点、师门、旧约、存放处）首次出现时必须在本章内交代来龙去脉"
          "（对话引入/回忆/旁白锚点皆可），**禁止以「既定事实」的口吻直接引用**——"
          "独立核查员按台账逐句比对，无据断言会被判编造并触发整章定点修。\n")
    if is_opening:
        s += f"【开场变故·硬约束】这是全书第 1 章第 1 场景：前 300 字内必须发生「{spec['opening']}」，事件先行，禁止慢热铺陈环境。\n"
    s += f"这是本章第 {scene_no}/{total_scenes} 个场景（{stage}）。本场景任务：{goal}。\n"
    s += f"必须完成的节拍：{' → '.join(beats)}\n"
    if genre_hint:
        s += f"{genre_hint}专属锚点：{spec['anchor']}\n"
        s += ("若本场景是爽点场景：爽点必须「落地可见」——打脸写对手当众反应"
              "（哑口无言/脸色铁青/颜面扫地），收获写具体物件入手的细节（触感/光泽/重量），"
              "揭露写在场人物的震惊与连锁反应；禁止只用内心感受充当爽点"
              "（如「他感到修为精进」）而没有外部反馈。\n")
        s += ("【新设定锚点】本章若首次引入新设定（怪物/神器/地名/体系），必须自带解释锚点"
              "（角色传闻/物件来历/回忆闪回一句即可），禁止裸奔抛出新名词让读者摸不着头脑。\n")
    if state and state.strip():
        s += f"\n【跨章状态（人物伤势/修为/物品/承诺必须与此一致，不得自相矛盾）】\n{state.strip()}\n"
    if scene_no == total_scenes:
        if hook:
            s += (f"这是本章最后一个场景：结尾必须落在「{hook}」这一类钩子上（本章指定类型）；"
                  "禁止用发热/发光/苏醒类身体异动收束。\n")
        else:
            s += "这是本章最后一个场景：结尾必须留下未落地的钩子（悬念/变故/威胁逼近/秘密将揭），让读者必须看下一章。\n"
    if style_block:
        s += f"\n{style_block}"
    if prev_text:
        s += f"\n上一段的情境（必须承接）：\n{prev_text[-150:]}\n"
    s += "\n只输出场景正文："
    return s


# ============================================================
# 通用流式 LLM 调用（OpenAI 兼容 SSE）
# ============================================================


# ============================================================
# 字数统计：薄转发（唯一定义在 fanqie_review.count_words）
# ============================================================
# 2026-09-29 收敛：此处原有一份与 Dart `AppConstants.countWords` **近乎相同但不等价**
# 的复制品（少算 CJK 扩展A、且把数字单独计词），注释还写着「复用 Dart countWords
# 逻辑」——实测同一本书两端差 0.028%（正文）/ 最多 20%（ASCII 密集的报表）。
# 现改为转发到 fanqie_review 的唯一定义，杜绝双份实现再次各自漂移。
def count_words(text):
    return _count_words(text)


# ============================================================
# 简易质检（调用 NovelQualityChecker 算法的 Python 移植版）
# ============================================================
# 注：此处原为 `NEGATION = NEGATION = list(NEGATION)`，是收编 negations 时
# 一并替换赋值两侧留下的合并残留。双重赋值里左侧第一个 NEGATION 会被
# Python 解析为**未定义的名字**——只是恰好因为右侧同名而侥幸不报 NameError。
# 它能跑不代表它对，且掩盖了「到底在给谁赋值」的意图，故收敛为单次赋值。

# ============================================================
# 单一数据源（2026-10-01）：以下词表**不再**在本文件写死，而是从
# rules/quality_rules.json 的生成物 quality_rules_generated.py 导入
# （HOOK_WORDS / OPENING_STRONG / OPENING_WEAK / THRILL_WORDS /
# POWER_SURGE_WORDS / SIDE_REACTION_WORDS），与 Dart 侧 QualityRules 同源。
# 改词表请改 JSON 再跑 scripts/rules_codegen.py——两端结构上不会再漂移。
# 仍属「双端同步」范畴（尚未收进 JSON）的有：
# release_profile<->releaseProfile（落点判定：n>=2 适用线 + 0.6/0.5 阈值）、
# ending_triad/ending_ev_fragment<->endingTriad/endingEvFragment（三件套收束窗口 60 +
# TRIAD_END_WORDS 词表，均在 rules/quality_rules.json -> quality_rules_generated 生成物，
# fanqie_review 从该生成物取值、不得反向 import 本文件，防循环依赖）、
# AI_ADVERBS<_aiAdverbs>、SENTENCE_CONNECTORS<_sentenceConnectors>、
# AI_ECHO<aiClicheWords>、NEGATION<negations>），以及 deep_ai_metrics
# 四项统计阈值。调优时必须同一次同时更新两端，防止标准漂移。
# ============================================================
# 章末钩子信号词（结尾 200 字内命中即视为有钩子，与 Dart PipelineQa 对齐）
# 经《碎脉铸仙录》33 章结尾全量实测校准：覆盖直白突变 + 隐喻式钩子
# （监视/诡谲意象/悬而未决），人工基线 91% 覆盖率。
# 词表值：rules/quality_rules.json 的 hookWords -> quality_rules_generated.HOOK_WORDS
# （本文件不再保存字面量；改词表请改 JSON 并跑 scripts/rules_codegen.py）

# 开场节奏·强信号词（双字/特定短语，1 个即视为快速进入事件）
# 双级判定避免单字词（碎/撞/压）在比喻语境（"像纸一样一碰就碎"）的误报。
# 词表值：rules/quality_rules.json 的 openingStrong -> OPENING_STRONG

# 开场节奏·弱信号词（单字动词/名词，需 >=2 个同时出现）
# 词表值：rules/quality_rules.json 的 openingWeak -> OPENING_WEAK

# 兼容旧引用（qa_scan_existing.py 等曾 import 该名）

# 爽点信号词（打脸/升级/收获/揭露 四大类，与 Dart PipelineQa 对齐）
# 选「语义明确」的词避免宽泛误报；每千字 <0.5 视为爽点过淡。
# 2026-09-07 扩展：原表为玄幻向（突破/玉简/功法），补入都市/悬疑/末世/科幻/游戏
# 题材的通用爽点词，避免题材词表失准（如《逆袭之巅》《雾锁迷城》被打低分）。
# 词表值：rules/quality_rules.json 的 thrillWords -> THRILL_WORDS
# 注：全表必须唯一（重复项会让 text.count 把同一处命中记两次，造成两端密度不一致）；
# 生成器 scripts/rules_codegen.py 已内置查重。题材加成词仍是 Python 侧独有的
# GENRE_THRILL_EXTRA（见 docs/quality-rules-current.md 第三节）。


# 题材专属爽点词表（2026-09-10 题材感知质检）：基础 THRILL_WORDS 为全题材通用，
# GENRE_THRILL_EXTRA 为各题材加成词——都市看重打脸/商战、悬疑看重反转/揭露、
# 末世/科幻看重进化/变异、游戏看重竞技/首杀。检测时用「基础词表 + 题材加成词」。


# 变强异动信号词（含蓄爽点：金手指/修为成长的身体异动表达，与 Dart 对齐）
# 实测：直白爽点词在《碎脉铸仙录》仅命中 5 处，而本类命中 58 处——
# 含蓄文风的爽点藏在「丹田温热/掌心发烫/铁粉苏醒」里，需双通道检测。
# 2026-09-07 扩展：补入异能/系统流身体异动（骨刺/断茬/星纹/数据流等）。
# 词表值：rules/quality_rules.json 的 powerSurgeWords -> POWER_SURGE_WORDS


# 侧面反响/震惊链信号词（三视角震惊环，与 Dart PipelineQa 对齐）
# 词表值：rules/quality_rules.json 的 sideReactionWords -> SIDE_REACTION_WORDS
# （同时是「爽点断供」判定的逃生通道，见 docs/quality-rules-current.md）


# ============================================================
# AI 味深度检测（统计层：句长均匀度 / 的字密度 / 叠词 / 句首连接词）
# ============================================================

# —— 句式层 AI 指纹（2026-09-12 补：词表层/统计层抓不到的三类句式模式）——
# 对齐 FANQIE_SYSTEM_PROMPT 第 21 条（「像……似的」每千字不超过 2 次）：
# 此前约束已写进 prompt 但质检抓不到违规（有约束无检测），写手超密比喻无法被发现。
# 比喻：只抓明喻强结构（像X一样/似的/般、跟X似的）+ 比喻独词（仿佛/宛如等）；
# 「他像他爹」这类判断句不带结构标记，不计入（宁漏检勿误报）。

# 身体反应四件套（发烫/发凉/嗓子发干/汗毛立起一类）：真人写作只在关键节点用，
# AI 会每个场景配一套，形成可统计的风格指纹。阈值 2.5/千字（回测校准后定）。

# 单句成段阈值：段落 ≤14 字视为单句段（喘气段），占比过高 = 机械节奏感


# 句式指纹超标线（2026-09-12 四本真实成书回测校准，见 docs/quality-enhancement-log.md 第十一节）：
# - 比喻 2.0/千字：对齐 SYSTEM_PROMPT 第 21 条的承诺线（实测正常书 1.0-2.0，
#   《铁幕孤刃》4.75 超线但人工确认为好书——该线定位是「标记风格特征供人工复核」，非否决线）
# - 单句成段 30%：正常书 11-18%，仅《断脉逆命诀》31% 超标（第 5 章 44.7%，恰为终审官点名的追读断裂章）
# - 身体反应 1.5/千字：正常书 0.5-1.2，仅断脉第 1 章（风格指纹最重章）1.53 超线（回测后从 2.5 收紧）


def quality_check(chapters):
    """极简质检：AI 囷痕密度 + 世界观关键词冲突 + 章末钩子/开场节奏（商业向）。"""
    report = []
    world_claims = {}
    for ch in chapters:
        text = ch.get("content", "")
        words = count_words(text)
        hits = sum(text.count(c) for c in AI_CLICHE)
        echo = (hits / words * 100) if words > 0 else 0.0
        ch["_words"] = words
        ch["_ai_echo_pct"] = round(echo, 2)
        # 商业向：章末钩子 / 黄金三章开场 / 爽点密度（只记录不阻塞）
        ch["_has_hook"] = has_ending_hook(text)
        ch["_has_quick_opening"] = has_quick_opening(text)
        ch["_thrill_per_k"] = thrill_per_thousand(text)
        ch["_surge_per_k"] = surge_per_thousand(text)
        # 压抑释放结构（爽点落点）：先抑后扬是否成立，note 级不阻塞
        ch["_release"] = release_profile(text)["verdict"]
        # 章末三件套收尾（规则20）：命中词供逐章打印与报告展示
        ch["_ending_triad"] = ending_triad(text)
        ch["_ai_deep_level"] = deep_ai_metrics(text)["level"]
        # 世界观关键词（灵气/斗气/筑基 等）
        for kw in ["灵气", "斗气", "筑基", "金丹", "元婴", "灵石", "灵根"]:
            if kw in text:
                idx = text.find(kw)
                prefix = text[max(0, idx - 6):idx]
                neg = any(n in prefix for n in NEGATION)
                if kw not in world_claims:
                    world_claims[kw] = (ch["idx"], neg)
                else:
                    prev_idx, prev_neg = world_claims[kw]
                    if neg != prev_neg:
                        ch.setdefault("_world_conflicts", []).append(
                            f"第 {prev_idx} 章「{kw}」({'肯定' if not prev_neg else '否定'}) 与第 {ch['idx']} 章（{'肯定' if not neg else '否定'}）相反"
                        )
        report.append({
            "idx": ch["idx"], "words": words, "ai_echo": round(echo, 2),
            "has_hook": ch["_has_hook"],
            "thrill_per_k": ch["_thrill_per_k"],
            "surge_per_k": ch["_surge_per_k"],
            "release": ch["_release"],
            "ending_triad": ch["_ending_triad"],
        })
    return report


def _quality_repair_prompt(text, review, registry, genre, protagonist, prev_text,
                           world_terms=()):
    """组装质量修复指令；只针对检测到的问题，不重写无关段落。

    world_terms 传大纲专名时，世界观缺失会被点名（见 fanqie_review.fix_prompt）。"""
    lock = registry_block(registry)
    facts = facts_block(registry)
    return fix_prompt(review, text, world_terms) + (
        f"\n【本题材】{genre}\n【主角】{protagonist}\n"
        f"【前文尾部】{prev_text[-200:] if prev_text else '无'}\n"
        f"【角色户籍】{lock}\n【数字台账】{facts}\n"
        "【修复硬约束】保留主线、人物身份、数字、章末钩子；"
        "优先把叙述信息改成有压力的对白或动作；每句尽量不超过 25 字；"
        "删除不推进剧情的段落；不得用环境、回忆或同义反复凑字数。"
    )


def _quality_chunks(text, max_chars=1800):
    """按自然段切分质量修复上下文，避免单次请求携带整本长文。"""
    if max_chars <= 0:
        raise ValueError("max_chars must be positive")
    paragraphs = [p for p in re.split(r'\n\s*\n', text or '') if p.strip()]
    chunks = []
    current = []
    size = 0
    for paragraph in paragraphs:
        paragraph = paragraph.strip()
        if len(paragraph) > max_chars:
            if current:
                chunks.append('\n\n'.join(current))
                current, size = [], 0
            for start in range(0, len(paragraph), max_chars):
                chunks.append(paragraph[start:start + max_chars])
            continue
        if current and size + len(paragraph) + 2 > max_chars:
            chunks.append('\n\n'.join(current))
            current, size = [], 0
        current.append(paragraph)
        size += len(paragraph) + 2
    if current:
        chunks.append('\n\n'.join(current))
    return chunks or ['']


def _quality_repair_in_chunks(text, review, registry, genre, protagonist,
                               prev_text, call, max_chars=1800, world_terms=()):
    """分块调用质量修复；任一块失败即放弃整章，避免拼出半修复稿。"""
    chunks = _quality_chunks(text, max_chars=max_chars)
    repaired = []
    context = prev_text or ''
    for chunk in chunks:
        prompt = _quality_repair_prompt(
            chunk, review, registry, genre, protagonist, context[-200:], world_terms)
        part = call(prompt, max(600, int(count_words(chunk) * 2.2)))
        if not part or not part.strip():
            return ''
        part = part.strip()
        repaired.append(part)
        context = part
    return '\n\n'.join(repaired)


def _quality_repair_candidate(before, after, before_review, after_review, target_words):
    """只接受不劣化且字数稳定的质量修复稿。"""
    before_words = count_words(before)
    after_words = count_words(after)
    # 允许适度扩写：补对白、拆长句、删水段可能让正文增加 30%~50%；
    # 超过 60%~150% 才视为模型失控，原稿必须保留。
    if after_words < before_words * 0.6 or after_words > before_words * 1.5:
        return False, '字数偏离原章超过允许范围'
    if after_words < max(500, int(target_words * 0.5)):
        return False, '修复后字数不足'
    if after_review.get('score', 0) < before_review.get('score', 0):
        return False, '质量分下降'
    if len(after_review.get('blockers') or []) > len(before_review.get('blockers') or []):
        return False, '阻断项增加'
    before_dialogue = dialogue_ratio(before)
    after_dialogue = dialogue_ratio(after)
    if before_dialogue < 0.25:
        if after_dialogue < 0.25:
            return False, '对白占比没有改善'
    elif after_dialogue < before_dialogue - 0.05:
        return False, '对白占比明显下降'
    if filler_ratio(after)[0] > filler_ratio(before)[0] + 2:
        return False, '水段率恶化'
    if self_repeat_ratio(after) > self_repeat_ratio(before) + 1:
        return False, '整句重复恶化'
    return True, '质量分/对白/水段/重复均未劣化'


# ============================================================
# 状态持久化
# ============================================================
def load_state(path, min_words=800):
    """加载进度；只接受结构有效且正文足够长的章节，按 idx 去重。

    JSONL 是追加式断点文件，可能因进程中断留下半行；恢复时不能因坏行
    静默丢失，也不能把重复章节重复计入总字数。outline/registry 采用
    last-wins，章节采用唯一 idx。
    """
    if not os.path.exists(path):
        return {"outline": None, "chapters": [], "registry": None}
    out = {"outline": None, "chapters": [], "registry": None}
    seen_idx = set()
    with open(path, encoding="utf-8", errors="replace") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as exc:
                print(f"  [WARN] 进度第 {line_no} 行 JSON 损坏，已跳过：{exc.msg}")
                continue
            if not isinstance(rec, dict) or not rec.get("type") or "data" not in rec:
                print(f"  [WARN] 进度第 {line_no} 行结构无效，已跳过")
                continue
            kind = rec.get("type")
            data = rec.get("data")
            if kind in ("outline", "registry"):
                if isinstance(data, dict):
                    out[kind] = data
                else:
                    print(f"  [WARN] 进度第 {line_no} 行 {kind} data 不是对象，已跳过")
            elif kind == "chapter":
                if not isinstance(data, dict):
                    print(f"  [WARN] 进度第 {line_no} 行 chapter data 不是对象，已跳过")
                    continue
                idx = data.get("idx")
                content = data.get("content")
                if not isinstance(idx, int) or isinstance(idx, bool) or idx <= 0:
                    print(f"  [WARN] 进度第 {line_no} 行章节 idx 无效，已跳过")
                    continue
                if idx in seen_idx:
                    print(f"  [WARN] 进度第 {line_no} 行重复第 {idx} 章，已跳过")
                    continue
                if not isinstance(content, str) or not content.strip():
                    print(f"  [WARN] 进度第 {line_no} 行第 {idx} 章正文为空，已跳过")
                    continue
                actual_words = count_words(content)
                if actual_words < min_words:
                    print(f"  [SKIP] 第 {idx} 章仅 {actual_words} 字，标记为待重做")
                    continue
                chapter = dict(data)
                chapter["words"] = actual_words
                out["chapters"].append(chapter)
                seen_idx.add(idx)
    # 按 idx 升序重排（2026-09-30 修复章序错乱）。
    #
    # 实测事故：真机 12.6 万字长篇的 jsonl 物理顺序是
    #   1..9, **12,13,14,15,16,17, 10,11**, 18,19, **22,24,25,27,28,30,31,32,33, 20,21,23,26,29**
    # 导出成书后章节物理顺序错乱，读者/审稿无法按序阅读，须人工重排。
    #
    # 根因是**断点续跑**：本函数按 jsonl 行的物理顺序 append，而 jsonl 是
    # 「完成一章追加一行」。中断后重跑时，缺章（如 10、11）是在已有 12~17 之后
    # 才补写的，于是物理顺序 ≠ 章序。续跑是本流水线的正常路径（配额受限时长跑
    # 的唯一续命方式），所以这不是边界情况而是常态。
    #
    # 在 load 处排序而非 export 处：state["chapters"] 的所有下游消费者
    # （export_txt / 总编终审 / 结构修复 / md_projection）都依赖它拿到有序列表，
    # 只修导出层会留下别的乱序隐患。
    out["chapters"].sort(key=lambda c: c.get("idx", 0))
    return out


def append_state(path, kind, data):
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps({"type": kind, "data": data}, ensure_ascii=False) + "\n")


def _sidecar_path(path, suffix):
    """生成派生文件路径；无 .jsonl 后缀时追加后缀，绝不覆盖进度文件。"""
    root, ext = os.path.splitext(path)
    return (root if ext.lower() == ".jsonl" else path) + suffix


def export_txt(path, title, chapters):
    txt_path = _sidecar_path(path, ".txt")
    # 按 idx 升序写（2026-09-30 修复章序错乱）：defense in depth。
    # load_state 已排过序，这里再排一次是防调用方直接传乱序列表
    # （写手断点续跑 / 结构补章都是就地 append 的路径）。
    ordered = sorted(chapters, key=lambda c: c.get("idx", 0))
    with open(txt_path, "w", encoding="utf-8") as f:
        f.write(f"《{title}》\n\n")
        for ch in ordered:
            f.write(f"\n\n第 {ch['idx']} 章  {ch.get('title', '')}\n")
            f.write("—" * 20 + "\n\n")
            f.write(ch.get("content", ""))
            f.write("\n")
    return txt_path


# ============================================================
# 主线
# ============================================================
def main():
    p = argparse.ArgumentParser(description="墨匠长篇小说生成器")
    p.add_argument("--provider", default="openai")
    p.add_argument("--genre", default="玄幻", help="题材（玄幻/都市/悬疑等，映射写作准则与爽点豁免）")
    p.add_argument("--base-url", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--api-key", default="")
    p.add_argument("--total-words", type=int, default=8000, help="目标总字数")
    p.add_argument("--max-chapters", type=int, default=20, help="最多生成几章")
    p.add_argument("--output", default="novel_output.jsonl", help="进度文件路径")
    p.add_argument("--temperature", type=float, default=0.8)
    p.add_argument("--chapter-wait", type=float, default=2.0, help="每章之间的等待时间（秒），避免触发限流")
    p.add_argument("--skip-quality-repair", action="store_true",
                   help="跳过章节质量自动修复轮（调试/节省额度时使用）")
    p.add_argument("--style-ref", default="",
                   help="文风参考 txt 路径：提取文风指纹注入写手场景 prompt，"
                        "逐章打印与参考文的指纹距离（与 novel_pipeline 同口径）")
    p.add_argument("--dry-run", action="store_true", help="只打印大纲不生成正文")
    args = p.parse_args()
    if args.total_words <= 0 or args.max_chapters <= 0:
        p.error("--total-words 与 --max-chapters 必须为正数")
    if not args.output.strip():
        p.error("--output 不能为空")
    args.output = os.path.abspath(args.output)
    if os.path.isdir(args.output):
        p.error(f"--output 必须是文件路径：{args.output}")
    os.makedirs(os.path.dirname(args.output), exist_ok=True)

    api_key = args.api_key or os.environ.get("NOVEL_LLM_API_KEY", "")
    base_url_raw = args.base_url

    print(f"[INFO] model={args.model}  target={args.total_words}字  file={args.output}")
    STYLE_BLOCK, REF_FP = load_style_block(args.style_ref)
    if args.dry_run:
        print("[DRY RUN] 将只打印大纲\n")

    # 加载已有进度
    state = load_state(args.output)
    outline = state["outline"]

    # ====== 第一步：规划大纲 ======
    if not outline:
        print("=" * 60)
        print("[Phase 1] 规划全书大纲...")
        print("=" * 60)
        plan_text = call_llm(base_url_raw, args.model,
                             f"你是网文小说作者，擅长构思长篇{args.genre}故事。",
                             planning_prompt_idea(args.total_words, genre=args.genre), api_key, 8000, 0.8)
        outline = parse_json_from_llm(plan_text)
        if not outline or not outline.get("chapter_outlines"):
            print(f"[ERROR] LLM 规划失败，原始输出（前 500 字）：\n{plan_text[:500]}")
            sys.exit(1)
        title = outline.get("title", "未命名")
        chars = outline.get("chapter_outlines", [])
        print(f"[OK] 《{title}》｜共 {len(chars)} 章")
        print(f"     主角：{outline.get('protagonist', {}).get('name', '?')}")
        print(f"     体系：{outline.get('world', {}).get('power_system', '?')}")
        for c in chars[:5]:
            print(f"     第 {c['idx']} 章 {c['title']}（目标 {c.get('target', 2000)} 字）")
        if len(chars) > 5:
            print(f"     ... 及更多 {len(chars) - 5} 章")
        append_state(args.output, "outline", outline)
        print("[OK] 大纲已写入进度文件\n")
        if args.dry_run:
            print("[DRY RUN] 结束")
            return
    else:
        title = outline.get("title", "未命名")
        chars = outline.get("chapter_outlines", [])
        print(f"[RESUME] 《{title}》｜已有 {len(state['chapters'])} 章，继续生成")

    # ====== 第二步：逐章多pass生成 ======
    total_words = 0
    for ch_data in state["chapters"]:
        total_words += count_words(ch_data.get("content", ""))

    existing_idx = {c["idx"] for c in state["chapters"]}
    _p = outline.get("protagonist")
    protagonist = _p.get("name", "") if isinstance(_p, dict) else ""
    _w = outline.get("world") or {}
    world_str = _w if isinstance(_w, str) else json.dumps(_w, ensure_ascii=False)
    # 世界观专名清单：评审按字面命中判定「世界观是否落地」，写手/修复提示词都要逐条点名
    world_terms = extract_world_terms(outline)
    # 配角户籍表 + 数字台账：随进度文件持久化，跨章/跨次运行强一致；主角自动登记
    registry = state.get("registry") or {"characters": [], "facts": []}
    registry.setdefault("characters", [])
    registry.setdefault("facts", [])
    if protagonist and not any(c["name"] == protagonist for c in registry["characters"]):
        _pdesc = _p.get("desc", "") if isinstance(_p, dict) else ""
        registry["characters"].insert(0, {"name": protagonist,
                                          "identity": _pdesc or "主角",
                                          "first_seen": 1, "note": "主角（规划官设定）"})

    for ch in chars:
        idx = ch["idx"]
        if idx in existing_idx:
            continue
        if total_words >= args.total_words:
            print(f"\n[DONE] 已达成目标字数 {total_words} >= {args.total_words}")
            break
        if idx > args.max_chapters:
            break

        chapter_title = ch.get("title", f"第{idx}章")
        goal = ch.get("goal", "")
        target = ch.get("target", 2000)
        # 承接前一章（按章号取，而非生成顺序——补写中间章时绝不能拿最后一章的尾巴，
        # 历史事故：重写的第 2 章开场接了第 3 章结尾的飞刀，时间线穿越）
        prev_done = sorted((c for c in state["chapters"] if c["idx"] < idx),
                           key=lambda c: c["idx"])
        if prev_done:
            _pc = prev_done[-1].get("content", "")
            last_summary = _pc[-200:] if len(_pc) > 200 else _pc
        else:
            last_summary = ""
        print(f"\n{'=' * 60}")
        print(f"[CH {idx}] {chapter_title}（目标 {target} 字）")
        print(f"  章纲：{goal}")
        print("=" * 60)

        # 场景规划
        plan = None
        for attempt in range(2):
            scene_plan_raw = call_llm(base_url_raw, args.model,
                                     "你擅长长篇小说结构，能把章纲拆成有序场景组合。",
                                     scene_planning_prompt(goal, last_summary, genre=args.genre,
                                                           protagonist=protagonist,
                                                           world_hint=world_str,
                                                           registry=registry_block(registry),
                                                           facts=facts_block(registry)),
                                     api_key, 1200, 0.7)
            plan = parse_json_from_llm(scene_plan_raw)
            if plan and plan.get("scenes"):
                break
        if not plan or not plan.get("scenes"):
            print("  [SKIP] 场景规划失败，跳过本章")
            continue

        scenes = plan["scenes"]
        print(f"  [规划] {len(scenes)} 个场景：{'/'.join(s['stage'] for s in scenes)}")

        # 逐场景生成
        scene_texts = []
        prev_text = last_summary
        for si, sc in enumerate(scenes):
            goal_s = sc.get("goal", "")
            beats = sc.get("beats", [])
            tw = sc.get("targetWords", 600)
            stage = sc.get("stage", "承")
            print(f"  [场景 {si + 1}/{len(scenes)}] {stage}：{goal_s}（目标 {tw} 字）")
            text = call_llm(base_url_raw, args.model, SYSTEM_PROMPT,
                            scene_prompt(si + 1, len(scenes), stage, goal_s,
                                         beats, prev_text, args.genre, protagonist=protagonist, world=world_str,
                                         hook=hook_for(idx) if si + 1 == len(scenes) else "",
                                         registry=registry_block(registry),
                                         facts=facts_block(registry),
                                         world_terms=world_terms,
                                         style_block=STYLE_BLOCK),
                            api_key, int(tw * 1.8), args.temperature)
            text = text.strip()
            w = count_words(text)
            print(f"    -> {w} 字")
            if text:
                scene_texts.append(text)
                prev_text = text
            if w < tw * 0.4 and len(text) > 50:
                print("    [WARN] 字数偏少，尝试补充...")
                add = call_llm(base_url_raw, args.model, SYSTEM_PROMPT,
                               f"请续写 300 字，承接：\n{text[-100:]}\n\n只输出续写正文：",
                               api_key, 600, 0.8)
                if add.strip():
                    scene_texts.append("\n\n" + add.strip())

        # 拼接 & 质检 & 记录
        full_text = "\n\n".join(scene_texts)
        w = count_words(full_text)
        if w < target * 0.5:
            print(f"  [WARN] 第 {idx} 章仅 {w} 字（目标 {target}），尝试整体续写...")
            add = call_llm(base_url_raw, args.model, SYSTEM_PROMPT,
                           f"请将下面章节内容扩充到 {target} 字以上，保留原意，只输出正文：\n{full_text[:500]}...\n（续写剩余部分）",
                           api_key, int(target * 1.5), 0.8)
            if add.strip():
                full_text += "\n\n" + add.strip()
                w = count_words(full_text)
                print(f"    续写后 {w} 字")
        # 情绪闸门：零爽点章触发一轮情绪强化定点修（验收通过才采纳，绝不劣化原文）
        # 断供口径：旧条件是「双低」（💥<0.5 且 ✨<1.0），而 ✨ 含蓄异动恒高
        # （~2.2/千字）使双低几乎永不成立——实测 116 章只触发 7 章。补跨章通道：
        # 已连着 >=3 章无外显爽点时，本章只要 💥 仍低就补（不再要求 ✨ 也低）。
        import novel_pipeline as _np  # 延迟导入避免循环依赖
        _thrill = thrill_per_thousand(full_text)
        _surge = surge_per_thousand(full_text)
        _drought_n = _np.trailing_drought_len(
            [thrill_per_thousand(c["content"], args.genre)
             for c in state.get("chapters", [])],
            [side_reaction_per_thousand(c["content"])
             for c in state.get("chapters", [])])
        if _np.needs_payoff_repair(
                _thrill, _surge,
                min_words_ok=w >= target * 0.5,
                drought_len=_drought_n,
                side=side_reaction_per_thousand(full_text)):
            _why = (f"跨章断供 {_drought_n} 章" if _drought_n >= 3 else "单章双低")
            print(f"  [情绪] 本章无外显爽点（{_why}），触发一轮情绪强化定点修...")
            fix = call_llm(base_url_raw, args.model, SYSTEM_PROMPT,
                           _np.payoff_repair_prompt(
                               full_text,
                               registry=registry_block(registry),
                               facts=facts_block(registry),
                               drought_len=_drought_n),
                           api_key, int(w * 2.2), args.temperature).strip()
            if fix:
                _ok, _why2 = _np.accept_payoff_repair(
                    full_text, fix, registry=registry_block(registry))
                if _ok:
                    print(f"    [情绪] 采纳强化稿：{_why2}")
                    full_text, w = fix, count_words(fix)
                else:
                    print(f"    [情绪] 强化稿未过验收（{_why2}），保原文")
        # 质量修复轮：先评审，再把问题交给编辑模型；修复稿不劣化才采纳。
        if not args.skip_quality_repair and w >= max(500, int(target * 0.5)):
            # world_terms 一并传入：此前这条路径不查世界观落地，与 novel_pipeline 口径不一致
            before_review = review_chapter(
                full_text, last_summary, idx, args.genre, protagonist,
                world_terms=world_terms, has_hook=has_ending_hook(full_text))
            needs_repair = (
                before_review.get('score', 0) < 78 or
                dialogue_ratio(full_text) < 0.25 or
                filler_ratio(full_text)[0] > 10 or
                self_repeat_ratio(full_text) > 2 or
                not has_ending_hook(full_text))
            if needs_repair:
                print('  [质量] 本章低于可投稿门槛，触发一轮定点修复...')
                candidate = _quality_repair_in_chunks(
                    full_text, before_review, registry, args.genre,
                    protagonist, last_summary,
                    lambda prompt, max_tokens: call_llm(
                        base_url_raw, args.model, SYSTEM_PROMPT, prompt,
                        api_key, max_tokens, args.temperature,
                        retries=1, timeout=90),
                    world_terms=world_terms)
                if candidate:
                    after_review = review_chapter(
                        candidate, last_summary, idx, args.genre, protagonist,
                        world_terms=world_terms, has_hook=has_ending_hook(candidate))
                    accepted, reason = _quality_repair_candidate(
                        full_text, candidate, before_review, after_review,
                        target)
                    if accepted:
                        print('  [质量] 采纳修复稿：'
                              f"{before_review.get('score', 0):.0f}→"
                              f"{after_review.get('score', 0):.0f} 分｜"
                              f"对白 {dialogue_ratio(full_text):.1%}→"
                              f"{dialogue_ratio(candidate):.1%}")
                        full_text, w = candidate, count_words(candidate)
                    else:
                        print(f'  [质量] 修复稿拒绝：{reason}，保留原稿')
                else:
                    print('  [质量] 修复模型无有效输出，保留原稿')

        chapter_content = {
            "idx": idx,
            "title": chapter_title,
            "content": full_text,
            "words": w,
            "scenes": len(scenes),
        }
        state["chapters"].append(chapter_content)
        append_state(args.output, "chapter", chapter_content)
        total_words += w
        # 户籍登记：LLM 提取本章新登场/身份变动角色（首见锁定，穿帮记警示）+ 数字台账合并
        merge_facts(registry, full_text, idx)
        _ext_raw = call_llm(base_url_raw, args.model,
                            "你是小说设定整理员，只输出 JSON。",
                            extract_registry_prompt(full_text, idx, registry),
                            api_key, 1200, 0.3)
        _ext = parse_json_from_llm(_ext_raw)
        if _ext:
            for _cf in merge_registry(registry, _ext, idx):
                print(f"  [户籍] ⚠ 穿帮警示：{_cf}")
        append_state(args.output, "registry", registry)
        if REF_FP is not None:
            print(f"  [文风] 本章与参考文指纹距离 "
                  f"{fingerprint_distance(REF_FP, style_fingerprint(full_text))}"
                  "（0=同分布，逐章对比看是否收敛）")
        print(f"  [完成] 第 {idx} 章：{w} 字 | 累计 {total_words} 字")
        if args.chapter_wait > 0 and idx < args.max_chapters and total_words < args.total_words:
            time.sleep(args.chapter_wait)

    # ====== 第三步：质检汇总 ======
    # 断点续传/补章可能乱序或重复：按章号去重（保留最新记录）并排序，质检与导出同口径
    _dedup = {}
    for _c in state["chapters"]:
        _dedup[_c["idx"]] = _c
    state["chapters"] = [_dedup[k] for k in sorted(_dedup)]
    print(f"\n{'=' * 60}")
    print("[质检] 运行一致性检查...")
    quality_check(state["chapters"])  # 副作用：填充各章 _world_conflicts 等质检字段
    print(f"{'=' * 60}")
    total_issues = 0
    for ch in state["chapters"]:
        issues = ch.get("_world_conflicts", [])
        issues_count = len(issues)
        total_issues += issues_count
        flag = "⚠" if issues_count else "✓"
        hook_flag = "🪝" if ch.get("_has_hook") else "✗无钩"
        open_flag = "⚡" if ch.get("_has_quick_opening", True) else "✗开场慢"
        thrill_flag = "💥" if ch.get("_thrill_per_k", 1) >= 0.5 else "✗爽点淡"
        deep_flag = "🤖" if ch.get("_ai_deep_level", 0) >= 3 else ""
        print(f"  {flag} 第 {ch['idx']} 章：{ch['_words']} 字｜AI囷痕 {ch['_ai_echo_pct']}%｜{hook_flag}｜{open_flag}｜{thrill_flag}({ch.get('_thrill_per_k', 0)}/千字)｜✨{ch.get('_surge_per_k', 0)}/千字｜{deep_flag}")
        if not ch.get("_has_hook"):
            print("      → 章末疑似缺少钩子（结尾 200 字未见悬念信号）")
        if ch.get("idx", 99) <= 3 and not ch.get("_has_quick_opening"):
            print("      → 开场 300 字未检测到变故/冲突信号（黄金三章要求快速进入事件）")
        if ch.get("_ai_deep_level", 0) >= 3:
            print("      → AI 腔偏重（句长均匀/的字过多/叠词修饰/句首连接词 超标）")
        if ch.get("idx", 99) > 0 and ch.get("_thrill_per_k", 1) < 0.5 and ch.get("_surge_per_k", 1) < 1.0:
            print("      → 爽点过淡（直白爽点 <0.5 且变强异动 <1.0/千字，建议安排打脸/升级/收获/揭露至少一处）")
        elif ch.get("idx", 99) > 0 and ch.get("_thrill_per_k", 1) < 0.5:
            print("      → 含蓄变强流（外显爽点偏少，建议补充打脸/收获等外显爽点增强追读）")
        if ch.get("_release") == "late_start":
            print("      → 压抑过长（首个爽点晚于全章 60% 才释放，先抑后扬失衡，读者中段易流失）")
        elif ch.get("_release") == "front_loaded":
            print("      → 爽点前置泄洪（所有爽点在前半段，后半段零释放，后半章平铺掉追读）")
        if ch.get("_ending_triad"):
            print(f"      → 章末三件套收尾：命中「{ch['_ending_triad']}」"
                  "（规则20禁止身体异动/发光物件收束，换成未落地悬念）")
    print(f"\n  世界观冲突：{total_issues} 处")
    _chars = registry.get("characters", [])
    _facts = registry.get("facts", [])
    if _chars:
        print(f"  户籍表：{len(_chars)} 名角色已登记（首见锁定）")
        for _c in _chars:
            _note = f"｜{_c['note']}" if _c.get("note") else ""
            print(f"    - {_c['name']}｜{_c.get('identity', '')}｜第 {_c.get('first_seen', '?')} 章{_note}")
    if _facts:
        print(f"  数字台账：{'、'.join(f['value'] for f in _facts)}")

    # ====== 第四步：导出 ======
    txt_path = export_txt(args.output, title, state["chapters"])
    jsonl_path = args.output
    print(f"\n[OK] 文本输出：{txt_path}")
    print(f"[OK] 进度文件：{jsonl_path}")
    print(f"[OK] 总字数：{sum(c.get('words', 0) for c in state['chapters'])}")


if __name__ == "__main__":
    main()
