#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""规则-检测覆盖矩阵候选缺口 证据探针（真实成书回测）。

对三个「有指令无检测」候选量化信号强度，数据决定选题：
1. 说话标签频率（FANQIE 规则 4「『他说道/她道』式标签每三次对白最多一次」）
   —— 对白轮次 vs 说话标签数，规则线 ratio<=1/3。
2. 总结式抒情收尾（规则 22「禁止总结式抒情收尾，停在事件上」）
   —— 末句命中抒情总结词模式；现有 cliche_overlap 是全章密度，无收尾特判。
3. 钩子承接（上一章末钩是否被下一章开篇接住）
   —— 相邻章 hook 窗 vs 开篇窗的 bigram 重合率，对比「随机章开篇」基线；
   相邻显著高于基线才有检测价值。

用法：python tool/probe_rule_gaps.py
"""
import io
import json
import random
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

ROOT = Path(__file__).resolve().parent.parent / "data" / "generated"

# 抒情总结收尾模式（规则 22 例句 + novel_quality_checker 空泛总结词扩展）
LYRICAL_END = [
    "从这一刻起", "一切都变了", "都不一样了", "一切都将改变", "命运的车轮",
    "人生的轨迹", "才刚刚开始", "刚刚开始", "新的征程", "未来的路",
    "明白了一个道理", "属于他的时代", "这只是个开始", "远远没有结束",
]


def load_chapters(path):
    chapters = []
    with io.open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("type") != "chapter":
                continue
            data = rec.get("data", rec)
            content = data.get("content") or ""
            if content:
                chapters.append((data.get("idx"), content))
    chapters.sort(key=lambda x: (x[0] is None, x[0]))
    return chapters


def final_sentence(text):
    t = text.rstrip()
    parts = [p for p in re.split(r"[。！？…]", t) if p.strip()]
    return parts[-1] if parts else t[-60:]


def bigrams(s):
    s = re.sub(r"\s+", "", s or "")
    return {s[i:i + 2] for i in range(max(0, len(s) - 1))}


def main():
    # ---- 1) 说话标签（引号口径与 dialogue_ratio 对齐：「“『 与 ”」』 双风格） ----
    open_q = set('“"『「')
    tag_pat_a = re.compile(
        r'[”」』"][一-龥]{1,4}(?:说道|道|说|问|答|喊|吼|叹|笑|喝)[。！，,：:]')
    tag_pat_b = re.compile(
        r'[一-龥]{1,4}(?:说道|问道|答道|沉声道|冷冷道|低声道|怒道|道)[：:]\s*[“「『]')
    tag_rows = []       # (book, idx, turns, tags, ratio)
    # ---- 2) 抒情收尾 ----
    lyr_hits = []
    ch_total = 0
    # ---- 3) 钩子承接：见 main() 末段逐书自校准（需书内全章） ----
    # ---- 4) 情绪直陈（规则15：情绪一律外化，不写「他很愤怒」「心里一沉」） ----
    # 只数叙述层（剔除对白——角色喊「我好愤怒」是台词不是作者直陈）。
    tell_pats = [
        re.compile(r"(?:感到|觉得|感觉到)[^。！？\n]{0,10}"
                   r"(?:愤怒|生气|悲伤|难过|恐惧|害怕|焦虑|绝望|沮丧|"
                   r"失落|委屈|尴尬|羞愧)"),
        re.compile(r"(?:心中|心里|内心)(?:一阵|一股|满是|充满)"
                   r"[^。！？\n]{0,6}"
                   r"(?:愤怒|悲伤|恐惧|委屈|绝望|难过|焦虑|沮丧|失落)"),
        re.compile(r"(?:很|非常|十分|无比|格外)"
                   r"(?:愤怒|悲伤|恐惧|难过|委屈|绝望|焦虑|沮丧|尴尬)"),
    ]
    tell_hits = []
    # ---- 5) 非视觉五感（规则17：每场景至少两种非视觉感官） ----
    SENSES = {
        "听": ["声音", "响起", "传来", "轰鸣", "嗡嗡", "滴答", "哗啦",
               "咔嚓", "咆哮", "嘶吼", "钟声", "脚步声", "叮当", "沙沙",
               "闷响", "爆响", "哀嚎", "尖叫", "呜咽", "嘶哑"],
        "嗅": ["气味", "香味", "臭味", "腥味", "腐臭", "霉味", "焦味",
               "香气", "芬芳", "刺鼻", "血腥味", "药香", "酒香", "土腥"],
        "触": ["冰冷", "滚烫", "粗糙", "滑腻", "刺痛", "麻木", "湿润",
               "干燥", "灼烧", "寒意", "刺骨", "黏腻", "割裂", "坚硬",
               "温热", "发烫", "发麻"],
        "味": ["苦味", "甜味", "咸味", "酸味", "腥甜", "发苦", "咸腥"],
    }
    sense_counts = []   # 每章命中的非视觉感官类别数
    # ---- 6) goal 四元组完整性（GOAL_FORMAT：缺一项视为不合格） ----
    goal_rows = []      # (book, total, all4, partial, none)

    for path in sorted(ROOT.glob("*.jsonl")):
        chapters = load_chapters(path)
        if len(chapters) < 3:
            continue
        for idx, content in chapters:
            ch_total += 1
            # 1) 标签
            turns = sum(content.count(q) for q in open_q)
            tags = len(tag_pat_a.findall(content)) + \
                len(tag_pat_b.findall(content))
            if turns >= 4:
                tag_rows.append(
                    (path.name, idx, turns, tags, tags / max(turns, 1)))
            # 2) 抒情收尾
            fs = final_sentence(content)
            hit = [w for w in LYRICAL_END if w in fs]
            if hit:
                lyr_hits.append((path.name, idx, hit))
            # 4) 情绪直陈（叙述层）
            narr = re.sub(r"[“「『\"][^”」』\"]*[”」』\"]", "", content)
            n_tell = sum(len(p.findall(narr)) for p in tell_pats)
            if n_tell > 0:
                tell_hits.append((path.name, idx, n_tell))
            # 5) 非视觉五感类别数
            cats = sum(1 for ws in SENSES.values()
                       if any(w in content for w in ws))
            sense_counts.append(cats)
        # 6) goal 四元组完整性（outline 记录）
        goals = []
        with io.open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("type") != "outline":
                    continue
                for co in (rec.get("data") or {}).get(
                        "chapter_outlines") or []:
                    goals.append(str(co.get("goal") or ""))
        if goals:
            keys = ("新信息=", "变化=", "主角选择=", "钩子=")
            all4 = sum(1 for g in goals if all(k in g for k in keys))
            none = sum(1 for g in goals
                       if not any(k in g for k in keys))
            goal_rows.append(
                (path.name, len(goals), all4,
                 len(goals) - all4 - none, none))

    print("=== 1) 说话标签频率（规则4：tags/turns <= 1/3） ===")
    print(f"适用章（对白轮>=4）: {len(tag_rows)}")
    if tag_rows:
        rs = sorted(r[4] for r in tag_rows)
        med = rs[len(rs) // 2]
        over = [r for r in tag_rows if r[4] > 1 / 3]
        print(f"中位 ratio={med:.2f}  最大 ratio={rs[-1]:.2f}  "
              f"超规则线(>0.33)章数: {len(over)} "
              f"({len(over) / len(tag_rows) * 100:.0f}%)")
        for name, idx, turns, tags, ratio in sorted(
                over, key=lambda x: -x[4])[:6]:
            print(f"  超线: {name} ch{idx}: tags={tags}/turns={turns} "
                  f"ratio={ratio:.2f}")

    print("\n=== 2) 总结式抒情收尾（末句命中） ===")
    print(f"章总数: {ch_total}  命中: {len(lyr_hits)} "
          f"({len(lyr_hits) / max(1, ch_total) * 100:.1f}%)")
    for name, idx, hit in lyr_hits[:10]:
        print(f"  {name} ch{idx}: {'/'.join(hit)}")

    print("\n=== 3) 钩子承接（bigram 重合率：相邻 vs 同书随机基线） ===")
    # 逐书计算（书内自校准基线），并抽样人工复核被标章对的尾/头原文
    for path in sorted(ROOT.glob("*.jsonl")):
        chapters = load_chapters(path)
        if len(chapters) < 3:
            continue
        rnd2 = random.Random(7)
        rows = []
        for i in range(len(chapters) - 1):
            hook = chapters[i][1][-200:]
            payoff = chapters[i + 1][1][:500]
            hb = bigrams(hook)
            if not hb:
                continue
            adj = len(hb & bigrams(payoff)) / len(hb)
            cands = [j for j in range(len(chapters))
                     if j not in (i, i + 1)]
            if not cands:
                continue
            picks = rnd2.sample(cands, min(5, len(cands)))
            base = sum(len(hb & bigrams(chapters[j][1][:500])) / len(hb)
                       for j in picks) / len(picks)
            rows.append((i, adj, base, hook, payoff))
        if not rows:
            continue
        adj_m = sum(r[1] for r in rows) / len(rows)
        base_m = sum(r[2] for r in rows) / len(rows)
        flagged = [r for r in rows if r[1] < r[2]]
        print(f"\n  {path.name}: 相邻均值={adj_m:.3f} 基线={base_m:.3f} "
              f"提升={adj_m - base_m:+.3f}  标记 {len(flagged)}/{len(rows)}")
        for i, adj, base, hook, payoff in flagged[:2]:
            print(f"    >> ch{i + 1}→ch{i + 2} adj={adj:.3f}<base={base:.3f}")
            print(f"      钩尾: …{hook[-60:].strip()}")
            print(f"      开头: {payoff[:60].strip()}…")

    print("\n=== 4) 情绪直陈（规则15，叙述层命中章） ===")
    print(f"命中章: {len(tell_hits)}/{ch_total} "
          f"({len(tell_hits) / max(1, ch_total) * 100:.1f}%)  "
          f"命中次总数: {sum(t[2] for t in tell_hits)}")
    for name, idx, n in sorted(tell_hits, key=lambda x: -x[2])[:8]:
        print(f"  {name} ch{idx}: {n} 处")

    print("\n=== 5) 非视觉五感类别数（规则17：>=2 类达标） ===")
    if sense_counts:
        dist = {}
        for c in sense_counts:
            dist[c] = dist.get(c, 0) + 1
        ok2 = sum(1 for c in sense_counts if c >= 2)
        print(f"分布: {dist}  达标(>=2类): {ok2}/{len(sense_counts)} "
              f"({ok2 / len(sense_counts) * 100:.0f}%)")

    print("\n=== 6) goal 四元组完整性（GOAL_FORMAT 四键） ===")
    tot = sum(r[1] for r in goal_rows)
    a4 = sum(r[2] for r in goal_rows)
    pa = sum(r[3] for r in goal_rows)
    nn = sum(r[4] for r in goal_rows)
    print(f"章纲总数: {tot}  四键齐: {a4}  部分缺: {pa}  全缺: {nn}")
    for name, n, a, p, z in goal_rows:
        if a < n:
            print(f"  {name}: {a}/{n} 齐 | 部分缺 {p} | 全缺 {z}")


if __name__ == "__main__":
    main()
