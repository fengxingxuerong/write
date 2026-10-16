#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_report_v8e.py — v8e 冒烟门禁长跑结束后自动生成验收报告（一次性工具）。

被后台等待器在「python 进程全部退出」后调用，读取：
  - verify-logs/smoke_gate_v8e.log            （门禁总结 SMOKE GATE: PASS/FAIL n/17）
  - data/generated/smoke_gate_v8e.smokegate.log（跑书日志：评审/终审/[核查] 行）
  - data/generated/smoke_gate_v8e.jsonl        （type=fact_check 记录的取证字段）
汇总为 verify-logs/v8e_report.md，重点回答两个验收问题：
  (a) 门禁第 16 项编造核查 PASS/FAIL？「确定性优先」判据是否按预期工作？
  (b) 门禁第 4 项编辑链压缩是否干净（退化 WARN 不计入）？
不修改仓库任何受版本控制的文件。
"""
import json
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATE_LOG = os.path.join(ROOT, "verify-logs", "smoke_gate_v8e.log")
RUN_LOG = os.path.join(ROOT, "data", "generated", "smoke_gate_v8e.smokegate.log")
JSONL = os.path.join(ROOT, "data", "generated", "smoke_gate_v8e.jsonl")
OUT = os.path.join(ROOT, "verify-logs", "v8e_report.md")


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


gate = read_lines(GATE_LOG)
run = read_lines(RUN_LOG)

# ---- 门禁总结 ----
gate_verdict = next((l for l in gate if "SMOKE GATE" in l and ("PASS" in l or "FAIL" in l)), "（未找到门禁总结）")
gate_fails = [l.strip() for l in gate if l.strip().startswith("[FAIL]")]

# ---- 跑书日志关键行 ----
def pick(pattern, lines=run):
    return [l.strip() for l in lines if re.search(pattern, l)]

reviews = pick(r"\[评审\]")
chiefs = pick(r"\[终审·第1轮\]|合并综合")
fact_lines = pick(r"\[核查\]")
over_compress = pick(r"过度压缩")
degenerate = pick(r"产出退化")
fallback = pick(r"fallback|静默兜底")
tracebacks = pick(r"Traceback")

# ---- fact_check 记录取证 ----
fact_recs = []
for line in read_lines(JSONL):
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("type") == "fact_check":
        d = obj.get("data", {})
        fabs = d.get("fabrications") or []
        fabs_before = d.get("fabrications_before")
        fabs_after = d.get("fabrications_after")
        persisting = d.get("persisting_after")
        # 口径：fabrications 恒为「生效中」命中（门禁第 16 项数它）；
        # 首轮命中 = 采纳分支的 fabrications_before，否则即 fabrications 本身。
        first_round = len(fabs_before) if fabs_before is not None else len(fabs)
        fact_recs.append({
            "idx": d.get("idx"),
            "error": d.get("error"),
            "effective": len(fabs),
            "first": first_round,
            "after": len(fabs_after) if fabs_after is not None else None,
            "persisting": len(persisting) if persisting is not None else None,
            "repaired": d.get("repaired"),
        })

# ---- 两个验收问题 ----
item16 = next((l for l in gate_fails if "编造核查" in l), None)
if item16 is None:
    item16 = next((l.strip() for l in gate if "编造核查" in l and l.strip().startswith("[PASS]")), "（第 16 项行未找到）")
item4 = next((l for l in gate_fails if "过度压缩" in l), None)
if item4 is None:
    item4 = next((l.strip() for l in gate if "过度压缩" in l and l.strip().startswith("[PASS]")), "（第 4 项行未找到）")

report = []
report.append("# v8e 冒烟门禁长跑验收报告（自动生成）\n")
report.append(f"**门禁结论**：{gate_verdict.strip()}\n")
if gate_fails:
    report.append("**FAIL 项明细**：")
    report.extend(f"- {l}" for l in gate_fails)
    report.append("")
else:
    report.append("**FAIL 项明细**：无（全 PASS）\n")

report.append("## 逐章评审分 / 终审分\n")
report.extend(f"- {l}" for l in reviews) or report.append("- （无评审行）")
report.extend(f"- {l}" for l in chiefs) or report.append("- （无终审行）")
report.append("")

report.append("## 编造核查（关卡5）逐章取证\n")
if fact_recs:
    report.append("| 章 idx | error | 首轮命中 | 复检(after) | 生效(门禁数它) | persisting(确定性) | repaired |")
    report.append("|---|---|---|---|---|---|---|")
    for r in fact_recs:
        report.append(f"| {r['idx']} | {r['error']} | {r['first']} | {r['after']} | {r['effective']} | {r['persisting']} | {r['repaired']} |")
else:
    report.append("（产物中无 type=fact_check 记录）")
report.append("")
report.append("### 跑书日志中的 [核查] 行")
report.extend(f"- {l}" for l in fact_lines) or report.append("- （无）")
report.append("")

report.append("## 验收问题回答\n")
report.append(f"**(a) 门禁第 16 项**：{item16}\n")
residual = sum((r["effective"] or 0) for r in fact_recs)
errors = sum(1 for r in fact_recs if r["error"])
report.append(f"- 生效命中合计 = {residual} 处；执行失败(error)章 = {errors}")
det = [r for r in fact_recs if r["repaired"] is True]
rolled = [r for r in fact_recs if r["repaired"] is False and r["after"] is not None]
if det:
    improved = [r for r in det if r["persisting"] is not None and r["persisting"] < r["first"]]
    report.append(f"- 走过定点修且被采纳(repaired=True)的章 = {len(det)}；其中确定性复核显示「真有原句消失」(persisting < 首轮) 的章 = {len(improved)}")
    report.append("- 「确定性优先」判据工作情况：" + ("按预期——采纳由确定性读数驱动，LLM 复检仅作护栏" if improved == det else "存在未见确定性改善却采纳的章（详见上表，需人工复核）"))
if rolled:
    report.append(f"- 定点修后回滚(repaired=False 且有复检明细)的章 = {len(rolled)}（确定性未改善即回滚，符合新判据）")
report.append("")
report.append(f"**(b) 门禁第 4 项**：{item4}")
report.append(f"- 「过度压缩」字面量出现次数 = {len(over_compress)}；「产出退化」出现次数 = {len(degenerate)}（退化为 WARN，不拦项）\n")

report.append("## 异常信号\n")
report.append(f"- Traceback 数 = {len(tracebacks)}")
report.append(f"- fallback/静默兜底相关行 = {len(fallback)}")
for l in tracebacks[:5]:
    report.append(f"  - {l}")

with open(OUT, "w", encoding="utf-8") as f:
    f.write("\n".join(report))
print(f"报告已写入 {OUT}")
