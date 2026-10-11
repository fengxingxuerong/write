#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""番茄评审 · 完读率 / 同质化 / 结构指标层：首屏、节奏、水段、套句、漂移、重复。

2026-10-10 从 fanqie_review.py 拆出（同批还有 fanqie_text / fanqie_world）。
只放**纯本地规则指标**（不含红线合规、不调 LLM）；词表/阈值取自
quality_rules_generated（rules/quality_rules.json 的生成物），本文件不写死词表。

对外接口：调用方仍从 fanqie_review 取同名转发。拆分红线：只降维护成本，
不改对外契约，函数体逐字搬运。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fanqie_text import count_words, dialogue_ratio, paragraphs, sentences  # noqa: E402,F401
from quality_rules_generated import (  # noqa: E402,F401
    ANCIENT_GENRES, CONFLICT_WORDS, INTRA_REPEAT_GRAM, INTRA_REPEAT_MIN_BLOCK,
    META_TALK, MODERN_MARKERS, PROMPT_LEAK, REVIEW_CLICHE_SENTENCES,
    TRIAD_END_WINDOW, TRIAD_END_WORDS,
)


CLICHE_SENTENCES = REVIEW_CLICHE_SENTENCES


TRIAD_END_WORDS = list(TRIAD_END_WORDS)  # 本地可变副本（值来自生成物）


def ending_triad(text):
    """章末三件套收尾检测：收束区域（末 60 字）命中规则 20 词表则返回该词。

    返回命中的词（如「发烫」），未命中返回空串。只管收尾位置——正文中段
    出现发烫/苏醒是正常身体异动描写（POWER_SURGE 通道），不算本违规。
    """
    if not text:
        return ""
    seg = text[-TRIAD_END_WINDOW:]
    for w in TRIAD_END_WORDS:
        start = 0
        while True:
            i = seg.find(w, start)
            if i < 0:
                break
            # 「天亮了」是时间推进，不是发光物件收束（逐个出现位置排除，
            # 同窗内「天亮了」在前、「玉符亮了」在后时仍能命中后者）
            if w.startswith("亮") and i > 0 and seg[i - 1] == "天":
                start = i + len(w)
                continue
            return w
    return ""


def ending_ev_fragment(text):
    """评审证据串：章末收尾（注入 qa_ev，与 Dart endingEvFragment 同文）。"""
    w = ending_triad(text)
    if w:
        return f"章末收尾：三件套命中「{w}」⚠（规则20禁止身体异动/发光物件收束，需换成未落地悬念）"
    return "章末收尾：未见三件套 ✅"


DRIVE_WORDS = [
    "说", "道", "问", "答", "喊", "笑", "看", "抓", "推", "砸", "拔", "转身",
    "走", "跑", "冲", "拿", "递", "写", "敲", "点", "掀", "摸", "掏", "塞",
    "死", "伤", "血", "钱", "字", "信", "刀", "枪", "门", "窗", "牌", "图",
    "答应", "拒绝", "决定", "必须", "马上", "今晚", "三天", "一个亿", "名字",
]


NAME_PAT = re.compile(
    r"([\u4e00-\u9fff]{2,3})(?:[，,、]?"
    r"(?:说|道|问|答|笑|喊|盯|看|抬头|转身|点头|摇头|皱眉|收|站|蹲|伸手|开口|吐))")


CONFLICT_WORDS = list(CONFLICT_WORDS)


PROMPT_LEAK = PROMPT_LEAK = list(PROMPT_LEAK)  # 值来自 rules/quality_rules.json 的生成物（勿在本文件再写词表）


META_TALK = META_TALK = list(META_TALK)  # 值来自 rules/quality_rules.json 的生成物（勿在本文件再写词表）


MODERN_MARKERS = MODERN_MARKERS = list(MODERN_MARKERS)  # 值来自 rules/quality_rules.json 的生成物（勿在本文件再写词表）


ANCIENT_GENRES = ANCIENT_GENRES = tuple(ANCIENT_GENRES)  # 值来自 rules/quality_rules.json 的生成物（勿在本文件再写词表）


INTRA_REPEAT_MIN_BLOCK = INTRA_REPEAT_MIN_BLOCK  # 值来自 rules/quality_rules.json 生成物


