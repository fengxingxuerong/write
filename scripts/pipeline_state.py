#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""断点续传状态读取层：从进度 jsonl 回放状态（纯 I/O，无网络）。

2026-10-10 从 novel_pipeline.py 拆出。本模块只负责「把进度文件读回内存」：
读者官反馈 / 逐章评审 / 终审打回补丁 / 跨章状态清单。落盘（append_state /
save_state_track / save_foreshadow）仍在 novel_pipeline 与 foreshadow.py。

对外接口：调用方仍从 novel_pipeline 取同名转发。拆分红线同 pipeline_llm：
只降维护成本，不改对外契约，函数体逐字搬运。
"""
import json
import os


def load_reader_feedback(path):
    """续传恢复：取最后一条 type=reader_feedback 记录的反馈文本（无则空串）。"""
    if not os.path.exists(path):
        return ""
    fb = ""
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "reader_feedback":
                d = rec.get("data", {})
                if isinstance(d, dict):
                    fb = str(d.get("feedback", ""))
    return fb


def load_reviews_from_jsonl(path):
    """续传恢复：从 jsonl 的 type=review 记录重建 reviews（每章 last-wins，全字段透传）。

    旧格式记录只存 idx/score/verdict/problems（缺 redline/words），读取方须用 .get() 兜底；
    新格式存完整 rv dict。
    """
    out = {}
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "review":
                d = rec.get("data", {})
                if isinstance(d, dict) and d.get("idx") is not None:
                    out[d["idx"]] = d
            elif rec.get("type") == "chief_rewrite":
                # 打回重写的复审分覆盖旧评审（last-wins）：live 路径在打回时已同步
                # reviews[ri]，续传路径此前只恢复内容不恢复分数，评估卡/终审会拿旧分
                d = rec.get("data", {})
                if isinstance(d, dict) and d.get("idx") is not None and d.get("rescore") is not None:
                    cur = out.get(d["idx"])
                    if isinstance(cur, dict):
                        cur["score"] = d["rescore"]
                    else:
                        out[d["idx"]] = {"idx": d["idx"], "score": d["rescore"],
                                         "verdict": "重写复审", "words": d.get("words"),
                                         "problems": []}
    return [out[k] for k in sorted(out)]


def apply_chief_rewrites(path, state):
    """续传恢复：回放 type=chief_rewrite 补丁（同章 last-wins），保证重写内容不因断点丢失。"""
    if not os.path.exists(path):
        return 0
    patches = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "chief_rewrite":
                d = rec.get("data", {})
                patches[d.get("idx")] = d
    n = 0
    for ch in state.get("chapters", []):
        p = patches.get(ch.get("idx"))
        if p and p.get("content"):
            ch["content"] = p["content"]
            ch["words"] = p.get("words", ch.get("words", 0))
            if p.get("has_hook") is not None:
                ch["_has_hook"] = p["has_hook"]
            n += 1
    return n


def load_state_track(path):
    """从进度文件恢复跨章状态清单（无则返回空串）。"""
    if not os.path.exists(path):
        return ""
    latest = ""
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
                # 同名状态记录按最后一条恢复，避免续跑回退到第一章状态。
                latest = rec.get("data", "")
    return latest
