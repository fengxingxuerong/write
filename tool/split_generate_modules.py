#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 generate_novel.py 的「LLM 调用+JSON 解析 / 质检指标+文本卫生」两块拆成兄弟模块。

一次性（幂等）：按 ast 精确定位顶层符号，逐字搬运（不改函数体），再由
generate_novel.py 顶部 `from gen_x import (...)` 反向转发，保证
`from generate_novel import Y` / `import generate_novel as gn; gn.Y` 两种用法零改动
（仓库内 15+ 文件依赖此契约）。

用法：python tool/split_generate_modules.py
"""
from __future__ import annotations

import ast
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "scripts" / "generate_novel.py"

LLM_NAMES = [
    "is_reasoning_model", "call_llm", "repair_json",
    "_sanitize_ctrl", "parse_json_from_llm",
]

# 只搬「纯本地计算」的质检指标/文本卫生；quality_check 与其定点修链
# （_quality_repair_*）依赖户籍表文本块与 review_chapter/fix_prompt，留在
# generate_novel 原位，避免与 gen_registry/novel_pipeline 形成环。
QUALITY_NAMES = [
    "AI_CLICHE", "NEGATION", "OPENING_ACTION_WORDS",
    "GENRE_THRILL_EXTRA", "GENRE_THRILL_ALL", "thrill_per_thousand",
    "GENRE_SURGE_EXTRA", "GENRE_SURGE_ALL", "surge_per_thousand",
    "side_reaction_per_thousand", "release_profile",
    "payoff_drought_zones", "payoff_drought_ev_fragment", "release_ev_fragment",
    "AI_ADVERBS", "SENTENCE_CONNECTORS", "METAPHOR_PAT", "BODY_REACTION_WORDS",
    "SINGLE_PARA_MAX_CHARS", "_style_fingerprint_metrics", "STYLE_FP_LIMITS",
    "_split_sentences", "deep_ai_metrics", "style_fingerprint",
    "style_fingerprint_block", "fingerprint_distance", "load_style_block",
    "style_ev_fragment", "has_ending_hook", "has_quick_opening",
]

LLM_HEADER = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""通用流式 LLM 调用 + JSON 解析层：OpenAI 兼容 SSE，无写作判据、无流水线状态。

2026-10-10 从 generate_novel.py 拆出（同批还有 gen_quality）。本模块只负责
「把请求发出去、把返回的文本解析成 JSON」，不含题材/质检逻辑；导入本模块不触网。

对外接口：调用方仍从 generate_novel 取同名转发（见该文件 import 处）。
⚠ 拆分红线：只降低维护成本，不改对外契约；函数体逐字搬运，未改写。
"""
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request

# 与 generate_novel 同款：强制 print 实时刷新（长跑日志不被缓冲吞掉）
_real_print = print


def print(*args, **kwargs):
    kwargs.setdefault("flush", True)
    _real_print(*args, **kwargs)


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))'''

QUALITY_HEADER = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""质检指标 + 文本卫生层：爽点/异动/侧反密度、伏笔断供、AI 味深度、文风指纹、
钩子/开篇判定——纯本地计算，不触网、不调 LLM。

2026-10-10 从 generate_novel.py 拆出（同批还有 gen_llm）。词表/阈值一律取自
quality_rules_generated（rules/quality_rules.json 的生成物），本文件不写死词表。
单章质检 quality_check 与其定点修链留在 generate_novel（依赖户籍表文本块与
review_chapter/fix_prompt，搬走会成环）。

对外接口：调用方仍从 generate_novel 取同名转发。拆分红线同 novel_pipeline：
只降维护成本，不改对外契约，函数体逐字搬运。
"""
import os
import re
import sys

_real_print = print


def print(*args, **kwargs):
    kwargs.setdefault("flush", True)
    _real_print(*args, **kwargs)


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fanqie_review import count_words, dialogue_ratio  # noqa: E402,F401
from quality_rules_generated import (  # noqa: E402,F401
    AI_ADVERBS, BODY_REACTION_WORDS, HOOK_WORDS, NEGATION, OPENING_STRONG,
    OPENING_WEAK, POWER_SURGE_WORDS, SENTENCE_CONNECTORS, SIDE_REACTION_WORDS,
    THRILL_WORDS, TRIAD_HOOK_ONLY,
)'''

GROUPS = [
    ("gen_llm.py", LLM_HEADER, "通用流式 LLM 调用 + JSON 解析", LLM_NAMES),
    ("gen_quality.py", QUALITY_HEADER, "质检指标 + 文本卫生", QUALITY_NAMES),
]

ANCHOR = "from fanqie_prompts import GOLDEN3_SPEC as _GOLDEN3, GOAL_FORMAT as _GOAL_FORMAT  # noqa: E402\n"


def _symbol_spans(tree):
    spans = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            spans[node.name] = (node.lineno, node.end_lineno)
        elif isinstance(node, ast.Assign):
            # 支持链式赋值（如 AI_ADVERBS = AI_ADVERBS = list(AI_ADVERBS)）：
            # 每个 Name 目标都记录同一段行区间。
            for tgt in node.targets:
                if isinstance(tgt, ast.Name):
                    spans.setdefault(tgt.id, (node.lineno, node.end_lineno))
    return spans


def _reexport_block(module_file, title, names):
    mod = module_file[:-3]
    lines = [
        "# ============================================================",
        f"# {title}（2026-10-10 从本文件拆出 -> {module_file}）",
        "# ============================================================",
        "# 转发导入而非直接定义，是为了让调用点（本文件 main 及仓库内 15+ 个",
        "# `from generate_novel import ...` / `import generate_novel as gn` 的脚本与测试）",
        "# 零改动——拆分只降低维护成本，不改对外契约；函数体逐字搬运、未改写。",
        f"from {mod} import (  # noqa: E402,F401",
    ]
    for i in range(0, len(names), 4):
        lines.append("    " + ", ".join(names[i:i + 4]) + ",")
    lines.append(")")
    return "\n".join(lines) + "\n"


def _collapse_unprotected_blanks(text):
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
        print("两个模块均已存在且源文件已无对应定义，跳过（幂等）")
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

    skip = set()
    for a, b in used:
        skip.update(range(a, b + 1))
    kept = [ln for i, ln in enumerate(lines, start=1) if i not in skip]
    new_text = _collapse_unprotected_blanks("".join(kept))

    pos = new_text.find(ANCHOR)
    if pos < 0:
        print("未找到插入锚点", file=sys.stderr)
        return 1
    pos += len(ANCHOR)
    blocks = "\n" + "\n".join(
        _reexport_block(f, t, ns) for f, _h, t, ns in GROUPS)
    new_text = new_text[:pos] + blocks + new_text[pos:]

    io.open(SRC, "w", encoding="utf-8", newline="\n").write(new_text)
    print(f"generate_novel.py: {len(lines)} -> {len(new_text.splitlines())} 行")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
