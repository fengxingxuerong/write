#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 novel_pipeline.py 的「提示词 / 纯规则逻辑 / 状态读取」三块**纯函数**拆成兄弟模块。

一次性（幂等）：按 ast 精确定位顶层符号，逐字搬运（不改函数体），再由
novel_pipeline.py 顶部 `from pipeline_x import (...)` 反向转发，保证
`import novel_pipeline as np` / `from novel_pipeline import Y` 两种用法零改动。

为什么只搬纯函数：仓库大量用 `patch.object(novel_pipeline, "llm_call"/"call_chain"/...)`
打桩；触网函数一旦离开本模块，内部名字解析到新模块全局，补丁落空 → **不报错、
静默发真网络请求**（这是本仓库用注释写明的坑）。故只搬不触网、不引用被打桩符号的纯函数。

用法：python tool/split_pipeline_modules.py
"""
from __future__ import annotations

import ast
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "scripts" / "novel_pipeline.py"

PROMPTS_NAMES = [
    "PLANNER_SYS", "EDITOR_SYS", "TITLER_SYS", "VERIFIER_SYS",
    "OUTLINE_REVIEWER_SYS", "FACT_CHECK_SYS",
    "editor_prompt", "titler_prompt", "verifier_prompt", "quality_review_prompt",
    "rewrite_prompt", "state_extract_prompt", "payoff_repair_prompt",
    "fabrication_check_prompt", "fact_fix_prompt",
    "chief_editor_prompt", "chief_rewrite_prompt", "structure_fix_prompt",
    "outline_review_prompt", "reader_proxy_prompt", "verify_promises_prompt",
]

QUALITY_NAMES = [
    "PAYOFF_SCENE_KEYS", "extract_chapter_hook", "apply_text_patch", "dedup_chapter",
    "trailing_drought_len", "needs_payoff_repair", "accept_payoff_repair", "needs_fix",
    "is_payoff_scene", "payoff_scene_constraint", "fallback_scenes",
    "verdict_from_score", "_merge_chief_samples", "apply_promise_closures",
    "build_promise_block", "_splice_head",
]

STATE_NAMES = [
    "load_reader_feedback", "load_reviews_from_jsonl",
    "apply_chief_rewrites", "load_state_track",
]

PROMPTS_HEADER = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""各角色提示词（Prompt）层：纯字符串构建，无 I/O、无网络。

2026-10-10 从 novel_pipeline.py 拆出（该文件 2587 行，属「上帝文件」；此前已拆出
pipeline_llm「LLM 调用层」与 foreshadow「伏笔台账」）。拆分依据是**内聚性边界**：
本模块只负责把结构化输入拼成给模型看的系统/用户提示词，不含任何调用、判据或
流水线状态；导入本模块不触网、不读文件，可独立单测。

对外接口：调用方仍从 novel_pipeline 取同名转发（见该文件 import 处）。

⚠ 拆分红线（与 pipeline_llm / foreshadow 同一条）：只降低维护成本，**不改对外契约**；
函数体逐字搬运、未做任何改写。
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from generate_novel import count_words, registry_block, facts_block  # noqa: E402
from fanqie_review import FIX_MIN_RATIO  # noqa: E402'''

QUALITY_HEADER = '''#!/usr/bin/env python3
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

from generate_novel import (  # noqa: E402
    count_words, thrill_per_thousand, surge_per_thousand, side_reaction_per_thousand,
)
from fanqie_review import patch_gate, dedup_intra_repeat  # noqa: E402
from pipeline_llm import EDITOR_MIN_RATIO  # noqa: E402'''

STATE_HEADER = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""断点续传状态读取层：从进度 jsonl 回放状态（纯 I/O，无网络）。

2026-10-10 从 novel_pipeline.py 拆出。本模块只负责「把进度文件读回内存」：
读者官反馈 / 逐章评审 / 终审打回补丁 / 跨章状态清单。落盘（append_state /
save_state_track / save_foreshadow）仍在 novel_pipeline 与 foreshadow.py。

对外接口：调用方仍从 novel_pipeline 取同名转发。拆分红线同 pipeline_llm：
只降维护成本，不改对外契约，函数体逐字搬运。
"""
import json
import os'''

GROUPS = [
    # (target module filename, header, title, names)
    ("pipeline_prompts.py", PROMPTS_HEADER, "各角色提示词（Prompt）", PROMPTS_NAMES),
    ("pipeline_quality.py", QUALITY_HEADER, "纯规则质检 / 采纳 / 文本卫生", QUALITY_NAMES),
    ("pipeline_state.py", STATE_HEADER, "断点续传状态读取", STATE_NAMES),
]

# 转发块插入锚点：pipeline_llm 转发块结尾。
ANCHOR = "    _HEALTH, _health_key, _mark_fail, _mark_ok, _in_cooldown,\n)\n"


def _symbol_spans(tree):
    """顶层 函数 / 单目标赋值 的名字 -> (lineno, end_lineno)。"""
    spans = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            spans[node.name] = (node.lineno, node.end_lineno)
        elif (isinstance(node, ast.Assign) and len(node.targets) == 1
              and isinstance(node.targets[0], ast.Name)):
            spans[node.targets[0].id] = (node.lineno, node.end_lineno)
    return spans


def _reexport_block(module_file, title, names):
    mod = module_file[:-3]
    lines = [
        "# ============================================================",
        f"# {title}（2026-10-10 从本文件拆出 -> {module_file}）",
        "# ============================================================",
        "# 转发导入而非直接定义，是为了让调用点（本文件 main / generate_appended_chapter",
        "# 及仓库内 16 个 `import novel_pipeline as np` 的测试与探针脚本）零改动——",
        "# 拆分只降低维护成本，不改对外契约；函数体逐字搬运、未改写。",
        f"from {mod} import (  # noqa: E402,F401",
    ]
    for i in range(0, len(names), 4):
        lines.append("    " + ", ".join(names[i:i + 4]) + ",")
    lines.append(")")
    return "\n".join(lines) + "\n"


def _collapse_unprotected_blanks(text):
    """把顶层节点之外的连续空行收敛到最多 2 行（节点内部空行不动，防改坏字符串）。"""
    tree = ast.parse(text)
    protected = set()
    for node in tree.body:
        if hasattr(node, "lineno"):
            protected.update(range(node.lineno, node.end_lineno + 1))
    lines = text.split("\n")
    out, blanks = [], 0
    for idx, ln in enumerate(lines, start=1):
        if ln.strip() == "" and idx not in protected:
            blanks += 1
            if blanks <= 2:
                out.append(ln)
        else:
            blanks = 0
            out.append(ln)
    return "\n".join(out)


def main() -> int:
    text = io.open(SRC, encoding="utf-8").read()
    dsts = [ROOT / "scripts" / g[0] for g in GROUPS]
    if all(d.exists() for d in dsts) and not any(
            f"\ndef {n}(" in text or f"\n{n} = " in text
            for g in GROUPS for n in g[3]):
        print("三个模块均已存在且源文件已无对应定义，跳过（幂等）")
        return 0

    lines = text.splitlines(keepends=True)
    tree = ast.parse(text)
    spans = _symbol_spans(tree)

    missing = [n for g in GROUPS for n in g[3] if n not in spans]
    if missing:
        print(f"未在顶层定位到符号：{missing}", file=sys.stderr)
        return 1

    used = []
    for module_file, header, title, names in GROUPS:
        segs = []
        for n in sorted(names, key=lambda x: spans[x][0]):
            a, b = spans[n]
            segs.append("".join(lines[a - 1:b]).rstrip())
            used.append((a, b))
        body = "\n\n\n".join(segs)
        content = header.rstrip("\n") + "\n\n\n" + body + "\n"
        io.open(ROOT / "scripts" / module_file, "w",
                encoding="utf-8", newline="\n").write(content)
        print(f"写出 scripts/{module_file}（{len(names)} 个符号，"
              f"{len(content.splitlines())} 行）")

    # 从源文件删掉被搬走的行（含其后的空行），再把顶层空行收敛到 <=2
    skip = set()
    for a, b in used:
        skip.update(range(a, b + 1))
    kept = [ln for i, ln in enumerate(lines, start=1) if i not in skip]
    new_text = _collapse_unprotected_blanks("".join(kept))

    # 插入转发块
    pos = new_text.find(ANCHOR)
    if pos < 0:
        print("未找到插入锚点（pipeline_llm 转发块结尾）", file=sys.stderr)
        return 1
    pos += len(ANCHOR)
    blocks = "\n" + "\n".join(
        _reexport_block(f, t, ns) for f, _h, t, ns in GROUPS)
    new_text = new_text[:pos] + blocks + new_text[pos:]

    io.open(SRC, "w", encoding="utf-8", newline="\n").write(new_text)
    print(f"novel_pipeline.py: {len(lines)} -> {len(new_text.splitlines())} 行")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
