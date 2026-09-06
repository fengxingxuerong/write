#!/usr/bin/env python3
"""墨匠 InkSmith —— 多模型协作长篇小说流水线（10 万字级）

角色分工（全部经连通性实测）：
  planner  Sensenova glm-5.2 (k2)         全书大纲 + 章节场景规划（temp=1, 大token）
  writer   AMD DeepSeek-V4-Flash          场景正文（故障转移 Sensenova dsf k1→k2→k3）
  editor   Sensenova kimi-k3 (k1/k2)      整章去AI味润色（temp=1）
  titler   Sensenova flash-lite (k3)      章节标题提炼
  verifier Sensenova glm-5.2 (k2)         每5章跨章一致性校验（只记录不阻塞）
  qa       本地规则引擎                   AI味密度/重复率/节奏/世界观冲突

断点续传：Ctrl+C 后重跑同一命令即可继续。
密钥经环境变量传入：NOVEL_KEY_AMD / NOVEL_KEY_SENSE_K1 / NOVEL_KEY_SENSE_K2 / NOVEL_KEY_SENSE_K3
"""
import argparse
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from generate_novel import (count_words, parse_json_from_llm, quality_check,
                            append_state, load_state, export_txt,
                            planning_prompt_idea, scene_planning_prompt, scene_prompt,
                            SYSTEM_PROMPT)

# ============================================================
# 模型配置（密钥经环境变量注入，不硬编码）
# ============================================================
SENSE = "https://token.sensenova.cn/v1/chat/completions"
AMD = "https://developer.amd.com.cn/radeon/api/v1/chat/completions"

def _key(name):
    k = os.environ.get(name, "")
    if not k:
        print(f"[WARN] 环境变量 {name} 未设置！")
    return k

# 角色配置（2026-09-05 全量实测后定稿）：
#   glm-5.2 需 temp=1.0 + max_tokens>=4000 才能稳定出完整 JSON（k1/k3 可用）
#   dsf(k2) 最稳；kimi(k2) 波动大；flash-lite 当日全灭弃用
PLANNER = dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=4000)
PLANNER_CHAIN = [
    dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=4000),          # k1
    dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=2000),  # k2
]
WRITER_CHAIN = [
    dict(url=AMD, model="DeepSeek-V4-Flash", key="", temp=0.8),                     # AMD 主
    dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8),                   # k2 备
]
EDITOR_CHAIN = [
    dict(url=SENSE, model="kimi-k3", key="", temp=1.0, max_tokens=4000),           # k2 主
    dict(url=AMD, model="DeepSeek-V4-Flash", key="", temp=0.8),                     # AMD 兜底
]
TITLER = dict(url=SENSE, model="deepseek-v4-flash", key="", temp=0.8, max_tokens=300)  # k2
VERIFIER = dict(url=SENSE, model="glm-5.2", key="", temp=1.0, max_tokens=3000)         # k1


def setup_keys():
    PLANNER["key"] = _key("NOVEL_KEY_SENSE_K1")
    PLANNER_CHAIN[0]["key"] = _key("NOVEL_KEY_SENSE_K1")
    PLANNER_CHAIN[1]["key"] = _key("NOVEL_KEY_SENSE_K2")
    WRITER_CHAIN[0]["key"] = _key("NOVEL_KEY_AMD")
    WRITER_CHAIN[1]["key"] = _key("NOVEL_KEY_SENSE_K2")
    EDITOR_CHAIN[0]["key"] = _key("NOVEL_KEY_SENSE_K2")
    EDITOR_CHAIN[1]["key"] = _key("NOVEL_KEY_AMD")
    TITLER["key"] = _key("NOVEL_KEY_SENSE_K2")
    VERIFIER["key"] = _key("NOVEL_KEY_SENSE_K1")


