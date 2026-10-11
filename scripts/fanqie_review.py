#!/usr/bin/env python3
"""番茄过审评审器（本地零成本，不调 LLM）。

把「能不能过番茄作品评估」拆成可计算的三组指标：

1) 红线合规（一票否决）——时政/宗教民族/封建迷信渲染/未成年风险/过度血腥/现实品牌真人
2) 开篇与结构（决定编辑是否继续看）——首屏 300 字、黄金三章、每章四件套
3) 完读率与同质化（决定数据表现与"低质/AI 味"判定）——句长/段长/对话占比/水段率/套句重合率

用法：
  python fanqie_review.py <成书.txt> [--genre 历史] [--json]
  # 或在 novel_pipeline 中作为库使用：review_chapter() / review_book() / fix_prompt()

口径说明：词表与阈值是「编辑初审」的代理指标，不是番茄官方规则；
命中不代表一定被拒，不命中也不代表一定签约。它的作用是——让生成端有一把
可以反复量的尺子，而不是靠"爽点词命中次数"这种会奖励套路的假指标。
"""
import io
import json
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


# 词表/阈值单一数据源（rules/quality_rules.json 的生成物，与 Dart QualityRules 同源）。
# 两种入口都要能导入：`python -m scripts.fanqie_review`（包内，走相对导入）与
# `python scripts/fanqie_review.py` / 被 generate_novel 同目录导入（走平铺导入）。
# 下方 FIX_MIN_RATIO / REDLINE_* / INSTRUCTION_MARKS 即由该生成物提供——本文件不再保存
# 字面量（改词表请改 JSON 后跑 scripts/rules_codegen.py）；TRIAD_END_* 等指标词表随拆分
# 迁到 fanqie_metrics（由该模块从生成物导入）。
# TRIAD_HOOK_ONLY 本模块不用（由 generate_novel 直接从生成物导入），故不在此转发。
try:  # pragma: no cover - 分支取决于调用方式
    from .quality_rules_generated import (
        FIX_MIN_RATIO,
        INSTRUCTION_MARKS,
        REDLINE_BRAND_CELEBRITY,
        REDLINE_GORE,
        REDLINE_ILLEGAL_DETAIL,
        REDLINE_MINOR_RISK,
        REDLINE_POLITICS,
        REDLINE_RELIGION,
    )
except ImportError:  # pragma: no cover - 平铺导入（脚本直跑/同目录 import）
    _here = os.path.dirname(os.path.abspath(__file__))
    if _here not in sys.path:
        sys.path.insert(0, _here)
    from quality_rules_generated import (
        FIX_MIN_RATIO,
        INSTRUCTION_MARKS,
        REDLINE_BRAND_CELEBRITY,
        REDLINE_GORE,
        REDLINE_ILLEGAL_DETAIL,
        REDLINE_MINOR_RISK,
        REDLINE_POLITICS,
        REDLINE_RELIGION,
    )

# ============================================================
# 兄弟模块转发（2026-10-10 从本文件拆出）
# ============================================================
# 转发导入而非直接定义，是为了让调用点（本文件 review_chapter/fix_prompt/main
# 及仓库内各脚本/测试）零改动——拆分只降低维护成本，不改对外契约。
# 先补 sys.path 使 `python -m scripts.fanqie_review` 与直跑两种入口都能解析平铺同级模块。
if os.path.dirname(os.path.abspath(__file__)) not in sys.path:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fanqie_metrics import (  # noqa: E402,F401
    ANCIENT_GENRES,
    BLOCKING_MIN_WORDS,
    CLICHE_SENTENCES,
    CONFLICT_WORDS,
    DRIVE_WORDS,
    INTRA_REPEAT_GRAM,
    INTRA_REPEAT_MIN_BLOCK,
    META_TALK,
    MODERN_MARKERS,
    NAME_PAT,
    PROMPT_LEAK,
    SURNAMES,
    TRIAD_END_WORDS,
    _dup_spans,
    _long_paras,
    _para_dup,
    agency_check,
    blocking_reasons,
    cliche_overlap,
    dedup_intra_repeat,
    ending_ev_fragment,
    ending_triad,
    filler_ratio,
    first_screen_check,
    genre_drift,
    intra_repeat,
    looks_like_name,
    meta_talk,
    name_drift,
    pacing_stats,
    prompt_leak,
    repeat_with_prev,
    self_repeat_ratio,
)
from fanqie_text import (  # noqa: E402,F401
    CHAPTER_RE,
    CHAR_RE,
    QUOTE_RE,
    SENT_SPLIT,
    count_words,
    dialogue_ratio,
    paragraphs,
    sentences,
    split_chapters,
)
from fanqie_world import (  # noqa: E402,F401
    _GENERIC_WORLD,
    _SEP_CHARS,
    _TERM_OK,
    _term_hit,
    extract_world_terms,
    world_consistency,
)

