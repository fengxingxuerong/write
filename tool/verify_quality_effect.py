#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真机效果验收台（充值/配额恢复后跑一次即可出结论）。

背景：第二十六~三十三节把「外显爽点断供」的**检测 / 预防 / 修复**三层做完并双端对齐，
但**效果**始终未验证——离线只能证明阈值、路由、验收闸与双端一致，证明不了模型是否
真能补出外显爽点。本脚本把「效果」变成可复算的三个判据。

用法：
    # 只分析已有产物（不调 LLM，零成本，可随时跑）
    python tool/verify_quality_effect.py data/generated/xxx.jsonl [更多.jsonl ...]

    # 顺带把新旧书并排对比（前者=改动前基线，后者=改动后新跑）
    python tool/verify_quality_effect.py --compare before.jsonl after.jsonl

输出：每个文件一节，含三组判据 + PASS/FAIL/未知；退出码非 0 表示有 FAIL。

三组判据
--------
① **断供收窄**：💥 外显爽点密度、断供带章数占比、💥 达标章占比。
   参考线：💥 >=0.5/千字为「不算过淡」；断供带 min_run=3。
② **补修采纳率**：读 chapter.issues 里 type=payoff_repair 的记账
   （第二十九节改为**触发即记账**，含 ok 字段与 before/after）。
   采纳率 = 采纳数 / 触发数；无触发则报「未触发」而不是 0%。
③ **文风收敛**：仅当书里带 style_ref 指纹时才有意义——逐章算与参考文的
   距离，看是否**下降**。⚠️ 单点噪声远大于 0.5->0.45 这类变化
   （真机 n=5 独立采样 sigma≈0.075、极差 0.181，第 25 节），故**单章永不判**，
   只报 3 章滑动均值与首末对比。

