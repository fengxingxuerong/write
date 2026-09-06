#!/usr/bin/env python3
"""墨匠 InkSmith —— 模板引擎离线生成 + 质量评估演示"""
import re, sys, json

# ============================================================
# 1. Mulberry32 PRNG —— 与 Dart SeededRandom 完全一致
# ============================================================
class SeededRandom:
    def __init__(self, seed: int = 0):
        self._state = seed & 0xFFFFFFFF
    def next(self) -> float:
        self._state = (self._state + 0x6D2B79F5) & 0xFFFFFFFF
        z = self._state
        z = ((z ^ (z >> 15)) * (1 | z)) & 0xFFFFFFFF
        z ^= (z + ((z ^ (z >> 7)) * (61 | z)) & 0xFFFFFFFF)
        z ^= (z >> 14)
        return (z % 0x100000000) / 4294967296.0
    def range(self, lo: int, hi: int) -> int:
        if hi <= lo: return lo
        return lo + int(self.next() * (hi - lo))
    def pick(self, items):
        if not items: raise StateError("empty")
        return items[self.range(0, len(items))]
    def chance(self, p: float) -> bool:
        return self.next() < p

# ============================================================
# 2. 字数统计
# ============================================================
def count_words(text):
    if not text: return 0
    count, in_ascii = 0, False
    for ch in text:
        r = ord(ch)
        if 0x3400 <= r <= 0x4DBF or 0x4E00 <= r <= 0x9FFF or 0xF900 <= r <= 0xFAFF:
            count += 1; in_ascii = False
        elif (0x41 <= r <= 0x5A) or (0x61 <= r <= 0x7A) or (0x30 <= r <= 0x39):
            if not in_ascii: count += 1; in_ascii = True
        else: in_ascii = False
    return count

def dart_hash(s):
    h = 5381
    for ch in s:
        h = ((h * 33 + ord(ch)) & 0x7FFFFFFF)
    return h

NAMES = ['云澈','苏璃','林玄','楚月','风行','墨渊','白砚','夜阑','君无邪','慕容雪','陆长风','秦照','洛天','沈砚','姬晨','寒山客','萧瑟','叶倾','顾长歌','宋云','钟离','澹台镜','东方既白','南宫月','北冥舟','西门吹雪','独孤意','李暮','姜望','唐缺','温如言','卓清','蓝衫','苏陌','楚狂','雷震','贺兰辞','尉迟烈','白无垢','商陆','燕惊鸿','青萝','冷千秋','木槿','任天行','桑柔','百里屠','花无缺','齐灵']
PLACES = ['天玄大陆','青云宗','幽冥渊','落霞峰','听雪城','寒江渡','九霄阙','万剑谷','浮生海','星陨原','枯荣山','流光河','赤焰岭','碧落宫','断魂崖','云梦泽','苍梧野','无妄海','问天台','葬神谷','琉璃京','风陵渡','太虚古境','焚天窟','玄冰渊','沧澜城','万兽山脉','寂灳海']
FACTIONS = ['青云宗','魔教','剑阁','丹盟','妖族王庭','天机阁','散修联盟','御兽宗','缥缈仙宫','幽都','万宝楼','影堂','太玄门','血煎盟','阵法公会','铸兵山庄']
OBJECTS = ['古剑','玉佩','残卷','令牌','秘境图','灵草','铜镜','油灯','旧信','怀表','钥匙','棋局','药囊','骨笛','星盘']
ACTIONS = ['缓步前行','悄然退后','凝神细看','低声沉吟','猛然惊醒','负手而立','纵身一跃','垂眸不语','转身离去','驻足回望','握紧双拳','闭上双眼']
EMOTIONS = ['心中一紧','暗自忖度','不胜唏嘘','隐隐不安','豁然开朗','怅然若失','肃然起敬','五味杂陈','如释重负','波澜暗生']
DIALOGS = ['{name}，你当真要走','此事，绝非表面那般简单','你可知自己惹了多大的麻烦','放心，有我在','若你执意如此，便别怪我不念旧情','有些话，我藏了很久','这世间，值得你守护的，还剩什么']
CONTINUATION_OPENERS = ['这一夜，{place}的灯火久久未熄。','翌日清晓，{place}的雾气还未散尽。','时间一点点流逝，{name}的心绪却无法平复。','事情远未结束，{name}知道真正的风暴还在后头。','过了许久，{place}才重新恢复平静。','那一幕过后，{name}久久难以入眠。']
HINT_LEADS = ['这一日，','说来也巧，','谁也没想到，','变故来得毫无征兆——','一切要从那件事说起：','就在众人以为风平浪静时，']

