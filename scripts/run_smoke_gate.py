#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""run_smoke_gate.py — 墨匠端到端冒烟门禁

每次改动 novel_pipeline.py / generate_novel.py / fanqie_review.py 后跑一次：
  1) 编译检查（py_compile 三大脚本）
  2) 3 章小样全链路（写前守门 → 逐章 → 守护/爽点 → 终审多采样 → 评估卡/终审卡）
  3) 自动验收十二项，输出 SMOKE GATE: PASS / FAIL
     其中 9~12 项是 2026-09 事故回归护栏（正文元话语残留/章内大段重复/题材漂移/
     阻断级硬伤章），与 fanqie_review 同口径——门禁必须能拦住评审报的硬伤。

断点友好：中途中断后重跑同命令自动续传，续传完成后照常验收。
用法：
  python scripts/run_smoke_gate.py                 # 全程（编译+跑书+验收）
  python scripts/run_smoke_gate.py --check-only    # 只验收已有产物（不跑书）
"""
import argparse
import json
import os
import py_compile
import subprocess
import sys
import time

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DEFAULT = os.path.join(ROOT, "data", "generated", "smoke_gate.jsonl")

# 复用评审器的正文级检测器：门禁与评审同口径，避免「评审报的硬伤门禁看不见」
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fanqie_review import (blocking_reasons, genre_drift, intra_repeat,  # noqa: E402
                           meta_talk, prompt_leak)


def step_compile():
    ok = True
    for f in ("novel_pipeline.py", "generate_novel.py", "fanqie_review.py"):
        path = os.path.join(ROOT, "scripts", f)
        try:
            py_compile.compile(path, doraise=True)
            print(f"  [编译] {f} OK")
        except Exception as e:
            print(f"  [编译] {f} FAIL: {e}")
            ok = False
    return ok


def run_book(output, total_words, max_chapters, genre="玄幻"):
    env = dict(os.environ)
    env_file = os.path.join(ROOT, ".env.local")
    if os.path.exists(env_file):
        with open(env_file, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env.setdefault(k.strip(), v.strip())
    cmd = [sys.executable, "-u", os.path.join(ROOT, "scripts", "novel_pipeline.py"),
           "--total-words", str(total_words), "--max-chapters", str(max_chapters),
           "--genre", genre, "--output", output]
    log = output.replace(".jsonl", ".smokegate.log")
    print(f"  [跑书] {' '.join(cmd[2:])}")
    print(f"  [跑书] 日志：{log}")
    with open(log, "a", encoding="utf-8") as lf:
        proc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=lf,
                              stderr=subprocess.STDOUT)
    print(f"  [跑书] 退出码 {proc.returncode}")
    return log


def check(output, max_chapters, review_pass=78.0, genre="玄幻"):
    results = []

    def chk(name, ok, detail=""):
        results.append((name, bool(ok), detail))
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}{('｜' + detail) if detail else ''}")

    log = output.replace(".jsonl", ".smokegate.log")
    txt = output.replace(".jsonl", ".txt")
    card = output.replace(".jsonl", ".评估卡.txt")
    chief = output.replace(".jsonl", ".终审卡.txt")

    # 1) 章节数
    chapters = []
    if os.path.exists(output):
        with open(output, encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("type") == "chapter":
                    chapters.append(rec["data"])
    chk(f"章节数 ≥ {max_chapters}", len(chapters) >= max_chapters, f"实际 {len(chapters)} 章")

    # 2) 无 Traceback
    tb = 0
    if os.path.exists(log):
        with open(log, encoding="utf-8", errors="replace") as f:
            tb = f.read().count("Traceback (most recent call last)")
    chk("日志无 Traceback", tb == 0, f"{tb} 处")

    # 3) 编辑守卫未告警（守卫触发=编辑链异常输出，记 WARN 不 FAIL，但要在报告中可见）
    compress = 0
    if os.path.exists(log):
        with open(log, encoding="utf-8", errors="replace") as f:
            compress = f.read().count("过度压缩")
    chk("编辑链无过度压缩告警", compress == 0, f"{compress} 次（WARN）")

    # 4) 每章评审分数有效（0 分=评审静默失效，属回归信号；低分章仅 WARN 不算回归）
    reviews = {}
    review_rows = {}
    if os.path.exists(output):
        with open(output, encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("type") == "review":
                    d = rec["data"]
                    reviews[d.get("idx")] = d.get("score", 0)
                    review_rows[d.get("idx")] = d
    zeros = {k: v for k, v in reviews.items() if v <= 0}
    lows = {k: v for k, v in reviews.items() if 0 < v < review_pass}
    chk(f"各章评审分数有效（无 0 分静默失效），数量 ≥ {max_chapters}",
        len(reviews) >= max_chapters and not zeros,
        f"零分章: {zeros}" if zeros else f"{len(reviews)} 章有效")
    if lows:
        print(f"  [WARN] 低于达线 {review_pass} 的章（非回归，仅提示）: {lows}")

    # 5) 评估卡存在且非空卡（旧版续跑早期会写「章节：0｜评审均分：0.0」，属回归信号）
    card_empty = False
    if os.path.exists(card):
        with open(card, encoding="utf-8") as f:
            head = f.read(200)
        card_empty = "章节：0" in head
    chk("评估卡已生成且非空卡", os.path.exists(card) and not card_empty,
        "章节数写成 0" if card_empty else "")

    # 6) 终审卡存在且含合并分
    chief_ok = False
    if os.path.exists(chief):
        with open(chief, encoding="utf-8") as f:
            head = f.read(400)
        chief_ok = "终审官总评" in head and "最终：综合" in head
    chk("终审卡已生成（含合并终分）", chief_ok)

    # 7) 成书 txt 存在且非空
    chk("成书 txt 已生成", os.path.exists(txt) and os.path.getsize(txt) > 5000)

    # 8) 截断补全无残留（最后章末以完整标点收尾）
    tail_ok = False
    if os.path.exists(txt):
        with open(txt, encoding="utf-8") as f:
            tail = f.read().rstrip()[-12:]
        tail_ok = any(tail.endswith(p) for p in ("。", "！", "？", "…", "”", "」", "』", "）", "——", "……"))
    chk("成书末尾完整收句", tail_ok)

    # 9~11) 正文级事故回归护栏：元话语残留 / 章内大段重复 / 题材漂移。
    # 三条都来自同一本 3 章小样的真实事故（补写把操作说明拼进正文、玄幻书写成都市悬疑、
    # 第 3 章 800 字整块重复两遍），本地闸门必须能拦住，否则「质检通过」毫无意义。
    meta_hits, dup_chapters, drift_chapters = [], [], []
    for c in chapters:
        body = c.get("content", "") or ""
        m = meta_talk(body) + prompt_leak(body)
        if m:
            meta_hits.append(f"第{c.get('idx')}章「{m[0]}」")
        ir = intra_repeat(body)
        if ir["blocks"]:
            dup_chapters.append(f"第{c.get('idx')}章 {ir['words']} 字")
        gd = genre_drift(body, genre)
        if gd["level"] == "重写":
            drift_chapters.append(f"第{c.get('idx')}章 {'、'.join(gd['hits'][:2])}")
    chk("正文无指令/元话语残留", not meta_hits, "、".join(meta_hits))
    chk("正文无章内大段重复", not dup_chapters, "、".join(dup_chapters))
    chk(f"正文无题材漂移（{genre}）", not drift_chapters, "、".join(drift_chapters))

    # 12) 无阻断级硬伤章（与 fanqie_review.review_book 同口径：有阻断项即不给「可投」）
    blocked = []
    for idx, d in sorted(review_rows.items(), key=lambda kv: (kv[0] is None, kv[0])):
        bl = d.get("blockers") or blocking_reasons(d)
        if bl:
            blocked.append(f"第{idx}章：{'、'.join(bl)}")
    chk("无阻断级硬伤章", not blocked, "、".join(blocked[:3]))

    n_pass = sum(1 for _, ok, _ in results if ok)
    print(f"\nSMOKE GATE: {'PASS' if n_pass == len(results) else 'FAIL'}（{n_pass}/{len(results)}）")
    return n_pass == len(results)

def main():
    ap = argparse.ArgumentParser(description="墨匠端到端冒烟门禁")
    ap.add_argument("--output", default=OUT_DEFAULT)
    ap.add_argument("--total-words", type=int, default=6000)
    ap.add_argument("--max-chapters", type=int, default=3)
    ap.add_argument("--check-only", action="store_true", help="只验收已有产物，不跑书")
    ap.add_argument("--genre", default="玄幻", help="题材（题材漂移检测要按题材判定）")
    a = ap.parse_args()
    print("=" * 64)
    print("墨匠端到端冒烟门禁")
    print("=" * 64)
    t0 = time.time()
    ok = step_compile()
    if not ok:
        print("\nSMOKE GATE: FAIL（编译阶段）")
        sys.exit(1)
    if not a.check_only:
        run_book(a.output, a.total_words, a.max_chapters, a.genre)
    passed = check(a.output, a.max_chapters, genre=a.genre)
    print(f"总耗时 {time.time() - t0:.0f}s")
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