# ============================================================
# 1) 红线词表（番茄平台审核红线，6 类）
#    值来自 rules/quality_rules.json 的 redline* 六张表（与 Dart 编辑自查词库**不是**
#    同一套**：词级交集仅 17/295，作用域与分类都不同——见
#    docs/quality-rules-current.md 第三节 asymmetries.complianceTables）
#    白名单：命中该词但上下文属于合法叙事时降级为「提示」而非「否决」
# ============================================================
REDLINE = {
    "时政敏感": list(REDLINE_POLITICS),
    "宗教民族": list(REDLINE_RELIGION),
    "未成年风险": list(REDLINE_MINOR_RISK),
    "过度血腥": list(REDLINE_GORE),
    "现实品牌与真人": list(REDLINE_BRAND_CELEBRITY),
    "教唆与违法细节": list(REDLINE_ILLEGAL_DETAIL),
}

# 白名单：命中该词但上下文属于合法叙事时降级为「提示」而非「否决」
REDLINE_WHITELIST = {
    "分尸": re.compile(r"分尸案|碎尸案|串并案"),
    "肢解": re.compile(r"肢解痕迹|疑似被肢解"),
    "凌迟": re.compile(r"(历史上|记载|律例|明正|刑罚志)"),
    "上访": re.compile(r"上访材料|信访局接待"),  # 现实题材案件线索，仍属高风险，仅降级
    "吸毒": re.compile(r"尿检呈阳性|因吸毒被抓"),
}

# ============================================================
# 2) 同质化套句库（网文高频"AI 也爱写"的句子骨架）
#    命中越多 → 越像流水线产物 → 查重/低质判定风险越高
#    值来自 rules/quality_rules.json 的 reviewClicheSentences（Python 评审口径）。
#    注意：Dart 闸门用的是**另一张**表 gateClichePhrases（同公式不同词表，
#    两端差异记录于 docs/quality-rules-current.md 第三节 asymmetries.clicheTables）。
# ============================================================

# ============================================================
# 3) 章末三件套收尾（FANQIE 规则 20 / 规则 10 / scene_prompt 双端承诺的检测器）
#    背景：三件套（发烫/亮起/苏醒…）是 AI 网文读者一眼假的收尾套路，规则层
#    全端禁止，但检测侧长期空白——且 has_ending_hook 把「发烫」「醒了过来」
#    当钩子词，三件套收尾反被判「有钩」（真实成书 116 章实测 93% 反向奖励，
#    历史事故「52% 章节落在发光物件+苏醒」即此形态）。2026-09-28 补齐。
# ============================================================
# 收束区域判定词表（TRIAD_END_WORDS）：值来自 rules/quality_rules.json -> 生成物。
# 长词在前（像有什么东西醒了 > 醒了过来 > 醒了、亮了起来 > 亮了）。
# 「亮」字族带天字排除（「天亮了」是时间过渡，不是发光物件收束）。
# HOOK_WORDS 中属于三件套性质的成员：作为**唯一**尾部钩子信号时不采信（frozenset，生成物）。
# 收束区域窗口（校准：tool/probe_ending_and_simile.py 三窗口 × 词表敏感性——
# 末句 6.9% / 末60字 11.2% / 末200字 25.9%；取末 60 字，200 字窗会把
# 「尾部另有真钩子、三件套只出现在中段」的章误伤）。


# 段落"推进力"检测用的动词/信息词（有则视为该段在推进剧情）


# 人名候选：2~3 字汉字串 + 动作/说话词（用于查“主角漂移”）

# 冲突信号：首屏必须出现至少一个（开局要带包袋）
# 值来自 rules/quality_rules.json 的 conflictWords -> quality_rules_generated
# （2026-10-03 收编：Dart 原表是本表的真子集，Python 独有 9 词实测命中
#  66/123 份真实成书 = 53.7%，属真漏判，故以本表全集为准单端收编并双端同源）

# 骨架/规划官提示词泄漏（漏进正文 = 直接判废）

