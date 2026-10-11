#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语义硬伤检测 · 关卡2（主角称谓漂移）+ 候选名发现/聚类。

2026-10-10 从 qa_semantic_check.py 拆出。纯本地规则，不触网、不调 LLM。

对外接口：调用方仍从 qa_semantic_check 取同名转发。拆分红线：只降维护成本，
不改对外契约；函数体逐字搬运，未改写。
"""
import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


SURNAMES = (
    "王李张刘陈杨黄赵吴周徐孙马朱胡郭何林高罗郑梁谢宋唐许韩冯邓曹彭曾肖田"
    "董袁潘蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹"
    "孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤萧穆"
    # 网文常用姓补充（裴照/晏无咎/霍刃/郗砚/季渊/温衡等真实主角教训）
    "裴晏郗霍祝左关岑屈柳管盛凌纪庞颜梅童骆樊虞柯房解宗宣单洪包邢荣翁"
    "惠甄封储井段富巫焦谷侯尚农柴瞿阎充茹习宦艾容古易廖居衡耿匡"
    "文寇欧沃越隆师巩聂晁敖融冷辛简饶空鞠须丰巢蒯查荆游竺权桓南宫"
)


VERB_CHARS = (
    "站坐走跑蹲跳转退凑摸拍推拉扯指攥握拎提压按咬嚼吞咽吐咳喘瞅瞪瞄看望盯"
    "听闻嗅觉知想念记悟懂问说答讲念诵读骂吼喊嚷道言点摇抬低弯屈咧抿眨愣怔"
    "呆开闭回侧摆挥踢踹蹬踩迈跨撑爬翻滚挪移靠倚来去到从向朝对跟与和把将给"
    "让使是被那这又便就都还也才刚正要会能可"
)


STOP_NAMES = {
    "马上", "东西", "金石", "江水", "河水", "海水", "井水",
    "江南", "江北", "河南", "河北", "湖南", "湖北", "山东", "山西",
    "广东", "广西", "王子", "天子", "君子", "夫人", "老子", "孙子",
    "大王", "大人", "大方", "平时", "平方", "方正", "北方", "南方",
    "东方", "西方", "下手", "下水", "上山", "下山", "上火",
    "方向", "方式", "方法", "方剂", "药方", "丹方", "方才",
    "步子", "步都", "脚下", "手下",
}


OBJ_SUFFIX = set(
    "罐坛壶瓶桶锅碗瓢盆盖钉绳链环圈球油盐酱醋茶米面肉菜树木桥船车"
    "门窗墙砖瓦土坑沟渠河湖海丸散膏丹碟杯盘盏筷勺叉铲锄犁耙鞘托柄"
    "棍棒弓弦箭矢甲盔靴帽被褥枕席帘布帛绢纱绸缎锭两珠宝货财粮谷豆"
    "麦稻饭粥羹酒向村寨镇城楼台殿阁塔坟墓碑庙寺观庵井刀柴家"
    "底边口沿台旁里外面中前后人上下阶缝子"
    "尊父兄傅长叔伯婶姑姨舅嫂爷奶爹娘姐妹弟徒孙仙圣者翁婆"
    "肩手腕臂腿脚腰背胸口脸头目嘴鼻耳板壁"
)


PLACEHOLDER_RES = [
    (re.compile(r"([" + SURNAMES + r"])某"), "{x}某"),
    (re.compile(r"姓([" + SURNAMES + r"])的"), "姓{x}的"),
    (re.compile(r"([" + SURNAMES + r"])(小子|丫头|老头|姑娘|老太|婆姨)"), "{x}{suffix}"),
]


NICKNAME_RES = [
    (re.compile(r"[老小阿]([" + SURNAMES + r"])(?![\u4e00-\u9fff])"), "昵·{x}"),
]


PRON_SUFFIX = set("你我他她它谁啥什不没得了个之乎者也挺更最太")


MIN_CAND_FREQ = 2        # 候选名至少出现次数（动作验证命中）


MIN_CLUSTER_FREQ = 8     # 参与主角级区间分析的簇最小频次


MIN_MEMBER_FREQ = 5      # 主角级簇必须有高频代表名（防"田垄/石室"类


SPAN_OVERLAP_ALERT = 0.15  # 主角级簇区间重叠率低于此值 → 报警


def discover_names(text):
    """从全书文本发现候选人名。返回 (Counter{名:次数}, {名: 首现 offset}, {名: 末现 offset})。

    核心策略：正向上下文驱动（名 + 动作/说话动词），不裸扫姓名组合，
    从源头压低"木头/马上"类词组误报。
    """
    cands = Counter()
    first_offset = {}
    last_offset = {}

    def add(name, pos):
        cands[name] += 1
        if name not in first_offset:
            first_offset[name] = pos
        last_offset[name] = pos

    # 裸名 + 动作验证：姓 + 1~2 字，懒惰匹配 + 回溯
    pat_bare = re.compile(
        r"([" + SURNAMES + r"])([\u4e00-\u9fff]{1,2}?)((?=[" + VERB_CHARS + r"]))"
    )
    for m in pat_bare.finditer(text):
        name = m.group(1) + m.group(2)
        if name in STOP_NAMES:
            continue
        if len(name) >= 2 and name[1] in OBJ_SUFFIX:
            continue  # 器物/地名词组（陶罐/方向/王村）
        if len(name) >= 2 and name[1] in PRON_SUFFIX:
            continue  # 代词词组（连你/像他）
        add(name, m.start())

    for pat, tpl in list(PLACEHOLDER_RES) + list(NICKNAME_RES):
        for m in pat.finditer(text):
            name = tpl.format(x=m.group(1), suffix=m.group(2) if m.lastindex and m.lastindex >= 2 else "")
            add(name, m.start())

    # 长名归并：懒惰+回溯会产生「裴照没/裴照收」类子串候选——
    # 若去掉尾字的短名存在且频次 >= 长名，则长名并入短名
    merged = Counter()
    merged_first, merged_last = {}, {}
    for name, cnt in cands.items():
        if len(name) >= 3 and name[:-1] in cands and cands[name[:-1]] >= cnt:
            short = name[:-1]
            merged[short] += cnt
            merged_first[short] = min(merged_first.get(short, first_offset.get(short, 0)),
                                      first_offset.get(name, first_offset.get(short, 0)))
            merged_last[short] = max(merged_last.get(short, last_offset.get(short, 0)),
                                     last_offset.get(name, last_offset.get(short, 0)))
        else:
            merged[name] += cnt
            merged_first[name] = first_offset.get(name, 0)
            merged_last[name] = last_offset.get(name, 0)
    return merged, merged_first, merged_last


def cluster_names(cands, first_offset, last_offset):
    """按姓氏聚簇。返回 {簇姓: {total, names, first, last}}，按频次降序。"""
    clusters = {}
    for name, cnt in cands.items():
        if name.startswith("姓"):
            key = name[1]
        elif "·" in name:
            key = name.split("·")[-1]
        elif name.endswith(("某", "小子", "丫头", "老头", "姑娘", "老太", "婆姨")):
            key = name[0]
        else:
            key = name[0]
        c = clusters.setdefault(key, {"total": 0, "names": Counter(),
                                      "first": first_offset.get(name, 0),
                                      "last": last_offset.get(name, 0)})
        c["total"] += cnt
        c["names"][name] += cnt
        c["first"] = min(c["first"], first_offset.get(name, 0))
        c["last"] = max(c["last"], last_offset.get(name, 0))
    return dict(sorted(clusters.items(), key=lambda kv: -kv[1]["total"]))


def detect_name_drift(chapters, expected_protagonist=None, min_cluster=MIN_CLUSTER_FREQ):
    """检测主角称谓漂移。返回 dict（alerts / placeholder / clusters / per_chapter）。

    三条信号：
      S1 占位称呼统计（X某/姓X的/X小子…出现即列，💡 提示级）
      S2 主角级簇区间分析（频次 >=min_cluster 的簇两两重叠率 <15% → ⚠）
      S3 每章活跃簇分布表（人读）
    """
    # 全书文本 + 每章文本的 offset 边界
    full_parts = []
    chapter_ranges = []  # (idx, start_offset, end_offset)
    pos = 0
    for idx, _t, content in chapters:
        full_parts.append(content)
        chapter_ranges.append((idx, pos, pos + len(content)))
        pos += len(content)
    text = "\n".join(full_parts)

    cands, first_offset, last_offset = discover_names(text)
    clusters = cluster_names(cands, first_offset, last_offset)

    # S1 占位称呼（只收真占位：X某/姓X的/X小子…；昵称"昵·X"不算）
    # 簇级合计 >=2 才提示——单次"姓赵的"属长书常见路人群像，无报警价值
    placeholders = []
    ph_by_cluster = {}
    for name, cnt in cands.most_common():
        if name.endswith("某") or name.startswith("姓") or \
           name.endswith(("小子", "丫头", "老头", "姑娘", "老太", "婆姨")):
            key = name[1] if name.startswith("姓") else name[0]
            ph_by_cluster.setdefault(key, {"count": 0, "last_offset": 0,
                                           "names": []})
            ph_by_cluster[key]["count"] += cnt
            ph_by_cluster[key]["last_offset"] = max(
                ph_by_cluster[key]["last_offset"], last_offset.get(name, 0))
            ph_by_cluster[key]["names"].append(f"{name}×{cnt}")
    for key, info in ph_by_cluster.items():
        if info["count"] >= 2:
            placeholders.append({"cluster": key, "count": info["count"],
                                 "last_offset": info["last_offset"],
                                 "names": info["names"]})
    placeholders.sort(key=lambda p: -p["count"])

    # S2 主角级簇区间分析（区间 = 全簇成员真实首现~末现范围）
    # 前置：只对「主角级」簇（章覆盖率 >=0.3）做两两比较——
    # 两个仅在少数章活动的配角区间不重叠是正常现象，不构成换名警报
    total_len = max(len(text), 1)
    n_chapters = max(len(chapter_ranges), 1)
    cluster_spans = {}
    for key, info in clusters.items():
        if info["total"] < min_cluster:
            continue
        if max(info["names"].values()) < MIN_MEMBER_FREQ:
            continue  # 全碎片词组簇（田垄/石室…），非人名
        member_names = [n for n in info["names"] if n in last_offset]
        ch_hit = set()
        for idx, start, end in chapter_ranges:
            if any(text.find(n, start, end) >= 0 for n in member_names):
                ch_hit.add(idx)
        coverage = len(ch_hit) / n_chapters
        cluster_spans[key] = {
            "total": info["total"],
            "first": info["first"],
            "span": (info["first"], info["last"]),
            "coverage": round(coverage, 2),
            "names": dict(info["names"].most_common(5)),
        }
    span_alerts = []
    # 主角级 = 频次 top2（主角 + 头号配角）：两个小配角区间不重叠是正常现象，
    # 只对 top2 做两两比较——3 章小样里配角簇覆盖 1/3 章也能过 coverage 门槛，
    # 不收紧会误报（《焚骨逆天诀》v3 事故产物的陈默/周成属真换名，频次恰为 top2）
    cand_keys = [k for k, v in cluster_spans.items() if v["coverage"] >= 0.3]
    cand_keys = sorted(cand_keys, key=lambda k: -cluster_spans[k]["total"])[:2]
    for i in range(len(cand_keys)):
        for j in range(i + 1, len(cand_keys)):
            a, b = cluster_spans[cand_keys[i]], cluster_spans[cand_keys[j]]
            ov_start = max(a["span"][0], b["span"][0])
            ov_end = min(a["span"][1], b["span"][1])
            overlap = max(0, ov_end - ov_start)
            shorter = min(a["span"][1] - a["span"][0], b["span"][1] - b["span"][0]) or 1
            ratio = overlap / shorter
            if ratio < SPAN_OVERLAP_ALERT:
                span_alerts.append({
                    "cluster_a": cand_keys[i], "cluster_b": cand_keys[j],
                    "overlap_ratio": round(ratio, 2),
                    "span_a": [round(a["span"][0] / total_len, 2), round(a["span"][1] / total_len, 2)],
                    "span_b": [round(b["span"][0] / total_len, 2), round(b["span"][1] / total_len, 2)],
                })

    # S2' 占位称呼 → 裸名簇接管信号（《铁掌破风》事故形态：
    #  前半「苏小子/姓苏的」，占位称呼消失后高频裸名簇「裴照」接管主角位。
    #  只判 top1 主导簇——配角出场晚于占位称呼消失不构成"接管"）
    takeover_alerts = []
    if placeholders:
        ph_last = max(p["last_offset"] for p in placeholders)
        top_clusters = [c for c in clusters.values()
                        if c["total"] >= min_cluster
                        and max(c["names"].values()) >= MIN_MEMBER_FREQ]
        if top_clusters:
            chief = max(top_clusters, key=lambda c: c["total"])
            if chief["first"] > ph_last:
                takeover_alerts.append({
                    "placeholder_last_ratio": round(ph_last / total_len, 2),
                    "cluster": next(k for k, v in clusters.items() if v is chief),
                    "cluster_total": chief["total"],
                    "cluster_first_ratio": round(chief["first"] / total_len, 2),
                })

    # S3 每章活跃簇
    per_chapter = []
    for idx, start, end in chapter_ranges:
        ch_text = text[start:end]
        ch_cands, ch_first, ch_last = discover_names(ch_text)
        ch_clusters = cluster_names(ch_cands, ch_first, ch_last)
        top = [(k, v["total"]) for k, v in
               sorted(ch_clusters.items(), key=lambda kv: -kv[1]["total"])[:5]]
        per_chapter.append({"idx": idx, "top_clusters": top})

    # 置信度合成
    confidence = "none"
    if span_alerts or takeover_alerts:
        confidence = "high" if placeholders else "medium"

    # 预期主角校验
    expected_info = None
    if expected_protagonist:
        exp_key = expected_protagonist[0]
        exp_total = clusters.get(exp_key, {}).get("total", 0)
        rival = [(k, v["total"]) for k, v in clusters.items()
                 if k != exp_key and v["total"] > exp_total]
        expected_info = {
            "name": expected_protagonist,
            "cluster_total": exp_total,
            "louder_rivals": rival[:3],
        }

    return {
        "confidence": confidence,
        "placeholders": placeholders,
        "span_alerts": span_alerts,
        "takeover_alerts": takeover_alerts,
        # 报告只展示有高频代表名的簇（真角色簇），词组噪声簇折叠
        "clusters": {k: {"total": v["total"], "names": dict(v["names"].most_common(5))}
                     for k, v in clusters.items()
                     if max(v["names"].values()) >= MIN_MEMBER_FREQ},
        "per_chapter": per_chapter,
        "expected_protagonist": expected_info,
    }
