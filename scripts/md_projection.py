#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""随书 Markdown 人类可读投影（P0-3，借鉴 InkOS truth files 双层设计）。

jsonl 是权威账本（机器可读、断点续传依据）；本模块把作者最常要看的三份视图
随书导出为 Markdown 投影（人可读、可直接进编辑器审阅）：

  <书>.当前状态.md  —— 跨章状态清单 + 户籍表（人物）+ 数字台账
  <书>.伏笔台账.md  —— open/closed 伏笔、埋设/回收章号、超时未回收告警
  <书>.控制面.md    —— 作者意图 + 近 3 章关注点（目标/评审问题/读者反馈）+ 下章提醒

约定：
- 纯本地零 LLM 调用；jsonl 永远是权威数据，投影是只读快照
- 任何小节解析失败只跳过该小节（绝不阻塞流水线），投影之间互不影响
- 作者意图优先取 jsonl 的 type=author_intent 最后一条（可手工/界面写入），
  无记录时回落大纲（hook/blurb/tags/主角）作「大纲意图摘要」

用法：
  python scripts/md_projection.py <progress.jsonl>
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from generate_novel import _sidecar_path  # noqa: E402

# 超时未回收告警阈值（与 novel_pipeline.check_open_foreshadows 同口径）
STALE_AFTER = 5


def _iter_records(path):
    """逐行读 jsonl，跳过损坏行（投影是只读视图，坏行不阻断）。"""
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if isinstance(rec, dict) and rec.get("type"):
                yield rec


def _maybe_json(value):
    """data 可能是 dict 也可能是 JSON 字符串（历史写入两种都有），统一解开。"""
    if isinstance(value, str):
        try:
            return json.loads(value)
        except Exception:
            return value
    return value


def load_projection_state(path):
    """回放 jsonl，收集三份投影所需的全部输入（last-wins 与续传口径一致）。"""
    st = {
        "outline": None,
        "state_track": "",
        "foreshadows": [],
        "registry": None,
        "author_intent": "",
        "chapters": [],
        "reviews": {},
        "reader_feedback": "",
        "reader_feedback_idx": 0,
    }
    for rec in _iter_records(path):
        t = rec.get("type")
        data = rec.get("data")
        if t == "outline":
            obj = _maybe_json(data)
            if isinstance(obj, dict):
                st["outline"] = obj
        elif t == "state_track":
            if isinstance(data, str):
                st["state_track"] = data
            else:
                st["state_track"] = json.dumps(data, ensure_ascii=False)
        elif t == "foreshadow":
            ledger = _maybe_json(data)
            if isinstance(ledger, dict):
                items = ledger.get("foreshadows", [])
            elif isinstance(ledger, list):
                items = ledger
            else:
                items = []
            st["foreshadows"] = [x for x in items if isinstance(x, dict)]
        elif t == "registry":
            reg = _maybe_json(data)
            if isinstance(reg, dict):
                st["registry"] = reg
        elif t == "author_intent":
            if isinstance(data, str):
                st["author_intent"] = data
            elif isinstance(data, dict):
                st["author_intent"] = str(data.get("text") or data.get("intent") or "")
        elif t == "chapter":
            ch = _maybe_json(data)
            if isinstance(ch, dict) and isinstance(ch.get("idx"), int):
                st["chapters"].append(ch)
        elif t == "review":
            rv = _maybe_json(data)
            if isinstance(rv, dict) and isinstance(rv.get("idx"), int):
                st["reviews"][rv["idx"]] = rv
        elif t == "reader_feedback":
            fb = _maybe_json(data)
            if isinstance(fb, dict) and isinstance(fb.get("idx"), int):
                st["reader_feedback"] = str(fb.get("feedback") or "")
                st["reader_feedback_idx"] = fb["idx"]
    st["chapters"].sort(key=lambda c: c["idx"])
    return st


