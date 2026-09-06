#!/usr/bin/env python3
"""墨匠 A/B 成书对比评测 —— 同一套质检规则并排对比两本成书。

用法:
  python ab_compare.py <A书.txt> <B书.txt>

适用场景：
  - 新旧标准对比：旧标准跑的书 vs 新标准（黄金三章/爽点/钩子）跑的书
  - 双模型对比：AMD 版 vs Sensenova 版
  - 人工校对前后对比

对比维度（与 qa_scan_existing.py / 流水线质检完全同源）：
  - 钩子覆盖率（🪝）
  - 黄金三章开场通过（⚡）
  - 直白爽点密度（💥/千字）
  - 变强异动密度（✨/千字）
  - AI 囷痕密度（%）

零成本，不调用任何 LLM。
"""
import argparse
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from generate_novel import (has_ending_hook, has_quick_opening, count_words,
                            thrill_per_thousand, surge_per_thousand, AI_CLICHE)
from qa_scan_existing import split_chapters

CHAPTER_RE = re.compile(r"^第\s*(\d+)\s*章")


def analyze_book(path):
    """对一本书做全量质检，返回 (rows, stats)。"""
    chapters = split_chapters(path)
    rows = []
    total_hook = 0
    total_open = 0
    total_words = 0
    for idx, title, content in chapters:
        words = count_words(content)
        hook = has_ending_hook(content)
        opening = has_quick_opening(content)
        thrill = thrill_per_thousand(content)
        surge = surge_per_thousand(content)
        hits = sum(content.count(c) for c in AI_CLICHE)
        echo = round(hits / words * 100, 2) if words > 0 else 0.0
        total_words += words
        total_hook += 1 if hook else 0
        if idx <= 3:
            total_open += 1 if opening else 0
        rows.append({
            "idx": idx, "title": title, "words": words,
            "hook": hook, "opening": opening,
            "thrill": thrill, "surge": surge, "echo": echo,
        })
    n = len(rows)
    stats = {
        "name": os.path.basename(path),
        "chapters": n,
        "words": total_words,
        "hook_rate": round(total_hook / n, 3) if n else 0,
        "opening_pass": total_open,
        "opening_total": min(3, n),
        "avg_thrill": round(sum(r["thrill"] for r in rows) / n, 2) if n else 0,
        "avg_surge": round(sum(r["surge"] for r in rows) / n, 2) if n else 0,
        "avg_echo": round(sum(r["echo"] for r in rows) / n, 2) if n else 0,
    }
    return rows, stats


def fmt_rate(v):
    return f"{v * 100:.0f}%"


