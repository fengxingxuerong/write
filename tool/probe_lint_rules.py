"""探测候选 lint 规则在当前代码库的实际违规量（一次性工具，不改仓库文件）。

用法：python tool/probe_lint_rules.py [rule ...]
输出每个规则的违规条数，用于决定 analysis_options 里启用哪些。
"""
from __future__ import annotations

import io
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OPTS = ROOT / "analysis_options.yaml"

CANDIDATES = [
    "require_trailing_commas",
    "sort_pub_dependencies",
    "avoid_dynamic_calls",
    "prefer_single_quotes",
    "directives_ordering",
    "always_put_control_body_on_new_line",
    "avoid_redundant_argument_values",
    "unnecessary_await_in_return",
    "use_string_buffers",
    "join_return_with_assignment",
]


def analyze() -> list[dict]:
    out = subprocess.run(
        ["dart", "analyze", "--format=machine"],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
    ).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split("|")
        if len(parts) >= 8:
            rows.append({"code": parts[3], "path": parts[1], "line": parts[2]})
    return rows


def main() -> int:
    rules = sys.argv[1:] or CANDIDATES
    base = io.open(OPTS, encoding="utf-8").read()
    # 基线（含当前启用的规则）先跑一次，作为对照
    print(f"探测 {len(rules)} 条规则，每条各跑一次 analyze…", flush=True)
    results = {}
    for rule in rules:
        patched = base.replace(
            "analyzer:",
            f"    {rule}: true\n\nanalyzer:", 1)
        if patched == base:
            print(f"  {rule}: 无法注入锚点，跳过", flush=True)
            continue
        # 临时文件必须建在仓库内：Windows 上 Path.replace 跨盘符（C: 临时目录 → D: 仓库）
        # 会报 [WinError 17]，跨盘符无法原子移动。
        tmp = OPTS.with_name(OPTS.name + ".probe.tmp")
        tmp.write_text(patched, encoding="utf-8", newline="\n")
        try:
            tmp.replace(OPTS)
            rows = analyze()
            results[rule] = len(rows)
            print(f"  {rule}: {len(rows)} 处", flush=True)
        finally:
            if tmp.exists():
                tmp.unlink()
            OPTS.write_text(base, encoding="utf-8", newline="\n")
    print(json.dumps(results, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())