# 元话语/指令残留（模型把「补写操作说明」当正文吐出来，拼进成书 = 直接判废）
# 实测事故：钩子补写返回「我拿到的指令是补写钩子，不是扩写。你贴的那段"充到 2000 字以上"…」
# 被原样拼到第 1 章末尾，本地评审仍给 92 分（旧 PROMPT_LEAK 只覆盖骨架词，抓不到这类）。
# 选词原则：只收「叙事里不可能出现」的短语，避免误伤正文（不用「抱歉」「请确认」这类口语）。

# 题材漂移：给「古风/非现代」题材用的现代生活标志词。
# 实测事故：玄幻书第 3 章整章变成现代都市悬疑（路灯/手机/牛皮纸袋/面包车），
# 逐章本地评审仍给 84 分，直到终审官通读才发现「书名标称玄幻，末章主角换人」。
# 只收古风题材几乎不可能自然出现的词：「钥匙/医院/巷口」这类玄幻也合法的词一律不收。

# 需要锁题材的「非现代」题材（其余题材如都市/校园/悬疑不做现代词漂移判定）

# 章内大段重复判定：重复块最短字数 / 指纹长度
# 阻断级硬伤的下限字数：番茄单章建议 2000~3000，低于这条线不给「可投」


# ------------------------------------------------------------
# 基础统计
# ------------------------------------------------------------
# 常见姓氏（含网文高频复姓/生僻姓）：只有开头是姓的候选才算人名，
# 否则「人影×10」「老人×8」会被误报成主角漂移。
SURNAMES |= set("欧司马东方上官独孤南宫慕容宇文长孙闻人东郭呼延轩墨夜司徒卿慕凌花")


# 对白引号配对（与 Dart 侧 PipelineQa.dialogueRatioOf 同口径）。
#
# 【口径核实 2026-09-30】曾担心旧写法 `[“"『「]([^”"』」]{1,200})[”"』」]` 会让
# 直引号 `"` 自配对（把 `'青'` 当成对白），遂改为「同类型配对」的多正则版本。
# **实测四种边界情形（跨类型混排 / 奇数个直引号 / 奇数个中文引号 / 直角引号
# 跨句）两种口径输出完全一致**，因为「起引号后紧跟同类型收引号」是绝大多数情况，
# 而落单的引号两边都匹配不到。故原写法并无实际缺陷，本次改动回退，
# 保持单正则（更短、且与历史产物对账口径不变）。


# ------------------------------------------------------------
# 单项指标
# ------------------------------------------------------------
# 这三类只有在「教唆/推广/交易」语境下才是红线；小说把它们当情节元素使用是正常的
# （“妹妹欠下高利贷”不是红线，“高利贷放款教程”才是）。旧版一律否决，
# 实测会误伤《碎星航线》第 1 章（因章纲自带“高利贷”而被扣 45 分）。
NARRATIVE_OK_CATEGORIES = {
    "教唆与违法细节", "宗教民族", "现实品牌与真人"
}
# 2026-10-03 本表**收编进 rules/quality_rules.json**（instructionMarks），两端同源。
# 原两端各写一份（Dart _instructionMark 21 词 / Python 24 词），漂移只能靠注释约束；
# 收编前已按 scripts/ab_rules_parity.py 测过否决条数增量（134 份真实成书）：
# 两表同为 5 条否决、增量 +0，即改判定零风险，故取 Python 全集。
# 改词表请改 JSON 再跑 scripts/rules_codegen.py，不要在本文件写字面量。
# 2026-10-03 修正两处历史笔误（依据：rules/quality_rules.json 的
# asymmetries.instructionMarks；误伤面已用 scripts/probe/probe_instruction_marker.py
# 在 174 份真实成书/样本上实测，否决升级条数差值 +0）：
#   1) 「招摹」→ 「招募」：原为错别字，contains 永远匹配不到「招募」，
#      导致正文出现「招募」时漏判指令痕迹（Dart 侧一直是对的）。
#   2) 「代办」重复登记两次 → 去重。以 any() 语义使用，重复项不影响判定结果，
#      仅属冗余；但留着会让「词表条数」与 Dart 侧对不上、误导后续收编对账。
INSTRUCTION_MARKERS = list(INSTRUCTION_MARKS)