OPENERS = [
    '{place}的天刚蒙蒙亮，{name}已经站在了这里。','辰时刚过，{place}的人声便渐渐稠了起来。',
    '{name}到{place}的时候，风里还带着夜里的凉意。','这是{name}第无数次踏进{place}，但今天不一样。',
    '{place}深处传来钟声，一下一下，敲得人心头发紧。','晨雾未散，{name}的身影已经出现在{place}的入口。',
    '没有人注意到，{name}在{place}的角落停了下来。','{faction}的告示才贴出半天，{place}前就围满了人。',
    '日头偏西，{place}的影子被拉得老长，{name}终于来了。','雨后的{place}泛着一股土腥气，{name}深一脚浅一脚地走。',
    '{object}被{name}贴身收着，一路随着心跳发烫。','夜里落过一场雨，{place}的石阶上还汪着水光。',
]
DEVELOPMENT = [
    '{name}{action}，顺着人群往里走，眼睛却在飞快地打量四周。','事情比预想的顺利，顺利得让{name}反而不敢松劲。',
    '{ally}凑过来压低声音：「先别动手，看看再说。」','{name}不动声色地绕到侧边，把整件事从头到尾又捋了一遍。',
    '按照计划，接下来只差最后一步。','{name}把{object}递过去，指尖在对方看不见的角度轻轻一按。',
    '人群忽然朝两边让开，来人的身份不言自明。','{name}沿着{place}的回廊疾行，靴底敲出的声响又急又稳。',
    '{ally}在前头引路，一路上把{faction}的门道讲了个七七八八。','时间一点点过去，{place}的气氛却越来越不对。',
    '{name}试着催动体内那股暖流，这一次竟没有半分滞涩。','线索断在这里，{name}却从{object}的夹层里摸出了新东西。',
]
SENSORY = [
    '{place}里弥漫着一股陈年木料混着香灰的味道。','风从窗缝里挤进来，烛火伏低了又直起来。',
    '脚下的木板咯吱作响，每一声都在寂静里放大。','茶汤的热气袅袅上升，映得{name}的眉眼有些模糊。',
    '墙外更鼓敲过二更，寒意顺着衣领往里钻。','指尖抚过{object}粗糙的表面，细小的划痕硌着指腹。',
    '远处市集的喧闙隔着一道墙，闷闷地涌进来。','{place}的日光斜斜切进来，照亮空气里浮动的尘埃。',
    '血腥味混着雨水漫开，呛得人喉头发紧。','檐角铁马叮当乱响，风比想象中大得多。',
    '墨迹未干的纸页散发出清苦的气味。','灶膛里的火星噼啪炸开，映红了半面土墙。',
]
DIALOGUE_PAIRS = [
    '「{dialogue}」{rival}慢条斯理地说，像是在谈论今天的天气。','{name}冷笑一声：「{dialogue}。」',
    '「{dialogue}？」{ally}的声音陡然拔高，「你知道自己在说什么吗！」','「{dialogue}。」{name}答得干脆，不给对方留半分余地。',
    '{rival}眯起眼：「{dialogue}——有意思，可惜晚了。」','「{dialogue}。」这句话很轻，落在耳中却重若千钧。',
    '{name}沉默片刻，才缓缓开口：「{dialogue}。」','「{dialogue}！」{rival}拍案而起，满座皆惊。',
    '{ally}苦笑着摇头：「{dialogue}。你自己掂量吧。」','「{dialogue}。」{name}说完转身就走，任凭身后议论纷纷。',
    '「{dialogue}。」对方话里有话，{name}听懂了，面上却不露分毫。','{rival}盯着{name}看了许久，忽而一笑：「{dialogue}。」',
]
INNER_THOUGHTS = [
    '{name}在心里飞快地权衡：退，前功尽弃；进，十死无生。','不能露怯——至少现在不能。',
    '如果{ally}说的是真的，那么此前的一切都要推倒重来。','{name}想起临行前的承诺，胸口像堵着一团烧红的炭。',
    '赌吗？赌。除此之外别无他法。','对方越是从容，说明水越深。',
    '{name}把{emotion}咽了回去，眼下不是动情的时候。','一步一步走到今天，靠的从来不只是运气。',
    '最坏的结果无非是死，可比起等死，{name}宁可去搏。','这件事透着蹊跷，而蹊跷就在于它太顺理成章。',
    '{name}提醒自己：越是这种时候，越要慢。','罢了，路是自己选的，跪着也要走完。',
]
TENSION = [
    '空气像是被人抽走了，{place}安静得能听见自己的心跳。','{rival}缓缓抬起眼，那道目光像刀子一样刮过来。',
    '不对——{name}的后颈猛地绷紧，杀气！','四面八方的退路，不知何时已经被堵死了。',
    '{rival}笑了，笑声不大，却让在场每个人心头一寒。','{object}开始发烫，这是危险临近的信号。',
    '{name}数着自己的呼吸，把翻涌的{emotion}一寸寸压下去。','头顶的房梁发出不堪重负的呻吟，尘灰簌簌往下掉。',
    '{rival}每向前一步，{name}掌心的汗就多一分。','远处传来一声闷响，紧接着是第二声、第三声，越来越近。',
    '所有人都看得出，这一击之下必有一方倒下。','灯花爆了一声，{place}里的火光骤然暗了一瞬。',
]
CLIMAX = [
    '电光石火之间，{name}{action}，快得没有人看清轨迹。','轰然巨响，气浪掀翻了半个{place}。',
    '{name}把积攒了许久的{emotion}在这一刻尽数砸了出去。','「住手！」{name}一声怒喝，人已欺身而至。',
    '两股力道狠狠相撞，僵持不过三息，胜负已分。','{rival}的攻势密不透风，{name}却硬生生从中撕开一道口子。',
    '这一下用尽了全力，{name}连站姿都晃了一晃。','血珠溅上半空，{rival}难以置信地看着自己颤抖的手。',
    '{object}应声而碎，碎片里迸出的光却照亮了全场。','{name}咬碎了牙关，硬扛着这雷霆一击没有后退半步。',
    '满场哗然之中，唯有{name}的呼吸依旧平稳如初。','胜负在此一举，{name}把所有底牌都摊在了这一击里。',
]
TWIST = [
    '直到这时{name}才发现，事情从一开始就不是那个样子。','「你以为你赢定了？」{rival}撕下伪装，眼底一片冰凉。',
    '{object}背面赫然刻着一行小字，正是{name}再熟悉不过的手迹。','{ally}站在了对面，这个事实比任何刀剑都伤人。',
    '原来所谓机缘，不过是有人布下的一个局。','记忆里模糊的一角忽然清晰，{name}浑身发冷。',
    '{faction}的态度一夜之间急转直下，其中必有隐情。','死者手中攥着的，竟是半块{name}从小佩戴的信物。',
    '真话说了一半，往往比谎话更让人心惊。','{rival}临走前丢下的那句话，此刻才显出真正的分量。',
    '账目对不上，缺的那一笔恰好指向最不可能的人。','{name}反复确认了三遍，结论依然荒谬得可怕。',
]
RESOLUTION = [
    '尘埃落定，{place}恢复了往日的嘈杂，仿佛什么都没发生过。','{name}长长吐出一口气，紧绷的肩膀这才垮了下来。',
    '{ally}拍着{name}的肩，半天只说出一句「好样的」。','夜深了，{name}独自坐在灯下，把今日种种又想了一遍。',
    '该来的总会来，躲不掉的，{name}便不再躲。','伤好得差不多了，有些账也该慢慢算了。',
    '{object}重新收进怀里，这一次，{name}握得更紧。','{faction}的封赏如期而至，{name}却只淡淡谢过。',
    '风波暂平，可{name}清楚，这不过是暴风雨前的宁静。','日子照旧过，只是{place}的人再看{name}时，眼神都变了。',
    '睡梦里，{name}又回到了白天那一刻，这一次没有失手。','第二天清晨，{name}照常出现在练功场上，仿佛无事发生。',
]
HOOKS = [
    '就在这时，门外传来一阵极轻、却绝对刻意放出来的脚步声。','{rival}留下的最后一句话在耳边反复回响——「三日之后，老地方。」',
    '{object}忽然毫无征兆地震了一下。','深夜，{faction}方向的天空亮起了一道不祥的红光。',
    '信使滚落下马，手里死死攥着一封火漆未拆的信。','{name}吹熄灯火，黑暗里那双眼睛却迟迟没有合上。',
    '第二天一早，{place}门口多了一具无名尸首。','更漏三声，窗外黑影一闪而过，快得像是错觉。',
    '{ally}欲言又止，最终还是把那句警告咽了回去。','名册翻到最后一页，{name}的瞳孔骤然收缩。',
    '远方的地平线上，烟柱正一根接一根地竖起来。','「他们来了。」不知是谁在暗处低低说了一句。',
]
ALL_BEATS = {'openers': OPENERS, 'development': DEVELOPMENT, 'tension': TENSION,
             'climax': CLIMAX, 'twist': TWIST, 'resolution': RESOLUTION,
             'hooks': HOOKS, 'sensory': SENSORY,
             'dialoguePairs': DIALOGUE_PAIRS, 'innerThoughts': INNER_THOUGHTS}
