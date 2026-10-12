#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""编造核查 prompt 的**真机验针**（3 例，直接打真实核查链）。

为什么要有它（2026-10-12）：
    `fabrication_check_prompt` 给「无中生有」补了「本章内首次交代来龙去脉不算问题」的
    豁免（原口径只认前章台账，与修复侧 `fact_fix_prompt` 允许的「在本章内补出来龙去脉」
    互相打架，导致定点修恒被回滚）。prompt 改动的效果**无法离线证明**，故留这个探针：
    以后任何人再动这两侧判据，都应先跑它复核。

它验的是两个方向，缺一不可：
    · 必须**仍判**：真·数字漂移、凭空当既定事实引用（豁免不能变成放水）；
    · 必须**不判**：本章内首次交代来龙去脉（否则定点修永远无法收敛）。

用法：
    python tool/_probe_fact_prompt.py        # 跑全部 3 例
    python tool/_probe_fact_prompt.py 3      # 只跑第 3 例（其台账撤掉「三十年」，
                                             #   避免与样本「三年前」构成人为数字冲突）

判读（2026-10-12 首次验针实测）：
    例 1 → 1 处 number（依据指向台账「利钱另计」，未放水）✅
    例 2 → 2 处 fabricated（依据写明「本章仅以一句带过，未交代谁/何时/为何」——新口径
           确实被采纳：模型开始区分「交代了来龙去脉」与「没交代」）✅
    例 3 → 0 处 ✅（豁免生效；首跑因样本自带数字冲突被判 1 处 number，与豁免无关）
"""
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

for line in (ROOT / ".env.local").read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

import novel_pipeline as np  # noqa: E402

np.setup_keys()  # 必须显式调用：否则各链槽位 key 为空 → 全线 401 Forbidden

REGISTRY = {
    "characters": [
        {"name": "微生辞", "identity": "镇河渊外门弟子", "first_seen": 1, "note": ""},
        {"name": "周显", "identity": "外门执事，掌库房底账", "first_seen": 2, "note": ""},
    ],
    "facts": [{"value": "四两七钱", "first_seen": 1}, {"value": "三十年", "first_seen": 3}],
}
STATE_TRACK = "微生辞欠周显灵石账四两七钱及利钱（利钱另计，未计入四两七钱）。"

CASES = [
    ("必须仍判｜数字漂移（把「利钱另计」说成「连本带利」）",
     "周执事查了库房底账，你爹当年欠的那笔灵石账，连本带利，月底要还四两七钱。"
     "还不上，签卖身契，去镇河渊矿场挖三十年煞石。",
     "期望：判出 number 类漂移（豁免不得把这条放过去）"),
    ("必须仍判｜凭空当既定事实引用（前文从未提及，且没交代来龙去脉）",
     "他取出师父玄阳真人留下的《九转归元剑谱》，当年门中巨变，全靠这本剑谱他才活下来。",
     "期望：判出 fabricated 类（无出处、无从属交代）"),
    ("必须不判｜本章首次交代来龙去脉（谁/何时/为何/在哪都在本节内）",
     "三年前的那个雨夜，周显在碎星谷替微生辞挡下一记雷劫，右臂自此落下暗伤；"
     "他从不提这件事，只在每次收租时把价码往上抬一分。",
     "期望：不判（属「本章首次确立」，旧口径会误判为无中生有）"),
]

ONLY = sys.argv[1] if len(sys.argv) > 1 else ""
if ONLY == "3":
    # 只跑第 3 例时撤掉台账里的「三十年」：它与样本的「三年前」构成一个**人为**的
    # 数字冲突（三十年 vs 三年前），会把豁免的干净验证搅浑。
    REGISTRY = {"characters": REGISTRY["characters"],
                "facts": [{"value": "四两七钱", "first_seen": 1}]}
    CASES = [CASES[2]]

print("=" * 70)
for i, (label, text, expect) in enumerate(CASES, 1):
    print("\n[%d] %s" % (i, label))
    print("    %s" % expect)
    t0 = time.time()
    hits = np.run_fact_check(REGISTRY, STATE_TRACK, text, 3)
    dt = time.time() - t0
    if hits is None:
        print("    → 核查未跑成（error）%.0fs" % dt)
    elif not hits:
        print("    → 0 处（未判出）%.0fs" % dt)
    else:
        for h in hits:
            print("    → ⚠ [%s] %s ｜依据：%s"
                  % (h.get("type"), str(h.get("claim"))[:40], str(h.get("evidence"))[:60]))
        print("    （共 %d 处，%.0fs）" % (len(hits), dt))
    if i < len(CASES):
        time.sleep(5)
print("\n" + "=" * 70)