def render_state_md(st, path):
    """当前状态.md：跨章状态清单 + 户籍表 + 数字台账。"""
    out = [_header(st, "当前状态", path)]
    state_text = (st.get("state_track") or "").strip()
    out.append("\n## 跨章状态清单\n")
    if state_text:
        # 状态条目以中文分号串接，拆成 bullet 便于逐条审阅；不改写原文。
        segs = [s.strip().rstrip("。") for s in state_text.replace("\n", "；").split("；")]
        for seg in segs:
            if seg:
                out.append(f"- {seg}")
    else:
        out.append("_暂无状态记录（尚无章节完成状态提取）_")
    reg = st.get("registry")
    if isinstance(reg, dict) and reg:
        chars = [c for c in (reg.get("characters") or []) if isinstance(c, dict)]
        facts = [x for x in (reg.get("facts") or []) if isinstance(x, dict)]
        if chars:
            out.append("\n## 户籍表 · 人物\n")
            out.append("| 人物 | 身份 | 首见 |")
            out.append("|---|---|---|")
            for c in chars:
                out.append(f"| {c.get('name', '?')} | {str(c.get('identity', '')).replace('|', '／')} "
                           f"| 第{c.get('first_seen', '?')}章 |")
        if facts:
            out.append("\n## 数字台账（首次出现即锁定）\n")
            out.append("| 数值 | 首见 |")
            out.append("|---|---|")
            for x in facts:
                out.append(f"| {x.get('value', '?')} | 第{x.get('first_seen', '?')}章 |")
    return "\n".join(out) + "\n"


def render_foreshadow_md(st, path):
    """伏笔台账.md：open/closed 分列 + 超时未回收告警。"""
    out = [_header(st, "伏笔台账", path)]
    items = st.get("foreshadows") or []
    opens = [x for x in items if x.get("status") == "open" and x.get("recovered") is None]
    closed = [x for x in items if x.get("status") == "closed" or x.get("recovered") is not None]
    last_idx = st["chapters"][-1]["idx"] if st.get("chapters") else 0

    out.append(f"\n## 未回收（open）· {len(opens)} 条\n")
    if not opens:
        out.append("_无_")
    for x in opens:
        planted = x.get("planted", "?")
        age = (last_idx - planted) if isinstance(planted, int) and isinstance(last_idx, int) else 0
        warn = f" ⚠ 已{age}章未收" if age >= STALE_AFTER else ""
        out.append(f"- [第{planted}章埋] {x.get('desc', '?')}{warn}")

    out.append(f"\n## 已回收（closed）· {len(closed)} 条\n")
    if not closed:
        out.append("_无_")
    for x in closed:
        out.append(f"- [第{x.get('planted', '?')}章埋 → 第{x.get('recovered', '?')}章收] "
                   f"{x.get('desc', '?')}")
    return "\n".join(out) + "\n"


def _book_title(st):
    outline = st.get("outline")
    if isinstance(outline, dict):
        return str(outline.get("title") or "未命名")
    return "未命名"


def _header(st, name, path):
    n_ch = len(st.get("chapters") or [])
    total = sum(int(c.get("words") or 0) for c in st.get("chapters") or [])
    return (f"# 《{_book_title(st)}》{name}\n\n"
            f"> 自动生成自 `{os.path.basename(path)}` 账本（只读投影，权威数据以 jsonl 为准）。\n"
            f"> 截至第 {n_ch} 章 · 累计 {total} 字 · 导出时间 {time.strftime('%Y-%m-%d %H:%M')}\n")


