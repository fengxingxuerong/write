#!/usr/bin/env python3
"""墨匠语义硬伤检测器 v1 —— 抓机器质检够不着、人工试读才看得见的硬伤。

背景：机器质检分（钩子/爽点/AI 味/句式指纹）对下列「语义级硬伤」天然失盲，
历来只能靠人工试读发现（《铁掌破风》机器 93.3 高潜🔥但人工复核翻车即为例证）：

  关卡 1  人称漂移：第一人称叙述 ↔ 第三人称叙述中途切换
          （《铁掌破风》第 1 章内「我」叙述突然切成「裴照」第三人称）
  关卡 2  主角称谓漂移：主角名字中途换人 / 占位称呼未落实命名
          （「苏小子/姓苏的」→「裴照」，且两个称呼体系几乎互不重叠；
            「X某 / 姓X的 / X小子」属 AI 写手未落实命名的强信号）
  关卡 3  标题-内容相符：题材词零命中 = 内容塌陷 / 跑偏
          （《铁掌破风》玄幻书正文写成守井人现代文）
  关卡 4  人物关系张冠李戴：排他型关系（父母/师父/夫妻）同一
          「(关系, 被修饰者)」指向不同对象（人工试读四连翻车之一，2026-09-23）

本脚本为上述关卡提供**纯规则**检测，零 LLM 成本，作为「投前五关」的规则层关卡
（关卡 5 编造核查走 LLM 换模型家族，见 novel_pipeline 的 fact_check 阶段）。
函数均为可导入纯函数，便于集成进 run_smoke_gate / qa_scan_existing / Dart 端。

用法:
  python qa_semantic_check.py <小说.txt路径> [--json] [--block-chars 500]
      [--expected-protagonist 主角名] [--min-cluster 8]

校准基准（2026-09-23）:
  genre_tiyu_full.txt（《铁掌破风》）应报: 第 1 章内 first→third 切换 + 苏/裴称谓断裂
  genre_junshi_full.txt / novel_10w_pipeline_final.txt 等正常书应零/低误报
  关卡 4 同口径：负样本零误报优先（宁可漏报不可误报）
"""
import argparse
import json
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

CHAPTER_RE = re.compile(r"^\s*(第\s*\d+\s*章[^\n]*)", re.MULTILINE)

# ============================================================
# 文本预处理：章节切分 / 对话剔除
# ============================================================
# ============================================================
# 兄弟模块转发（2026-10-10 从本文件拆出）
# ============================================================
# 转发导入而非直接定义，是为了让调用点（本文件 main / run_smoke_gate / 测试）零改动。
# 先补 sys.path 使 `python -m scripts.qa_semantic_check` 与直跑两种入口都能解析平铺同级模块。
if os.path.dirname(os.path.abspath(__file__)) not in sys.path:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qa_content import (  # noqa: E402,F401
    CONTENT_MIN_CHARS,
    CONTENT_SUSPECT_CAP,
    CONTENT_SUSPECT_RATIO,
    GENRE_CONTENT_WORDS,
    _title_keywords,
    detect_content_drift,
)
from qa_names import (  # noqa: E402,F401
    MIN_CAND_FREQ,
    MIN_CLUSTER_FREQ,
    MIN_MEMBER_FREQ,
    NICKNAME_RES,
    OBJ_SUFFIX,
    PLACEHOLDER_RES,
    PRON_SUFFIX,
    SPAN_OVERLAP_ALERT,
    STOP_NAMES,
    SURNAMES,
    VERB_CHARS,
    cluster_names,
    detect_name_drift,
    discover_names,
)
from qa_pov import (  # noqa: E402,F401
    FIRST_PRON,
    POV_FIRST_RATIO,
    POV_MIN_NARR_CHARS,
    POV_MIN_PRON,
    POV_STABLE_RUN,
    POV_THIRD_RATIO,
    THIRD_PRON,
    block_pov,
    detect_pov_drift,
    split_blocks,
)
from qa_relation import (  # noqa: E402,F401
    _REL_ADVERBS,
    _REL_ALT,
    _REL_BAD_CHARS,
    REL_P1_PAT,
    REL_P2_PAT,
    REL_WORDS,
    _clean_rel_name,
    detect_relation_drift,
)
from qa_text import (  # noqa: E402,F401
    DIALOGUE_PATTERNS,
    strip_dialogue,
)


