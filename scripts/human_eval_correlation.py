#!/usr/bin/env python3
"""人评相关性实验：质检指标 vs 人工评分（回答「指标涨了，人评涨了吗」）。

为什么需要它（2026-10-01 评审的核心结论）：
    本项目的质量主张建立在本地启发式指标上（💥 爽点密度 / ✨ 变强异动 / 章末钩子 /
    对白占比 / 水段率 / 套话重合 / AI 味深度…）。这些指标都是**表层统计量的代理**：
    模型只要多堆词、切碎段落、把对白凑到 30%，分数自然上去——即「可刷分」。
    没有「指标 ↔ 人评」的相关性证据，`80 分达线` 只是**自洽**，不是**有效**。

    本脚本把人评样本与指标逐章对齐，算 Spearman 秩相关（含并列秩）与置换检验 p 值，
    给出「保留 / 降权 / 下线」的建议。目的是把评分权重从「惯例」变成「有数据支撑」。

用法:
    python scripts/human_eval_correlation.py --init        # 生成标注模板（含填写说明）
    python scripts/human_eval_correlation.py               # 读默认标注文件，打印相关性表
    python scripts/human_eval_correlation.py --out docs/human-eval/report.md

标注文件（JSONL，一行一章）:
    {"id": "碎脉铸仙录-03", "file": "data/generated/short_sample.txt", "chapter": 3,
     "human": 82, "rater": "A", "human_dims": {"开篇": 4, "爽点": 4, "钩子": 5,
     "动机": 4, "节奏": 5}, "note": "打脸兑现到位，中段略拖"}
    - human: 人工总分（0~100 的整数）——**必须是人读出来的**；
    - file: 章节正文文件（整章或章节片段均可）；
    - 也可直接内联正文：{"id": "...", "text": "……", "human": 70}。

⚠️ 严禁编造人评数据：本实验的全部价值来自「评分者是人」。脚本会把 rater 与样本数
   打进报告，样本 < --min-n（默认 10）时以退出码 2 失败，不产出结论。
"""
import argparse
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
DEFAULT_ANNOTATIONS = ROOT / "docs" / "human-eval" / "annotations.jsonl"

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

from fanqie_review import cliche_overlap, filler_ratio, pacing_stats, review_chapter  # noqa: E402
from generate_novel import (  # noqa: E402
    deep_ai_metrics,
    has_ending_hook,
    side_reaction_per_thousand,
    surge_per_thousand,
    thrill_per_thousand,
)

TEMPLATE = """# 人评标注（JSONL，一行一章；以 # 开头的行与本文件说明都不参与计算）
# 字段：id / file 或 text / chapter / human(0~100) / rater / human_dims(可选) / note
# 选取原则：好中差三档各约 1/3，同题材、同字数区间（1500~3000 字），避免只看甜点样本。
# 例（**请替换成你真实读过的章节**，编造数据会让整份报告失去意义）：
# {"id": "作品A-01", "file": "data/generated/xxx.txt", "chapter": 1, "human": 78, "rater": "A", "note": "开篇有变故，爽点偏淡"}
"""


def _rank(values):
    """平均秩（并列取平均），Spearman 的并列秩口径。"""
    idx = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(idx):
        j = i
        while j + 1 < len(idx) and values[idx[j + 1]] == values[idx[i]]:
            j += 1
        avg = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            ranks[idx[k]] = avg
        i = j + 1
    return ranks


def _pearson(a, b):
    n = len(a)
    if n < 2:
        return 0.0
    ma, mb = sum(a) / n, sum(b) / n
    cov = sum((p - ma) * (q - mb) for p, q in zip(a, b))
    va = sum((p - ma) ** 2 for p in a) ** 0.5
    vb = sum((q - mb) ** 2 for q in b) ** 0.5
    if va == 0 or vb == 0:
        return 0.0
    return cov / (va * vb)


def spearman(x, y):
    """Spearman 秩相关：对秩做 Pearson（含并列秩时为正确口径）。"""
    if len(x) != len(y) or len(x) < 3:
        return 0.0
    return _pearson(_rank([float(v) for v in x]), _rank([float(v) for v in y]))


def permutation_p(x, y, observed, permutations=2000, seed=20261001):
    """置换检验双侧 p 值（n 小、无分布假设；固定种子保证可复现）。"""
    if permutations <= 0:
        return float("nan")
    rng = random.Random(seed)
    ys = list(y)
    hit = 0
    for _ in range(permutations):
        rng.shuffle(ys)
        if abs(spearman(x, ys)) >= abs(observed):
            hit += 1
    return (hit + 1) / (permutations + 1)


def metrics_of(text):
    """一章正文 -> 质检指标字典（键即指标名，与报告表格一一对应）。"""
    pace = pacing_stats(text)
    fr, _ = filler_ratio(text)
    cl = cliche_overlap(text)
    deep = deep_ai_metrics(text)
    return {
        "fanqie_score": float(review_chapter(text, idx=1)["score"]),
        "thrill_per_k": thrill_per_thousand(text),
        "surge_per_k": surge_per_thousand(text),
        "side_reaction_per_k": side_reaction_per_thousand(text),
        "has_hook": 1.0 if has_ending_hook(text) else 0.0,
        "dialogue_ratio": float(pace["dialogue"]),
        "filler_percent": float(fr),
        "cliche_per_k": float(cl["per_k"]),
        "sent_len_avg": float(pace["sent_avg"]),
        "ai_depth_level": float(deep.get("level", 0)),
    }


