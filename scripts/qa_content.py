#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语义硬伤检测 · 关卡3（题材内容塌陷：标题-内容脱节）。

2026-10-10 从 qa_semantic_check.py 拆出。纯本地规则，不触网、不调 LLM。

对外接口：调用方仍从 qa_semantic_check 取同名转发。拆分红线：只降维护成本，
不改对外契约；函数体逐字搬运，未改写。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


GENRE_CONTENT_WORDS = {
    "玄幻": ['灵气', '修为', '宗门', '丹田', '境界', '灵石', '功法', '真气',
             '经脉', '玉简', '长老', '弟子', '筑基', '炼气', '灵田', '妖兽',
             '法术', '储物', '外门', '内门', '灵脉', '洞府'],
    "仙侠": ['仙门', '修士', '灵根', '金丹', '元婴', '法宝', '飞升', '渡劫',
             '道法', '仙缘', '宗门', '丹药', '灵草', '剑诀'],
    "都市": ['公司', '合同', '项目', '经理', '写字楼', '工资', '客户', '加班',
             '手机', '地铁', '会议', '老板', '总裁', '房产'],
    "都市异能": ['异能', '觉醒', '超能力', '念力', '电弧', '控火', '控电',
                 '读心', '隐身', '能力者'],
    "科幻": ['飞船', '星舰', '机甲', '芯片', '殖民', '太空', '辐射', '克隆',
             '量子', '终端', '数据库', '曲速', '跃迁', '智械', '星图', '舱',
             '废铁', '零件', '齿轮', '机关', '锁芯', '铜锁', '钥匙', '扳手',
             '机械', '管道', '废土', '拾荒', '改装', '图纸', '金属', '仪表',
             '电缆', '水井', '井口', '井底', '锁孔'],
    "游戏": ['副本', 'BOSS', '装备', '等级', '经验', '公会', '任务', '技能',
             '登录', '全服', '掉落', '满级', '地图', 'NPC', '血条'],
    "悬疑": ['案子', '凶手', '证据', '警方', '侦查', '线索', '尸体', '现场',
             '嫌疑', '监控', '刑警', '案发', '死者', '指纹', '口供'],
    "武侠": ['武功', '内力', '剑法', '掌法', '江湖', '门派', '掌门', '秘籍',
             '轻功', '镖局', '大侠', '切磋', '武林', '招式', '穴道',
             '剑', '刀', '断剑', '短刀', '长剑', '武馆', '比武', '拜师',
             '师父', '仇怨', '侠'],
    "历史": ['皇上', '衙门', '科举', '圣旨', '朝廷', '大人', '奏折', '宫殿',
             '兵部', '流官', '革职', '贡品', '殿试', '太子'],
    "军事": ['部队', '连长', '枪', '阵地', '侦察', '参谋', '作战', '行军',
             '哨所', '军牌', '番号', '弹药', '战友', '营房', '紧急集合', '突围'],
    "体育": ['训练', '球场', '赛场', '比赛', '联赛', '教练', '队员', '队长',
             '体能', '场馆', '热身', '战术', '选手', '跑道', '操场', '篮球',
             '足球', '排球', '田径', '拳台', '散打', '试训', '运动会', '集训'],
}


CONTENT_MIN_CHARS = 800       # 短于该字数的章不判


CONTENT_SUSPECT_RATIO = 0.15  # 密度 < 全书中位数 × 0.15 → 疑似


CONTENT_SUSPECT_CAP = 0.30    # 且密度绝对值 < 0.3/千字 → 疑似


def _title_keywords(ch_title):
    """从「第 N 章  XXX」剥出标题实词段（>=2 字汉字段）。"""
    t = re.sub(r"^\s*第\s*\d+\s*章\s*", "", ch_title or "").strip()
    segs = re.findall(r"[\u4e00-\u9fff]{2,}", t)
    return segs or ([t] if t else [])


def detect_content_drift(chapters, genre=None):
    """关卡 3：题材内容塌陷 + 标题词命中参考。返回 dict。"""
    import statistics
    used_auto = False
    if not genre or genre not in GENRE_CONTENT_WORDS:
        # 自动探测：各题材全书章密度中位数最高者
        best, best_med = None, -1.0
        for g, words in GENRE_CONTENT_WORDS.items():
            dens = []
            for _i, _t, c in chapters:
                kk = max(len(c), 1) / 1000
                dens.append(sum(c.count(w) for w in words) / kk)
            m = statistics.median(dens) if dens else 0.0
            if m > best_med:
                best, best_med = g, m
        genre, used_auto = best, True

    words = GENRE_CONTENT_WORDS[genre]
    per_ch = []
    for idx, title, content in chapters:
        k = max(len(content), 1) / 1000
        hits = sum(content.count(w) for w in words)
        kws = _title_keywords(title)
        per_ch.append({
            "idx": idx, "title": title, "chars": len(content),
            "hits": hits, "density": round(hits / k, 2),
            "title_words": kws,
            "title_hit": any(w in content for w in kws),
        })

    dens = [p["density"] for p in per_ch if p["chars"] >= CONTENT_MIN_CHARS]
    med = statistics.median(dens) if dens else 0.0

    alerts = []
    for p in per_ch:
        if p["chars"] < CONTENT_MIN_CHARS:
            continue
        level = None
        if p["hits"] == 0:
            level = "high" if not p["title_hit"] else "medium"
        elif p["density"] < med * CONTENT_SUSPECT_RATIO and \
                p["density"] < CONTENT_SUSPECT_CAP:
            level = "suspect"
        if level:
            alerts.append({
                "idx": p["idx"], "title": p["title"],
                "hits": p["hits"], "density": p["density"],
                "title_words": p["title_words"],
                "title_hit": p["title_hit"], "level": level,
            })
    return {
        "genre": genre, "genre_auto": used_auto,
        "median_density": round(med, 2),
        "per_chapter": per_ch, "alerts": alerts,
    }
