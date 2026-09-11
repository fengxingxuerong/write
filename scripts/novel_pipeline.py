#!/usr/bin/env python3
"""墨匠 InkSmith —— 多模型协作长篇小说流水线（10 万字级）

角色分工（全部经连通性实测）：
  planner  Sensenova glm-5.2 (k2)         全书大纲 + 章节场景规划（temp=1, 大token）
  writer   AMD DeepSeek-V4-Flash          场景正文（故障转移 Sensenova dsf k1→k2→k3）
  editor   Sensenova kimi-k3 (k1/k2)      整章去AI味润色（temp=1）
  titler   Sensenova flash-lite (k3)      章节标题提炼
  verifier Sensenova glm-5.2 (k2)         每5章跨章一致性校验（只记录不阻塞）
  qa       本地规则引擎                   AI味密度/重复率/节奏/世界观冲突

断点续传：Ctrl+C 后重跑同一命令即可继续。
密钥经环境变量传入：NOVEL_KEY_AMD / NOVEL_KEY_SENSE_K1 / NOVEL_KEY_SENSE_K2 / NOVEL_KEY_SENSE_K3
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

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from generate_novel import (count_words, parse_json_from_llm, quality_check,
                            append_state, load_state, export_txt,
                            planning_prompt_idea, scene_planning_prompt, scene_prompt, hook_for,
                            has_ending_hook, SYSTEM_PROMPT)
from fanqie_review import (review_chapter, fix_prompt, redline_scan,
                           extract_world_terms)  # noqa: E402
from fanqie_prompts import first_screen_rewrite_prompt, pack_prompt  # noqa: E402

# ============================================================
# 模型配置（密钥经环境变量注入，不硬编码）
# ============================================================
SENSE = "https://token.sensenova.cn/v1/chat/completions"
AMD = "https://developer.amd.com.cn/radeon/api/v1/chat/completions"
NVIDIA = "https://integrate.api.nvidia.com/v1/chat/completions"

def _key(name):
    k = os.environ.get(name, "")
    if not k:
        print(f"[WARN] 环境变量 {name} 未设置！")
    return k

# 角色配置（2026-09-05 全量实测后定稿；2026-09-10 规划链接入商汤 K1/K3 分摊 AMD 限流压力）：
# 规划官：AMD 主 → 商汤 K1 glm-5.2 → 商汤 K3 → NVIDIA 备（商汤矩阵分摊，避免单链路限流卡死）
# 写手：AMD 主 → 商汤 K2 dsf 备
# 编辑：商汤 K2 kimi 主 → AMD 兜底
# 标题官：商汤 K2 dsf
# 审校：商汤 K1 glm-5.2（大 token）→ AMD 兜底
PLANNER = dict(url=AMD, model="DeepSeek-V4-Flash", key="", temp=0.8, max_tokens=4000)
PLANNER_CHAIN = [
    dict(url=AMD, model="DeepSeek-V4-Flash", key="", temp=0.8, max_tokens=4000),      # AMD 主
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=4000),              # 商汤 K1 glm-5.2 备（配额恢复后生效）
    dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=4000),    # 商汤 K3 dsf 备
    dict(url=NVIDIA, model="deepseek-ai/deepseek-v4-flash-0731", key="", temp=0.8, max_tokens=4000),  # NVIDIA 备
]
WRITER_CHAIN = [
    dict(url=AMD, model="DeepSeek-V4-Flash", key="", temp=0.8),                     # AMD 主
    dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8),                    # 商汤 K2 dsf 备
]
EDITOR_CHAIN = [
    dict(url=SENSE, model="kimi-k3", key="", temp=1.0, max_tokens=4000),           # 商汤 K2 kimi 主
    dict(url=AMD, model="DeepSeek-V4-Flash", key="", temp=0.8),                     # AMD 兜底
]
TITLER = dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=300)  # 商汤 K2 dsf
VERIFIER = dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=3000)     # 商汤 K1 glm-5.2 大 token


def setup_keys():
    PLANNER["key"] = _key("NOVEL_KEY_AMD")
    PLANNER_CHAIN[0]["key"] = _key("NOVEL_KEY_AMD")
    PLANNER_CHAIN[1]["key"] = _key("NOVEL_KEY_SENSE_K1")
    PLANNER_CHAIN[2]["key"] = _key("NOVEL_KEY_SENSE_K3")
    PLANNER_CHAIN[3]["key"] = _key("NOVEL_KEY_NVIDIA")
    WRITER_CHAIN[0]["key"] = _key("NOVEL_KEY_AMD")
    WRITER_CHAIN[1]["key"] = _key("NOVEL_KEY_SENSE_K2")
    EDITOR_CHAIN[0]["key"] = _key("NOVEL_KEY_SENSE_K2")
    EDITOR_CHAIN[1]["key"] = _key("NOVEL_KEY_AMD")
    TITLER["key"] = _key("NOVEL_KEY_SENSE_K2")
    VERIFIER["key"] = _key("NOVEL_KEY_SENSE_K1")


# ============================================================
# 非流式调用（Sensenova 系模型流式格式不统一，统一非流式最稳）
# ============================================================
# 健康 key 池（2026-09-10 配额感知路由）：记录每个 provider 的连续失败/冷却状态。
# 冷却中的 provider 会被跳过，避免单 key 配额耗尽后反复撞 429 浪费时间；
# 冷却期满自动恢复，运行中持续自愈。
_HEALTH = {}  # key: {fails: 连续失败数, cooldown_until: 时间戳, hits: 成功数}
COOLDOWN_SECONDS = 300  # 连续失败 N 次后冷却 5 分钟


def _mark_fail(provider):
    k = (provider["url"], provider["model"])
    h = _HEALTH.setdefault(k, {"fails": 0, "cooldown_until": 0, "hits": 0})
    h["fails"] += 1
    if h["fails"] >= 3:
        h["cooldown_until"] = time.time() + COOLDOWN_SECONDS
        print(f"    [健康池] {provider['model']} 连续失败 {h['fails']} 次，冷却 {COOLDOWN_SECONDS}s")


def _mark_ok(provider):
    k = (provider["url"], provider["model"])
    h = _HEALTH.setdefault(k, {"fails": 0, "cooldown_until": 0, "hits": 0})
    h["fails"] = 0
    h["hits"] += 1


def _in_cooldown(provider):
    k = (provider["url"], provider["model"])
    h = _HEALTH.get(k)
    if not h or h["cooldown_until"] <= time.time():
        return False
    return True


def llm_call(provider, system, user, max_tokens=None, temperature=None, retries=2):
    """非流式 OpenAI 兼容调用，带指数退避。返回内容字符串，失败返回 ''。"""
    payload = {
        "model": provider["model"],
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": max_tokens or provider.get("max_tokens", 2000),
        "temperature": temperature if temperature is not None else provider.get("temp", 0.8),
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    body = json.dumps(payload).encode("utf-8")
    url = provider["url"].rstrip("/")
    # 配额感知路由：冷却中的 key 直接跳过（返回空让 call_chain 切下一个）
    if _in_cooldown(provider):
        return ""
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, data=body, method="POST")
            req.add_header("Content-Type", "application/json")
            req.add_header("Authorization", f"Bearer {provider['key']}")
            with urllib.request.urlopen(req, timeout=300) as resp:
                d = json.loads(resp.read().decode("utf-8"))
                content = d.get("choices", [{}])[0].get("message", {}).get("content", "") or ""
                if content.strip():
                    _mark_ok(provider)
                return content
        except urllib.error.HTTPError as e:
            msg = e.read().decode("utf-8", errors="replace")[:160].replace("\n", " ")
            if e.code in (429, 500, 502, 503):
                _mark_fail(provider)
                wait = (3 ** (attempt + 1)) * 5 + random.randint(3, 15)
                print(f"    [retry {attempt+1}/{retries}] {provider['model']} HTTP {e.code}: {msg} (等 {wait}s)")
                if attempt < retries:
                    time.sleep(wait)
                    continue
            else:
                print(f"    [HTTP {e.code}] {provider['model']}: {msg}")
            return ""
        except Exception as e:
            _mark_fail(provider)
            print(f"    [retry {attempt+1}/{retries}] {provider['model']}: {type(e).__name__}: {str(e)[:100]}")
            if attempt < retries:
                time.sleep((3 ** attempt) * 5)
                continue
    return ""


def call_chain(chain, system, user, max_tokens):
    """沿故障转移链依次调用，返回第一个非空结果。冷却中的 key 自动跳过。"""
    for p in chain:
        if _in_cooldown(p):
            print(f"    [chain] {p['model']} 冷却中，跳过")
            continue
        r = llm_call(p, system, user, max_tokens=max_tokens)
        if r and len(r.strip()) > 20:
            return r
        print(f"    [chain] {p['model']} 返回为空，切换下一个")
    return ""


def dedup_scene_join(prev_text, new_text, min_overlap=12):
    """场景拼接去重：若 new_text 开头与 prev_text 结尾有 >=min_overlap 字的
    连续重叠（LLM 续写时常把上一场景结尾复述一遍），裁掉重叠部分再拼接。
    返回去重后的 new_text（不包含重叠头）。"""
    if not prev_text or not new_text:
        return new_text
    prev_tail = prev_text.rstrip()[-200:]
    best = 0
    # 找 new_text 前缀与 prev_tail 后缀的最长公共重叠
    max_check = min(len(new_text), len(prev_tail))
    for i in range(max_check, min_overlap - 1, -1):
        if prev_tail[-i:] == new_text[:i]:
            best = i
            break
    if best >= min_overlap:
        print(f"    [去重] 场景衔接重叠 {best} 字，已裁剪")
        return new_text[best:]
    return new_text


# ============================================================
# 各角色 Prompt
# ============================================================
PLANNER_SYS = "你是一位资深网文总编，擅长长篇小说的框架规划。输出严格遵循要求的 JSON 格式。"
EDITOR_SYS = "你是一位资深网文编辑，专精「去AI味」改写。"
TITLER_SYS = "你是一位网文标题专家，擅长提炼有悬念感、点击欲的章名。"
VERIFIER_SYS = "你是一位严谨的长篇小说一致性审校编辑。"


def editor_prompt(text):
    return f"""请把下面的小说章节改写得更像真人网文作者的手笔：