作者备注：判据阈值取自本仓库既有定标（docs/quality-enhancement-log.md 第 25/26/27 节），
不在此另立标准。
"""
import argparse
import io
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from generate_novel import (  # noqa: E402
    payoff_drought_zones,
    side_reaction_per_thousand,
    style_fingerprint,
    surge_per_thousand,
    thrill_per_thousand,
)

# ---- 判据阈值（全部来自既有定标，见文件头说明）----
THRILL_OK = 0.5          # 每千字；<此值算「过淡」（与各检测器同边界）
DROUGHT_MIN_RUN = 3      # 连续多少章无兑现才判断供带
ADOPT_MIN_RATE = 0.30    # 补修采纳率下限（低于此说明验收闸太严或提示词不对症）


def load_book(path):
    """返回 (chapters=[{idx,content}], repairs=[issue...], style_ref=fp or None)。"""
    chapters, repairs, style_ref = [], [], None
    with io.open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = rec.get("type")
            data = rec.get("data", rec)
            if not isinstance(data, dict):
                continue
            if t == "chapter" and (data.get("content") or "").strip():
                chapters.append(
                    {"idx": data.get("idx"), "content": data["content"]})
                for it in (data.get("issues") or []):
                    if isinstance(it, dict) and it.get("type") == "payoff_repair":
                        repairs.append(it)
            elif t == "style_ref":
                # 2026-09-29 流水线新增：`--style-ref` 提取的指纹落盘（九项分布
                # 数值，不含参考文任何原文）。有它才能算「是否真在向参考文收敛」。
                fp = data.get("fingerprint")
                if isinstance(fp, dict):
                    style_ref = (
                        {k: float(v) for k, v in fp.items()
                         if isinstance(v, (int, float))},
                        str(data.get("source", "")),
                    )
            elif t == "outline":
                # 兼容早期把 style_ref 挂在 outline 上的形态
                sr = data.get("style_ref")
                if isinstance(sr, dict) and isinstance(sr.get("fingerprint"), dict):
                    style_ref = (sr.get("fingerprint"), sr.get("source", ""))
    # 断点续传产物章序可能非连续，必须按章号排序（与流水线载入同口径）
    chapters.sort(key=lambda c: (c["idx"] is None, c["idx"]))
    return chapters, repairs, style_ref


def _median(xs):
    ys = sorted(xs)
    n = len(ys)
    return 0.0 if n == 0 else (ys[n // 2] if n % 2 else (ys[n // 2 - 1] + ys[n // 2]) / 2)


def analyse(path, verbose=True):
    """分析一本书，返回指标字典。"""
    chapters, repairs, style_ref = load_book(path)
    if not chapters:
        return {"file": path.name, "error": "无章节记录"}

    t = [thrill_per_thousand(c["content"]) for c in chapters]
    s = [surge_per_thousand(c["content"]) for c in chapters]
    sd = [side_reaction_per_thousand(c["content"]) for c in chapters]
    zones = payoff_drought_zones(t, side_per_k=sd)
    in_zone = sum(z[2] for z in zones)
    ok_ch = sum(1 for x in t if x >= THRILL_OK)

    triggered = len(repairs)
    adopted = sum(1 for r in repairs if r.get("ok") is True)
    rejected = [r.get("desc", "") for r in repairs if r.get("ok") is not True]

    out = {
        "file": path.name,
        "chapters": len(chapters),
        "words": sum(len(c["content"]) for c in chapters),
        "thrill_median": round(_median(t), 2),
        "surge_median": round(_median(s), 2),
        "side_median": round(_median(sd), 2),
        "ok_rate": round(ok_ch / len(t), 3),
        "drought_zones": [[chapters[a]["idx"], chapters[b]["idx"], n] for a, b, n in zones],
        "drought_rate": round(in_zone / len(t), 3),
        # 逐章断供率（不要求连续）：短书上「断、断、好、断」会因 min_run=3 而不成带，
        # 只看带会给出「0 段 = PASS」的假安全感——终审官判 v7 爽点滞后正是这种形态。
        "flat_rate": round(sum(1 for i in range(len(t)) if t[i] < THRILL_OK
                                and sd[i] < 0.3) / len(t), 3),
        "repair_triggered": triggered,
        "repair_adopted": adopted,
        "repair_rate": (round(adopted / triggered, 3) if triggered else None),
        "repair_rejected": rejected[:6],
        "style_ref": style_ref,
    }

    # 文风收敛（仅当书里带指纹）
    if style_ref and isinstance(style_ref, tuple):
        fp_ref, _src = style_ref
        d = []
        for c in chapters:
            d.append(round(__import__("generate_novel").fingerprint_distance(
                fp_ref, style_fingerprint(c["content"])), 3))
        out["style_dist"] = d
        out["style_dist_first3"] = round(sum(d[:3]) / max(min(3, len(d)), 1), 3)
        out["style_dist_last3"] = round(sum(d[-3:]) / max(min(3, len(d)), 1), 3)
    return out


def _verdict(ok, bad, unknown=None):
    if unknown:
        return "UNKNOWN"
    return "PASS" if ok else f"FAIL({bad})"


def report(m):
    if m.get("error"):
        return
    print(f"\n=== {m['file']} ===")
    print(f"  章节 {m['chapters']}  正文 {m['words']} 字")
    print(f"  💥中位 {m['thrill_median']}/千字（及格 {THRILL_OK}）  "
          f"✨中位 {m['surge_median']}  侧反中位 {m['side_median']}")
    # ① 断供
    zones = m["drought_zones"]
    v1 = _verdict(m["drought_rate"] <= 0.34 and m["flat_rate"] <= 0.40,
                  f"断供带占比 {m['drought_rate']:.0%}>34% 或逐章断供 {m['flat_rate']:.0%}>40%")
    print(f"  ① 断供收窄: {v1}  "
          f"💥达标章 {m['ok_rate']:.0%}｜断供带 {len(zones)} 段 "
          f"覆盖 {m['drought_rate']:.0%} 章｜逐章断供 {m['flat_rate']:.0%}")
    if zones:
        print("     " + "、".join(f"第{a}-{b}章({n})" for a, b, n in zones[:4]))
    # ② 补修采纳
    if m["repair_triggered"]:
        v2 = _verdict(m["repair_rate"] >= ADOPT_MIN_RATE,
                      f"采纳率 {m['repair_rate']:.0%} < {ADOPT_MIN_RATE:.0%}")
        print(f"  ② 补修采纳率: {v2}  "
              f"触发 {m['repair_triggered']} 次 / 采纳 {m['repair_adopted']} 次 "
              f"= {m['repair_rate']:.0%}")
        for r in m["repair_rejected"][:3]:
            print(f"     未采纳样本: {r[:70]}")
    else:
        print("  ② 补修采纳率: UNKNOWN（本产物无 payoff_repair 记账——"
              "要么未触发，要么产物早于第二十九节的可记账版本）")
    # ③ 文风收敛
    if "style_dist" in m:
        first, last = m["style_dist_first3"], m["style_dist_last3"]
        v3 = _verdict(last < first, f"末3章均值 {last} 未低于首3章 {first}")
        print(f"  ③ 文风收敛: {v3}  首3章均值 {first} → 末3章均值 {last}"
              f"（单章噪声大，只看趋势）")
    else:
        print("  ③ 文风收敛: UNKNOWN（本书未落 style_ref 指纹；"
              "桌面端走 Novel.styleRef，不进 jsonl）")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--compare", action="store_true",
                    help="按「基线 → 新跑」并排，只看断供收窄")
    a = ap.parse_args()
    results = []
    for f in a.files:
        p = Path(f)
        if not p.exists():
            print(f"[SKIP] 不存在: {f}")
            continue
        m = analyse(p)
        report(m)
        results.append(m)
    if a.compare and len(results) >= 2:
        b, c = results[0], results[1]
        if "error" not in b and "error" not in c:
            print("\n=== 并排对比（基线 → 新跑）===")
            print(f"  断供章占比  {b['drought_rate']:.0%} → {c['drought_rate']:.0%}")
            print(f"  💥达标章    {b['ok_rate']:.0%} → {c['ok_rate']:.0%}")
            d = c["drought_rate"] - b["drought_rate"]
            print("  判据①（断供收窄）: " +
                  ("PASS" if d < 0 else f"FAIL(未收窄，Δ{d:+.0%})"))


if __name__ == "__main__":
    main()