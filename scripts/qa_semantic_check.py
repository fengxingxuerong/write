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
from collections import Counter

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

CHAPTER_RE = re.compile(r"^\s*(第\s*\d+\s*章[^\n]*)", re.MULTILINE)

# ============================================================
# 文本预处理：章节切分 / 对话剔除
# ============================================================

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
DIALOGUE_PATTERNS = [
    re.compile(r"‘[^’]*’"),
    re.compile(r"“[^”]*”"),
    re.compile(r"「[^」]*」"),
    re.compile(r"『[^』]*』"),
    re.compile(r'"[^"]*"'),
]


def strip_dialogue(text):
    """剔除引号内内容，只留叙述层。用标点占位防词黏连。"""
    prev = None
    while prev != text:
        prev = text
        for pat in DIALOGUE_PATTERNS:
            text = pat.sub("，", text)
    return text


# ============================================================
# 关卡 1：人称一致性检测（叙述人称漂移）
# ============================================================

FIRST_PRON = ("我", "俺", "咱")
THIRD_PRON = ("他", "她")

# 块级判定阈值（校准基准见文件头）
POV_MIN_NARR_CHARS = 100   # 引号外叙述字数下限（对话章整块跳过）
POV_MIN_PRON = 5           # 代词总数下限（样本不足不判；《铁掌破风》回测：
                           # 8 会漏掉第 1 章切换后的短第三人称块）
POV_FIRST_RATIO = 0.70     # 第一人称代词占比 >= 此值判 first
POV_THIRD_RATIO = 0.30     # 占比 <= 此值判 third
POV_STABLE_RUN = 2         # 稳定段最少块数（切换须持续 >=2 块才报）


def split_blocks(content, block_chars=500):
    """按段落聚合切块，每块约 block_chars 字。分隔线行（————/====）不计入。"""
    paras = [p.strip() for p in content.split("\n")
             if p.strip() and not re.match(r"^[—\-=_*]{3,}$", p.strip())]
    blocks, cur, size = [], [], 0
    for p in paras:
        cur.append(p)
        size += len(p)
        if size >= block_chars:
            blocks.append("\n".join(cur))
            cur, size = [], 0
    if cur:
        blocks.append("\n".join(cur))
    return blocks


def block_pov(block):
    """判定单块叙述人称。返回 (pov, c1, c3) 或 None（样本不足）。"""
    narr = strip_dialogue(block)
    n_chars = len(re.sub(r"\s", "", narr))
    c1 = sum(narr.count(x) for x in FIRST_PRON)
    c3 = sum(narr.count(x) for x in THIRD_PRON)
    if n_chars < POV_MIN_NARR_CHARS or c1 + c3 < POV_MIN_PRON:
        return None
    ratio = c1 / (c1 + c3)
    if ratio >= POV_FIRST_RATIO:
        return ("first", c1, c3)
    if ratio <= POV_THIRD_RATIO:
        return ("third", c1, c3)
    return ("mixed", c1, c3)


def detect_pov_drift(chapters, block_chars=500):
    """检测叙述人称漂移。返回 (events, chapter_summary)。

    判定逻辑：块级人称 → 游程编码 → 仅「连续 >=2 块」的稳定段参与比较，
    相邻稳定段人称不同即记一次切换事件（防对话噪声造成单块抖动误报）。
    """
    events = []
    chapter_summary = []
    for idx, ch_title, content in chapters:
        blocks = split_blocks(content, block_chars)
        n_first = n_third = n_mixed = n_skip = 0
        decided = []  # (block_idx, pov, 首段摘录, c1, c3)
        for bi, blk in enumerate(blocks):
            r = block_pov(blk)
            if r is None:
                n_skip += 1
                continue
            pov, c1, c3 = r
            if pov == "mixed":
                n_mixed += 1
            elif pov == "first":
                n_first += 1
            else:
                n_third += 1
            if pov in ("first", "third"):
                excerpt = blk.strip().split("\n")[0]
                decided.append((bi, pov, excerpt, c1, c3))
        # 游程编码
        runs = []
        for bi, pov, excerpt, c1, c3 in decided:
            if runs and runs[-1]["pov"] == pov:
                runs[-1]["len"] += 1
                runs[-1]["end"] = bi
            else:
                runs.append({"start": bi, "end": bi, "pov": pov,
                             "len": 1, "excerpt": excerpt})
        stable = [r for r in runs if r["len"] >= POV_STABLE_RUN]
        for a, b in zip(stable, stable[1:]):
            if a["pov"] != b["pov"]:
                events.append({
                    "chapter": idx,
                    "chapter_title": ch_title,
                    "from_pov": a["pov"],
                    "to_pov": b["pov"],
                    "pos_ratio": round(b["start"] / max(len(blocks), 1), 2),
                    "excerpt": b["excerpt"][:60],
                })
        chapter_summary.append({
            "idx": idx, "title": ch_title,
            "first_blocks": n_first, "third_blocks": n_third,
            "mixed_blocks": n_mixed, "skipped_blocks": n_skip,
            # 主导判定须过半数且 >=3 块，防独白密集章（first×1 mixed×5）误标第一人称
            "dominant_pov": ("first" if n_first >= 3 and n_first > n_third and
                             n_first * 2 >= n_first + n_third else
                             "third" if n_third >= 3 and n_third > n_first and
                             n_third * 2 >= n_first + n_third else
                             "mixed" if n_first + n_third else "-"),
        })
    return events, chapter_summary


# ============================================================
# 关卡 2：角色名漂移检测
# ============================================================