INTRA_REPEAT_GRAM = INTRA_REPEAT_GRAM  # 值来自 rules/quality_rules.json 生成物


BLOCKING_MIN_WORDS = 1500


SURNAMES = set(
    "王李张刘陈杨黄赵周吴徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘于蒋蔡"
    "余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯"
    "龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤柴桑关岳鲍盛赖樊温柯岑路桂傅齐应宗简")


def looks_like_name(s):
    """粗略判断：首字是姓才算人名。"""
    return bool(s) and s[0] in SURNAMES


def first_screen_check(text):
    """首屏 300 字：编辑与算法的第一道门槛。"""
    head = (text or "")[:320]
    probs, good = [], []
    if count_words(head) < 120:
        probs.append(("首屏不足 120 字，多半是空行或标题占位", "重写"))
    if re.match(r"^\s*[^\n]{0,16}[雨雪霜雾风]", head):
        probs.append(("首屏以天气起手（模板化，且未进入事件）", "修改"))
    if not re.search(r"[“\"「]", head):
        probs.append(("首屏无对白：纯描述开场完读率风险高", "重写"))
    has_actor = bool(NAME_PAT.search(head)) or bool(re.search(r"[“「]", head))
    if not has_actor:
        probs.append(("首屏看不到「谁在做什么」——缺具体主语+动作", "修改"))
    if not any(w in head for w in CONFLICT_WORDS):
        probs.append(("首屏无冲突信号（无威胁/无要求/无损失）", "修改"))
    long_ones = [s for s in sentences(head) if len(s) > 32]
    if len(long_ones) >= 3:
        probs.append((f"首屏有 {len(long_ones)} 句超 32 字（移动端一行放不下）", "修改"))
    if not probs:
        good.append("首屏具备：在场人物 + 正在发生 + 可对白的冲突")
    return probs, good


def pacing_stats(text):
    """完读率三兄弟：句长、段长、对话占比。"""
    sents = sentences(text)
    paras = paragraphs(text)
    slen = [len(s) for s in sents]
    plen = [count_words(p) for p in paras]
    return {
        "sent_avg": round(sum(slen) / len(slen), 1) if slen else 0.0,
        "sent_over30": round(sum(1 for x in slen if x > 30) / max(len(slen), 1) * 100, 1),
        "para_over5": round(sum(1 for x in plen if x > 160) / max(len(plen), 1) * 100, 1),
        "dialogue": dialogue_ratio(text),
        "paras": len(paras),
    }


def filler_ratio(text):
    """水段率：长度 ≥ 40 字、既无对白又无推进词的段落占比（可替换性代理）。

    短段一律不判水：「他顿了顿。」「弯腰，捾鞋，拍灰，穿上。」这类喘气段是写作准则
    明要求的节奏手段，拿段落长短去砍它会把好文风压成流水账。"""
    paras = paragraphs(text)
    if not paras:
        return 0.0, 0
    bad = counted = 0
    for p in paras:
        if count_words(p) < 40:
            continue
        counted += 1
        if "“" in p or "\"" in p or "「" in p:
            continue
        if any(w in p for w in DRIVE_WORDS):
            continue
        bad += 1
    ratio = round(bad / max(counted, 1) * 100, 1)
    return ratio, counted


def cliche_overlap(text, corpus_hint=""):
    """同质化：套句命中数 / 千字。"""
    n = max(count_words(text), 1)
    hit = [s for s in CLICHE_SENTENCES if s in text]
    return {"per_k": round(len(hit) / n * 1000, 2), "hits": hit}


def repeat_with_prev(text, prev_text):
    """与上一章的 8-gram 重合率（自我重复/灌水代理）。"""
    if not prev_text:
        return 0.0
    def grams(t):
        t = re.sub(r"\s+", "", t or "")
        return {t[i:i + 8] for i in range(0, max(len(t) - 7, 0), 3)}
    a, b = grams(text), grams(prev_text)
    if not a:
        return 0.0
    return round(len(a & b) / len(a) * 100, 2)


