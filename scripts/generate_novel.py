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
import random
import re
import sys
import time
import urllib.error
import urllib.request

# 强制 print 实时刷新
_real_print = print
def print(*args, **kwargs):
    kwargs.setdefault("flush", True)
    _real_print(*args, **kwargs)

# ============================================================
# Prompts（与 Dart WritingGuidelines + 多 pass 引擎对齐）
# ============================================================
# 写作准则已迁到 fanqie_prompts.py：每一条都能被 fanqie_review.py 量化检查，
# 避免旧版「准则教套路、质检数词表」的自相矛盾。
from fanqie_prompts import FANQIE_SYSTEM_PROMPT as SYSTEM_PROMPT  # noqa: E402


from fanqie_prompts import GOLDEN3_SPEC as _GOLDEN3, GOAL_FORMAT as _GOAL_FORMAT

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


def scene_planning_prompt(outline, prev_summary, state="", protagonist="", genre="玄幻", world_hint=""):
    """为每一章拆场景。state 为跨章状态清单（人物伤势/修为/物品/承诺）。
    protagonist 非空时强制场景只使用该主角名，禁止另起别名/新角色名。
    genre 为题材（见 GENRE_SPECS）。world_hint 为全书大纲世界观（JSON 片段），
    防止正文写手脱离规划官设定的世界体系自由发挥（历史事故：大纲裴照系统流、
    正文写成赵铁柱超自然流）。"""
    spec = GENRE_SPECS.get(genre, GENRE_SPECS["玄幻"])
    s = f"""下面是一章的纲。请把它拆成 3~5 个「各有结构目标的」场景（起承转合）。题材：{spec['label']}。

【规划要求】
- 本章至少安排 1 个「外显爽点」场景（优先级：打脸 > 收获 > 秘密揭露 > 升级）：
  · 打脸：冲突对方当众吃瘪（哑口无言/脸色铁青/颜面扫地）；
  · 收获：具体宝物/机缘/情报到手，有可感知的细节（触感/光泽/重量）；
  · 秘密揭露：关键身份或真相反转，在场人物震惊；
  · 若选升级：必须写出外部可见反应（威压外放/众人震惊/对手变色/境界显化），
    不能只停留在内心与身体感受；
- 爽点场景放在章内后半段（先抑后扬，压抑后释放）；
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


def scene_prompt(scene_no, total_scenes, stage, goal, beats, prev_text, genre_hint="玄幻",
                 state="", protagonist="", world="", hook="", is_opening=False):
    """单场景生成。state 为跨章状态清单（人物伤势/修为/物品/承诺）。
    genre_hint 为题材（见 GENRE_SPECS）；protagonist/world 为本书已确立的主角名与世界观，
    必须显式注入——缺这两项时写手会自己另起一个故事。
    is_opening 为全书第 1 章第 1 场景标记，强制开场变故硬约束。"""
    spec = GENRE_SPECS.get(genre_hint, GENRE_SPECS["玄幻"])
    s = ""
    if genre_hint:
        s += f"本书题材：{genre_hint}（{spec['label']}）。\n"
    if world:
        s += f"本书世界观（必须沿用，不得改写或另起设定）：{world}\n"
    if protagonist:
        s += f"本章主角：{protagonist}。全章只用这个名字，禁止改名、别名或新增有名字的角色。\n"
        s += (f"【主角名片】场景中首次出现主角时必须自然带出名字（对话称呼/名牌/他人介绍/身份描写均可），"
              f"让读者在前 300 字内记住「{protagonist}」这个名字及其处境；禁止长时间用「他/她」指代。\n")
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
    if prev_text:
        s += f"\n上一段的情境（必须承接）：\n{prev_text[-150:]}\n"
    s += "\n只输出场景正文："
    return s


# ============================================================
# 通用流式 LLM 调用（OpenAI 兼容 SSE）
# ============================================================
def is_reasoning_model(model):
    """判断模型是否需要额外的 options.Thinking 参数。"""
    m = model.lower().replace("-", "").replace("_", "")
    return "sensenova" in m or "deepseek" in m


def call_llm(base_url, model, system, user, api_key, max_tokens, temperature=0.8, retries=3, extra_wait=0):
    """流式调用 OpenAI 兼容 LLM。retries 含 4 次指数退避，额外支持 reasoning 模型 throatle。"""
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": True,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    if is_reasoning_model(model):
        payload["options"] = {"Thinking": False}
    body = json.dumps(payload).encode("utf-8")
    url = base_url.rstrip("/")
    rate_limit_backoff = 0  # 遇 429 退避基数
    for attempt in range(retries + 1):
        try:
            if extra_wait > 0:
                time.sleep(extra_wait)
            req = urllib.request.Request(url, data=body, method="POST")
            req.add_header("Content-Type", "application/json")
            req.add_header("Accept", "text/event-stream")
            if api_key:
                req.add_header("Authorization", f"Bearer {api_key}")
            with urllib.request.urlopen(req, timeout=300) as resp:
                chunks = []
                for raw_line in resp:
                    line = raw_line.decode("utf-8").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                        choices = chunk.get("choices")
                        if not choices:
                            continue
                        delta = choices[0].get("delta", {})
                        if delta.get("content"):
                            chunks.append(delta["content"])
                    except Exception:
                        continue
                return "".join(chunks)
        except urllib.error.HTTPError as e:
            body_text = ""
            try:
                body_text = e.read().decode("utf-8", errors="replace")[:300]
            except Exception:
                pass
            if e.code in (429, 500, 502, 503):
                retry_after = None
                try:
                    retry_after = int(e.headers.get("Retry-After", ""))
                except Exception:
                    pass
                # 计算退避：取 Retry-After 与指数退避的较大值，至少等 5s
                backoff = (3 ** (attempt + 1)) * 5 + random.randint(5, 30) + rate_limit_backoff
                if retry_after and retry_after <= 300:
                    wait = max(retry_after, min(backoff, 15))  # 即使 Retry-After 也给个保底
                else:
                    wait = min(300, backoff)
                rate_limit_backoff += 15  # 每次遇 429 多等 15s
                print(f"    [retry {attempt + 1}/{retries + 1}] HTTP {e.code}: {body_text[:150]} (等待 {wait}s, 累计退避 {rate_limit_backoff}s)")
                if attempt < retries:
                    time.sleep(wait)
                    continue
                return ""
            print(f"    [HTTP {e.code}] {body_text}")
            return ""
        except Exception as e:
            wait = min(120, (3 ** attempt) * 5 + random.randint(1, 10))
            print(f"    [retry {attempt + 1}/{retries}] {e} (等待 {wait}s)")
            if attempt < retries:
                time.sleep(wait)
                continue
    print("    [FAILED] ")
    return ""


def repair_json(text):
    """尝试修复截断的 JSON：补全缺失的闭合括号与最后一项。"""
    t = text.strip()
    # 统计开闭括号
    opens = t.count("{")
    closes = t.count("}")
    if opens <= closes:
        return t
    # 在末尾补全缺失的闭合：先闭合可能的字符串/对象，再补 chapter_outlines 数组
    # 去掉末尾不完整的 token（引号后的半截内容）
    t = re.sub(r',\s*"[^"]*$', '', t)  # 最后一项 title/goal 截断
    t = re.sub(r'"[^"]*$', '""', t)     # 某个字符串值未闭合
    # 重新统计
    opens = t.count("{")
    closes = t.count("}")
    # 补 closing
    needed = opens - closes
    # 先闭合最后一个 chapter_outline 对象 → "}]}"
    if t.rstrip().endswith(","):
        t = t.rstrip()[:-1]
    if not t.rstrip().endswith("}"):
        t = t.rstrip() + "\n  }"
    # 再闭合 chapter_outlines 数组和根对象
    t += "\n]\n}" * (1 if needed >= 1 else 0)
    return t


def _sanitize_ctrl(text):
    """把 JSON 字符串值内的裸控制字符（未转义的换行/制表/不可见字符）转义为 \\n \\t \\uXXXX。
    避免 LLM 在字符串里直接换行导致 json.loads 抛 Invalid control character。"""
    out = []
    in_str = False
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"' and (i == 0 or text[i - 1] != '\\'):
            in_str = not in_str
            out.append(c)
        elif in_str:
            o = ord(c)
            if c == '\n':
                out.append('\\n')
            elif c == '\r':
                out.append('\\r')
            elif c == '\t':
                out.append('\\t')
            elif o < 0x20:
                out.append('\\u%04x' % o)
            else:
                out.append(c)
        else:
            out.append(c)
        i += 1
    return ''.join(out)


def parse_json_from_llm(text, repair=True):
    """从 LLM 输出中找出第一个 JSON 对象，支持修复截断 JSON 与字符串内裸控制字符。"""
    if not text:
        return None
    t = text.strip()
    # 去 ```json 包
    t = re.sub(r"```(?:json)?", "", t)
    s = t.find("{")
    d = t.rfind("}")
    if s < 0 or d <= s:
        return None
    # 先清理字符串值内的裸控制字符（LLM 常见违规），再尝试解析
    t_clean = _sanitize_ctrl(t[s:d + 1])
    try:
        result = json.loads(t_clean)
        return result
    except Exception as e:
        if not repair:
            print(f"    [JSON parse error] {e}")
            return None
        # 尝试修复（repair 可能引入新的裸控制字符，再做一次 sanitize）
        try:
            repaired = repair_json(t_clean)
            repaired = _sanitize_ctrl(repaired)
            result = json.loads(repaired)
            print("    [JSON repaired]")
            return result
        except Exception as e2:
            print(f"    [JSON parse error] {e} (repair failed: {e2})")
            visible_nl = '\\n'  # 换行显示为可见标记（f-string 表达式内不能含反斜杠）
            print(f"    [JSON 原文前300]: {t_clean[:300].replace(chr(10), visible_nl)}")
            return None


# ============================================================
# 字数统计（复用 Dart countWords 逻辑）
# ============================================================
def count_words(text):
    if not text:
        return 0
    count = 0
    in_ascii = False
    for ch in text:
        r = ord(ch)
        if 0x4E00 <= r <= 0x9FFF or 0xF900 <= r <= 0xFAFF:
            count += 1
            in_ascii = False
        elif 0x30 <= r <= 0x39:
            count += 1
            in_ascii = False
        elif (0x41 <= r <= 0x5A) or (0x61 <= r <= 0x7A):
            if not in_ascii:
                count += 1
                in_ascii = True
        else:
            in_ascii = False
    return count


# ============================================================
# 简易质检（调用 NovelQualityChecker 算法的 Python 移植版）
# ============================================================
AI_CLICHE = ['嘴角', '唇角', '眼底', '眼神', '目光', '仿佛', '似乎', '宛如',
             '空气', '心跳', '深吸', '命运', '轨迹', '万语', '舒了一口',
             '微微上扬', '闪过一丝', '勾起一抹']
NEGATION = ['不', '没', '无', '没有', '并未', '不曾', '决不', '毫无']

# ============================================================
# 双端同步须知：以下词表与 Dart 端 lib/ai_pipeline/services/pipeline_qa.dart
# 对应常量同步维护（HOOK_WORDS<->_hookWords、OPENING_STRONG/_WEAK、
# THRILL_WORDS<thrillWords>、POWER_SURGE_WORDS<powerSurgeWords>、
# AI_ADVERBS<_aiAdverbs>、SENTENCE_CONNECTORS<_sentenceConnectors>、
# AI_ECHO<aiClicheWords>、NEGATION<negations>），以及 deep_ai_metrics
# 四项统计阈值。调优时必须同一次同时更新两端，防止标准漂移。
# ============================================================
# 章末钩子信号词（结尾 200 字内命中即视为有钩子，与 Dart PipelineQa 对齐）
# 经《碎脉铸仙录》33 章结尾全量实测校准：覆盖直白突变 + 隐喻式钩子
# （监视/诡谲意象/悬而未决），人工基线 91% 覆盖率。
HOOK_WORDS = ['突然', '猛然', '竟然', '就在这时', '就在此时', '刹那', '一瞬',
              '缓缓', '响起', '逼近', '袭来', '浮现', '动静', '不对劲',
              '怎么回事', '为什么', '究竟', '难道', '敲门声', '脚步声',
              '目光', '视线', '盯着', '没开过口', '探猎物', '不安全', '跟着',
              '尾随', '跟踪', '有人', '像有人', '一道人影', '一个声音', '一声冷笑',
              '有什么', '探出来', '那只眼', '正看着他', '暗处', '暗影',
              '旧疤', '刃口', '符箓', '未展开', '惨白', '泛着', '异动',
              '火燎', '咬掉', '又闪', '又响', '醒了过来', '暗红', '风铃', '渗',
              '看不清', '看不透', '将落未落', '还没有断', '没断', '发烫', '滴水',
              '黑影', '还没', '尚未', '来不及', '远远没', '不知何时', '轰', '嗡']

# 开场节奏·强信号词（双字/特定短语，1 个即视为快速进入事件）
# 双级判定避免单字词（碎/撞/压）在比喻语境（"像纸一样一碰就碎"）的误报。
OPENING_STRONG = ['穿越', '醒来', '重生', '系统', '觉醒', '废物', '杂种', '契约',
                  '丹田', '灵根', '考核', '耳光', '滚出']

# 开场节奏·弱信号词（单字动词/名词，需 >=2 个同时出现）
OPENING_WEAK = ['闯', '砸', '吼', '骂', '跪', '杀', '死', '血', '痛',
                '摔', '怒', '冲', '撞', '剑', '刀', '雷', '震', '裂', '碎',
                '废', '辱', '欺', '压', '滚', '魂']

# 兼容旧引用（qa_scan_existing.py 等曾 import 该名）
OPENING_ACTION_WORDS = OPENING_STRONG + OPENING_WEAK

# 爽点信号词（打脸/升级/收获/揭露 四大类，与 Dart PipelineQa 对齐）
# 选「语义明确」的词避免宽泛误报；每千字 <0.5 视为爽点过淡。
# 2026-09-07 扩展：原表为玄幻向（突破/玉简/功法），补入都市/悬疑/末世/科幻/游戏
# 题材的通用爽点词，避免题材词表失准（如《逆袭之巅》《雾锁迷城》被打低分）。
THRILL_WORDS = ['突破', '觉醒', '晋升', '顿悟', '蜕变', '脱胎换骨', '突破瓶颈', '进阶',
                '哑口无言', '脸色铁青', '目瞪口呆', '鸦雀无声', '颜面扫地',
                '下不来台', '难以置信', '不敢置信', '灰头土脸', '噤声', '讪讪',
                '愣住', '说不出话',
                '收入囊中', '白捡', '意外之喜', '认主', '获得传承', '获得功法',
                '大丰收', '捡到宝', '至宝', '契约',
                '真相大白', '水落石出', '恍然大悟', '惊觉', '识破', '原来是你',
                '竟然是他', '谜底', '露出真面目',
                '一模一样', '对得上',
                # —— 2026-09-07 题材扩展（都市/悬疑/末世/科幻/游戏）——
                # 系统流 / 都市金手指
                '系统激活', '绑定成功', '完成任务', '任务完成', '解锁', '权限提升',
                '经验值', '奖励到账', '到账', '首杀', '通关', '满级',
                # 打脸通用（都市/职场/商战）
                '碾压', '碾压全场', '全场震惊', '鸦雀无声', '刮目相看', '俯首',
                '乖乖交出', '低头认错', '自取其辱', '搬起石头', '打脸',
                # 悬疑/推理反转
                '真凶', '反转', '神反转', '水落石出', '真相浮出', '证据确凿',
                '铁证如山', '一锤定音', '当场拆穿', '原形毕露', '身份暴露',
                # 末世/科幻 变强
                '进化', '异能觉醒', '获得异能', '能力提升', '升级成功', '吞噬成功',
                '融合成功', '突破极限', '超频', '进化完成', '变异强化', '战力飙升',
                # 游戏/竞技
                '击败', '完胜', '绝杀', '反超', '夺冠', '晋级', '破纪录', 'MVP',
                '团灭', '一波带走']


# 题材专属爽点词表（2026-09-10 题材感知质检）：基础 THRILL_WORDS 为全题材通用，
# GENRE_THRILL_EXTRA 为各题材加成词——都市看重打脸/商战、悬疑看重反转/揭露、
# 末世/科幻看重进化/变异、游戏看重竞技/首杀。检测时用「基础词表 + 题材加成词」。
GENRE_THRILL_EXTRA = {
    "玄幻": [],
    "仙侠": [],
    "都市": ['翻身', '逆袭', '成交', '合同', '签约', '订单', '报表', '晋升通知',
             '董事会', '拿下项目', '赔偿', '解雇', '开除', '失业', '涨薪', '升职',
             '住进', '买车', '买房', '奢侈品', '被人围观', '经理', '总裁'],
    "都市异能": ['异能觉醒', '超能力', '念力', '控火', '控电', '隐身', '读心',
                '飞起来', '挡住子弹', '碾碎', '轰飞', '击退', '弹开', '挡住'],
    "科幻": ['曲速', '跃迁', '智械', '机甲', '能量核心', '歼星', '殖民舰',
             '星图', '超越', '破解', '代码', 'AI 觉醒', '算力'],
    "末世": ['进化', '异能', '晶核', '丧尸', '变异兽', '幸存者', '庇护所',
             '猎杀', '收割', '强化', '吞噬', '升级', '武器库', '清剿'],
    "游戏": ['首杀', '满级', '掉落', '神器', '装备', '副本首通', '全服', '公会',
             'PK', '团灭', '一波带走', 'MVP', '上分', '王者', '登录', '经验'],
    "悬疑": ['真凶', '反转', '证据', '真相', '破案', '抓捕', '结案', '指纹',
             '监控', '供认', '落网', '水落石出', '嫌疑人', '密室', '凶器'],
    "武侠": ['武功', '内力', '剑法', '掌法', '名震', '成名', '武林', '掌门',
             '秘籍', '神功', '快意恩仇', '切磋', '战', '破'],
    "历史": ['圣旨', '官拜', '封赏', '凯旋', '捷报', '升官', '权倾', '殿前',
             '大捷', '收复', '纳贡', '称臣', '赐婚'],
    "军事": ['击毙', '歼灭', '拿下', '突袭', '斩首', '缴获', '战利', '反杀',
             '突围', '胜利', '勋章', '一等功', '击落', '摧毁'],
    "体育": ['绝杀', '反超', '夺冠', '破纪录', '金牌', '决赛', '晋级', '逆转',
             '绝地', '爆冷', '教练', '首发', '战胜'],
}
GENRE_THRILL_ALL = {g: THRILL_WORDS + (GENRE_THRILL_EXTRA.get(g) or []) for g in GENRE_THRILL_EXTRA}


def thrill_per_thousand(text, genre=""):
    """爽点密度（每千字命中数）。网文参考线：>=1.5 合格，<0.5 过淡。
    genre 非空时叠加题材专属词表（都市/悬疑/末世等词表感知，避免题材误判）。"""
    if not text:
        return 0.0
    words_list = GENRE_THRILL_ALL.get(genre, THRILL_WORDS) if genre else THRILL_WORDS
    hits = sum(text.count(w) for w in words_list)
    words = count_words(text)
    return round(hits / words * 1000, 2) if words > 0 else 0.0


# 变强异动信号词（含蓄爽点：金手指/修为成长的身体异动表达，与 Dart 对齐）
# 实测：直白爽点词在《碎脉铸仙录》仅命中 5 处，而本类命中 58 处——
# 含蓄文风的爽点藏在「丹田温热/掌心发烫/铁粉苏醒」里，需双通道检测。
# 2026-09-07 扩展：补入异能/系统流身体异动（骨刺/断茬/星纹/数据流等）。
POWER_SURGE_WORDS = ['发烫', '温热', '流转', '苏醒', '凝聚', '暴涨', '充盈', '贯通',
                     '蠕动', '微光', '亮了一亮', '震颤', '嗡鸣', '顺着经脉', '涌入丹田',
                     '沉进丹田', '吞吸', '周天', '拱了一下', '醒了', '睁开眼',
                     # —— 2026-09-07 题材扩展（异能/系统/末世）——
                     '星纹', '光纹', '发亮', '一明一灭', '热流', '涌入体内', '灌入',
                     '钻进体内', '钻进经脉', '皮肉底下', '骨刺', '断茬', '长出',
                     '顶开', '破土', '抽芽', '生根', '融合', '数据流', '面板',
                     '提示音', '嘀', '叮', '进度条', '金光', '青芒', '白光',
                     '烫得', '灼热', '胀热', '酸麻', '发麻', '暴起', '腾起']


GENRE_SURGE_EXTRA = {
    "玄幻": [],
    "仙侠": [],
    "都市": ['心跳加速', '血压', '掌心出汗', '手指发抖', '头皮发麻', '背后发凉'],
    "都市异能": ['能量涌动', '蓝色电弧', '金色光晕', '念力波动', '身体变轻', '力量涌出'],
    "科幻": ['系统提示', '面板刷新', '数据跳动', '能量读数', '警报', '扫描'],
    "末世": ['晶核闪烁', '肉体强化', '骨骼作响', '血脉奔涌', '力量膨胀', '皮肤发紧'],
    "游戏": ['技能栏', '冷却结束', '血条', '蓝条', '装备发光', '暴击', '连击'],
    "悬疑": ['心跳漏拍', '瞳孔一缩', '汗毛竖起', '后颈发凉', '寒意', '鸡皮疙瘩'],
    "武侠": ['真气流转', '内力涌动', '气机', '丹田发热', '剑气', '血脉偾张'],
    "历史": ['手心发汗', '脊背发凉', '眼神一凛', '呼吸一窒', '跪'],
    "军事": ['雷达锁定', '警报响起', '肾上腺素', '手雷', '瞄准镜', '心跳加速'],
    "体育": ['观众沸腾', '计时器', '记分牌', '心跳如鼓', '肌肉紧绷', '观众席'],
}
GENRE_SURGE_ALL = {g: POWER_SURGE_WORDS + (GENRE_SURGE_EXTRA.get(g) or []) for g in GENRE_SURGE_EXTRA}


def surge_per_thousand(text, genre=""):
    """变强异动密度（每千字命中数）。玄幻文参考线：>=1.0 为含蓄变强流。
    genre 非空时叠加题材专属异动词（都市异能/末世/游戏等身体异动词表感知）。"""
    if not text:
        return 0.0
    words_list = GENRE_SURGE_ALL.get(genre, POWER_SURGE_WORDS) if genre else POWER_SURGE_WORDS
    hits = sum(text.count(w) for w in words_list)
    words = count_words(text)
    return round(hits / words * 1000, 2) if words > 0 else 0.0


# ============================================================
# AI 味深度检测（统计层：句长均匀度 / 的字密度 / 叠词 / 句首连接词）
# ============================================================
AI_ADVERBS = ['微微', '轻轻', '淡淡', '深深', '缓缓', '悄悄', '默默', '隐隐',
              '幽幽', '怔怔', '静静', '浅浅']
SENTENCE_CONNECTORS = ['然而', '但是', '因此', '与此同时', '于是', '随即',
                       '紧接着', '然后', '不过', '可是']

# —— 句式层 AI 指纹（2026-09-12 补：词表层/统计层抓不到的三类句式模式）——
# 对齐 FANQIE_SYSTEM_PROMPT 第 21 条（「像……似的」每千字不超过 2 次）：
# 此前约束已写进 prompt 但质检抓不到违规（有约束无检测），写手超密比喻无法被发现。
# 比喻：只抓明喻强结构（像X一样/似的/般、跟X似的）+ 比喻独词（仿佛/宛如等）；
# 「他像他爹」这类判断句不带结构标记，不计入（宁漏检勿误报）。
METAPHOR_PAT = re.compile(
    r"像[^。！？！?，\n]{1,18}(?:一样|似的|般)|跟[^。！？！?，\n]{1,18}(?:一样|似的)"
    r"|如同[^。！？！?，\n]{1,14}(?:一样|一般|似的)|仿佛|宛如|好似|犹如|恰似")

# 身体反应四件套（发烫/发凉/嗓子发干/汗毛立起一类）：真人写作只在关键节点用，
# AI 会每个场景配一套，形成可统计的风格指纹。阈值 2.5/千字（回测校准后定）。
BODY_REACTION_WORDS = ['发烫', '发凉', '发冷', '嗓子发干', '喉咙发干', '汗毛',
                       '头皮发麻', '掌心出汗', '手心出汗', '脊背发凉', '寒意',
                       '牙根发酸', '后槽牙', '呼吸一窒', '心跳漏拍', '胃里发紧',
                       '指尖发麻', '指尖发凉', '太阳穴一跳']

# 单句成段阈值：段落 ≤14 字视为单句段（喘气段），占比过高 = 机械节奏感
SINGLE_PARA_MAX_CHARS = 14


def _style_fingerprint_metrics(text):
    """句式层 AI 指纹三项：比喻密度 / 单句成段占比 / 身体反应密度（返回值与超标判定分离）。"""
    if not text:
        return {'metaphor_density': 0.0, 'single_para_rate': 0.0, 'body_reaction_density': 0.0}
    words = count_words(text)
    # 1) 比喻密度（每千字）
    metaphor_hits = len(METAPHOR_PAT.findall(text))
    metaphor_density = round(metaphor_hits / words * 1000, 2) if words else 0.0
    # 2) 单句成段占比（≤14 字短段 / 非空段落）
    paras = [p.strip() for p in text.split("\n") if p.strip()]
    single_para_rate = (round(sum(1 for p in paras if count_words(p) <= SINGLE_PARA_MAX_CHARS)
                              / len(paras) * 100, 1)) if paras else 0.0
    # 3) 身体反应密度（每千字）
    body_hits = sum(text.count(w) for w in BODY_REACTION_WORDS)
    body_reaction_density = round(body_hits / words * 1000, 2) if words else 0.0
    return {'metaphor_density': metaphor_density, 'single_para_rate': single_para_rate,
            'body_reaction_density': body_reaction_density}


# 句式指纹超标线（2026-09-12 四本真实成书回测校准，见 docs/quality-enhancement-log.md 第十一节）：
# - 比喻 2.0/千字：对齐 SYSTEM_PROMPT 第 21 条的承诺线（实测正常书 1.0-2.0，
#   《铁幕孤刃》4.75 超线但人工确认为好书——该线定位是「标记风格特征供人工复核」，非否决线）
# - 单句成段 30%：正常书 11-18%，仅《断脉逆命诀》31% 超标（第 5 章 44.7%，恰为终审官点名的追读断裂章）
# - 身体反应 1.5/千字：正常书 0.5-1.2，仅断脉第 1 章（风格指纹最重章）1.53 超线（回测后从 2.5 收紧）
STYLE_FP_LIMITS = {'metaphor_density': 2.0, 'single_para_rate': 30.0, 'body_reaction_density': 1.5}


def _split_sentences(text):
    import re as _re
    return [s.strip() for s in _re.split(r'[。！？!?…]+', text) if s.strip()]


def deep_ai_metrics(text):
    """AI 味深度指标：句长CV / 的字密度 / 叠词密度 / 句首连接词率
    + 句式指纹三项（比喻密度/单句成段占比/身体反应密度，2026-09-12 补）
    + level(0~5)：原四项各超标 +1；句式指纹三项中 ≥2 项超标再 +1（合并计 1 项，口径变化最小）。"""
    if not text:
        return {'sentence_cv': 0.0, 'de_density': 0.0,
                'adverb_density': 0.0, 'connector_rate': 0.0,
                'metaphor_density': 0.0, 'single_para_rate': 0.0, 'body_reaction_density': 0.0,
                'level': 0}
    words = count_words(text)

    # 1) 句长变异系数
    lens = [count_words(s) for s in _split_sentences(text)]
    lens = [n for n in lens if n > 0]
    cv = 0.0
    if len(lens) >= 3:
        mean = sum(lens) / len(lens)
        variance = sum((n - mean) ** 2 for n in lens) / len(lens)
        sd = variance ** 0.5
        cv = round(sd / mean, 2) if mean > 0 else 0.0

    # 2) 「的」字密度
    de_density = round(text.count('的') / words * 100, 2) if words else 0.0

    # 3) 叠词修饰密度（每千字）
    adv_hits = sum(text.count(w) for w in AI_ADVERBS)
    adverb_density = round(adv_hits / words * 1000, 2) if words else 0.0

    # 4) 句首连接词比例
    sents = _split_sentences(text)
    conn_hits = 0
    for s in sents:
        head = s[:4]
        if any(head.startswith(c) for c in SENTENCE_CONNECTORS):
            conn_hits += 1
    connector_rate = round(conn_hits / len(sents), 2) if sents else 0.0

    # 5) 句式指纹三项（≥2/3 超标 → 记 1 项超标，不逐项累加以免 level 失真）
    fp = _style_fingerprint_metrics(text)
    fp_over = sum(1 for k, lim in STYLE_FP_LIMITS.items() if fp[k] > lim)

    level = (1 if cv < 0.55 else 0) + (1 if de_density > 4.0 else 0) + \
            (1 if adverb_density > 2.0 else 0) + (1 if connector_rate > 0.15 else 0) + \
            (1 if fp_over >= 2 else 0)
    out = {'sentence_cv': cv, 'de_density': de_density,
           'adverb_density': adverb_density, 'connector_rate': connector_rate,
           'level': level}
    out.update(fp)
    return out


def has_ending_hook(text):
    """章末钩子检测：结尾 200 字内是否有未落地悬念信号。"""
    if not text:
        return False
    tail = text[-200:] if len(text) > 200 else text
    for w in HOOK_WORDS:
        if w in tail:
            return True
    last60 = tail[-60:] if len(tail) > 60 else tail
    return '？' in last60 or '?' in last60 or '……' in last60


def has_quick_opening(text):
    """开场节奏检测（黄金三章）：前 300 字是否进入变故/冲突。

    强信号（穿越/醒来/废物/耳光…）1 个即达标；弱信号（单字动词）需 >=2 个，
    避免比喻语境（"像纸一样一碰就碎"）误报。
    """
    if not text:
        return False
    head = text[:300]
    if any(w in head for w in OPENING_STRONG):
        return True
    weak_hits = sum(1 for w in OPENING_WEAK if w in head)
    return weak_hits >= 2


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
        })
    return report


# ============================================================
# 状态持久化
# ============================================================
def load_state(path, min_words=800):
    """加载进度；字数不足 min_words 的章节会被视为未完成，从 existing_idx 中排除以便重做。"""
    if not os.path.exists(path):
        return {"outline": None, "chapters": []}
    out = {"outline": None, "chapters": []}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "outline":
                out["outline"] = rec["data"]
            elif rec.get("type") == "chapter":
                ch = rec["data"]
                # 标记过短章节为需要重做
                if ch.get("words", 0) < min_words:
                    print(f"  [SKIP] 第 {ch.get('idx')} 章仅 {ch.get('words')} 字，标记为待重做")
                    continue
                out["chapters"].append(ch)
    return out


def append_state(path, kind, data):
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps({"type": kind, "data": data}, ensure_ascii=False) + "\n")


def export_txt(path, title, chapters):
    txt_path = path.replace(".jsonl", ".txt")
    with open(txt_path, "w", encoding="utf-8") as f:
        f.write(f"《{title}》\n\n")
        for ch in chapters:
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
    p.add_argument("--dry-run", action="store_true", help="只打印大纲不生成正文")
    args = p.parse_args()

    api_key = args.api_key or os.environ.get("NOVEL_LLM_API_KEY", "")
    base_url_raw = args.base_url

    print(f"[INFO] model={args.model}  target={args.total_words}字  file={args.output}")
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
    last_summary = ""
    if state["chapters"]:
        last_content = state["chapters"][-1].get("content", "")
        last_summary = last_content[-200:] if len(last_content) > 200 else last_content

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
        print(f"\n{'=' * 60}")
        print(f"[CH {idx}] {chapter_title}（目标 {target} 字）")
        print(f"  章纲：{goal}")
        print("=" * 60)

        # 场景规划
        plan = None
        for attempt in range(2):
            scene_plan_raw = call_llm(base_url_raw, args.model,
                                     "你擅长长篇小说结构，能把章纲拆成有序场景组合。",
                                     scene_planning_prompt(goal, last_summary, genre=args.genre),
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
                                         hook=hook_for(idx) if si + 1 == len(scenes) else ""),
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
        last_summary = full_text[-200:] if len(full_text) > 200 else full_text
        print(f"  [完成] 第 {idx} 章：{w} 字 | 累计 {total_words} 字")
        if args.chapter_wait > 0 and idx < args.max_chapters and total_words < args.total_words:
            time.sleep(args.chapter_wait)

    # ====== 第三步：质检汇总 ======
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
    print(f"\n  世界观冲突：{total_issues} 处")

    # ====== 第四步：导出 ======
    txt_path = export_txt(args.output, title, state["chapters"])
    jsonl_path = args.output
    print(f"\n[OK] 文本输出：{txt_path}")
    print(f"[OK] 进度文件：{jsonl_path}")
    print(f"[OK] 总字数：{sum(c.get('words', 0) for c in state['chapters'])}")


if __name__ == "__main__":
    main()
