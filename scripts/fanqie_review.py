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

CHAPTER_RE = re.compile(r"^第\s*(\d+)\s*章")

# ============================================================
# 1) 红线词表（与 Dart 侧 lib/services/sensitive_words.dart 保持同步扩充）
# ============================================================
REDLINE = {
    "时政敏感": [
        "国家主席", "国务院", "中南海", "政治局", "省委书记", "市委书记", "中央委员会",
        "全国人大", "政协会议", "入党", "开除党籍", "纪委", "巡视组", "维稳", "上访",
        "信访局", "政府大楼", "市委大楼", "派出所值班", "国安局", "情报部门", "政变",
        "选举舞弊", "游行", "示威", "暴乱", "骚乱", "分裂势力", "台独", "港独",
    ],
    "宗教民族": [
        "真主", "安拉", " Jesus", "佛祖显灵", "基督", "天主教", "清真寺", "礼拜",
        "古兰经", "藏传佛教", "活佛转世", "蒙古大汗", "回族", "维吾尔", "穆斯林",
        "异教徒", "圣战", "驱魔仪式", "苗疆蛊", "蛊毒", "降头", "养小鬼", "请神",
        "问米", "问仙", "通灵", "招魂", "借尸还魂", "转世投胎实证",
    ],
    "未成年风险": [
        "未成年发生关系", "辍学少女", "师生恋", "初中生怀孕", "高中生开房", "萝莉",
        "正太", "诱奸", "迷奸少女", "童养媳圆房", "包养学生", "陪读母亲",
        "校园霸凌视频", "拍视频传播", "搜身羞辱", "扒光衣服", "拍裸照",
    ],
    "过度血腥": [
        "分尸", "碎尸", "肢解", "凌迟", "剥皮", "人彘", "开膛", "挖眼", "剔骨",
        "千刀万剐", "五马分尸", "肠子", "脑浆", "血流成河", "尸横遍野", "吃人肉",
        "烹尸", "熬人油", "人血馒头", "活体解剖", "虐杀", "鞭尸",
    ],
    "现实品牌与真人": [
        "微信", "支付宝", "淘宝", "京东", "拼多多", "抖音", "快手", "百度", "腾讯",
        "阿里巴巴", "华为手机", "苹果手机", "茅台", "可口可乐", "星巴克", "麦当劳",
        "清华大学", "北京大学", "协和医院", "钟南山", "马云", "马化腾", "任正非",
        "刘翔", "姚明",
    ],
    "教唆与违法细节": [
        "制作炸药的方法", "配比", "土制炸弹", "开锁技巧", "撬锁工具", "伪造身份证",
        "办假证", "洗钱方法", "跑路路线", "如何逃脱追查", "下毒剂量", "无色无味",
        "自制枪支", "射钉枪改造", "弩的图纸",
    ],
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
# ============================================================
CLICHE_SENTENCES = [
    "空气仿佛凝固", "嘴角勾起一抹", "眼底闪过一丝", "心中一凛", "心头一震",
    "不由得倒吸一口凉气", "瞳孔骤缩", "深吸一口气", "缓缓开口", "淡淡开口",
    "声音不大，却清晰地传入每个人耳中", "全场寂静", "鸦雀无声", "面面相觑",
    "众所周知", "谁也没想到", "就在这时", "一阵狂风刮过", "天空乌云密布",
    "仿佛在诉说着什么", "如同一头苏醒的洪荒巨兽", "周身气势暴涨",
    "气息陡然变强", "境界壁垒应声而碎", "突破了", "觉醒了",
    "他知道，从这一刻起，一切都不一样了", "命运的车轮开始转动",
    "既然如此，那便", "他握紧拳头，指甲嵌入掌心", "血液沸腾",
    "不服来战", "莫欺少年穷", "三十年河东三十年河西",
]

# 段落"推进力"检测用的动词/信息词（有则视为该段在推进剧情）
DRIVE_WORDS = [
    "说", "道", "问", "答", "喊", "笑", "看", "抓", "推", "砸", "拔", "转身",
    "走", "跑", "冲", "拿", "递", "写", "敲", "点", "掀", "摸", "掏", "塞",
    "死", "伤", "血", "钱", "字", "信", "刀", "枪", "门", "窗", "牌", "图",
    "答应", "拒绝", "决定", "必须", "马上", "今晚", "三天", "一个亿", "名字",
]

SENT_SPLIT = re.compile(r"[。！？…；]+")
CHAR_RE = re.compile(r"[\u4e00-\u9fff]")

# 人名候选：2~3 字汉字串 + 动作/说话词（用于查“主角漂移”）
NAME_PAT = re.compile(
    r"([\u4e00-\u9fff]{2,3})(?:[，,、]?"
    r"(?:说|道|问|答|笑|喊|盯|看|抬头|转身|点头|摇头|皱眉|收|站|蹲|伸手|开口|吐))")

# 冲突信号：首屏必须出现至少一个（开局要带包袋）
CONFLICT_WORDS = ["吼", "骂", "砸", "押", "欠", "逐", "抢", "抓", "审", "封门", "退婚",
                  "断", "碎", "伤", "血", "死", "遗物", "最后", "今天必须", "不交", "偿命",
                  "让位", "除名", "扫地出门", "递", "按在", "推到", "罚", "跪", "赔", "欠条",
                  "盯上", "警告", "通融", "期限", "三天内", "当场", "搜", "抬走", "拉走"]

# 骨架/规划官提示词泄漏（漏进正文 = 直接判废）
PROMPT_LEAK = ["本场景任务", "必须完成的节拍", "爽点：", "钩子：", "一次奇缘让主角获得机缘",
               "遭遇强敌或瓶颈", "心境蜕变", "就在众人以为风平浪静时", "targetWords",
               "【场景", "【跨章状态"]

# 元话语/指令残留（模型把「补写操作说明」当正文吐出来，拼进成书 = 直接判废）
# 实测事故：钩子补写返回「我拿到的指令是补写钩子，不是扩写。你贴的那段"充到 2000 字以上"…」
# 被原样拼到第 1 章末尾，本地评审仍给 92 分（旧 PROMPT_LEAK 只覆盖骨架词，抓不到这类）。
# 选词原则：只收「叙事里不可能出现」的短语，避免误伤正文（不用「抱歉」「请确认」这类口语）。
META_TALK = [
    "我拿到的指令", "拿到的指令是", "根据你的指令", "按你的指令", "按照你的要求", "按你的要求",
    "作为AI", "作为人工智能", "作为一个AI", "作为语言模型", "我无法完成", "我无法直接",
    "抱歉，我", "很抱歉，我", "你贴的那段", "你提供的文本", "以下是我的改写", "以上是补写",
    "字数要求", "扩写到", "如需继续", "如果你需要", "希望这符合", "无法满足这个要求",
]

# 题材漂移：给「古风/非现代」题材用的现代生活标志词。
# 实测事故：玄幻书第 3 章整章变成现代都市悬疑（路灯/手机/牛皮纸袋/面包车），
# 逐章本地评审仍给 84 分，直到终审官通读才发现「书名标称玄幻，末章主角换人」。
# 只收古风题材几乎不可能自然出现的词：「钥匙/医院/巷口」这类玄幻也合法的词一律不收。
MODERN_MARKERS = [
    "手机", "电脑", "网络", "微信", "支付宝", "电梯", "汽车", "面包车", "出租车", "公交车",
    "马路", "红绿灯", "路灯", "屏幕", "短信", "沙发", "咖啡", "监控", "摄像头", "银行卡",
    "外卖", "快递", "物业", "办公室", "上班", "加班", "房租", "塑料袋", "牛皮纸袋", "客服",
    "二维码", "充电", "导航", "直播", "朋友圈", "地铁", "高铁", "身份证",
]

# 需要锁题材的「非现代」题材（其余题材如都市/校园/悬疑不做现代词漂移判定）
ANCIENT_GENRES = ("玄幻", "仙侠", "武侠", "修真", "历史", "古代", "宫斗", "权谋",
                  "奇幻", "东方", "洪荒", "仙", "古言")

# 章内大段重复判定：重复块最短字数 / 指纹长度
INTRA_REPEAT_MIN_BLOCK = 120
INTRA_REPEAT_GRAM = 12

# 阻断级硬伤的下限字数：番茄单章建议 2000~3000，低于这条线不给「可投」
BLOCKING_MIN_WORDS = 1500


# ------------------------------------------------------------
# 基础统计
# ------------------------------------------------------------
# 常见姓氏（含网文高频复姓/生僻姓）：只有开头是姓的候选才算人名，
# 否则「人影×10」「老人×8」会被误报成主角漂移。
SURNAMES = set(
    "王李张刘陈杨黄赵周吴徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘于蒋蔡"
    "余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯"
    "龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤柴桑关岳鲍盛赖樊温柯岑路桂傅齐应宗简")
SURNAMES |= set("欧司马东方上官独孤南宫慕容宇文长孙闻人东郭呼延轩墨夜司徒卿慕凌花")


def looks_like_name(s):
    """粗略判断：首字是姓才算人名。"""
    return bool(s) and s[0] in SURNAMES


def count_words(text):
    """正文字数（只数汉字），与 generate_novel.count_words 同口径。"""
    return len(CHAR_RE.findall(text or ""))


def sentences(text):
    return [s.strip() for s in SENT_SPLIT.split(text) if s.strip()]


def paragraphs(text):
    return [p.strip() for p in (text or "").split("\n") if p.strip()]


def dialogue_ratio(text):
    """引号内字数占比。"""
    quoted = "".join(re.findall(r"[“\"『「]([^”\"』」]{1,200})[”\"』」]", text or ""))
    total = max(count_words(text), 1)
    return round(count_words(quoted) / total, 3)


def split_chapters(path):
    """按「第 N 章」拆章；无标题行时整篇当一章。"""
    lines = io.open(path, encoding="utf-8").read().splitlines()
    out, idx, title, body = [], None, "", []
    for line in lines:
        s = line.strip()
        m = CHAPTER_RE.match(s)
        if m:
            if idx is not None:
                out.append((idx, title, "\n".join(body).strip()))
            idx, title, body = int(m.group(1)), s, []
        elif s.startswith("—"):
            continue
        elif idx is not None:
            body.append(line)
    if idx is not None:
        out.append((idx, title, "\n".join(body).strip()))
    out = [x for x in out if x[2]]
    if out:
        return out
    whole = "\n".join(lines).strip()
    return [(1, "全文", whole)] if whole else []


# ------------------------------------------------------------
# 单项指标
# ------------------------------------------------------------
# 这三类只有在「教唆/推广/交易」语境下才是红线；小说把它们当情节元素使用是正常的
# （“妹妹欠下高利贷”不是红线，“高利贷放款教程”才是）。旧版一律否决，
# 实测会误伤《碎星航线》第 1 章（因章纲自带“高利贷”而被扣 45 分）。
NARRATIVE_OK_CATEGORIES = {"违法违规", "宗教民族", "现实品牌与真人"}
INSTRUCTION_MARKERS = ["方法", "教程", "步骤", "配方", "图解", "教你", "怎么", "如何", "加入",
                      "联系", "转发", "关注", "下载", "买卖", "出售", "招摹", "代办", "代办",
                      "价格", "起办", "免抵押", "低息", "放款", "群", "链接"]


_SEP_CHARS = set(
    "，。、；：！？（）()《》〈〉“”‘’「」『』【】[]{}\\/\"':;,·—-与和及 \t\r\n"
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
    """世界观一致性：大纲里的专名在正文命中几个。一个都没有 = 写手跑题。"""
    if not terms:
        return None
    hit = [t for t in terms if _term_hit(text or "", t)]
    return {"hit": len(hit), "total": len(terms), "terms": hit[:5]}


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
    """
    txt = (hook_hint or "").strip()
    if not txt:
        return ""
    txt = re.sub(r"^.*?[：:]", "", txt, count=1) if "：" in txt or ":" in txt else txt
    txt = txt.strip("（）() 「」『』")
    if not txt:
        return ""
    head = protagonist or "他"
    if head in txt:
        return txt if txt.endswith(("。", "！", "？", "…")) else txt + "。"
    return f"{head}回头。{txt.rstrip('。')}。"


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
                      "（写手没接住设定，己另起故事）", "重写"))
    elif wc and wc["hit"] <= 1:
        probs.append(("一致性", f"世界观专名仅命中 {wc['hit']}/{wc['total']}，题材锁定不够紧",
                      "修改"))
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
                       "repeat": rep, "agency": ag}}
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


def fix_prompt(review, content):
    """把评估结果转成「定点修」提示（只改问题处，保留已写好的剧情与文字）。

    达线且无阻断项（无重写/修改级问题）时返回空串——与 Dart 侧 fixPrompt 同一约定。
    阻断项在身时即使分数达标也照样出单（实测事故：92 分章含「元话语残留」被判可投，
    于是修复链跳过，脏文本一路留到成书）。"""
    probs = [p for p in review["problems"] if p["action"] in ("重写", "修改")]
    if not probs or (review.get("verdict") == "可投" and not review.get("blockers")):
        return ""
    lines = [f"- {p['type']}：{p['msg']}" for p in probs]
    rl = review["redline"]["veto"]
    if rl:
        lines += [f"- 合规红线：出现「{h['word']}」（{h['category']}），必须替换成不点名的写法"
                  for h in rl[:8]]
    return (
        "下面这一章要过番茄初审，评审器给出以下硬伤。请**只针对这些点改写**，"
        "保持人物名、事件顺序、已埋的伏笔完全不变，不要重写无关段落：\n"
        + "\n".join(lines)
        + "\n\n【改写要求】首屏 300 字必须有主角在场、正在发生的冲突、至少一句对白；"
          "主角本章至少做出一次有代价的主动选择；对话占比提到 25%~45%；"
          "删掉所有「删了不影响剧情」的段落；句子尽量控制在 25 字内；段落不超过 3 行。\n"
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