def redline_scan(text):
    """返回命中列表（含类别/词/等级/上下文）。「否决」= 硬伤，「提示」= 人工再看一眼。"""
    hits = []
    for cat, words in REDLINE.items():
        for w in words:
            for m in re.finditer(re.escape(w.strip()), text or ""):
                ctx = (text or "")[max(0, m.start() - 12):m.end() + 12].replace("\n", " ")
                wide = (text or "")[max(0, m.start() - 40):m.end() + 40]
                wl = REDLINE_WHITELIST.get(w)
                if wl and wl.search(ctx):
                    level = "提示"
                elif cat in NARRATIVE_OK_CATEGORIES:
                    level = "否决" if any(k in wide for k in INSTRUCTION_MARKERS) else "提示"
                else:
                    level = "否决"
                hits.append({"category": cat, "word": w.strip(), "level": level,
                             "context": ctx})
    return hits


def patch_gate(patch, base_text="", genre="", max_words=260):
    """补丁卫生：补写/扩写/定点修的产出在拼回正文前必须过这道闸。

    返回 (ok, reason)。拦三类事故（都有实测案例）：
    ① 指令/元话语残留（模型把操作说明当正文）；
    ② 题材漂移（玄幻书补出「手机屏幕亮了」）；
    ③ 与正文尾部重复（补写把结尾复述一遍）。
    """
    p = (patch or "").strip()
    if not p:
        return False, "空产出"
    if count_words(p) > max_words:
        return False, f"超长（{count_words(p)} 字 > {max_words}）"
    leak = prompt_leak(p) + meta_talk(p)
    if leak:
        return False, f"指令/元话语残留「{leak[0]}」"
    dr = genre_drift(p, genre)
    if dr["level"]:
        return False, f"题材漂移：{'、'.join(dr['hits'][:3])}"
    rl = [h for h in redline_scan(p) if h["level"] == "否决"]
    if rl:
        return False, f"合规红线「{rl[0]['word']}」（{rl[0]['category']}）"
    if base_text:
        flat_p = re.sub(r"\s+", "", p)
        tail = re.sub(r"\s+", "", base_text)[-400:]
        for k in range(min(len(flat_p), 80), 19, -5):
            if k <= len(flat_p) and flat_p[:k] and flat_p[:k] in tail:
                return False, f"与正文尾部重复 {k} 字"
    return True, ""


def local_hook_fallback(hook_hint="", protagonist="", genre=""):
    """零 LLM 钩子兜底：用章纲自带的钩子写死一句章末悬念，保证不掉钩、不跑题。

    用途：LLM 补写被拒（指令残留/题材漂移/重复）或全部模型不可用时，仍要留住追读命门。

    【实测事故 2026-09-30】规划官的钩子**系统性**写成 `类型（说明）` 形式
    （`钩子=威胁逼近（周管事察觉异象，封铺捉贼）`，真机 5 章 5 中）。旧实现只按
    冒号切后半段，遇到括号时整段原样返回，于是「威胁逼近（……）」这种**大纲标注**
    被拼进成书第 1 章末尾，读者一眼判定机器产物。故与 Dart 侧
    `_localHookFallback` 同口径修复：
      ① 括号/冒号两种切法都支持，剥掉 `威胁逼近` 这类类型词与外层括号；
      ② 剥完仍带标注感的（残留 `＝`/`｜`/未闭合括号）直接放弃兜底，返回空串，
         由上层保留原文并记日志——宁可章末无钩，也不把标注拼进正文；
      ③ 产出为纯叙事句，绝不把「说明」当正文。
    """
    txt = (hook_hint or "").strip()
    if not txt:
        return ""

    # ① 先剥外层成对括号：取括号内说明（`威胁逼近（说明）` → `说明`）。
    #    规划官的类型词（威胁逼近/信息反转/选择困境/反常细节/承诺未兑）
    #    连同括号一起丢弃——它是大纲标签，不是叙事。
    #    尾部容许句末标点：真机存在 `（……只剩九十天）。` 这种右括号后带句号的写法，
    #    以 `$` 锚定的旧正则会整条失配 → 退回冒号切法 → 切在内层引号的冒号上，
    #    吐出「……'拔擢试上，你会死得很难看'，……）。」，尾部 `）` 漏进正文。
    m = re.match(r"^[^()（）]{0,12}[(（]([^()（）]*)[)）][。．.！!？?、，,；;：:\s]*$", txt)
    if m:
        txt = m.group(1).strip()
    else:
        # ② 无括号时才退回冒号切法（兼容 `威胁逼近：说明` 写法）。
        txt = re.sub(r"^.*?[：:]", "", txt, count=1) if ("：" in txt or ":" in txt) else txt
    txt = txt.strip("（）() 「」『』\n\r\t")
    if not txt:
        return ""

    # ③ 标注残留自检：仍带大纲分隔符或括号不闭合，说明这不是可用的叙事素材。
    if any(t in txt for t in ("＝", "=", "｜", "|")) or re.search(r"[（(]", txt):
        return ""

    head = (protagonist or "").strip() or "他"
    # 剥离后仍可能以主角名开头（「宿峥必须在搜身之前藏住古钱」），此时直接补主语
    # 会读成「宿峥回头。宿峥必须……」，故只在不含主角名时才追加主语。
    out = txt if head in txt else f"{head}回头。{txt.rstrip('。！？')}"
    # 补主语后若以引号起头（「回头。'你会死得很难看'」），会读成无主语引语，
    # 直接弃用这段素材——宁可章末无钩，也不拼出病句。
    if out and out[0] in "'\"“”‘’「」『』":
        return ""
    out = out.rstrip("。！？")
    if not out:
        return ""
    return out + "。"


