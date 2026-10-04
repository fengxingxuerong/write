"""把 quality-enhancement-log.md 按日期轮次拆成 archive/*（一次性工具）。

切分点由原文的 `## ` 二级标题行号决定，内容原样搬运，不改写正文。
幂等：已拆分过（archive 下已有产物）则直接退出。
"""
from __future__ import annotations

import io
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "docs" / "quality-enhancement-log.md"
OUT = ROOT / "docs" / "archive" / "quality-enhancement-log"

# (输出文件名, 该文件收录的二级标题序号起止, 建议的标题行)
GROUPS = [
    ("2026-09-12-llm-role-matrix.md", 8, 11, "2026-09-12 LLM 角色矩阵 v2 与角色扩充"),
    ("2026-09-23-semantic-gates.md", 12, 14, "2026-09-23 语义硬伤检测器与关卡 4/5 落地"),
    ("2026-09-26-gate-v7.md", 15, 21, "2026-09-26 合规投影与门禁 v7 治理"),
    ("2026-09-28-payoff-style.md", 22, 25, "2026-09-28 商业爽点闭环与文风指纹 P1-1"),
    ("2026-09-29-live-verification.md", 26, 34, "2026-09-29 爽点断供检测与真机验证"),
    ("2026-09-30-thinking-budget.md", 35, 35, "2026-09-30 思考链预算缺陷收敛"),
]

HEAD_RE = re.compile(r"^## ")


def read_lines(p: Path) -> list[str]:
    return io.open(p, encoding="utf-8").read().split("\n")


def main() -> int:
    if any((OUT / name).exists() for name, _, _, _ in GROUPS):
        print("archive 产物已存在，跳过（幂等）")
        return 0

    lines = read_lines(SRC)
    # 二级标题（`## `）的 1-based 行号 -> 序号（中文数字另行处理）
    heads = [(i + 1, ln) for i, ln in enumerate(lines) if HEAD_RE.match(ln)]
    # 一~七 共 7 节（留在主文件）+ 八~三十五 共 28 节（归档）= 35 个 `## `
    if len(heads) != 35:
        print(f"标题数异常：{len(heads)}（预期 35）", file=sys.stderr)
        return 1

    # 前 7 节（总览）留在主文件，其余按 GROUPS 切走
    keep_end = heads[7][0] - 1  # 第 8 个标题之前的全部内容
    out_files: dict[str, list[str]] = {}
    for name, lo, hi, _title in GROUPS:
        start = heads[lo - 1][0]
        end = heads[hi][0] - 1 if hi < len(heads) else len(lines) + 1
        out_files[name] = lines[start - 1 : end - 1]

    OUT.mkdir(parents=True, exist_ok=True)
    for name, _lo, _hi, title in GROUPS:
        body = "\n".join(out_files[name]).rstrip() + "\n"
        header = (
            f"> 📦 归档件，原文第 {_lo}~{_hi} 节：{title}。\n"
            f"> 只读参考，**不要照此改代码**；当前实态见 "
            f"[`docs/README.md`](../../README.md) 索引的现行文档。\n\n"
        )
        io.open(OUT / name, "w", encoding="utf-8", newline="\n").write(header + body)

    kept = lines[:keep_end]
    index = ["", "## 归档索引（按日期轮次）", "",
             "以下为历史轮次记录，**只读参考，不要照此改代码**：", "",
             "| 归档件 | 覆盖轮次 |", "| --- | --- |"]
    for name, lo, hi, title in GROUPS:
        index.append(f"| [`archive/quality-enhancement-log/{name}`]"
                      f"(archive/quality-enhancement-log/{name}) | 第 {lo}~{hi} 节：{title} |")
    index.append("")

    io.open(SRC, "w", encoding="utf-8", newline="\n").write(
        "\n".join(kept).rstrip() + "\n" + "\n".join(index) + "\n"
    )
    print("拆分完成：" + "、".join(sorted(out_files)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())