STAGE_WEIGHTS = {
    '起': {'openers': 5, 'sensory': 2, 'development': 2, 'innerThoughts': 1},
    '转': {'tension': 4, 'climax': 3, 'twist': 3, 'dialoguePairs': 1},
    '合': {'resolution': 5, 'innerThoughts': 2, 'sensory': 1},
    '承': {'development': 5, 'dialoguePairs': 2, 'innerThoughts': 2, 'tension': 1, 'sensory': 1},
}
SKELETONS = [
    [('起','铺垫修炼世界的规则与主角微末处境'),('承','一次奇缘让主角获得机缘'),('转','遭遇强敌或瓶颈，心境蜕变'),('合','小有突破并埋下宗门暗流')],
    [('起','宗门测评为引，凸显主角资质'),('承','秘境开启，主角误入禁地'),('转','古碑传承觉醒，实力跃迁'),('合','携宝归来却惹来觊觎')],
    [('起','主角受辱，立下变强之志'),('承','偶遇隐世高人指点'),('转','比武台上以弱胜强'),('合','声名初露，宿敌现身')],
    [('起','家族衰败，主角临危受命'),('承','祖地秘藏现身'),('转','血脉觉醒引动天地异象'),('合','重振家声，暗敌环伺')],
    [('起','凡人少年向往仙途'),('承','以杂役之身窥见道法'),('转','生死之间悟出本心'),('合','被名门收为记名弟子')],
]