1. 全篇「仿佛/似乎/宛如」合计不超过 2 次；清除「嘴角勾起」「眼底闪过」「空气凝固」「深吸一口气」「空气像是被人抽走」等 AI 高频表达
2. 情节、人物、伏笔、章节结尾的钩子必须全部保留，不新增、不删减剧情
3. 对话更口语化、更有潜台词；描写更具体（数字、颜色、气味、声响），允许更「糙」、更有网文节奏
4. 保持原有段落结构

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


def quality_review_prompt(text):
    """语义级五维评分（开篇/爽点/钩子/动机/节奏），输出 JSON。"""
    return f"""请以网文编辑的眼光为下面的章节打分（每项 0~100）：
1. opening：开篇是否快速进入事件、有代入感（黄金三章标准）
2. thrill：爽点密度与强度（打脸/升级/收获/秘密揭露；含蓄变强具象化也算）
3. hook：章末钩子是否让人想看下一章（悬念/变故/威胁）
4. motivation：人物动机是否清晰、行为是否合理
5. rhythm：节奏是否张弛有度、无注水、无流水账

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
- 随身物品的获得/丢失（含具体物名：玉简/银戒/灰布/断剑/钥匙等）
- 承诺、恩怨、伪装身份
- 关键地点变化
- 已发生的关键事件（探秘/寻宝/获传承/对峙等，注明已完成，下章不得重复设计同一事件）

要求：
1. 在旧状态基础上增删改，不要整段重写
2. 每条一行，格式：人物：状态；物品：xxx；事件：xxx（已完成）
3. 输出 3~10 行，简洁具体
4. 只输出状态清单文本，不要任何解释或 Markdown

【旧状态】（首次为空）
{prev}

【本章内容】
{text}"""


