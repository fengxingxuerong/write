#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 qa_semantic_check.py 的四个语义关卡 + 文本基础拆成兄弟模块。

一次性（幂等）：按 ast 精确定位顶层符号，逐字搬运（不改函数体），再由
qa_semantic_check.py 顶部 `from qa_x import (...)` 反向转发，保证
`from qa_semantic_check import Y` / `import qa_semantic_check as qa; qa.Y` 零改动。

留原位：load_chapters / CHAPTER_RE / print_report / main。
本文件零项目内导入、无源码级测试耦合，拆分最干净。

用法：python tool/split_semantic_modules.py
"""
from __future__ import annotations

import ast
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "scripts" / "qa_semantic_check.py"

TEXT_NAMES = ["DIALOGUE_PATTERNS", "strip_dialogue"]

POV_NAMES = [
    "FIRST_PRON", "THIRD_PRON", "POV_MIN_NARR_CHARS", "POV_MIN_PRON",
    "POV_FIRST_RATIO", "POV_THIRD_RATIO", "POV_STABLE_RUN",
    "split_blocks", "block_pov", "detect_pov_drift",
]

NAMES_NAMES = [
    "SURNAMES", "VERB_CHARS", "STOP_NAMES", "OBJ_SUFFIX", "PLACEHOLDER_RES",
    "NICKNAME_RES", "PRON_SUFFIX", "MIN_CAND_FREQ", "MIN_CLUSTER_FREQ",
    "MIN_MEMBER_FREQ", "SPAN_OVERLAP_ALERT",
    "discover_names", "cluster_names", "detect_name_drift",
]

CONTENT_NAMES = [
    "GENRE_CONTENT_WORDS", "CONTENT_MIN_CHARS", "CONTENT_SUSPECT_RATIO",
    "CONTENT_SUSPECT_CAP", "_title_keywords", "detect_content_drift",
]

RELATION_NAMES = [
    "REL_WORDS", "_REL_ALT", "REL_P1_PAT", "REL_P2_PAT", "_REL_BAD_CHARS",
    "_REL_ADVERBS", "_clean_rel_name", "detect_relation_drift",
]

TEXT_HEADER = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语义硬伤检测 · 文本基础：对白剥离（供多个关卡复用）。

2026-10-10 从 qa_semantic_check.py 拆出。纯本地规则，不触网。

对外接口：调用方仍从 qa_semantic_check 取同名转发。拆分红线：只降维护成本，
不改对外契约；函数体逐字搬运，未改写。
"""
import re'''

POV_HEADER = '''#!/usr/bin/env python3
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

from qa_text import strip_dialogue  # noqa: E402'''

NAMES_HEADER = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语义硬伤检测 · 关卡2（主角称谓漂移）+ 候选名发现/聚类。

2026-10-10 从 qa_semantic_check.py 拆出。纯本地规则，不触网、不调 LLM。

对外接口：调用方仍从 qa_semantic_check 取同名转发。拆分红线：只降维护成本，
不改对外契约；函数体逐字搬运，未改写。
"""
import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))'''

CONTENT_HEADER = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语义硬伤检测 · 关卡3（题材内容塌陷：标题-内容脱节）。

2026-10-10 从 qa_semantic_check.py 拆出。纯本地规则，不触网、不调 LLM。

对外接口：调用方仍从 qa_semantic_check 取同名转发。拆分红线：只降维护成本，
不改对外契约；函数体逐字搬运，未改写。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))'''

RELATION_HEADER = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语义硬伤检测 · 关卡4（人物关系张冠李戴）。

2026-10-10 从 qa_semantic_check.py 拆出。纯本地规则，不触网、不调 LLM。

对外接口：调用方仍从 qa_semantic_check 取同名转发。拆分红线：只降维护成本，
不改对外契约；函数体逐字搬运，未改写。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from qa_text import strip_dialogue  # noqa: E402'''

GROUPS = [
    ("qa_text.py", TEXT_HEADER, "文本基础", TEXT_NAMES),
    ("qa_pov.py", POV_HEADER, "关卡1 人称漂移", POV_NAMES),
    ("qa_names.py", NAMES_HEADER, "关卡2 称谓漂移", NAMES_NAMES),
    ("qa_content.py", CONTENT_HEADER, "关卡3 内容塌陷", CONTENT_NAMES),
    ("qa_relation.py", RELATION_HEADER, "关卡4 关系张冠李戴", RELATION_NAMES),
]

ANCHOR = "\ndef load_chapters(path):"

INSERT_PREFIX = (
    "# ============================================================\n"
    "# 兄弟模块转发（2026-10-10 从本文件拆出）\n"
    "# ============================================================\n"
    "# 转发导入而非直接定义，是为了让调用点（本文件 main / run_smoke_gate / 测试）零改动。\n"
    "# 先补 sys.path 使 `python -m scripts.qa_semantic_check` 与直跑两种入口都能解析平铺同级模块。\n"
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
        print("模块均已存在且源文件已无对应定义，跳过（幂等）")
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
        _reexport_block(f, ns) for f, _h, _t, ns in GROUPS) + "\n"
    new_text = new_text[:pos] + blocks + new_text[pos:]

    io.open(SRC, "w", encoding="utf-8", newline="\n").write(new_text)
    print(f"qa_semantic_check.py: {len(lines)} -> {len(new_text.splitlines())} 行")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
