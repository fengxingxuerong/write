#!/usr/bin/env python3
"""墨匠成书质检扫描器 —— 用新版商业向质检规则扫描已有成书文本。

用法:
  python qa_scan_existing.py <小说.txt路径> [--json]

对新版规则做「基线验证」：
  - 章末钩子检测（🪝 / ✗无钩）：结尾 200 字是否有悬念信号（含隐喻式钩子词表）
  - 黄金三章开场检测（⚡ / ✗开场慢）：前 3 章开场 300 字是否快速进入事件
  - AI 囷痕密度（%）

不调用任何 LLM，零成本；复用 generate_novel.py 的质检函数（与 Dart 侧对齐）。
"""
import argparse
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from generate_novel import (has_ending_hook, has_quick_opening, count_words,
                            thrill_per_thousand, surge_per_thousand, AI_CLICHE,
                            OPENING_ACTION_WORDS, deep_ai_metrics)


CHAPTER_RE = re.compile(r"^第\s*(\d+)\s*章")

# ============================================================
# 黄金三章专项体检词表（签约命门：前三章决定追读率）
# ============================================================

# 身份落差信号：废柴/受辱/卑微处境（让读者代入"我要翻身"）
GOLDEN_IDENTITY = ['废物', '废材', '杂种', '受辱', '羞辱', '耳光', '嗤笑',
                   '讥', '滚出', '不配', '丹田碎', '灵根尽毁', '废人',
                   '踩在脚下', '颜面扫地', '跪', '白眼', '欺辱', '贬']

# 金手指/机缘信号：异动/传承/外挂（让读者期待"我要崛起"）
GOLDEN_POWER = ['发烫', '温热', '苏醒', '玉简', '传承', '系统', '金色',
                '裂缝', '纹路', '异动', '功法', '残卷', '觉醒', '种子',
                '周天', '灵脉', '残印', '吞天', '拱', '渗']

# 目标确立信号：复仇/变强/离开（让读者知道"主角要干什么"）
GOLDEN_GOAL = ['必须', '一定要', '要变强', '报仇', '离开', '活下去',
               '等着', '迟早', '总有一', '誓', '要拿回', '要夺回',
               '出人头地', '登顶', '站起', '雪耻', '翻身']


def _golden_check(content, words):
    """返回命中词（未命中返回空串）。"""
    return next((w for w in words if w in content), "")


def _golden_three_stats(chapters, rows):
    """黄金三章达标统计，返回 (pass_count, total_items, per_chapter_dicts)。"""
    g3 = [r for r in rows if r["idx"] <= 3]
    if not g3:
        return 0, 0, []
    content_by_idx = {idx: c for idx, _, c in chapters}
    dims = [
        ("开场变故", lambda c: has_quick_opening(c),),
        ("身份落差", lambda c: _golden_check(c, GOLDEN_IDENTITY)),
        ("金手指", lambda c: _golden_check(c, GOLDEN_POWER)),
        ("目标确立", lambda c: _golden_check(c, GOLDEN_GOAL)),
    ]
    per = []
    total_pass = 0
    for r in g3:
        content = content_by_idx.get(r["idx"], "")
        checks = [bool(fn(content)) if content else False for _, fn in dims]
        hook_ok = bool(r["hook"])
        pass_count = sum(checks) + (1 if hook_ok else 0)
        total_pass += pass_count
        per.append({"idx": r["idx"], "checks": checks, "hook": hook_ok,
                    "pass": pass_count})
    return total_pass, len(g3) * 5, per


