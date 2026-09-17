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
                            has_ending_hook, SYSTEM_PROMPT,
                            thrill_per_thousand, surge_per_thousand)  # noqa: E402
from fanqie_review import (review_chapter, fix_prompt, patch_gate, local_hook_fallback,
                           extract_world_terms, dedup_intra_repeat)  # noqa: E402
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

# 角色配置（2026-09-12 两轮大 token 探针实测后优化——8 角色协作矩阵 v2）：
# 可用性矩阵（2026-09-12 实测）：
#   商汤 glm-5.2: K1✅K2✅K3✅（三件套 temp=1.0+大token+enable_thinking=False；长场景 prompt 有思考死循环风险）
#   商汤 deepseek-v4-pro: K1✅K2✅K3✅（思考链重 2000-2900 token，max_tokens≥6000 否则正文必空）
#   商汤 kimi-k3: K2✅（K1/K3 上轮 429）；硬约束 temperature 仅允许 1（llm_call 已加守卫）
#   商汤 deepseek-v4-flash: K1✅K2✅K3✅【本轮复活，上轮 401】（3-4s 快，思维链轻但也会吃 400+ token，需 max_tokens≥1500）
#   AMD DeepSeek-V4-Flash: ✅（约 30s 偏慢，高峰限流，作末备）
#   NVIDIA deepseek-v4-flash-0731: ✅（3.1s，新增容量；kimi/pro 在 NV 超时不可用）
#   NVIDIA z-ai/glm-5.2: 410 EOL 确认死亡（2026-08-21 下架，勿再尝试）
#   OpenRouter: 账户 0 余额（402），stealth/ox-alpha 内测期结束→变身 z-ai/glm-5.3-flash；
#               充值后可解锁 glm-5.3 / glm-5.3-flash / deepseek-v4.1-flash / kimi-k3，届时优先升级写手与规划官
#   sensenova-6.8-flash-lite: 持续弃用（空输出/不支持 system/传 temperature 即空）
# 角色分配 v2（核心思路：写手主位换 dsf-flash 消除 glm 长场景死循环；轻任务角色换 dsf-flash；
#             重推理角色保 pro 但修 max_tokens；每条链至少跨 2 个独立端点）：
#   规划官：glm-5.2 K1→K2→K3（JSON 结构化最稳）→ AMD（稳定 30s）→ NVIDIA dsf-flash（300s 超时风险，末位——链序原则，2026-09-12 真书验证 glm 全灭时曾卡 NV 超时）
#   写手：商汤 dsf-v4-flash K1 主【3-4s，思维链轻，根治 glm 场景死循环】→ glm-5.2 K1（大token）
#         → NVIDIA dsf-flash-0731 → AMD 末备（跨 3 端点 2 模型家族，防同质化）
#   编辑：kimi-k3 K2 主（temp=1 硬约束由 llm_call 守卫保证）→ glm-5.2 K3 备 → AMD 兜底
#   标题官：商汤 dsf-v4-flash K1 主（快）→ 失败回退章纲标题（现有后置防护）
#   审校：deepseek-v4-pro K1 主（max_tokens≥6000）→ glm-5.2 K3 备（VERIFIER_CHAIN）
#   状态提取官：商汤 dsf-v4-flash K3【轻任务换轻模型，修 pro+800 静默空输出 bug】
#   伏笔官：商汤 dsf-v4-flash K2 主（修 glm 小 token 思考吃满隐患）
#   世界观守护官：deepseek-v4-pro K2（max_tokens 6000，每 5 章低频调用可承受 pro 时延）
#   爽点总监：商汤 dsf-v4-flash K2（30 字短答，修 pro+200 必空 bug）
#   终审官（第 10 角色，2026-09-12 补设）：deepseek-v4-pro K2 → glm-5.2 K1。
#         全书收官后唯一一次通读级总评——此前终局把关只有本地规则评分（签约可行性报告），
#         节奏曲线/人物弧光/伏笔回收质量/结局力度这类需通读才能判断的维度长期无人把守。
#         输入为全书结构化摘要（逐章指标 + 状态清单 + 伏笔台账 + 首末章与最低分章样本正文），
#         输出 JSON 终审报告（总分/六维/问题清单/修改优先级/签约建议）。
#   大纲终审官（第 11 角色，2026-09-12 补设，写前守门）：deepseek-v4-pro K2 → glm-5.2 K1。
#         规划官出大纲后、第 1 章动笔前对大纲做结构级评审——伏笔分布（单章 ≤2 条）、
#         末章必须有结局（禁"前夕态"收尾）、单章信息密度、钩子链完整性。
#         终审官《断脉逆命诀》二审实测证明：结构级问题（第 1 章 6 条伏笔全悬、末章停"大典前夕"）
#         单章重写治不了，必须在写之前拦住。大纲是全书唯一低频高价值产物，守门用最强 pro。
PLANNER = dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=8000)
PLANNER_CHAIN = [
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=8000),           # K1 主
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=8000),           # K2 备
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=8000),           # K3 备
    dict(url=AMD, model="DeepSeek-V4-Flash", key="", temp=0.8, max_tokens=4000),   # AMD 备（稳定 30s，链序原则排 NV 前）
    dict(url=NVIDIA, model="deepseek-ai/deepseek-v4-flash-0731", key="", temp=0.8, max_tokens=4000),  # NV 末备（300s 超时风险）
]
WRITER_CHAIN = [
    dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=6000),  # K1 dsf 主（快，思维链轻）
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=8000),            # K2 glm 备（三件套）
    dict(url=AMD, model="DeepSeek-V4-Flash", key="", temp=0.8, max_tokens=6000),    # AMD（稳定 30s，思考死循环免疫，排 NV 前）
    dict(url=NVIDIA, model="deepseek-ai/deepseek-v4-flash-0731", key="", temp=0.8, max_tokens=6000),  # NV 末备（有 300s 超时风险）
]
EDITOR_CHAIN = [
    dict(url=SENSE, model="kimi-k3", key="", temp=1.0, max_tokens=4000),           # K2 kimi 主（temp=1 硬约束）
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=8000),           # K3 glm 备
    dict(url=AMD, model="DeepSeek-V4-Flash", key="", temp=0.8, max_tokens=6000),   # AMD 兜底
]
TITLER = dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=800)  # K1 dsf 主（3-4s）
# 审校改为故障转移链：pro 主（深推理无死循环风险）→ glm K3 备
VERIFIER_CHAIN = [
    dict(url=SENSE, model="deepseek-v4-pro", key="", temp=0.8, max_tokens=8000),   # K1 pro 主
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=8000),           # K3 glm 备
]
STATE_EXTRACTOR = dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=2000)  # K3 轻任务
# 读者官（第 12 角色，2026-09-12 补设）：每章末尾以「追读读者」视角读完本章，
# 回答三问（追不追/哪里想弃/下一章想看什么），反馈注入下一章场景规划——
# 此前 12 角色全是生产侧，没有消费侧视角，「第 5 章 100 分却无钩子」正是生产侧自嗨的产物。
READER_PROXY = dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=500)  # K3 轻任务
# 新增角色（8 角色协作 v2）
FORESHADOWER = dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=4000)  # K2 轻任务（台账 JSON 含 6 条长 desc，2000 曾被思考链+输出吃满截断）
WORLD_GUARDIAN = dict(url=SENSE, model="deepseek-v4-pro", key="", temp=0.8, max_tokens=6000)  # K2 pro（一致性校验需深推理）
THRILL_DIRECTOR = dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=1000)  # K2 dsf（30 字短答）
# 终审官（全书收官总评，唯一通读级 LLM 角色）：pro 深推理 → glm K1 备
CHIEF_EDITOR_CHAIN = [
    dict(url=SENSE, model="deepseek-v4-pro", key="", temp=0.8, max_tokens=8000),   # K2 pro 主
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=8000),           # K1 glm 备（三件套）
]
# 大纲终审官（第 11 角色，写前守门）：规划官出大纲后、第 1 章动笔前跑一次。
# 低频高价值任务用最强 pro 守最重要的产物（大纲）；pro 挂 → glm-5.2 K1 备。
# max_tokens 8000：pro 思考链 2000-2900 + 修订版大纲全量 JSON（40 章约 4000-5000 token）。
OUTLINE_REVIEWER_CHAIN = [
    dict(url=SENSE, model="deepseek-v4-pro", key="", temp=0.8, max_tokens=12000),  # K2 pro 主（12000：真书实测思考链+修订版大纲全量 JSON 曾吃满 8000 致截断）
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=12000),          # K1 glm 备（三件套）
]


def setup_keys():
    PLANNER["key"] = _key("NOVEL_KEY_SENSE_K1")
    # 规划官：glm K1→K2→K3 → AMD（稳定 30s）→ NVIDIA（300s 超时风险，末位——链序原则）
    PLANNER_CHAIN[0]["key"] = _key("NOVEL_KEY_SENSE_K1")
    PLANNER_CHAIN[1]["key"] = _key("NOVEL_KEY_SENSE_K2")
    PLANNER_CHAIN[2]["key"] = _key("NOVEL_KEY_SENSE_K3")
    PLANNER_CHAIN[3]["key"] = _key("NOVEL_KEY_AMD")
    PLANNER_CHAIN[4]["key"] = _key("NOVEL_KEY_NVIDIA")
    # 写手：商汤 dsf-flash K1 → glm K1 → AMD → NVIDIA
    WRITER_CHAIN[0]["key"] = _key("NOVEL_KEY_SENSE_K1")
    WRITER_CHAIN[1]["key"] = _key("NOVEL_KEY_SENSE_K1")
    WRITER_CHAIN[2]["key"] = _key("NOVEL_KEY_AMD")
    WRITER_CHAIN[3]["key"] = _key("NOVEL_KEY_NVIDIA")
    # 编辑：kimi K2 → glm K3 → AMD
    EDITOR_CHAIN[0]["key"] = _key("NOVEL_KEY_SENSE_K2")
    EDITOR_CHAIN[1]["key"] = _key("NOVEL_KEY_SENSE_K3")
    EDITOR_CHAIN[2]["key"] = _key("NOVEL_KEY_AMD")
    # 标题官：商汤 dsf-flash K1
    TITLER["key"] = _key("NOVEL_KEY_SENSE_K1")
    # 审校链：pro K1 主 → glm K3 备
    VERIFIER_CHAIN[0]["key"] = _key("NOVEL_KEY_SENSE_K1")
    VERIFIER_CHAIN[1]["key"] = _key("NOVEL_KEY_SENSE_K3")
    # 状态提取官：商汤 dsf-flash K3
    STATE_EXTRACTOR["key"] = _key("NOVEL_KEY_SENSE_K3")
    # 读者官：商汤 dsf-flash K3（轻任务，与状态提取官同 key 分摊）
    READER_PROXY["key"] = _key("NOVEL_KEY_SENSE_K3")
    # 伏笔官：商汤 dsf-flash K2
    FORESHADOWER["key"] = _key("NOVEL_KEY_SENSE_K2")
    # 世界观守护官：pro K2；爽点总监：dsf-flash K2
    WORLD_GUARDIAN["key"] = _key("NOVEL_KEY_SENSE_K2")
    THRILL_DIRECTOR["key"] = _key("NOVEL_KEY_SENSE_K2")
    # 终审官：pro K2 主 → glm K1 备
    CHIEF_EDITOR_CHAIN[0]["key"] = _key("NOVEL_KEY_SENSE_K2")
    CHIEF_EDITOR_CHAIN[1]["key"] = _key("NOVEL_KEY_SENSE_K1")
    # 大纲终审官：pro K2 主 → glm K1 备（与终审官同链型，低频高价值岗位）
    OUTLINE_REVIEWER_CHAIN[0]["key"] = _key("NOVEL_KEY_SENSE_K2")
    OUTLINE_REVIEWER_CHAIN[1]["key"] = _key("NOVEL_KEY_SENSE_K1")


