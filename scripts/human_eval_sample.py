#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""人评取样器：从已生成成书里切章、铺开好中差三档、产出待标注表。

背景（2026-10-01）：`human_eval_correlation.py` 与作业手册都就绪了，但
`docs/human-eval/annotations.jsonl` 里**一条真实标注都没有**——于是「指标 ↔
人评是否相关」始终未验证，`80 分达线` 只是自洽。本脚本把「除了打分以外的所有
准备工作」做完，让人只需要读和打分。

它做什么：
    1. 读 data/ 下已生成的成书 jsonl（流水线产物，本地不入库），按字数区间筛章；
    2. 用 human_eval_correlation.metrics_of 给每章算一遍机器指标；
    3. 按「番茄分 + 爽点密度」排序后**等距取 30 章**，让指标轴铺满高中低三档；
    4. 每章切成一个 samples/*.txt，并把 id/file/chapter/指标提示写进
       annotations.jsonl，**human 与 rater 留空等人填**。

它绝不做什么：**绝不填 human 分**。整份实验的价值来自「评分者是人」，
脚本编的分数会把权重体系带偏，比不做更糟。

为什么要按机器指标分档、又不把档位当答案：
    手册要求「好中差三档各约 1/3」。若随手取章，样本会集中在指标中段，算出的
    相关性既无区分度也容易虚高。分档让样本在指标轴上铺开——是**为了提高实验的
    区分度**，不是为了让指标「显得准」。指标只写进 `_machine_hint` 备查，
    评分时应当无视，独立按阅读体验给分；否则就是循环论证。

用法:
    python scripts/human_eval_sample.py            # 生成样本与标注表
    python scripts/human_eval_sample.py --dry-run  # 只打印取样分布，不写文件

生成物:
    docs/human-eval/samples/*.txt   逐章正文（**已 gitignore**，量约 300KB）
    docs/human-eval/annotations.jsonl  标注表（入库，human 待填）

之后: 读 samples/*.txt -> 填 human/rater -> python scripts/human_eval_correlation.py
"""
import argparse
import io
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from human_eval_correlation import metrics_of  # noqa: E402

OUT_DIR = ROOT / "docs" / "human-eval" / "samples"
ANN = ROOT / "docs" / "human-eval" / "annotations.jsonl"

# 已生成的成书（相对路径）。data/ 是本地产物目录，已 gitignore。
# 书名不写在这里——一律从各书 outline 记录的 title 字段现取：
# 早先版本在下面硬编码了「碎脉铸仙录/废脉纪元…」等自造书名，实测与成书真名
# 全不一致（如 novel_200k 实为《逆鳞焚天》），且 novel_10w 与 novel_200k
# 竟是同一本书——自造名会把两份产物当成两本书，样本来源就说不清了。
BOOKS = [
    "data/generated/novel_10w_pipeline.jsonl",
    "data/novel_200k.jsonl",
    "data/generated/chief_test_v2.jsonl",
    "data/generated/full_imnovel.jsonl",
    "data/generated/novel_10w.jsonl",
    "data/generated/smoke_gate_v7.jsonl",
    "data/generated/verify_12roles.jsonl",
    "data/generated/smoke_gate_v6.jsonl",
]

# 手册建议 1500~3000 字/章。实测 8 本书里落进该区间的仅 22 章，不够「建议 30 章」，
# 故放宽到 1200~3500——仍是同一量级（不跨数量级），避免字数本身成为混淆变量。
MIN_W, MAX_W = 1200, 3500
TOTAL = 30  # 手册：「至少 10 章，建议 30 章以上才当结论用」


def count_words(text):
    """字数统计，与 AppConstants.countWords 同口径：CJK 每字计 1，
    ASCII 字母数字连续成一个词计 1，标点与空白不计。"""
    count = 0
    in_ascii = False
    for ch in text:
        o = ord(ch)
        if (0x3400 <= o <= 0x4DBF) or (0x4E00 <= o <= 0x9FFF) or (0xF900 <= o <= 0xFAFF):
            count += 1
            in_ascii = False
        elif (0x41 <= o <= 0x5A) or (0x61 <= o <= 0x7A) or (0x30 <= o <= 0x39):
            if not in_ascii:
                count += 1
                in_ascii = True
        else:
            in_ascii = False
    return count


def load_chapters(rel_path):
    """从流水线 jsonl 里取出所有 chapter 记录的 (idx, title, content)。"""
    out = []
    with io.open(ROOT / rel_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("type") != "chapter":
                continue
            d = rec.get("data", {})
            content = (d.get("content") or "").strip()
            if content:
                out.append((d.get("idx"), d.get("title", ""), content))
    return out


def read_title(rel_path):
    """从 jsonl 的 outline 记录里取书名（取不到就退回文件名）。"""
    try:
        with io.open(ROOT / rel_path, encoding="utf-8") as fh:
            for line in fh:
                if not line.strip():
                    continue
                rec = json.loads(line)
                if rec.get("type") == "outline":
                    t = (rec.get("data") or {}).get("title")
                    if t:
                        return str(t)
    except (json.JSONDecodeError, OSError):
        pass
    return Path(rel_path).stem


def collect():
    """筛出候选章并算好指标。返回 [(book, idx, title, text, words, metrics)]。"""
    pool = []
    seen_books = {}          # 书名 -> 已计入章数；同一本书的多个产物只取一次
    for rel in BOOKS:
        if not (ROOT / rel).exists():
            print(f"  跳过（缺文件）：{rel}")
            continue
        book = read_title(rel)
        if book in seen_books:
            print(f"  跳过 {rel}：与 {seen_books[book]} 同为《{book}》，"
                  f"同一本书不重复取样")
            continue
        chapters = load_chapters(rel)
        kept = 0
        for idx, title, content in chapters:
            w = count_words(content)
            if not (MIN_W <= w <= MAX_W):
                continue
            try:
                m = metrics_of(content)
            except Exception as exc:      # 单章失败不该毁掉整轮取样
                print(f"    指标计算失败 {book}-{idx}: {exc}")
                continue
            pool.append((book, idx, title, content, w, m))
            kept += 1
        seen_books[book] = rel
        print(f"  《{book}》({Path(rel).name}): {len(chapters)} 章 "
              f"-> 落在 {MIN_W}~{MAX_W} 字区间 {kept} 章")
    return pool


def pick(pool):
    """等距取 TOTAL 章：让样本在指标轴上铺满高中低，而非挤在一端。

    排序轴取「番茄分 + 爽点密度×10」两项之和，刻意不用单一指标——
    单指标分档会把样本锁死在该指标自己的分布形状上。
    """
    scored = [(p[5]["fanqie_score"] + p[5]["thrill_per_k"] * 10, p) for p in pool]
    scored.sort(key=lambda x: x[0], reverse=True)
    n = len(scored)
    picked, seen = [], set()
    for i in range(TOTAL):
        cand = scored[int(i * n / TOTAL)][1]
        key = (cand[0], cand[1])
        if key in seen:
            continue
        seen.add(key)
        picked.append(cand)
    return picked


HEADER = """# 人评标注（JSONL，一行一章；本行及以 # 开头的行不参与计算）
# 字段：id / file / chapter / human(0~100) / rater / note / human_dims(可选)
#
# 【怎么用】
#   1) 读 samples/ 下同名 .txt；
#   2) 按**整体阅读感受**给 0~100 总分（可分次填，human 为 null 的行会被跳过）；
#   3) 把 human 与 rater 填回本行；rater 填你自己的代号，便于追溯一致性。
#
# 【重要·别作弊】
#   每行末尾的 _machine_hint 是机器指标，仅备查。**请不要看它，也不要按它反推
#   分数**——「指标准不准」正是本实验要检验的东西，凭指标打分等于循环论证。
#   样本已按指标铺开高中低三档正是为了提高区分度，不是为了证明指标准。
#
# 评分参考：<60 读不下去 / 60~75 能看但套路明显 / 76~85 还行 / >85 好看
# 五维可选（human_dims）：开篇 / 爽点 / 钩子 / 动机 / 节奏，各 1~5 分
#
# 生成方式：python scripts/human_eval_sample.py（样本正文不入库，需本地重跑）
"""


def main():
    ap = argparse.ArgumentParser(description="人评取样器（不填 human 分）")
    ap.add_argument("--dry-run", action="store_true", help="只打印分布，不写文件")
    args = ap.parse_args()

    print("扫描成书：")
    pool = collect()
    if len(pool) < TOTAL:
        print(f"\n可用章节只有 {len(pool)} 章 < {TOTAL}，"
              f"请补跑几本书或放宽字数区间。")
        return 1

    picked = pick(pool)
    fan = [p[5]["fanqie_score"] for p in picked]
    thr = [p[5]["thrill_per_k"] for p in picked]
    n_books = len({p[0] for p in pool})
    print(f"\n候选 {len(pool)} 章（来自 {n_books} 本书）-> 取样 {len(picked)} 章")
    print(f"  机器指标跨度：番茄分 {min(fan):.0f}~{max(fan):.0f}｜"
          f"💥爽点 {min(thr):.2f}~{max(thr):.2f}")
    if args.dry_run:
        print("\n--dry-run：未写任何文件。")
        return 0

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    records = []
    for book, idx, title, content, w, m in picked:
        sid = f"{book}-{int(idx):02d}"
        rel = f"docs/human-eval/samples/{sid}.txt"
        (ROOT / rel).write_text(content, encoding="utf-8", newline="\n")
        records.append({
            "id": sid,
            "file": rel,
            "chapter": idx,
            "human": None,     # ← 必须人来填，脚本绝不代填
            "rater": "",
            "note": "",
            "_machine_hint": {
                "fanqie_score": round(m["fanqie_score"], 1),
                "thrill_per_k": round(m["thrill_per_k"], 2),
                "surge_per_k": round(m["surge_per_k"], 2),
                "has_hook": int(m["has_hook"]),
                "dialogue_ratio": round(m["dialogue_ratio"], 3),
                "ai_depth_level": int(m["ai_depth_level"]),
                "words": w,
            },
        })

    head = HEADER.replace("# 生成方式", f"# 取样：{len(picked)} 章 / {len({p[0] for p in pool})} 本书 / "
                                       f"字数 {MIN_W}~{MAX_W}\n# 生成方式")
    ANN.write_text("\n".join(head.split("\n") +
                             [json.dumps(r, ensure_ascii=False) for r in records]) + "\n",
                   encoding="utf-8", newline="\n")

    print(f"\n样本正文 -> {OUT_DIR}（{len(picked)} 个 .txt，约 300KB，已 gitignore）")
    print(f"标注表   -> {ANN}（入库，human 待填）")
    print("\n下一步：读 samples/*.txt 填 human/rater，然后跑")
    print("  python scripts/human_eval_correlation.py --out docs/human-eval/report.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
