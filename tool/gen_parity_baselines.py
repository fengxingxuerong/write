#!/usr/bin/env python3
"""生成双端对账基线（verify-logs/py_*.json），供 tool/verify_*_parity_test.dart 使用。

为什么需要它（2026-10-01 评审）：
    三个「真实成书上双端**算法**对账」检查依赖 verify-logs/ 下的基线，而这些基线
    原先由一次性脚本生成、脚本未入库 → 基线无法重建，检查也就无法复现。本脚本把
    数据源、算法、枚举口径全部固定下来，并用 `--check` 重算比对。

生成三份：
    py_drought2.json  —— 逐本 jsonl 成书的外显爽点断供带
    py_stylefp.json   —— 三个真实成书的九项文风指纹
    py_payscene.json  —— isPayoffScene 的 240 例矩阵（10 目标 × 4 场景拍 × 6 位置）

用法:
    python tool/gen_parity_baselines.py                # 写入 verify-logs/
    python tool/gen_parity_baselines.py --check        # 重算比对（不写文件）
    python tool/gen_parity_baselines.py --only payscene
    python tool/gen_parity_baselines.py --out-dir <dir>

对齐要点（改这里必须同步 tool/ 下的 Dart 检查）：
    - 断供带：**按章**逐章算 💥/侧反密度（非 2000 字切片），章按 idx 升序
      （断点续传产物物理顺序 ≠ 章序；不去重，与 Dart 侧载入口径一致）
    - 文风指纹：ref 对应 files[0]，samples[i] 对应 files[i+1]（Dart 按下标取）
    - 爽点场景：判定全在 Python 侧，本脚本只负责枚举与记录
"""
import argparse
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from generate_novel import (  # noqa: E402
    payoff_drought_zones,
    side_reaction_per_thousand,
    style_fingerprint,
    thrill_per_thousand,
)
from novel_pipeline import is_payoff_scene  # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

GEN_DIR = ROOT / "data" / "generated"

# 与 tool/verify_style_fingerprint_parity_test.dart 的 files 列表严格同序
STYLE_FILES = ["novel_10w_pipeline.txt", "short_sample.txt", "smoke_gate_v7.txt"]

# 与 tool/verify_payoff_scene_parity_test.dart 的 240 例矩阵同口径
GOALS = [
    "外显爽点：当众打脸", "设计一次打脸", "当众揭穿真凶", "局势逆转，危机爆发",
    "场景铺垫", "事件推进，冲突升级", "危机爆发", "收束本章并埋下钩子",
    "外显爽点：收获", "",
]
STAGES = ["起", "承", "转", "合"]
POSITIONS = [(0, 4), (1, 4), (2, 4), (1, 3), (0, 2), (2, 0)]


def load_chapters(path):
    """读 jsonl 成书 -> [(idx, 正文)]，按 idx 升序（与 Dart 侧载入口径一致）。"""
    chs = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("type") != "chapter":
            continue
        d = rec.get("data", rec)
        content = d.get("content") or ""
        if not content:
            continue
        chs.append((d.get("idx") or 0, content))
    chs.sort(key=lambda kv: kv[0])
    return chs


def gen_drought():
    """逐本成书的断供带，输出与 Dart 侧读取结构一致：{n, zones:[[s,e,ch]], in_zone}。

    注意 payoff_drought_zones 返回的是 (start, end, chapters) 元组列表，基线里存的是
    **列表**形式且带 n/in_zone 三个字段——Dart 侧 tool/verify_payoff_drought_parity_test.dart
    按 `py[k]['n'] / ['zones'] / ['in_zone']` 取值，包装形状必须一致。
    """
    out = {}
    if not GEN_DIR.is_dir():
        return out
    for j in sorted(GEN_DIR.glob("*.jsonl")):
        chs = load_chapters(j)
        if len(chs) < 3:
            continue
        t = [thrill_per_thousand(c) for _, c in chs]
        s = [side_reaction_per_thousand(c) for _, c in chs]
        zones = payoff_drought_zones(t, side_per_k=s)
        out[j.stem] = {
            "n": len(t),
            "zones": [list(z) for z in zones],
            "in_zone": sum(z[2] for z in zones),
        }
    return out


def gen_stylefp():
    missing = [f for f in STYLE_FILES if not (GEN_DIR / f).exists()]
    if missing:
        raise SystemExit(
            "缺少真机样本：" + "、".join(missing) +
            "（data/generated/ 下是 gitignore 的本机产物，无法凭空重建）")
    paths = [GEN_DIR / f for f in STYLE_FILES]
    texts = [p.read_text(encoding="utf-8", errors="replace") for p in paths]
    fps = [style_fingerprint(t, source=p.name) for t, p in zip(texts, paths)]
    return {"ref": fps[0],
            "samples": [{"name": STYLE_FILES[i + 1], "fp": fps[i + 1]}
                        for i in range(len(fps) - 1)]}