def print_golden_three(chapters, rows):
    """黄金三章专项体检：前 3 章 × 5 维度（变故/落差/金手指/目标/钩子）。"""
    g3 = [r for r in rows if r["idx"] <= 3]
    if not g3:
        return
    content_by_idx = {idx: c for idx, _, c in chapters}
    dims = [
        ("开场变故", lambda c: has_quick_opening(c), "前300字出变故/冲突"),
        ("身份落差", lambda c: _golden_check(c, GOLDEN_IDENTITY), "废柴/受辱/卑微"),
        ("金手指", lambda c: _golden_check(c, GOLDEN_POWER), "异动/传承/外挂"),
        ("目标确立", lambda c: _golden_check(c, GOLDEN_GOAL), "复仇/变强/离开"),
    ]
    print("\n【黄金三章专项体检】（签约命门：前 3 章 × 5 项）")
    print(f"  {'章':>3} {'开场变故':>8} {'身份落差':>8} {'金手指':>8} {'目标确立':>8} {'章末钩子':>8}")
    print("  " + "-" * 58)
    total_pass, total_items, _ = _golden_three_stats(chapters, rows)
    for r in g3:
        content = content_by_idx.get(r["idx"], "")
        cells = []
        for label, fn, _ in dims:
            hit = fn(content) if content else ""
            if isinstance(hit, bool):
                cells.append(f"{'✅' if hit else '✗':>8}")
            else:
                cells.append(f"{hit or '✗':>8}")
        hook_cell = "🪝" if r["hook"] else "✗"
        print(f"  {r['idx']:>3} {cells[0]} {cells[1]} {cells[2]} {cells[3]} {hook_cell:>8}")
        for label, fn, desc in dims:
            if content and not fn(content):
                print(f"      ↳ 缺「{label}」（{desc}）")
        if not r["hook"]:
            print("      ↳ 缺「章末钩子」（结尾 200 字未见悬念信号）")
    rate = total_pass / total_items * 100
    verdict = "达标 ✅" if rate >= 80 else ("临界 ⚠" if rate >= 60 else "不达标 ❌")
    print("  " + "-" * 58)
    print(f"  体检结果：{total_pass}/{total_items} 项达标（{rate:.0f}%）→ {verdict}")
    if rate < 80:
        print("  💡 建议：缺项对应补强——开篇变故/身份落差/金手指/目标/钩子，")
        print("     前三章每章必须至少满足 4/5 项，才具备番茄签约的开篇追读力。")
    print()


