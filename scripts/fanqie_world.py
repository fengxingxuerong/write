#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""番茄评审 · 世界观专名一致性层：抽专名、按专名判题材是否落到正文。

2026-10-10 从 fanqie_review.py 拆出（同批还有 fanqie_text / fanqie_metrics）。
纯本地计算，不触网。

对外接口：调用方仍从 fanqie_review 取同名转发。拆分红线：只降维护成本，
不改对外契约，函数体逐字搬运。
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fanqie_text import count_words  # noqa: E402,F401

_SEP_CHARS = set(
    "，。、；：！？（）()《》〈〉“”‘’「」『』【】[]{}\\/\"':;,·—-与和及／｜ \t\r\n"
)


_TERM_OK = re.compile(r"^[\u4e00-\u9fffA-Za-z0-9·]{2,12}$")


_GENERIC_WORLD = {
    "主舞台", "城市", "势力", "等级", "体系", "境界", "科技", "能源", "联赛", "舞台",
    "俱乐部", "国家队", "朝代名", "大陆名", "星域名", "游戏世界", "职业", "出身",
    "性格特征", "竞技场", "背景", "主要", "门派", "世家", "组织", "机构", "主要势力",
    "自拟", "三大势力", "自拟专名", "能源为",
}


def extract_world_terms(outline):
    """从大纲的 world 字段抽专名候选（供一致性检查用）。与 Dart worldTermsFrom 同口径。

    1) 先收引号/书名号里的片段——规划官写的专名通常带引号（『星髓』、《深渊回廊》）；
    2) 再按分隔符切片，只留 **3 字以上**的片段。
    收 2 字词会把「秩序」「资本」当专名，跟跑题文本随手撞上，一致性检查就失效
    （定标实测：阈值降到 2 字后，旧版跑题样本从 55 分涨回 63 分）。"""
    blob = json.dumps(outline.get("world") or {}, ensure_ascii=False) \
        if isinstance(outline, dict) else str(outline or "")
    out = []

    def push(t):
        t = t.strip().rstrip("的地了")
        # 必须含汉字：否则 JSON 的键名（galaxy/faction）会混进专名池
        if not re.search(r"[\u4e00-\u9fff]", t):
            return
        if 2 <= len(t) <= 12 and t not in _GENERIC_WORLD \
                and _TERM_OK.match(t) and t not in out:
            out.append(t)

    for m in re.finditer("[「『《“‘]([^\\n」』”’]{2,10})[」』”’]", blob):
        push(m.group(1))
    frag, cur = [], []
    for ch in blob:
        if ch in _SEP_CHARS:
            frag.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    frag.append("".join(cur))
    for raw in frag:
        if len(raw.strip()) >= 3:
            push(raw)
    return out[:14]


def _term_hit(text, term):
    """专名命中：允许局部命中。

    专名池是从大纲 world 字段切的完整短语（「星洲奥体中心」），正文可能写「星洲青训基地」；
    「体能师老韩」正文写「老韩」。整串包含会把接住了设定的正文误判为跑题，
    所以退一步：term 的 3 字滑窗或尾 2 字任一命中即算命中。"""
    if not term or not text:
        return False
    if term in text:
        return True
    for i in range(0, max(len(term) - 2, 0)):
        if term[i:i + 3] in text:
            return True
    return len(term) >= 2 and term[-2:] in text


def world_consistency(text, terms):
    """世界观一致性：大纲里的专名在正文命中几个。一个都没有 = 写手跑题。

    同时给出 missing（未命中的专名清单）：定点修与写手提示词要靠它点名。
    只告诉模型「专名一个都没出现」而不给清单，模型根本无从下手——这是
    门禁 v7 第 13 项「世界观未落地」定点修一轮后仍残留的直接原因。
    """
    if not terms:
        return None
    hit = [t for t in terms if _term_hit(text or "", t)]
    missing = [t for t in terms if not _term_hit(text or "", t)]
    return {"hit": len(hit), "total": len(terms), "terms": hit[:5],
            "missing": missing[:8], "missing_total": len(missing)}