# ============================================================
# 4. 模板引擎核心
# ============================================================
def fill_template(tpl, ctx):
    return re.sub(r'\{(\w+)\}', lambda m: ctx.get(m.group(1), ''), tpl)

def pick_for_stage(stage, rng, beats):
    w = STAGE_WEIGHTS.get(stage, STAGE_WEIGHTS['承'])
    total = sum(w.values()); roll = rng.range(0, total)
    for g, wt in w.items():
        roll -= wt
        if roll < 0: return rng.pick(beats[g])
    return rng.pick(beats['development'])

class Engine:
    def __init__(s, genre, tone, target_words, random_level, protagonist_name=None):
        s.genre = genre; s.tone = tone; s.target_words = target_words
        s.random_level = random_level; s.protagonist_name = protagonist_name
        seed = (dart_hash(genre) ^ dart_hash(tone) ^ target_words ^ int(random_level * 1000)) & 0x7FFFFFFF
        s.rng = SeededRandom(seed); s.beats = ALL_BEATS; s.skeps = SKELETONS
        s._pool = {}
    def _setup(s, chars_known):
        s.hero = s.protagonist_name or s.rng.pick(NAMES)
        ex = {s.hero}
        s.rival = s.rng.pick([n for n in chars_known if n not in ex] or NAMES); ex.add(s.rival)
        s.ally = s.rng.pick([n for n in chars_known if n not in ex] or NAMES); ex.add(s.ally)
        s.cast = [n for n in NAMES if n not in ex]
        s.place = s.rng.pick(PLACES); s.faction = s.rng.pick(FACTIONS); s.obj = s.rng.pick(OBJECTS)
    def _val(s, key):
        if key == 'name': return s.rng.pick(s.cast) if (not s.rng.chance(0.7) and s.cast and s.rng.chance(0.5)) else s.hero
        elif key == 'rival': return s.rival
        elif key == 'ally': return s.ally
        elif key == 'place': return s.place
        elif key == 'faction': return s.faction
        elif key == 'object': return s.obj if s.rng.chance(0.7) else s.rng.pick(OBJECTS)
        elif key == 'action': return s.rng.pick(ACTIONS)
        elif key == 'emotion': return s.rng.pick(EMOTIONS)
        elif key == 'dialogue': return s.rng.pick(DIALOGS).replace('{name}', s._val('name'))
        return ''
    def _fill(s, tpl):
        ctx = {k: s._val(k) for k in ['name','rival','ally','place','faction','object','action','emotion','dialogue']}
        return fill_template(tpl, ctx)
    def _pp(s, pool_key):
        rec = s._pool.setdefault(pool_key, [])
        cands = [t for t in s.beats[pool_key] if t not in rec]
        tpl = s.rng.pick(cands) if len(cands) > 1 else s.rng.pick(s.beats[pool_key])
        rec.append(tpl)
        if len(rec) > 6: del rec[0]
        return tpl
    def _weave(s, hint, stage):
        lead = s.rng.pick(HINT_LEADS); tail = pick_for_stage(stage, s.rng, s.beats)
        return f'{lead}{hint}。{s._fill(tail)}'
    def generate(s, continuation=None, outline='', chars_known=None):
        chars_known = chars_known or []
        target = max(200, min(s.target_words, 20000))
        s._setup(chars_known); buf = ''; current = 0
        if continuation:
            buf += s._fill(s.rng.pick(CONTINUATION_OPENERS)) + '\n\n'; current = count_words(buf)
        pts = [l.strip() for l in outline.split('\n') if l.strip()] if outline else []
        first_sk = s.rng.pick(SKELETONS)
        if pts:
            bi = 0; usable = first_sk if first_sk else [('起','推进')]
            for pt in pts:
                if current >= target: break
                b = usable[bi % len(usable)]; bi += 1
                buf += s._weave(pt, b[0]); current = count_words(buf)
                for _ in range(s.rng.range(2, 5)):
                    if current >= target: break
                    buf += s._fill(pick_for_stage(b[0], s.rng, s.beats)); current = count_words(buf)
                buf += '\n\n'; current = count_words(buf)
        else:
            for b in first_sk:
                if current >= target: break
                buf += s._weave(b[1], b[0]); current = count_words(buf)
                ns = {'转': s.rng.range(2,4), '合': s.rng.range(3,5)}.get(b[0], s.rng.range(3,6))
                for _ in range(ns):
                    if current >= target: break
                    buf += s._fill(pick_for_stage(b[0], s.rng, s.beats)); current = count_words(buf)
                buf += '\n\n'; current = count_words(buf)
        while current < target:
            sk = s.rng.pick(SKELETONS)
            dev = [b for b in sk if b[0] in ('承','转')]
            if not dev: break
            for b in dev:
                if current >= target: break
                buf += s._weave(b[1], b[0]); current = count_words(buf)
                ns = {'转': s.rng.range(2,4), '合': s.rng.range(3,5)}.get(b[0], s.rng.range(3,6))
                for _ in range(ns):
                    if current >= target: break
                    buf += s._fill(pick_for_stage(b[0], s.rng, s.beats)); current = count_words(buf)
                buf += '\n\n'; current = count_words(buf)
            if current >= target: break
        if current < target:
            sk = s.rng.pick(SKELETONS); end = [b for b in sk if b[0] == '合']
            for b in end:
                if current >= target: break
                buf += s._weave(b[1], b[0]); current = count_words(buf)
                for _ in range(s.rng.range(3, 5)):
                    if current >= target: break
                    buf += s._fill(pick_for_stage('合', s.rng, s.beats)); current = count_words(buf)
                buf += '\n\n'; current = count_words(buf)
        hook = s._fill(s.rng.pick(HOOKS))
        if count_words(buf.rstrip() + hook) <= target + 60:
            buf += hook + '\n'
        return buf.rstrip()

