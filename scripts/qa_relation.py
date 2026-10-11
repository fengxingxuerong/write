#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语义硬伤检测 · 关卡4（人物关系张冠李戴）。

2026-10-10 从 qa_semantic_check.py 拆出。纯本地规则，不触网、不调 LLM。

对外接口：调用方仍从 qa_semantic_check 取同名转发。拆分红线：只降维护成本，
不改对外契约；函数体逐字搬运，未改写。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from qa_text import strip_dialogue  # noqa: E402


REL_WORDS = ("父亲", "母亲", "师父", "师傅", "丈夫", "妻子", "夫人",
             "儿子", "女儿", "义父", "义母")


_REL_ALT = "|".join(REL_WORDS)


REL_P1_PAT = re.compile(
    r"([一-鿿]{2,5})的(%s)(?:乃是|是)([一-鿿]{2,5})(?![一-鿿])" % _REL_ALT)


REL_P2_PAT = re.compile(
    r"([一-鿿]{2,5})(?:乃是|是)([一-鿿]{2,5})的(%s)" % _REL_ALT)


_REL_BAD_CHARS = set("是他她它我你您的了没非谁什这那其位个诸众各")


_REL_ADVERBS = (
    "当年", "如今", "此刻", "此时", "此番", "后来", "之前", "便是",
    "竟然", "原来", "确实", "其实", "真正", "的确", "才是", "就是",
    "也是", "正是", "似乎", "仿佛", "想必", "好像", "大概", "本来",
)


def _clean_rel_name(s):
    """剥离副词前后缀并做名字资格校验；不合格返回 None。"""
    s = (s or "").strip()
    prev = None
    while s and s != prev:  # 循环剥离直到稳定（「当年林啸天就是」多段叠加）
        prev = s
        for w in _REL_ADVERBS:
            if len(s) > len(w) and s.startswith(w):
                s = s[len(w):]
            if len(s) > len(w) and s.endswith(w):
                s = s[:-len(w)]
    if len(s) < 2 or len(s) > 6:
        return None
    if _REL_BAD_CHARS & set(s):
        return None
    return s


def detect_relation_drift(chapters):
    """检测人物关系张冠李戴。入参 [(idx, title, content)]。

    返回 {"claims": 总关系断言数, "alerts": [
        {"rel", "head", "level": high|medium,
         "values": [{"value", "chapters": [...], "count", "phrase"}...],
         "phrase": 首条证据句}]}。
    - high：同一章内同一 (关系, 被修饰者) 出现两个对象（章内自相矛盾）
    - medium：跨章指向不同对象（身世揭露类反转也可能触发，需人工复核）
    """
    claims = []
    for idx, _title, content in chapters:
        narr = strip_dialogue(content)  # 对话里的假设/举例不算断言
        for m in REL_P1_PAT.finditer(narr):
            head = _clean_rel_name(m.group(1))
            value = _clean_rel_name(m.group(3))
            if not head or not value or head == value:
                continue
            claims.append({"rel": m.group(2), "head": head, "value": value,
                           "chapter": idx, "phrase": m.group(0)[:40]})
        for m in REL_P2_PAT.finditer(narr):
            value = _clean_rel_name(m.group(1))
            head = _clean_rel_name(m.group(2))
            if not head or not value or head == value:
                continue
            claims.append({"rel": m.group(3), "head": head, "value": value,
                           "chapter": idx, "phrase": m.group(0)[:40]})

    groups = {}
    for c in claims:
        groups.setdefault((c["rel"], c["head"]), []).append(c)

    alerts = []
    for (rel, head), cs in groups.items():
        by_value = {}
        for c in cs:
            by_value.setdefault(c["value"], []).append(c)
        if len(by_value) < 2:
            continue
        chs_by_ch = {}
        for c in cs:
            chs_by_ch.setdefault(c["chapter"], set()).add(c["value"])
        same_ch = any(len(v) >= 2 for v in chs_by_ch.values())
        values = []
        for v, vcs in by_value.items():
            values.append({"value": v,
                           "chapters": sorted({c["chapter"] for c in vcs}),
                           "count": len(vcs),
                           "phrase": vcs[0]["phrase"]})
        values.sort(key=lambda x: -x["count"])
        alerts.append({"rel": rel, "head": head,
                       "level": "high" if same_ch else "medium",
                       "values": values, "phrase": cs[0]["phrase"]})
    alerts.sort(key=lambda a: (a["level"] != "high", a["head"]))
    return {"claims": len(claims), "alerts": alerts}
