#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 fanqie_review.py 的「文本基础 / 完读率同质化指标 / 世界观专名」三块纯函数拆成兄弟模块。

一次性（幂等）：按 ast 精确定位顶层符号，逐字搬运（不改函数体），再由
fanqie_review.py 顶部 `from fanqie_x import (...)` 反向转发，保证
`from fanqie_review import Y` / `import fanqie_review as fr; fr.Y` 两种用法零改动。

留原位的块：红线合规（REDLINE/REDLINE_WHITELIST/NARRATIVE_OK_CATEGORIES/
INSTRUCTION_MARKERS + redline_scan）——源码级测试
test_quality_rules_parity 钉死了「INSTRUCTION_MARKERS = list(INSTRUCTION_MARKS)」
与两条导入分支计数，搬走即红；评审门/review_chapter/fix_prompt/main 亦留原位。

用法：python tool/split_fanqie_modules.py
"""
from __future__ import annotations

import ast
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "scripts" / "fanqie_review.py"

TEXT_NAMES = [
    "CHAPTER_RE", "SENT_SPLIT", "CHAR_RE", "QUOTE_RE",
    "count_words", "sentences", "paragraphs", "dialogue_ratio", "split_chapters",
]

METRICS_NAMES = [
    "CLICHE_SENTENCES", "TRIAD_END_WORDS", "DRIVE_WORDS", "NAME_PAT",
    "CONFLICT_WORDS", "PROMPT_LEAK", "META_TALK", "MODERN_MARKERS",
    "ANCIENT_GENRES", "INTRA_REPEAT_MIN_BLOCK", "INTRA_REPEAT_GRAM",
    "BLOCKING_MIN_WORDS", "SURNAMES",
    "looks_like_name", "ending_triad", "ending_ev_fragment", "first_screen_check",
    "pacing_stats", "filler_ratio", "cliche_overlap", "repeat_with_prev",
    "agency_check", "self_repeat_ratio", "name_drift", "blocking_reasons",
    "prompt_leak", "meta_talk", "genre_drift", "intra_repeat",
    "dedup_intra_repeat", "_dup_spans", "_long_paras", "_para_dup",
]

WORLD_NAMES = [
    "_SEP_CHARS", "_TERM_OK", "_GENERIC_WORLD",
    "extract_world_terms", "_term_hit", "world_consistency",
]

TEXT_HEADER = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""番茄评审 · 文本基础工具层：字数 / 句 / 段 / 对白占比 / 章切分。

2026-10-10 从 fanqie_review.py 拆出（同批还有 fanqie_metrics / fanqie_world）。
纯本地计算，无词表依赖、不触网、不调 LLM。

对外接口：调用方仍从 fanqie_review 取同名转发（见该文件 import 处）。
⚠ 拆分红线：只降低维护成本，不改对外契约；函数体逐字搬运，未改写。
"""
import io
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))'''

METRICS_HEADER = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""番茄评审 · 完读率 / 同质化 / 结构指标层：首屏、节奏、水段、套句、漂移、重复。

2026-10-10 从 fanqie_review.py 拆出（同批还有 fanqie_text / fanqie_world）。
只放**纯本地规则指标**（不含红线合规、不调 LLM）；词表/阈值取自
quality_rules_generated（rules/quality_rules.json 的生成物），本文件不写死词表。

对外接口：调用方仍从 fanqie_review 取同名转发。拆分红线：只降维护成本，
不改对外契约，函数体逐字搬运。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fanqie_text import count_words, dialogue_ratio, paragraphs, sentences  # noqa: E402,F401
from quality_rules_generated import (  # noqa: E402,F401
    ANCIENT_GENRES, CONFLICT_WORDS, INTRA_REPEAT_GRAM, INTRA_REPEAT_MIN_BLOCK,
    META_TALK, MODERN_MARKERS, PROMPT_LEAK, REVIEW_CLICHE_SENTENCES,
    TRIAD_END_WINDOW, TRIAD_END_WORDS,
)'''

WORLD_HEADER = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""番茄评审 · 世界观专名一致性层：抽专名、按专名判题材是否落到正文。

2026-10-10 从 fanqie_review.py 拆出（同批还有 fanqie_text / fanqie_metrics）。
纯本地计算，不触网。

对外接口：调用方仍从 fanqie_review 取同名转发。拆分红线：只降维护成本，
不改对外契约，函数体逐字搬运。
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fanqie_text import count_words  # noqa: E402,F401'''

GROUPS = [
    ("fanqie_text.py", TEXT_HEADER, "文本基础工具", TEXT_NAMES),
    ("fanqie_metrics.py", METRICS_HEADER, "完读率 / 同质化 / 结构指标", METRICS_NAMES),
    ("fanqie_world.py", WORLD_HEADER, "世界观专名一致性", WORLD_NAMES),
]

ANCHOR = "# ============================================================\n# 1) 红线词表（番茄平台审核红线，6 类）"

INSERT_PREFIX = (
    "# ============================================================\n"
    "# 兄弟模块转发（2026-10-10 从本文件拆出）\n"
    "# ============================================================\n"
    "# 转发导入而非直接定义，是为了让调用点（本文件 review_chapter/fix_prompt/main\n"
    "# 及仓库内各脚本/测试）零改动——拆分只降低维护成本，不改对外契约。\n"
    "# 先补 sys.path 使 `python -m scripts.fanqie_review` 与直跑两种入口都能解析平铺同级模块。\n"
    "if os.path.dirname(os.path.abspath(__file__)) not in sys.path:\n"
    "    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))\n"
)


def _symbol_spans(tree):
    spans = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            spans[node.name] = (node.lineno, node.end_lineno)
        elif isinstance(node, ast.Assign):
            for tgt in node.targets:
                if isinstance(tgt, ast.Name):
                    spans.setdefault(tgt.id, (node.lineno, node.end_lineno))
    return spans


def _reexport_block(module_file, names):
    mod = module_file[:-3]
    lines = [f"from {mod} import (  # noqa: E402,F401"]
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

    skip = set()
    for a, b in used:
        skip.update(range(a, b + 1))
    kept = [ln for i, ln in enumerate(lines, start=1) if i not in skip]
    new_text = _collapse_unprotected_blanks("".join(kept))

    pos = new_text.find(ANCHOR)
    if pos < 0:
        print("未找到插入锚点", file=sys.stderr)
        return 1
    blocks = INSERT_PREFIX + "\n".join(
        _reexport_block(f, ns) for f, _h, _t, ns in GROUPS) + "\n\n"
    new_text = new_text[:pos] + blocks + new_text[pos:]

    io.open(SRC, "w", encoding="utf-8", newline="\n").write(new_text)
    print(f"fanqie_review.py: {len(lines)} -> {len(new_text.splitlines())} 行")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
