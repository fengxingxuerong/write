#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""番茄评审 · 文本基础工具层：字数 / 句 / 段 / 对白占比 / 章切分。

2026-10-10 从 fanqie_review.py 拆出（同批还有 fanqie_metrics / fanqie_world）。
纯本地计算，无词表依赖、不触网、不调 LLM。

对外接口：调用方仍从 fanqie_review 取同名转发（见该文件 import 处）。
⚠ 拆分红线：只降低维护成本，不改对外契约；函数体逐字搬运，未改写。
"""
import io
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


CHAPTER_RE = re.compile(r"^第\s*(\d+)\s*章")


SENT_SPLIT = re.compile(r"[。！？…；]+")


CHAR_RE = re.compile(r"[\u4e00-\u9fff]")


def count_words(text):
    """正文字数（唯一口径，与 Dart `AppConstants.countWords` 逐字符等价）。

    2026-09-29 收敛：此前仓库里有**三套**互不相同的实现——本函数只数 CJK 基本区，
    `generate_novel.count_words` 少算扩展A且把数字单独计词，Dart 版又多算扩展A。
    三处都自称「同口径」，实测同一本书两端差 0.028%（正文）/ 最多 20%（评估卡等
    ASCII 密集的报表）。现统一到 Dart 版，理由：
      1. **对用户零可见变化**——Dart 是界面显示的那一套，改它才会动用户看到的字数；
         改 Python 只是让流水线口径向界面对齐；
      2. Dart 版**含 CJK 扩展A**（㐀-䶿一类生僻字），语义上更正确；
      3. 数字与字母连续算一个词（MVP2024=1）符合中英混排的直觉。

    依赖方向：本模块是 `generate_novel` 的下层（后者 import 本模块），故**唯一定义
    放这里**，`generate_novel.count_words` 改为薄转发，杜绝双份实现再次漂移。
    """
    if not text:
        return 0
    count = 0
    in_ascii = False
    for ch in text:
        r = ord(ch)
        # CJK 统一表意文字（基本区 + 扩展A + 兼容区）：每字计 1。
        if (0x3400 <= r <= 0x4DBF or 0x4E00 <= r <= 0x9FFF
                or 0xF900 <= r <= 0xFAFF):
            count += 1
            in_ascii = False
        # ASCII 字母或数字：连续成一个词，计 1。
        elif (0x41 <= r <= 0x5A or 0x61 <= r <= 0x7A
              or 0x30 <= r <= 0x39):
            if not in_ascii:
                count += 1
                in_ascii = True
        else:
            in_ascii = False
    return count


def sentences(text):
    return [s.strip() for s in SENT_SPLIT.split(text) if s.strip()]


def paragraphs(text):
    return [p.strip() for p in (text or "").split("\n") if p.strip()]


QUOTE_RE = re.compile(r"[“\"『「]([^”\"』」]{1,200})[”\"』」]")


def dialogue_ratio(text):
    """引号内字数占比。"""
    quoted = "".join(QUOTE_RE.findall(text or ""))
    total = max(count_words(text or ""), 1)
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