# ------------------------------------------------------------
# 章节 / 全书评估
# ------------------------------------------------------------
def review_chapter(text, prev_text="", idx=1, genre="", protagonist="", world_terms=(),
                   has_hook=None):
    """单章评估：返回分数 + 问题清单 + 可直接喂回模型的修改指令。

    has_hook：调用方（novel_pipeline）传入的本地理钩子检测结果（has_ending_hook）。
    None=未检测（CLI/旧调用，行为不变）；False=明确无章末钩子 → 记「重写」级问题扣分。
    治「评审 100 分但钩子无」的评分分裂——终审官《断脉逆命诀》实测抓到的案例。"""
    probs = []
    words = count_words(text)
    if words < 1800:
        probs.append(("结构", f"本章仅 {words} 字（番茄单章建议 2000~3000）", "重写"))
    if words > 3800:
        probs.append(("结构", f"本章 {words} 字偏长，建议压到 3000 内", "建议"))
    if has_hook is False:
        probs.append(("钩子", "本章无章末钩子（本地钩子检测直白+隐喻双通道均未命中）"
                      "——追读命门，结尾必须收在悬念/变故/威胁上", "重写"))
    triad = ending_triad(text)
    if triad:
        # 修改级：扣 4 分并进 fix_prompt（fix_prompt 收「修改」级问题）。
        # 若三件套同时是唯一尾钩信号，has_hook 已判 False 另计重写级，两条不重复。
        probs.append(("收尾", f"章末三件套收尾：以「{triad}」收束"
                      "（规则20禁止发烫/亮起/苏醒类「身体异动+发光物件」收尾，"
                      "读者一眼判定 AI 文）——换成未落地的悬念/威胁/反常细节", "修改"))
    fs_probs, _ = first_screen_check(text)
    probs += [("首屏", m, a) for m, a in fs_probs]

    pace = pacing_stats(text)
    if pace["dialogue"] < 0.18:
        probs.append(("对白", f"对话占比仅 {pace['dialogue'] * 100:.0f}%（建议 25~45%）", "重写"))
    if pace["sent_over30"] > 18:
        probs.append(("句长", f"{pace['sent_over30']}% 的句子超 30 字，移动端阅读吃力", "修改"))
    if pace["para_over5"] > 12:
        probs.append(("段落", f"{pace['para_over5']}% 的段落超 160 字，需要拆分", "修改"))

    fr, fr_n = filler_ratio(text)
    if fr > 12:
        # 长段样本太少时不能拿百分比说话（2000 字短章可能只有 4 个长段，
        # 1 个被判水就是 25%）——样本不足只降级为提示。
        kind = "重写" if fr_n >= 8 else "建议"
        probs.append(("水段", f"水段率 {fr}%（统计自 {fr_n} 个 ≥40 字段落；"
                      "无对白且无推进词），删掉不影响剧情的一律重写", kind))
    cl = cliche_overlap(text)
    if cl["per_k"] > 1.2:
        probs.append(("同质化", f"套句 {cl['per_k']}/千字：{'、'.join(cl['hits'][:4])}", "修改"))
    rep = repeat_with_prev(text, prev_text)
    if rep > 4:
        probs.append(("自我重复", f"与上一章 8-gram 重合 {rep}%", "修改"))
    ag = agency_check(text)
    if (ag["passive"] >= 3 and ag["active"] == 0) or \
            (ag["passive"] >= 5 and ag["active"] < ag["passive"] * 0.4):
        probs.append(("主角性", f"主角主动句 {ag['active']} 处 / 被动 {ag['passive']} 处"
                      "（代理指标：本章建议安排一次有代价的主动选择）", "修改"))
    for msg in name_drift(text, protagonist):
        probs.append(("一致性", msg, "重写"))
    wc = world_consistency(text, world_terms)
    if wc and wc["hit"] == 0:
        probs.append(("一致性", f"大纲世界观专名 {wc['total']} 个在正文一个都没出现"
                      f"（写手没接住设定，己另起故事；待补：{'、'.join(wc['missing'][:6])}）", "重写"))
    elif wc and wc["hit"] <= 1:
        probs.append(("一致性", f"世界观专名仅命中 {wc['hit']}/{wc['total']}，题材锁定不够紧"
                      f"（待补：{'、'.join(wc['missing'][:6])}）", "修改"))
    sr = self_repeat_ratio(text)
    if sr > 1.0:
        probs.append(("重复", f"整句重复率 {sr}%（同句复用，读者会判定为凑字）", "重写"))
    leak = prompt_leak(text)
    if leak:
        probs.append(("泄漏", f"提示词/骨架残留漏进正文：{'、'.join(leak[:5])}", "重写"))
    meta = meta_talk(text)
    if meta:
        probs.append(("泄漏", f"模型操作说明/元话语混进正文：{'、'.join(meta[:3])}"
                      "（补写或定点修的说明文字被当成正文采纳）", "重写"))
    gd = genre_drift(text, genre)
    if gd["level"]:
        probs.append(("一致性", f"题材漂移：{genre}题材出现现代标志词 "
                      f"{'、'.join(gd['hits'][:4])}（共 {gd['count']} 处）"
                      "——补写/改写把正文带出了本书世界观", gd["level"]))
    ir = intra_repeat(text)
    if ir["blocks"]:
        probs.append(("重复", f"章内大段重复：{ir['words']} 字整块出现两次"
                      f"（如「{ir['sample']}…」），属复制粘贴级事故", "重写"))

    rl = redline_scan(text)
    veto = [h for h in rl if h["level"] == "否决"]
    warn = [h for h in rl if h["level"] == "提示"]

    score = 100.0
    for cat, _msg, kind in probs:
        score -= 8 if kind == "重写" else (4 if kind == "修改" else 1.5)
    score -= len(veto) * 45 + len(warn) * 5
    score = round(max(0.0, score), 1)
    row = {"idx": idx, "words": words, "score": score, "verdict": "",
           "problems": [{"type": c, "msg": m, "action": k} for c, m, k in probs],
           "redline": {"veto": veto, "warn": warn},
           "metrics": {"pace": pace, "filler": fr, "filler_paras": fr_n,
                       "cliche": cl["per_k"],
                       "repeat": rep, "agency": ag, "world": wc}}
    row["blockers"] = blocking_reasons(row)
    if veto:
        row["verdict"] = "不予推荐"
    elif row["blockers"]:
        # 阻断项在身，分数再高也只能是「需修」——杜绝「92 分可投但整章跑题」
        row["verdict"] = "需修"
    else:
        row["verdict"] = "可投" if score >= 80 else ("需修" if score >= 55 else "不予推荐")
    return row