def load_annotations(path):
    """读 JSONL 标注；返回 [(id, text, human, rater, note)]，非法行直接报错。"""
    if not path.exists():
        raise SystemExit(f"标注文件不存在：{path}\n先跑 --init 生成模板，再按真实阅读结果填写。")
    items = []
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"第 {lineno} 行不是合法 JSON：{exc}")
        human = rec.get("human")
        if human is None:
            continue  # 未评分（模板行）跳过，不算样本
        text = rec.get("text")
        if text is None:
            f = rec.get("file")
            if not f:
                raise SystemExit(f"第 {lineno} 行既无 text 也无 file")
            fp = (ROOT / f) if not Path(f).is_absolute() else Path(f)
            if not fp.exists():
                raise SystemExit(f"第 {lineno} 行引用的文件不存在：{fp}")
            text = fp.read_text(encoding="utf-8")
        items.append((rec.get("id", f"line{lineno}"), text, float(human),
                      rec.get("rater", "?"), rec.get("note", "")))
    return items


def verdict_for(rho, p):
    """按 ρ 与 p 给建议（阈值刻意保守：宁可降权也不留假指标）。

    负相关必须单列：`abs(rho)` 很大但方向相反时，指标越「好」人评越差
    （典型成因：词表奖励套话），这是最危险的一类，绝不能被当成「强相关 -> 保留」。
    """
    if p > 0.10 or abs(rho) < 0.30:
        return "下线/重做", "与人评无关或噪声，继续用它打分会误导生成端"
    if rho < 0:
        return "下线/重做", "与人评负相关（指标越高读者越不买账）——最危险的一类，必须立刻降权并复查词表"
    if rho < 0.55:
        return "降权", "弱相关：可保留为提示，但不该独自决定达线"
    return "保留", "与人评同向且不弱，可作为门禁依据"


def render_report(items, table, permutations, seed):
    raters = sorted({it[3] for it in items})
    lines = [
        "<!-- 由 scripts/human_eval_correlation.py 生成；数据来自人工标注 -->",
        "",
        "# 人评相关性报告",
        "",
        f"- 样本数：{len(items)} 章（评分者：{'、'.join(raters)}）",
        f"- 人评总分均值：{sum(it[2] for it in items) / len(items):.1f}",
        f"- 方法：Spearman 秩相关（并列取平均秩）+ 置换检验双侧 p"
        f"（{permutations} 次置换，种子 {seed}）",
        "",
        "| 指标 | Spearman ρ | p | 结论 | 说明 |",
        "|---|---|---|---|---|",
    ]
    for name, rho, p, verdict, why in table:
        lines.append(f"| `{name}` | {rho:.3f} | {p:.3f} | {verdict} | {why} |")
    lines += [
        "",
        "## 怎么用这份报告",
        "",
        "1. `下线/重做`：该指标不得单独决定达线；若它当前参与打分，按"
        " `docs/quality-rules-current.md` 的流程改权重或词表（改完跑 rules_codegen）；",
        "2. `降权`：只作提示（note 级），不进 `pass` 判定；",
        "3. `保留`：可作为门禁依据，但每轮词表/阈值改动后应重跑本实验；",
        "4. ρ 为负 = 指标与人评反向（越“好”越差），这是**最危险的**一类，"
        "必须立刻降权并复查词表（典型成因：词表奖励套话）。",
        "",
        "> 样本 < 30 章时结论只作方向性参考；把好中差三档都覆盖到，"
        "否则相关性会被样本选择本身塑形。",
        "",
    ]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description="质检指标 vs 人评相关性（Spearman + 置换检验）")
    ap.add_argument("--annotations", default=str(DEFAULT_ANNOTATIONS),
                    help="标注 JSONL 路径（默认 docs/human-eval/annotations.jsonl）")
    ap.add_argument("--init", action="store_true", help="生成标注模板后退出")
    ap.add_argument("--min-n", type=int, default=10, help="最少样本数（默认 10，低于即失败）")
    ap.add_argument("--permutations", type=int, default=2000, help="置换次数（默认 2000）")
    ap.add_argument("--seed", type=int, default=20261001, help="置换随机种子（保证可复现）")
    ap.add_argument("--out", default="", help="把报告写入该路径（默认只打印）")
    args = ap.parse_args()

    path = Path(args.annotations)
    if args.init:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            print(f"已存在，未覆盖：{path}")
            return 0
        with path.open("w", encoding="utf-8", newline="\n") as fh:
            fh.write(TEMPLATE)
        print(f"已生成标注模板：{path}")
        print("填写要点见文件头注释；每行一章，human 为人工总分（0~100）。")
        return 0

    items = load_annotations(path)
    if len(items) < args.min_n:
        print(f"样本不足：{len(items)} 章 < {args.min_n} 章——"
              "相关性在这么小的样本上没有结论价值（脚本拒绝给出「通过」判定）。")
        print("补足样本后重跑；标注模板见 docs/human-eval/annotations.jsonl。")
        return 2

    humans = [it[2] for it in items]
    metric_values = {}
    for ident, text, _human, _rater, _note in items:
        for k, v in metrics_of(text).items():
            metric_values.setdefault(k, []).append(v)

    table = []
    for name in sorted(metric_values):
        vals = metric_values[name]
        if len(set(vals)) < 2:
            table.append((name, 0.0, 1.0, "下线/重做", "样本内取值无变化，无法判定"))
            continue
        rho = spearman(vals, humans)
        p = permutation_p(vals, humans, rho, args.permutations, args.seed)
        verdict, why = verdict_for(rho, p)
        table.append((name, rho, p, verdict, why))

    report = render_report(items, table, args.permutations, args.seed)
    print(report)
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open("w", encoding="utf-8", newline="\n") as fh:
            fh.write(report)
        print(f"报告已写入：{out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