# ============================================================
# 非流式调用（Sensenova 系模型流式格式不统一，统一非流式最稳）
# ============================================================
# 健康 key 池（2026-09-10 配额感知路由）：记录每个 provider 的连续失败/冷却状态。
# 冷却中的 provider 会被跳过，避免单 key 配额耗尽后反复撞 429 浪费时间；
# 冷却期满自动恢复，运行中持续自愈。
_HEALTH = {}  # key: {fails: 连续失败数, cooldown_until: 时间戳, hits: 成功数}
COOLDOWN_SECONDS = 300  # 连续失败 N 次后冷却 5 分钟

# 编辑类产出采纳下限（2026-09-13 fulltest 实测：编辑链曾把 3805 字章润色成 1921 字
# 砍半后被无条件采纳，违反"字数只多不少"约定）。润色/定点修/重写类采纳统一要求
# ≥ 原文 85%，不达标视为无效产出、保留原文并告警。Dart 端 lib/ai_pipeline/ 同步待办。
EDITOR_MIN_RATIO = 0.85


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
    # kimi-k3 硬约束（2026-09-12 探针实测）：temperature 仅允许 1，传其他值直接 HTTP 400。
    # 无论调用方传什么，kimi 一律强制 1，防止角色复用时踩雷。
    if "kimi" in provider.get("model", "").lower():
        temperature = 1.0
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
                msg = d.get("choices", [{}])[0].get("message", {})
                content = msg.get("content", "") or ""
                # 诊断：deepseek-v4-pro 等推理模型 thinking 关不掉时，
                # token 全烧在 reasoning_content，正文为空（finish=length）。
                if not content.strip() and (msg.get("reasoning_content") or "").strip():
                    print(f"    [diag] {provider['model']} 思考链有输出但正文为空"
                          f"（thinking 吃满 max_tokens={provider.get('max_tokens')}），建议加大 max_tokens")
                    # 思考死循环计入健康池：连续 3 次后冷却 5 分钟，
                    # 让 call_chain 自动跳过该端点直奔可用备选（2026-09-12 冒烟实测补丁）
                    _mark_fail(provider)
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
TITLER_SYS = "你是一位网文章名提炼师，擅长从章节内容提炼短而带悬念的章名，只输出章名本身。"
VERIFIER_SYS = "你是一位严谨的长篇小说一致性审校编辑。"
OUTLINE_REVIEWER_SYS = "你是番茄/起点资深内容主编，在大纲阶段就为签约稿把关。只输出严格 JSON。"


# ============================================================
# 补丁卫生：补写/扩写/定点修的产出在拼回正文前必须过闸
# 实测事故（同一本 3 章小样里同时发生）：
#   ① 钩子补写返回「我拿到的指令是补写钩子，不是扩写…」被原样拼进第 1 章末尾；
#   ② 另一章补出「手机屏幕亮了。不是短信。」，把玄幻书写成都市悬疑；
#   ③ 第 3 章开头 800 字整块重复两遍（复制粘贴级）。
# 三道防线：patch_gate（指令残留/题材漂移/红线/与正文重复）+ 章纲钩子本地兜底 + 章内去重。
# ============================================================
HOOK_FALLBACK_SIGNALS = ("还没", "突然", "竟然", "不对劲", "盯着", "动静", "浮现", "逼近", "异动")


def extract_chapter_hook(ch):
    """从章纲里取钩子原文（兜底时唯一可信的「题材内素材」）。

    规划官把钩子写在 goal 里（`…｜钩子=威胁逼近：血煞盟的人影一闪而逝`），
    结构补章的章纲则可能带独立 hook 字段。"""
    if not isinstance(ch, dict):
        return ""
    m = re.search(r"钩子[=＝:：]\s*([^｜|]+)", ch.get("goal", "") or "")
    if m:
        return m.group(1).strip()
    return (ch.get("hook") or "").strip()


def apply_hook_patch(final_text, hook_hint, protagonist, genre, tag=""):
    """章末钩子兜底（带补丁卫生）：LLM 补写 → 过闸 → 不过就用章纲钩子本地兜底。

    返回 (新正文, 来源)，来源 ∈ {"llm", "local", ""}。
    """
    add = call_chain(
        WRITER_CHAIN, SYSTEM_PROMPT,
        "下面是本章结尾，最后 1~2 句太平淡，没有留下让读者必须看下一章的悬念。"
        f"请接着补写 30~80 字的钩子句（悬念/变故/威胁逼近/秘密将揭，按{genre}题材），"
        "不新增情节、不改变已发生的事，只把结尾收在悬念上。"
        "只输出补写内容本身，不要任何解释、说明或字数报告：\n\n" + final_text[-300:],
        max_tokens=300)
    ok, why = patch_gate(add, base_text=final_text, genre=genre, max_words=160)
    if ok:
        print(f"  [钩子{tag}] 已补写钩子：{add.strip()[:40]}...")
        return final_text.rstrip() + "\n\n" + add.strip(), "llm"
    print(f"  [钩子{tag}] LLM 补写被拒（{why}）→ 改用章纲钩子本地兜底")
    fb = local_hook_fallback(hook_hint, protagonist, genre)
    if fb:
        if not any(s in fb for s in HOOK_FALLBACK_SIGNALS):
            fb = fb.rstrip("。") + "——他还没看清那是什么。"
        print(f"  [钩子{tag}] 本地兜底：{fb[:40]}")
        return final_text.rstrip() + "\n\n" + fb, "local"
    print(f"  [钩子{tag}] 无可用兜底素材，保留原文")
    return final_text, ""


def apply_text_patch(final_text, patch, genre, min_ratio=EDITOR_MIN_RATIO, tag="补丁"):
    """整章级补丁（扩写/定点修/打勾补写）的通用采纳判定：字数下限 + 补丁卫生。

    与旧实现相比多了一道 patch_gate：字数够但跑题/带操作说明的产出不再被采纳
    （旧实现只看字数比例，实测放进了「手机屏幕亮了」这种跨题材文本）。
    """
    if not patch or not patch.strip():
        print(f"  [{tag}] 无有效产出，保留原文")
        return final_text
    p = patch.strip()
    if count_words(p) < count_words(final_text) * min_ratio:
        print(f"  [{tag}] 过度压缩（{count_words(final_text)} -> {count_words(p)} 字，"
              f"低于 {int(min_ratio * 100)}%），拒绝采纳保留原文")
        return final_text
    ok, why = patch_gate(p, genre=genre, max_words=10 ** 9)
    if not ok:
        print(f"  [{tag}] 补丁被拒（{why}），保留原文")
        return final_text
    return p


def dedup_chapter(final_text, idx):
    """章内重复段自动去重（复制粘贴级事故：同一章 800 字整块出现两遍）。"""
    if not final_text:
        return final_text
    clean, removed = dedup_intra_repeat(final_text)
    if removed:
        print(f"  [去重] 第 {idx} 章删掉 {removed} 字章内重复段")
    return clean


def needs_fix(rv, review_pass):
    """是否需要定点修：不达线，或带阻断级硬伤（分数达线也不能放过）。

    实测事故：第 1 章 92 分但含「元话语残留/字数不足」→ 旧条件只看分数，修复链直接跳过。
    """
    return bool(rv.get("problems")) and (rv.get("score", 0) < review_pass
                                         or bool(rv.get("blockers")))



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


def quality_review_prompt(text, qa_evidence=""):
    """语义级五维评分（开篇/爽点/钩子/动机/节奏），输出 JSON。

    qa_evidence：本地质检证据（钩子有无/爽点密度/AI 味），注入后 LLM 评审带证据打分，
    避免与本地检测互相矛盾（终审官实测抓到「评审 100 分但钩子无」的分裂案例）。"""
    ev = ""
    if qa_evidence:
        ev = f"\n【本地质检证据（规则引擎实测，评分时必须与之对照，不得与证据矛盾）】\n{qa_evidence}\n"
    return f"""请以网文编辑的眼光为下面的章节打分（每项 0~100）：
1. opening：开篇是否快速进入事件、有代入感（黄金三章标准）
2. thrill：爽点密度与强度（打脸/升级/收获/秘密揭露；含蓄变强具象化也算）
3. hook：章末钩子是否让人想看下一章（悬念/变故/威胁）
4. motivation：人物动机是否清晰、行为是否合理
5. rhythm：节奏是否张弛有度、无注水、无流水账
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


def load_reader_feedback(path):
    """续传恢复：取最后一条 type=reader_feedback 记录的反馈文本（无则空串）。"""
    if not os.path.exists(path):
        return ""
    fb = ""
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "reader_feedback":
                d = rec.get("data", {})
                if isinstance(d, dict):
                    fb = str(d.get("feedback", ""))
    return fb


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
   - idx 从 {last_idx + 1} 顺延；title 不超过 8 字；goal 60~120 字写清事件+回收哪些伏笔+章末钩子
2. 若判定现有章节已能自洽收尾、加章反而注水：输出空数组，并给出一句话理由。
3. 严格沿用已有世界观、人物与设定，不得新增主角、不改已有设定。
4. 只输出 JSON（不要 Markdown 代码块）：
{{"new_chapters": [{{"idx": {last_idx + 1}, "title": "不超过8字", "goal": "60~120字", "hook": "章末钩子一句话"}}], "reason": "一句话理由"}}"""