# ============================================================
# 5. 质量检查器
# ============================================================
AI_ECHO_WORDS = ['嘴角','唇角','眼底','眼神','目光','仿佛','似乎','宛如','空气','心跳','深吸','舒了','命运','改变','轨迹','万语','千里','暮气','春风']
SENSOR_WDS = list('风香味声响热冷触痒咸甜苦酸涩滑冰烫湿燥烟雨雪沙')

def calc_ai_echo(text):
    if not text: return 0.0
    hits = sum(text.count(w) for w in AI_ECHO_WORDS)
    w = count_words(text); return (hits / w * 100.0) if w > 0 else 0.0

def _jaccard(a, b):
    ta = set(re.findall(r'[\u4e00-\u9fff]{2,}', a)); tb = set(re.findall(r'[\u4e00-\u9fff]{2,}', b))
    if not ta and not tb: return 0.0
    i = len(ta & tb); u = len(ta | tb); return i/u if u > 0 else 0.0

def calc_rep(text):
    pars = [p for p in text.split('\n\n') if len(p.strip()) > 10]
    if len(pars) < 2: return 0.0
    return sum(_jaccard(pars[i-1], pars[i]) for i in range(1, len(pars))) / (len(pars)-1)

def calc_rhythm(text):
    pars = [p for p in text.split('\n\n') if len(p.strip()) > 10]
    if not pars: return 0.0
    return sum(1 for p in pars if count_words(p) < 30 or count_words(p) > 400) / len(pars)