# ============================================================
# 非流式调用（Sensenova 系模型流式格式不统一，统一非流式最稳）
# ============================================================
def llm_call(provider, system, user, max_tokens=None, temperature=None, retries=2):
    """非流式 OpenAI 兼容调用，带指数退避。返回内容字符串，失败返回 ''。"""
    payload = {
        "model": provider["model"],
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": max_tokens or provider.get("max_tokens", 2000),
        "temperature": temperature if temperature is not None else provider.get("temp", 0.8),
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    body = json.dumps(payload).encode("utf-8")
    url = provider["url"].rstrip("/")
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, data=body, method="POST")
            req.add_header("Content-Type", "application/json")
            req.add_header("Authorization", f"Bearer {provider['key']}")
            with urllib.request.urlopen(req, timeout=300) as resp:
                d = json.loads(resp.read().decode("utf-8"))
                return d.get("choices", [{}])[0].get("message", {}).get("content", "") or ""
        except urllib.error.HTTPError as e:
            msg = e.read().decode("utf-8", errors="replace")[:160].replace("\n", " ")
            if e.code in (429, 500, 502, 503):
                wait = (3 ** (attempt + 1)) * 5 + random.randint(3, 15)
                print(f"    [retry {attempt+1}/{retries}] {provider['model']} HTTP {e.code}: {msg} (等 {wait}s)")
                if attempt < retries:
                    time.sleep(wait)
                    continue
            else:
                print(f"    [HTTP {e.code}] {provider['model']}: {msg}")
            return ""
        except Exception as e:
            print(f"    [retry {attempt+1}/{retries}] {provider['model']}: {type(e).__name__}: {str(e)[:100]}")
            if attempt < retries:
                time.sleep((3 ** attempt) * 5)
                continue
    return ""


def call_chain(chain, system, user, max_tokens):
    """沿故障转移链依次调用，返回第一个非空结果。"""
    for p in chain:
        r = llm_call(p, system, user, max_tokens=max_tokens)
        if r and len(r.strip()) > 20:
            return r
        print(f"    [chain] {p['model']} 返回为空，切换下一个")
    return ""


# ============================================================
# 各角色 Prompt
# ============================================================
PLANNER_SYS = "你是一位资深网文总编，擅长长篇玄幻小说的框架规划。输出严格遵循要求的 JSON 格式。"
EDITOR_SYS = "你是一位资深网文编辑，专精「去AI味」改写。"
TITLER_SYS = "你是一位网文标题专家，擅长提炼有悬念感、点击欲的章名。"
VERIFIER_SYS = "你是一位严谨的长篇小说一致性审校编辑。"


def editor_prompt(text):
    return f"""请把下面的小说章节改写得更像真人网文作者的手笔：

1. 全篇「仿佛/似乎/宛如」合计不超过 2 次；清除「嘴角勾起」「眼底闪过」「空气凝固」「深吸一口气」「空气像是被人抽走」等 AI 高频表达
2. 情节、人物、伏笔、章节结尾的钩子必须全部保留，不新增、不删减剧情
3. 对话更口语化、更有潜台词；描写更具体（数字、颜色、气味、声响），允许更「糙」、更有网文节奏
4. 保持原有段落结构

只输出改写后的完整正文，不要任何解释或前缀。

【章节正文】
{text}"""


def titler_prompt(text):
    return f"""为下面的章节内容提炼一个 8~15 字的章名，要有悬念感和网文味。只输出章名本身。

【章节内容】
{text[:500]}"""


def verifier_prompt(outline, chapters):
    return f"""以下是本书的大纲设定与已生成章节的标题列表。请检查：1) 世界观设定是否自相矛盾；2) 人物名称/身份是否混乱；3) 剧情是否有明显断裂或逻辑硬伤。

只输出 JSON（不要 Markdown 包裹）：{{"issues":[{{"chapter":N,"type":"矛盾类型","desc":"一句话说明"}}]}}
无问题则输出：{{"issues":[]}}

【大纲设定】
{json.dumps(outline, ensure_ascii=False)[:1500]}

【已生成章节】
{chapters}"""


def quality_review_prompt(text):
    """语义级五维评分（开篇/爽点/钩子/动机/节奏），输出 JSON。"""
    return f"""请以网文编辑的眼光为下面的章节打分（每项 0~100）：
1. opening：开篇是否快速进入事件、有代入感（黄金三章标准）
2. thrill：爽点密度与强度（打脸/升级/收获/秘密揭露；含蓄变强具象化也算）
3. hook：章末钩子是否让人想看下一章（悬念/变故/威胁）
4. motivation：人物动机是否清晰、行为是否合理
5. rhythm：节奏是否张弛有度、无注水、无流水账

严格输出 JSON（不要 Markdown 包裹）：
{{"scores":{{"opening":85,"thrill":60,"hook":90,"motivation":75,"rhythm":80}},"overall":78,"comment":"一句话点评（30字内）"}}

【章节正文】
{text}"""