def print_signability_report(rows, chapters):
    """签约可行性报告：五大维度合成总分 + 对标番茄签约要素清单。"""
    if not rows:
        return
    n = len(rows)
    # ---- 各维度得分 ----
    hook_rate = sum(1 for r in rows if r["hook"]) / n
    score_hook = round(hook_rate * 30, 1)

    g3_pass, g3_total, _ = _golden_three_stats(chapters, rows)
    g3_rate = g3_pass / g3_total if g3_total else 0
    score_g3 = round(g3_rate * 30, 1)

    avg_thrill = sum(r["thrill_per_k"] for r in rows) / n
    avg_surge = sum(r["surge_per_k"] for r in rows) / n
    score_thrill = round(min(20.0, avg_thrill * 8 + avg_surge * 4), 1)

    avg_echo = sum(r["ai_echo_pct"] for r in rows) / n
    deep_levels = [deep_ai_metrics(c)["level"] for _, _, c in chapters]
    avg_deep = sum(deep_levels) / len(deep_levels) if deep_levels else 0
    score_ai = round(max(0.0, 10.0 - avg_echo * 4 - avg_deep * 1.5), 1)

    # 节奏：无塌陷区满分，每个塌陷区 -3
    zones = 0
    start = None
    for i, r in enumerate(rows):
        if r["thrill_per_k"] < 0.5:
            if start is None:
                start = i
        else:
            if start is not None and i - start >= 2:
                zones += 1
            start = None
    if start is not None and len(rows) - start >= 2:
        zones += 1
    score_rhythm = round(max(0.0, 10.0 - zones * 3), 1)

    total = round(score_hook + score_g3 + score_thrill + score_ai + score_rhythm, 1)

    if total >= 85:
        verdict = "高潜 🔥（可直接投番茄/起点）"
    elif total >= 70:
        verdict = "可投 ✅（先打磨低分项再投）"
    elif total >= 55:
        verdict = "需打磨 ⚠（重写低分章节后重扫）"
    else:
        verdict = "不建议 ❌（需大幅调整开篇与节奏）"

    print("\n" + "=" * 60)
    print("  📋 签约可行性报告")
    print("=" * 60)
    print(f"  {'维度':<12}{'得分':>8}{'满分':>6}  说明")
    print("  " + "-" * 56)
    print(f"  {'章末钩子':<12}{score_hook:>8}{30:>6}  覆盖率 {hook_rate * 100:.0f}%")
    print(f"  {'黄金三章':<12}{score_g3:>8}{30:>6}  体检达标 {g3_rate * 100:.0f}%")
    print(f"  {'爽点密度':<12}{score_thrill:>8}{20:>6}  💥{avg_thrill:.2f}/✨{avg_surge:.2f} 每千字")
    print(f"  {'反AI腔':<12}{score_ai:>8}{10:>6}  囷痕 {avg_echo:.2f}% / 深度 {avg_deep:.1f}")
    print(f"  {'节奏':<12}{score_rhythm:>8}{10:>6}  塌陷区 {zones} 个")
    print("  " + "-" * 56)
    print(f"  {'总分':<12}{total:>8}{100:>6}  → {verdict}")
    print()

    # ---- 对标番茄签约要素 ----
    first = rows[0]
    print("  【对标番茄签约要素】")
    items = [
        ("开篇 300 字内出事件", bool(first.get("opening")),
         "第 1 章开场变故缺失会直接劝退"),
        ("前三章金手指/机缘", g3_pass >= 2 and len([r for r in rows if r['idx'] <= 3]) >= 2
         and bool(_golden_check(
             dict((idx, c) for idx, _, c in chapters).get(first["idx"], ""), GOLDEN_POWER)),
         "金手指是追读的第一动力"),
        ("前三章身份落差", g3_pass >= 2 and bool(_golden_check(
             dict((idx, c) for idx, _, c in chapters).get(first["idx"], ""), GOLDEN_IDENTITY)),
         "废柴/受辱开局是经典签约模板"),
        ("章末钩子覆盖率", hook_rate >= 0.8, "低于 80% 追读率会掉"),
        ("每章有爽点", avg_thrill + avg_surge >= 1.0, "爽点密度决定留读"),
        ("无明显 AI 腔", avg_echo < 1.0 and avg_deep < 3.0, "编辑一眼 AI 味会直接退稿"),
    ]
    for label, ok, tip in items:
        mark = "✅" if ok else "⚠ 缺"
        print(f"    {mark} {label}")
        if not ok:
            print(f"        ↳ {tip}")
    print("=" * 60 + "\n")


def split_chapters(path):
    """按「第 N 章」标题行把成书 txt 切成章节列表。"""
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    chapters = []  # (idx, title, content)
    cur_idx, cur_title, cur_body = None, "", []
    for line in lines:
        m = CHAPTER_RE.match(line.strip())
        if m:
            if cur_idx is not None:
                chapters.append((cur_idx, cur_title, "\n".join(cur_body).strip()))
            cur_idx = int(m.group(1))
            cur_title = line.strip()
            cur_body = []
        elif cur_idx is not None:
            # 跳过章节分隔线（————）
            if line.strip().startswith("—"):
                continue
            cur_body.append(line)
    if cur_idx is not None:
        chapters.append((cur_idx, cur_title, "\n".join(cur_body).strip()))
    return chapters