def load_chapters(path):
    """按「第 N 章」切分成书，返回 (title, [(idx, ch_title, content)])。

    第一个章标题之前的文字（书名/简介）忽略；无任何章标题时整本算第 1 章。
    """
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        text = f.read()
    title = ""
    m = re.search(r"《(.+?)》", text[:200])
    if m:
        title = m.group(1)

    matches = list(CHAPTER_RE.finditer(text))
    chapters = []
    if not matches:
        return title, [(1, "全篇", text)]
    if matches[0].start() > 0:
        pass  # 书名等前置文字忽略
    for i, mt in enumerate(matches):
        start = mt.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        ch_title = mt.group(1).strip()
        body = text[start:end]
        # 去掉章节分隔线
        body = re.sub(r"^[—\-=]{3,}\s*", "", body)
        chapters.append((i + 1, ch_title, body))
    return title, chapters


# 引号（含嵌套）：迭代剔除直到稳定，先内层后外层


# ============================================================
# 关卡 1：人称一致性检测（叙述人称漂移）
# ============================================================


# 块级判定阈值（校准基准见文件头）
                           # 8 会漏掉第 1 章切换后的短第三人称块）


# ============================================================
# 关卡 2：角色名漂移检测
# ============================================================


# 候选名后紧跟这些单字（动作/说话/介词/助词）视为强上下文

# 高频词误报黑名单（姓氏撞词）

# 器物/地物/方位/亲属称谓/身体部位类第二字黑名单：
# 候选名第二字命中即视为词组而非人名
# （陶罐/柴刀/井底/师尊/师父/石头/左肩/王村…；保留砚/墨/石/峰等常见人名字）

# 占位称呼模式（真占位 = 写手未落实命名的强信号）
# 昵称模式（老王/小裴——正常称呼，聚簇参与但不进占位信号）

# 代词/虚词类第二字黑名单（连你/像他/高不/高个…）

                         # 全碎片词组簇冒充；真主角簇代表名 >=5 次）


# ============================================================
# 关卡 3：标题-内容相符检测（题材内容塌陷）
# ============================================================
# 事故形态：《铁掌破风》第 2 章标题「试训」下零体育内容（跑偏成守井人玄学）。
# 与 GENRE_THRILL_EXTRA（爽点词）不同，这里用「题材场景元素词」——
# 正文里真正构成题材内容的名词/场景词。


# 塌陷判定阈值（校准：正样本《铁掌破风》--genre 体育 第 2 章零命中；
# 负样本各书每章命中密度 >=1/千字）


# ============================================================
# 关卡 4：人物关系归属一致性（关系张冠李戴）
# ============================================================
# 背景：《铁掌破风》人工试读四连翻车含「角色关系张冠李戴」，机器分抓不住。
# 机制：只取**排他型关系词**（唯一父母/唯一师承/一夫一妻/唯一主人身份），
# 双向句式归一为 (关系, 被修饰者) → 关系对象；同一键指向不同对象即疑似张冠李戴：
#   P1「林舟的父亲是林啸天」→ (父亲, 林舟) → 林啸天
#   P2「林啸天是林舟的父亲」→ (父亲, 林舟) → 林啸天
# 非排他关系（徒弟/师兄/朋友/对手/属下天然多值）不参与，防误报。
# 防误报三件套（负样本零误报优先，宁可漏报）：
#   ① 名字含代词/否定/量词/的 → 整条丢弃（「他是林啸天的父亲」「一位医生」类）
#   ② 时地副词前后缀剥离（「当年林啸天」「就是林啸天」与「林啸天」归一）
#   ③ P1 对象侧加 (?![汉字]) 边界——后接叙述文字的贪婪吞字直接不匹配（漏报可接受）

