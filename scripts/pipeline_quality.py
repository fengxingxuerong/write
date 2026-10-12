#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""纯规则质检 / 采纳 / 文本卫生层：本地判定逻辑，无网络、无 LLM 调用。

2026-10-10 从 novel_pipeline.py 拆出（同批还有 pipeline_prompts / pipeline_state）。
本模块只放**纯函数**：采纳闸（apply_text_patch）、断供判定、爽点场景识别、承诺清单
构造、终审判档、末尾补全切点等——它们不调用 call_chain / llm_call 等被打桩的触网
符号，故可安全搬离本模块。

⚠ 为什么不搬触网函数（本仓库用注释写明的坑）：测试大量用
`patch.object(novel_pipeline, "llm_call"/"call_chain"/"run_fact_check"/"apply_text_patch")`
打桩；函数一旦离开本模块，内部名字解析到新模块全局，补丁落空 → 不报错、静默发真
网络请求。故触网编排函数（main / fact_check_stage / plan_scenes_or_fallback /
generate_appended_chapter …）一律原位保留。

对外接口：调用方仍从 novel_pipeline 取同名转发。拆分红线同 pipeline_llm：只降维护
成本，不改对外契约，函数体逐字搬运。
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fanqie_review import dedup_intra_repeat, patch_gate  # noqa: E402
from generate_novel import (  # noqa: E402
    count_words,
    side_reaction_per_thousand,
    surge_per_thousand,
    thrill_per_thousand,
)
from pipeline_llm import EDITOR_MIN_RATIO  # noqa: E402


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


def trailing_drought_len(thrill_per_k, side_per_k=None, threshold=0.5,
                         side_threshold=0.3):
    """末尾连续「无外显兑现」的章数（不含当前章，判断「已断供多久」）。

    传入**已完成的**前序章序列，返回当前章之前处于断供中的连续长度：
    0 表示上一章有外显兑现（未断供），>=3 表示已连着 3 章以上没有。

    side_per_k 传入时启用侧面反响逃生通道（与 payoff_drought_zones 同口径）：
    某章 💥 低但在场者反应达标 = 外显兑现其实已送达，不计断供。
    """
    n = len(thrill_per_k or [])
    k = 0
    for i in range(n - 1, -1, -1):
        flat = thrill_per_k[i] < threshold
        if flat and side_per_k is not None and i < len(side_per_k):
            flat = side_per_k[i] < side_threshold
        if not flat:
            break
        k += 1
    return k


def needs_payoff_repair(thrill, surge, min_words_ok=True, drought_len=0,
                        threshold=0.5, surge_ok=1.0, drought_min_run=3,
                        side=0.0, side_ok=0.3):
    """本章是否需要「外显爽点」情绪强化修（单章口径 + 跨章断供口径取或）。

    旧口径只有「双低」（thrill<0.5 **且** surge<1.0），实测 14 本成书 116 章里
    只触发 **7 章**——因为 ✨ 含蓄异动恒高（~2.2/千字），双低几乎永不成立，
    真正缺外显爽点的章被静默放过。断供带内的「低💥但✨高」章共 **47 章**漏修。

    两个通道：
    ① 单章双低（保留旧行为，零回归）；
    ② 跨章断供：已处于连续 >=drought_min_run 章 💥 断供带中（drought_len>0）时，
       本章只要 💥 仍 <threshold 就修——不再要求 ✨ 也低。断供带内含蓄流正是
       「读者感觉不到爽」的高发形态，此时补外显兑现正是处方。
       drought_len=0（未传历史）时本通道自动关闭，行为与旧版完全一致。

    min_words_ok 由调用方传字数下限判定（过短章不修：没内容可强化）。

    **side 逃生通道（2026-09-29 真机 A/B 后补）**：若在场者已有明确外部反应
    （侧面反响达标），说明外显兑现其实**已经送达读者**，只是没用 💥 词表里的
    套话词——真机实测确有此类样本（满堂哄笑/全场屏息/众目睽睽，💥=0.0）。
    此时再送修纯属白烧一次 LLM 调用，故直接跳过。side=0.0（未传）时该通道关闭，
    行为与旧版完全一致。
    """
    if not min_words_ok:
        return False
    if side >= side_ok:
        return False
    if thrill < threshold and surge < surge_ok:
        return True
    return bool(drought_len >= drought_min_run) and thrill < threshold


