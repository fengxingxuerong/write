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
    | `instructionMarks`| `_instructionMark` 21 | `INSTRUCTION_MARKERS` 24 | Dart 是 Python 真子集 |

⚠ `instructionMarks`（2026-10-03 补）的口径与其余四项**不同**，不能数词表命中：
这张表只在「叙事成立分类（`NARRATIVE_OK_CATEGORIES`）的红线命中 ±40 字窗口内」
才起作用，而「价格」「加入」「群」这类词在正文里遍地都是，命中数高说明不了
任何问题。真正该测的是**收编后「否决」条数的增量**（会不会凭空多出否决），
口径与 scripts/probe/probe_instruction_marker.py 当初那句
「否决升级条数差值 +0」一致。

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
import re
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
# instructionMarks 已于 2026-10-03 收编进单一数据源，两端同源——与 conflictWords
# 同理直接取生成物，不再手抄 Dart 字面量。
#
# 这一条是实测踩过的坑：收编前这里手抄的是 Dart 侧 21 词，收编后**忘了改**，
# 于是工具拿 21 词去比 Python 的 24 词，得出「Python 独有 3 词 → 建议收编」——
# 而收编早已完成。工具给出的是**已完成动作的假建议**，且看起来完全合理：
# 这类「过期副本」比没有工具更危险，因为它让人以为差异仍存在。
# 与 DART_CONFLICT 用同一手法根治：取生成物，让副本从根上不存在。
#
# 判定口径不变：这张表只在叙事成立分类的红线 ±40 字窗口内起作用，须测否决增量。
DART_INSTRUCTION_MARK = list(gen.INSTRUCTION_MARKS)

# Dart _extraRedline：**从 Dart 源码解析**，不再手抄。
#
# 为什么不手抄：手抄的那份会在 Dart 侧收编后变成过期副本，得出「Dart 仍是
# Python 真子集、建议收编」之类**已完成动作的假建议**——本轮就踩过一次
# （DART_INSTRUCTION_MARK 忘了跟着收编改，工具建议了一个早已做完的动作）。
#
# 为什么不引生成物：其中「宗教民族」是**故意保持分歧**的（双向独有，且
# 生成物独有的「礼拜」在真实成书里命中 2 份），必须读 Dart 自己的表，
# 不能用生成物冒充——否则会把这处分歧悄悄抹平。
DART_SRC = ROOT / "lib" / "engine" / "quality" / "fanqie_gate_checker.dart"


def snake_upper(camel: str) -> str:
    """camelCase -> UPPER_SNAKE_CASE（与 rules_codegen 的命名规则一致）。"""
    out = []
    for i, ch in enumerate(camel):
        if ch.isupper() and i > 0:
            out.append("_")
        out.append(ch.upper())
    return "".join(out)


def _dart_extra_redline():
    """解析 Dart _extraRedline 的「分类名 -> 词表」。只认 QualityRules.x 形式。

    对已收编的类（Dart 写作 `QualityRules.redlinePolitics`）返回生成物值；
    对故意保留自有字面量的类（如宗教民族）返回其 Dart 字面量。
    解析不了就报错——宁可让工具失败，也不要静默用错误的表得出错误结论。
    """
    text = DART_SRC.read_text(encoding="utf-8")
    m = re.search(
        r"_extraRedline\s*=\s*<String,\s*List<String>>\{(.*?)\n  \};", text, re.S)
    if not m:
        raise RuntimeError("未在 fanqie_gate_checker.dart 解析到 _extraRedline")
    body = m.group(1)

    out: dict = {}
    # 形式 1：'分类名': QualityRules.xxx,
    for cm in re.finditer(r"'([^']+)':\s*QualityRules\.(\w+),", body):
        name, const = cm.group(1), cm.group(2)
        if not hasattr(gen, snake_upper(const)):
            raise RuntimeError(f"QualityRules.{const} 在生成物中不存在")
        out[name] = list(getattr(gen, snake_upper(const)))
    # 形式 2：'分类名': <String>[ ... ],
    for cm in re.finditer(r"'([^']+)':\s*<String>\[(.*?)\]", body, re.S):
        name = cm.group(1)
        if name in out:
            continue  # 形式 1 已解析过（同一类不会既引生成物又写字面量）
        out[name] = re.findall(r"'([^']+)'", cm.group(2))
    if not out:
        raise RuntimeError("_extraRedline 解析结果为空")
    return out


