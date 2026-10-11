#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""终审测试数据的两处修正（2026-10-03）。

1) 移除临时 DEBUG print（正式跑时不该留在测试里）。
2) JSON 键名纠正：模型契约（pipeline_prompts + _chiefIssues）用的是
   **snake_case `top_issues`**，我初版误写成 camelCase `topIssues`，
   结果 _chiefIssues 读不到 → topIssues 恒为空 → 打回分支永不进入，
   两条「打回」用例假失败。

   这类「测试数据与生产契约不一致」只能靠真跑发现：静态检查看不出键名
   是否与解析器约定相符，而它让整组用例都测不到目标分支。
"""
import io
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "test" / "ai_pipeline" / "ai_pipeline_service_run_test.dart"

text = io.open(SRC, encoding="utf-8", newline="").read()

# 1) 移除临时 DEBUG print：逐行删，避免正则跨行贪婪（首版用了 flags=re.S 的
#    `.*?\);\n`，它把后续内容一起吞掉，导致后面的替换没生效）。
lines = text.split("\n")
out, skip = [], False
for ln in lines:
    if "DEBUG-TEMP" in ln or "ignore: avoid_print" in ln:
        skip = "print(" in ln
        continue
    if skip:
        if ln.rstrip().endswith(");"):
            skip = False
        continue
    out.append(ln)
text = "\n".join(out)

# 2) JSON 键名：模型契约用 snake_case（见 _chiefIssues 与 pipeline_prompts）。
n = text.count("'topIssues':")
text = text.replace("'topIssues':", "'top_issues':")

io.open(SRC, "w", encoding="utf-8", newline="").write(text)
print(f"DEBUG left={'DEBUG-TEMP' in text}; topIssues->top_issues: {n}")
