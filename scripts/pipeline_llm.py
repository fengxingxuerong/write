#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LLM 调用层 + 角色槽位配置：多模型协作的「传输层」。

2026-10-03 从 novel_pipeline.py 拆出（该文件 2620 行，属「上帝文件」）。
拆分依据是**内聚性边界**而非行数好看：本模块只负责「把一段 prompt 送到某个模型
并把文本拿回来」，不含任何写作判据（钩子/爽点/伏笔/一致性全在外面）。

本模块只依赖标准库 + quality_rules_generated（单一数据源），不含流水线状态，
可独立单测；导入本模块不会触发任何网络请求。

对外接口（调用方仍从 novel_pipeline 取同名转发，见该文件 import 处）：
  槽位常量：SENSE / AMD / NVIDIA / PLANNER / PLANNER_CHAIN / WRITER_CHAIN /
            EDITOR_CHAIN / TITLER / VERIFIER_CHAIN / STATE_EXTRACTOR /
            READER_PROXY / FORESHADOWER / WORLD_GUARDIAN / THRILL_DIRECTOR /
            CHIEF_EDITOR_CHAIN / OUTLINE_REVIEWER_CHAIN / THINKING_FLOOR_TOKENS
  函数：_key / setup_keys / scene_budget / llm_call / call_chain / dedup_scene_join
  阈值：EDITOR_MIN_RATIO / COOLDOWN_SECONDS