# 排他型关系词（P1: X的rel是Y / P2: X是Y的rel；rel 均为捕获组，
# 防「王夫人的女儿」这类被修饰者姓名本身含关系词时取错 rel）

# 名字里出现这些字 → 是代词/否定/量词/结构词而非人名，整条丢弃
# 时地/评注副词前后缀（与人名归一：当年林啸天 ≡ 林啸天 ≡ 林啸天就是）


# ============================================================
# CLI 报告输出
# ============================================================

def print_report(result, book_title=""):
    pov_events, pov_summary, name = (result["pov_events"], result["pov_summary"],
                                     result["name_drift"])
    content = result.get("content_drift") or {}
    print(f"\n{'=' * 62}\n【语义硬伤检测】{book_title}\n{'=' * 62}")

    # 关卡 1：人称
    print("\n【关卡 1 · 叙述人称一致性】")
    for s in pov_summary:
        label = {"first": "第一人称", "third": "第三人称"}.get(s["dominant_pov"], "—")
        print(f"  第 {s['idx']:>2} 章 {s['title'][:12]:<14} 主导: {label:<6}"
              f" (first×{s['first_blocks']} third×{s['third_blocks']}"
              f" mixed×{s['mixed_blocks']} skip×{s['skipped_blocks']})")
    if pov_events:
        for e in pov_events:
            print(f"  ⚠ 第 {e['chapter']} 章「{e['chapter_title']}」{e['pos_ratio']*100:.0f}% 处"
                  f"人称切换: {e['from_pov']} → {e['to_pov']}")
            print(f"      ↳ 切换后开头: 「{e['excerpt']}」")
        print(f"  结论: ⚠ 抓到 {len(pov_events)} 处叙述人称漂移")
    else:
        print("  结论: ✅ 未检出叙述人称漂移")

    # 关卡 2：角色名
    print("\n【关卡 2 · 主角称谓一致性】")
    if name["clusters"]:
        print("  活跃称谓簇（Top）:")
        for k, v in list(name["clusters"].items())[:6]:
            names = "/".join(list(v["names"].keys())[:4])
            print(f"    {k}簇: {v['total']:>3} 次 ({names})")
    if name["placeholders"]:
        ph = "、".join(
            f"{p['cluster']}系({'+'.join(p['names'][:3])})"
            for p in name["placeholders"][:4])
        print(f"  💡 占位称呼（未落实命名信号）: {ph}")
    if name["span_alerts"]:
        for a in name["span_alerts"]:
            print(f"  ⚠ 称谓区间几乎不重叠: {a['cluster_a']}簇 {a['span_a']}"
                  f" vs {a['cluster_b']}簇 {a['span_b']} (重叠率 {a['overlap_ratio']})")
    if name.get("takeover_alerts"):
        for t in name["takeover_alerts"]:
            print(f"  ⚠ 占位称呼在全书 {t['placeholder_last_ratio']*100:.0f}% 处消失后，"
                  f"「{t['cluster']}」簇（{t['cluster_total']} 次）于 "
                  f"{t['cluster_first_ratio']*100:.0f}% 处接管主角位")
    if name["expected_protagonist"]:
        ei = name["expected_protagonist"]
        print(f"  预期主角「{ei['name']}」簇频次: {ei['cluster_total']}")
        if ei["louder_rivals"]:
            print(f"      ↳ ⚠ 更响亮的竞争簇: {ei['louder_rivals']}")
    conf = name["confidence"]
    verdict = {"high": "⚠ 高置信主角称谓漂移",
               "medium": "⚠ 中置信主角称谓漂移（建议人工复核）",
               "none": "✅ 未检出主角称谓漂移"}[conf]
    print(f"  结论: {verdict}")

    # 关卡 3：标题-内容相符
    if content:
        print(f"\n【关卡 3 · 标题-内容相符】（题材: {content['genre']}"
              f"{'，自动探测' if content.get('genre_auto') else ''}，"
              f"全书章密度中位数 {content['median_density']}/千字）")
        for a in content["alerts"]:
            if a["level"] == "high":
                mark = "⚠"
            elif a["level"] == "medium":
                mark = "⚠"
            else:
                mark = "💡"
            tw = "/".join(a["title_words"][:2]) or "—"
            th = "标题词已现" if a["title_hit"] else "标题词未现"
            print(f"  {mark} 第 {a['idx']} 章「{a['title'][:14]}」"
                  f"题材词命中 {a['hits']} 次（{a['density']}/千字，{th}·「{tw}」）"
                  + ("——疑似内容跑偏，须人工复核" if a["level"] in ("high", "medium")
                     else "——题材密度偏低，留意"))
        if not content["alerts"]:
            print("  结论: ✅ 各章题材内容密度正常，未检出标题-内容脱节")
        else:
            n_high = sum(1 for a in content["alerts"] if a["level"] in ("high", "medium"))
            print(f"  结论: ⚠ 抓到 {n_high} 章题材内容塌陷"
                  if n_high else "  结论: 💡 无塌陷章，仅密度偏低提示")

    # 关卡 4：人物关系归属（张冠李戴）
    rel_d = result.get("relation_drift") or {}
    if rel_d:
        print(f"\n【关卡 4 · 人物关系一致性】（关系断言 {rel_d.get('claims', 0)} 条）")
        if rel_d.get("alerts"):
            for a in rel_d["alerts"]:
                tag = "章内自相矛盾" if a["level"] == "high" else "跨章指向不同"
                vs = "、".join(
                    f"「{v['value']}」(第{'/'.join(str(c) for c in v['chapters'])}章×{v['count']})"
                    for v in a["values"][:3])
                print(f"  ⚠ [{tag}] {a['head']}的{a['rel']}: {vs}")
                print(f"      ↳ 证据: 「{a['phrase']}」")
            print(f"  结论: ⚠ 抓到 {len(rel_d['alerts'])} 处关系张冠李戴（人工复核）")
        else:
            print("  结论: ✅ 未检出排他型关系矛盾")

    # 总判
    rel_d = result.get("relation_drift") or {}
    total_alerts = (len(pov_events) + len(name["span_alerts"])
                    + len(name.get("takeover_alerts") or [])
                    + sum(1 for a in content.get("alerts", [])
                          if a["level"] in ("high", "medium"))
                    + len(rel_d.get("alerts") or []))
    print(f"\n{'-' * 62}")
    if total_alerts > 0:
        print(f"  总判: ⚠ 共 {total_alerts} 处语义硬伤警报——投递前须人工复核")
    else:
        print("  总判: ✅ 四关全过（规则层零警报，仍建议抽读正文）")
    print()