def generate_appended_chapter(ch, ctx):
    """结构打回：为终审官增补的收尾章跑生成流水线。

    与 Phase 2 章节循环同一套角色链（规划官场景规划 → 写手 → 编辑 → 标题官 →
    番茄评审门 → 状态提取官 → 伏笔官），收尾章跳过黄金三章首屏强化（非前三章）。
    ctx 键：args(.genre/.output/.review_pass)、outline、state、reviews（就地更新）、
            trackers{total_words/last_summary/state_track/foreshadow_ledger}（就地更新）、
            protagonist、world_str、review_world_terms。
    返回 chapter_record 或 None（空章节保护）。"""
    args = ctx["args"]
    idx = ch["idx"]
    chapter_title = ch.get("title", f"第{idx}章")
    goal = ch.get("goal", "")
    target = ch.get("target", 3000)
    trackers = ctx["trackers"]
    state = ctx["state"]
    print(f"\n{'=' * 60}\n[CH {idx}·结构补章] {chapter_title}（目标 {target} 字）\n  章纲：{goal}\n{'=' * 60}")

    # 未收伏笔 + 跨章状态注入（收尾章的核心使命就是收伏笔）
    # 「必兑现清单」是硬约束版：答案必须落纸面，不得只暗示（治指令执行衰减）
    promise_block = build_promise_block(trackers["foreshadow_ledger"])
    if promise_block:
        state_inject = (trackers["state_track"] + "\n\n" + promise_block) if trackers["state_track"] else promise_block
        write_state = state_inject
        print(f"  [承诺] 必兑现清单 {promise_block.count(chr(10))} 条注入场景规划与写手")
    else:
        state_inject = trackers["state_track"]
        write_state = trackers["state_track"]

    world_hint = json.dumps(ctx["outline"].get("world", {}), ensure_ascii=False) if isinstance(ctx["outline"], dict) else ""
    plan = None
    for attempt in range(2):
        raw = call_chain(PLANNER_CHAIN, PLANNER_SYS,
                         scene_planning_prompt(goal, trackers["last_summary"], state_inject,
                                               protagonist=ctx["protagonist"], genre=args.genre,
                                               world_hint=world_hint),
                         max_tokens=2000)
        plan = parse_json_from_llm(raw)
        if plan and plan.get("scenes"):
            break
    if not plan or not plan.get("scenes"):
        print("  [规划] 场景规划失败，使用默认「起承转合」骨架兜底")
        plan = {"scenes": [
            {"index": 0, "stage": "起", "goal": f"承接前文：{goal[:30]}", "beats": [], "targetWords": max(400, int(target * 0.3))},
            {"index": 1, "stage": "承", "goal": "推进收束事件", "beats": [], "targetWords": max(400, int(target * 0.25))},
            {"index": 2, "stage": "转", "goal": "回收伏笔/摊牌/交代主线", "beats": [], "targetWords": max(400, int(target * 0.25))},
            {"index": 3, "stage": "合", "goal": "收束并留续作余韵", "beats": [], "targetWords": max(400, int(target * 0.2))},
        ]}
    scenes = plan["scenes"]
    print(f"  [规划] {len(scenes)} 场景：{'/'.join(s.get('stage', '承') for s in scenes)}")

    scene_texts = []
    prev_text = trackers["last_summary"]
    for si, sc in enumerate(scenes):
        stage = sc.get("stage", "承")
        goal_s = sc.get("goal", "")
        # 外显爽点硬约束：规划层写了打脸/当众类目标时，强制写手写出外部可见反应
        # （治执行衰减：fulltest 第5章规划"当众打脸"但💥词表命中 0.00，写手写成了内心戏）
        if any(k in goal_s for k in ("外显爽点", "打脸", "当众")):
            goal_s += ("【本场景硬约束】这是外显爽点场景：必须写出对手/旁观者的当众外部反应"
                       "（脸色骤变、失态、惊呼、修为显化、围观哗然），禁止只写主角内心感受或含蓄暗示。")
        beats = sc.get("beats", [])
        tw = sc.get("targetWords", 600)
        print(f"  [场景 {si + 1}/{len(scenes)}] {stage}：{goal_s}（目标 {tw} 字）")
        text = ""
        for sretry in range(3):
            text = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                              scene_prompt(si + 1, len(scenes), stage, goal_s, beats, prev_text,
                                           args.genre, write_state,
                                           protagonist=ctx["protagonist"], world=ctx["world_str"],
                                           hook=hook_for(idx) if si + 1 == len(scenes) else "",
                                           is_opening=False),
                              max_tokens=int(tw * 3.0))
            if text.strip():
                break
            if sretry < 2:
                print(f"    [重试 {sretry + 1}/3] 场景空输出，10s 后再试")
                time.sleep(10)
        text = text.strip()
        # 场景衔接去重：裁掉与上一场景结尾重复的开头
        if text and scene_texts:
            tail = scene_texts[-1][-150:]
            for k in range(min(len(text), 150), 20, -10):
                if tail.endswith(text[:k]):
                    print(f"  [去重] 场景衔接重叠 {k} 字，已裁剪")
                    text = text[k:]
                    break
        if text:
            scene_texts.append(text)
            prev_text = text[-200:] if len(text) > 200 else text

    final_text = "\n\n".join(scene_texts).strip()
    if not final_text or count_words(final_text) < 200:
        print("  [SKIP] 收尾章产出为空/过短（空章节保护），留待重试")
        return None

    w = count_words(final_text)
    if w < target * 0.75:
        print(f"  [扩写] {w} 字低于目标，扩写…")
        add = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                         f"以下章节正文偏短，请在保持情节、伏笔回收与章末钩子的前提下扩写至 {target} 字左右，只输出完整正文：\n\n{final_text}",
                         max_tokens=int(target * 2.0) + 800)
        new_text = apply_text_patch(final_text, add, args.genre, min_ratio=1.0, tag="扩写")
        if new_text != final_text:
            final_text = new_text
            w = count_words(final_text)

    edited = call_chain(EDITOR_CHAIN, EDITOR_SYS,
                        editor_prompt(final_text), max_tokens=int(w * 2.0) + 800)
    edited = apply_text_patch(final_text, edited, args.genre, tag="润色")
    if edited != final_text:
        final_text = edited
        w = count_words(final_text)

    # 章末钩子兜底（带补丁卫生 + 章纲钩子本地兜底）
    if not has_ending_hook(final_text):
        final_text, _src = apply_hook_patch(
            final_text, extract_chapter_hook(ch), ctx["protagonist"], args.genre)

    # 末尾完整性检查 + 自动补全（与主循环同款，结构补章此前缺这道防线）
    final_text, _repaired = ensure_complete_ending(final_text, args.genre)

    # 回收清单打勾：必兑现清单逐条校验 → 未兑现定向补写（最多 1 轮）
    promise_results = []
    if promise_block:
        final_text, promise_results = verify_and_repair_promises(
            final_text, promise_block, idx, args.genre)
        # 打勾 ✅ 直接联动台账 closed（证据句作回收凭证），不再依赖伏笔官二次提取
        if promise_results and not any(r.get("id") == "verify" for r in promise_results):
            new_ledger, n_closed = apply_promise_closures(
                trackers["foreshadow_ledger"], promise_results, idx)
            if n_closed:
                trackers["foreshadow_ledger"] = new_ledger
                save_foreshadow(args.output, trackers["foreshadow_ledger"])
                print(f"  [台账] 打勾联动：{n_closed} 条伏笔已标记回收（closed）")

    # 标题官
    t = llm_call(TITLER, TITLER_SYS, titler_prompt(final_text))
    raw_title = (t.strip() or chapter_title).strip(" \"「」『』《》")
    title_ok = raw_title if (len(raw_title) <= 10 and not any(c in raw_title for c in "，。！？、；：,，\"'")) else chapter_title
    print(f"  [标题] {title_ok}")

    # 番茄评审门（收尾章同样要达线；不达标一轮定点修）
    rv = review_chapter(final_text, trackers["last_summary"], idx, args.genre,
                        ctx["protagonist"], ctx["review_world_terms"])
    if needs_fix(rv, args.review_pass):
        fp = fix_prompt(rv, final_text)
        if fp.strip():
            print(f"  [评审] {rv['score']} 分，定点修…")
            fixed = call_chain(EDITOR_CHAIN, SYSTEM_PROMPT, fp,
                               max_tokens=int(count_words(final_text) * 2.2) + 800)
            fixed = apply_text_patch(final_text, fixed, args.genre, tag="评审修")
            if fixed != final_text:
                rv2 = review_chapter(fixed, trackers["last_summary"], idx, args.genre,
                                     ctx["protagonist"], ctx["review_world_terms"])
                if rv2["score"] >= rv["score"] and \
                        len(rv2.get("blockers") or []) <= len(rv.get("blockers") or []):
                    final_text, rv = fixed, rv2
                    print(f"  [评审] 修后 {rv2['score']} 分")
                else:
                    print(f"  [评审] 修后 {rv2['score']} 分（未改善/新增阻断项），丢弃")
    print(f"  [评审] {rv['score']} 分")

    rv["words"] = count_words(final_text)
    ctx["reviews"].append(rv)

    final_text = dedup_chapter(final_text, idx)
    record = {"idx": idx, "title": title_ok, "content": final_text,
              "words": count_words(final_text), "raw_words": w,
              "scenes": len(scenes), "issues": [], "chief_structural": True}
    if promise_results:
        n_ok = sum(1 for r in promise_results if r.get("fulfilled"))
        record["issues"].append({"type": "promise_check",
                                 "desc": f"必兑现清单 {n_ok}/{len(promise_results)} 条伏笔兑现"})
        append_state(args.output, "promise_check",
                     {"idx": idx, "results": promise_results, "promise_block": promise_block})
    state["chapters"].append(record)
    append_state(args.output, "chapter", record)
    trackers["total_words"] += record["words"]
    trackers["last_summary"] = final_text[-200:] if len(final_text) > 200 else final_text

    # 状态提取官 + 伏笔官（收尾章回收伏笔后台账必须更新）
    st = llm_call(STATE_EXTRACTOR, VERIFIER_SYS,
                  state_extract_prompt(final_text, trackers["state_track"]), max_tokens=2000)
    if st and st.strip():
        trackers["state_track"] = st.strip()
        save_state_track(args.output, trackers["state_track"])
        print("  [状态] 已更新跨章状态清单")
    fs = llm_call(FORESHADOWER, "你是一位长篇小说伏笔管理员。",
                  foreshadow_extract_prompt(final_text, trackers["foreshadow_ledger"], idx),
                  max_tokens=4000)
    parsed_fs = parse_json_from_llm(fs)
    if parsed_fs and parsed_fs.get("foreshadows"):
        trackers["foreshadow_ledger"] = json.dumps(parsed_fs, ensure_ascii=False)
        save_foreshadow(args.output, trackers["foreshadow_ledger"])
        n_open = sum(1 for it in parsed_fs["foreshadows"] if it.get("status") == "open")
        n_closed = sum(1 for it in parsed_fs["foreshadows"] if it.get("status") == "closed")
        print(f"  [伏笔] 台账已更新（open {n_open} / closed {n_closed}）")
    print(f"  [完成] 第 {idx} 章：{record['words']} 字 | 累计 {trackers['total_words']} 字")
    return record


