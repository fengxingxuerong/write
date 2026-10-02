#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""双端词表 A/B 工具：用**真实成书**量化收编影响面（离线、零 LLM 成本）。

背景
----
docs/quality-rules-current.md 第三节记录了若干「已知端间不对称」，其中 4 项
标注为「收编前需真机 A/B 定哪一侧更准」。本脚本就是把那句「需 A/B」变成
「已用真实语料 A/B 过」的工具——它不改任何词表，只**测量**分歧的实际影响面，
为是否收编提供依据。

测量的 4 项（均为**同用途**，即同一指标的两端实现）：

| 项 | Dart | Python | 性质 |
|---|---|---|---|
| `conflictWords`   | `_conflict` 31 词   | `CONFLICT_WORDS` 40 词   | Dart 是 Python 真子集 |
| `driveWords`      | `_drive` 44 词      | `DRIVE_WORDS` 45 词      | Dart 是 Python 真子集 |
| `aiClicheWords`   | `aiClicheWords` 21 | `AI_CLICHE` 18           | Dart 是 Python 超集 |
| `clicheTables`    | `gateClichePhrases` 19 | `reviewClicheSentences` 34 | 双向独有（口径分歧）|

用法
----
    python scripts/ab_rules_parity.py                 # 全量扫描 + 报告
    python scripts/ab_rules_parity.py --limit 20      # 只扫前 20 份（快）
    python scripts/ab_rules_parity.py --json          # 输出 JSON（便于自动化）