# ============================================================
# 跨章状态持久化（写入 jsonl 的 type=state_track 行）
def load_state_track(path):
    """从进度文件恢复跨章状态清单（无则返回空串）。"""
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "state_track":
                return rec.get("data", "")
    return ""


# ============================================================
# 伏笔台账（foreshadow ledger）：长篇不丢伏笔的核心机制
# ============================================================
def foreshadow_extract_prompt(text, prev_ledger, idx):
    """从本章内容提取/更新伏笔台账。prev_ledger 为既有台账（JSON 字符串）。
    输出严格 JSON：{"foreshadows":[{"desc":"伏笔描述","planted":埋设章号,"recovered":回收章号或null,"status":"open/closed"}]}
    仅记录「明确埋下且预期后文回收」的设定级伏笔（神秘物件/预言/身份谜团/异常现象），
    不记录普通对话、氛围描写。"""
    prev = prev_ledger if prev_ledger and prev_ledger.strip() else "[]"
    return f"""你是长篇小说伏笔管理员。请根据本章内容（第 {idx} 章），维护一份「伏笔台账」，防止长篇写作丢伏笔/改设定。

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
4. 只输出 JSON 数组文本（不要 Markdown），格式：
{{"foreshadows":[{{"desc":"伏笔描述（一句话）","planted":1,"recovered":null,"status":"open"}}]}}

【旧台账】
{prev}

【本章内容】
{text}"""


def load_foreshadow(path):
    """从进度文件恢复伏笔台账（JSON 字符串，无则返回 '[]'）。"""
    if not os.path.exists(path):
        return "[]"
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "foreshadow":
                return rec.get("data", "[]")
    return "[]"


def save_foreshadow(path, data):
    """持久化伏笔台账（type=foreshadow 行）。"""
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps({"type": "foreshadow", "data": data}, ensure_ascii=False) + "\n")
    except Exception:
        pass


def check_open_foreshadows(ledger_json, cur_idx, stale_after=5):
    """检查超时未回收伏笔：埋设超过 stale_after 章仍未回收的伏笔，返回告警列表。"""
    if not ledger_json or ledger_json.strip() == "[]":
        return []
    try:
        data = json.loads(ledger_json)
        items = data.get("foreshadows", []) if isinstance(data, dict) else data
    except Exception:
        return []
    warnings = []
    for it in items:
        if not isinstance(it, dict):
            continue
        if it.get("status") == "open" and it.get("recovered") is None:
            planted = it.get("planted", cur_idx)
            age = cur_idx - planted
            if age >= stale_after:
                warnings.append(f"⚠ 伏笔超时未收（已{age}章）：{it.get('desc','?')}（埋于第{planted}章）")
    return warnings
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "state_track":
                return rec.get("data", "")
    return ""


def scan_used_protagonist_names(glob_dir="D:/novel-writer/data/generated"):
    """扫描既有 jsonl 大纲，收集已用主角名（跨书查重，防规划官惯性起名）。
    返回已用名单列表；扫描失败返回空列表（不影响生成）。"""
    used = []
    try:
        if not os.path.isdir(glob_dir):
            return used
        for fn in os.listdir(glob_dir):
            if not fn.endswith(".jsonl"):
                continue
            p = os.path.join(glob_dir, fn)
            try:
                with open(p, encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            rec = json.loads(line)
                        except Exception:
                            continue
                        if rec.get("type") != "outline":
                            continue
                        outline = rec.get("data") or {}
                        if isinstance(outline, str):
                            try:
                                outline = json.loads(outline)
                            except Exception:
                                continue
                        pobj = outline.get("protagonist")
                        if isinstance(pobj, dict) and pobj.get("name"):
                            used.append(pobj["name"])
            except Exception:
                continue
    except Exception:
        return []
    # 去重保序
    seen = set()
    uniq = []
    for n in used:
        if n and n not in seen:
            seen.add(n)
            uniq.append(n)
    return uniq


def save_state_track(path, data):
    """追加跨章状态清单到进度文件。"""
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps({"type": "state_track", "data": data}, ensure_ascii=False) + "\n")