def gen_payscene():
    rows = []
    for g in GOALS:
        for s in STAGES:
            for i, t in POSITIONS:
                rows.append({"g": g, "s": s, "i": i, "t": t,
                             "r": bool(is_payoff_scene(g, s, i, t))})
    return rows


BUILDERS = {
    "drought": ("py_drought2.json", gen_drought),
    "stylefp": ("py_stylefp.json", gen_stylefp),
    "payscene": ("py_payscene.json", gen_payscene),
}


def describe(data):
    return f"{len(data)} 项" if isinstance(data, dict) else f"{len(data)} 例"


def _strip_words(fp):
    """指纹比对**排除 words**：双端 countWords 定义本就不同（见
    docs/quality-rules-current.md 第三节），Dart 侧对账同样不比它（只比九项）。
    """
    return {k: v for k, v in fp.items() if k != "words"}


def compare(name, old, new):
    """比对旧基线与重算结果 -> (是否一致, 差异说明列表)。只比共有项：

    本机 data/generated/ 会随新跑书不断新增（基线不可能跟着长），新增/缺失只提示不报错；
    真正的回归信号是「两边都有的项发生了变化」。
    """
    diffs = []
    if name == "stylefp":
        pairs = [("ref", old.get("ref", {}), new.get("ref", {}))]
        old_s = {s.get("name"): s.get("fp", {}) for s in old.get("samples", [])}
        new_s = {s.get("name"): s.get("fp", {}) for s in new.get("samples", [])}
        for nm in sorted(set(old_s) & set(new_s)):
            pairs.append((f"samples[{nm}]", old_s[nm], new_s[nm]))
        for label, a, b in pairs:
            aa, bb = _strip_words(a), _strip_words(b)
            if aa != bb:
                diffs.append(f"{label} 九项指纹不一致")
        extra = sorted(set(new_s) - set(old_s))
        if extra:
            print(f"     [信息] samples 新增：{extra}")
    elif isinstance(old, dict) and isinstance(new, dict):
        for k in sorted(set(old) & set(new)):
            if old[k] != new[k]:
                diffs.append(f"{k}: old={old[k]} new={new[k]}")
        extra = sorted(set(new) - set(old))
        dropped = sorted(set(old) - set(new))
        if extra:
            print(f"     [信息] 新增成书（不在旧基线中）：{extra}")
        if dropped:
            print(f"     [信息] 旧基线有、本机已无：{dropped}")
    else:
        if old != new:
            diffs.append("整表不一致")
    return (not diffs), diffs


def main():
    ap = argparse.ArgumentParser(description="生成双端对账基线（py_*.json）")
    ap.add_argument("--check", action="store_true",
                    help="重算并与现有基线比对；不一致则 exit 1（不写文件）")
    ap.add_argument("--only", choices=sorted(BUILDERS), help="只处理其中一份")
    ap.add_argument("--out-dir", default="", help="输出目录（默认 verify-logs/）")
    args = ap.parse_args()

    out_dir = Path(args.out_dir) if args.out_dir else ROOT / "verify-logs"
    names = [args.only] if args.only else list(BUILDERS)
    bad = []
    for name in names:
        filename, builder = BUILDERS[name]
        data = builder()
        target = out_dir / filename
        if args.check:
            if not target.exists():
                bad.append(f"{filename} 缺失（先不带 --check 生成一次）")
                continue
            old = json.loads(target.read_text(encoding="utf-8"))
            ok, diffs = compare(name, old, data)
            if ok:
                print(f"[OK]   {filename} 与重算一致（{describe(data)}）")
            else:
                extra = f"（另有 {len(diffs) - 1} 项）" if len(diffs) > 1 else ""
                bad.append(f"{filename} 与重算不一致：{diffs[0]}{extra}")
            continue
        out_dir.mkdir(parents=True, exist_ok=True)
        with target.open("w", encoding="utf-8", newline="\n") as fh:
            json.dump(data, fh, ensure_ascii=False, sort_keys=True, indent=1)
        shown = target.relative_to(ROOT) if str(target).startswith(str(ROOT)) else target
        print(f"[WRIT] {shown}（{describe(data)}）")

    if bad:
        print("基线重算不一致：")
        for b in bad:
            print("  -", b)
        print("提示：本机 data/generated/ 的真机产物若与当初不同，重算结果本就不同——"
              "此时请人工确认后重新生成基线，不要 --check 硬过。")
        return 1
    if args.check:
        print("全部基线与重算一致。")
    return 0


if __name__ == "__main__":
    os.chdir(ROOT)
    sys.exit(main())