def main():
    ap = argparse.ArgumentParser(description="墨匠语义硬伤检测器 v1（人称/角色名/题材/关系漂移）")
    ap.add_argument("book", help="小说 txt 路径")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--block-chars", type=int, default=500, help="人称检测块大小（默认 500 字）")
    ap.add_argument("--expected-protagonist", default=None, help="预期主角名（校验用）")
    ap.add_argument("--min-cluster", type=int, default=MIN_CLUSTER_FREQ,
                    help="参与区间分析的簇最小频次（默认 8）")
    ap.add_argument("--genre", default=None,
                    help="题材（玄幻/体育/军事…；缺省自动探测）")
    args = ap.parse_args()

    if not os.path.exists(args.book):
        print(f"文件不存在: {args.book}", file=sys.stderr)
        sys.exit(2)

    title, chapters = load_chapters(args.book)
    pov_events, pov_summary = detect_pov_drift(chapters, args.block_chars)
    name_drift = detect_name_drift(chapters, args.expected_protagonist, args.min_cluster)
    content_drift = detect_content_drift(chapters, args.genre)
    relation_drift = detect_relation_drift(chapters)

    result = {
        "book": title or os.path.basename(args.book),
        "pov_events": pov_events,
        "pov_summary": pov_summary,
        "name_drift": name_drift,
        "content_drift": content_drift,
        "relation_drift": relation_drift,
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print_report(result, result["book"])


if __name__ == "__main__":
    main()
