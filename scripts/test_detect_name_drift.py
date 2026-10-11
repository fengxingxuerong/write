#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""qa_names.detect_name_drift 的离线回归测试。

为什么补这个（2026-10-11）：
--------------------------
`detect_name_drift`（147 行）是关卡2「主角称谓漂移」的核心，三条信号
（S1 占位称呼 / S2 主角级簇区间不重叠 / S2' 占位→裸名接管）+ 每章活跃簇。
此前模块层面无任何直接单测——它只在 qa_scan_existing / run_smoke_gate 里被
间接调用，而那两个门禁依赖**历史成书产物**。后果同 test_semantic_check 头部
记录的教训：检测逻辑被改坏时，全量测试仍绿，要等下次跑门禁（需端点配额、
约 1 小时）才暴露，且很难定位是哪次改动引入的。

本测试锁死的是那些**易被改坏的设计**（每条都配负样本对照，确保断言不是
「怎么都绿」的恒真命题——这是本仓库一贯要求）：

- S1 占位称呼按**簇级合计 ≥2** 才提示（单次「姓X的」是长书路人群像，不报警）；
- S2 只对**频次 top2 且章覆盖 ≥0.3** 的主角级簇做区间比较，且重叠率 <0.15 才报警；
  单一稳定主角名（只 1 个簇）不得触发任何区间报警（负样本）；
- confidence 只在 span/takeover 报警时升高，**占位称呼单独不升**（负样本）；
- expected_protagonist 正确算出「更响的对手」（频次高于预期主角的簇）。

全部离线、零 LLM、零端点，CI 稳定生效。合成数据（不依赖 data/）。
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import qa_names as qn  # noqa: E402


def _ch(idx, title, content):
    """构造 (idx, title, content) 三元组（检测器统一吃这个形状）。"""
    return (idx, title, content)


def _name_block(name, n, verb="走"):
    """生成 name 后接动作动词、重复 n 次的正文段。

    `discover_names` 靠「姓 + 动作/说话动词」正向上下文识名，纯裸名堆叠
    不触发识别——这里每次都给名配一个动词，模拟真实正文。
    """
    return (f"{name}{verb}了过来。\n") * n


class DetectNameDriftTest(unittest.TestCase):
    def test_empty_chapters_returns_empty_structure(self):
        """空输入：返回结构完整，所有信号为空、置信度 none（不得崩）。"""
        r = qn.detect_name_drift([])
        self.assertEqual(
            sorted(r.keys()),
            sorted(["confidence", "placeholders", "span_alerts",
                    "takeover_alerts", "clusters", "per_chapter",
                    "expected_protagonist"]),
        )
        self.assertEqual(r["confidence"], "none")
        self.assertEqual(r["placeholders"], [])
        self.assertEqual(r["span_alerts"], [])
        self.assertEqual(r["takeover_alerts"], [])
        self.assertEqual(r["per_chapter"], [])

    def test_placeholder_signal_clusters_by_surname(self):
        """S1：'姓苏的' 多次出现 → 归入 '苏' 簇提示，count=累计次数。"""
        text = ("姓苏的男子走了过来，他停下脚步。\n") * 6
        r = qn.detect_name_drift([_ch(1, "t", text)])
        self.assertEqual(len(r["placeholders"]), 1)
        ph = r["placeholders"][0]
        self.assertEqual(ph["cluster"], "苏")
        self.assertEqual(ph["count"], 6)
        self.assertIn("姓苏的×6", ph["names"])

    def test_single_placeholder_below_threshold_not_reported(self):
        """S1 负样本：单次占位称呼（簇级合计 <2）不得提示（路人群像不报警）。"""
        text = "姓苏的男子走了过来，他只露了一面便消失了。\n"
        r = qn.detect_name_drift([_ch(1, "t", text)])
        self.assertEqual(r["placeholders"], [])

    def test_placeholder_alone_does_not_raise_confidence(self):
        """置信度负样本：只有占位称呼、无区间/接管报警时 confidence 仍为 none。"""
        text = ("姓苏的男子走了过来。\n") * 6
        r = qn.detect_name_drift([_ch(1, "t", text)])
        self.assertTrue(r["placeholders"])          # 占位称呼确实在
        self.assertEqual(r["span_alerts"], [])
        self.assertEqual(r["takeover_alerts"], [])
        self.assertEqual(r["confidence"], "none")   # 但不因此升置信度

    def test_stable_single_name_no_span_alert(self):
        """S2 负样本：全书只有一个稳定主角名 → 无区间对可比，span_alerts 空。"""
        text = _name_block("林啸", 12)
        r = qn.detect_name_drift([_ch(1, "t", text)])
        self.assertIn("林", r["clusters"])
        self.assertEqual(r["span_alerts"], [])
        self.assertEqual(r["confidence"], "none")

    def test_disjoint_names_trigger_span_alert(self):
        """S2：两个主角级名（林/裴）区间完全不重叠 → 触发区间报警，置信度升 medium。"""
        ch1 = _name_block("林啸", 12)
        ch2 = _name_block("裴照", 12)
        r = qn.detect_name_drift([_ch(1, "t1", ch1), _ch(2, "t2", ch2)])
        self.assertEqual(r["clusters"].get("林", {}).get("total"), 12)
        self.assertEqual(r["clusters"].get("裴", {}).get("total"), 12)
        self.assertEqual(len(r["span_alerts"]), 1)
        alert = r["span_alerts"][0]
        self.assertEqual({alert["cluster_a"], alert["cluster_b"]}, {"林", "裴"})
        self.assertEqual(alert["overlap_ratio"], 0.0)
        # 两个名分居全书首尾：一个 span 靠前、一个靠后
        spans = sorted([alert["span_a"], alert["span_b"]], key=lambda s: s[0])
        self.assertLess(spans[0][1], spans[1][0])
        self.assertEqual(r["confidence"], "medium")  # 无占位称呼 → medium

    def test_expected_protagonist_reports_louder_rival(self):
        """expected_protagonist：预期主角频次被另一簇超过 → louder_rivals 列出对手。"""
        text = _name_block("林啸", 6) + _name_block("裴照", 12)
        r = qn.detect_name_drift([_ch(1, "t", text)], expected_protagonist="林啸")
        info = r["expected_protagonist"]
        self.assertEqual(info["name"], "林啸")
        self.assertEqual(info["cluster_total"], 6)
        # 裴照频次 12 > 林啸 6，应被列为「更响的对手」
        self.assertIn(("裴", 12), info["louder_rivals"])

    def test_per_chapter_lists_top_clusters(self):
        """S3：每章活跃簇表按章给出，章数与输入一致。"""
        r = qn.detect_name_drift([
            _ch(1, "t1", _name_block("林啸", 6)),
            _ch(2, "t2", _name_block("裴照", 6)),
        ])
        self.assertEqual([pc["idx"] for pc in r["per_chapter"]], [1, 2])
        # 每章应至少识别出该章的簇
        self.assertTrue(r["per_chapter"][0]["top_clusters"])
        self.assertTrue(r["per_chapter"][1]["top_clusters"])


if __name__ == "__main__":
    unittest.main()