def build_promise_block(ledger_json, max_promises=6, cur_idx=None, stale_after=None):
    """从伏笔台账提取 open 条目，构造成「本章必兑现清单」硬约束文本。

    治「指令执行衰减」：泛泛的"回收伏笔"会被写手衰减成任意剧情（真书验证中
    规划官下令回收伏笔，写手却写成了开脉突破悬念）。必须逐条给明确的落地
    要求——答案以对话/物证/内心揭示落到纸面，不得只暗示或留白。

    两种模式：
    - 收尾章（cur_idx/stale_after 不传）：取全部 open 前 max_promises 条
    - 普通章（传 cur_idx + stale_after）：只取「埋设超时未收」的条目
      （planted ≤ cur_idx - stale_after），每章最多 max_promises 条——
      普通章只在伏笔快烂时上硬约束，不背全部回收负担。"""
    items = []
    try:
        ledger = json.loads(ledger_json) if ledger_json else {}
        for it in ledger.get("foreshadows", []):
            if not (isinstance(it, dict) and it.get("status") == "open" and it.get("desc")):
                continue
            if cur_idx is not None and stale_after is not None:
                planted = it.get("planted", 0)
                try:
                    age = int(cur_idx) - int(planted)
                except (TypeError, ValueError):
                    continue
                if age < stale_after:
                    continue
            items.append(str(it["desc"])[:60])
    except Exception:
        pass
    items = items[:max_promises]
    if not items:
        return ""
    lines = ["【本章必兑现清单（硬约束：必须逐条写进正文，以对话/物证/内心揭示给出明确答案，不得只暗示或留白）】"]
    for i, d in enumerate(items, 1):
        lines.append(f"{i}. {d}——本章必须明确交代其答案（人物对话点破、实物证据呈现、内心揭示皆可，答案必须落到纸面）。")
    return "\n".join(lines)


def verify_promises_prompt(text, promise_lines, chapter_idx):
    return f"""你是伏笔回收验收员。下面是第 {chapter_idx} 章正文和「必兑现清单」，
请逐条核验正文是否真的兑现了清单要求（答案是否落到纸面；只暗示/留白/远景铺陈不算兑现）。

【必兑现清单】
{promise_lines}

【章节正文】
{text}

只输出 JSON（不要 Markdown 代码块）：
{{"results": [{{"id": 序号, "fulfilled": true或false, "evidence": "正文证据句，不超过20字（未兑现则填缺失原因，不超过20字）"}}]}}"""


def verify_and_repair_promises(final_text, promise_lines, chapter_idx, genre):
    """回收清单打勾校验 + 定向补写（最多 1 轮）。返回 (final_text, results)。

    校验用伏笔官（dsf-flash 轻任务）；补写用编辑链（只加不改、答案落纸面）。"""
    if not promise_lines:
        return final_text, []

    def _verify(text):
        # 校验走故障转移链（复用编辑链 kimi→glm→AMD）：单点 FORESHADOWER 在思考链
        # 风暴期会原地连败（实测 run8：dsf 4000 两次吃满），call_chain 让健康池自动换端点
        for attempt in range(2):
            raw = call_chain(EDITOR_CHAIN, "你是一位严谨的伏笔回收验收员，只输出 JSON。",
                             verify_promises_prompt(text, promise_lines, chapter_idx), max_tokens=4000)
            parsed = parse_json_from_llm(raw, repair=False) or parse_json_from_llm(raw, repair=True)
            results = (parsed or {}).get("results") or []
            if results:
                return results
            if attempt == 0:
                print("  [打勾] 校验输出为空/解析失败，重试一次…")
        print("  [打勾] ☠ 校验两次失败（限流/思考链吃满/解析失败），本次打勾未执行——请人工复核伏笔兑现")
        return [{"id": "verify", "fulfilled": False,
                 "evidence": "校验调用两次失败，打勾未执行（非正文问题，是验收环节失败）"}]

    results = _verify(final_text)
    # 校验环节失败：不触发补写（正文无问题），带失败标记返回供落盘告警
    if any(r.get("id") == "verify" for r in results):
        return final_text, results
    for r in results:
        mark = "✅" if r.get("fulfilled") else "❌"
        print(f"  [打勾] {mark} 清单{r.get('id', '?')}：{str(r.get('evidence', ''))[:50]}")
    unfulfilled = [r for r in results if not r.get("fulfilled")]
    if unfulfilled:
        print(f"  [打勾] {len(unfulfilled)} 条未兑现，编辑链定向补写（最多 1 轮）…")
        ul_lines = "\n".join(
            f"{r.get('id', '?')}. 必兑现条目（验收反馈：{str(r.get('evidence', ''))[:60]}）" for r in unfulfilled)
        fix = call_chain(
            EDITOR_CHAIN, EDITOR_SYS,
            f"""终审要求本章兑现以下条目，但验收发现未兑现。请在不动其他情节、不改已发生事件的前提下，
把这些条目的答案自然补进正文（人物对话点破/物证呈现/内心揭示皆可），答案必须落到纸面，不得只暗示。
只输出修改后的完整正文，字数只多不少。

{ul_lines}

【当前正文】
{final_text}""",
            max_tokens=int(count_words(final_text) * 1.6) + 800)
        new_text = apply_text_patch(final_text, fix, genre, tag="打勾")
        if new_text != final_text:
            final_text = new_text
            results2 = _verify(final_text)
            for r in results2:
                mark = "✅" if r.get("fulfilled") else "❌"
                print(f"  [打勾·复验] {mark} 清单{r.get('id', '?')}：{str(r.get('evidence', ''))[:50]}")
            results = results2 or results
        else:
            print("  [打勾] 保留原文，未兑现项交终审兜底")
    return final_text, results


def verdict_from_score(overall):
    """按分数区间本地判档。终审评分跨轮方差大（实测同书 83/68/64/71/64），
    verdict 改由分数区间决定——同分必同档，模型判词降级为参考。"""
    try:
        s = float(overall)
    except (TypeError, ValueError):
        return ""
    if s >= 80:
        return "高潜可投"
    if s >= 70:
        return "可投"
    if s >= 60:
        return "需打磨"
    return "不建议"


def _merge_chief_samples(samples):
    """终审多采样合并：overall 与六维各取中位数（偶数取均值四舍五入），
    top_issues/fix_priority/对标以首个成功采样为准（跨采样合并去重易引入噪声）。
    治「评分方差」：实测同书单轮 83/68/64/71/64 波动，双采样中位可显著收敛。"""
    ok = [s for s in samples if s and s.get("overall") is not None]
    if not ok:
        return None

    def median(vals):
        vals = sorted(float(v) for v in vals if v is not None)
        if not vals:
            return None
        n = len(vals)
        m = vals[n // 2] if n % 2 else (vals[n // 2 - 1] + vals[n // 2]) / 2
        return int(round(m))

    merged = dict(ok[0])
    merged["overall"] = median([s.get("overall") for s in ok])
    dim_keys = set()
    for s in ok:
        dim_keys.update((s.get("dimensions") or {}).keys())
    dims = {}
    for k in dim_keys:
        vals = [(s.get("dimensions") or {}).get(k) for s in ok]
        vals = [v for v in vals if v is not None]
        if vals:
            dims[k] = median(vals)
    merged["dimensions"] = dims
    # 模型判词降级为参考，verdict 由分数区间决定（同分同档）
    merged["model_verdict"] = ok[0].get("verdict", "")
    merged["verdict"] = verdict_from_score(merged["overall"])
    merged["samples"] = len(ok)
    return merged


def apply_promise_closures(ledger_json, promise_results, chapter_idx):
    """打勾 ✅ 联动台账：校验通过的条目直接标记 closed（证据句作回收凭证）。

    治「台账不闭环」：此前台账更新依赖伏笔官二次提取，限流/截断下易失败，
    导致正文明明回收了伏笔、台账却仍 open（终审官会误判"伏笔悬空"）。
    映射关系：清单第 n 条 ↔ 台账 open 列表第 n 个（build_promise_block 同序）。
    返回 (新台账JSON, closed数量)。"""
    try:
        ledger = json.loads(ledger_json) if ledger_json else {}
    except Exception:
        return ledger_json or "{}", 0
    items = ledger.get("foreshadows", []) if isinstance(ledger, dict) else []
    open_idx = [i for i, it in enumerate(items)
                if isinstance(it, dict) and it.get("status") == "open"]
    n_closed = 0
    for r in promise_results:
        if r.get("id") == "verify" or not r.get("fulfilled"):
            continue  # 校验失败标记与未兑现条目不联动
        try:
            n = int(r.get("id", 0))
        except (TypeError, ValueError):
            continue
        if 1 <= n <= len(open_idx):
            item = items[open_idx[n - 1]]
            item["status"] = "closed"
            item["recovered"] = chapter_idx
            item["evidence"] = str(r.get("evidence", ""))[:80]
            n_closed += 1
    if n_closed:
        return json.dumps(ledger, ensure_ascii=False), n_closed
    return ledger_json or "{}", 0


def ensure_complete_ending(final_text, genre, max_rounds=2):
    """末尾完整性检查 + 自动补全（公共函数，主循环与结构补章共用）。

    治「写手输出截断」（fulltest 第 5 章'落在'处戛然而止）：结尾被 max_tokens
    截断成残句时，调写手链补全；补全后复验，最多 max_rounds 轮。
    返回 (final_text, 是否发生补全)。"""
    complete_marks = ("。", "！", "？", "…", "”", "」", "』", "）", "——", "……")
    repaired = False
    for _ in range(max(1, max_rounds)):
        if not final_text.strip():
            break
        tail = final_text.rstrip()[-12:]
        if any(tail.endswith(p) for p in complete_marks):
            break
        print("  [补全] 章末疑似截断，自动补全结尾...")
        add = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                         f"下面是本章结尾，句子似乎没写完（可能被截断）。请接着补全 50~120 字，"
                         f"把话说完、收束本章并保持原有语气与伏笔，不要另起新情节。只输出补全内容：\n\n{final_text[-200:]}",
                         max_tokens=400)
        if add and len(add.strip()) > 10:
            final_text = final_text.rstrip() + add.strip()
            repaired = True
            print(f"  [补全] 已补全 {count_words(add)} 字，当前 {count_words(final_text)} 字")
        else:
            print("  [补全] 补全失败，保留原文")
            break
    return final_text, repaired


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


