

# ============================================================
# 4. 模板引擎核心
# ============================================================
STAGE_WEIGHTS = {
    '起': {'openers': 5, 'sensory': 2, 'development': 2, 'innerThoughts': 1},
    '转': {'tension': 4, 'climax': 3, 'twist': 3, 'dialoguePairs': 1},
    '合': {'resolution': 5, 'innerThoughts': 2, 'sensory': 1},
    '承': {'development': 5, 'dialoguePairs': 2, 'innerThoughts': 2, 'tension': 1, 'sensory': 1},
}

def fill_template(tpl, ctx):
    def repl(m):
        k = m.group(1)
        return str(ctx.get(k, ctx.get(k, '')))
    return re.sub(r'\{(\w+)\}', repl, tpl)

def pick_for_stage(stage, rng, beats):
    weights = STAGE_WEIGHTS.get(stage, STAGE_WEIGHTS['承'])
    total = sum(weights.values())
    roll = rng.r(0, total)
    for group, w in weights.items():
        roll -= w
        if roll < 0:
            return rng.p(beats[group])
    return rng.p(beats['development'])

class Engine:
    def __init__(s, genre, tone, target_words, random_level, protagonist_name=None):
        s.genre = genre; s.tone = tone; s.target_words = target_words
        s.random_level = random_level; s.protagonist_name = protagonist_name
        base = dh(genre) ^ dh(tone) ^ target_words
        jitter = int(random_level * 1000)
        seed = (base ^ jitter) & 0x7FFFFFFF
        s.rng = R(seed)
        s.beats = ALL_BEATS
        s.skeps = SKELETONS
        s.templates = ALL_TEMPLATES
        s._pool = {}
    def _setup(s, chars_known):
        s.hero = s.protagonist_name or s.rng.p(NAMES)
        exclude = {s.hero}
        s.rival = s.rng.p([n for n in chars_known if n not in exclude] or NAMES)
        exclude.add(s.rival)
        s.ally = s.rng.p([n for n in chars_known if n not in exclude] or NAMES)
        exclude.add(s.ally)
        s.cast = [n for n in NAMES if n not in exclude]
        s.place = s.rng.p(PLACES)
        s.faction = s.rng.p(FACTIONS)
        s.obj = s.rng.p(OBJECTS)
    def _val(s, key):
        if key == 'name':
            if s.rng.c(0.7): return s.hero
            return s.rng.p(s.cast) if s.cast and s.rng.c(0.5) else s.hero
        elif key == 'rival': return s.rival
        elif key == 'ally': return s.ally
        elif key == 'place': return s.place
        elif key == 'faction': return s.faction
        elif key == 'object': return s.obj if s.rng.c(0.7) else s.rng.p(OBJECTS)
        elif key == 'action': return s.rng.p(ACTIONS)
        elif key == 'emotion': return s.rng.p(EMOTIONS)
        elif key == 'dialogue':
            d = s.rng.p(DIALOGS)
            return d.replace('{name}', s._val('name'))
        return ''
    def _fill(s, tpl):
        ctx = {}
        for k in ['name','rival','ally','place','faction','object','action','emotion','dialogue']:
            ctx[k] = s._val(k)
        return fill_template(tpl, ctx)
    def _pick_pool(s, key, pool):
        recent = s._pool.setdefault(key, [])
        candidates = [t for t in pool if t not in recent]
        tpl = s.rng.p(candidates) if len(candidates) > 1 else s.rng.p(pool)
        recent.append(tpl)
        if len(recent) > 6: del recent[0]
        return tpl
    def _weave(s, hint, stage):
        lead = s.rng.p(HINT_LEADS)
        tail_pool = pick_for_stage(stage, s.rng, s.beats)
        return f'{lead}{hint}。{s._fill(tail_pool)}'
    def _write_stage(s, stage, hint, buf, current, target):
        buf += s._weave(hint, stage)
        current = wc(buf)
        if current >= target: return current
        nsent = {'转': s.rng.r(2,4), '合': s.rng.r(3,5)}.get(stage, s.rng.r(3,6))
        for _ in range(nsent):
            if current >= target: break
            beat = s._pick_pool(stage.lower(), s.beats.get(stage.replace('起','openers').replace('承','development').replace('转','tension').replace('合','resolution'), s.beats['development']))
            buf += s._fill(beat)
            current = wc(buf)
        buf += '\n\n'
        return wc(buf)

    def generate(s, continuation=None, outline='', chars_known=None):
        chars_known = chars_known or []
        target = max(200, min(s.target_words, 20000))
        s._setup(chars_known)
        buf = ''
        current = 0
        if continuation:
            tpl = s.rng.p(CONTINUATION_OPENERS)
            buf += s._fill(tpl) + '\n\n'
            current = wc(buf)
        outline_pts = [l.strip() for l in outline.split(chr(10)) if l.strip()] if outline else []
        first_sk = s.rng.p(s.skeps)
        if outline_pts:
            bi = 0
            usable = first_sk if first_sk else [('起','推进')]
            for pt in outline_pts:
                if current >= target: break
                beat = usable[bi % len(usable)]; bi += 1
                buf += s._weave(pt, beat[0])
                current = wc(buf)
                for _ in range(s.rng.r(2,5)):
                    if current >= target: break
                    p = s._pick_pool(beat[0], s.beats.get(beat[0], s.beats['development']))
                    buf += s._fill(p)
                    current = wc(buf)
                buf += '\n\n'
                current = wc(buf)
        else:
            for beat in first_sk:
                if current >= target: break
                buf += s._weave(beat[1], beat[0])
                current = wc(buf)
                nsent = {'转': s.rng.r(2,4), '合': s.rng.r(3,5)}.get(beat[0], s.rng.r(3,6))
                for _ in range(nsent):
                    if current >= target: break
                    p = pick_for_stage(beat[0], s.rng, s.beats)
                    buf += s._fill(p)
                    current = wc(buf)
                buf += '\n\n'
                current = wc(buf)
        while current < target:
            sk = s.rng.p(s.skeps)
            dev = [b for b in sk if b[0] in ('承','转')]
            if not dev: break
            for beat in dev:
                if current >= target: break
                buf += s._weave(beat[1], beat[0])
                current = wc(buf)
                nsent = {'转': s.rng.r(2,4), '合': s.rng.r(3,5)}.get(beat[0], s.rng.r(3,6))
                for _ in range(nsent):
                    if current >= target: break
                    p = pick_for_stage(beat[0], s.rng, s.beats)
                    buf += s._fill(p)
                    current = wc(buf)
                buf += '\n\n'
                current = wc(buf)
            if current >= target: break
        if current < target:
            sk = s.rng.p(s.skeps)
            end = [b for b in sk if b[0] == '合']
            for beat in end:
                if current >= target: break
                buf += s._weave(beat[1], beat[0])
                current = wc(buf)
                for _ in range(s.rng.r(3,5)):
                    if current >= target: break
                    p = pick_for_stage('合', s.rng, s.beats)
                    buf += s._fill(p)
                    current = wc(buf)
                buf += '\n\n'
                current = wc(buf)
        hook = s._fill(s.rng.p(HOOKS))
        merged = buf.rstrip() + hook
        if wc(merged) <= target + 60:
            buf += hook + '\n'
        return buf.rstrip()
