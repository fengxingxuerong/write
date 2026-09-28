#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真实成书质量缺口探针（一次性诊断脚本，用于选题）。

扫描 data/generated 下真实成书 jsonl，量化尚未被检测器覆盖的质量短板：
1. 跨章句子级复读（同一句话在多章原样出现）
2. 跨章比喻复用（同一比喻跨章出现，违反「同一比喻全书只用一次」）
3. 有指令无检测的写作规则违规计数（仿佛/似乎/宛如、不是…而是、单句成段）
4. 开场套路重复（连续章同开场、天气起手）
"""
import io
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from fanqie_review import SENT_SPLIT  # noqa: E402
from generate_novel import METAPHOR_PAT, count_words  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent / "data" / "generated"
SENT_MIN = 10  # 复读判定的最短句长（汉字数）


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


def norm(s):
    return re.sub(r"[\s\u3000“”\"'‘’（）()《》]", "", s)


def probe_book(path):
    chapters = load_chapters(path)
    if len(chapters) < 3:
        return None
    # 1) 跨章句子复读
    sent_owners = defaultdict(set)
    for idx, content in chapters:
        for s in SENT_SPLIT.split(content):
            s = norm(s)
            if len(s) >= SENT_MIN:
                sent_owners[s].add(idx)
    dup_sents = {s: o for s, o in sent_owners.items() if len(o) >= 2}
    dup_chars = sum(len(s) * len(o) for s, o in dup_sents.items())
    total_chars = sum(count_words(c) for _, c in chapters)

    # 2) 跨章比喻复用
    meta_owners = defaultdict(set)
    for idx, content in chapters:
        for m in METAPHOR_PAT.finditer(content):
            g = norm(m.group(0))
            if len(g) >= 4:
                meta_owners[g].add(idx)
    dup_meta = {m: o for m, o in meta_owners.items() if len(o) >= 2}

    # 3) 有指令无检测的规则违规
    v_hugua = v_but = v_single = 0
    hugua_ch = but_ch = single_ch = 0
    for idx, content in chapters:
        h = sum(content.count(w) for w in ("仿佛", "似乎", "宛如"))
        b = len(re.findall(r"不是[^。\n]{0,20}?而是", content))
        # 单句成段：段落 ≤14 字（与 Dart STYLE_FP 同口径）
        single = sum(
            1 for p in content.split("\n\n")
            if p.strip() and count_words(p) <= 14
        )
        if h > 2:
            v_hugua += h
            hugua_ch += 1
        if b > 1:
            v_but += b
            but_ch += 1
        if single > 4:
            v_single += single - 4
            single_ch += 1

    # 4) 开场套路
    openings = []
    weather_starts = 0
    weather_words = ("清晨", "早晨", "清晨的", "夜色", "夜幕", "天空", "晨光", "夕阳", "月光", "阳光", "风", "雨")
    for idx, content in chapters:
        head = content.strip()[:12]
        openings.append(head)
        first4 = content.strip()[:4]
        if any(first4.startswith(w) for w in weather_words):
            weather_starts += 1
    consecutive_same = sum(
        1 for a, b in zip(openings, openings[1:]) if norm(a)[:6] == norm(b)[:6]
    )

    return {
        "chapters": len(chapters),
        "total_chars": total_chars,
        "dup_sent": len(dup_sents),
        "dup_sent_max_chapters": max((len(o) for o in dup_sents.values()), default=0),
        "dup_sent_chars": dup_chars,
        "dup_sent_ratio": round(dup_chars / total_chars * 100, 2) if total_chars else 0,
        "dup_meta": len(dup_meta),
        "hugua_violating_chapters": hugua_ch,
        "but_violating_chapters": but_ch,
        "single_violating_chapters": single_ch,
        "weather_openings": weather_starts,
        "consecutive_same_opening": consecutive_same,
        "top_dup": sorted(dup_sents.items(), key=lambda kv: -len(kv[1]))[:3],
    }


def main():
    results = []
    for path in sorted(ROOT.glob("*.jsonl")):
        r = probe_book(path)
        if r:
            results.append((path.name, r))
    hdr = (
        f"{'book':38} {'ch':>3} {'字数':>7} {'复读句':>6} {'复读%':>6} "
        f"{'比喻复用':>6} {'仿佛':>4} {'不是而是':>6} {'单句段':>5} {'天气起手':>6} {'连开':>4}"
    )
    print(hdr)
    print("-" * len(hdr))
    for name, r in results:
        print(
            f"{name:38} {r['chapters']:>3} {r['total_chars']:>7} {r['dup_sent']:>6} "
            f"{r['dup_sent_ratio']:>6} {r['dup_meta']:>6} {r['hugua_violating_chapters']:>4} "
            f"{r['but_violating_chapters']:>6} {r['single_violating_chapters']:>5} "
            f"{r['weather_openings']:>6} {r['consecutive_same_opening']:>4}"
        )
    print("\n复读最重样本：")
    for name, r in results:
        if r["dup_sent"]:
            for s, owners in r["top_dup"]:
                print(f"  {name} | {sorted(owners)} | {s[:40]}")


if __name__ == "__main__":
    main()