def calc_sensory(text):
    w = count_words(text)
    if w == 0: return 0.0
    return min(sum(text.count(x) for x in SENSOR_WDS) / w * 100, 100.0)

def calc_dialogue(text):
    pars = [p for p in text.split('\n\n') if len(p.strip()) > 10]
    if not pars: return 0.0
    return sum(1 for p in pars if '\u300c' in p and '\u300d' in p) / len(pars)

def qc(text):
    ae = calc_ai_echo(text); rep = calc_rep(text); rhy = calc_rhythm(text)
    sen = calc_sensory(text); dial = calc_dialogue(text); words = count_words(text)
    overall = max(0, min(100, 100 - ae*20 - rep*30 - rhy*15))
    return {'词数': words, '评分': round(overall), 'AI囷痕': round(ae,2), '重复率': round(rep,3),
            '节奏失衡': round(rhy,3), '五感': round(sen,1), '对话占比': round(dial,3),
            '需要润色': '是' if ae > 0.02 or rep > 0.10 else '否'}

# ============================================================
# 6. Main
# ============================================================
def main():
    print('=' * 70)
    print('墨匠 InkSmith —— 模板引擎离线生成 + 质量评估演示')
    print('=' * 70)
    print()
    print('配置:')
    print('  题材: 玄幻 | 基调: 热血 | 目标: 2000字/章 | 随机度: 0.5')
    print('  主角: 赵怡阳 (自定义)')
    print()

    chars = ['赵怡阳', '林素婧']
    outlines = ['', '赵怡阳在青云宗被测试时意外展现废脉潜能\n遇到危机时灵气暴涨\n获得上古法器', '赵怡阳回到家族考察祖地图\n意外触发家族隐藏禁制\n面对内奸背刺']

    chapters = []
    for i in range(3):
        eng = Engine('xuanhuan', '热血', 2000, 0.5, '赵怡阳')
        cont = chapters[-1][:200] if chapters else None
        print(f'--- 生成第 {i+1} 章 ---')
        ch = eng.generate(continuation=cont, outline=outlines[i], chars_known=chars)
        chapters.append(ch)
        r = qc(ch)
        print(f'  质量: {r}')
        print()

    print('\n' + '=' * 70)
    print('生成的小说内容')
    print('=' * 70)
    for i, ch in enumerate(chapters):
        print(f'\n{"="*50}')
        print(f'第 {i+1} 章')
        print(f'{"="*50}\n')
        print(ch)
        print()

if __name__ == '__main__':
    main()