def rewrite_prompt(text, comment, scores):
    """低分章节定向重写（保留情节与钩子，针对薄弱维度改进）。"""
    dims = ""
    if scores:
        dims = "薄弱维度参考：" + " ".join(f"{k}={v}" for k, v in scores.items())
    return f"""你是资深网文编辑。下面的章节质量评分偏低，请重写以提升质量：

- 保留原情节、人物、伏笔、章末钩子，不新增、不删减剧情
- 针对薄弱维度重点改进：开篇快速进入事件 / 爽点密度 / 章末钩子 / 人物动机 / 节奏
- 反AI腔：全篇「仿佛/似乎/宛如」合计不超过 2 次，禁用万能描写
- 保持原有段落结构，总字数与原作相当（只多不少）

原评语：{comment}
{dims}

【章节正文】
{text}

只输出重写后的完整正文，不要任何解释或前缀。"""


def state_extract_prompt(text, prev_state):
    """跨章状态提取：维护状态清单供下一章写作遵守（防人物状态断片）。"""
    prev = prev_state if prev_state and prev_state.strip() else "（无）"
    return f"""你是长篇小说状态管理员。请根据本章内容，维护一份「跨章状态清单」，供下一章写作时遵守，防止人物状态断片（如上一章断腿、下一章健步如飞）。

只记录硬状态：
- 人物伤势（含恢复情况）、修为/境界变化
- 随身物品的获得/丢失
- 承诺、恩怨、伪装身份
- 关键地点变化

要求：
1. 在旧状态基础上增删改，不要整段重写
2. 每条一行，格式：人物：状态；物品：xxx
3. 输出 3~8 行，简洁具体
4. 只输出状态清单文本，不要任何解释或 Markdown

【旧状态】（首次为空）
{prev}

【本章内容】
{text}"""


# ============================================================
# 跨章状态持久化（写入 jsonl 的 type=state_track 行）
# ============================================================
def load_state_track(path):
    """从进度文件恢复跨章状态清单（无则返回空串）。"""
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "state_track":
                return rec.get("data", "")
    return ""


def save_state_track(path, data):
    """追加跨章状态清单到进度文件。"""
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps({"type": "state_track", "data": data}, ensure_ascii=False) + "\n")