DART_EXTRA_REDLINE = _dart_extra_redline()


# 「教唆细节」（Dart 分类名）对应生成物的 redlineIllegalDetail（「教唆与违法细节」）。
# 分类名两侧不同但语义同一，故这里显式配对，不靠名字自动匹配——
# 自动匹配会因「教唆细节 ≠ 教唆与违法细节」而漏配。
REDLINE_PAIRS = [
    ("时政敏感", "redlinePolitics"),
    ("宗教民族", "redlineReligion"),
    ("未成年风险", "redlineMinorRisk"),
    ("现实品牌与真人", "redlineBrandCelebrity"),
    ("教唆细节", "redlineIllegalDetail"),
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

    # ---- 5) instructionMarks：测「否决条数增量」，不测词表命中 ----
    result["instructionMarks"] = _analyze_instruction_marks(corpus)

    # ---- 6) extraRedlineTables：番茄红线五类（Dart _extraRedline ↔ 生成物）----
    # 红线类与前面几项不同：漏判性质比多判严重（Dart 无此词 → 不判违规），
    # 故每类都同时统计两侧独有词的命中，而不是只看 Python 独有词。
    result["extraRedlineTables"] = _analyze_extra_redline(corpus)

    _assign_verdicts(result, len(corpus))
    return result


def _analyze_extra_redline(corpus):
    """番茄红线五类的双端差集 + 各自命中面。

    与其余四项的关键差异：**两个方向都要测**。
    - Python 独有词命中 → Dart 漏判（该判没判，性质更严重）；
    - Dart 独有词命中 → Dart 多判（会误伤正常情节）。
    只测一边就下结论是本项目吃过的亏（aiClicheWords 曾据「Python 独有词
    零命中」就断言无影响，实际 Dart 独有词是会命中的）。

    分类名两侧不同（教唆细节 ↔ 教唆与违法细节），故显式配对，
    不靠名字自动匹配。
    """
    out = {}
    for dart_cat, const in REDLINE_PAIRS:
        dart_words = DART_EXTRA_REDLINE.get(dart_cat)
        if dart_words is None:
            raise RuntimeError(
                f"Dart _extraRedline 解析结果里没有分类「{dart_cat}」——"
                f"实际解析到：{sorted(DART_EXTRA_REDLINE)}")
        py_words = list(getattr(gen, snake_upper(const)))
        py_only = [w for w in py_words if w not in dart_words]
        dart_only = [w for w in dart_words if w not in py_words]

        py_hits, py_files = {}, set()
        dart_hits, dart_files = {}, set()
        for name, text in corpus:
            hp = _hit_words(text, py_only)
            if hp:
                py_files.add(name)
                for w in hp:
                    py_hits[w] = py_hits.get(w, 0) + text.count(w)
            hd = _hit_words(text, dart_only)
            if hd:
                dart_files.add(name)
                for w in hd:
                    dart_hits[w] = dart_hits.get(w, 0) + text.count(w)

        kind = ("subset" if not dart_only and py_only
                else "divergent" if dart_only and py_only
                else "dart_superset" if dart_only else "identical")
        out[dart_cat] = {
            "kind": kind,
            "const": const,
            "dart_count": len(dart_words),
            "py_count": len(py_words),
            "py_only": py_only,
            "dart_only": dart_only,
            "py_hit_counts": dict(sorted(py_hits.items(), key=lambda kv: -kv[1])),
            "dart_hit_counts": dict(sorted(dart_hits.items(), key=lambda kv: -kv[1])),
            "py_files_affected": len(py_files),
            "dart_files_affected": len(dart_files),
            "files_total": len(corpus),
            "verdict": None,
        }
    return out


def _analyze_instruction_marks(corpus):
    """收编 instructionMarks 会让「否决」凭空多出多少条。

    为什么不能数词表命中（2026-10-03）：
    `INSTRUCTION_MARKERS` 只在**叙事成立分类**（NARRATIVE_OK_CATEGORIES）的红线
    命中 ±40 字窗口内才起作用。「价格」「加入」「群」在网文正文里俯拾即是，
    词表命中数高不代表判定会变；反之零命中也可能只是因为该样本恰好没有
    教唆类红线。唯一有意义的量是**收编前后否决条数的差值**。

    实现口径与 fanqie_review.redline_scan 完全一致（白名单优先 → 叙事成立分类
    走 marker 升级 → 其余直接否决），只是把 markers 换成参数，便于跑 A/B。
    不复制判定逻辑而是抽参数，是为避免「探针自己写错一套判定」——
    那会让探针给出假信号，而假信号比没有信号更糟。
    """
    py_only = [w for w in fr.INSTRUCTION_MARKERS
               if w not in DART_INSTRUCTION_MARK]
    dart_only = [w for w in DART_INSTRUCTION_MARK
                 if w not in fr.INSTRUCTION_MARKERS]

    def veto_count(text, markers):
        """按给定 markers 复算「否决」条数（口径同 redline_scan）。"""
        n = 0
        for cat, words in fr.REDLINE.items():
            for w in words:
                for m in re.finditer(re.escape(w.strip()), text or ""):
                    ctx = (text or "")[max(0, m.start() - 12):m.end() + 12].replace("\n", " ")
                    wide = (text or "")[max(0, m.start() - 40):m.end() + 40]
                    wl = fr.REDLINE_WHITELIST.get(w)
                    if wl and wl.search(ctx):
                        continue  # 白名单已降级为提示，不受 marker 影响
                    if cat in fr.NARRATIVE_OK_CATEGORIES:
                        if any(k in wide for k in markers):
                            n += 1
                    else:
                        n += 1  # 非叙事成立分类恒为否决，与 markers 无关
        return n

    base = cur = 0
    extra_files = []
    for name, text in corpus:
        a = veto_count(text, DART_INSTRUCTION_MARK)
        b = veto_count(text, fr.INSTRUCTION_MARKERS)
        base += a
        cur += b
        if b > a:
            extra_files.append((name, b - a))

    return {
        "kind": "subset",
        "py_only": py_only,
        "dart_only": dart_only,
        "veto_with_dart_table": base,
        "veto_with_py_table": cur,
        "veto_delta": cur - base,
        "files_with_extra_veto": extra_files,
        "files_total": len(corpus),
        "files_affected": len(extra_files),
        "hit_counts": {},  # 该表不以词表命中为指标
        "verdict": None,
    }


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

    # instructionMarks：按**否决增量**判读，不按词表命中
    r = result["instructionMarks"]
    if not r["py_only"] and not r["dart_only"]:
        r["verdict"] = "已一致，无需收编"
    elif r["veto_delta"] == 0:
        r["verdict"] = (
            f"Python 独有 {len(r['py_only'])} 词（{'、'.join(r['py_only'])}）在 {n} 份"
            f"真实语料上**否决条数增量为 0**（两表同为 {r['veto_with_dart_table']} 条）"
            f" → 收编零判定风险，建议收编进 JSON 让两端结构上不再漂移")
    else:
        r["verdict"] = (
            f"Python 独有 {len(r['py_only'])} 词（{'、'.join(r['py_only'])}）会让否决"
            f"从 {r['veto_with_dart_table']} 条增至 {r['veto_with_py_table']} 条"
            f"（+{r['veto_delta']}），命中 {r['files_affected']}/{n} 份 → "
            f"会改变判定结果，需产品裁决后再收编")

    # extraRedlineTables：按类别分别给建议（漏判与多判都要说清）
    for cat, r in result["extraRedlineTables"].items():
        py_hit = r["py_files_affected"]
        dart_hit = r["dart_files_affected"]
        if r["kind"] == "identical":
            r["verdict"] = "已一致，无需收编"
        elif r["kind"] == "subset":
            if py_hit == 0:
                r["verdict"] = (
                    f"Dart 是 {r['const']} 真子集（缺 {len(r['py_only'])} 词），"
                    f"但这 {len(r['py_only'])} 词在 {n} 份真实语料上零命中 → "
                    f"实测无漏判，取全集零风险，建议收编")
            else:
                r["verdict"] = (
                    f"Dart 缺 {len(r['py_only'])} 词且命中 {py_hit}/{n} 份 → "
                    f"Dart 侧**存在真实漏判**，建议收编以消除")
        else:
            r["verdict"] = (
                f"双向独有（Python 独有 {len(r['py_only'])} 词命中 {py_hit}/{n} 份；"
                f"Dart 独有 {len(r['dart_only'])} 词命中 {dart_hit}/{n} 份）"
                f" → 属口径设计分歧（两端各有独有词且都在用），"
                f"合并会同时改变两端的漏判与多判面，须产品裁决，不宜由脚本合并")

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
        "instructionMarks": "instructionMarks · 教唆语境标记（Dart _instructionMark ↔ Python INSTRUCTION_MARKERS）",
    }

    # extraRedlineTables 是「一组五类」，与前面按 key 取单条的结构不同，
    # 故单独成节而非塞进 titles 循环。
    if "extraRedlineTables" in result:
        out += ["", "=" * 72,
                "■ extraRedlineTables · 番茄红线五类"
                "（Dart _extraRedline ↔ Python 生成物 redline*）",
                "-" * 72]
        for cat, r in result["extraRedlineTables"].items():
            out += ["", f"  ▸ {cat} · Dart {r['dart_count']} 词 ↔ "
                        f"Python {r['py_count']} 词 [{r['kind']}]"]
            out.append(f"    Python 独有 {len(r['py_only'])} 词："
                       + ("、".join(r['py_only'][:10])
                          + (" …" if len(r['py_only']) > 10 else "")
                          if r['py_only'] else "（无）"))
            out.append(f"    Dart 独有 {len(r['dart_only'])} 词："
                       + ("、".join(r['dart_only'][:10])
                          + (" …" if len(r['dart_only']) > 10 else "")
                          if r['dart_only'] else "（无）"))
            out.append(f"    Python 独有词命中（漏判面）：{r['py_files_affected']}"
                       f"/{r['files_total']} 份"
                       + (f"  {r['py_hit_counts']}" if r['py_hit_counts'] else ""))
            out.append(f"    Dart 独有词命中（多判面）：{r['dart_files_affected']}"
                       f"/{r['files_total']} 份"
                       + (f"  {r['dart_hit_counts']}" if r['dart_hit_counts'] else ""))
            out.append(f"    ▶ {r['verdict']}")
        out += ["-" * 72,
                "  注：红线类两个方向都要看——Python 独有词命中 = Dart 漏判"
                "（该判没判），Dart 独有词命中 = 多判（会误伤）。"]

    for key, title in titles.items():
        r = result[key]
        out += ["", f"■ {title}", f"  类型：{r['kind']}"]
        if key == "instructionMarks":
            # 该表按「否决增量」判读，渲染口径与其余四项刻意不同。
            out.append(f"  Python 独有 {len(r['py_only'])} 词："
                       f"{'、'.join(r['py_only']) if r['py_only'] else '（无）'}")
            out.append(f"  Dart 独有 {len(r['dart_only'])} 词："
                       f"{'、'.join(r['dart_only']) if r['dart_only'] else '（无）'}")
            out.append(f"  否决条数（Dart 表 {len(DART_INSTRUCTION_MARK)} 词）："
                       f"{r['veto_with_dart_table']}")
            out.append(f"  否决条数（Python 表 {len(fr.INSTRUCTION_MARKERS)} 词）："
                       f"{r['veto_with_py_table']}")
            out.append(f"  否决增量：{r['veto_delta']:+d}"
                       f"（判定结果{'不变' if r['veto_delta'] == 0 else '会变'}）")
            for name, d in r["files_with_extra_veto"][:5]:
                out.append(f"    - {name}：多 {d} 条否决")
            out += ["", "  （该表不适用「词表命中数」口径——价格/加入/群等词在正文里"
                    "遍地皆是，命中高说明不了判定会变，故只报否决增量。）"]
            out.append(f"  ▶ 结论：{r['verdict']}")
            continue  # 已自渲染并给出结论，不再落入下面的通用分支
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