def review_book(chapters, genre="", protagonist="", world_terms=()):
    """全书评估卡。chapters = [(idx, title, content)]"""
    rows, prev = [], ""
    for idx, title, content in chapters:
        r = review_chapter(content, prev, idx, genre, protagonist, world_terms)
        rows.append(r)
        prev = content
    n = len(rows) or 1
    avg = round(sum(r["score"] for r in rows) / n, 1)
    veto_rows = [r for r in rows if r["redline"]["veto"]]
    first3 = [r for r in rows if r["idx"] <= 3]
    first3_avg = round(sum(r["score"] for r in first3) / max(len(first3), 1), 1)

    # 「阻断项」= 不能让书投出去的硬伤（与逐章评分的软指标分开）。
    # 逐章分只回答「这一章写得好不好」，阻断项回答「这本书现在能不能投」——
    # 实测事故：逐章 92/80/64 但第 3 章整章跑成现代都市、主角缺席、单章 671 字，
    # 旧版 review_book 仍可能给「可投」，与终审官「36 分 不建议」完全背离。
    blockers = []
    for r in rows:
        why = r.get("blockers") or blocking_reasons(r)
        if why:
            blockers.append(f"第 {r['idx']} 章：{'、'.join(why)}")

    if veto_rows:
        verdict = "不予推荐 ❌（存在合规红线，先删改再谈质量）"
    elif len(rows) < 3:
        verdict = "样本不足 ⚠（不足 3 章，无法评估黄金三章）"
    elif blockers:
        verdict = f"不予推荐 ❌（{len(blockers)} 章存在阻断级硬伤，先执行定点修再重扫）"
    elif avg >= 82 and first3_avg >= 80:
        verdict = "可投 ✅（前 3 章达标，具备冷启动条件）"
    elif avg >= 68:
        verdict = "需修 🔧（按章内问题清单逐条定点重写后重扫）"
    else:
        verdict = "不予推荐 ❌（首屏、节奏、主角性多项不达标）"

    return {"avg_score": avg, "first3_score": first3_avg, "verdict": verdict,
            "chapters": rows, "blockers": blockers,
            "veto_count": sum(len(r["redline"]["veto"]) for r in veto_rows)}


