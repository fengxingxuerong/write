#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""关卡4 人物关系张冠李戴检测器（qa_relation.detect_relation_drift）离线回归测试。

为什么补这个（2026-10-11）
--------------------------
`detect_relation_drift`（关卡 4：人物关系张冠李戴）此前**零直接单测**，只在
`run_smoke_gate` 里依赖历史成书产物被间接调用。它防的是「同一人的『父亲』
在不同处指向两个不同人」这类设定崩坏；检测口径一旦被改坏，全量测试仍全绿，
要等下一次跑门禁（需端点配额、耗时数十分钟）才暴露。

本测试用合成输入钉住那些**精妙但极易被误改的口径**，每个都配负样本对照
（防恒真命题）：

- **章内自相矛盾 = high，跨章不一致 = medium**：同一 (关系, 被修饰者) 分组下
  出现 >=2 个不同对象即告警；若这两个对象出现在**同一章**，升级为 high
  （见 test_same_chapter_conflict_high / test_cross_chapter_medium）；
- **一致重复不得告警**：同一对象多次出现（by_value 只有 1 个键）不构成漂移
  （见 test_consistent_repeated_no_alert）；
- **对话里的关系不算断言**：`strip_dialogue` 先剥离对话，叙述层为空即零断言
  （见 test_dialogue_excluded）；
- **副词前后缀剥离**：「当年/如今」等副词叠加前后缀循环剥离后仍能取到干净的
  被修饰者 head（见 test_adverb_prefix_stripped）；
- **head == value 自指跳过**：「X 的父亲是 X」无意义自指不计入（见
  test_self_reference_skipped）；
- **无关正文零误报**（见 test_irrelevant_content_zero）。

全部离线、零 LLM 成本、不依赖 data/ 与 verify-logs/，CI 恒定生效。
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from qa_relation import detect_relation_drift  # noqa: E402


def _chap(idx, *sentences):
    """把若干句子拼成一章正文（重复以凑足叙述样本）。"""
    return (idx, f"第{idx}章", "".join(sentences))


