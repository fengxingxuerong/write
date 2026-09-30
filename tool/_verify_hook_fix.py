# -*- coding: utf-8 -*-
"""用真机产物回归验证 2026-09-30 钩子兜底修复（一次性验证脚本）。

验证：把真机账本 verify_effect.jsonl 里规划官写的钩子原文，直接喂给修好的
local_hook_fallback，确认「类型（说明）」这种大纲标注不再漏进成书正文。

运行：python tool/_verify_hook_fix.py
"""
import io
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
from fanqie_review import local_hook_fallback  # noqa: E402

ROOT = os.path.dirname(os.path.abspath(__file__))
LEDGER = os.path.join(ROOT, "..", "data", "generated", "verify_effect.jsonl")

# 不得出现在正文里的标注痕迹
BANNED = ["威胁逼近", "信息反转", "选择困境", "反常细节", "承诺未兑",
          "主角选择=", "钩子=", "｜", "（", "）"]


def load_hooks():
    """从真机账本里取每章 goal 的钩子原文（复现真机输入形态）。"""
    hooks = []
    with io.open(LEDGER, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            o = json.loads(line)
            if o.get("type") != "outline":
                continue
            for ch in o["data"].get("chapter_outlines", []):
                m = re.search(r"钩子[=＝:：]\s*([^｜|]+)", ch.get("goal", "") or "")
                if m:
                    hooks.append((ch.get("idx"), m.group(1).strip()))
    return hooks


def main():
    hooks = load_hooks()
    print("真机钩子样本：%d 条" % len(hooks))
    if not hooks:
        print("!! 账本里没取到钩子，无法验证")
        return 1

    leaks = 0
    for idx, raw in hooks:
        fb = local_hook_fallback(raw, "宿峥", "玄幻")
        bad = [b for b in BANNED if b in fb]
        if bad:
            leaks += 1
        print("  [%s] 第%s章" % ("LEAK" if bad else "OK  ", idx))
        print("        raw = %s" % raw)
        print("        fb  = %s" % (fb if fb else "(放弃兜底，保留原文)"))
        if bad:
            print("        !! 泄漏标注: %s" % bad)

    print("")
    if leaks:
        print("结论：仍有 %d 条泄漏 —— 修复无效" % leaks)
        return 1
    print("结论：%d 条真机钩子全部无标注泄漏" % len(hooks))

    # 冒烟：括号后带句号 + 内层引号含冒号（Dart 侧有同名回归用例，双端须同口径）
    tricky = "选择困境（执事临走冷笑：'拔擢试上，你会死得很难看'，而血誓倒计时只剩九十天）。"
    out = local_hook_fallback(tricky, "宿峥", "玄幻")
    if "）" in out or "选择困境" in out:
        print("!! 冒烟失败：%s" % out)
        return 1
    print("冒烟（真机第 3 章形态）：OK  ->  %s" % out)

    # 冒烟：剥壳后残留大纲分隔符 → 必须放弃兜底
    if local_hook_fallback("威胁逼近（宿峥＝必须藏钱）", "宿峥", "玄幻") != "":
        print("!! 冒烟失败：带分隔符的脏素材未被拒")
        return 1
    print("冒烟（脏素材放弃兜底）：OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
