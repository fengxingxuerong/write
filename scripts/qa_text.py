#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语义硬伤检测 · 文本基础：对白剥离（供多个关卡复用）。

2026-10-10 从 qa_semantic_check.py 拆出。纯本地规则，不触网。

对外接口：调用方仍从 qa_semantic_check 取同名转发。拆分红线：只降维护成本，
不改对外契约；函数体逐字搬运，未改写。
"""
import re


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