def render_control_md(st, path):
    """控制面.md：作者意图 + 近 3 章关注点 + 下章提醒。"""
    out = [_header(st, "控制面", path)]
    outline = st.get("outline") if isinstance(st.get("outline"), dict) else {}
    intent = (st.get("author_intent") or "").strip()
    out.append("\n## 作者意图\n")
    if intent:
        for line in intent.splitlines():
            out.append(f"- {line}" if line.strip() else "")
    else:
        out.append("_（无 type=author_intent 记录，以下为大纲意图摘要）_")
        if outline.get("hook"):
            out.append(f"- 核心钩子：{outline['hook']}")
        if outline.get("blurb"):
            out.append(f"- 简纲：{outline['blurb']}")
        tags = outline.get("tags")
        if isinstance(tags, list) and tags:
            out.append(f"- 标签：{'、'.join(str(t) for t in tags)}")
        proto = outline.get("protagonist")
        if isinstance(proto, dict) and proto.get("name"):
            out.append(f"- 主角：{proto['name']}（{proto.get('trait', '')}）")

    chapters = st.get("chapters") or []
    reviews = st.get("reviews") or {}
    recent = chapters[-3:]
    out.append("\n## 近 3 章关注点\n")
    if not recent:
        out.append("_尚无成章_")
    outlines_by_idx = {}
    if isinstance(outline.get("chapter_outlines"), list):
        outlines_by_idx = {c.get("idx"): c for c in outline["chapter_outlines"]
                           if isinstance(c, dict)}
    for ch in recent:
        idx = ch.get("idx")
        goal = str((outlines_by_idx.get(idx) or {}).get("goal") or "").strip()
        out.append(f"\n### 第 {idx} 章 {ch.get('title', '')}"
                   f"（{ch.get('words', '?')} 字｜评审 {reviews.get(idx, {}).get('score', '—')} 分）")
        if goal:
            out.append(f"- 规划目标：{goal}")
        rv = reviews.get(idx) or {}
        problems = [p for p in (rv.get("problems") or []) if isinstance(p, dict)][:3]
        for p in problems:
            out.append(f"- 评审问题：{p.get('type', '')}——{p.get('msg', '')}")
        if rv.get("blockers"):
            out.append(f"- ⛔ 阻断项：{'、'.join(str(b) for b in rv['blockers'])}")
    if st.get("reader_feedback"):
        out.append(f"\n**读者官反馈（第 {st.get('reader_feedback_idx')} 章）**："
                   f"{st['reader_feedback']}")

    # 下章提醒：大纲中紧随其后的 1 章目标 + 超时伏笔
    last_idx = chapters[-1]["idx"] if chapters else 0
    nxt = outlines_by_idx.get(last_idx + 1)
    out.append("\n## 下一章提醒\n")
    if nxt:
        out.append(f"- 第 {nxt.get('idx')} 章《{nxt.get('title', '')}》目标：{nxt.get('goal', '')}")
    else:
        out.append("_大纲中无下一章记录_")
    for x in st.get("foreshadows") or []:
        if x.get("status") == "open" and x.get("recovered") is None:
            planted = x.get("planted")
            if isinstance(planted, int) and last_idx - planted >= STALE_AFTER:
                out.append(f"- ⚠ 超时伏笔（第{planted}章埋，已{last_idx - planted}章未收）："
                           f"{x.get('desc', '?')}")
    return "\n".join(out) + "\n"


def export_projections(path):
    """导出三份投影，返回实际写出的路径列表（失败的不计入且不抛出）。"""
    written = []
    if not os.path.exists(path):
        return written
    st = load_projection_state(path)
    for suffix, renderer in (
        (".当前状态.md", render_state_md),
        (".伏笔台账.md", render_foreshadow_md),
        (".控制面.md", render_control_md),
    ):
        try:
            target = _sidecar_path(path, suffix)
            with open(target, "w", encoding="utf-8") as f:
                f.write(renderer(st, path))
            written.append(target)
        except Exception as exc:  # 投影是锦上添花，绝不阻塞流水线
            print(f"  [WARN] 投影 {suffix} 导出失败：{exc}")
    return written


def main():
    ap = argparse.ArgumentParser(description="随书 Markdown 人类可读投影导出")
    ap.add_argument("path", help="进度文件（.jsonl）路径")
    a = ap.parse_args()
    path = os.path.abspath(a.path)
    if not os.path.exists(path):
        ap.error(f"进度文件不存在：{path}")
    written = export_projections(path)
    for w in written:
        print(f"[OK] 投影：{w}")
    if not written:
        print("[WARN] 未导出任何投影")
        sys.exit(1)


if __name__ == "__main__":
    main()