# ============================================================
# 主线
# ============================================================
def _splice_head(text, new_head, min_cut=300, hard_cap=700):
    """把开头替换成 new_head，切点落在段落边界（避免把句子拦腰剪断）。"""
    if not new_head or not new_head.strip():
        return text
    cut = text.find("\n\n")
    while cut != -1 and cut < min_cut:
        cut = text.find("\n\n", cut + 2)
    if cut == -1 or cut > hard_cap:
        cut = min(hard_cap, len(text))
    return new_head.strip() + "\n\n" + text[cut:].lstrip()


VAGUE_WORLD_PAT = ("大陆名|朝代名|星域名|主舞台城市|案发城市|城市名|联赛舞台|战场背景"
                   "|游戏世界名|并存区名|幸存区名|江湖地名|九州名|主要势力|势力名")


def concretize_world(outline, genre):
    """world 仍是「大陆名/朝代名」这类占位词时，追一次只补设定的调用。

    写手与评审器都靠 world 里的专名锁定题材；填类别名等于两边都拿不到信息
    （旧版 14 本里就有好几本世界观看不出题材，历史样本因此被一致性检查误扣）。"""
    w = outline.get("world")
    if not isinstance(w, dict) or not w:
        return outline
    vague = [k for k, v in w.items()
             if not isinstance(v, str) or re.search(VAGUE_WORLD_PAT, v)]
    if not vague:
        return outline
    print(f"  [设定] world 字段过于笼统（{'、'.join(vague)}）→ 让规划官具体化…")
    ask = ("下面这本小说的世界观字段写的是占位词，写手无法据此建立世界。"
           f"请只把这些字段改成**自拟的具体专名与数值**（题材：{genre}），"
           "不要改动书名、主角名与章节结构。只输出 JSON 对象，键与下面完全一致：\n"
           + json.dumps({k: w[k] for k in vague}, ensure_ascii=False))
    raw = call_chain(PLANNER_CHAIN, PLANNER_SYS, ask, max_tokens=800)
    fixed = parse_json_from_llm(raw)
    if isinstance(fixed, dict):
        merged = dict(w)
        changed = False
        for k in vague:
            v = fixed.get(k)
            if isinstance(v, str) and v.strip() and not re.search(VAGUE_WORLD_PAT, v):
                merged[k] = v.strip()
                changed = True
        if changed:
            outline = dict(outline)
            outline["world"] = merged
            print("  [设定] 已具体化")
    return outline


