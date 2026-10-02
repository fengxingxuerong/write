#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""伏笔台账（foreshadow ledger）：长篇不丢伏笔的核心机制。

2026-10-03 从 novel_pipeline.py 拆出（该文件已 2341 行，属「上帝文件」，

改一处判据要上下翻找、review 成本高）。本模块只依赖标准库 os/json，

不含 LLM 调用与流水线状态，可独立单测。

对外接口（调用方仍从 novel_pipeline 取同名转发，见该文件 import 处）：
  foreshadow_extract_prompt / load_foreshadow / save_foreshadow
  check_open_foreshadows / scan_used_protagonist_names / save_state_track

注意：save_state_track 严格说属「跨章状态清单」而非伏笔台账，但两者都是

「长篇连续性账本」且同属 jsonl 断点续传的一对存取，故一并归入本模块。
"""
import json
import os


# ============================================================
# 伏笔台账（foreshadow ledger）：长篇不丢伏笔的核心机制
# ============================================================
def foreshadow_extract_prompt(text, prev_ledger, idx):
    """从本章内容提取/更新伏笔台账。prev_ledger 为既有台账（JSON 字符串）。
    输出严格 JSON：{"foreshadows":[{"desc":"伏笔描述","planted":埋设章号,"recovered":回收章号或null,"status":"open/closed"}]}
    仅记录「明确埋下且预期后文回收」的设定级伏笔（神秘物件/预言/身份谜团/异常现象），
    不记录普通对话、氛围描写。"""
    prev = prev_ledger if prev_ledger and prev_ledger.strip() else "[]"
    return f"""你是长篇小说伏笔管理员。请根据本章内容（第 {idx} 章），维护一份「伏笔台账」，防止长篇写作丢伏笔/改设定。

只记录设定级伏笔（后文必须回收的）：
- 神秘物件/信物（银鱼/断剑/古玉等）及其来源谜团
- 预言/警告/神秘声音（"记住这个形状"类）
- 身份谜团（某人真实身份/来历）
- 异常现象（异象/异动/神秘组织行动）
- 角色承诺/恩怨（欠债/血仇/约定）

规则：
1. 本章新埋的伏笔 → 新增条目（planted=当前章号, status=open）
2. 本章回收/揭晓的伏笔 → 对应条目标 recovered=当前章号, status=closed
3. 在旧台账基础上增删改，不要重写无关条目
4. 只输出 JSON 数组文本（不要 Markdown），格式：
{{"foreshadows":[{{"desc":"伏笔描述（一句话）","planted":1,"recovered":null,"status":"open"}}]}}

【旧台账】
{prev}

【本章内容】
{text}"""


def load_foreshadow(path):
    """从进度文件恢复伏笔台账（JSON 字符串，无则返回 '[]'）。"""
    if not os.path.exists(path):
        return "[]"
    latest = "[]"
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "foreshadow":
                # 伏笔台账按最后一条恢复，避免续跑使用早期未完成台账。
                latest = rec.get("data", "[]")
    return latest


def save_foreshadow(path, data):
    """持久化伏笔台账（type=foreshadow 行）。"""
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps({"type": "foreshadow", "data": data}, ensure_ascii=False) + "\n")
    except Exception as exc:
        print(f"  [WARN] 伏笔台账保存失败：{exc}")


def check_open_foreshadows(ledger_json, cur_idx, stale_after=5):
    """检查超时未回收伏笔：埋设超过 stale_after 章仍未回收的伏笔，返回告警列表。"""
    if not ledger_json or ledger_json.strip() == "[]":
        return []
    try:
        data = json.loads(ledger_json)
        items = data.get("foreshadows", []) if isinstance(data, dict) else data
    except Exception:
        return []
    warnings = []
    for it in items:
        if not isinstance(it, dict):
            continue
        if it.get("status") == "open" and it.get("recovered") is None:
            planted = it.get("planted", cur_idx)
            age = cur_idx - planted
            if age >= stale_after:
                warnings.append(f"⚠ 伏笔超时未收（已{age}章）：{it.get('desc','?')}（埋于第{planted}章）")
    return warnings


def scan_used_protagonist_names(glob_dir="D:/novel-writer/data/generated"):
    """扫描既有 jsonl 大纲，收集已用主角名（跨书查重，防规划官惯性起名）。
    扫描范围：data/generated/ + scripts/（test_quality 等验证书也曾撞名——
    《焚骨逆天诀》裴烬在 scripts/test_quality.jsonl，漏扫导致《断脉逆命诀》再次撞名裴烬）。
    返回已用名单列表；扫描失败返回空列表（不影响生成）。"""
    used = []
    scan_dirs = [glob_dir, os.path.join(os.path.dirname(os.path.abspath(__file__)))]
    for scan_dir in scan_dirs:
        try:
            if not os.path.isdir(scan_dir):
                continue
            for fn in os.listdir(scan_dir):
                if not fn.endswith(".jsonl"):
                    continue
                p = os.path.join(scan_dir, fn)
                try:
                    with open(p, encoding="utf-8") as f:
                        for line in f:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                rec = json.loads(line)
                            except Exception:
                                continue
                            if rec.get("type") != "outline":
                                continue
                            outline = rec.get("data") or {}
                            if isinstance(outline, str):
                                try:
                                    outline = json.loads(outline)
                                except Exception:
                                    continue
                            pobj = outline.get("protagonist")
                            if isinstance(pobj, dict) and pobj.get("name"):
                                used.append(pobj["name"])
                except Exception:
                    continue
        except Exception:
            continue
    # 去重保序
    seen = set()
    uniq = []
    for n in used:
        if n and n not in seen:
            seen.add(n)
            uniq.append(n)
    return uniq


def save_state_track(path, data):
    """追加跨章状态清单到进度文件。"""
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps({"type": "state_track", "data": data}, ensure_ascii=False) + "\n")