def main():
    p = argparse.ArgumentParser(description="墨匠 A/B 成书对比评测（零成本）")
    p.add_argument("book_a", help="A 书 txt 路径")
    p.add_argument("book_b", help="B 书 txt 路径")
    p.add_argument("--json", action="store_true", help="以 JSON 输出结果")
    args = p.parse_args()

    rows_a, stats_a = analyze_book(args.book_a)
    rows_b, stats_b = analyze_book(args.book_b)
    if not rows_a or not rows_b:
        print("[ERROR] 两本书都需包含「第 N 章」标题行。")
        sys.exit(1)

    if args.json:
        import json
        print(json.dumps({
            "a": stats_a, "b": stats_b,
            "per_chapter": [{
                "idx": ra["idx"],
                "a": {"hook": ra["hook"], "thrill": ra["thrill"], "echo": ra["echo"]},
                "b": {"hook": rb["hook"], "thrill": rb["thrill"], "echo": rb["echo"]},
            } for ra, rb in zip(rows_a, rows_b)],
        }, ensure_ascii=False, indent=2))
        return

    # ===== 总体对比表 =====
    print("\n" + "=" * 64)
    print("  A/B 成书对比评测报告")
    print("=" * 64)
    print(f"  A：《{stats_a['name']}》   B：《{stats_b['name']}》\n")

    metrics = [
        ("章节数", f"{stats_a['chapters']}", f"{stats_b['chapters']}"),
        ("总字数", f"{stats_a['words']:,}", f"{stats_b['words']:,}"),
        ("章末钩子覆盖率", fmt_rate(stats_a["hook_rate"]), fmt_rate(stats_b["hook_rate"])),
        ("黄金三章开场通过", f"{stats_a['opening_pass']}/{stats_a['opening_total']}",
         f"{stats_b['opening_pass']}/{stats_b['opening_total']}"),
        ("直白爽点密度(💥/千字)", f"{stats_a['avg_thrill']:.2f}", f"{stats_b['avg_thrill']:.2f}"),
        ("变强异动密度(✨/千字)", f"{stats_a['avg_surge']:.2f}", f"{stats_b['avg_surge']:.2f}"),
        ("AI 囷痕密度(%)", f"{stats_a['avg_echo']:.2f}", f"{stats_b['avg_echo']:.2f}"),
    ]

    print(f"  {'指标':<18}{'A':>12}{'B':>12}  判定")
    print("  " + "-" * 56)
    wins = {"a": 0, "b": 0, "tie": 0}
    for label, va, vb in metrics:
        # 判定方向（除 AI 囷痕外都是越高越好）
        better = None
        if label in ("AI 囷痕密度(%)",):
            better = "A" if stats_a["avg_echo"] < stats_b["avg_echo"] else \
                     ("B" if stats_b["avg_echo"] < stats_a["avg_echo"] else "-")
        elif label == "章节数":
            better = "-"
        elif va != vb:
            try:
                na, nb = float(va.replace(",", "")), float(vb.replace(",", ""))
                if label == "总字数":
                    # 字数取更接近目标者；无目标时仅展示
                    better = "A" if na > nb else ("B" if nb > na else "-")
                else:
                    better = "B" if nb > na else ("A" if na > nb else "-")
            except ValueError:
                better = "-"
        else:
            better = "-"
        if better == "A":
            wins["a"] += 1
        elif better == "B":
            wins["b"] += 1
        else:
            wins["tie"] += 1
        mark = "B ✓" if better == "B" else ("A ✓" if better == "A" else "  =")
        print(f"  {label:<18}{va:>12}{vb:>12}  {mark}")

    # ===== 每章对比（按 idx 对齐） =====
    print("\n  【每章对比】（章节数不同时按序对齐，缺失标 -）")
    print(f"  {'章':>4} {'A钩':>4} {'B钩':>4} {'A💥':>6} {'B💥':>6} {'A✨':>6} {'B✨':>6} {'A囷':>6} {'B囷':>6}")
    print("  " + "-" * 58)
    max_n = max(len(rows_a), len(rows_b))
    for i in range(max_n):
        ra = rows_a[i] if i < len(rows_a) else None
        rb = rows_b[i] if i < len(rows_b) else None
        idx = (ra or rb)["idx"]
        a_hook = "🪝" if ra and ra["hook"] else ("✗" if ra else "-")
        b_hook = "🪝" if rb and rb["hook"] else ("✗" if rb else "-")
        a_thrill = f"{ra['thrill']:.2f}" if ra else "-"
        b_thrill = f"{rb['thrill']:.2f}" if rb else "-"
        a_surge = f"{ra['surge']:.2f}" if ra else "-"
        b_surge = f"{rb['surge']:.2f}" if rb else "-"
        a_echo = f"{ra['echo']:.2f}" if ra else "-"
        b_echo = f"{rb['echo']:.2f}" if rb else "-"
        print(f"  {idx:>4} {a_hook:>4} {b_hook:>4} {a_thrill:>6} {b_thrill:>6} "
              f"{a_surge:>6} {b_surge:>6} {a_echo:>6} {b_echo:>6}")

    # ===== 结论 =====
    print("\n  " + "-" * 56)
    print("  【结论】")
    if wins["a"] > wins["b"]:
        print(f"  A 版在 {wins['a']} 项指标上占优（B 占 {wins['b']} 项）——A 更优")
    elif wins["b"] > wins["a"]:
        print(f"  B 版在 {wins['b']} 项指标上占优（A 占 {wins['a']} 项）——B 更优")
    else:
        print(f"  两版打平（各 {wins['a']} 项，{wins['tie']} 项持平）——差异不显著")
    # 关键差异明细
    diffs = []
    if stats_b["hook_rate"] - stats_a["hook_rate"] >= 0.05:
        diffs.append(f"钩子覆盖率 +{fmt_rate(stats_b['hook_rate'] - stats_a['hook_rate'])}")
    elif stats_a["hook_rate"] - stats_b["hook_rate"] >= 0.05:
        diffs.append(f"钩子覆盖率 -{fmt_rate(stats_a['hook_rate'] - stats_b['hook_rate'])}")
    if stats_b["avg_thrill"] - stats_a["avg_thrill"] >= 0.3:
        diffs.append(f"爽点密度 +{stats_b['avg_thrill'] - stats_a['avg_thrill']:.2f}/千字")
    elif stats_a["avg_thrill"] - stats_b["avg_thrill"] >= 0.3:
        diffs.append(f"爽点密度 -{stats_a['avg_thrill'] - stats_b['avg_thrill']:.2f}/千字")
    if stats_b["avg_echo"] - stats_a["avg_echo"] <= -0.15:
        diffs.append(f"AI 囷痕 -{stats_a['avg_echo'] - stats_b['avg_echo']:.2f}%")
    elif stats_a["avg_echo"] - stats_b["avg_echo"] <= -0.15:
        diffs.append(f"AI 囷痕 +{stats_b['avg_echo'] - stats_a['avg_echo']:.2f}%")
    if diffs:
        print("  显著差异：" + "、".join(diffs))
    else:
        print("  无显著差异（阈值内波动）。")
    print("=" * 64 + "\n")


if __name__ == "__main__":
    main()