def accept_payoff_repair(original, fix, registry="", min_ratio=0.7, max_ratio=1.6,
                        threshold=0.5, side_ok=0.3):
    """情绪强化稿采纳判定：字数在区间 + 户籍完整 + 💥 真的提升（绝不劣化原文）。

    沿用 `generate_novel` 情绪闸门的三项验收（字数/户籍/指标不劣化），
    补一道**必须真的补上外显爽点**的硬条件：断供带内补修的目的是补 💥，
    若强化稿只把 ✨ 写高而 💥 没动，等于没修——此时拒绝采纳。
    非断供场景（drought_len=0）保持旧语义：💥 或 ✨ 任一提升即采纳。
    """
    o_w, f_w = count_words(original or ""), count_words(fix or "")
    if not (min_ratio * o_w <= f_w <= max_ratio * o_w):
        return False, f"字数越界（{o_w}->{f_w}，允许 {min_ratio}~{max_ratio}）"
    reg = registry or ""
    if reg:
        names = [ln.strip() for ln in reg.splitlines()
                 if ln.strip() and "：" in ln]
        missing = [ln for ln in names
                   if ln.split("：", 1)[0].strip() and
                   ln.split("：", 1)[0].strip() not in fix]
        if missing:
            return False, f"户籍角色丢失（{missing[0].split('：')[0]}）"
    o_t = thrill_per_thousand(original or "")
    f_t = thrill_per_thousand(fix or "")
    o_s = surge_per_thousand(original or "")
    f_s = surge_per_thousand(fix or "")
    o_side = side_reaction_per_thousand(original or "")
    f_side = side_reaction_per_thousand(fix or "")
    # 判定顺序要紧：**先把「侧反达标」记为有效提升**，再看「是否整体没动」。
    # 否则只涨侧反（💥/✨ 都没动）的稿会在下面的「未提升」被提前拒掉——
    # 这正是真机实测的好稿形态（不套话、只有在场者反应）。
    side_ok_gain = f_side >= side_ok and f_side > o_side
    if not side_ok_gain and f_t <= o_t and f_s <= o_s:
        return False, (f"未提升（💥{o_t}->{f_t}｜✨{o_s}->{f_s}"
                       f"｜侧反{o_side}->{f_side}）")
    # 补修的目的是让读者看见外显兑现：💥 仍低于阈值时，**只涨 ✨ 不算数**
    # （那是把「含蓄异动」当外显兑现，正是断供的成因本身）；但若**侧面反响
    # 涨到达标**（在场者确有反应，如惊呼/哗然/脸色铁青），那外显兑现同样成立
    # ——真机实测确有此类不套话的好稿，💥 词表天然抓不到。
    if f_t < threshold and not side_ok_gain:
        return False, (f"未补上外显爽点（💥{f_t}<{threshold}、侧反{f_side}<{side_ok}，"
                       f"仅 ✨{o_s}->{f_s} 不算修好）")
    return True, f"💥{o_t}->{f_t}｜✨{o_s}->{f_s}｜侧反{f_side}｜{f_w}字"


def needs_fix(rv, review_pass):
    """是否需要定点修：不达线，或带阻断级硬伤（分数达线也不能放过）。

    实测事故：第 1 章 92 分但含「元话语残留/字数不足」→ 旧条件只看分数，修复链直接跳过。
    """
    return bool(rv.get("problems")) and (rv.get("score", 0) < review_pass
                                         or bool(rv.get("blockers")))


PAYOFF_SCENE_KEYS = ("外显爽点", "打脸", "当众")


def is_payoff_scene(goal, stage="", si=0, total=0):
    """本场景是否承担「外显爽点」职责（关键词 **或** 位置双通道判定）。

    为什么不能只靠关键词（2026-09-29 实测）：
    ① `scene_planning_prompt` 要求 goal「20字内」，模型很少写满「外显爽点/打脸」
       这类词——14 本真实成书 108 章里仅 **16 章**的 goal 含爽点键，
       于是 novel_pipeline 的写手硬约束几乎永不触发，💥 通道系统性断供；
    ② 规划链失败走 `fallback_scenes` 时，骨架 goal 是固定文案
       （「事件推进，冲突升级」等），关键词更不可能命中。

    故补位置通道：写作准则要求「爽点放在章内后半段、先压后扬」，而场景按
    起承转合顺序排列——**后半段的「转」场景天然是爽点位**。两个通道取或：
    关键词命中照旧（尊重规划层显式意图），位置兜底则保证「每章至少一个
    外显爽点场景」不再依赖模型是否恰好用了那三个词。
    """
    if any(k in (goal or "") for k in PAYOFF_SCENE_KEYS):
        return True
    if not total:
        return False
    # 后半段（进度 >= 55%）且 stage 为「转」——起承转合的第三拍
    return stage == "转" and (si + 1) / total >= 0.55


