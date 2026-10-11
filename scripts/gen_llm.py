#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""通用流式 LLM 调用 + JSON 解析层：OpenAI 兼容 SSE，无写作判据、无流水线状态。

2026-10-10 从 generate_novel.py 拆出（同批还有 gen_quality）。本模块只负责
「把请求发出去、把返回的文本解析成 JSON」，不含题材/质检逻辑；导入本模块不触网。

对外接口：调用方仍从 generate_novel 取同名转发（见该文件 import 处）。
⚠ 拆分红线：只降低维护成本，不改对外契约；函数体逐字搬运，未改写。
"""
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request

# 与 generate_novel 同款：强制 print 实时刷新（长跑日志不被缓冲吞掉）
_real_print = print


def print(*args, **kwargs):
    kwargs.setdefault("flush", True)
    _real_print(*args, **kwargs)


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def is_reasoning_model(model):
    """判断模型是否需要额外的 options.Thinking 参数。"""
    m = model.lower().replace("-", "").replace("_", "")
    return "sensenova" in m or "deepseek" in m


def call_llm(base_url, model, system, user, api_key, max_tokens, temperature=0.8,
             retries=3, extra_wait=0, timeout=300):
    """流式调用 OpenAI 兼容 LLM。retries 含 4 次指数退避，额外支持 reasoning 模型 throatle。"""
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": True,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    if is_reasoning_model(model):
        payload["options"] = {"Thinking": False}
    body = json.dumps(payload).encode("utf-8")
    url = base_url.rstrip("/")
    rate_limit_backoff = 0  # 遇 429 退避基数
    for attempt in range(retries + 1):
        try:
            if extra_wait > 0:
                time.sleep(extra_wait)
            req = urllib.request.Request(url, data=body, method="POST")
            req.add_header("Content-Type", "application/json")
            req.add_header("Accept", "text/event-stream")
            if api_key:
                req.add_header("Authorization", f"Bearer {api_key}")
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                chunks = []
                for raw_line in resp:
                    line = raw_line.decode("utf-8").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                        choices = chunk.get("choices")
                        if not choices:
                            continue
                        delta = choices[0].get("delta", {})
                        if delta.get("content"):
                            chunks.append(delta["content"])
                    except Exception:
                        continue
                return "".join(chunks)
        except urllib.error.HTTPError as e:
            body_text = ""
            try:
                body_text = e.read().decode("utf-8", errors="replace")[:300]
            except Exception:
                pass
            if e.code in (429, 500, 502, 503):
                retry_after = None
                try:
                    retry_after = int(e.headers.get("Retry-After", ""))
                except Exception:
                    pass
                # 计算退避：取 Retry-After 与指数退避的较大值，至少等 5s
                backoff = (3 ** (attempt + 1)) * 5 + random.randint(5, 30) + rate_limit_backoff
                if retry_after and retry_after <= 300:
                    wait = max(retry_after, min(backoff, 15))  # 即使 Retry-After 也给个保底
                else:
                    wait = min(300, backoff)
                rate_limit_backoff += 15  # 每次遇 429 多等 15s
                print(f"    [retry {attempt + 1}/{retries + 1}] HTTP {e.code}: {body_text[:150]} (等待 {wait}s, 累计退避 {rate_limit_backoff}s)")
                if attempt < retries:
                    time.sleep(wait)
                    continue
                return ""
            print(f"    [HTTP {e.code}] {body_text}")
            return ""
        except Exception as e:
            wait = min(120, (3 ** attempt) * 5 + random.randint(1, 10))
            print(f"    [retry {attempt + 1}/{retries}] {e} (等待 {wait}s)")
            if attempt < retries:
                time.sleep(wait)
                continue
    print("    [FAILED] ")
    return ""


def repair_json(text):
    """尝试修复截断的 JSON：补全缺失的闭合括号与最后一项。"""
    t = text.strip()
    # 统计开闭括号
    opens = t.count("{")
    closes = t.count("}")
    if opens <= closes:
        return t
    # 在末尾补全缺失的闭合：先闭合可能的字符串/对象，再补 chapter_outlines 数组
    # 去掉末尾不完整的 token（引号后的半截内容）
    t = re.sub(r',\s*"[^"]*$', '', t)  # 最后一项 title/goal 截断
    t = re.sub(r'"[^"]*$', '""', t)     # 某个字符串值未闭合
    # 重新统计
    opens = t.count("{")
    closes = t.count("}")
    # 补 closing
    needed = opens - closes
    # 先闭合最后一个 chapter_outline 对象 → "}]}"
    if t.rstrip().endswith(","):
        t = t.rstrip()[:-1]
    if not t.rstrip().endswith("}"):
        t = t.rstrip() + "\n  }"
    # 再闭合 chapter_outlines 数组和根对象
    t += "\n]\n}" * (1 if needed >= 1 else 0)
    return t


def _sanitize_ctrl(text):
    """把 JSON 字符串值内的裸控制字符（未转义的换行/制表/不可见字符）转义为 \\n \\t \\uXXXX。
    避免 LLM 在字符串里直接换行导致 json.loads 抛 Invalid control character。"""
    out = []
    in_str = False
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"' and (i == 0 or text[i - 1] != '\\'):
            in_str = not in_str
            out.append(c)
        elif in_str:
            o = ord(c)
            if c == '\n':
                out.append('\\n')
            elif c == '\r':
                out.append('\\r')
            elif c == '\t':
                out.append('\\t')
            elif o < 0x20:
                out.append('\\u%04x' % o)
            else:
                out.append(c)
        else:
            out.append(c)
        i += 1
    return ''.join(out)


def parse_json_from_llm(text, repair=True):
    """从 LLM 输出中找出第一个 JSON 对象，支持修复截断 JSON 与字符串内裸控制字符。"""
    if not text:
        return None
    t = text.strip()
    # 去 ```json 包
    t = re.sub(r"```(?:json)?", "", t)
    s = t.find("{")
    d = t.rfind("}")
    if s < 0 or d <= s:
        return None
    # 先清理字符串值内的裸控制字符（LLM 常见违规），再尝试解析
    t_clean = _sanitize_ctrl(t[s:d + 1])
    try:
        result = json.loads(t_clean)
        return result
    except Exception as e:
        if not repair:
            print(f"    [JSON parse error] {e}")
            return None
        # 尝试修复（repair 可能引入新的裸控制字符，再做一次 sanitize）
        try:
            repaired = repair_json(t_clean)
            repaired = _sanitize_ctrl(repaired)
            result = json.loads(repaired)
            print("    [JSON repaired]")
            return result
        except Exception as e2:
            print(f"    [JSON parse error] {e} (repair failed: {e2})")
            visible_nl = '\\n'  # 换行显示为可见标记（f-string 表达式内不能含反斜杠）
            print(f"    [JSON 原文前300]: {t_clean[:300].replace(chr(10), visible_nl)}")
            return None
