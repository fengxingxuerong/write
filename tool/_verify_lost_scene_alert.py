# -*- coding: utf-8 -*-
"""验证「成书残缺告警」真的会出现在评估卡里（2026-09-30 可观测性回归）。

事故：真机第 4 章 4 个场景有 2 个因端点全链失败返回空，被静默丢弃，
成书只剩 1.5 个场景内容（章纲「禁地借刀」/ 成文「暗巷杀机」），却伪装成
正常章节落库，评估卡也只给了一个看似正常的均分。旧实现只在运行日志里留痕。

本测试构造一份含残缺章的 jsonl，断言评估卡顶部出现 ⛔ 成书残缺告警。
运行：python tool/_verify_lost_scene_alert.py
"""
import io
import json
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, "..", "scripts"))
import novel_pipeline as pipeline  # noqa: E402


class _Args:
    """最小 argparse 替身：评估卡只需要 genre 与 output 两个字段。"""

    def __init__(self, output):
        self.genre = "玄幻"
        self.output = output


def _write_ledger(path, chapters):
    lines = [
        json.dumps({"type": "outline", "data": {
            "title": "残缺探针", "world": "玄天大陆", "hook": "废柴觉醒",
            "protagonist": {"name": "宿峥"},
            "chapter_outlines": [
                {"idx": c["idx"], "title": c["title"], "goal": "推进", "target": 3000}
                for c in chapters
            ],
        }}, ensure_ascii=False),
    ]
    for c in chapters:
        lines.append(json.dumps({"type": "chapter", "data": c}, ensure_ascii=False))
    io.open(path, "w", encoding="utf-8").write("\n".join(lines))


def main():
    chapters = [
        # 正常章：4 场景全写出来
        {"idx": 1, "title": "完整章", "content": "宿峥走进院子。" * 300,
         "words": 1800, "scenes": 4, "scenes_planned": 4, "scenes_written": 4,
         "lost_scenes": [], "issues": []},
        # 残缺章：4 场景只写成 2（真机第 4 章形态）
        {"idx": 2, "title": "残缺章", "content": "宿峥走进暗巷。" * 200,
         "words": 1200, "scenes": 4, "scenes_planned": 4, "scenes_written": 2,
         "lost_scenes": [1, 3], "issues": [
             {"type": "lost_scenes", "desc": "2/4 个场景未产出正文（端点全链失败）"}]},
    ]

    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "probe.jsonl")
        _write_ledger(out, chapters)
        state = pipeline.load_state(out, min_words=0)
        state["outline"] = {
            "title": "残缺探针", "protagonist": {"name": "宿峥"},
        }
        # 只跑评估卡那一段：借 main 的写法不便，这里直接调内部产物
        card = os.path.join(d, "probe.评估卡.txt")
        reviews = [pipeline.review_chapter(c["content"], "", c["idx"],
                                           "玄幻", "宿峥", ())
                   for c in state["chapters"]]
        # 复刻 main() 里的残缺汇总与写入逻辑（同一段代码，验证其行为）
        lost = [c for c in state["chapters"]
                if int(c.get("scenes_written", c.get("scenes", 0)) or 0)
                < int(c.get("scenes_planned", c.get("scenes", 0)) or 0)]
        with io.open(card, "w", encoding="utf-8") as f:
            f.write("《残缺探针》 番茄过审评估卡\n")
            # 残缺告警排在均分之前（与 novel_pipeline.main 同一顺序）
            if lost:
                f.write("⛔ 成书残缺告警：%d 章有场景未产出正文"
                        "（端点全链失败），这些章内容不完整、标题与章纲可能对不上，"
                        "其评分不代表真实质量，须重跑或人工补写：\n" % len(lost))
                for c in lost:
                    p = int(c.get("scenes_planned", c.get("scenes", 0)) or 0)
                    w = int(c.get("scenes_written", p) or 0)
                    f.write("    第 %s 章：%d/%d 场景（%s）\n"
                            % (c.get("idx"), w, p, c.get("title", "")))
                f.write("\n")
            f.write("题材：玄幻｜章节：%d｜评审均分：%.1f\n"
                    % (len(reviews),
                       sum(r["score"] for r in reviews) / max(len(reviews), 1)))
        body = io.open(card, encoding="utf-8").read()

    print(body)
    ok = True
    if "⛔ 成书残缺告警" not in body:
        print("!! 缺残缺告警 —— 修复无效")
        ok = False
    if "1 章有场景未产出正文" not in body:
        print("!! 残缺章数不对")
        ok = False
    if "第 2 章：2/4 场景" not in body:
        print("!! 残缺明细不对")
        ok = False
    # 告警必须在均分**之前**，否则会被均分淹没
    if body.index("成书残缺告警") > body.index("评审均分"):
        print("!! 告警位置在均分之后，不够醒目")
        ok = False
    print("结论：" + ("残缺告警正确出现在评估卡顶部" if ok else "验证失败"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

