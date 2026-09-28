#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""压抑释放结构（爽点落点）阈值校准探针。

直接调用生产实现 `generate_novel.release_profile`（不重复实现，保证复跑即复现），
对每章取 verdict / hits / first / last，输出：
- 全量 verdict 分布（none/single/ok/late_start/front_loaded）
- 敏感性：min_n=1/2/3 下 late_start（first>0.6）与 front_loaded（last<0.5）的触发率，
  说明生产口径 n>=2 的取舍依据
- 告警样本清单（生产口径 n>=2）

用法：python tool/probe_release_profile.py
"""
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from generate_novel import release_profile  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent / "data" / "generated"


def load_chapters(path):
    chapters = []
    with io.open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("type") != "chapter":
                continue
            data = rec.get("data", rec)
            content = data.get("content") or ""
            if content:
                chapters.append((data.get("idx"), content))
    chapters.sort(key=lambda x: (x[0] is None, x[0]))
    return chapters


def main():
    rows = []
    for path in sorted(ROOT.glob("*.jsonl")):
        for idx, content in load_chapters(path):
            # 与生产口径一致：短章不判（chapterIssues/composite 均有 >1500 字门，
            # 此处用 800 字下限做分布观察，不影响阈值结论的方向性）。
            if len(content) < 800:
                continue
            p = release_profile(content)
            rows.append((path.name, idx, p))

    total = len(rows)
    dist = {}
    for _, _, p in rows:
        dist[p["verdict"]] = dist.get(p["verdict"], 0) + 1
    print(f"章总数(>=800字): {total}  verdict 分布: {dist}")

    for min_n in (1, 2, 3):
        cand = [p for _, _, p in rows if p["hits"] >= min_n]
        late = sum(1 for p in cand if p["first"] > 0.6)
        front = sum(1 for p in cand if p["last"] < 0.5)
        print(
            f"\n[min_n={min_n}] 适用章 {len(cand)}"
            f" | 压抑过长(first>0.6): {late} ({late / max(1, len(cand)) * 100:.0f}%)"
            f" | 前置泄洪(last<0.5): {front} ({front / max(1, len(cand)) * 100:.0f}%)"
        )

    print("\n告警样本（生产口径 n>=2）：")
    for name, idx, p in rows:
        if p["verdict"] in ("late_start", "front_loaded"):
            print(f"  {name} ch{idx} hits={p['hits']} "
                  f"first={p['first']:.2f} last={p['last']:.2f} → {p['verdict']}")


if __name__ == "__main__":
    main()