def review_outline(outline, genre, total_words, max_chapters, output_path):
    """大纲终审守门（写前）：pass 放行；fail 且修订版有效则替换大纲。

    续传安全设计：原始大纲在调用前已 append（type=outline）；修订版作为新一条
    type=outline 追加——load_state 按 last-wins 读取，断点续传天然取修订版，
    且续跑时 outline 已存在不会重复守门。审查过程落 type=outline_review 留痕
    （load_state 不读该类型，不影响任何现有逻辑）。
    LLM 全挂/解析失败时放行原大纲——守门岗不得阻塞生成（与项目兜底原则一致）。
    返回 (outline_used, review_dict_or_None)。"""
    print("=" * 60)
    print("[大纲终审] 写前守门：结构级评审大纲...")
    raw = call_chain(OUTLINE_REVIEWER_CHAIN, OUTLINE_REVIEWER_SYS,
                     outline_review_prompt(outline, genre, total_words, max_chapters),
                     max_tokens=8000)
    rv = parse_json_from_llm(raw)
    if not rv or not isinstance(rv, dict):
        print("  [大纲终审] LLM 评审失败/无有效 JSON，放行原大纲继续（不阻塞生成）")
        return outline, None
    passed = bool(rv.get("pass"))
    issues = rv.get("issues", []) if isinstance(rv.get("issues"), list) else []
    score_txt = rv.get("overall", "-")
    if passed:
        print(f"  [大纲终审] 通过 ✅（{score_txt} 分）")
    else:
        print(f"  [大纲终审] 不通过 ❌（{score_txt} 分，{len(issues)} 个结构问题）")
        for it in issues[:6]:
            print(f"    - [{it.get('chapter', '?')}] {it.get('issue', '')}")
    append_state(output_path, "outline_review",
                 {"pass": passed, "overall": rv.get("overall"), "issues": issues,
                  "advice": rv.get("advice", []), "adopted": False})
    if passed:
        return outline, rv
    rev = rv.get("revised_outline")
    if not isinstance(rev, dict) or not rev.get("chapter_outlines"):
        print("  [大纲终审] 修订版大纲缺失/无效，放行原大纲（问题清单已留痕）")
        return outline, rv
    # 顶层字段兜底合并：修订版缺失的键从原大纲补齐，防止下游取 world/protagonist 落空
    for k in ("title", "blurb", "tags", "protagonist", "world", "hook"):
        if not rev.get(k) and outline.get(k):
            rev[k] = outline[k]
    rev = concretize_world(rev, genre)  # 修订版若引入占位世界观，再具体化一次（幂等）
    append_state(output_path, "outline", rev)   # last-wins：续传读修订版
    print(f"  [大纲终审] 已采纳修订版大纲（{len(rev['chapter_outlines'])} 章）并落盘")
    append_state(output_path, "outline_review",
                 {"pass": passed, "overall": rv.get("overall"), "issues": issues,
                  "advice": rv.get("advice", []), "adopted": True})
    return rev, rv


def load_reviews_from_jsonl(path):
    """续传恢复：从 jsonl 的 type=review 记录重建 reviews（每章 last-wins，全字段透传）。

    旧格式记录只存 idx/score/verdict/problems（缺 redline/words），读取方须用 .get() 兜底；
    新格式存完整 rv dict。
    """
    out = {}
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "review":
                d = rec.get("data", {})
                if isinstance(d, dict) and d.get("idx") is not None:
                    out[d["idx"]] = d
    return [out[k] for k in sorted(out)]


def apply_chief_rewrites(path, state):
    """续传恢复：回放 type=chief_rewrite 补丁（同章 last-wins），保证重写内容不因断点丢失。"""
    if not os.path.exists(path):
        return 0
    patches = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "chief_rewrite":
                d = rec.get("data", {})
                patches[d.get("idx")] = d
    n = 0
    for ch in state.get("chapters", []):
        p = patches.get(ch.get("idx"))
        if p and p.get("content"):
            ch["content"] = p["content"]
            ch["words"] = p.get("words", ch.get("words", 0))
            if p.get("has_hook") is not None:
                ch["_has_hook"] = p["has_hook"]
            n += 1
    return n


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