⚠ 拆分的红线（与 foreshadow.py 同一条）：拆分只降低维护成本，**不改对外契约**。
槽位配置是**可变 dict/list**，调用方（main、tool/ 下各探针）会原地改
`CHAIN[i]["key"]`；转发导入必须保持同一对象引用，**不能深拷贝**，否则
setup_keys 写进去的 key 在调用方看不到。故 novel_pipeline 侧直接 `from
pipeline_llm import (...)`，不做任何包装。
"""
import hashlib
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# 质检阈值单一数据源（rules/quality_rules.json 的生成物，无项目内依赖）。
import quality_rules_generated as _gen  # noqa: E402

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
# 可用性矩阵（2026-09-12 实测；2026-09-23 花名册更新见质量日志第十四节）：
#   商汤 glm-5.2: K1✅K2✅K3✅（三件套 temp=1.0+大token+enable_thinking=False；长场景 prompt 有思考死循环风险）
#   商汤 deepseek-v4-pro: K1✅K2✅K3✅（思考链重 2000-2900 token，max_tokens≥6000 否则正文必空）
#   商汤 kimi-k3: K2✅（K1/K3 上轮 429）；硬约束 temperature 仅允许 1（llm_call 已加守卫）
#   商汤 deepseek-v4-flash: K1✅K2✅K3✅【本轮复活，上轮 401】（3-4s 快，思维链轻但也会吃 400+ token，需 max_tokens≥1500）
#   AMD DeepSeek-V4-Flash: ✅（约 30s 偏慢，高峰限流，作末备）
#   NVIDIA deepseek-ai/deepseek-v4.1-flash: 【2026-09-23 换】旧 deepseek-v4-flash-0731 已
#       下架（HTTP 410，且不在 /v1/models 目录）→ 换代际后继 v4.1-flash（目录在架；
#       当前端点排队严重，60s+ 超时频发 → 维持链末位，不指望它兜底）
#   NVIDIA z-ai/glm-5.2: 410 EOL 确认死亡（2026-08-21 下架，勿再尝试）；
#       现目录在架 z-ai/glm-5.3 / glm-5.3-flash / deepseek-v4.1-flash / moonshotai/kimi-k3
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
# 规划官链：glm K1 → dsf K1 → glm K2 → dsf K2 → AMD → NV
#
# 2026-09-29 真机改链：原链是 glm K1→K2→K3→AMD→NV，**三个 glm 同模型同端点、
# 只差 key**。这在两类失败下的价值完全不同：
#   · key 级失败（429 配额）：K1 耗尽 ≠ K2 耗尽，key 多样性**有效**；
#   · 模型级失败（glm 思考链吃满 max_tokens=8000 致正文为空）：三把 key **必然
#     一起失败**，key 多样性**完全无用**——纯白等三轮。
# 真机实测（verify_after 跑书）：三把 glm key 轮番报同一条
# `[diag] glm-5.2 思考链有输出但正文为空`，最后靠 AMD（159s）才拿到大纲，
# 规划阶段白白多花约 8 分钟。
#
# 修法 = 给规划链补**模型多样性**：插入 dsf-flash（写手链早已验证「思维链轻、
# 免疫思考死循环」，第 8 节「根治 glm 场景死循环」那条教训当初只落在写手位、
# 漏了规划位）。glm 仍保留首位（其大纲质量经真书验证），dsf 紧随其后专门接
# 模型级失败，后续 glm/dsf 交替再分摊 key 级配额压力。
#
# 2026-09-30 记录**真正的根因**（此前「补模型多样性」只治了 key/模型级失败）：
# 规划死循环跟链里配的 max_tokens **无关**——`call_chain(chain, sys, user, max_tokens)`
# 的 max_tokens 是必填参数、直接透传给 llm_call，而 llm_call 里是
# `max_tokens or provider.get('max_tokens', 2000)`，**调用方传的值优先**。
# 规划调用点硬编码 `max_tokens=4000`，把每个槽位配的 8000 **整个覆盖掉**。
# 于是：思考链模型实际只拿到 4000 token，正文必然为空；而诊断打印的是
# `provider.get('max_tokens')`（槽位配置 8000），于是日志 misleading 地显示
# 「吃满 max_tokens=8000」——**日志与实际发出的请求对不上**，这也是此前
# 一直没定位到真因的原因。跑书卡在规划、jsonl 只落 1 条 style_ref、一章没写成。
# 修法见规划调用点（4000 → 12000，与大纲终审官对齐）。槽位 max_tokens 对
# 走 call_chain 且显式传参的调用点一律无效，属既有设计债，本轮只修规划位。
PLANNER_CHAIN = [
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=8000),            # K1 主
    dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=8000),  # dsf：接模型级失败
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=8000),            # K2 备
    dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=8000),  # dsf 备
    dict(url=AMD, model="DeepSeek-V4-Flash", key="", temp=0.8, max_tokens=4000),     # AMD（真机实测 159s/2000字）
    dict(url=NVIDIA, model="deepseek-ai/deepseek-v4.1-flash", key="", temp=0.8, max_tokens=4000),  # NV 末备
]
WRITER_CHAIN = [
    dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=6000),  # K1 dsf 主（快，思维链轻）
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=8000),            # K2 glm 备（三件套）
    dict(url=AMD, model="DeepSeek-V4-Flash", key="", temp=0.8, max_tokens=6000),    # AMD（稳定 30s，思考死循环免疫，排 NV 前）
    dict(url=NVIDIA, model="deepseek-ai/deepseek-v4.1-flash", key="", temp=0.8, max_tokens=6000),  # NV 末备（-0731 已 410 下架，2026-09-23 换代；端点排队严重仅象征性兜底）
]


def scene_budget(target_words, factor=3.0, floor=4000):
    """场景写作的 max_tokens = 目标字数 × factor，并给**思考链**留出生存空间。

    2026-09-30 真机实锤：写手链是 dsf/glm 这类**思考链**模型，且端点忽略
    `enable_thinking=False`——thinking 会先烧掉 token。正文要活下来，预算不能
    只按字数算。原先写手调用点一律 `int(tw * 3.0)`，600 字场景 = 1800 token，
    dsf/glm 思考链把 1800 吃满 → **正文恒空**；每个场景白白烧 2 次失败调用
    （dsf+glm），最后落到慢的 AMD（159s）兜底，整书又慢又失真。
    这与规划位/大纲终审位是**同一个病根**：思考链预算不足导致「吃满→正文空」。

    floor=4000 的依据：写手槽位本身配的就是 6000~8000，仓库里「思考链模型需
    数千 token 才有正文」是反复验证过的；这里取 4000 作场景级保守下限——场景
    短（数百字），正文需求小，主要成本是 thinking 本身。字数大时 ×factor 自然
    超过 floor，不受此下限影响。
    """
    return max(int(target_words * factor), floor)


# 思考链模型（dsf/glm 系，端点忽略 enable_thinking=False）调用小任务时的
# max_tokens 保底：任务本身正文很短（钩子/补全/续写/专名/读者官），但 thinking
# 仍要先烧 token。2026-09-30 真机实锤：max_tokens=300 喂 glm 思考链必然「吃满→
# 正文空」，钩子补写（追读命门）长期只能靠本地兜底撑着；=800 喂规划链同理。
# 给一个能容纳 thinking 的下限，避免小预算调用恒空。
THINKING_FLOOR_TOKENS = 2000
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
    # 规划官：glm K1 → dsf K1 → glm K2 → dsf K2 → AMD → NVIDIA
    # （dsf 槽为 2026-09-29 补的模型多样性，见 PLANNER_CHAIN 处说明）
    PLANNER_CHAIN[0]["key"] = _key("NOVEL_KEY_SENSE_K1")
    PLANNER_CHAIN[1]["key"] = _key("NOVEL_KEY_SENSE_K1")
    PLANNER_CHAIN[2]["key"] = _key("NOVEL_KEY_SENSE_K2")
    PLANNER_CHAIN[3]["key"] = _key("NOVEL_KEY_SENSE_K2")
    PLANNER_CHAIN[4]["key"] = _key("NOVEL_KEY_AMD")
    PLANNER_CHAIN[5]["key"] = _key("NOVEL_KEY_NVIDIA")
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
# 健康池按「端点 + 凭据」隔离。相同 URL/模型但不同 API Key 的配额状态相互独立；
# 只把 Key 的 SHA-256 短指纹放进内存键，避免日志或调试输出泄露明文凭据。
_HEALTH = {}  # key: {fails: 连续失败数, cooldown_until: 时间戳, hits: 成功数}
COOLDOWN_SECONDS = 300  # 连续失败 N 次后冷却 5 分钟

# 编辑类产出采纳下限（2026-09-13 fulltest 实测：编辑链曾把 3805 字章润色成 1921 字
# 砍半后被无条件采纳，违反"字数只多不少"约定）。润色/定点修/重写类采纳统一要求
# ≥ 原文 85%，不达标视为无效产出、保留原文并告警。
# 2026-10-03：值改由 rules/quality_rules.json 的 editorMinRatio 单一数据源下发
# （此前本文件与 Dart 侧各自硬编码 0.85，是唯一一条未受 codegen 保护的阈值）。
EDITOR_MIN_RATIO = _gen.EDITOR_MIN_RATIO


def _health_key(provider):
    """返回不含明文 API Key 的健康池身份。"""
    raw_key = str(provider.get("key", "")).encode("utf-8")
    fingerprint = hashlib.sha256(raw_key).hexdigest()[:12] if raw_key else "anonymous"
    return (provider["url"], provider["model"], fingerprint)


def _mark_fail(provider):
    k = _health_key(provider)
    h = _HEALTH.setdefault(k, {"fails": 0, "cooldown_until": 0, "hits": 0})
    h["fails"] += 1
    if h["fails"] >= 3:
        h["cooldown_until"] = time.time() + COOLDOWN_SECONDS
        print(f"    [健康池] {provider['model']} 连续失败 {h['fails']} 次，冷却 {COOLDOWN_SECONDS}s")


def _mark_ok(provider):
    k = _health_key(provider)
    h = _HEALTH.setdefault(k, {"fails": 0, "cooldown_until": 0, "hits": 0})
    h["fails"] = 0
    h["hits"] += 1


def _in_cooldown(provider):
    k = _health_key(provider)
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
    # 实发 max_tokens：调用方传参优先，其次槽位配置，最后 2000 兜底。
    # 抽成变量供诊断打印——诊断必须反映**真实发出的**值，而非槽位配置，
    # 否则调用方覆盖时会打印出与实际请求不符的数字，误导排查。
    _sent_max_tokens = max_tokens or provider.get("max_tokens", 2000)
    payload = {
        "model": provider["model"],
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": _sent_max_tokens,
        "temperature": temperature if temperature is not None else provider.get("temp", 0.8),
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    # 【已否决 2026-09-30 · 真机探针实测】曾按 Dart 侧 TokenBudget
    # needsExtraThinkingFlag 补发第二层开关（options.Thinking=false），理由是
    # 「Python 只发一层、双端口径分叉」。**真机实测证明该假设不成立**：
    # tool/_probe_thinking_flag.py 对 deepseek-v4-flash 用真实
    # system(1735字)+场景 prompt 跑了 8 次，结果是——
    #   短prompt/1500：不发→正文空(思考链2044) ；发→正文332
    #   长prompt/1500：不发→正文784 ；    发→正文空(思考链2193)
    #   长prompt/6000：不发→正文712 ；    发→正文空(思考链8925)
    # 同一条件下「发/不发」的正文有无是**随机**的，思考链长度在 89~8925 之间
    # 大幅波动。第二层开关不改变 thinking 是否被关闭，只会让思考链偶发暴涨
    # 把正文挤空——**有害无益，故不加**。
    #
    # 真根因：该端点的 enable_thinking=false 对 deepseek 系并不完全生效，
    # 思考链长度不可预测，偶发超过 max_tokens 就正文空。有效对策只有两条：
    #   ① max_tokens 给足（让思考链也装得下）——实测 4000 时两次都出正文；
    #   ② 靠 call_chain 的健康池冷却 + 降级换模型（既有机制，本已在跑）。
    # 见 tool/_probe_thinking_flag.py（可复跑复核）。
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
                    # 打印**实发**的 max_tokens（`_sent_max_tokens`），不是槽位配置
                    # `provider['max_tokens']`：2026-09-30 规划死循环排查时，这条诊断
                    # 显示「吃满 8000」而实际请求只发了 4000（call_chain 的调用方
                    # 传参覆盖了槽位配置），日志与真实请求对不上，误导定位半天。
                    print(f"    [diag] {provider['model']} 思考链有输出但正文为空"
                          f"（thinking 吃满实发 max_tokens={_sent_max_tokens}"
                          f"，槽位配={provider.get('max_tokens')}），建议加大 max_tokens")
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


def call_chain(chain, system, user, max_tokens, _call=None, _in_cooldown_=None):
    """沿故障转移链依次调用，返回第一个非空结果。冷却中的 key 自动跳过。

    ⚠ 拆分注记（2026-10-03）：`_call` / `_in_cooldown_` 是**注入点**。
    novel_pipeline 转发本函数时会把自己的模块属性传进来，于是既有测试里的
    `patch.object(novel_pipeline, "llm_call", ...)` 仍能生效——若这里直接写死
    解析本模块的全局名 `llm_call`，补丁就打在别的模块对象上，测试会静默
    失去「短路网络」的保护（表现为真发请求或断言失效）。
    """
    call = _call if _call is not None else llm_call
    cooldown = _in_cooldown_ if _in_cooldown_ is not None else _in_cooldown
    for p in chain:
        if cooldown(p):
            print(f"    [chain] {p['model']} 冷却中，跳过")
            continue
        r = call(p, system, user, max_tokens=max_tokens)
        # 合法 JSON 可能很短（例如 {"issues":[]}），不能按字符数误判为空；
        # 具体角色是否满足 schema 由各自解析器负责。
        if r and r.strip():
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