class RelationDriftTest(unittest.TestCase):
    def test_same_chapter_conflict_high(self):
        # 同一章里同一 (父亲, 林啸天) 指向两个不同人 → high
        chapters = [_chap(1,
                          "林啸天的父亲乃是林远山，此人面容冷峻。",
                          "林啸天的父亲乃是林天南，那是另一个名字。")]
        r = detect_relation_drift(chapters)
        self.assertEqual(r["claims"], 2)
        self.assertEqual(len(r["alerts"]), 1)
        a = r["alerts"][0]
        self.assertEqual(a["rel"], "父亲")
        self.assertEqual(a["head"], "林啸天")
        self.assertEqual(a["level"], "high")
        vals = {v["value"] for v in a["values"]}
        self.assertEqual(vals, {"林远山", "林天南"})
        # 章内两对象都在第 1 章
        for v in a["values"]:
            self.assertEqual(v["chapters"], [1])

    def test_cross_chapter_medium(self):
        # 同一 head 在不同章指向不同对象 → medium（非章内矛盾）
        chapters = [
            _chap(1, "林啸天的父亲乃是林远山，冷峻威严。"),
            _chap(2, "林啸天的父亲乃是林天南，另一副模样。"),
        ]
        r = detect_relation_drift(chapters)
        self.assertEqual(r["claims"], 2)
        self.assertEqual(len(r["alerts"]), 1)
        a = r["alerts"][0]
        self.assertEqual(a["head"], "林啸天")
        self.assertEqual(a["level"], "medium")
        by_val = {v["value"]: v["chapters"] for v in a["values"]}
        self.assertEqual(by_val["林远山"], [1])
        self.assertEqual(by_val["林天南"], [2])

    def test_consistent_repeated_no_alert(self):
        # 负样本：同一对象重复出现（by_value 仅 1 键）→ 不得告警
        chapters = [_chap(1,
                          "林啸天的父亲乃是林远山，威严。",
                          "林啸天的父亲乃是林远山，再提一次仍旧。")]
        r = detect_relation_drift(chapters)
        self.assertEqual(r["claims"], 2)
        self.assertEqual(r["alerts"], [])

    def test_p2_sentence_form(self):
        # P2 句式「X 乃是 Y 的父亲」：value=林远山, head=林啸天
        chapters = [_chap(1,
                          "林远山乃是林啸天的父亲，这是众所周知的事。",
                          "林远山乃是林啸天的父亲，众人皆知。")]
        r = detect_relation_drift(chapters)
        # 两句式都指向同一对象 → 一致，不告警，但应被捕获成 2 条断言
        self.assertEqual(r["claims"], 2)
        self.assertEqual(r["alerts"], [])

    def test_dialogue_excluded(self):
        # 负样本：关系表述全在对话里 → strip_dialogue 剥离后零断言
        chapters = [_chap(1,
                          "“林啸天的父亲乃是林天南！”他怒吼道。",
                          "他不再多说，转身离去，夜色渐深。")]
        r = detect_relation_drift(chapters)
        self.assertEqual(r["claims"], 0)
        self.assertEqual(r["alerts"], [])

    def test_adverb_prefix_stripped(self):
        # 「当年/如今」副词前后缀剥离后 head 仍归一为「林啸天」→ 章内 high
        chapters = [_chap(1,
                          "当年林啸天的父亲乃是林远山。",
                          "如今林啸天的父亲乃是林天南。")]
        r = detect_relation_drift(chapters)
        self.assertEqual(len(r["alerts"]), 1)
        a = r["alerts"][0]
        self.assertEqual(a["head"], "林啸天")
        self.assertEqual(a["level"], "high")

    def test_self_reference_skipped(self):
        # 负样本：head == value 自指 → 跳过，不计入断言
        chapters = [_chap(1, "林啸天的父亲乃是林啸天，无意义自指。")]
        r = detect_relation_drift(chapters)
        self.assertEqual(r["claims"], 0)
        self.assertEqual(r["alerts"], [])

    def test_irrelevant_content_zero(self):
        # 负样本：无关正文 → 零误报
        chapters = [_chap(1, "今天天气很好，他出门去集市买了些蔬菜水果回家做饭。")]
        r = detect_relation_drift(chapters)
        self.assertEqual(r["claims"], 0)
        self.assertEqual(r["alerts"], [])

    def test_values_sorted_by_count(self):
        # values 按 count 降序：count 大的排前面
        chapters = [_chap(1,
                          "林啸天的父亲乃是林天南。",
                          "林啸天的父亲乃是林天南，再说。",
                          "林啸天的父亲乃是林远山。")]
        r = detect_relation_drift(chapters)
        self.assertEqual(len(r["alerts"]), 1)
        values = r["alerts"][0]["values"]
        self.assertEqual(values[0]["value"], "林天南")  # count=2 排前
        self.assertEqual(values[0]["count"], 2)
        self.assertEqual(values[1]["count"], 1)

    def test_alerts_high_before_medium(self):
        # 多个告警时 high 排在 medium 前
        chapters = [
            _chap(1,
                  "林啸天的父亲乃是林远山。",
                  "林啸天的父亲乃是林天南，章内矛盾。"),      # (父亲,林啸天) high
            _chap(2, "苏浅浅的母亲乃是苏夫人。"),
            _chap(3, "苏浅浅的母亲乃是苏姨娘，跨章不一致。"),   # (母亲,苏浅浅) medium
        ]
        r = detect_relation_drift(chapters)
        self.assertGreaterEqual(len(r["alerts"]), 2)
        # 第一条必为 high
        self.assertEqual(r["alerts"][0]["level"], "high")
        levels = [a["level"] for a in r["alerts"]]
        self.assertEqual(levels, sorted(levels, key=lambda x: x != "high"))


if __name__ == "__main__":
    unittest.main()
