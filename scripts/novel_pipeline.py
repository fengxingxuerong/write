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

本文件已按职责拆分为兄弟模块（用转发导入保持 `import novel_pipeline as np` 的
对外契约不变，见下方各 import 块）：
  pipeline_llm       LLM 调用层 + 角色槽位配置 / 健康池 / 故障转移
  pipeline_prompts   各角色提示词（纯字符串构建，无 I/O、无网络）
  pipeline_quality   纯规则质检 / 采纳 / 文本卫生（无网络）
  pipeline_state     断点续传状态读取（纯 I/O）
  foreshadow         伏笔台账 / 跨章状态清单
本文件只保留**触网编排**（main / generate_appended_chapter / fact_check_stage /
plan_scenes_or_fallback …）——它们调用 call_chain / llm_call 等被打桩的符号，
搬走会让测试补丁落空、静默发真网络请求，故一律原位。
"""
import argparse
import json
import os
import re
import sys
import time

# urllib 不是本文件的残留——它是 llm_call 打桩的**注入点**。
# scripts/test_chain_diversity.py 用 patch.object(np.urllib.request, "urlopen")
# 截获实发 payload，验证「max_tokens 取调用方传参而非槽位配置」
# （2026-09-30 规划死循环的根因：诊断打印槽位 8000、实发只有 4000，日志与真实
# 请求对不上，误导定位半天）。删掉它会让该回归护栏报 AttributeError 而红。
import urllib.request  # noqa: F401 —— 经 np.urllib.request 动态访问，静态分析看不到
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# ============================================================
# LLM 调用层 + 角色槽位配置（2026-10-03 从本文件拆出）
# ============================================================
# 转发导入而非直接定义，是为了让调用点（本文件 main / generate_appended_chapter /
# 以及仓库内 16 个 `import novel_pipeline as np` 的测试与探针脚本）都无需改动
# ——拆分只降低维护成本，不该顺手制造调用方迁移。槽位常量是**可变对象**，
# 这里不做任何拷贝，调用方原地改动与拆分前完全一致。
import pipeline_llm as _llm  # noqa: E402

# 注：原先此处 import quality_rules_generated as _gen，已于2026-10-03 移除——
# 阈值随 LLM 调用层搬到 pipeline_llm.py 并由下方 from pipeline_llm import 转发，
# 本文件不再直接引用生成物，留着会触发 ruff F401（CI 的 ruff --select=F 会红）。
from fanqie_prompts import first_screen_rewrite_prompt, pack_prompt  # noqa: E402
from fanqie_review import (
    ending_ev_fragment,  # noqa: E402
    extract_world_terms,
    fix_prompt,
    local_hook_fallback,
    patch_gate,
    review_chapter,
)

# 伏笔台账 / 跨章状态清单（2026-10-03 从本文件拆出）。
# 转发导入而非直接定义，是为了让调用点（generate_appended_chapter / main 等）
# 与外部测试都无需改动——拆分只降低维护成本，不该顺手制造调用方迁移。
from foreshadow import (  # noqa: E402,F401
    check_open_foreshadows,
    foreshadow_extract_prompt,
    load_foreshadow,
    save_foreshadow,
    save_state_track,
    scan_used_protagonist_names,
)
from generate_novel import (
    SYSTEM_PROMPT,
    append_state,
    count_words,
    export_txt,
    extract_registry_prompt,
    facts_block,
    fingerprint_distance,
    has_ending_hook,
    hook_for,
    load_state,
    load_style_block,
    merge_facts,
    merge_registry,  # noqa: E402
    parse_json_from_llm,
    payoff_drought_ev_fragment,
    planning_prompt_idea,
    quality_check,
    registry_block,
    release_ev_fragment,
    scene_planning_prompt,
    scene_prompt,
    side_reaction_per_thousand,
    style_ev_fragment,
    style_fingerprint,
    surge_per_thousand,
    thrill_per_thousand,
)
from pipeline_llm import (  # noqa: E402,F401
    # 私有符号同样要转发：健康池既是跨函数共享状态（.clear() 复位），
    # 也是测试直接操作的把手（pipeline._HEALTH.clear()）。
    _HEALTH,
    AMD,
    CHIEF_EDITOR_CHAIN,
    COOLDOWN_SECONDS,
    EDITOR_CHAIN,
    EDITOR_MIN_RATIO,
    FORESHADOWER,
    NVIDIA,
    OUTLINE_REVIEWER_CHAIN,
    PLANNER,
    PLANNER_CHAIN,
    READER_PROXY,
    SENSE,
    STATE_EXTRACTOR,
    THINKING_FLOOR_TOKENS,
    THRILL_DIRECTOR,
    TITLER,
    VERIFIER_CHAIN,
    WORLD_GUARDIAN,
    WORLD_GUARDIAN_CHAIN,
    WRITER_CHAIN,
    _health_key,
    _in_cooldown,
    _key,
    _mark_fail,
    _mark_ok,
    dedup_scene_join,
    llm_call,
    scene_budget,
    setup_keys,
)

# ============================================================
# 各角色提示词（Prompt）（2026-10-10 从本文件拆出 -> pipeline_prompts.py）
# ============================================================
# 转发导入而非直接定义，是为了让调用点（本文件 main / generate_appended_chapter
# 及仓库内 16 个 `import novel_pipeline as np` 的测试与探针脚本）零改动——
# 拆分只降低维护成本，不改对外契约；函数体逐字搬运、未改写。
from pipeline_prompts import (  # noqa: E402,F401
    EDITOR_SYS,
    FACT_CHECK_SYS,
    OUTLINE_REVIEWER_SYS,
    PLANNER_SYS,
    TITLER_SYS,
    VERIFIER_SYS,
    chief_editor_prompt,
    chief_rewrite_prompt,
    editor_prompt,
    fabrication_check_prompt,
    fact_fix_prompt,
    outline_review_prompt,
    payoff_repair_prompt,
    quality_review_prompt,
    reader_proxy_prompt,
    rewrite_prompt,
    state_extract_prompt,
    structure_fix_prompt,
    titler_prompt,
    verifier_prompt,
    verify_promises_prompt,
)

# ============================================================
# 纯规则质检 / 采纳 / 文本卫生（2026-10-10 从本文件拆出 -> pipeline_quality.py）
# ============================================================
# 转发导入而非直接定义，是为了让调用点（本文件 main / generate_appended_chapter
# 及仓库内 16 个 `import novel_pipeline as np` 的测试与探针脚本）零改动——
# 拆分只降低维护成本，不改对外契约；函数体逐字搬运、未改写。
from pipeline_quality import (  # noqa: E402,F401
    PAYOFF_SCENE_KEYS,
    _merge_chief_samples,
    _splice_head,
    accept_payoff_repair,
    apply_promise_closures,
    apply_text_patch,
    build_promise_block,
    dedup_chapter,
    extract_chapter_hook,
    fallback_scenes,
    is_payoff_scene,
    needs_fix,
    needs_payoff_repair,
    payoff_scene_constraint,
    refresh_hook_review,
    trailing_drought_len,
    verdict_from_score,
)

# ============================================================
# 断点续传状态读取（2026-10-10 从本文件拆出 -> pipeline_state.py）
# ============================================================
# 转发导入而非直接定义，是为了让调用点（本文件 main / generate_appended_chapter
# 及仓库内 16 个 `import novel_pipeline as np` 的测试与探针脚本）零改动——
# 拆分只降低维护成本，不改对外契约；函数体逐字搬运、未改写。
from pipeline_state import (  # noqa: E402,F401
    apply_chief_rewrites,
    load_reader_feedback,
    load_reviews_from_jsonl,
    load_state_track,
)


def call_chain(chain, system, user, max_tokens):
    """转发到 pipeline_llm.call_chain，并把**本模块的属性**作为注入点传下去。

    为什么必须是包装而不能直接 `from pipeline_llm import call_chain`：
    既有测试用 `patch.object(pipeline, "llm_call", ...)` / `patch.object(pipeline,
    "_in_cooldown", ...)` 打桩来短路网络。若 call_chain 直接被转发，它内部会
    解析 pipeline_llm 自己的全局名，补丁打在 novel_pipeline 的属性上完全无效
    ——测试不会报错，而是**真的发网络请求**（或断言假绿）。这正是拆分子模块时
    最隐蔽的语义漂移，故此处显式把本模块的名字接进去。
    """
    return _llm.call_chain(chain, system, user, max_tokens,
                           _call=llm_call, _in_cooldown_=_in_cooldown)

# ============================================================
# 各角色 Prompt
# ============================================================


# ============================================================
# 补丁卫生：补写/扩写/定点修的产出在拼回正文前必须过闸
# 实测事故（同一本 3 章小样里同时发生）：
#   ① 钩子补写返回「我拿到的指令是补写钩子，不是扩写…」被原样拼进第 1 章末尾；
#   ② 另一章补出「手机屏幕亮了。不是短信。」，把玄幻书写成都市悬疑；
#   ③ 第 3 章开头 800 字整块重复两遍（复制粘贴级）。
# 三道防线：patch_gate（指令残留/题材漂移/红线/与正文重复）+ 章纲钩子本地兜底 + 章内去重。
# ============================================================
HOOK_FALLBACK_SIGNALS = ("还没", "突然", "竟然", "不对劲", "盯着", "动静", "浮现", "逼近", "异动")


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
        max_tokens=THINKING_FLOOR_TOKENS)
    ok, why = patch_gate(add, base_text=final_text, genre=genre, max_words=160)
    if ok:
        print(f"  [钩子{tag}] 已补写钩子：{add.strip()[:40]}...")
        return final_text.rstrip() + "\n\n" + add.strip(), "llm"
    print(f"  [钩子{tag}] LLM 补写被拒（{why}）→ 改用章纲钩子本地兜底")
    fb = local_hook_fallback(hook_hint, protagonist, genre)
    if fb:
        if not any(s in fb for s in HOOK_FALLBACK_SIGNALS):
            fb = fb.rstrip("。") + "——他还没看清那是什么。"
        # 兜底产出同样要过补丁卫生闸：旧实现只审 LLM 补写，本地兜底是盲区，
        # 大纲标注就是这么漏进成书的（实测「威胁逼近（……）」落进第 1 章末尾）。
        ok2, why2 = patch_gate(fb, base_text=final_text, genre=genre, max_words=160)
        if ok2:
            print(f"  [钩子{tag}] 本地兜底：{fb[:40]}")
            return final_text.rstrip() + "\n\n" + fb, "local"
        print(f"  [钩子{tag}] 本地兜底被拒（{why2}）→ 保留原文，章末无钩需人工补")
        return final_text, ""
    print(f"  [钩子{tag}] 无可用兜底素材，保留原文")
    return final_text, ""


# ============================================================
# 关卡 5 · 编造核查（投前五关最后一关，2026-09-23）
# ============================================================
# 与写手不同模型家族独立核查（写手主位 dsf/DeepSeek → 核查走规划官 glm 链），
# 对照户籍表/数字台账/跨章状态，抓「身份换人 / 数字漂移 / 状态矛盾 / 无中生有」。
# 必须在户籍表更新前调用——核查的是「本章 vs 前章已确立事实」。
# 核查预算（2026-09-26 门禁 v7 实锤修复）：PLANNER_CHAIN 主位是思考型 glm-5.2，
# 原固定 3000 预算下「思考链吃满 → 正文为空 → 整章核查记 error」三章复发，直接把门禁
# 第 16 项判负。逐档重试：8000（与链定义同档）→ 16000（仍被吃满时的最后一道）。
FACT_CHECK_BUDGETS = (8000, 16000)


def run_fact_check(registry, state_track, final_text, idx):
    """关卡 5 · 编造核查：规划官 glm 链（与写手 dsf/DeepSeek 异家族）独立核查。

    返回 fabrication 列表；核查未跑成（异常/空输出/不合 schema）返回 **None**，
    由调用方记 error——「没跑成」绝不当「没问题」（门禁第 16 项据此判 FAIL）。
    预算按 FACT_CHECK_BUDGETS 逐档重试，防思考型模型吃满 max_tokens 造成静默失效。
    """
    prompt = fabrication_check_prompt(final_text, registry, state_track, idx)
    for attempt, budget in enumerate(FACT_CHECK_BUDGETS, start=1):
        try:
            raw = call_chain(PLANNER_CHAIN, FACT_CHECK_SYS, prompt, max_tokens=budget)
            parsed = parse_json_from_llm(raw)
        except Exception:
            parsed = None
        if isinstance(parsed, dict) and isinstance(parsed.get("fabrications"), list):
            return [item for item in parsed["fabrications"] if isinstance(item, dict)]
        if attempt < len(FACT_CHECK_BUDGETS):
            print(f"    [核查] 预算 {budget} 未取到合法 JSON（思考链吃满/解析失败），"
                  f"提到 {FACT_CHECK_BUDGETS[attempt]} 重试")
        else:
            print(f"    [核查] 预算提到 {budget} 仍未取到合法 JSON，本轮核查放弃")
    return None


def fact_check_stage(registry, state_track, final_text, idx, genre):
    """关卡5 全流程：核查 → 命中即定点修 → 复检（台账保持前章口径，绝不回灌自证）。

    返回 (final_text, fabs, record)：
    - fabs 为 None ⇒ 核查未跑成，调用方记 error（门禁据此判 FAIL，不作通过凭据）；
    - 修复只有在**复检命中数下降**时才采纳，否则回滚保留原文与首轮命中——
      「换了段文字」绝不等于「问题解决了」（与评审修同一验收哲学）。
    成本：只在命中时多两次调用（1 次修复 + 1 次复检），0 命中章零额外开销。
    """
    fabs = run_fact_check(registry, state_track, final_text, idx)
    if fabs is None:
        return final_text, None, {"idx": idx, "fabrications": [], "error": True}
    if not fabs:
        print("  [核查] 编造核查通过 ✅（0 处编造）")
        return final_text, [], {"idx": idx, "fabrications": [], "error": False}
    for fb in fabs[:8]:
        desc = f"{fb.get('type', 'fabricated')}: {str(fb.get('claim', ''))[:60]}"
        print(f"  [核查] ⚠ {desc}")
    print(f"  [核查] {len(fabs)} 处编造 → 定点修并复检…")
    try:
        raw_fix = call_chain(EDITOR_CHAIN, SYSTEM_PROMPT,
                             fact_fix_prompt(final_text, fabs, idx),
                             max_tokens=int(count_words(final_text) * 1.6) + 600)
    except Exception:
        raw_fix = ""
    repaired = apply_text_patch(final_text, raw_fix or "", genre, tag="编造修")
    if repaired == final_text:
        print("  [核查] 修复稿未过采纳闸（空产出/过度压缩/补丁卫生），保留原文照记命中")
        return final_text, fabs, {"idx": idx, "fabrications": fabs,
                                  "error": False, "repaired": False}
    fabs2 = run_fact_check(registry, state_track, repaired, idx)
    if fabs2 is not None and len(fabs2) < len(fabs):
        print(f"  [核查] 复检 {len(fabs)} → {len(fabs2)} 处，采纳修复稿"
              f"（{count_words(final_text)} → {count_words(repaired)} 字）")
        return repaired, fabs2, {"idx": idx, "fabrications": fabs2,
                                 "error": False, "repaired": True}
    why = "复检未跑成" if fabs2 is None else f"复检仍 {len(fabs2)} 处"
    print(f"  [核查] {why}、未优于首轮，回滚保留原文（首轮命中照记）")
    return final_text, fabs, {"idx": idx, "fabrications": fabs,
                              "error": False, "repaired": False}


# 外显爽点场景的识别键：规划层 goal 里出现任一即视为爽点场景。


# 场景规划预算：与关卡5 同款教训——规划官链主位是思考型 glm-5.2、链自身 max_tokens=8000，
# 而两处规划调用此前都写死 2000 且**两次重试同预算**。v7 实测 4 章中 3 章「思考链吃满 →
# 正文为空 → 非法 JSON」→ 静默走兜底骨架（见 fallback_scenes docstring）。
SCENE_PLAN_BUDGETS = (8000, 16000)


def plan_scenes_or_fallback(goal, last_summary, state_inject, target, *, protagonist="",
                            genre="", world_hint="", registry="", facts=""):
    """场景规划：按 SCENE_PLAN_BUDGETS 逐档重试，全档失败才退回兜底骨架。

    返回 (scenes, source)：source ∈ {"llm", "fallback"}，随章节记录落盘（scene_plan 字段），
    门禁第 17 项据此统计兜底率——**静默降级必须在报告里可见**。
    失败原因分两类打印（空输出＝思考链吃满/全线失败；非法 JSON＝模型没按格式答），
    v7 只有一句「规划失败」，分不清是预算还是格式问题。
    """
    reason = ""
    for attempt, budget in enumerate(SCENE_PLAN_BUDGETS, start=1):
        try:
            raw = call_chain(PLANNER_CHAIN, PLANNER_SYS,
                             scene_planning_prompt(goal, last_summary, state_inject,
                                                   protagonist=protagonist, genre=genre,
                                                   world_hint=world_hint,
                                                   registry=registry, facts=facts),
                             max_tokens=budget)
        except Exception:
            raw = ""
        plan = parse_json_from_llm(raw)
        if plan and plan.get("scenes"):
            return plan["scenes"], "llm"
        reason = "空输出（思考链吃满/全线失败）" if not raw else "返回非法 JSON 或缺 scenes"
        if attempt < len(SCENE_PLAN_BUDGETS):
            print(f"  [规划] 预算 {budget} 未拿到场景（{reason}），"
                  f"提到 {SCENE_PLAN_BUDGETS[attempt]} 重试")
    print(f"  [规划] LLM 场景规划失败（{reason}），使用默认「起承转合」骨架兜底")
    return fallback_scenes(goal, target), "fallback"


def update_registry(output, registry, final_text, idx):
    """章节定稿后维护配角户籍表/数字台账。

    数字本地零成本（首见即锁定）；身份由 dsf-flash 轻任务提取（失败保留旧表）。
    每次追加 type=registry 落盘（load_state last-wins，断点续传可恢复）。
    """
    merge_facts(registry, final_text, idx)
    try:
        raw = llm_call(STATE_EXTRACTOR, "你是小说设定整理员，只输出 JSON。",
                       extract_registry_prompt(final_text, idx, registry),
                       max_tokens=2000)
        extracted = parse_json_from_llm(raw)
    except Exception:
        extracted = None
    if extracted:
        for cf in merge_registry(registry, extracted, idx):
            print(f"  [户籍] ⚠ 疑似穿帮：{cf}")
    append_state(output, "registry", registry)
    print(f"  [户籍] 户籍表 {len(registry.get('characters', []))} 人 / "
          f"数字台账 {len(registry.get('facts', []))} 条")


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
    registry = ctx.get("registry") or {"characters": [], "facts": []}
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
    scenes, plan_source = plan_scenes_or_fallback(
        goal, trackers["last_summary"], state_inject, target,
        protagonist=ctx["protagonist"], genre=args.genre, world_hint=world_hint,
        registry=registry_block(registry), facts=facts_block(registry))
    print(f"  [规划] {len(scenes)} 场景：{'/'.join(s.get('stage', '承') for s in scenes)}"
          f"（{plan_source}）")

    scene_texts = []
    # 未产出正文的场景序号（1 基），用于成书残缺告警与落库记账。
    lost_scenes = []
    prev_text = trackers["last_summary"]
    for si, sc in enumerate(scenes):
        stage = sc.get("stage", "承")
        goal_s = sc.get("goal", "")
        # 外显爽点硬约束：关键词命中 **或** 位置兜底（后半段「转」）时，
        # 强制写手写出外部可见反应（治执行衰减：fulltest 第5章规划"当众打脸"
        # 但💥词表命中 0.00，写手写成了内心戏；且 goal 仅「20字内」时关键词常缺）。
        if is_payoff_scene(goal_s, stage, si, len(scenes)):
            goal_s += payoff_scene_constraint(goal_s)
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
                                           is_opening=False,
                                           registry=registry_block(registry),
                                           facts=facts_block(registry),
                                           world_terms=ctx["review_world_terms"],
                                           style_block=ctx.get("style_block", "")),
                              max_tokens=scene_budget(tw))
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
        else:
            # 【可观测性 2026-09-30】3 次重试后仍为空 = 该端点/模型整条链都没出
            # 正文（思考链吃满 max_tokens、全部冷却等）。旧实现直接跳过，成书
            # 残缺却无任何痕迹——真机第 4 章 4 个场景丢了 2 个，章纲「禁地借刀」
            # 却成文「暗巷杀机」，整章伪装成正常章节落库，只能靠翻日志才发现。
            lost_scenes.append(si + 1)
            print(f"  [WARN] 场景 {stage} 三次重试仍无正文（端点全链失败），"
                  f"本章将残缺 {len(scene_texts)}/{len(scenes)} 场景")

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
                        editor_prompt(final_text,
                                      style_block=ctx.get("style_block", "")),
                        max_tokens=int(w * 2.0) + 800)
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
        fp = fix_prompt(rv, final_text, ctx["review_world_terms"])
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
    # 评审全字段落盘（与主循环 3.6 同款）：此前只进内存——门禁数不到补章评审分
    # （run10 实战：4 章书仅 2 章"评审有效"假警报），断点续传后评估卡/终审也会丢补章评审
    append_state(args.output, "review", dict(rv))

    final_text = dedup_chapter(final_text, idx)

    # 关卡5 编造核查（与主循环同款：户籍表更新前、glm 与写手异家族独立核查；
    # 命中即定点修并复检，台账口径保持前章、绝不回灌自证）
    fab_issues = []
    if not args.no_fact_check:
        final_text, fabs, fact_record = fact_check_stage(
            registry, trackers["state_track"], final_text, idx, args.genre)
        append_state(args.output, "fact_check", fact_record)
        if fabs is None:
            print("  [核查] ⚠ 编造核查执行失败（记 error，不算通过凭据）")
        else:
            for fb in fabs[:8]:
                desc = f"{fb.get('type', 'fabricated')}: {str(fb.get('claim', ''))[:60]}"
                fab_issues.append({"type": "fabrication", "desc": desc})

    record = {"idx": idx, "title": title_ok, "content": final_text,
              "words": count_words(final_text), "raw_words": w,
              "scenes": len(scenes), "scene_plan": plan_source,
              # 场景残缺记账（2026-09-30，可观测性）：与 Dart 端
              # PipelineChapter.scenesPlanned/scenesWritten 同名同义。
              "scenes_planned": len(scenes),
              "scenes_written": len(scenes) - len(lost_scenes),
              "lost_scenes": lost_scenes,
              "issues": fab_issues, "chief_structural": True}
    # 成书残缺告警写进 issues 随章节落盘，而不是只留在运行日志里
    if lost_scenes:
        record["issues"].append({
            "type": "lost_scenes",
            "desc": f"{len(lost_scenes)}/{len(scenes)} 个场景未产出正文"
                    f"（端点全链失败），本章内容残缺，标题与章纲可能对不上，"
                    f"建议重跑本章或人工补写",
        })
    if promise_results:
        n_ok = sum(1 for r in promise_results if r.get("fulfilled"))
        record["issues"].append({"type": "promise_check",
                                 "desc": f"必兑现清单 {n_ok}/{len(promise_results)} 条伏笔兑现"})
        append_state(args.output, "promise_check",
                     {"idx": idx, "results": promise_results, "promise_block": promise_block})
    state["chapters"].append(record)
    append_state(args.output, "chapter", record)
    # 户籍表/数字台账更新（收尾章同样入册，供后续三审与下一本书借鉴）
    update_registry(args.output, registry, final_text, idx)
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
                         max_tokens=THINKING_FLOOR_TOKENS)
        if add and len(add.strip()) > 10:
            final_text = final_text.rstrip() + add.strip()
            repaired = True
            print(f"  [补全] 已补全 {count_words(add)} 字，当前 {count_words(final_text)} 字")
        else:
            print("  [补全] 补全失败，保留原文")
            break
    return final_text, repaired


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
    # max_tokens=12000：与 OUTLINE_REVIEWER_CHAIN 槽位配置对齐。槽位注释明写
    # 「思考链+修订版大纲全量 JSON 曾吃满 8000 致截断」，但此处曾硬编码 8000 覆盖
    # 槽位的 12000（call_chain 的调用方传参优先）——即配了 12000 却一直按 8000 跑，
    # pro 思考链吃满→正文空→退回 glm，glm 同样吃满→守门静默失效。真机
    # （verify_effect 第 35 节）实测复现，诊断日志「实发 8000 / 槽位配 12000」。
    raw = call_chain(OUTLINE_REVIEWER_CHAIN, OUTLINE_REVIEWER_SYS,
                     outline_review_prompt(outline, genre, total_words, max_chapters),
                     max_tokens=12000)
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


# ============================================================
# 跨章状态持久化（写入 jsonl 的 type=state_track 行）


# ============================================================
# 主线
# ============================================================


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
    raw = call_chain(PLANNER_CHAIN, PLANNER_SYS, ask, max_tokens=THINKING_FLOOR_TOKENS)
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


def render_eval_card(title, genre, reviews, chapters):
    """渲染番茄过审评估卡正文（纯函数：不读文件、不发网络、无副作用）。

    从 main() Phase 5 内联块提取，使其获得直接单测覆盖。输出结构：
    1) 书名标题行；
    2) 成书残缺告警（若有）——**排在均分之前**，避免内容半残的章节
       （标题与章纲对不上）被正常均分掩盖；
    3) 题材 / 章节数 / 评审均分 / 阻断级硬伤章数汇总；
    4) 逐章明细：评分、字数、阻断项、问题项、红线（veto）。

    参数：
        title:    书名（可为空字符串）。
        genre:    题材（写入汇总行）。
        reviews:  review_chapter() 结果列表，每项含 idx/score/verdict/
                  words/blockers/problems/redline 等键（缺失键一律安全回退）。
        chapters: state["chapters"]，用于按 scenes_written/scenes_planned
                  判定「成书残缺」章节（端点全链失败导致场景丢失的章节）。
    返回：评估卡完整文本（以换行结尾，直接写入 .评估卡.txt）。
    """
    n_block = sum(1 for r in reviews if r.get("blockers"))
    # 成书残缺汇总（2026-09-30 可观测性）：端点全链失败导致场景丢失的章，
    # 必须在评估卡顶部显式列出——这类章的标题与章纲对不上、内容半残，
    # 却能拿正常评分伪装成好章。放在最前面，不允许被均分淹没。
    lost_chapters = [c for c in chapters
                     if int(c.get("scenes_written", c.get("scenes", 0)) or 0)
                     < int(c.get("scenes_planned", c.get("scenes", 0)) or 0)]
    out = []
    out.append(f"《{title}》 番茄过审评估卡\n")
    # 残缺告警排在**均分之前**：残缺章的评分本身没有意义
    # （内容半残、标题与章纲对不上），让读者先看均分会以为这本书质量正常。
    if lost_chapters:
        out.append(f"⛔ 成书残缺告警：{len(lost_chapters)} 章有场景未产出正文"
                   f"（端点全链失败），这些章内容不完整、标题与章纲可能对不上，"
                   f"其评分不代表真实质量，须重跑或人工补写：\n")
        for c in lost_chapters:
            planned = int(c.get("scenes_planned", c.get("scenes", 0)) or 0)
            written = int(c.get("scenes_written", planned) or 0)
            out.append(f"    第 {c.get('idx')} 章：{written}/{planned} 场景"
                       f"（{c.get('title', '')}）\n")
        out.append("\n")
    out.append(f"题材：{genre}｜章节：{len(reviews)}｜评审均分："
               f"{round(sum(r['score'] for r in reviews) / max(len(reviews), 1), 1)}\n")
    out.append(f"阻断级硬伤章数：{n_block}（有阻断项即不给「可投」，先按下列清单定点修）\n\n")
    for r in reviews:
        out.append(f"第 {r['idx']} 章  {r.get('score', '-')} 分  {r.get('verdict', '')}｜{r.get('words', 0)} 字\n")
        if r.get("blockers"):
            out.append(f"    ⛔ 阻断项：{'、'.join(r['blockers'])}\n")
        for pr in r.get("problems") or []:
            out.append(f"    [{pr['action']}] {pr['type']}：{pr['msg']}\n")
        for h in (r.get("redline") or {}).get("veto") or []:
            out.append(f"    ☠ 红线（{h['category']}）「{h['word']}」 上下文：{h['context']}\n")
    return "".join(out)


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
    p.add_argument("--no-projection", action="store_true",
                   help="不导出随书 Markdown 投影（当前状态/伏笔台账/控制面）")
    p.add_argument("--skip-amd", action="store_true",
                   help="跳过 AMD/NVIDIA 链路，直接走商汤（AMD 持续限流时用）")
    p.add_argument("--no-chief-review", action="store_true",
                   help="收官后跳过终审官总评（省配额；默认开启终审）")
    p.add_argument("--no-outline-review", action="store_true",
                   help="跳过大纲终审官写前守门（默认开启；守门岗失败不阻塞生成）")
    p.add_argument("--no-reader-proxy", action="store_true",
                   help="跳过读者官每章追读反馈（默认开启；反馈注入下一章场景规划）")
    p.add_argument("--no-fact-check", action="store_true",
                   help="跳过关卡5 编造核查（默认每章开启，规划官 glm 链与写手异家族独立核查）")
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
    p.add_argument("--style-ref", default="",
                   help="文风参考 txt 路径：提取文风指纹注入写手场景 prompt，"
                        "向参考文分布收敛（只学节奏与密度，禁抄句子/情节，"
                        "逐章打印与参考文的指纹距离）")
    args = p.parse_args()
    if args.total_words <= 0 or args.max_chapters <= 0:
        p.error("--total-words 与 --max-chapters 必须为正数")
    if not args.output.strip():
        p.error("--output 不能为空")
    args.output = os.path.abspath(args.output)
    if os.path.isdir(args.output):
        p.error(f"--output 必须是文件路径：{args.output}")
    os.makedirs(os.path.dirname(args.output), exist_ok=True)

    prev_summary = ""
    if args.prev_summary_file and os.path.exists(args.prev_summary_file):
        with open(args.prev_summary_file, encoding="utf-8") as pf:
            prev_summary = pf.read().strip()

    # ===== 文风指纹（P1-1）：--style-ref 模式提取参考文指纹并注入写手 =====
    # 提取逻辑与 generate_novel 共用 load_style_block（单一实现防两端漂移）
    STYLE_BLOCK, REF_FP = load_style_block(args.style_ref)
    if REF_FP:
        # 指纹落盘：否则事后无从判断「是否真在向参考文收敛」——注入与否、注入的
        # 是什么分布，都只能靠翻日志。落的是九项**分布数值**（不含参考文任何
        # 原文），与注入块同源，可被 tool/verify_quality_effect.py 直接读取算收敛。
        append_state(args.output, "style_ref", {
            "source": Path(args.style_ref).name if args.style_ref else "",
            "fingerprint": REF_FP,
            "block": STYLE_BLOCK,
        })
        print("  [文风] 指纹已落盘（type=style_ref），可供事后算收敛")

    setup_keys()
    if args.skip_amd:
        # 跳过 AMD：把 AMD 链路预标记为冷却（call_chain 自动跳过，纯商汤/NVIDIA 路由）。
        # 按 **url 判 AMD** 而非硬编码下标——2026-09-29 给规划链插入 dsf 槽后
        # 下标整体后移，原来的 PLANNER_CHAIN[3] 会指向商汤槽，把商汤误标成冷却
        # （等于自己把自己踢下线）。下标硬编码在链变动时必错，按特征选才不会。
        amd_providers = [p for chain in (PLANNER_CHAIN, WRITER_CHAIN,
                                         EDITOR_CHAIN, VERIFIER_CHAIN,
                                         CHIEF_EDITOR_CHAIN)
                         for p in chain if p.get("url") == AMD]
        for p in amd_providers:
            _HEALTH[_health_key(p)] = {"fails": 3, "cooldown_until": time.time() + 24 * 3600, "hits": 0}
        print(f"[INFO] --skip-amd：跳过 {len(amd_providers)} 个 AMD 链路，纯商汤/NVIDIA 路由")
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
        # max_tokens=12000：与大纲终审官 OUTLINE_REVIEWER_CHAIN 对齐。此前此处
        # 硬编码 4000，把各槽位配的 8000 整个覆盖，思考链模型必然「吃满→正文空」，
        # 规划死循环。真机日志曾 misleading 显示「吃满 8000」（诊断打印的是槽位
        # 配置而非实发值），故此前一直没定位到真因。详见 PLANNER_CHAIN 处注释。
        plan_text = ""
        for attempt in range(2):
            plan_text = call_chain(PLANNER_CHAIN, PLANNER_SYS,
                                   planning_prompt_idea(args.total_words, prev_summary, genre=args.genre,
                                                        used_names=scan_used_protagonist_names()),
                                   max_tokens=12000)
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

    # 配角户籍表/数字台账：断点恢复（load_state 回放最后一条 type=registry）；
    # 每章定稿后更新，场景规划/写手强注入——防跨章身份漂移与数字漂移（2026-09-22 事故复盘）
    registry = state.get("registry") or {"characters": [], "facts": []}
    if registry.get("characters") or registry.get("facts"):
        print(f"[RESUME] 户籍表 {len(registry.get('characters', []))} 人 / "
              f"数字台账 {len(registry.get('facts', []))} 条")

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
        # write_state_main 必须先给默认值——7a319d3 曾只在内层 if 赋值，
        # 无超时伏笔时（如第 1 章）直接 UnboundLocalError（2026-09-23 冒烟实锤）
        write_state_main = state_track
        if promise_block_main:
            state_inject = (state_inject + "\n\n" + promise_block_main) if state_inject else promise_block_main
            print(f"  [承诺] 超时伏笔必兑现清单 {promise_block_main.count(chr(10))} 条注入场景规划与写手")
            write_state_main = (state_track + "\n\n" + promise_block_main) if state_track else promise_block_main
        scenes, plan_source = plan_scenes_or_fallback(
            goal, last_summary, state_inject, target, protagonist=protagonist,
            genre=args.genre, world_hint=world_hint,
            registry=registry_block(registry), facts=facts_block(registry))
        print(f"  [规划] {len(scenes)} 场景：{'/'.join(s.get('stage','承') for s in scenes)}"
              f"（{plan_source}）")

        # 2) 逐场景正文（writer，带故障转移）
        scene_texts = []
        prev_text = last_summary
        for si, sc in enumerate(scenes):
            stage = sc.get("stage", "承")
            goal_s = sc.get("goal", "")
            # 外显爽点硬约束：关键词命中 **或** 位置兜底（后半段「转」）时，
            # 强制写手写出外部可见反应（治执行衰减：fulltest 第5章规划"当众打脸"
            # 但💥词表命中 0.00，写手写成了内心戏；且 goal 仅「20字内」时关键词常缺）。
            if is_payoff_scene(goal_s, stage, si, len(scenes)):
                goal_s += payoff_scene_constraint(goal_s)
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
                                               is_opening=(idx == 1 and si == 0),
                                               registry=registry_block(registry),
                                               facts=facts_block(registry),
                                               world_terms=review_world_terms,
                                               style_block=STYLE_BLOCK),
                                  max_tokens=scene_budget(tw))
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
                                 max_tokens=THINKING_FLOOR_TOKENS)
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
        edited = call_chain(EDITOR_CHAIN, EDITOR_SYS,
                            editor_prompt(full_text, style_block=STYLE_BLOCK),
                            max_tokens=int(w * 2.0) + 800)
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
        # 2026-10-12：由单槽位 llm_call 改走 call_chain——原 pro 单点在下架后
        # 返回空即静默失声（连告警都不打印），改链后自动落到 glm 备胎。
        issues = []
        if idx % 5 == 0 and state["chapters"]:
            chap_list = "\n".join(f"第{c['idx']}章《{c.get('title','')}》" for c in state["chapters"][-5:])
            v = call_chain(WORLD_GUARDIAN_CHAIN, VERIFIER_SYS, verifier_prompt(outline, chap_list), max_tokens=6000)
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
                # 全书 💥 序列：只喂最近 5 章时，长跑断供带（可达 18 章）对总监不可见，
                # 处方会一直说「节奏紧凑」——补一份跨章连低事实。
                _all_thrill = [thrill_per_thousand(c["content"], args.genre)
                               for c in state["chapters"]]
                _all_side = [side_reaction_per_thousand(c["content"])
                             for c in state["chapters"]]
                _drought = payoff_drought_ev_fragment(_all_thrill,
                                                      side_per_k=_all_side)
                _drought_line = (f"\n【外显爽点断供事实】{_drought}\n"
                                 if _drought else
                                 "\n【外显爽点断供事实】无连续 3 章以上断供 ✅\n")
                tdiag = llm_call(THRILL_DIRECTOR,
                                 "你是一位网文节奏总监，专诊爽点分布与追读危机。",
                                 f"以下 5 章爽点密度（💥直白/✨变强异动，每千字）：\n{chr(10).join(thrills)}\n"
                                 f"全书共 {len(_all_thrill)} 章。{_drought_line}"
                                 f"题材：{args.genre}。请判断：1)💥外显爽点是否已断供（✨高不代表爽点够，"
                                 f"读者要的是打脸/收获/揭露这类外显兑现）；2)下一章建议的爽点类型与位置。"
                                 f"30 字内回答。", max_tokens=1000)
                if tdiag and tdiag.strip():
                    print(f"  [节奏] {tdiag.strip()[:120]}")
                    if _drought:
                        print(f"  [断供] {_drought}")

        # 6) 语义质量评分（每 3 章，审校链 pro 主/glm 备）+ 低分自动重写（editor）
        # 注意：max_tokens 必须 ≥6000——pro 思考链实测烧 2000-2900，给小了正文必空（旧值 1000 曾致评分永久静默失效）
        if idx % 3 == 0:
            # 本地质检证据注入：LLM 评审带证据打分，不与规则引擎矛盾（治「100 分无钩子」分裂）
            _style_ev = style_ev_fragment(REF_FP, final_text)
            # 外显爽点断供：跨章 💥 连低证据（单章看不出，必须带历史窗口）
            _drought_ev = payoff_drought_ev_fragment(
                [thrill_per_thousand(c["content"], args.genre)
                 for c in state["chapters"]],
                side_per_k=[side_reaction_per_thousand(c["content"])
                            for c in state["chapters"]])
            qa_ev = (f"章末钩子检测：{'命中 ✅' if has_ending_hook(final_text) else '未命中 ❌（hook 维度不应高于 40 分）'}；"
                     f"直白爽点 {thrill_per_thousand(final_text, args.genre)}/千字；"
                     f"变强异动 {surge_per_thousand(final_text, args.genre)}/千字；"
                     f"侧面反响 {side_reaction_per_thousand(final_text)}/千字；"
                     f"{release_ev_fragment(final_text)}；"
                     f"{ending_ev_fragment(final_text)}"
                     + (f"；{_drought_ev}" if _drought_ev else "")
                     + (f"；{_style_ev}" if _style_ev else ""))
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
            fp = fix_prompt(rv, final_text, review_world_terms)
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
                # 补写后必须同步刷新评审记录：评审（3.6）早于本节落盘，若不刷新，
                # jsonl 会留下「正文有钩 / 评审 blockers 说无钩」的矛盾，门禁据此判
                # 阻断级硬伤章 FAIL（2026-10-12 v8b 实测第 1 章，正文明明是强钩）。
                # 重新 append 一份 review，靠 load_reviews_from_jsonl 的 last-wins 覆盖。
                if reviews:
                    _rv_fixed, _removed = refresh_hook_review(reviews[-1])
                    if _removed:
                        reviews[-1] = _rv_fixed
                        append_state(args.output, "review", dict(_rv_fixed))
                        print(f"    [钩子终检] 已同步刷新评审记录"
                              f"（摘除 {len(_removed)} 条钩子结论，分数/判档不动）")

        # 7.56) 外显爽点补修（跨章断供口径）：与钩子终检同理放在 record 前——
        #       前面的定点修/首屏强化/评审修都可能把 💥 通道改回去，而断供是**跨章**
        #       形态，单章质检看不出来。旧情绪闸门只有「双低」（💥<0.5 且 ✨<1.0），
        #       实测 116 章只触发 7 章，断供带内「低💥但✨高」的 47 章被静默放过。
        #       这里按 needs_payoff_repair 双通道判定，采纳走 accept_payoff_repair
        #       （字数区间 + 户籍完整 + 💥 真的补上），任一不过即保留原文。
        _prev_thrill = [thrill_per_thousand(c["content"], args.genre)
                        for c in state["chapters"]]
        _prev_side = [side_reaction_per_thousand(c["content"])
                      for c in state["chapters"]]
        _drought_n = trailing_drought_len(_prev_thrill, _prev_side)
        _th_now = thrill_per_thousand(final_text, args.genre)
        _sg_now = surge_per_thousand(final_text, args.genre)
        if final_text.strip() and needs_payoff_repair(
                _th_now, _sg_now,
                min_words_ok=count_words(final_text) >= max(
                    500, int(target * 0.5)),
                drought_len=_drought_n,
                side=side_reaction_per_thousand(final_text)):
            why = (f"跨章断供 {_drought_n} 章" if _drought_n >= 3
                   else "单章双低")
            print(f"  [爽点补修] {why}（💥{_th_now}/✨{_sg_now}），触发情绪强化…")
            # 触发即记账（无论成败）：采纳率是本节唯一的量化验证口径，
            # 只记成功会让「触发了 20 次、采纳 0 次」与「一次没触发」无法区分。
            _base_t, _base_s = _th_now, _sg_now
            _pf = call_chain(EDITOR_CHAIN, SYSTEM_PROMPT,
                             payoff_repair_prompt(
                                 final_text,
                                 registry=registry_block(registry),
                                 facts=facts_block(registry),
                                 drought_len=_drought_n),
                             max_tokens=int(count_words(final_text) * 2.2)).strip()
            if not _pf:
                print("    [爽点补修] 无有效产出，保留原文")
                issues.append({"type": "payoff_repair",
                               "desc": f"{why}｜未采纳：模型无有效产出",
                               "ok": False})
            else:
                _pf = apply_text_patch(final_text, _pf, args.genre,
                                       tag="爽点补修")
                if _pf == final_text:
                    # 补丁被 patch_gate 拦下（超长/指令残留/题材漂移/尾部重复）
                    issues.append({"type": "payoff_repair",
                                   "desc": f"{why}｜未采纳：补丁未过卫生闸",
                                   "ok": False})
                else:
                    _ok, _why = accept_payoff_repair(
                        final_text, _pf, registry=registry_block(registry))
                    if _ok:
                        print(f"    [爽点补修] 采纳：{_why}")
                        final_text = _pf
                        issues.append({"type": "payoff_repair",
                                       "desc": f"{why}｜采纳：{_why}",
                                       "ok": True,
                                       "before": f"💥{_base_t}/✨{_base_s}",
                                       "after": _why})
                    else:
                        print(f"    [爽点补修] 未过验收（{_why}），保原文")
                        issues.append({"type": "payoff_repair",
                                       "desc": f"{why}｜未采纳：{_why}",
                                       "ok": False,
                                       "before": f"💥{_base_t}/✨{_base_s}"})

        # 7.6) 章内去重：复制粘贴级的整块重复（实测第 3 章开头 800 字出现两遍）
        final_text = dedup_chapter(final_text, idx)

        # 7.60) 关卡5 编造核查（规划官 glm 链与写手异家族，--no-fact-check 可关）：
        #        必须在户籍表更新前——核查「本章 vs 前章已确立事实」；失败记 error 不算通过凭据；
        #        命中即触发定点修并复检（台账口径不变、绝不回灌自证），last-wins 写盘供门禁第 16 项读取
        if not args.no_fact_check:
            final_text, fabs, fact_record = fact_check_stage(
                registry, state_track, final_text, idx, args.genre)
            append_state(args.output, "fact_check", fact_record)
            if fabs is None:
                print("  [核查] ⚠ 编造核查执行失败（记 error，不作为通过凭据）")
            else:
                for fb in fabs[:8]:
                    issues.append({"type": "fabrication",
                                   "desc": f"{fb.get('type', 'fabricated')}: "
                                           f"{str(fb.get('claim', ''))[:60]}"})

        chapter_record = {
            "idx": idx,
            "title": title_ok,
            "content": final_text,
            "words": count_words(final_text),
            "raw_words": w,
            "scenes": len(scenes),
            "scene_plan": plan_source,
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

        # 7.62) 配角户籍表/数字台账更新（数字本地零成本 + 身份 dsf 轻任务，失败保留旧表）
        #        必须在下一章场景规划前——下一章的 registry 注入依赖本章更新后的表
        update_registry(args.output, registry, final_text, idx)

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
                          reader_proxy_prompt(final_text, args.genre),
                          max_tokens=THINKING_FLOOR_TOKENS)
            if rf and rf.strip():
                reader_hint = rf.strip()
                append_state(args.output, "reader_feedback",
                             {"idx": idx, "feedback": reader_hint})
                first_line = reader_hint.splitlines()[0] if reader_hint.splitlines() else ""
                print(f"  [读者] {first_line[:44]}（反馈已注入下一章规划）")
            else:
                print("  [读者] 反馈获取失败，下一章规划不注入")

        if REF_FP is not None:
            _style_dist = fingerprint_distance(
                REF_FP, style_fingerprint(final_text))
            print(f"  [文风] 本章与参考文指纹距离 {_style_dist}"
                  "（0=同分布，逐章对比看是否收敛）")
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
        rel_flag = {"late_start": "⚠压抑过长", "front_loaded": "⚠前置泄洪"}.get(ch.get("_release"), "✓")
        print(f"  {flag} 第 {ch['idx']} 章：{ch.get('_words',0)} 字｜AI味 {ch.get('_ai_echo_pct',0)}%｜{hook_flag}｜{open_flag}｜落点{rel_flag}")
        if ch.get("_release") == "late_start":
            print("      → 压抑过长（首个爽点晚于全章 60% 才释放，先抑后扬失衡）")
        elif ch.get("_release") == "front_loaded":
            print("      → 爽点前置泄洪（后半段零释放，后半章平铺掉追读）")
        if ch.get("_ending_triad"):
            print(f"      → 章末三件套收尾：命中「{ch['_ending_triad']}」"
                  "（规则20禁止身体异动/发光物件收束）")
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
                       "review_world_terms": review_world_terms, "registry": registry,
                       "style_block": STYLE_BLOCK}
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

    # ===== Phase 4.5：Markdown 人类可读投影（当前状态/伏笔台账/控制面）=====
    # jsonl 是权威账本，投影是只读快照；导出失败只告警，绝不阻塞成书。
    if not args.no_projection:
        try:
            from md_projection import export_projections
            for proj in export_projections(args.output):
                print(f"[OK] 投影：{proj}")
        except Exception as exc:
            print(f"  [WARN] Markdown 投影导出失败（不影响成书）：{exc}")

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
        card_text = render_eval_card(outline.get('title', ''), args.genre,
                                     reviews, state["chapters"])
        with open(card, "w", encoding="utf-8") as f:
            f.write(card_text)
        print(f"[OK] 评估卡：{card}")

        first3 = "\n\n".join(c.get("content", "")[:900] for c in state["chapters"][:3])
        # 预算不覆盖槽位配置：PLANNER 是 glm-5.2（思考链模型），而上架包输入是大纲 + 前三章
        # 全文，思考链会先烧掉大量 token。此前此处写死 max_tokens=1500，实测
        # 「[diag] 思考链有输出但正文为空（实发 1500，槽位配 8000）」→ 上架包生成失败
        # （2026-10-12 门禁 v8b 的 WARN）。与规划位当年那处「调用点覆盖槽位预算」同族，
        # 直接不传，让槽位配置（8000）生效。
        pack_raw = llm_call(PLANNER, PLANNER_SYS, pack_prompt(outline, first3))
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