SURNAMES = (
    "王李张刘陈杨黄赵吴周徐孙马朱胡郭何林高罗郑梁谢宋唐许韩冯邓曹彭曾肖田"
    "董袁潘蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹"
    "孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤萧穆"
    # 网文常用姓补充（裴照/晏无咎/霍刃/郗砚/季渊/温衡等真实主角教训）
    "裴晏郗霍祝左关岑屈柳管盛凌纪庞颜梅童骆樊虞柯房解宗宣单洪包邢荣翁"
    "惠甄封储井段富巫焦谷侯尚农柴瞿阎充茹习宦艾容古易廖居衡耿匡"
    "文寇欧沃越隆师巩聂晁敖融冷辛简饶空鞠须丰巢蒯查荆游竺权桓南宫"
)

# 候选名后紧跟这些单字（动作/说话/介词/助词）视为强上下文
VERB_CHARS = (
    "站坐走跑蹲跳转退凑摸拍推拉扯指攥握拎提压按咬嚼吞咽吐咳喘瞅瞪瞄看望盯"
    "听闻嗅觉知想念记悟懂问说答讲念诵读骂吼喊嚷道言点摇抬低弯屈咧抿眨愣怔"
    "呆开闭回侧摆挥踢踹蹬踩迈跨撑爬翻滚挪移靠倚来去到从向朝对跟与和把将给"
    "让使是被那这又便就都还也才刚正要会能可"
)

# 高频词误报黑名单（姓氏撞词）
STOP_NAMES = {
    "马上", "东西", "金石", "江水", "河水", "海水", "井水",
    "江南", "江北", "河南", "河北", "湖南", "湖北", "山东", "山西",
    "广东", "广西", "王子", "天子", "君子", "夫人", "老子", "孙子",
    "大王", "大人", "大方", "平时", "平方", "方正", "北方", "南方",
    "东方", "西方", "下手", "下水", "上山", "下山", "上火",
    "方向", "方式", "方法", "方剂", "药方", "丹方", "方才",
    "步子", "步都", "脚下", "手下",
}

# 器物/地物/方位/亲属称谓/身体部位类第二字黑名单：
# 候选名第二字命中即视为词组而非人名
# （陶罐/柴刀/井底/师尊/师父/石头/左肩/王村…；保留砚/墨/石/峰等常见人名字）
OBJ_SUFFIX = set(
    "罐坛壶瓶桶锅碗瓢盆盖钉绳链环圈球油盐酱醋茶米面肉菜树木桥船车"
    "门窗墙砖瓦土坑沟渠河湖海丸散膏丹碟杯盘盏筷勺叉铲锄犁耙鞘托柄"
    "棍棒弓弦箭矢甲盔靴帽被褥枕席帘布帛绢纱绸缎锭两珠宝货财粮谷豆"
    "麦稻饭粥羹酒向村寨镇城楼台殿阁塔坟墓碑庙寺观庵井刀柴家"
    "底边口沿台旁里外面中前后人上下阶缝子"
    "尊父兄傅长叔伯婶姑姨舅嫂爷奶爹娘姐妹弟徒孙仙圣者翁婆"
    "肩手腕臂腿脚腰背胸口脸头目嘴鼻耳板壁"
)

# 占位称呼模式（真占位 = 写手未落实命名的强信号）
PLACEHOLDER_RES = [
    (re.compile(r"([" + SURNAMES + r"])某"), "{x}某"),
    (re.compile(r"姓([" + SURNAMES + r"])的"), "姓{x}的"),
    (re.compile(r"([" + SURNAMES + r"])(小子|丫头|老头|姑娘|老太|婆姨)"), "{x}{suffix}"),
]
# 昵称模式（老王/小裴——正常称呼，聚簇参与但不进占位信号）
NICKNAME_RES = [
    (re.compile(r"[老小阿]([" + SURNAMES + r"])(?![\u4e00-\u9fff])"), "昵·{x}"),
]

# 代词/虚词类第二字黑名单（连你/像他/高不/高个…）
PRON_SUFFIX = set("你我他她它谁啥什不没得了个之乎者也挺更最太")

MIN_CAND_FREQ = 2        # 候选名至少出现次数（动作验证命中）
MIN_CLUSTER_FREQ = 8     # 参与主角级区间分析的簇最小频次
MIN_MEMBER_FREQ = 5      # 主角级簇必须有高频代表名（防"田垄/石室"类
                         # 全碎片词组簇冒充；真主角簇代表名 >=5 次）
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


# ============================================================
# 关卡 3：标题-内容相符检测（题材内容塌陷）
# ============================================================
# 事故形态：《铁掌破风》第 2 章标题「试训」下零体育内容（跑偏成守井人玄学）。
# 与 GENRE_THRILL_EXTRA（爽点词）不同，这里用「题材场景元素词」——
# 正文里真正构成题材内容的名词/场景词。

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

# 塌陷判定阈值（校准：正样本《铁掌破风》--genre 体育 第 2 章零命中；
# 负样本各书每章命中密度 >=1/千字）
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
REL_WORDS = ("父亲", "母亲", "师父", "师傅", "丈夫", "妻子", "夫人",
             "儿子", "女儿", "义父", "义母")
_REL_ALT = "|".join(REL_WORDS)
REL_P1_PAT = re.compile(
    r"([一-鿿]{2,5})的(%s)(?:乃是|是)([一-鿿]{2,5})(?![一-鿿])" % _REL_ALT)
REL_P2_PAT = re.compile(
    r"([一-鿿]{2,5})(?:乃是|是)([一-鿿]{2,5})的(%s)" % _REL_ALT)

# 名字里出现这些字 → 是代词/否定/量词/结构词而非人名，整条丢弃
_REL_BAD_CHARS = set("是他她它我你您的了没非谁什这那其位个诸众各")
# 时地/评注副词前后缀（与人名归一：当年林啸天 ≡ 林啸天 ≡ 林啸天就是）
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