判读要点：子集类（conflict/drive）只要「Python 独有的词在真实语料里确实会命中」
且命中后判定方向正确，就说明 Dart 漏词是**真漏判**、应当收编；口径分歧类
（cliche/aiCliche）看独有词是否高频命中——高频说明两端会持续给出不同结论，
需要产品裁决，不宜由脚本单方面合并。
"""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import fanqie_review as fr  # noqa: E402
import generate_novel as gn  # noqa: E402
import quality_rules_generated as gen  # noqa: E402


# Dart 侧字面量（从 lib/engine/quality/fanqie_gate_checker.dart 与
# lib/engine/quality/quality_rules.g.dart 抄录）。**刻意手写而非解析 Dart**：
# Dart 侧那些是 private/生成物常量，解析源码去取字面量脆弱且会绕过类型检查；
# 这里改成「双端词表登记 + 测试断言与 Dart 源一致」，漂移时测试会失败。
# conflictWords 已于 2026-10-03 收编进单一数据源，两端同源——这里直接取生成物，
# 不再手抄一份 Dart 字面量（手抄的那份会在收编后变成过期副本，得出「仍不一致」
# 的错误结论，恰好是本工具要防的那类假信号）。
DART_CONFLICT = list(gen.CONFLICT_WORDS)
DART_DRIVE = [
    "说", "道", "问", "答", "喊", "笑", "看", "抓", "推", "砸", "拔", "转身",
    "走", "跑", "冲", "拿", "递", "写", "敲", "点", "掀", "摸", "掏", "塞",
    "死", "伤", "血", "钱", "字", "信", "刀", "枪", "门", "窗", "牌", "图",
    "答应", "拒绝", "决定", "必须", "马上", "今晚", "三天", "名字",
]
DART_AI_CLICHE = [
    "嘴角", "唇角", "眼底", "眼神", "目光", "仿佛", "似乎", "宛如",
    "空气", "心跳", "深吸", "命运", "轨迹", "万语", "舒了一口",
    "微微上扬", "闪过一丝", "勾起一抹", "空气凝固", "嘴角勾起", "眼底闪过",
]


def _hits(text: str, words) -> int:
    """非重叠计数（与两端实际使用的 contains 语义一致）。"""
    return sum(text.count(w) for w in words if w)


def _hit_words(text: str, words):
    return sorted({w for w in words if w and w in text})


def load_corpus(limit: int = 0):
    """加载真实成书语料（txt 成书 + jsonl + 人评样本章）。"""
    files = []
    files += sorted((ROOT / "data").rglob("*.txt"))
    files += sorted((ROOT / "docs" / "human-eval" / "samples").glob("*.txt"))
    files += sorted((ROOT / "verify-logs").rglob("*.txt"))
    files = [p for p in files if p.is_file()]
    if limit:
        files = files[:limit]
    out = []
    for p in files:
        try:
            out.append((p.name, p.read_text(encoding="utf-8", errors="replace")))
        except Exception:
            continue
    return out
def analyze(corpus):
    """逐项统计：两端差集词在真实语料里的实际命中情况。"""
    result = {}

    # ---- 1) conflictWords / 2) driveWords：Dart 是 Python 真子集 ----
    for key, py_words, dart_words in (
            ("conflictWords", fr.CONFLICT_WORDS, DART_CONFLICT),
            ("driveWords", fr.DRIVE_WORDS, DART_DRIVE)):
        py_only = [w for w in py_words if w not in dart_words]
        dart_only = [w for w in dart_words if w not in py_words]
        hits, affected = {}, set()
        for name, text in corpus:
            hit = _hit_words(text, py_only)
            if hit:
                affected.add(name)
                for w in hit:
                    hits[w] = hits.get(w, 0) + text.count(w)
        result[key] = {
            "kind": "subset",
            "py_only": py_only,
            "dart_only": dart_only,
            "hit_counts": dict(sorted(hits.items(), key=lambda kv: -kv[1])),
            "files_affected": len(affected),
            "files_total": len(corpus),
            "verdict": None,
        }

    # ---- 3) aiClicheWords：Dart（AI_ECHO）是 Python AI_CLICHE 的超集 ----
    dart_only_ai = [w for w in DART_AI_CLICHE if w not in gn.AI_CLICHE]
    py_only_ai = [w for w in gn.AI_CLICHE if w not in DART_AI_CLICHE]
    ai_hits, ai_affected = {}, set()
    for name, text in corpus:
        hit = _hit_words(text, dart_only_ai)
        if hit:
            ai_affected.add(name)
            for w in hit:
                ai_hits[w] = ai_hits.get(w, 0) + text.count(w)
    result["aiClicheWords"] = {
        "kind": "superset",
        "dart_only": dart_only_ai,
        "py_only": py_only_ai,
        "hit_counts": dict(sorted(ai_hits.items(), key=lambda kv: -kv[1])),
        "files_affected": len(ai_affected),
        "files_total": len(corpus),
        "verdict": None,
    }

    # ---- 4) clicheTables：双向独有（口径设计分歧） ----
    dart_only_cliche = [w for w in gen.GATE_CLICHE_PHRASES
                        if w not in gen.REVIEW_CLICHE_SENTENCES]
    py_only_cliche = [w for w in gen.REVIEW_CLICHE_SENTENCES
                      if w not in gen.GATE_CLICHE_PHRASES]
    cd_hits, cp_hits, cd_files, cp_files = {}, {}, set(), set()
    for name, text in corpus:
        hd = _hit_words(text, dart_only_cliche)
        if hd:
            cd_files.add(name)
            for w in hd:
                cd_hits[w] = cd_hits.get(w, 0) + text.count(w)
        hp = _hit_words(text, py_only_cliche)
        if hp:
            cp_files.add(name)
            for w in hp:
                cp_hits[w] = cp_hits.get(w, 0) + text.count(w)
    result["clicheTables"] = {
        "kind": "divergent",
        "dart_only": dart_only_cliche,
        "py_only": py_only_cliche,
        "dart_hit_counts": dict(sorted(cd_hits.items(), key=lambda kv: -kv[1])),
        "py_hit_counts": dict(sorted(cp_hits.items(), key=lambda kv: -kv[1])),
        "dart_files_affected": len(cd_files),
        "py_files_affected": len(cp_files),
        "files_total": len(corpus),
        "verdict": None,
    }

    _assign_verdicts(result, len(corpus))
    return result


def _assign_verdicts(result, n):
    """按实测数据给出收编建议（只输出建议，不自动改表）。"""
    # 子集类：Dart 缺词且这些词在真实语料会命中 → Dart 真漏判 → 建议收编
    for key in ("conflictWords", "driveWords"):
        r = result[key]
        if not r["py_only"]:
            r["verdict"] = "已一致，无需收编"
        elif r["files_affected"] == 0:
            r["verdict"] = (f"Python 独有 {len(r['py_only'])} 词在 {n} 份真实语料"
                            f"上零命中 → 实测无影响，可暂不收编")
        else:
            pct = 100.0 * r["files_affected"] / n
            r["verdict"] = (f"Python 独有 {len(r['py_only'])} 词命中 "
                            f"{r['files_affected']}/{n} 份（{pct:.1f}%）"
                            f" → Dart 侧为真漏判，建议收编进 JSON")

    # 超集类：Dart 多词 → 两端 AI 味数值持续不同
    r = result["aiClicheWords"]
    if not r["dart_only"]:
        r["verdict"] = "已一致，无需收编"
    elif r["files_affected"] == 0:
        r["verdict"] = (f"Dart 独有 {len(r['dart_only'])} 词在 {n} 份真实语料"
                        f"上零命中 → 实测无影响，可暂不收编")
    else:
        pct = 100.0 * r["files_affected"] / n
        r["verdict"] = (f"Dart 独有 {len(r['dart_only'])} 词命中 "
                        f"{r['files_affected']}/{n} 份（{pct:.1f}%）"
                        f" → 两端 AI 味数值持续不同，需产品裁决口径")

    # 分歧类：双向独有 → 口径设计分歧，不宜由脚本合并
    r = result["clicheTables"]
    r["verdict"] = (
        f"Dart 独有 {len(r['dart_only'])} 词命中 {r['dart_files_affected']}/{n} 份；"
        f"Python 独有 {len(r['py_only'])} 词命中 {r['py_files_affected']}/{n} 份"
        f" → 两端各有独有词且都在用，是**口径设计分歧**（短词更宽 vs 长句更准），"
        f"统一会同时改变两端分数与定点修触发率，需产品裁决，不宜由脚本合并")


def render(result, corpus) -> str:
    out = ["", "=" * 72,
           "双端词表 A/B（真实成书语料，实测不改任何词表）",
           "=" * 72,
           f"语料：{len(corpus)} 份（data/*.txt + verify-logs + 人评样本章）"]
    titles = {
        "conflictWords": "conflictWords · 首屏冲突信号（Dart _conflict ↔ Python CONFLICT_WORDS）",
        "driveWords": "driveWords · 段落推进力（Dart _drive ↔ Python DRIVE_WORDS）",
        "aiClicheWords": "aiClicheWords · AI 腔（Dart AI_ECHO ↔ Python AI_CLICHE）",
        "clicheTables": "clicheTables · 同质化套句（Dart gateCliche ↔ Python reviewCliche）",
    }
    for key, title in titles.items():
        r = result[key]
        out += ["", f"■ {title}", f"  类型：{r['kind']}"]
        if key == "clicheTables":
            out.append(f"  Dart 独有 {len(r['dart_only'])} 词："
                       f"{'、'.join(r['dart_only'][:8])}"
                       f"{' …' if len(r['dart_only']) > 8 else ''}")
            out.append(f"  Python 独有 {len(r['py_only'])} 词："
                       f"{'、'.join(r['py_only'][:8])}"
                       f"{' …' if len(r['py_only']) > 8 else ''}")
            out.append(f"  Dart 独有词命中：{r['dart_files_affected']}/{r['files_total']} 份")
            out.append(f"  Python 独有词命中：{r['py_files_affected']}/{r['files_total']} 份")
        else:
            out.append(f"  Python 独有 {len(r['py_only'])} 词："
                       f"{'、'.join(r['py_only'][:10])}"
                       f"{' …' if len(r['py_only']) > 10 else ''}")
            out.append(f"  Dart 独有 {len(r['dart_only'])} 词："
                       f"{'、'.join(r['dart_only'][:10]) if r['dart_only'] else '（无）'}")
            out.append(f"  独有词命中文件数：{r['files_affected']}/{r['files_total']}")
            for w, c in list(r["hit_counts"].items())[:8]:
                out.append(f"    - {w} × {c}")
        out.append(f"  ▶ 结论：{r['verdict']}")
    out += ["", "=" * 72,
           "说明：本工具只测量、不改表。是否收编见上面「结论」列建议；",
           "改表一律走 rules/quality_rules.json → rules_codegen.py → 双端对账测试。",
           "=" * 72]
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description="双端词表 A/B（真实语料测量）")
    ap.add_argument("--limit", type=int, default=0, help="只扫前 N 份语料")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    a = ap.parse_args()
    corpus = load_corpus(a.limit)
    if not corpus:
        print("没有可用语料（data/ 与 docs/human-eval/samples/ 为空）")
        return 1
    result = analyze(corpus)
    if a.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(render(result, corpus))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