def payoff_scene_constraint(goal):
    """写手「外显爽点」硬约束文案（两处调用点共用，避免文案漂移）。"""
    return ("【本场景硬约束·外显爽点】这是外显爽点场景：必须写出对手/旁观者的"
            "当众外部反应（脸色骤变、失态、惊呼、修为显化、围观哗然），"
            "禁止只写主角内心感受或含蓄暗示。")


def fallback_scenes(goal, target):
    """场景规划全档失败时的兜底骨架（起承转合，字数按章目标 30/25/25/20 分配）。

    兜底只是「不空转」的底线：场景目标里没有世界/设定锚点，写手只能自己脑补——
    v7 四章里三章走兜底，随后第 1/2/3 章连挂「世界观未落地」、第 2 章 6 处编造。
    小章（target 小）时下限取 min(400, target/4)，避免四段之和反超章目标。
    """
    floor = min(400, max(1, int(target // 4)))
    # 「转」场景定为外显爽点场景：与 scene_planning_prompt「爽点放章内后半段、
    # 压抑不超过 60%」对齐（转 = 第 3/4 个场景，位置天然落在后半段）。
    # 此前兜底骨架**一个爽点场景都没有**——规划链失败走兜底时，
    # 写手的「外显爽点硬约束」（novel_pipeline 按 goal 含「外显爽点/打脸/当众」
    # 触发）永不命中，💥 通道必然断供。实测 14 本书里仅 16/108 章的 goal
    # 含爽点键，而兜底章占其中一部分，这是断供的结构性成因之一。
    return [
        {"index": 0, "stage": "起", "goal": f"场景铺垫：{goal[:30]}", "beats": [],
         "targetWords": max(floor, int(target * 0.3))},
        {"index": 1, "stage": "承", "goal": "事件推进，冲突升级", "beats": [],
         "targetWords": max(floor, int(target * 0.25))},
        {"index": 2, "stage": "转", "goal": "外显爽点：局势逆转，当众打脸或收获到手",
         "beats": [], "targetWords": max(floor, int(target * 0.25))},
        {"index": 3, "stage": "合", "goal": "收束本章并埋下钩子", "beats": [],
         "targetWords": max(floor, int(target * 0.2))},
    ]


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


def refresh_hook_review(rv):
    """钩子终检补写成功后就地刷新该章评审记录——摘掉与钩子相关的结论（纯规则，零 LLM）。

    背景（2026-10-12 冒烟门禁 v8b 实测）：评审在主循环 3.6 处就 `append_state` 落盘了，
    而钩子终检（7.55）发生在其**之后**——补写把钩子放进了正文，却没有任何环节刷新
    评审记录。结果 jsonl 里同时存在两件互相矛盾的事实：
        · 最终正文 `has_ending_hook(final_text)` == True（第 1 章结尾是强钩）；
        · 评审记录 `blockers == ['无章末钩子']`（评审当时看的还是补写前的文本）。
    门禁按评审记录判「阻断级硬伤章」→ FAIL。这是横切机制只接线了一半的典型症状：
    改了正文、没改记录，**数据矛盾本身是唯一可观察的信号**。

    本函数只做「摘除已不成立的钩子结论」，**不动分数与判档**——分数是评审当时的实测，
    补写一轮不构成加分理由（避免为了过门禁而美化分数）。返回 (new_rv, removed)：
    removed 是被摘掉的原描述列表，供调用方打印披露，绝不静默丢证据。
    """
    old_blockers = list(rv.get("blockers") or [])
    removed = [b for b in old_blockers if "钩子" in str(b)]
    new_rv = dict(rv)
    new_rv["blockers"] = [b for b in old_blockers if "钩子" not in str(b)]

    new_problems, removed_problems = [], []
    for p in (rv.get("problems") or []):
        is_hook = "钩子" in str(p.get("type", "")) or "章末钩子" in str(p.get("msg", ""))
        if is_hook:
            removed_problems.append(str(p.get("msg", ""))[:60])
        else:
            new_problems.append(p)
    new_rv["problems"] = new_problems
    removed += removed_problems
    return new_rv, removed
