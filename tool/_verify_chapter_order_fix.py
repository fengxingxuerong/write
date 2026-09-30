# -*- coding: utf-8 -*-
"""用真机 12.6 万字长篇验证章序修复（一次性验证脚本）。

事故：真机 33 章长篇导出的 txt 物理顺序错乱
  1..9, 12,13,14,15,16,17, 10,11, 18,19, 22,24,25,27,28,30,31,32,33, 20,21,23,26,29
根因：load_state 按 jsonl 行物理顺序 append，而断点续跑时缺章是在已有章之后
补写的 → 物理顺序 ≠ 章序。修复：load 出口按 idx 升序排序。

运行：python tool/_verify_chapter_order_fix.py
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, "..", "scripts"))
from generate_novel import load_state, export_txt  # noqa: E402

LEDGER = os.path.join(ROOT, "..", "data", "generated", "novel_10w_pipeline.jsonl")


def physical_order(path):
    """按 jsonl 行的物理顺序读出章节 idx（未排序，= 修复前的行为）。"""
    order = []
    seen = set()
    with io.open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                import json
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") != "chapter":
                continue
            d = rec.get("data") or {}
            idx = d.get("idx")
            if isinstance(idx, int) and idx not in seen:
                seen.add(idx)
                order.append(idx)
    return order


def main():
    if not os.path.exists(LEDGER):
        print("!! 真机账本缺失：%s" % LEDGER)
        return 1

    before = physical_order(LEDGER)
    print("修复前（jsonl 物理顺序，%d 章）：" % len(before))
    print("  " + ",".join(str(i) for i in before))
    disorder_before = before != sorted(before)
    print("  是否乱序：%s" % ("是" if disorder_before else "否"))

    # 走修复后的 load_state
    state = load_state(LEDGER, min_words=0)
    after = [c["idx"] for c in state["chapters"]]
    print("")
    print("修复后（load_state 输出，%d 章）：" % len(after))
    print("  " + ",".join(str(i) for i in after))
    ok_sorted = after == sorted(after)
    print("  是否升序：%s" % ("是" if ok_sorted else "否"))

    if not disorder_before:
        print("")
        print("注意：本次账本物理顺序本就是升序，修复无可见效果")
        return 0

    if not ok_sorted:
        print("")
        print("结论：仍未排序 —— 修复无效")
        return 1

    # 导出成书，验证 txt 里的章节顺序
    out_dir = os.path.join(ROOT, "..", "verify-logs")
    os.makedirs(out_dir, exist_ok=True)
    probe = os.path.join(out_dir, "_chapter_order_probe.jsonl")
    txt = export_txt(probe, "顺序探针", state["chapters"])
    with io.open(txt, encoding="utf-8") as f:
        body = f.read()
    txt_order = [int(m) for m in re.findall(r"^第 (\d+) 章", body, re.M)]
    print("")
    print("导出 txt 章节顺序（%d 章）：" % len(txt_order))
    print("  " + ",".join(str(i) for i in txt_order[:40]))
    txt_ok = txt_order == sorted(txt_order)
    print("  是否升序：%s" % ("是" if txt_ok else "否"))

    try:
        os.remove(txt)
        os.remove(probe)
    except OSError:
        pass

    if not txt_ok:
        print("")
        print("结论：导出仍乱序 —— 修复未生效")
        return 1
    print("")
    print("结论：load 与导出两端均已按 idx 升序（%d 章）" % len(after))
    return 0


if __name__ == "__main__":
    sys.exit(main())