def scan_used_protagonist_names(glob_dir="D:/novel-writer/data/generated"):
    """扫描既有 jsonl 大纲，收集已用主角名（跨书查重，防规划官惯性起名）。
    扫描范围：data/generated/ + scripts/（test_quality 等验证书也曾撞名——
    《焚骨逆天诀》裴烬在 scripts/test_quality.jsonl，漏扫导致《断脉逆命诀》再次撞名裴烬）。
    返回已用名单列表；扫描失败返回空列表（不影响生成）。"""
    used = []
    scan_dirs = [glob_dir, os.path.join(os.path.dirname(os.path.abspath(__file__)))]
    for scan_dir in scan_dirs:
        try:
            if not os.path.isdir(scan_dir):
                continue
            for fn in os.listdir(scan_dir):
                if not fn.endswith(".jsonl"):
                    continue
                p = os.path.join(scan_dir, fn)
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
            continue
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
    p.add_argument("--no-chief-review", action="store_true",
                   help="收官后跳过终审官总评（省配额；默认开启终审）")
    p.add_argument("--no-outline-review", action="store_true",
                   help="跳过大纲终审官写前守门（默认开启；守门岗失败不阻塞生成）")
    p.add_argument("--no-reader-proxy", action="store_true",
                   help="跳过读者官每章追读反馈（默认开启；反馈注入下一章场景规划）")
    p.add_argument("--no-chief-rewrite", action="store_true",
                   help="终审不达标时不打回重写（默认开启打回权）")
    p.add_argument("--chief-rewrite-threshold", type=float, default=75.0,
                   help="终审打回线：总分低于该值触发问题章重写（默认 75）")
    p.add_argument("--chief-rewrite-max", type=int, default=3,
                   help="单轮打回最多重写几章（默认 3，控制配额）")
    p.add_argument("--no-chief-structure", action="store_true",
                   help="终审二审不达标时不做结构打回（不增补收尾章；默认开启）")
    p.add_argument("--chief-structure-max", type=int, default=2,
                   help="结构打回最多增补几章收尾章（默认 2，受 --max-chapters 语义外的硬顶保护）")
    p.add_argument("--chief-samples", type=int, default=2,
                   help="终审每轮采样次数取中位数（默认 2，治单轮评分方差；1 恢复单轮）")
    p.add_argument("--prev-summary-file", default="",
                   help="前情提要文件（续写模式：规划官须承接该剧情）")
    args = p.parse_args()

    prev_summary = ""
    if args.prev_summary_file and os.path.exists(args.prev_summary_file):
        with open(args.prev_summary_file, encoding="utf-8") as pf:
            prev_summary = pf.read().strip()

    setup_keys()
    if args.skip_amd:
        # 跳过 AMD：把 AMD 链路预标记为冷却（call_chain 自动跳过，纯商汤/NVIDIA 路由）
        amd_providers = [PLANNER_CHAIN[3], WRITER_CHAIN[2], EDITOR_CHAIN[2]]
        for p in amd_providers:
            _HEALTH[(p["url"], p["model"])] = {"fails": 3, "cooldown_until": time.time() + 24 * 3600, "hits": 0}
        print("[INFO] --skip-amd：跳过 AMD 链路，纯商汤路由")
    print(f"[INFO] 协作流水线启动 | 目标 {args.total_words} 字 | 输出 {args.output}")

    state = load_state(args.output, min_words=0)
    outline = state["outline"]
    state_track = load_state_track(args.output)
    if state_track:
        print(f"[RESUME] 已恢复跨章状态清单（{len(state_track.splitlines())} 行）")
    foreshadow_ledger = load_foreshadow(args.output)
    if foreshadow_ledger and foreshadow_ledger.strip() != "[]":
        desc_count = foreshadow_ledger.count('"desc"')  # f-string 表达式内不能含转义
        print(f"[RESUME] 已恢复伏笔台账（{desc_count} 条）")
    # 读者官反馈续传恢复：取最后一章的追读反馈，作为下一章场景规划的注入
    reader_hint = load_reader_feedback(args.output)
    if reader_hint:
        print(f"[RESUME] 已恢复读者官反馈（{reader_hint[:30]}…）")

    # ===== Phase 1：总规划官 =====
    if not outline:
        print("=" * 60)
        print("[Planner] 规划全书大纲...")
        print("=" * 60)
        # 用 PLANNER_CHAIN 故障转移链（K1→K2→K3→AMD），避免单 key 限流直接失败
        plan_text = ""
        for attempt in range(2):
            plan_text = call_chain(PLANNER_CHAIN, PLANNER_SYS,
                                   planning_prompt_idea(args.total_words, prev_summary, genre=args.genre,
                                                        used_names=scan_used_protagonist_names()),
                                   max_tokens=4000)
            outline = parse_json_from_llm(plan_text)
            if outline and outline.get("chapter_outlines"):
                break
        if not outline or not outline.get("chapter_outlines"):
            print(f"[ERROR] 大纲规划失败：{(plan_text or '')[:300]}")
            sys.exit(1)
        outline = concretize_world(outline, args.genre)
        append_state(args.output, "outline", outline)  # 原始大纲先落盘（崩溃后续传依据）
        title = outline.get("title", "未命名")
        print(f"[OK]《{title}》共 {len(outline['chapter_outlines'])} 章")
        # Phase 1.5：大纲终审官写前守门（第 11 角色）——pass 放行；fail 用修订版大纲。
        # 修订版以新一条 type=outline 追加落盘（load_state last-wins，续传安全，
        # 续跑时 outline 已存在不会重复守门）。守门失败/LLM 挂不阻塞生成。
        if not args.no_outline_review:
            outline, _ = review_outline(outline, args.genre, args.total_words,
                                        args.max_chapters, args.output)
            title = outline.get("title", "未命名")
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
    # 续传恢复：回放终审打回重写补丁 + 重建评审分数（修复断点续跑后评估卡"章节：0"问题）
    n_replayed = apply_chief_rewrites(args.output, state)
    if n_replayed:
        print(f"[RESUME] 已回放 {n_replayed} 章终审打回重写补丁")
    total_words = sum(count_words(c.get("content", "")) for c in state["chapters"])
    existing_idx = {c["idx"] for c in state["chapters"]}
    last_summary = ""
    if state["chapters"]:
        last_content = state["chapters"][-1].get("content", "")
        last_summary = last_content[-200:] if len(last_content) > 200 else last_content

    # ===== Phase 2：逐章多角色协作 =====
    reviews = load_reviews_from_jsonl(args.output)
    if reviews:
        print(f"[RESUME] 已恢复 {len(reviews)} 章评审记录")
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
        # 普通章打勾机制：埋设 ≥5 章未收的「超时伏笔」升级为必兑现清单（最多 2 条硬约束），
        # 生成后逐条打勾、✅ 联动台账——只对快烂的伏笔上硬约束，普通章不背全部回收负担
        fs_open_summary = ""
        promise_block_main = build_promise_block(foreshadow_ledger, max_promises=2,
                                                 cur_idx=idx, stale_after=5)
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
        # 读者官反馈注入（上一章读者三问）：消费侧视角入场，场景规划直接回应读者期待与弃点
        if reader_hint:
            rb_block = "【读者试读反馈（上一章，规划本章时尽量回应其期待、避开其弃点）】\n" + reader_hint
            state_inject = (state_inject + "\n\n" + rb_block) if state_inject else rb_block
        # 必兑现清单注入（超时伏笔硬约束）：场景规划必须为其安排落点
        if promise_block_main:
            state_inject = (state_inject + "\n\n" + promise_block_main) if state_inject else promise_block_main
            print(f"  [承诺] 超时伏笔必兑现清单 {promise_block_main.count(chr(10))} 条注入场景规划与写手")
            write_state_main = (state_track + "\n\n" + promise_block_main) if state_track else promise_block_main
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
            if any(k in goal_s for k in ("外显爽点", "打脸", "当众")):
                goal_s += ("【本场景硬约束】这是外显爽点场景：必须写出对手/旁观者的当众外部反应"
                           "（脸色骤变、失态、惊呼、修为显化、围观哗然），禁止只写主角内心感受或含蓄暗示。")
        # 外显爽点硬约束：规划层写了打脸/当众类目标时，强制写手写出外部可见反应
        # （治执行衰减：fulltest 第5章规划"当众打脸"但💥词表命中 0.00，写手写成了内心戏）
        if any(k in goal_s for k in ("外显爽点", "打脸", "当众")):
            goal_s += ("【本场景硬约束】这是外显爽点场景：必须写出对手/旁观者的当众外部反应"
                       "（脸色骤变、失态、惊呼、修为显化、围观哗然），禁止只写主角内心感受或含蓄暗示。")
            beats = sc.get("beats", [])
            tw = sc.get("targetWords", 600)
            print(f"  [场景 {si+1}/{len(scenes)}] {stage}：{goal_s}（目标 {tw} 字）")
            # 空输出快速重试：glm/pro 在长 prompt 下会触发思考死循环
            # （reasoning 吃满 max_tokens、正文为空），重试常能命中正常输出。
            text = ""
            for sretry in range(3):
                text = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                                  scene_prompt(si + 1, len(scenes), stage, goal_s, beats, prev_text, args.genre,
                                               write_state_main, protagonist=protagonist, world=world_str,
                                               hook=hook_for(idx) if si + 1 == len(scenes) else "",
                                               is_opening=(idx == 1 and si == 0)),
                                  max_tokens=int(tw * 3.0))
                if text.strip():
                    break
                if sretry < 2:
                    print(f"    [重试 {sretry+1}/3] 场景空输出（thinking 死循环），10s 后再试")
                    time.sleep(10)
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
                ok_c, why_c = patch_gate(add, base_text=full_text, genre=args.genre,
                                         max_words=int(target * 2.5))
                if ok_c:
                    full_text += "\n\n" + add.strip()
                    w = count_words(full_text)
                else:
                    print(f"  [续写] 产出被拒（{why_c}），保留原文")

        # 空章节保护：场景全部失败且续写也失败（通常为全线限流）时，
        # 跳过本章——避免空正文喂给编辑产生「解释性回复」被误存为正文。
        if w < 200:
            print(f"  [SKIP] 第 {idx} 章仅 {w} 字（场景生成失败），跳过本章，重跑同命令断点续传重试")
            time.sleep(args.chapter_wait)
            continue

        # 3) 去AI味润色（editor）——字数下限守卫：润色是去AI味不是删内容，
        #    低于原文 85% 视为过度压缩（实测曾有 3805→1921 砍半案例），拒绝采纳
        edited = call_chain(EDITOR_CHAIN, EDITOR_SYS, editor_prompt(full_text), max_tokens=int(w * 2.0) + 800)
        if edited:
            w_edited = count_words(edited)
            ok_ed, why_ed = patch_gate(edited, genre=args.genre, max_words=10 ** 9)
            if w_edited >= w * EDITOR_MIN_RATIO and ok_ed:
                print(f"  [编辑] 润色完成 {w} -> {w_edited} 字（AI味密度对比见质检）")
                final_text = edited
            elif not ok_ed:
                print(f"  [编辑] ⚠ 润色产出被拒（{why_ed}），保留原文")
                final_text = full_text
            else:
                print(f"  [编辑] ⚠ 润色产出 {w} -> {w_edited} 字，过度压缩（<{int(EDITOR_MIN_RATIO * 100)}%），拒绝采纳保留原文")
                final_text = full_text
        else:
            print("  [编辑] 润色失败，保留原文")
            final_text = full_text

        # 3.5) 末尾完整性检查 + 自动补全（公共函数，最多 2 轮补全+复验）
        final_text, _repaired = ensure_complete_ending(final_text, args.genre)

        # 3.6) 章末钩子兜底：结尾 200 字无钩子信号词时，补写钩子句（保追读）
        #      补丁卫生：补写产出先过 patch_gate，被拒或全模型不可用时用章纲钩子本地兜底
        if final_text.strip() and not has_ending_hook(final_text):
            print("  [钩子] 章末缺钩，自动补写钩子...")
            final_text, _src = apply_hook_patch(
                final_text, extract_chapter_hook(ch), protagonist, args.genre)

        # 3.65) 普通章打勾：超时伏笔必兑现清单逐条校验 → 未兑现定向补写 → ✅ 联动台账
        promise_results_main = []
        if promise_block_main:
            final_text, promise_results_main = verify_and_repair_promises(
                final_text, promise_block_main, idx, args.genre)
            if promise_results_main and not any(r.get("id") == "verify" for r in promise_results_main):
                new_ledger, n_closed = apply_promise_closures(foreshadow_ledger, promise_results_main, idx)
                if n_closed:
                    foreshadow_ledger = new_ledger
                    save_foreshadow(args.output, foreshadow_ledger)
                    print(f"  [台账] 打勾联动：{n_closed} 条超时伏笔已标记回收（closed）")

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

        # 5) 每 5 章一致性审校（世界观守护官，只记录）
        issues = []
        if idx % 5 == 0 and state["chapters"]:
            chap_list = "\n".join(f"第{c['idx']}章《{c.get('title','')}》" for c in state["chapters"][-5:])
            v = llm_call(WORLD_GUARDIAN, VERIFIER_SYS, verifier_prompt(outline, chap_list), max_tokens=6000)
            parsed = parse_json_from_llm(v, repair=False)
            if parsed and parsed.get("issues"):
                issues = parsed["issues"]
                for it in issues:
                    print(f"  [守护] ⚠ 第{it.get('chapter','?')}章 {it.get('type','')}: {it.get('desc','')}")

        # 5.5) 每 5 章节奏诊断（爽点总监：读最近 5 章，给爽点/节奏处方）
        if idx % 5 == 0:
            recent = state["chapters"][-5:]
            if recent:
                thrills = []
                for c in recent:
                    t1 = thrill_per_thousand(c["content"], args.genre)
                    t2 = surge_per_thousand(c["content"], args.genre)
                    thrills.append(f"第{c['idx']}章({c['words']}字):💥{t1}/✨{t2}")
                tdiag = llm_call(THRILL_DIRECTOR,
                                 "你是一位网文节奏总监，专诊爽点分布与追读危机。",
                                 f"以下 5 章爽点密度（💥直白/✨变强异动，每千字）：\n{chr(10).join(thrills)}\n"
                                 f"题材：{args.genre}。请判断：1)有无连续 2 章以上的爽点塌陷；2)下一章建议的爽点类型与位置。"
                                 f"30 字内回答。", max_tokens=1000)
                if tdiag and tdiag.strip():
                    print(f"  [节奏] {tdiag.strip()[:120]}")

        # 6) 语义质量评分（每 3 章，审校链 pro 主/glm 备）+ 低分自动重写（editor）
        # 注意：max_tokens 必须 ≥6000——pro 思考链实测烧 2000-2900，给小了正文必空（旧值 1000 曾致评分永久静默失效）
        if idx % 3 == 0:
            # 本地质检证据注入：LLM 评审带证据打分，不与规则引擎矛盾（治「100 分无钩子」分裂）
            qa_ev = (f"章末钩子检测：{'命中 ✅' if has_ending_hook(final_text) else '未命中 ❌（hook 维度不应高于 40 分）'}；"
                     f"直白爽点 {thrill_per_thousand(final_text, args.genre)}/千字；"
                     f"变强异动 {surge_per_thousand(final_text, args.genre)}/千字")
            qr = call_chain(VERIFIER_CHAIN, VERIFIER_SYS, quality_review_prompt(final_text, qa_ev), max_tokens=6000)
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
                    rw = apply_text_patch(final_text, rw, args.genre, tag="自动重写")
                    if rw != final_text:
                        w_old = count_words(final_text)
                        final_text = rw
                        w = count_words(final_text)
                        issues.append({"chapter": idx, "type": "auto_rewrite",
                                       "desc": f"{overall} 分已自动重写"})
                        print(f"  [重写] 第 {idx} 章 {w_old} 字 -> {w} 字")
                    else:
                        print("  [重写] 失败，保留原文")
            else:
                print(f"  [评分] 第 {idx} 章 评分解析失败，跳过（不影响生成）")

        # 3.6) 番茄过审评审：不达标就一轮定点修（只改问题处，不动剧情）
        # has_hook 传入本地钩子检测结果——无钩子直接记「重写」级扣分，杜绝「100 分无钩子」
        rv = review_chapter(final_text, last_summary, idx, args.genre, protagonist,
                            review_world_terms, has_hook=has_ending_hook(final_text))
        if needs_fix(rv, args.review_pass):
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
                fixed = apply_text_patch(final_text, fixed, args.genre, tag="评审修")
                if fixed != final_text:
                    rv2 = review_chapter(fixed, last_summary, idx, args.genre, protagonist,
                                         review_world_terms, has_hook=has_ending_hook(fixed))
                    print(f"  [评审] 修后 {rv2['score']} 分（原 {rv['score']} 分）")
                    if rv2["score"] >= rv["score"] and \
                            len(rv2.get("blockers") or []) <= len(rv.get("blockers") or []):
                        final_text, rv = fixed, rv2
                    else:
                        print("  [评审] 修后未改善或新增阻断项，丢弃这次的修")
        else:
            print(f"  [评审] {rv['score']} 分 达线")
        redline_veto = (rv.get("redline") or {}).get("veto") or []
        if redline_veto:
            print(f"  [评审] ☠ 合规红线 {len(redline_veto)} 处，需人工复核")
        for bl in rv.get("blockers") or []:
            print(f"  [评审] ⛔ 阻断项：{bl}（建议人工确认后再投）")
        reviews.append(rv)
        # 全字段落盘（含 redline/words），保证断点续传后评估卡与终审能完整恢复
        append_state(args.output, "review", dict(rv))

        # 3.7) 黄金三章：首屏 300 字单独强化一轮
        if idx <= args.golden_chapters:
            head = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                              first_screen_rewrite_prompt(final_text, args.genre, protagonist),
                              max_tokens=1400)
            if head and 80 <= count_words(head) <= 700:
                ok_head, why_head = patch_gate(head, genre=args.genre, max_words=700)
                if not ok_head:
                    print(f"  [首屏] 强化产出被拒（{why_head}），保留原首屏")
                    head = ""
            if head and 80 <= count_words(head) <= 700:
                cand = _splice_head(final_text, head)
                rv_head = review_chapter(cand, last_summary, idx, args.genre, protagonist,
                                         review_world_terms, has_hook=has_ending_hook(cand))
                if rv_head["score"] >= (reviews[-1]["score"] if reviews else 0) and \
                        len(rv_head.get("blockers") or []) <= \
                        len((reviews[-1].get("blockers") if reviews else None) or []):
                    print(f"  [首屏] 已强化（评审 {rv_head['score']} 分）")
                    final_text = cand
                    if reviews:
                        reviews[-1] = rv_head
                else:
                    print(f"  [首屏] 强化后反而降分（{rv_head['score']}），丢弃")

        if promise_results_main:
            n_ok = sum(1 for r in promise_results_main if r.get("fulfilled"))
            issues.append({"type": "promise_check",
                           "desc": f"必兑现清单 {n_ok}/{len(promise_results_main)} 条伏笔兑现"})
            append_state(args.output, "promise_check",
                         {"idx": idx, "results": promise_results_main, "promise_block": promise_block_main})

        # 7.55) 钩子终检：定点修/首屏强化/评审修都发生在钩子兜底之后，可能把已补的
        #       钩子改没（fulltest 实测第 3 章：229 行补写钩子 → 237 行定点修改没 →
        #       终审判"无钩"）。record 前最后一次校验，无钩再补一轮，堵住全部后置覆盖路径
        if final_text.strip() and not has_ending_hook(final_text):
            print("  [钩子终检] 定点修/强化后钩子丢失，补写…")
            final_text, hook_src = apply_hook_patch(
                final_text, extract_chapter_hook(ch), protagonist, args.genre, tag="终检")
            if hook_src:
                issues.append({"type": "hook_recheck",
                               "desc": f"后置修改吃掉钩子，终检补写（{hook_src}）"})

        # 7.6) 章内去重：复制粘贴级的整块重复（实测第 3 章开头 800 字出现两遍）
        final_text = dedup_chapter(final_text, idx)

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

        # 7) 跨章状态提取（状态提取官 dsf-flash K3）：维护状态清单供下一章写作遵守（失败保留旧状态）
        # 轻任务（3~8 行纯文本）换轻模型——旧版用 pro+max_tokens=800，思考链吃满预算曾致状态提取永久静默失效
        st = llm_call(STATE_EXTRACTOR, VERIFIER_SYS,
                      state_extract_prompt(final_text, state_track), max_tokens=2000)
        if st and st.strip():
            state_track = st.strip()
            save_state_track(args.output, state_track)
            print(f"  [状态] 已更新跨章状态清单（{len(state_track.splitlines())} 行）")
        else:
            print("  [状态] 提取失败，保留旧状态")

        # 7.5) 伏笔台账提取（伏笔官 dsf-flash K2）：记录新埋伏笔/标记回收（失败保留旧台账，不阻断）
        fs = llm_call(FORESHADOWER, "你是一位长篇小说伏笔管理员。",
                      foreshadow_extract_prompt(final_text, foreshadow_ledger, idx),
                      max_tokens=4000)
        parsed_fs = parse_json_from_llm(fs)
        if parsed_fs and parsed_fs.get("foreshadows"):
            foreshadow_ledger = json.dumps(parsed_fs, ensure_ascii=False)
            save_foreshadow(args.output, foreshadow_ledger)
            n_open = sum(1 for it in parsed_fs["foreshadows"] if it.get("status") == "open")
            n_closed = sum(1 for it in parsed_fs["foreshadows"] if it.get("status") == "closed")
            print(f"  [伏笔] 台账已更新（open {n_open} / closed {n_closed}）")
        else:
            print("  [伏笔] 提取失败，保留旧台账")

        # 7.6) 每 5 章检查超时未收伏笔（防长篇丢伏笔/改设定）
        if idx % 5 == 0:
            fs_warns = check_open_foreshadows(foreshadow_ledger, idx, stale_after=5)
            if fs_warns:
                print("  [伏笔] 超时未收告警：")
                for w in fs_warns:
                    print(f"    {w}")
            else:
                print("  [伏笔] 无超时未收伏笔 ✅")

        # 7.7) 读者官追读反馈（第 12 角色 dsf-flash K3）：读完本章答三问，
        #      反馈注入下一章场景规划（消费侧视角）；失败空过不阻塞（下一章无注入）
        if not args.no_reader_proxy:
            rf = llm_call(READER_PROXY,
                          "你是一位番茄小说重度读者，凭真实读感直说，只输出被要求的内容。",
                          reader_proxy_prompt(final_text, args.genre), max_tokens=500)
            if rf and rf.strip():
                reader_hint = rf.strip()
                append_state(args.output, "reader_feedback",
                             {"idx": idx, "feedback": reader_hint})
                first_line = reader_hint.splitlines()[0] if reader_hint.splitlines() else ""
                print(f"  [读者] {first_line[:44]}（反馈已注入下一章规划）")
            else:
                print("  [读者] 反馈获取失败，下一章规划不注入")

        print(f"  [完成] 第 {idx} 章：{chapter_record['words']} 字 | 累计 {total_words} 字")

    # ===== Phase 3：质检汇总 =====
    print(f"\n{'=' * 60}\n[QA] 本地规则质检（AI味密度/重复率/节奏/世界观冲突）\n{'=' * 60}")
    quality_check(state["chapters"])  # 副作用：填充各章 _world_conflicts 等质检字段
    total_conflicts = 0
    for ch in state["chapters"]:
        conflicts = ch.get("_world_conflicts", [])
        total_conflicts += len(conflicts)
        flag = "⚠" if conflicts else "✓"
        hook_flag = "🪝" if ch.get("_has_hook") else "✗无钩"
        open_flag = "⚡" if ch.get("_has_quick_opening", True) else "✗开场慢"
        print(f"  {flag} 第 {ch['idx']} 章：{ch.get('_words',0)} 字｜AI味 {ch.get('_ai_echo_pct',0)}%｜{hook_flag}｜{open_flag}")
    print(f"  世界观冲突：{total_conflicts} 处 | 审校问题：{sum(len(c.get('issues',[])) for c in state['chapters'])} 处")

    # ===== Phase 3.5：终审官总评 + 打回重写权（第 10 角色，全书唯一通读级 LLM 评审）=====
    # 流程：终审 → 总分低于打回线则定向重写问题章（最多 chief-rewrite-max 章）→ 二审一轮 → 出终审卡
    if not args.no_chief_review and state["chapters"]:
        print(f"\n{'=' * 60}\n[终审] 终审官通读级总评（六维 + 签约建议）\n{'=' * 60}")
        total_words_done = sum(c.get("words", 0) for c in state["chapters"])
        chief_history = []

        def _chief_pass(round_no):
            # 多采样取中位：单轮评分方差大（实测同书 83/68/64/71/64），
            # 采样 CHIEF_SAMPLES 次后合并（overall/六维取中位），verdict 按分数区间本地判档
            # 模型偶发写坏 JSON：按「目标成功数」补打（最多 2× 目标次数），不再两连败即放弃
            samples = []
            attempts = 0
            target = max(1, args.chief_samples)
            max_attempts = target * 2
            while len(samples) < target and attempts < max_attempts:
                attempts += 1
                raw = call_chain(
                    CHIEF_EDITOR_CHAIN,
                    "你是番茄/起点的资深签约终审编辑，只输出 JSON。",
                    chief_editor_prompt(outline, state["chapters"], reviews, state_track,
                                        foreshadow_ledger, args.genre, total_words_done),
                    max_tokens=6000)
                parsed = parse_json_from_llm(raw, repair=False)
                if not parsed:
                    # 终审 JSON 长（嵌套 top_issues），裸解析失败时走修复解析兜底
                    parsed = parse_json_from_llm(raw, repair=True)
                if parsed and parsed.get("overall") is not None:
                    samples.append(parsed)
                    print(f"  [终审·第{round_no}轮·采样 {len(samples)}/{target}] 综合 {parsed.get('overall')} 分"
                          f"（第 {attempts} 次尝试）")
                else:
                    print(f"  [终审·第{round_no}轮·尝试 {attempts}/{max_attempts}] 解析失败，原文前 300 字：")
                    print(f"    {(raw or '')[:300]}")
            parsed = _merge_chief_samples(samples)
            if parsed and parsed.get("overall") is not None:
                parsed["_round"] = round_no
                chief_history.append(parsed)
                dims = " ".join(f"{k}{v}" for k, v in (parsed.get("dimensions") or {}).items())
                print(f"  [终审·第{round_no}轮] 合并综合 {parsed.get('overall')} 分｜{parsed.get('verdict', '')}"
                      f"（模型判词参考：{parsed.get('model_verdict', '') or '—'}｜有效采样 {parsed.get('samples', 1)} 次）")
                print(f"  [终审·第{round_no}轮] 六维：{dims}")
                # 硬伤维度告警：任一维度 ≤40 时不因总分过线而漏报（防"83 分但伏笔回收 30"）
                hard_dims = {k: v for k, v in (parsed.get("dimensions") or {}).items()
                             if isinstance(v, (int, float)) and v <= 40}
                if hard_dims:
                    print(f"  [终审·第{round_no}轮] ☠ 硬伤维度（≤40）：{hard_dims}——即使总分达标也建议人工复核")
                for it in (parsed.get("top_issues") or [])[:5]:
                    print(f"  [终审·第{round_no}轮] ⚠ 第{it.get('chapter', '?')}章 "
                          f"{it.get('issue', '')}（{str(it.get('evidence', ''))[:40]}）")
            else:
                print(f"  [终审·第{round_no}轮] 全部采样解析失败（严格+修复双模式），无法合并")
            return parsed

        chief = _chief_pass(1)

        # ---- 打回重写权：总分低于打回线 → 定向重写被点名的章 ----
        if (chief and not args.no_chief_rewrite
                and chief.get("overall", 100) < args.chief_rewrite_threshold):
            issues = chief.get("top_issues") or []
            fixes = "；".join(str(x) for x in (chief.get("fix_priority") or [])[:3])
            cited = []
            for it in issues:
                try:
                    n = int(it.get("chapter", 0))
                except (TypeError, ValueError):
                    continue
                if n and n not in cited and any(c["idx"] == n for c in state["chapters"]):
                    cited.append(n)
            cited = cited[:args.chief_rewrite_max]
            if cited:
                print(f"\n  [打回] {chief.get('overall')} 分 < 打回线 {args.chief_rewrite_threshold}，"
                      f"打回重写第 {cited} 章（最多 {args.chief_rewrite_max} 章/轮）")
                for n in cited:
                    ch = next(c for c in state["chapters"] if c["idx"] == n)
                    issue = next((it for it in issues if str(it.get("chapter")) == str(n)), {})
                    old_w = count_words(ch.get("content", ""))
                    print(f"  [重写] 第 {n} 章（{str(issue.get('issue', ''))[:40]}）…")
                    rw = call_chain(
                        EDITOR_CHAIN, EDITOR_SYS,
                        chief_rewrite_prompt(ch.get("content", ""), issue,
                                             issue.get("evidence", ""), fixes),
                        max_tokens=int(old_w * 1.6) + 800)
                    rw = apply_text_patch(ch.get("content", ""), rw, args.genre, tag="终审重写")
                    if rw != ch.get("content", ""):
                        ch["content"] = rw
                        ch["words"] = count_words(ch["content"])
                        ch["_has_hook"] = has_ending_hook(ch["content"])
                        ch["issues"] = (ch.get("issues") or []) + [
                            {"type": "chief_rewrite", "desc": f"终审打回重写：{str(issue.get('issue', ''))[:40]}"}]
                        # 重新评审该章并同步 reviews
                        prev_ch = next((c for c in state["chapters"] if c["idx"] == n - 1), None)
                        prev_tail = (prev_ch.get("content", "")[-200:] if prev_ch else "")
                        rv2 = review_chapter(ch["content"], prev_tail, n, args.genre,
                                             protagonist, review_world_terms)
                        for ri, r in enumerate(reviews):
                            if r.get("idx") == n:
                                reviews[ri] = {"idx": n, "score": rv2["score"],
                                               "verdict": rv2["verdict"],
                                               "words": ch["words"],
                                               "problems": rv2["problems"]}
                                break
                        else:
                            reviews.append({"idx": n, "score": rv2["score"],
                                            "verdict": rv2["verdict"], "words": ch["words"],
                                            "problems": rv2["problems"]})
                        append_state(args.output, "chief_rewrite",
                                     {"idx": n, "words": ch["words"], "old_words": old_w,
                                      "content": ch["content"], "has_hook": ch["_has_hook"],
                                      "reason": issue.get("issue", ""),
                                      "rescore": rv2["score"]})
                        print(f"  [重写] 第 {n} 章 {old_w} 字 -> {ch['words']} 字，"
                              f"复审 {rv2['score']} 分（原 {next((r['score'] for r in reviews if r['idx'] == n), '-')}）")
                    else:
                        print(f"  [重写] 第 {n} 章无有效产出，保留原文")
                # 二审：重写后再终审一轮，以第二轮为准
                print("\n  [终审] 重写完成，二审…")
                total_words_done = sum(c.get("words", 0) for c in state["chapters"])
                chief2 = _chief_pass(2)
                if chief2:
                    chief = chief2
            else:
                print("  [打回] 终审问题未落到具体章节，无法定向重写，保留报告交人工")
        elif chief:
            print(f"  [终审] {chief.get('overall')} 分 ≥ 打回线 {args.chief_rewrite_threshold}，无需打回")

        # ---- 权力二·结构打回：二审仍不达标 → 规划官增补收尾章 → 生成 → 三审 ----
        # 针对修章治不了的结构级问题（伏笔悬空/缺结局/主线未收束），与写前守门（大纲终审官）互补
        if (chief and not getattr(args, "no_chief_structure", False)
                and len(chief_history) >= 2
                and chief.get("overall", 100) < args.chief_rewrite_threshold):
            print(f"\n  [结构打回] 二审 {chief.get('overall')} 分仍低于打回线，交规划官评估补章…")
            raw_fix = call_chain(PLANNER_CHAIN, PLANNER_SYS,
                                 structure_fix_prompt(outline, state["chapters"], state_track,
                                                      foreshadow_ledger, args.genre, chief,
                                                      args.chief_structure_max),
                                 max_tokens=3000)
            fix_plan = parse_json_from_llm(raw_fix, repair=False) or parse_json_from_llm(raw_fix, repair=True)
            if not fix_plan:
                # 长嵌套 JSON 偶发语法瑕疵，重试一次常能自愈；绝不把解析失败误报成"判定无需加章"
                print("  [结构打回] 规划官输出解析失败，重试一次…")
                raw_fix = call_chain(PLANNER_CHAIN, PLANNER_SYS,
                                     structure_fix_prompt(outline, state["chapters"], state_track,
                                                          foreshadow_ledger, args.genre, chief,
                                                          args.chief_structure_max),
                                     max_tokens=3000)
                fix_plan = parse_json_from_llm(raw_fix, repair=False) or parse_json_from_llm(raw_fix, repair=True) or {}
            max_idx = max((c.get("idx", 0) for c in state["chapters"]), default=0)
            new_chs = []
            if fix_plan:
                if fix_plan.get("reason"):
                    print(f"  [规划官裁决] {str(fix_plan['reason'])[:60]}")
                for c in (fix_plan.get("new_chapters") or []):
                    if not (isinstance(c, dict) and c.get("goal")):
                        continue
                    c["idx"] = max_idx + 1 + len(new_chs)
                    c.setdefault("title", f"第{c['idx']}章")
                    c.setdefault("target", 3000)
                    new_chs.append(c)
                    if len(new_chs) >= max(1, args.chief_structure_max):
                        break
            else:
                print("  [结构打回] 规划官两次解析失败，保留报告交人工")
            if new_chs:
                outline.setdefault("chapter_outlines", []).extend(new_chs)
                # 新大纲落盘（load_state 取最后一条 outline 记录，续传安全）
                append_state(args.output, "outline", outline)
                print("  [结构打回] 规划官增补：" +
                      "、".join(f"第{c['idx']}章《{c.get('title', '')}》" for c in new_chs) +
                      (f"（{str(fix_plan.get('reason', ''))[:60]}）" if fix_plan.get("reason") else ""))
                trackers = {"total_words": sum(c.get("words", 0) for c in state["chapters"]),
                            "last_summary": last_summary,
                            "state_track": state_track,
                            "foreshadow_ledger": foreshadow_ledger}
                ctx = {"args": args, "outline": outline, "state": state, "reviews": reviews,
                       "trackers": trackers, "protagonist": protagonist, "world_str": world_str,
                       "review_world_terms": review_world_terms}
                for c in new_chs:
                    generate_appended_chapter(c, ctx)
                # 同步回 main 局部变量，供三审与后续导出使用
                last_summary = trackers["last_summary"]
                state_track = trackers["state_track"]
                foreshadow_ledger = trackers["foreshadow_ledger"]
                print("\n  [终审] 收尾章生成完毕，三审…")
                chief3 = _chief_pass(3)
                if chief3:
                    chief = chief3
            else:
                if fix_plan:
                    print(f"  [结构打回] 规划官判定无需加章"
                          f"（{str(fix_plan.get('reason', ''))[:60] or '未给出理由'}），维持二审结论")
        elif chief and len(chief_history) >= 2:
            print(f"  [结构打回] 未触发（{'用户关闭' if args.no_chief_structure else '二审已达线'}）")

        # ---- 终审卡落盘（含轮次历史）----
        if chief:
            append_state(args.output, "chief_review",
                         {"overall": chief.get("overall"), "verdict": chief.get("verdict"),
                          "rounds": [{"round": h.get("_round"), "overall": h.get("overall"),
                                      "verdict": h.get("verdict")} for h in chief_history],
                          "report": chief})
            base = args.output.rsplit(".", 1)[0]
            chief_path = os.path.join(os.path.dirname(os.path.abspath(args.output)),
                                      os.path.basename(base) + ".终审卡.txt")
            with open(chief_path, "w", encoding="utf-8") as f:
                f.write(f"《{outline.get('title', '')}》 终审官总评（LLM 通读级）\n")
                f.write(f"题材：{args.genre}｜章节：{len(state['chapters'])}｜总字数："
                        f"{sum(c.get('words', 0) for c in state['chapters'])}\n\n")
                hist = " → ".join(f"第{h.get('_round')}轮 {h.get('overall')}分({h.get('verdict', '')})"
                                  for h in chief_history) or "—"
                f.write(f"终审轨迹：{hist}\n")
                f.write(f"打回线：{args.chief_rewrite_threshold}｜本轮打回重写："
                        f"{'无' if not args.no_chief_rewrite and len(chief_history) < 2 else ('有' if len(chief_history) >= 2 else '未触发')}\n\n")
                f.write(f"最终：综合 {chief.get('overall')} 分｜{chief.get('verdict', '')}\n\n")
                f.write(json.dumps(chief, ensure_ascii=False, indent=2))
            print(f"  [终审] 报告已落盘：{chief_path}")

    # ===== Phase 4：导出 =====
    txt_path = export_txt(args.output, outline.get("title", "未命名"), state["chapters"])
    print(f"\n[OK] 文本输出：{txt_path}")
    print(f"[OK] 总字数：{sum(c.get('words', 0) for c in state['chapters'])}")

    # ===== Phase 5：番茄评估卡 + 上架包 =====
    if not args.no_fanqie_pack:
        base = args.output.rsplit(".", 1)[0]
        card = os.path.join(os.path.dirname(os.path.abspath(args.output)),
                            os.path.basename(base) + ".评估卡.txt")
        if not reviews:
            # reviews 为空（中途退出/续跑早期）时现算一遍：旧版直接写「章节：0｜评审均分：0.0」，
            # 那种空卡会让人误判「已经达线」，也会掩盖真正的问题章
            reviews = [review_chapter(c.get("content", ""), "", c.get("idx", i + 1),
                                      args.genre, protagonist, review_world_terms)
                       for i, c in enumerate(state["chapters"])]
            print(f"  [评估卡] reviews 为空，按正文现算 {len(reviews)} 章")
        n_block = sum(1 for r in reviews if r.get("blockers"))
        with open(card, "w", encoding="utf-8") as f:
            f.write(f"《{outline.get('title', '')}》 番茄过审评估卡\n")
            f.write(f"题材：{args.genre}｜章节：{len(reviews)}｜评审均分："
                    f"{round(sum(r['score'] for r in reviews) / max(len(reviews), 1), 1)}\n")
            f.write(f"阻断级硬伤章数：{n_block}（有阻断项即不给「可投」，先按下列清单定点修）\n\n")
            for r in reviews:
                f.write(f"第 {r['idx']} 章  {r.get('score', '-')} 分  {r.get('verdict', '')}｜{r.get('words', 0)} 字\n")
                if r.get("blockers"):
                    f.write(f"    ⛔ 阻断项：{'、'.join(r['blockers'])}\n")
                for pr in r.get("problems") or []:
                    f.write(f"    [{pr['action']}] {pr['type']}：{pr['msg']}\n")
                for h in (r.get("redline") or {}).get("veto") or []:
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