def main():
    p = argparse.ArgumentParser(description="墨匠成书质检扫描器（零成本基线验证）")
    p.add_argument("novel_txt", help="成书 txt 路径")
    p.add_argument("--json", action="store_true", help="以 JSON 输出结果")
    args = p.parse_args()

    chapters = split_chapters(args.novel_txt)
    if not chapters:
        print("[ERROR] 未识别到任何「第 N 章」标题行，请确认文件格式。")
        sys.exit(1)

    total_hook = 0
    total_open = 0
    rows = []
    for idx, title, content in chapters:
        words = count_words(content)
        hook = has_ending_hook(content)
        opening = has_quick_opening(content)
        thrill = thrill_per_thousand(content)
        hits = sum(content.count(c) for c in AI_CLICHE)
        echo = round(hits / words * 100, 2) if words > 0 else 0.0
        total_hook += 1 if hook else 0
        if idx <= 3:
            total_open += 1 if opening else 0
        rows.append({
            "idx": idx, "title": title, "words": words,
            "has_hook": hook, "has_quick_opening": opening,
            # 兼容黄金三章/签约报告读取的简名键（print_golden_three 等）
            "hook": hook, "opening": opening,
            "ai_echo_pct": echo, "thrill_per_k": thrill,
            "surge_per_k": surge_per_thousand(content),
        })

    if args.json:
        import json
        print(json.dumps({
            "file": args.novel_txt,
            "chapters": rows,
            "stats": {
                "total": len(rows),
                "hook_pass": total_hook,
                "hook_rate": round(total_hook / len(rows), 3),
                "opening_pass": total_open,
                "opening_rate": round(total_open / min(3, len(rows)), 3),
                "avg_ai_echo": round(sum(r["ai_echo_pct"] for r in rows) / len(rows), 2),
                "avg_thrill": round(sum(r["thrill_per_k"] for r in rows) / len(rows), 2),
                "thrill_pass_rate": round(
                    sum(1 for r in rows if r["thrill_per_k"] >= 1.0) / len(rows), 3),
            },
        }, ensure_ascii=False, indent=2))
        return

    print(f"\n《{os.path.basename(args.novel_txt)}》 质检基线（共 {len(rows)} 章）\n")
    print(f"{'章':>3} {'字数':>6}  {'钩子':>4}  {'开场':>4}  {'爽点/千':>7}  {'AI囷痕':>7}  标题")
    print("-" * 78)
    for r in rows:
        hook_flag = "🪝" if r["has_hook"] else "✗无钩"
        open_flag = "⚡" if r["has_quick_opening"] else "✗慢"
        thrill_flag = "💥" if r["thrill_per_k"] >= 0.5 else "✗淡"
        print(f"{r['idx']:>3} {r['words']:>6}  {hook_flag:>4}  {open_flag:>4}"
              f"  {thrill_flag}{r['thrill_per_k']:>5.2f}"
              f"  {r['ai_echo_pct']:>6.2f}%  {r['title']}")
        if not r["has_hook"]:
            print("      ↳ 章末疑似缺少钩子（结尾 200 字未见悬念信号）")
        if r["idx"] <= 3 and not r["has_quick_opening"]:
            print("      ↳ 开场 300 字未进入变故/冲突（黄金三章要求）")
        if r["thrill_per_k"] < 0.5:
            print("      ↳ 爽点过淡（<0.5/千字）")

    # ===== 爽点密度曲线（ASCII） =====
    print("\n【爽点密度曲线】每章每千字爽点数（💥 参考线：1.5 合格 / 1.0 及格 / 0.5 过淡）")
    _print_thrill_curve(rows)

    # ===== 节奏塌陷检测 =====
    _print_collapse_zones(rows)

    # ===== 黄金三章专项体检 =====
    print_golden_three(chapters, rows)

    # ===== 签约可行性报告 =====
    print_signability_report(rows, chapters)

    hook_rate = total_hook / len(rows) * 100
    print("-" * 78)
    print(f"\n【汇总】")
    print(f"  章末钩子覆盖率：{total_hook}/{len(rows)} 章（{hook_rate:.0f}%）")
    print(f"  黄金三章开场通过：{total_open}/{min(3, len(rows))} 章")
    avg = sum(r["ai_echo_pct"] for r in rows) / len(rows)
    print(f"  平均 AI 囷痕密度：{avg:.2f}%")
    avg_t = sum(r["thrill_per_k"] for r in rows) / len(rows)
    pass_t = sum(1 for r in rows if r["thrill_per_k"] >= 1.0)
    low_t = min(rows, key=lambda r: r["thrill_per_k"])
    print(f"  平均爽点密度：{avg_t:.2f}/千字｜达标章数（>=1.0）：{pass_t}/{len(rows)}")
    print(f"  爽点最淡章节：第 {low_t['idx']} 章（{low_t['thrill_per_k']:.2f}/千字）")
    # AI 味深度（统计层：句长均匀度/的字/叠词/句首连接词）
    deep_levels = []
    for idx, title, content in chapters:
        deep_levels.append(deep_ai_metrics(content)["level"])
    deep_avg = sum(deep_levels) / len(deep_levels)
    deep_heavy = sum(1 for lv in deep_levels if lv >= 3)
    deep_flag = "🤖" if deep_avg >= 3 else ("⚠" if deep_avg >= 1.5 else "✅")
    print(f"  AI 味深度（0~4，≥3 为偏重）：均值 {deep_avg:.1f} {deep_flag}"
          f"｜偏重章节 {deep_heavy}/{len(deep_levels)}")
    if deep_heavy > 0:
        print(f"    ↳ 提示：句长过于均匀/「的」字过多/叠词修饰/句首连接词 超标，建议编辑润色")
    print(f"\n  💡 钩子覆盖率 < 80% 或前三章开场未全过 → 建议启用新版生成标准重跑；")
    print(f"     > 90% → 说明写作准则的「结尾留钩」执行到位，生成质量基线良好。\n")