# ============================================================
# 主线
# ============================================================
def main():
    p = argparse.ArgumentParser(description="墨匠多模型协作流水线")
    p.add_argument("--total-words", type=int, default=100000, help="目标总字数")
    p.add_argument("--max-chapters", type=int, default=40)
    p.add_argument("--output", default="novel_pipeline.jsonl")
    p.add_argument("--chapter-wait", type=float, default=2.0)
    args = p.parse_args()

    setup_keys()
    print(f"[INFO] 协作流水线启动 | 目标 {args.total_words} 字 | 输出 {args.output}")

    state = load_state(args.output, min_words=0)
    outline = state["outline"]
    state_track = load_state_track(args.output)
    if state_track:
        print(f"[RESUME] 已恢复跨章状态清单（{len(state_track.splitlines())} 行）")

    # ===== Phase 1：总规划官 =====
    if not outline:
        print("=" * 60)
        print("[Planner] 规划全书大纲...")
        print("=" * 60)
        text = llm_call(PLANNER, PLANNER_SYS, planning_prompt_idea(args.total_words))
        outline = parse_json_from_llm(text)
        if not outline or not outline.get("chapter_outlines"):
            print(f"[ERROR] 大纲规划失败：{(text or '')[:300]}")
            sys.exit(1)
        append_state(args.output, "outline", outline)
        title = outline.get("title", "未命名")
        print(f"[OK]《{title}》共 {len(outline['chapter_outlines'])} 章")
    else:
        title = outline.get("title", "未命名")
        print(f"[RESUME]《{title}》已有 {len(state['chapters'])} 章，继续")

    chars = outline.get("chapter_outlines", [])
    total_words = sum(count_words(c.get("content", "")) for c in state["chapters"])
    existing_idx = {c["idx"] for c in state["chapters"]}
    last_summary = ""
    if state["chapters"]:
        last_content = state["chapters"][-1].get("content", "")
        last_summary = last_content[-200:] if len(last_content) > 200 else last_content

    # ===== Phase 2：逐章多角色协作 =====
    for ch in chars:
        idx = ch["idx"]
        if idx in existing_idx:
            continue
        if total_words >= args.total_words:
            print(f"\n[DONE] 达成目标字数 {total_words} >= {args.total_words}")
            break
        if idx > args.max_chapters:
            break

        chapter_title = ch.get("title", f"第{idx}章")
        goal = ch.get("goal", "")
        target = ch.get("target", 3000)
        print(f"\n{'=' * 60}\n[CH {idx}] {chapter_title}（目标 {target} 字）\n  章纲：{goal}\n{'=' * 60}")

        # 1) 场景规划（planner 链 + 默认骨架兜底），注入跨章状态
        plan = None
        for attempt in range(2):
            raw = call_chain(PLANNER_CHAIN, PLANNER_SYS,
                             scene_planning_prompt(goal, last_summary, state_track),
                             max_tokens=2000)
            plan = parse_json_from_llm(raw)
            if plan and plan.get("scenes"):
                break
        if not plan or not plan.get("scenes"):
            print("  [规划] LLM 场景规划失败，使用默认「起承转合」骨架兜底")
            plan = {"scenes": [
                {"index": 0, "stage": "起", "goal": f"场景铺垫：{goal[:30]}", "beats": [], "targetWords": max(400, int(target * 0.3))},
                {"index": 1, "stage": "承", "goal": "事件推进，冲突升级", "beats": [], "targetWords": max(400, int(target * 0.25))},
                {"index": 2, "stage": "转", "goal": "局势逆转，危机爆发", "beats": [], "targetWords": max(400, int(target * 0.25))},
                {"index": 3, "stage": "合", "goal": "收束本章并埋下钩子", "beats": [], "targetWords": max(400, int(target * 0.2))},
            ]}
        scenes = plan["scenes"]
        print(f"  [规划] {len(scenes)} 场景：{'/'.join(s.get('stage','承') for s in scenes)}")

        # 2) 逐场景正文（writer，带故障转移）
        scene_texts = []
        prev_text = last_summary
        for si, sc in enumerate(scenes):
            stage = sc.get("stage", "承")
            goal_s = sc.get("goal", "")
            beats = sc.get("beats", [])
            tw = sc.get("targetWords", 600)
            print(f"  [场景 {si+1}/{len(scenes)}] {stage}：{goal_s}（目标 {tw} 字）")
            text = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                              scene_prompt(si + 1, len(scenes), stage, goal_s, beats, prev_text, "玄幻", state_track),
                              max_tokens=int(tw * 2.2))
            text = text.strip()
            w = count_words(text)
            print(f"    -> {w} 字")
            if text:
                scene_texts.append(text)
                prev_text = text
            if w < tw * 0.4 and len(text) > 50:
                add = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                                 f"请续写 300 字，承接：\n{text[-100:]}\n\n只输出续写正文：",
                                 max_tokens=600)
                if add.strip():
                    scene_texts.append("\n\n" + add.strip())
            time.sleep(args.chapter_wait)

        full_text = "\n\n".join(scene_texts)
        w = count_words(full_text)
        if w < target * 0.5:
            print(f"  [WARN] 仅 {w} 字，整章续写...")
            add = call_chain(WRITER_CHAIN, SYSTEM_PROMPT,
                             f"请将下面章节内容扩充到 {target} 字以上，保留原意，只输出正文：\n{full_text[:500]}...",
                             max_tokens=int(target * 1.8))
            if add.strip():
                full_text += "\n\n" + add.strip()
                w = count_words(full_text)

        # 3) 去AI味润色（editor）
        edited = call_chain(EDITOR_CHAIN, EDITOR_SYS, editor_prompt(full_text), max_tokens=int(w * 1.6) + 500)
        if edited:
            w_edited = count_words(edited)
            print(f"  [编辑] 润色完成 {w} -> {w_edited} 字（AI味密度对比见质检）")
            final_text = edited
        else:
            print("  [编辑] 润色失败，保留原文")
            final_text = full_text

        # 4) 章节标题（titler）
        t = llm_call(TITLER, TITLER_SYS, titler_prompt(final_text))
        title_ok = t.strip()[:30] if t.strip() else chapter_title
        print(f"  [标题] {title_ok}")

        # 5) 每 5 章一致性审校（verifier，只记录）
        issues = []
        if idx % 5 == 0 and state["chapters"]:
            chap_list = "\n".join(f"第{c['idx']}章《{c.get('title','')}》" for c in state["chapters"][-5:])
            v = llm_call(VERIFIER, VERIFIER_SYS, verifier_prompt(outline, chap_list), max_tokens=1000)
            parsed = parse_json_from_llm(v, repair=False)
            if parsed and parsed.get("issues"):
                issues = parsed["issues"]
                for it in issues:
                    print(f"  [审校] ⚠ 第{it.get('chapter','?')}章 {it.get('type','')}: {it.get('desc','')}")

        # 6) 语义质量评分（每 3 章，verifier）+ 低分自动重写（editor）
        if idx % 3 == 0:
            qr = llm_call(VERIFIER, VERIFIER_SYS, quality_review_prompt(final_text), max_tokens=1000)
            parsed = parse_json_from_llm(qr, repair=False)
            overall, scores, comment = -1, None, ""
            if parsed:
                scores = parsed.get("scores") or {}
                overall = int(parsed.get("overall", -1))
                comment = str(parsed.get("comment", ""))
            if overall >= 0:
                dims = " ".join(f"{k}={v}" for k, v in scores.items()) if scores else "-"
                print(f"  [评分] 第 {idx} 章 综合 {overall} 分（{dims}）{comment}")
                if overall < 55:
                    print(f"  [重写] 第 {idx} 章 {overall} 分 < 55，触发自动重写...")
                    rw = call_chain(EDITOR_CHAIN, EDITOR_SYS,
                                    rewrite_prompt(final_text, comment, scores),
                                    max_tokens=int(w * 1.6) + 500)
                    if rw and len(rw.strip()) > 100:
                        w_old = count_words(final_text)
                        final_text = rw.strip()
                        w = count_words(final_text)
                        issues.append({"chapter": idx, "type": "auto_rewrite",
                                       "desc": f"{overall} 分已自动重写"})
                        print(f"  [重写] 第 {idx} 章 {w_old} 字 -> {w} 字")
                    else:
                        print(f"  [重写] 失败，保留原文")
            else:
                print(f"  [评分] 第 {idx} 章 评分解析失败，跳过（不影响生成）")

        chapter_record = {
            "idx": idx,
            "title": title_ok,
            "content": final_text,
            "words": count_words(final_text),
            "raw_words": w,
            "scenes": len(scenes),
            "issues": issues,
        }
        state["chapters"].append(chapter_record)
        append_state(args.output, "chapter", chapter_record)
        total_words += chapter_record["words"]
        last_summary = final_text[-200:] if len(final_text) > 200 else final_text

        # 7) 跨章状态提取：维护状态清单供下一章写作遵守（失败保留旧状态）
        st = llm_call(VERIFIER, VERIFIER_SYS,
                      state_extract_prompt(final_text, state_track), max_tokens=800)
        if st and st.strip():
            state_track = st.strip()
            save_state_track(args.output, state_track)
            print(f"  [状态] 已更新跨章状态清单（{len(state_track.splitlines())} 行）")
        else:
            print(f"  [状态] 提取失败，保留旧状态")

        print(f"  [完成] 第 {idx} 章：{chapter_record['words']} 字 | 累计 {total_words} 字")

    # ===== Phase 3：质检汇总 =====
    print(f"\n{'=' * 60}\n[QA] 本地规则质检（AI味密度/重复率/节奏/世界观冲突）\n{'=' * 60}")
    report = quality_check(state["chapters"])
    total_conflicts = 0
    for ch in state["chapters"]:
        conflicts = ch.get("_world_conflicts", [])
        total_conflicts += len(conflicts)
        flag = "⚠" if conflicts else "✓"
        hook_flag = "🪝" if ch.get("_has_hook") else "✗无钩"
        open_flag = "⚡" if ch.get("_has_quick_opening", True) else "✗开场慢"
        print(f"  {flag} 第 {ch['idx']} 章：{ch.get('_words',0)} 字｜AI味 {ch.get('_ai_echo_pct',0)}%｜{hook_flag}｜{open_flag}")
    print(f"  世界观冲突：{total_conflicts} 处 | 审校问题：{sum(len(c.get('issues',[])) for c in state['chapters'])} 处")

    # ===== Phase 4：导出 =====
    txt_path = export_txt(args.output, outline.get("title", "未命名"), state["chapters"])
    print(f"\n[OK] 文本输出：{txt_path}")
    print(f"[OK] 总字数：{sum(c.get('words', 0) for c in state['chapters'])}")


if __name__ == "__main__":
    main()