def agency_check(text):
    """主角主动性：每千字主动句 vs 被动句（代理指标，只作「修改」级提醒）。"""
    active = sum(text.count(w) for w in
                 ["我决定", "我选", "我接", "我应", "我来", "我先", "当场", "主动", "开口",
                  "提出", "要求", "接下", "应下", "带着人", "连夜", "先把",
                  "他决定", "他选", "她要", "他要", "我偏", "我会", "我自己", "不靠",
                  "就算", "也要", "给我", "等着", "记住", "他反问", "他拒绝", "他点头",
                  "他开口", "他伸手", "他站起身", "他抢", "他夺", "他扫", "他赌", "他押",
                  "他扯", "他拆开", "他抬手", "他推开", "他回", "他接"])
    passive = sum(text.count(w) for w in
                  ["不得不", "只能", "只好", "由不得", "被人", "无从", "无处可",
                   "听天由命", "没办法", "被拖", "被推", "被换", "被安排"])
    n = max(count_words(text), 1) / 1000.0
    return {"active": active, "passive": passive,
            "active_per_k": round(active / n, 2), "passive_per_k": round(passive / n, 2),
            "ratio": round(active / max(passive, 1), 2)}


def self_repeat_ratio(text):
    """整句重复率（模板引擎与注水最直接的特征）。"""
    ss = [s for s in sentences(text) if len(s) >= 10]
    if not ss:
        return 0.0
    seen, dup = set(), 0
    for s in ss:
        if s in seen:
            dup += 1
        seen.add(s)
    return round(dup / len(ss) * 100, 2)


def name_drift(text, protagonist=""):
    """主角漂移：同章多个高频人名，或大纲主角名缺席。"""
    cnt = {}
    for m in NAME_PAT.finditer(text or ""):
        nm = m.group(1)
        if nm != protagonist and not looks_like_name(nm):
            continue
        cnt[nm] = cnt.get(nm, 0) + 1
    # 主角高频出现是正常叙事，不计入漂移判定（与 Dart 端 FanqieGateChecker 同口径）
    hot = sorted(((w, c) for w, c in cnt.items() if c >= 3 and w != protagonist),
                 key=lambda x: -x[1])
    probs = []
    # 「对手 + 盟友」两个常驻配角同章活跃是正常戏剧结构（与 Dart 端
    # FanqieGateChecker 同口径）；真正的视角漂移信号是 3 个以上高频配角。
    if len(hot) > 2:
        probs.append("同章出现多个高频人名：" + "、".join("%s×%d" % (w, c) for w, c in hot[:4])
                     + "（视角/主角漂移）")
    if protagonist and (text or "").count(protagonist) < 3:
        probs.append("大纲主角「%s」本章仅出现 %d 次（写手没接住主角）"
                     % (protagonist, (text or "").count(protagonist)))
    return probs


def blocking_reasons(row):
    """阻断级硬伤（不修完不给「可投」）。

    与「扣分项」分开的原因：分数只回答「写得好不好」，阻断项回答「能不能投」。
    实测事故：第 1 章 92 分（仅字数不足）时 fix_prompt 直接返回空串 → 那一章再也没被修，
    泄漏/跑题就留在了成书里。阻断项必须能独立触发定点修。
    """
    out = []
    for p in row.get("problems") or []:
        t, msg = p.get("type", ""), p.get("msg", "")
        if t == "泄漏":
            out.append("提示词/元话语残留")
        elif t == "重复" and "章内大段重复" in msg:
            out.append("章内大段重复")
        elif t == "一致性" and "题材漂移" in msg:
            out.append("题材漂移")
        elif t == "一致性" and "没接住主角" in msg:
            out.append("主角缺席")
        elif t == "一致性" and "世界观专名" in msg:
            out.append("世界观未落地")
        elif t == "钩子":
            out.append("无章末钩子")
    if row.get("words", 0) < BLOCKING_MIN_WORDS:
        out.append(f"单章仅 {row.get('words', 0)} 字")
    return out


def prompt_leak(text):
    """骨架/规划官提示词漏进正文。"""
    return [p for p in PROMPT_LEAK if p in (text or "")]


def meta_talk(text):
    """模型元话语/操作说明残留（补写、定点修把「我在干什么」写进正文）。"""
    return [p for p in META_TALK if p in (text or "")]


