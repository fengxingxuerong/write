#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语义硬伤检测 · 关卡1（人称漂移）+ 叙述块切分。

2026-10-10 从 qa_semantic_check.py 拆出。纯本地规则，不触网、不调 LLM。

对外接口：调用方仍从 qa_semantic_check 取同名转发。拆分红线：只降维护成本，
不改对外契约；函数体逐字搬运，未改写。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from qa_text import strip_dialogue  # noqa: E402


FIRST_PRON = ("我", "俺", "咱")


THIRD_PRON = ("他", "她")


POV_MIN_NARR_CHARS = 100   # 引号外叙述字数下限（对话章整块跳过）


POV_MIN_PRON = 5           # 代词总数下限（样本不足不判；《铁掌破风》回测：


POV_FIRST_RATIO = 0.70     # 第一人称代词占比 >= 此值判 first


POV_THIRD_RATIO = 0.30     # 占比 <= 此值判 third


POV_STABLE_RUN = 2         # 稳定段最少块数（切换须持续 >=2 块才报）


def split_blocks(content, block_chars=500):
    """按段落聚合切块，每块约 block_chars 字。分隔线行（————/====）不计入。"""
    paras = [p.strip() for p in content.split("\n")
             if p.strip() and not re.match(r"^[—\-=_*]{3,}$", p.strip())]
    blocks, cur, size = [], [], 0
    for p in paras:
        cur.append(p)
        size += len(p)
        if size >= block_chars:
            blocks.append("\n".join(cur))
            cur, size = [], 0
    if cur:
        blocks.append("\n".join(cur))
    return blocks


def block_pov(block):
    """判定单块叙述人称。返回 (pov, c1, c3) 或 None（样本不足）。"""
    narr = strip_dialogue(block)
    n_chars = len(re.sub(r"\s", "", narr))
    c1 = sum(narr.count(x) for x in FIRST_PRON)
    c3 = sum(narr.count(x) for x in THIRD_PRON)
    if n_chars < POV_MIN_NARR_CHARS or c1 + c3 < POV_MIN_PRON:
        return None
    ratio = c1 / (c1 + c3)
    if ratio >= POV_FIRST_RATIO:
        return ("first", c1, c3)
    if ratio <= POV_THIRD_RATIO:
        return ("third", c1, c3)
    return ("mixed", c1, c3)


def detect_pov_drift(chapters, block_chars=500):
    """检测叙述人称漂移。返回 (events, chapter_summary)。

    判定逻辑：块级人称 → 游程编码 → 仅「连续 >=2 块」的稳定段参与比较，
    相邻稳定段人称不同即记一次切换事件（防对话噪声造成单块抖动误报）。
    """
    events = []
    chapter_summary = []
    for idx, ch_title, content in chapters:
        blocks = split_blocks(content, block_chars)
        n_first = n_third = n_mixed = n_skip = 0
        decided = []  # (block_idx, pov, 首段摘录, c1, c3)
        for bi, blk in enumerate(blocks):
            r = block_pov(blk)
            if r is None:
                n_skip += 1
                continue
            pov, c1, c3 = r
            if pov == "mixed":
                n_mixed += 1
            elif pov == "first":
                n_first += 1
            else:
                n_third += 1
            if pov in ("first", "third"):
                excerpt = blk.strip().split("\n")[0]
                decided.append((bi, pov, excerpt, c1, c3))
        # 游程编码
        runs = []
        for bi, pov, excerpt, c1, c3 in decided:
            if runs and runs[-1]["pov"] == pov:
                runs[-1]["len"] += 1
                runs[-1]["end"] = bi
            else:
                runs.append({"start": bi, "end": bi, "pov": pov,
                             "len": 1, "excerpt": excerpt})
        stable = [r for r in runs if r["len"] >= POV_STABLE_RUN]
        for a, b in zip(stable, stable[1:]):
            if a["pov"] != b["pov"]:
                events.append({
                    "chapter": idx,
                    "chapter_title": ch_title,
                    "from_pov": a["pov"],
                    "to_pov": b["pov"],
                    "pos_ratio": round(b["start"] / max(len(blocks), 1), 2),
                    "excerpt": b["excerpt"][:60],
                })
        chapter_summary.append({
            "idx": idx, "title": ch_title,
            "first_blocks": n_first, "third_blocks": n_third,
            "mixed_blocks": n_mixed, "skipped_blocks": n_skip,
            # 主导判定须过半数且 >=3 块，防独白密集章（first×1 mixed×5）误标第一人称
            "dominant_pov": ("first" if n_first >= 3 and n_first > n_third and
                             n_first * 2 >= n_first + n_third else
                             "third" if n_third >= 3 and n_third > n_first and
                             n_third * 2 >= n_first + n_third else
                             "mixed" if n_first + n_third else "-"),
        })
    return events, chapter_summary