def main():
    p = argparse.ArgumentParser(description="墨匠多模型协作流水线")
    p.add_argument("--total-words", type=int, default=100000, help="目标总字数")
    p.add_argument("--max-chapters", type=int, default=40)
    p.add_argument("--output", default="novel_pipeline.jsonl")
    p.add_argument("--genre", default="玄幻",
                   help="题材（玄幻/仙侠/都市/都市异能/科幻/末世/游戏/悬疑/武侠/历史/军事/体育）")
    p.add_argument("--chapter-wait", type=float, default=2.0)
    p.add_argument("--review-pass", type=float, default=78.0,
                   help="番茄过审评审卡及格线：低于此分触发一轮定点修")
    p.add_argument("--golden-chapters", type=int, default=3,
                   help="前 N 章额外做首屏 300 字强化（番茄完读率命门）")
    p.add_argument("--no-fanqie-pack", action="store_true",
                   help="不生成上架包（书名/简介/标签）与评估卡文件")
    p.add_argument("--skip-amd", action="store_true",
                   help="跳过 AMD/NVIDIA 链路，直接走商汤（AMD 持续限流时用）")
    p.add_argument("--prev-summary-file", default="",
                   help="前情提要文件（续写模式：规划官须承接该剧情）")
    args = p.parse_args()

    prev_summary = ""
    if args.prev_summary_file and os.path.exists(args.prev_summary_file):
        with open(args.prev_summary_file, encoding="utf-8") as pf:
            prev_summary = pf.read().strip()

    setup_keys()
    if args.skip_amd:
        # 跳过 AMD/NVIDIA：把这两条链路预标记为冷却（call_chain 自动跳过，直接走商汤）
        for p in [PLANNER, PLANNER_CHAIN[0], PLANNER_CHAIN[3], WRITER_CHAIN[0],
                  EDITOR_CHAIN[1], VERIFIER]:
            _HEALTH[(p["url"], p["model"])] = {"fails": 3, "cooldown_until": time.time() + 24 * 3600, "hits": 0}
        print("[INFO] --skip-amd：跳过 AMD/NVIDIA 链路，纯商汤路由")
    print(f"[INFO] 协作流水线启动 | 目标 {args.total_words} 字 | 输出 {args.output}")

    state = load_state(args.output, min_words=0)
    outline = state["outline"]
    state_track = load_state_track(args.output)
    if state_track:
        print(f"[RESUME] 已恢复跨章状态清单（{len(state_track.splitlines())} 行）")
    foreshadow_ledger = load_foreshadow(args.output)
    if foreshadow_ledger and foreshadow_ledger.strip() != "[]":
        print(f"[RESUME] 已恢复伏笔台账（{foreshadow_ledger.count('\"desc\"')} 条）")

    # ===== Phase 1：总规划官 =====
    if not outline:
        print("=" * 60)
        print("[Planner] 规划全书大纲...")
        print("=" * 60)
        text = llm_call(PLANNER, PLANNER_SYS, planning_prompt_idea(args.total_words, prev_summary, genre=args.genre,
                                                                  used_names=scan_used_protagonist_names()))
        outline = parse_json_from_llm(text)
        if not outline or not outline.get("chapter_outlines"):
            print(f"[ERROR] 大纲规划失败：{(text or '')[:300]}")
            sys.exit(1)
        outline = concretize_world(outline, args.genre)
        append_state(args.output, "outline", outline)
        title = outline.get("title", "未命名")
        print(f"[OK]《{title}》共 {len(outline['chapter_outlines'])} 章")
    else:
        title = outline.get("title", "未命名")
        print(f"[RESUME]《{title}》已有 {len(state['chapters'])} 章，继续")

    chars = outline.get("chapter_outlines", [])
    pobj = outline.get("protagonist")
    protagonist = pobj.get("name", "") if isinstance(pobj, dict) else ""
    # 世界观必须随场景下发：写手拿不到设定时会自己另起一个故事（实测会跑题成古代）。
    wobj = outline.get("world") or {}
    world_str = wobj if isinstance(wobj, str) else json.dumps(wobj, ensure_ascii=False)
    review_world_terms = extract_world_terms(outline)
    total_words = sum(count_words(c.get("content", "")) for c in state["chapters"])
    existing_idx = {c["idx"] for c in state["chapters"]}
    last_summary = ""
    if state["chapters"]:
        last_content = state["chapters"][-1].get("content", "")
        last_summary = last_content[-200:] if len(last_content) > 200 else last_content

    # ===== Phase 2：逐章多角色协作 =====
    reviews = []
    for ch in chars:
        idx = ch["idx"]
        if idx in existing_idx:
            continue
        if total_words >= args.total_words:
            print(f"\n[DONE] 达成目标字数 {total_words} >= {args.total_words}")
            break
        if idx > args.max_chapters:
            break

        chapter_title = ch.get("title", f"第{idx}章")
        goal = ch.get("goal", "")
        target = ch.get("target", 3000)
        print(f"\n{'=' * 60}\n[CH {idx}] {chapter_title}（目标 {target} 字）\n  章纲：{goal}\n{'=' * 60}")

        # 1) 场景规划（planner 链 + 默认骨架兜底），注入跨章状态与全书世界观
        # 全书世界观取自大纲 world 字段，防止正文脱离规划官设定（裴照系统流→赵铁柱超自然流 事故）
        world_hint = json.dumps(outline.get("world", {}), ensure_ascii=False) if isinstance(outline, dict) else ""
        hook_hint = outline.get("hook", "") if isinstance(outline, dict) else ""
        if world_hint:
            world_hint += ("；开篇钩子：" + hook_hint) if hook_hint else ""
        # 未收伏笔摘要注入（提醒写手：已埋伏笔勿改设定，长线伏笔等待回收）
        fs_open_summary = ""
        try:
            fs_data = json.loads(foreshadow_ledger) if foreshadow_ledger else {}
            fs_items = fs_data.get("foreshadows", []) if isinstance(fs_data, dict) else []
            fs_open = [it.get("desc", "") for it in fs_items if it.get("status") == "open" and it.get("desc")]
            if fs_open:
                fs_open_summary = "【未收伏笔（写作时勿改相关设定，尽量自然推进/回收）】\n" + "\n".join(f"- {d}" for d in fs_open[:8])
        except Exception:
            pass
        state_inject = state_track
        if fs_open_summary:
            state_inject = (state_track + "\n\n" + fs_open_summary) if state_track else fs_open_summary
        plan = None
        for attempt in range(2):
            raw = call_chain(PLANNER_CHAIN, PLANNER_SYS,
                             scene_planning_prompt(goal, last_summary, state_inject,
                                                   protagonist=protagonist, genre=args.genre,
                                                   world_hint=world_hint),
                             max_tokens=2000)
            plan = parse_json_from_llm(raw)
            if plan and plan.get("scenes"):
                break
        if not plan or not plan.get("scenes"):
            print("  [规划] LLM 场景规划失败，使用默认「起承转合」骨架兜底")
            plan = {"scenes": [
                {"index": 0, "stage": "起", "goal": f"场景铺垫：{goal[:30]}", "beats": [], "targetWords": max(400, int(target * 0.3))},
                {"index": 1, "stage": "承", "goal": "事件推进，冲突升级", "beats": [], "targetWords": max(400, int(target * 0.25))},
                {"index": 2, "stage": "转", "goal": "局势逆转，危机爆发", "beats": [], "targetWords": max(400, int(target * 0.25))},
                {"index": 3, "stage": "合", "goal": "收束本章并埋下钩子", "beats": [], "targetWords": max(400, int(target * 0.2))},
            ]}
        scenes = plan["scenes"]
        print(f"  [规划] {len(scenes)} 场景：{'/'.join(s.get('stage','承') for s in scenes)}")

        # 2) 逐场景正文（writer，带故障转移）
        scene_texts = []
        prev_text = last_summary
        for si, sc in enumerate(scenes):
            stage = sc.get("stage", "承")
            goal_s = sc.get("goal", "")
            beats = sc.get("beats", [])
            tw = sc.get("targetWords", 600)
            print(f"  [场景 {si+1}/{len(scenes)}] {stage}：{goal_s}（目标 {tw} 字）")
            text = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                              scene_prompt(si + 1, len(scenes), stage, goal_s, beats, prev_text, args.genre,
                                           state_track, protagonist=protagonist, world=world_str,
                                           hook=hook_for(idx) if si + 1 == len(scenes) else "",
                                           is_opening=(idx == 1 and si == 0)),
                              max_tokens=int(tw * 3.0))
            text = text.strip()
            # 场景衔接去重：裁掉与上一场景结尾重复的开头
            if scene_texts:
                text = dedup_scene_join(scene_texts[-1], text)
            w = count_words(text)
            print(f"    -> {w} 字")
            if text:
                scene_texts.append(text)
                prev_text = text
            if w < tw * 0.4 and len(text) > 50:
                add = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                                 f"请续写 300 字，承接：\n{text[-100:]}\n\n只输出续写正文：",
                                 max_tokens=600)
                if add.strip():
                    scene_texts.append("\n\n" + add.strip())
            time.sleep(args.chapter_wait)

        full_text = "\n\n".join(scene_texts)
        # 章节级衔接去重：本章开头若与上一章结尾重叠（LLM 跨章续写常见），裁剪
        if idx > 1 and last_summary:
            full_text = dedup_scene_join(last_summary, full_text)
        w = count_words(full_text)
        if w < target * 0.5:
            print(f"  [WARN] 仅 {w} 字，整章续写...")
            add = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                             f"请将下面章节内容扩充到 {target} 字以上，保留原意，只输出正文：\n{full_text[:500]}...",
                             max_tokens=int(target * 1.8))
            if add.strip():
                full_text += "\n\n" + add.strip()
                w = count_words(full_text)

        # 3) 去AI味润色（editor）
        edited = call_chain(EDITOR_CHAIN, EDITOR_SYS, editor_prompt(full_text), max_tokens=int(w * 2.0) + 800)
        if edited:
            w_edited = count_words(edited)
            print(f"  [编辑] 润色完成 {w} -> {w_edited} 字（AI味密度对比见质检）")
            final_text = edited
        else:
            print("  [编辑] 润色失败，保留原文")
            final_text = full_text

        # 3.5) 末尾完整性检查 + 自动补全（防止结尾被 max_tokens 截断成残句）
        if final_text.strip():
            tail = final_text.rstrip()[-12:]
            # 完整结尾：以句号/感叹号/问号/省略号/闭合引号/破折号 收尾
            if not any(tail.endswith(p) for p in ("。", "！", "？", "…", "”", "」", "』", "）", "——", "……")):
                print("  [补全] 章末疑似截断，自动补全结尾...")
                add = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                                 f"下面是本章结尾，句子似乎没写完（可能被截断）。请接着补全 50~120 字，"
                                 f"把话说完、收束本章并保持原有语气与伏笔，不要另起新情节。只输出补全内容：\n\n{final_text[-200:]}",
                                 max_tokens=400)
                if add and len(add.strip()) > 10:
                    final_text = final_text.rstrip() + add.strip()
                    print(f"  [补全] 已补全 {count_words(add)} 字，最终 {count_words(final_text)} 字")
                else:
                    print("  [补全] 补全失败，保留原文")

        # 3.6) 章末钩子兜底：结尾 200 字无钩子信号词时，补写钩子句（保追读）
        if final_text.strip() and not has_ending_hook(final_text):
            print("  [钩子] 章末缺钩，自动补写钩子...")
            add = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                             f"下面是本章结尾，最后 1~2 句太平淡，没有留下让读者必须看下一章的悬念。"
                             f"请接着补写 30~80 字的钩子句（悬念/变故/威胁逼近/秘密将揭，按{args.genre}题材），"
                             f"不新增情节、不改变已发生的事，只把结尾收在悬念上。只输出补写内容：\n\n{final_text[-300:]}",
                             max_tokens=300)
            if add and len(add.strip()) > 8:
                final_text = final_text.rstrip() + "\n\n" + add.strip()
                print(f"  [钩子] 已补写钩子：{add.strip()[:40]}...")
            else:
                print("  [钩子] 补写失败，保留原文")

        # 4) 章节标题（titler）
        t = llm_call(TITLER, TITLER_SYS, titler_prompt(final_text))
        raw_title = (t.strip() or chapter_title).strip(" \"「」『』《》")
        # 后置防护：标题过长或带标点则回退章纲标题
        if len(raw_title) > 10 or any(c in raw_title for c in "，。！？、；：,，\"'"):
            print(f"  [标题] 不合格（{raw_title}），回退章纲标题")
            title_ok = chapter_title
        else:
            title_ok = raw_title
        print(f"  [标题] {title_ok}")

        # 5) 每 5 章一致性审校（verifier，只记录）
        issues = []
        if idx % 5 == 0 and state["chapters"]:
            chap_list = "\n".join(f"第{c['idx']}章《{c.get('title','')}》" for c in state["chapters"][-5:])
            v = llm_call(VERIFIER, VERIFIER_SYS, verifier_prompt(outline, chap_list), max_tokens=1000)
            parsed = parse_json_from_llm(v, repair=False)
            if parsed and parsed.get("issues"):
                issues = parsed["issues"]
                for it in issues:
                    print(f"  [审校] ⚠ 第{it.get('chapter','?')}章 {it.get('type','')}: {it.get('desc','')}")

        # 6) 语义质量评分（每 3 章，verifier）+ 低分自动重写（editor）
        if idx % 3 == 0:
            qr = llm_call(VERIFIER, VERIFIER_SYS, quality_review_prompt(final_text), max_tokens=1000)
            parsed = parse_json_from_llm(qr, repair=False)
            overall, scores, comment = -1, None, ""
            if parsed:
                scores = parsed.get("scores") or {}
                overall = int(parsed.get("overall", -1))
                comment = str(parsed.get("comment", ""))
            if overall >= 0:
                dims = " ".join(f"{k}={v}" for k, v in scores.items()) if scores else "-"
                print(f"  [评分] 第 {idx} 章 综合 {overall} 分（{dims}）{comment}")
                if overall < 55:
                    print(f"  [重写] 第 {idx} 章 {overall} 分 < 55，触发自动重写...")
                    rw = call_chain(EDITOR_CHAIN, EDITOR_SYS,
                                    rewrite_prompt(final_text, comment, scores),
                                    max_tokens=int(w * 1.6) + 500)
                    if rw and len(rw.strip()) > 100:
                        w_old = count_words(final_text)
                        final_text = rw.strip()
                        w = count_words(final_text)
                        issues.append({"chapter": idx, "type": "auto_rewrite",
                                       "desc": f"{overall} 分已自动重写"})
                        print(f"  [重写] 第 {idx} 章 {w_old} 字 -> {w} 字")
                    else:
                        print(f"  [重写] 失败，保留原文")
            else:
                print(f"  [评分] 第 {idx} 章 评分解析失败，跳过（不影响生成）")

        # 3.6) 番茄过审评审：不达标就一轮定点修（只改问题处，不动剧情）
        rv = review_chapter(final_text, last_summary, idx, args.genre, protagonist,
                            review_world_terms)
        if rv["score"] < args.review_pass and rv["problems"]:
            fp = fix_prompt(rv, final_text)
            if not fp.strip():
                # 只剩「建议」级问题：不值得为它花一次 LLM 调用
                print(f"  [评审] {rv['score']} 分（仅剩建议项，不触发定点修）")
            else:
                print(f"  [评审] {rv['score']} 分，{len(rv['problems'])} 项不达标 → 定点修…")
                for pr in rv["problems"][:6]:
                    print(f"      ↳ [{pr['action']}] {pr['type']}：{pr['msg']}")
                fixed = call_chain(
                    EDITOR_CHAIN, SYSTEM_PROMPT,
                    fp,
                    max_tokens=int(count_words(final_text) * 2.2) + 800)
                if fixed and count_words(fixed) > count_words(final_text) * 0.5:
                    fixed = fixed.strip()
                    rv2 = review_chapter(fixed, last_summary, idx, args.genre, protagonist,
                                         review_world_terms)
                    print(f"  [评审] 修后 {rv2['score']} 分（原 {rv['score']} 分）")
                    if rv2["score"] >= rv["score"]:
                        final_text, rv = fixed, rv2
                else:
                    print("  [评审] 定点修无有效产出，保留原文")
        else:
            print(f"  [评审] {rv['score']} 分 达线")
        if rv["redline"]["veto"]:
            print(f"  [评审] ☠ 合规红线 {len(rv['redline']['veto'])} 处，需人工复核")
        reviews.append(rv)
        append_state(args.output, "review", {"idx": idx, "score": rv["score"],
                                             "verdict": rv["verdict"],
                                             "problems": rv["problems"]})

        # 3.7) 黄金三章：首屏 300 字单独强化一轮
        if idx <= args.golden_chapters:
            head = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                              first_screen_rewrite_prompt(final_text, args.genre, protagonist),
                              max_tokens=1400)
            if head and 80 <= count_words(head) <= 700:
                cand = _splice_head(final_text, head)
                rv_head = review_chapter(cand, last_summary, idx, args.genre, protagonist,
                                         review_world_terms)
                if rv_head["score"] >= (reviews[-1]["score"] if reviews else 0):
                    print(f"  [首屏] 已强化（评审 {rv_head['score']} 分）")
                    final_text = cand
                    if reviews:
                        reviews[-1] = rv_head
                else:
                    print(f"  [首屏] 强化后反而降分（{rv_head['score']}），丢弃")

        chapter_record = {
            "idx": idx,
            "title": title_ok,
            "content": final_text,
            "words": count_words(final_text),
            "raw_words": w,
            "scenes": len(scenes),
            "issues": issues,
        }
        state["chapters"].append(chapter_record)
        append_state(args.output, "chapter", chapter_record)
        total_words += chapter_record["words"]
        last_summary = final_text[-200:] if len(final_text) > 200 else final_text

        # 7) 跨章状态提取：维护状态清单供下一章写作遵守（失败保留旧状态）
        st = llm_call(VERIFIER, VERIFIER_SYS,
                      state_extract_prompt(final_text, state_track), max_tokens=800)
        if st and st.strip():
            state_track = st.strip()
            save_state_track(args.output, state_track)
            print(f"  [状态] 已更新跨章状态清单（{len(state_track.splitlines())} 行）")
        else:
            print(f"  [状态] 提取失败，保留旧状态")

        # 7.5) 伏笔台账提取：记录新埋伏笔/标记回收（失败保留旧台账，不阻断）
        fs = llm_call(VERIFIER, VERIFIER_SYS,
                      foreshadow_extract_prompt(final_text, foreshadow_ledger, idx),
                      max_tokens=600)
        parsed_fs = parse_json_from_llm(fs)
        if parsed_fs and parsed_fs.get("foreshadows"):
            foreshadow_ledger = json.dumps(parsed_fs, ensure_ascii=False)
            save_foreshadow(args.output, foreshadow_ledger)
            n_open = sum(1 for it in parsed_fs["foreshadows"] if it.get("status") == "open")
            n_closed = sum(1 for it in parsed_fs["foreshadows"] if it.get("status") == "closed")
            print(f"  [伏笔] 台账已更新（open {n_open} / closed {n_closed}）")
        else:
            print(f"  [伏笔] 提取失败，保留旧台账")

        # 7.6) 每 5 章检查超时未收伏笔（防长篇丢伏笔/改设定）
        if idx % 5 == 0:
            fs_warns = check_open_foreshadows(foreshadow_ledger, idx, stale_after=5)
            if fs_warns:
                print("  [伏笔] 超时未收告警：")
                for w in fs_warns:
                    print(f"    {w}")
            else:
                print(f"  [伏笔] 无超时未收伏笔 ✅")

        print(f"  [完成] 第 {idx} 章：{chapter_record['words']} 字 | 累计 {total_words} 字")

    # ===== Phase 3：质检汇总 =====
    print(f"\n{'=' * 60}\n[QA] 本地规则质检（AI味密度/重复率/节奏/世界观冲突）\n{'=' * 60}")
    report = quality_check(state["chapters"])
    total_conflicts = 0
    for ch in state["chapters"]:
        conflicts = ch.get("_world_conflicts", [])
        total_conflicts += len(conflicts)
        flag = "⚠" if conflicts else "✓"
        hook_flag = "🪝" if ch.get("_has_hook") else "✗无钩"
        open_flag = "⚡" if ch.get("_has_quick_opening", True) else "✗开场慢"
        print(f"  {flag} 第 {ch['idx']} 章：{ch.get('_words',0)} 字｜AI味 {ch.get('_ai_echo_pct',0)}%｜{hook_flag}｜{open_flag}")
    print(f"  世界观冲突：{total_conflicts} 处 | 审校问题：{sum(len(c.get('issues',[])) for c in state['chapters'])} 处")

    # ===== Phase 4：导出 =====
    txt_path = export_txt(args.output, outline.get("title", "未命名"), state["chapters"])
    print(f"\n[OK] 文本输出：{txt_path}")
    print(f"[OK] 总字数：{sum(c.get('words', 0) for c in state['chapters'])}")

    # ===== Phase 5：番茄评估卡 + 上架包 =====
    if not args.no_fanqie_pack:
        base = args.output.rsplit(".", 1)[0]
        card = os.path.join(os.path.dirname(os.path.abspath(args.output)),
                            os.path.basename(base) + ".评估卡.txt")
        with open(card, "w", encoding="utf-8") as f:
            f.write(f"《{outline.get('title', '')}》 番茄过审评估卡\n")
            f.write(f"题材：{args.genre}｜章节：{len(reviews)}｜评审均分："
                    f"{round(sum(r['score'] for r in reviews) / max(len(reviews), 1), 1)}\n\n")
            for r in reviews:
                f.write(f"第 {r['idx']} 章  {r['score']} 分  {r['verdict']}｜{r['words']} 字\n")
                for pr in r["problems"]:
                    f.write(f"    [{pr['action']}] {pr['type']}：{pr['msg']}\n")
                for h in r["redline"]["veto"]:
                    f.write(f"    ☠ 红线（{h['category']}）「{h['word']}」 上下文：{h['context']}\n")
        print(f"[OK] 评估卡：{card}")

        first3 = "\n\n".join(c.get("content", "")[:900] for c in state["chapters"][:3])
        pack_raw = llm_call(PLANNER, PLANNER_SYS, pack_prompt(outline, first3), max_tokens=1500)
        pack = parse_json_from_llm(pack_raw) or {}
        if pack:
            pack_path = os.path.join(os.path.dirname(os.path.abspath(args.output)),
                                     os.path.basename(base) + ".上架包.txt")
            with open(pack_path, "w", encoding="utf-8") as f:
                f.write(json.dumps(pack, ensure_ascii=False, indent=2))
            print(f"[OK] 上架包（书名/简介/标签）：{pack_path}")
        else:
            print("[WARN] 上架包生成失败（不影响正文）")


if __name__ == "__main__":
    main()