# 定点修字数下限：低于则整份产出被 novel_pipeline.apply_text_patch 拒（默认 0.85）。
# 提示词里必须比守卫更严一档（0.92），且要写明「评审的压缩诉求让位于本下限」——
# 否则模型会照【改写要求】的「删水段/短句」把整章压掉三成，产出全被守卫拒绝、
# 定点修白跑、问题原地复发（门禁 v7 实测 4 次：4087→2847 / 3465→2718 /
# 4176→2707 / 5983→1517，四次全部「拒绝采纳保留原文」）。
FIX_MIN_RATIO = FIX_MIN_RATIO  # 值来自 rules/quality_rules.json -> 生成物（0.92）


def fix_prompt(review, content, world_terms=()):
    """把评估结果转成「定点修」提示（只改问题处，保留已写好的剧情与文字）。

    达线且无阻断项（无重写/修改级问题）时返回空串——与 Dart 侧 fixPrompt 同一约定。
    阻断项在身时即使分数达标也照样出单（实测事故：92 分章含「元话语残留」被判可投，
    于是修复链跳过，脏文本一路留到成书）。
    world_terms 传大纲专名时会点名「正文还缺哪些专名」——评审只报「专名一个都没出现」，
    模型拿不到清单就无从下手（门禁 v7 第 13 项「世界观未落地」定点修一轮后仍残留，
    直接原因是修复提示词里根本没有世界观专名）。不传时行为与旧版完全一致。"""
    probs = [p for p in review["problems"] if p["action"] in ("重写", "修改")]
    if not probs or (review.get("verdict") == "可投" and not review.get("blockers")):
        return ""
    lines = [f"- {p['type']}：{p['msg']}" for p in probs]
    rl = review["redline"]["veto"]
    if rl:
        lines += [f"- 合规红线：出现「{h['word']}」（{h['category']}），必须替换成不点名的写法"
                  for h in rl[:8]]
    # 世界观专名缺失清单：评审只报「专名一个都没出现」，不点名缺哪些，模型改不动
    world_block = ""
    if world_terms and any("世界观专名" in p["msg"] for p in probs):
        missing = [t for t in world_terms if not _term_hit(content or "", t)]
        if missing:
            hit = len(world_terms) - len(missing)
            need = min(5, len(missing))
            state = "一个都没出现" if hit == 0 else f"仅命中 {hit}/{len(world_terms)}"
            world_block = (
                "\n【世界观专名·本条为阻断项，必须解决】下列专名取自本书大纲，"
                f"当前正文{state}，还缺 {len(missing)} 个：{'、'.join(missing[:8])}\n"
                f"改写时必须把其中至少 {need} 个自然织进正文（地名/机构/功法/器物/称谓皆可）："
                "经由对白称呼、路牌招牌、他人提及、物件来历描写带出；专名按字面照抄，"
                "禁止换成近义词/简称/拼音（初审按字面命中判定）；"
                "禁止把专名列成清单、禁止整段解释设定、禁止为塞专名插入无关段落。\n")
    # 字数硬约束：没有它时，模型会把【改写要求】的「删水段/25 字句/3 行段」整章执行，
    # 产出低于 apply_text_patch 的下限被整份拒绝（门禁 v7 四次全如此）→ 定点修白跑。
    words = count_words(content or "")
    floor = int(words * FIX_MIN_RATIO)
    floor_block = ""
    if floor:
        floor_block = (
            f"\n【字数硬约束·先看这条】改写后正文不得少于 {floor} 字（原文 {words} 字，"
            f"最多允许压缩 {round((1 - FIX_MIN_RATIO) * 100)}%）。「删水段」只许删与剧情无关的段落，"
            "且删掉多少就要用冲突/对白/动作/细节补足同等篇幅——**总字数不得下降**。"
            "若评审意见（如「篇幅偏长」）与本下限冲突，以本下限为准：压缩诉求请用「改写」"
            "（并句、去修饰、换更短的表达）满足，不靠删段。\n")


    return (
        "下面这一章要过番茄初审，评审器给出以下硬伤。请**只针对这些点改写**，"
        "保持人物名、事件顺序、已埋的伏笔完全不变，不要重写无关段落：\n"
        + floor_block
        + "\n".join(lines)
        + world_block
        + "\n\n【改写要求】首屏 300 字必须有主角在场、正在发生的冲突、至少一句对白；"
          "主角本章至少做出一次有代价的主动选择；对话占比提到 25%~45%；"
          "只删与剧情无关的水段（删多少就补多少，见上文【字数硬约束】）；句子尽量控制在 25 字内；段落不超过 3 行。\n"
          "**题材与世界观必须与本作一致**：不得出现现代词汇、不得更换主角、不得引入新故事线。\n"
          "**只输出改写后的正文**：不要任何解释、说明、前言、字数报告或操作描述（写进正文即判废）。\n"
        + "\n\n" + content
    )


