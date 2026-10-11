#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""质检指标 + 文本卫生层：爽点/异动/侧反密度、伏笔断供、AI 味深度、文风指纹、
钩子/开篇判定——纯本地计算，不触网、不调 LLM。

2026-10-10 从 generate_novel.py 拆出（同批还有 gen_llm）。词表/阈值一律取自
quality_rules_generated（rules/quality_rules.json 的生成物），本文件不写死词表。
单章质检 quality_check 与其定点修链留在 generate_novel（依赖户籍表文本块与
review_chapter/fix_prompt，搬走会成环）。

对外接口：调用方仍从 generate_novel 取同名转发。拆分红线同 novel_pipeline：
只降维护成本，不改对外契约，函数体逐字搬运。
"""
import os
import re
import sys

_real_print = print


def print(*args, **kwargs):
    kwargs.setdefault("flush", True)
    _real_print(*args, **kwargs)


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fanqie_review import count_words, dialogue_ratio  # noqa: E402,F401
from quality_rules_generated import (  # noqa: E402,F401
    AI_ADVERBS, BODY_REACTION_WORDS, HOOK_WORDS, NEGATION, OPENING_STRONG,
    OPENING_WEAK, POWER_SURGE_WORDS, SENTENCE_CONNECTORS, SIDE_REACTION_WORDS,
    THRILL_WORDS, TRIAD_HOOK_ONLY,
)


AI_CLICHE = ['嘴角', '唇角', '眼底', '眼神', '目光', '仿佛', '似乎', '宛如',
             '空气', '心跳', '深吸', '命运', '轨迹', '万语', '舒了一口',
             '微微上扬', '闪过一丝', '勾起一抹']


NEGATION = list(NEGATION)  # 值来自 rules/quality_rules.json 的生成物（勿在本文件再写词表）


OPENING_ACTION_WORDS = OPENING_STRONG + OPENING_WEAK


GENRE_THRILL_EXTRA = {
    "玄幻": [],
    "仙侠": [],
    "都市": ['翻身', '逆袭', '成交', '合同', '签约', '订单', '报表', '晋升通知',
             '董事会', '拿下项目', '赔偿', '解雇', '开除', '失业', '涨薪', '升职',
             '住进', '买车', '买房', '奢侈品', '被人围观', '经理', '总裁'],
    "都市异能": ['异能觉醒', '超能力', '念力', '控火', '控电', '隐身', '读心',
                '飞起来', '挡住子弹', '碾碎', '轰飞', '击退', '弹开', '挡住'],
    "科幻": ['曲速', '跃迁', '智械', '机甲', '能量核心', '歼星', '殖民舰',
             '星图', '超越', '破解', '代码', 'AI 觉醒', '算力'],
    "末世": ['进化', '异能', '晶核', '丧尸', '变异兽', '幸存者', '庇护所',
             '猎杀', '收割', '强化', '吞噬', '升级', '武器库', '清剿'],
    "游戏": ['首杀', '满级', '掉落', '神器', '装备', '副本首通', '全服', '公会',
             'PK', '团灭', '一波带走', 'MVP', '上分', '王者', '登录', '经验'],
    "悬疑": ['真凶', '反转', '证据', '真相', '破案', '抓捕', '结案', '指纹',
             '监控', '供认', '落网', '水落石出', '嫌疑人', '密室', '凶器'],
    "武侠": ['武功', '内力', '剑法', '掌法', '名震', '成名', '武林', '掌门',
             '秘籍', '神功', '快意恩仇', '切磋', '战', '破'],
    "历史": ['圣旨', '官拜', '封赏', '凯旋', '捷报', '升官', '权倾', '殿前',
             '大捷', '收复', '纳贡', '称臣', '赐婚'],
    "军事": ['击毙', '歼灭', '拿下', '突袭', '斩首', '缴获', '战利', '反杀',
             '突围', '胜利', '勋章', '一等功', '击落', '摧毁'],
    "体育": ['绝杀', '反超', '夺冠', '破纪录', '金牌', '决赛', '晋级', '逆转',
             '绝地', '爆冷', '教练', '首发', '战胜'],
}


GENRE_THRILL_ALL = {g: THRILL_WORDS + (GENRE_THRILL_EXTRA.get(g) or []) for g in GENRE_THRILL_EXTRA}


def thrill_per_thousand(text, genre=""):
    """爽点密度（每千字命中数）。网文参考线：>=1.5 合格，<0.5 过淡。
    genre 非空时叠加题材专属词表（都市/悬疑/末世等词表感知，避免题材误判）。"""
    if not text:
        return 0.0
    words_list = GENRE_THRILL_ALL.get(genre, THRILL_WORDS) if genre else THRILL_WORDS
    hits = sum(text.count(w) for w in words_list)
    words = count_words(text)
    return round(hits / words * 1000, 2) if words > 0 else 0.0


GENRE_SURGE_EXTRA = {
    "玄幻": [],
    "仙侠": [],
    "都市": ['心跳加速', '血压', '掌心出汗', '手指发抖', '头皮发麻', '背后发凉'],
    "都市异能": ['能量涌动', '蓝色电弧', '金色光晕', '念力波动', '身体变轻', '力量涌出'],
    "科幻": ['系统提示', '面板刷新', '数据跳动', '能量读数', '警报', '扫描'],
    "末世": ['晶核闪烁', '肉体强化', '骨骼作响', '血脉奔涌', '力量膨胀', '皮肤发紧'],
    "游戏": ['技能栏', '冷却结束', '血条', '蓝条', '装备发光', '暴击', '连击'],
    "悬疑": ['心跳漏拍', '瞳孔一缩', '汗毛竖起', '后颈发凉', '寒意', '鸡皮疙瘩'],
    "武侠": ['真气流转', '内力涌动', '气机', '丹田发热', '剑气', '血脉偾张'],
    "历史": ['手心发汗', '脊背发凉', '眼神一凛', '呼吸一窒', '跪'],
    "军事": ['雷达锁定', '警报响起', '肾上腺素', '手雷', '瞄准镜', '心跳加速'],
    "体育": ['观众沸腾', '计时器', '记分牌', '心跳如鼓', '肌肉紧绷', '观众席'],
}


GENRE_SURGE_ALL = {g: POWER_SURGE_WORDS + (GENRE_SURGE_EXTRA.get(g) or []) for g in GENRE_SURGE_EXTRA}


def surge_per_thousand(text, genre=""):
    """变强异动密度（每千字命中数）。玄幻文参考线：>=1.0 为含蓄变强流。
    genre 非空时叠加题材专属异动词（都市异能/末世/游戏等身体异动词表感知）。"""
    if not text:
        return 0.0
    words_list = GENRE_SURGE_ALL.get(genre, POWER_SURGE_WORDS) if genre else POWER_SURGE_WORDS
    hits = sum(text.count(w) for w in words_list)
    words = count_words(text)
    return round(hits / words * 1000, 2) if words > 0 else 0.0


def side_reaction_per_thousand(text):
    """侧面反响/震惊链密度（每千字命中数）。网文参考线：>=0.8 合格，<0.3 偏淡。"""
    if not text:
        return 0.0
    hits = sum(text.count(w) for w in SIDE_REACTION_WORDS)
    words = count_words(text)
    return round(hits / words * 1000, 2) if words > 0 else 0.0


def release_profile(text):
    """压抑释放结构（爽点落点）——先抑后扬是否成立。

    规则来源：FANQIE_SYSTEM_PROMPT 规则 27「爽点放在章内后半段：先压后扬，
    压抑蓄水不超过全章 60%，后半段瞬间打脸释放」。该规则此前**只有 prompt 承诺、
    没有任何检测器**（2026-09-28 补齐，与 Dart PipelineQa.releaseProfile 对齐）。

    只用基础 THRILL_WORDS 判落点（题材加成词仅 Python 侧存在，用它会破坏双端同口径）。
    判定（命中 n>=2 才有结构可言，n=0/1 由密度指标「爽点过淡」负责）：
    - none         : 无外显爽点命中（落点判定不适用）
    - single       : 仅 1 处命中（单点无结构，落点判定不适用）
    - late_start   : 压抑过长——首个爽点晚于全章 60%（慢热掉追读）
    - front_loaded : 前置泄洪——末个爽点仍在前半段，后半段零释放（后半章平铺）
    - ok           : 结构正常

    阈值校准：真实成书 156 章（tool/probe_release_profile.py 复跑可复现）——
    适用章 61（39%），late_start 11%、front_loaded 5%，信号存在且不构成大规模误报；
    按 STYLE_FP 同定位为「标记供人工复核」，note 级不阻断。
    """
    if not text:
        return {"verdict": "none", "hits": 0, "first": 0.0, "last": 0.0}
    denom = max(1, len(text))
    positions = []
    for w in THRILL_WORDS:
        start = 0
        while True:
            i = text.find(w, start)
            if i < 0:
                break
            positions.append(i)
            start = i + len(w)
    if not positions:
        return {"verdict": "none", "hits": 0, "first": 0.0, "last": 0.0}
    positions.sort()
    first = round(positions[0] / denom, 2)
    last = round(positions[-1] / denom, 2)
    n = len(positions)
    if n < 2:
        verdict = "single"
    elif first > 0.6:
        verdict = "late_start"
    elif last < 0.5:
        verdict = "front_loaded"
    else:
        verdict = "ok"
    return {"verdict": verdict, "hits": n, "first": first, "last": last}


def payoff_drought_zones(thrill_per_k, threshold=0.5, min_run=3,
                         side_per_k=None, side_threshold=0.3):
    """外显爽点断供带（连续 >=min_run 章无外显兑现的区段）。

    背景（2026-09-29 真实成书回测，14 本 156 章）：
    既有爽点闸门一律用「双低」判定（💥<0.5 **且** ✨<1.0 才算过淡），
    双通道设计本意是放过「含蓄变强流」，但实测 💥 通道**全书性枯竭**：
    14 本书 💥 中位数仅 0.18~0.79/千字（参考线 1.5 合格 / 1.0 及格），
    而 ✨ 含蓄异动稳定在 ~2.2/千字 —— ✨ 恒高分使「双低」几乎永不成立，
    于是「外显爽点长期断供」这一真正的追读杀手**没有任何检测器看得见**。
    对照证据：《碎脉铸仙录》33 章里 18 章连低、26/33 章落在 >=3 章连低带内；
    门禁 v7 终审官（LLM 通读）独立判出同一问题「金手指参与度低、爽点滞后、
    未体现书名提纯能力」——规则层漏检、LLM 层看见 = 典型「有指令无检测」缺口。

    与既有 _collapse_zones（双低塌陷区）**互补不重叠**：那个判「两通道皆枯」，
    这个专判「含蓄流把外显断供掩盖」。故只看 💥，不看 ✨。

    阈值标定（min_run=3）：1~2 章连低属正常节奏起伏（6/14 本书出现且质量正常，
    如 smoke_gate_v6 / fulltest_20260913 最长连低均为 2）；>=3 章才判断供带，
    实测命中 6/14 本（chief_test_v2 / full_imnovel / novel_10w /
    novel_10w_pipeline / smoke_gate_v2 / verify_12roles），健康小样
    short_sample / short_sample2 零命中，无误报。

    返回 [(起章位序, 止章位序, 章数)]。

    **side_per_k 逃生通道（2026-09-29 真机 A/B 实测后补）**：
    单看 💥 会**误伤写得不套话的好章节**。真机单发对照（同 goal、同写手链）拿到
    一段教科书级当众兑现——满堂哄笑 → 全场屏息 →「几乎所有人都看清了」→ 公开
    揭示——但 💥 命中 **0 个词**（💥=0.0），因为 THRILL_WORDS 是 96 词的**闭合
    套话表**，不写套话的模型恰好系统性绕开它（该样本 ✨ 命中 3 个、侧反命中
    「哗然」）。故凡侧面反响达标的章（在场者确有反应，读者可感知兑现）一律不判
    断供。真实成书回测：该通道救回 10 章（verify_12roles 5→0、碎脉铸仙录
    24→19），且被救回的章经人工核对确有外显反应（惊呼/脸色铁青/哗然），非漏放
    真断供。side_per_k=None 时保持旧口径（只看 💥），旧调用零变化。
    """
    zones = []
    start = None
    for i, t in enumerate(thrill_per_k):
        flat = t < threshold
        if flat and side_per_k is not None and i < len(side_per_k):
            # 侧面反响达标 = 在场者确有反应 = 外显兑现已送达读者，不算断供
            flat = side_per_k[i] < side_threshold
        if flat:
            if start is None:
                start = i
        elif start is not None:
            if i - start >= min_run:
                zones.append((start, i - 1, i - start))
            start = None
    if start is not None and len(thrill_per_k) - start >= min_run:
        zones.append((start, len(thrill_per_k) - 1,
                      len(thrill_per_k) - start))
    return zones


def payoff_drought_ev_fragment(thrill_per_k, threshold=0.5, min_run=3,
                              side_per_k=None, side_threshold=0.3):
    """评审证据串：外显爽点断供带（注入 qa_ev，与落点、三件套同款）。

    评审的「爽点与期待感」维度此前只能看到本章 💥/✨ 两个数，含蓄流章节
    单看本章并不异常（✨ 高），只有**跨章连低**才暴露断供——不给连低证据，
    评审就会把「18 章没有一次外显爽点」判成节奏紧凑（与 v7 终审 69 分同源）。

    side_per_k 传入时启用侧面反响逃生通道（与 payoff_drought_zones 同口径），
    避免把「不套话但确有在场者反应」的好章误判为断供。
    """
    zones = payoff_drought_zones(thrill_per_k, threshold, min_run,
                                 side_per_k, side_threshold)
    if not zones:
        return ""
    total = sum(z[2] for z in zones)
    spans = "、".join(f"第{a+1}-{b+1}章({n}章)" for a, b, n in zones[:4])
    return (f"外显爽点断供：连续 {total} 章 💥<{threshold}/千字且无在场者反应（{spans}）"
            f"——含蓄异动不能替代外显兑现，此区间「期待感」维度不应高于 40 分")


def release_ev_fragment(text):
    """评审证据串：爽点落点（注入 quality_review_prompt 的 qa_ev，评审带数打分）。"""
    p = release_profile(text)
    v = p["verdict"]
    if v == "none":
        return "爽点落点：无外显爽点命中（落点不适用，按密度指标判 thrill）"
    if v == "single":
        return (f"爽点落点：仅 {p['hits']} 处命中于 {p['first']:.0%} 处"
                "（单点无结构，落点不适用）")
    if v == "ok":
        return (f"爽点落点：首现 {p['first']:.0%}、末现 {p['last']:.0%}"
                "（先抑后扬结构正常 ✅）")
    if v == "late_start":
        return (f"爽点落点：首现 {p['first']:.0%} ⚠ 压抑超过全章 60% 才首次释放"
                "（先抑后扬失衡，rhythm 维度不应高于 60 分）")
    return (f"爽点落点：末现 {p['last']:.0%} ⚠ 爽点全在前半段、后半段零释放"
            "（前置泄洪，rhythm 维度不应高于 60 分）")


AI_ADVERBS = AI_ADVERBS = list(AI_ADVERBS)  # 值来自 rules/quality_rules.json 的生成物（勿在本文件再写词表）


SENTENCE_CONNECTORS = SENTENCE_CONNECTORS = list(SENTENCE_CONNECTORS)  # 值来自 rules/quality_rules.json 的生成物（勿在本文件再写词表）


METAPHOR_PAT = re.compile(
    r"像[^。！？！?，\n]{1,18}(?:一样|似的|般)|跟[^。！？！?，\n]{1,18}(?:一样|似的)"
    r"|如同[^。！？！?，\n]{1,14}(?:一样|一般|似的)|仿佛|宛如|好似|犹如|恰似")


BODY_REACTION_WORDS = BODY_REACTION_WORDS = list(BODY_REACTION_WORDS)  # 值来自 rules/quality_rules.json 的生成物（勿在本文件再写词表）


SINGLE_PARA_MAX_CHARS = 14


def _style_fingerprint_metrics(text):
    """句式层 AI 指纹三项：比喻密度 / 单句成段占比 / 身体反应密度（返回值与超标判定分离）。"""
    if not text:
        return {'metaphor_density': 0.0, 'single_para_rate': 0.0, 'body_reaction_density': 0.0}
    words = count_words(text)
    # 1) 比喻密度（每千字）
    metaphor_hits = len(METAPHOR_PAT.findall(text))
    metaphor_density = round(metaphor_hits / words * 1000, 2) if words else 0.0
    # 2) 单句成段占比（≤14 字短段 / 非空段落）
    paras = [p.strip() for p in text.split("\n") if p.strip()]
    single_para_rate = (round(sum(1 for p in paras if count_words(p) <= SINGLE_PARA_MAX_CHARS)
                              / len(paras) * 100, 1)) if paras else 0.0
    # 3) 身体反应密度（每千字）
    body_hits = sum(text.count(w) for w in BODY_REACTION_WORDS)
    body_reaction_density = round(body_hits / words * 1000, 2) if words else 0.0
    return {'metaphor_density': metaphor_density, 'single_para_rate': single_para_rate,
            'body_reaction_density': body_reaction_density}


STYLE_FP_LIMITS = {'metaphor_density': 2.0, 'single_para_rate': 30.0, 'body_reaction_density': 1.5}


def _split_sentences(text):
    import re as _re
    return [s.strip() for s in _re.split(r'[。！？!?…]+', text) if s.strip()]


def deep_ai_metrics(text):
    """AI 味深度指标：句长CV / 的字密度 / 叠词密度 / 句首连接词率
    + 句式指纹三项（比喻密度/单句成段占比/身体反应密度，2026-09-12 补）
    + level(0~5)：原四项各超标 +1；句式指纹三项中 ≥2 项超标再 +1（合并计 1 项，口径变化最小）。"""
    if not text:
        return {'sentence_cv': 0.0, 'de_density': 0.0,
                'adverb_density': 0.0, 'connector_rate': 0.0,
                'metaphor_density': 0.0, 'single_para_rate': 0.0, 'body_reaction_density': 0.0,
                'level': 0}
    words = count_words(text)

    # 1) 句长变异系数
    lens = [count_words(s) for s in _split_sentences(text)]
    lens = [n for n in lens if n > 0]
    cv = 0.0
    if len(lens) >= 3:
        mean = sum(lens) / len(lens)
        variance = sum((n - mean) ** 2 for n in lens) / len(lens)
        sd = variance ** 0.5
        cv = round(sd / mean, 2) if mean > 0 else 0.0

    # 2) 「的」字密度
    de_density = round(text.count('的') / words * 100, 2) if words else 0.0

    # 3) 叠词修饰密度（每千字）
    adv_hits = sum(text.count(w) for w in AI_ADVERBS)
    adverb_density = round(adv_hits / words * 1000, 2) if words else 0.0

    # 4) 句首连接词比例
    sents = _split_sentences(text)
    conn_hits = 0
    for s in sents:
        head = s[:4]
        if any(head.startswith(c) for c in SENTENCE_CONNECTORS):
            conn_hits += 1
    connector_rate = round(conn_hits / len(sents), 2) if sents else 0.0

    # 5) 句式指纹三项（≥2/3 超标 → 记 1 项超标，不逐项累加以免 level 失真）
    fp = _style_fingerprint_metrics(text)
    fp_over = sum(1 for k, lim in STYLE_FP_LIMITS.items() if fp[k] > lim)

    level = (1 if cv < 0.55 else 0) + (1 if de_density > 4.0 else 0) + \
            (1 if adverb_density > 2.0 else 0) + (1 if connector_rate > 0.15 else 0) + \
            (1 if fp_over >= 2 else 0)
    out = {'sentence_cv': cv, 'de_density': de_density,
           'adverb_density': adverb_density, 'connector_rate': connector_rate,
           'level': level}
    out.update(fp)
    return out


def style_fingerprint(text, source=""):
    """文风指纹（P1-1 文风仿写第一阶段）：把参考文的可统计风格压成九项分布指标。

    全部复用 deep_ai_metrics / dialogue_ratio 既有口径（不另起标准），
    供 `novel_pipeline --style-ref` 注入写手 prompt 与收敛度量
    （fingerprint_distance）。返回值只含分布数值，**不含任何可照抄内容**。
    """
    zero = {'source': source, 'words': 0, 'sent_len_mean': 0.0,
            'sent_len_cv': 0.0, 'dialogue_ratio': 0.0, 'para_len_mean': 0.0,
            'single_para_rate': 0.0, 'de_density': 0.0,
            'adverb_density': 0.0, 'connector_rate': 0.0,
            'metaphor_density': 0.0}
    if not text:
        return zero
    deep = deep_ai_metrics(text)
    lens = [n for n in (count_words(s) for s in _split_sentences(text)) if n > 0]
    para_lens = [n for n in (count_words(p)
                             for p in re.split(r"\n\s*\n", text)) if n > 0]
    if not lens or not para_lens:
        return zero
    return {
        'source': source,
        'words': count_words(text),
        'sent_len_mean': round(sum(lens) / len(lens), 1),
        'sent_len_cv': deep['sentence_cv'],
        'dialogue_ratio': dialogue_ratio(text),
        'para_len_mean': round(sum(para_lens) / len(para_lens), 1),
        'single_para_rate': deep['single_para_rate'],
        'de_density': deep['de_density'],
        'adverb_density': deep['adverb_density'],
        'connector_rate': deep['connector_rate'],
        'metaphor_density': deep['metaphor_density'],
    }


def style_fingerprint_block(fp):
    """把文风指纹渲染成写手场景 prompt 注入块（学分布，不抄内容）。

    数字目标外必须带「向分布靠拢」的可执行翻译（长短句错落、对白密度、
    段落呼吸），否则模型面对裸数字无从下手；禁抄条款防文风仿写变成抄袭。
    """
    if not fp or not fp.get('words'):
        return ""
    return (
        "\n【目标文风指纹（参考《{src}》，共 {w} 字）——只学分布与节奏，"
        "禁止照抄其句子、情节与人名】\n"
        "句长：均值 {sl} 字、变异系数 {cv}（长短句错落，忌句长均匀——"
        "紧张处压短句，舒缓处放长句）\n"
        "结构：对白占比 {dr:.0%}｜段落均长 {pl} 字｜单句成段 {sp:.0f}%"
        "（段落呼吸与参考文一致）\n"
        "用词：的字密度 {de:.1f}%｜叠词 {ad}/千字｜句首连接词 {co:.0%}｜"
        "比喻 {me}/千字\n"
        "写本章时让以上各项向参考文靠拢，其余仍按写作准则执行；"
        "与准则冲突时以准则为准（如对白占比 25%~45%、章末钩子硬门槛），\n"
        "文风分布只在准则允许的范围内调节。\n"
    ).format(src=fp.get('source', '参考文'), w=fp['words'],
             sl=fp['sent_len_mean'], cv=fp['sent_len_cv'],
             dr=fp['dialogue_ratio'], pl=fp['para_len_mean'],
             sp=fp['single_para_rate'], de=fp['de_density'],
             ad=fp['adverb_density'], co=fp['connector_rate'],
             me=fp['metaphor_density'])


def fingerprint_distance(fp_a, fp_b):
    """两份文风指纹的归一化距离（0=同分布，越大差异越大）。

    每项 |a-b|/max(|a|,|b|) 后取均值——比值式让量纲自归一，无需逐项定权；
    双零项记 0 差异（分母取 1e-9 防除零）。用于真机跑后验收「新章是否向
    参考文收敛」（--style-ref 模式逐章打印）。
    """
    keys = ('sent_len_mean', 'sent_len_cv', 'dialogue_ratio',
            'para_len_mean', 'single_para_rate', 'de_density',
            'adverb_density', 'connector_rate', 'metaphor_density')
    diffs = []
    for k in keys:
        a = float(fp_a.get(k, 0.0))
        b = float(fp_b.get(k, 0.0))
        diffs.append(abs(a - b) / max(abs(a), abs(b), 1e-9))
    return round(sum(diffs) / len(diffs), 3)


def load_style_block(path):
    """读参考文并返回 (指纹注入块, 指纹 dict)；未配置/失败/空文返回 ("", None)。

    novel_pipeline 与 generate_novel 两个入口共用（打印同一套 [文风] 行，
    单一实现防止两端提取逻辑漂移）。
    """
    if not path:
        return "", None
    try:
        with open(path, encoding="utf-8") as sf:
            fp = style_fingerprint(sf.read(),
                                   source=os.path.basename(path))
    except OSError as e:
        print(f"[文风] --style-ref 读取失败（{e}），本轮不注入")
        return "", None
    block = style_fingerprint_block(fp)
    if not block:
        print("[文风] 参考文为空/过短，未提取到指纹，本轮不注入")
        return "", None
    print(f"[文风] 参考文指纹已提取（{fp['words']} 字）：句长均值 "
          f"{fp['sent_len_mean']}｜对白 {fp['dialogue_ratio']:.0%}｜"
          f"段落均长 {fp['para_len_mean']} → 注入写手场景 prompt")
    return block, fp


def style_ev_fragment(ref_fp, text):
    """评审证据串：本章文风与参考文的距离分解（REF_FP 模式注入 qa_ev）。

    无参考（ref_fp 为空）返回空串——与钩子/落点/收尾证据并列，评审的
    rhythm 维度拿它对照句段呼吸与对白密度，不空口评「节奏」。
    """
    if not ref_fp:
        return ""
    fp = style_fingerprint(text)
    return (f"文风：与参考文距离 {fingerprint_distance(ref_fp, fp)}"
            f"（句长均值 {fp['sent_len_mean']} vs 参考 {ref_fp['sent_len_mean']}"
            f"｜对白 {fp['dialogue_ratio']:.0%} vs {ref_fp['dialogue_ratio']:.0%}"
            f"｜段落均长 {fp['para_len_mean']} vs {ref_fp['para_len_mean']}）"
            "——供 rhythm 维度对照句段呼吸与对白密度")


def has_ending_hook(text):
    """章末钩子检测：结尾 200 字内是否有未落地悬念信号。

    三件套不算钩（FANQIE 规则 20/10）：尾部钩子词命中若**全是**三件套词
    （发烫/醒了过来），且末 60 字无问号/省略号悬念 → 判无钩——此前三件套
    收尾反而被本检测判「有钩」（真实成书 116 章实测 93% 反向奖励，历史事故
    「52% 章节落在发光物件+苏醒」即此形态）。回测：仅 1/116 章因此翻转，
    其余三件套章尾部另有真实钩子信号，不受影响。
    """
    if not text:
        return False
    tail = text[-200:] if len(text) > 200 else text
    last60 = tail[-60:] if len(tail) > 60 else tail
    if '？' in last60 or '?' in last60 or '……' in last60:
        return True
    # 存在任一**非三件套**尾部钩子词才算钩；全是三件套词（发烫/醒了过来）
    # → 不采信（检测矛盾修正）；无任何命中 → 无钩。
    return any(w not in TRIAD_HOOK_ONLY
               for w in HOOK_WORDS if w in tail)


def has_quick_opening(text):
    """开场节奏检测（黄金三章）：前 300 字是否进入变故/冲突。

    强信号（穿越/醒来/废物/耳光…）1 个即达标；弱信号（单字动词）需 >=2 个，
    避免比喻语境（"像纸一样一碰就碎"）误报。
    """
    if not text:
        return False
    head = text[:300]
    if any(w in head for w in OPENING_STRONG):
        return True
    weak_hits = sum(1 for w in OPENING_WEAK if w in head)
    return weak_hits >= 2
