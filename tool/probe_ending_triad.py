#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""章末三件套收尾 证据探针（真实成书回测，选题与阈值校准用）。

选题背景（有指令无检测 + 检测矛盾）：
- FANQIE 规则 20「禁止『三件套』收尾：发烫、亮起、苏醒（含『像有什么东西醒了』）」、
  规则 10「钩子禁止自行改成身体异动/发光物件」、scene_prompt「禁止用发热/发光/
  苏醒类身体异动收束」——双端提示词全都有这条承诺；
- 但检测侧无任何三件套收尾检查，且 has_ending_hook 把「发烫」「醒了过来」
  当钩子词——三件套收尾不但不报警，还被钩子检测判「有钩」（首轮实测 93%）。

本探针输出：
1. 窗口 × 词表命中率（末句 / 末 60 字 / 末 200 字 × core / core+亮了）
2. 末句「天亮了」歧义计数（决定是否收「亮了」进词表）
3. 末句命中明细
4. 钩子降级候选（尾部钩子词命中全是三件套词且无问号悬念 → 修正后将判无钩）

用法：python tool/probe_ending_and_simile.py
"""
import io
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from generate_novel import HOOK_WORDS  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent / "data" / "generated"

# 规则 20 点名的三件套 + 明确变体（不含裸「亮了」：与「天亮了」歧义）
CORE_WORDS = ["发烫", "发热", "亮起", "亮了起来", "苏醒", "醒来",
              "醒了", "发光", "像有什么东西醒了"]
# 钩子词表里属于三件套性质的成员（降级逻辑的排除集）
TRIAD_HOOK_WORDS = ("发烫", "醒了过来", "醒了")


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
    wins = {"末句": None, "末60字": 60, "末200字": 200}
    wordlists = {"core": CORE_WORDS, "core+亮了": CORE_WORDS + ["亮了"]}
    counts = {(w, k): 0 for w in wordlists for k in wins}
    ch_total = 0
    final_sky = 0
    final_hits = []
    flips = []

    for path in sorted(ROOT.glob("*.jsonl")):
        chapters = load_chapters(path)
        if len(chapters) < 3:
            continue
        for idx, content in chapters:
            ch_total += 1
            text = content.rstrip()
            parts = [p for p in re.split(r"[。！？…]", text) if p.strip()]
            final_s = parts[-1] if parts else text[-60:]
            if "天亮了" in final_s:
                final_sky += 1
            for wname, wl in wordlists.items():
                for win, n in wins.items():
                    seg = final_s if n is None else text[-n:]
                    hit = [w for w in wl if w in seg]
                    if hit:
                        counts[(wname, win)] += 1
                        if n is None and wname == "core":
                            final_hits.append((path.name, idx, hit))
            # 钩子降级对拍：旧语义（任一钩词即有钩）→ 新语义（全是三件套词
            # 且无 ？/… 悬念 → 无钩）。不调 has_ending_hook（它已是新语义）。
            tail = text[-200:]
            hook_hits = [w for w in HOOK_WORDS if w in tail]
            last60 = text[-60:]
            has_q = ("？" in last60 or "?" in last60 or "……" in last60)
            old_hook = bool(hook_hits) or has_q
            new_hook = has_q or any(
                w not in TRIAD_HOOK_WORDS for w in hook_hits)
            if old_hook and not new_hook:
                flips.append((path.name, idx, hook_hits))

    print(f"章总数: {ch_total}")
    print("\n=== 窗口 × 词表 命中率 ===")
    for wname in wordlists:
        for win in wins:
            c = counts[(wname, win)]
            print(f"  {wname:10} × {win:6}: {c:3} 章 "
                  f"({c / max(1, ch_total) * 100:.1f}%)")
    print(f"\n末句含「天亮了」（亮了歧义大头）: {final_sky} 章")
    print("\n=== 末句命中明细（core 词表） ===")
    for name, idx, hit in final_hits:
        print(f"  {name} ch{idx}: {'/'.join(hit)}")
    print(f"\n=== 钩子降级候选（唯一尾钩信号是三件套词、无问号悬念）: "
          f"{len(flips)} 章 ===")
    for name, idx, hh in flips:
        print(f"  {name} ch{idx}: 命中 {'/'.join(hh)}")


if __name__ == "__main__":
    main()