# ------------------------------------------------------------
# CLI
# ------------------------------------------------------------
def main():
    import argparse
    p = argparse.ArgumentParser(description="番茄过审评审器（本地零成本）")
    p.add_argument("novel_txt")
    p.add_argument("--genre", default="")
    p.add_argument("--protagonist", default="", help="大纲定的主角名（用于查主角漂移）")
    p.add_argument("--outline-json", default="",
                   help="大纲 JSON 文件（用其 world 字段查世界观一致性）")
    p.add_argument("--json", action="store_true")
    a = p.parse_args()
    chs = split_chapters(a.novel_txt)
    if not chs:
        print("[ERROR] 未识别到章节（需要「第 N 章」标题行）")
        sys.exit(1)
    wt = ()
    if a.outline_json and os.path.exists(a.outline_json):
        try:
            raw = io.open(a.outline_json, encoding="utf-8").readline()
            obj = json.loads(raw)
            wt = extract_world_terms(obj.get("data", obj))
        except Exception:
            wt = ()
    res = review_book(chs, a.genre, a.protagonist, wt)
    if a.json:
        print(json.dumps(res, ensure_ascii=False, indent=2))
        return
    print(f"\n《{os.path.basename(a.novel_txt)}》 番茄过审评估卡（{len(chs)} 章）\n")
    print(f"  {'章':>3} {'字数':>6} {'分':>6}  {'对白':>5} {'水段':>6} {'套句/千':>7} {'主动性':>7}  问题")
    print("  " + "-" * 76)
    for r in res["chapters"]:
        m = r["metrics"]
        print(f"  {r['idx']:>3} {r['words']:>6} {r['score']:>6}  "
              f"{m['pace']['dialogue'] * 100:>4.0f}% {m['filler']:>5.1f}% {m['cliche']:>7.2f}"
              f" {m['agency']['ratio']:>7.2f}  {len(r['problems'])} 项")
        for pr in r["problems"]:
            print(f"        ↳ [{pr['action']}] {pr['type']}：{pr['msg']}")
        for h in r["redline"]["veto"]:
            print(f"        ☠ 红线（{h['category']}）「{h['word']}」 … {h['context']}")
    print("  " + "-" * 76)
    print(f"  均分 {res['avg_score']}（前 3 章 {res['first3_score']}）｜红线命中 {res['veto_count']} 处")
    if res.get("blockers"):
        print(f"  ⛔ 阻断项 {len(res['blockers'])} 章（不修完不给「可投」）：")
        for b in res["blockers"][:8]:
            print(f"      · {b}")
    print(f"  结论：{res['verdict']}\n")


if __name__ == "__main__":
    main()