def _print_thrill_curve(rows):
    """打印垂直 ASCII 爽点密度曲线（纵轴 0~3.0，0.5/格）。"""
    if not rows:
        return
    levels = 6  # 0.5 * 6 = 3.0
    heights = [min(int(r["thrill_per_k"] / 0.5), levels) for r in rows]
    print()
    for row in range(levels, 0, -1):
        val = row * 0.5
        line = ""
        for h in heights:
            line += "█" if h >= row else " "
        label = f"{val:.1f} | {line}"
        if val == 1.5:
            label += "  ← 合格线"
        elif val == 0.5:
            label += "  ← 过淡线"
        print(label)
    # 底部坐标（只标首/中/尾章号）
    n = len(rows)
    tick_positions = sorted({0, n - 1, n // 2})
    ticks = [" "] * n
    for i in tick_positions:
        ticks[i] = str(rows[i]["idx"])[0]
    axis = "     +" + "-" * n
    print(axis)
    print("      " + "".join(ticks))
    print("      " + "章序 →".ljust(n))
    print()


def _print_collapse_zones(rows):
    """检测连续 >=2 章爽点密度 <0.5 的节奏塌陷区。"""
    zones = []
    start = None
    for i, r in enumerate(rows):
        if r["thrill_per_k"] < 0.5:
            if start is None:
                start = i
        else:
            if start is not None and i - start >= 2:
                zones.append((rows[start]["idx"], rows[i - 1]["idx"], i - start))
            start = None
    if start is not None and len(rows) - start >= 2:
        zones.append((rows[start]["idx"], rows[-1]["idx"], len(rows) - start))

    if zones:
        print("【⚠ 节奏塌陷区】连续 2 章以上爽点 <0.5/千字：")
        for s, e, cnt in zones:
            print(f"  ⚠ 第 {s}-{e} 章（连续 {cnt} 章）——读者流失高风险，建议重写或插入爽点场景")
    else:
        print("【节奏健康】未发现连续 2 章以上的爽点塌陷区 ✅")


if __name__ == "__main__":
    main()