def genre_drift(text, genre=""):
    """题材漂移：非现代题材正文里出现现代生活标志词。

    level："" 不报 / 「修改」个别穿帮 / 「重写」整章跑题（≥3 个不同标志词）。
    都市/校园/悬疑等现代题材不做判定（它们本来就该有这些词）。
    """
    g = (genre or "").strip()
    if not g or not any(a in g for a in ANCIENT_GENRES):
        return {"level": "", "hits": [], "count": 0, "total": len(MODERN_MARKERS)}
    hits = [w for w in MODERN_MARKERS if w in (text or "")]
    n = sum((text or "").count(w) for w in hits)
    if len(hits) >= 3:
        return {"level": "重写", "hits": hits, "count": n, "total": len(MODERN_MARKERS)}
    if hits:
        return {"level": "修改", "hits": hits, "count": n, "total": len(MODERN_MARKERS)}
    return {"level": "", "hits": [], "count": 0, "total": len(MODERN_MARKERS)}


def _dup_spans(t, gram=INTRA_REPEAT_GRAM, step=3, min_block=INTRA_REPEAT_MIN_BLOCK):
    """滑动指纹找长重复块：返回 [(起点, 终点)]（第二次出现的区间）。O(n)。"""
    seen, spans = {}, []
    for i in range(0, max(len(t) - gram + 1, 0), step):
        g = t[i:i + gram]
        first = seen.get(g)
        if first is None:
            seen[g] = i
            continue
        k = 0
        while first + k < len(t) and i + k < len(t) and t[first + k] == t[i + k]:
            k += 1
        if k >= min_block:
            spans.append((i, i + k))
    merged = []
    for a, b in sorted(spans):
        if merged and a <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    return merged


def _long_paras(text, min_words=INTRA_REPEAT_MIN_BLOCK):
    """长段落及其在原文/扁平文本中的位置（段落级近似重复用）。"""
    out = []
    for p in paragraphs(text):
        if count_words(p) >= min_words:
            out.append(p)
    return out


def _para_dup(text, min_words=INTRA_REPEAT_MIN_BLOCK):
    """段落级近似重复（标点/个别用词微调也算）：相似度 ≥0.9 判重。"""
    import difflib
    long_paras = _long_paras(text, min_words)
    hits = []
    for i in range(1, len(long_paras)):
        for j in range(i):
            a = re.sub(r"\s+", "", long_paras[j])
            b = re.sub(r"\s+", "", long_paras[i])
            if not a or not b:
                continue
            ratio = difflib.SequenceMatcher(None, a, b).ratio()
            if ratio >= 0.9:
                hits.append((long_paras[i], ratio))
                break
    return hits


def intra_repeat(text):
    """章内大段重复：同章 ≥120 字的整块文字出现两次（复制粘贴事故）。

    两条通道：① 扁平文本滑动指纹（完全相同的长块）；
    ② 段落级近似比对（标点/个别用词微调，实测事故正是这种形态）。
    返回 {"blocks", "words", "sample"}。
    """
    t = re.sub(r"\s+", "", text or "")
    spans = _dup_spans(t) if len(t) >= INTRA_REPEAT_MIN_BLOCK * 2 else []
    words = sum(b - a for a, b in spans)
    sample = t[spans[0][0]:spans[0][0] + 24] if spans else ""
    fuzzy = _para_dup(text) if not spans else []
    if fuzzy and not spans:
        words = count_words(fuzzy[0][0])
        sample = fuzzy[0][0][:24]
    return {"blocks": len(spans) + (1 if (fuzzy and not spans) else 0),
            "words": words, "sample": sample}


def dedup_intra_repeat(text, min_para_words=40):
    """章内重复段去重（保留首次出现，删掉后面复制的段）。返回 (新文本, 删除字数)。

    只对「与前面完全相同的段（≥40 字）」动手：短句复诵（"他点头。"）与刻意排比不受影响。
    """
    if not text:
        return text, 0
    seen, out, removed = set(), [], 0
    for ln in text.split("\n"):
        norm = re.sub(r"\s+", "", ln)
        if len(norm) >= min_para_words:
            if norm in seen:
                removed += len(norm)
                continue
            seen.add(norm)
        out.append(ln)
    if not removed:
        return text, 0
    return re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip(), removed
