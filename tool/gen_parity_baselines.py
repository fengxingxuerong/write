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

2026-10-14 补充（payscene/drought 已可进 CI）：
    payscene 与 drought 那两份**不依赖语料即可对账**（payscene 是纯函数枚举；
    drought 的逐章密度输入随基线一起固化），故可用 `--pinned` 固化到 rules/：
        python tool/gen_parity_baselines.py --pinned --only payscene
        python tool/gen_parity_baselines.py --pinned --only drought
    Dart 侧 tool/verify_*_parity_test.dart 读固化基线即可在 CI 无语料对账，
    Python 侧由 scripts/test_*_parity.py 钉「基线 == 当前 Python 行为」。
    --pinned --check 用于核对固化基线是否过期（重算比对，不写文件）。
    注意 stylefp 无法固化（输入是整篇正文，固化即提交生成产物，与 data/ 的
    gitignore 边界冲突），它的对账仍需本地语料，按需手动跑。
    刷新固化基线后请跑对应 scripts/test_*_parity.py 确认闭环未断。

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

    2026-10-14 增补 `thrill` / `side` **输入数组**（每章密度）：
    入库固化基线（--pinned）必须含输入，Dart 侧才能在无 data/generated 语料的
    CI 上从提交的输入重算断供带——否则 Dart 需要读真机 jsonl 才有输入，
    对账只能留在本机（这正是 drought 这份长期进不了 CI 的原因）。
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
            "thrill": t,
            "side": s,
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

# --pinned：写入/校验**入库固化基线**（rules/），供 CI 侧无语料对账。
# 文件名用语义名而非 py_*.json——它们是提交进仓库的公共契约，不是本机中间产物。
# payscene 已于 2026-10-14 固化；drought 同日固化（含逐章输入，见 gen_drought）。
# stylefp **暂不固化**：它的输入是整篇正文（数十万字），固化即把生成产物
# 提交进库，与 data/ 的 gitignore 边界冲突；它的双端对账仍是本机手动跑。
PINNED_NAMES = {
    "drought": "payoff_drought_parity.json",
    "payscene": "payoff_scene_parity.json",
}


def describe(data):
    return f"{len(data)} 项" if isinstance(data, dict) else f"{len(data)} 例"


def _write_stable_json(data, fh):
    """以**稳定格式**写基线：保持字段书写序、2 空格缩进、结尾带换行。

    为什么不能用 `json.dump(..., sort_keys=True, indent=1)`（2026-10-14 踩过）：
    这样写会把 payscene 的字段从 `g/s/i/t/r` 重排成 `g/i/r/s/t`、缩进换挡，
    于是**逐条内容完全相同**的基线也产生 ~1680 行 diff。后果是致命的——
    这些基线存在的意义就是「双端算法漂移时 diff 会说话」，而全文件重排
    恰好把真实漂移埋进 1680 行格式噪声里，人只会看到「格式变了」就跳过。

    故只需去掉 sort_keys：`gen_payscene()` 用字典字面量构造，字段书写序
    本就是 g/s/i/t/r，`json.dump` 按插入序输出即与手写基线逐字节一致。
    （曾试过手工逐 record 序列化，结果缩进层级猜错、多出前导空格——
    能用标准库解决的事不要自己写。）

    `--check` 比对走 json.loads 与格式无关；这里求的是**人工 review diff 时
    看到的每一行都必然是真变化**。
    """
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")


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
    ap.add_argument("--pinned", action="store_true",
                    help="操作入库固化基线（rules/<语义名>.json，供 CI 无语料对账）；"
                         "须配合 --only（固化基线一份一份地刷新）")
    args = ap.parse_args()

    if args.pinned:
        if not args.only:
            ap.error("--pinned 必须配合 --only（固化基线是逐份契约，"
                     "不支持一次性全量写入）")
        if args.only not in PINNED_NAMES:
            ap.error(f"{args.only} 尚未固化（见 PINNED_NAMES 注释："
                     "stylefp 输入是整篇正文，无法在不提交生成产物的前提下固化）")
        out_dir = Path(args.out_dir) if args.out_dir else ROOT / "rules"
        pinned_filename = PINNED_NAMES[args.only]
    else:
        out_dir = Path(args.out_dir) if args.out_dir else ROOT / "verify-logs"
        pinned_filename = None

    names = [args.only] if args.only else list(BUILDERS)
    bad = []
    if pinned_filename is None:
        # 说明性提示，不改变行为：历史上有人以为「直接跑一次就会刷新固化基线」，
        # 结果只写到了 verify-logs/（gitignore）或 --out-dir 指定的任意目录，
        # 入库的固化基线悄悄过期而没人发现（2026-10-14 本人就这样错过一次，
        # 把 payscene 写到了仓库根的 py_payscene.json 而非 rules/ 下）。
        dest = out_dir / "py_<name>.json"
        print(f"[提示] 未加 --pinned，将写入 {dest}（不入库）。"
              "要刷新 CI 用的固化基线请加 --pinned --only <name>。")
    for name in names:
        filename, builder = BUILDERS[name]
        if pinned_filename:
            filename = pinned_filename
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
            _write_stable_json(data, fh)
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
