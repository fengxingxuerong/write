#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""qa_scan_existing 签约可行性报告的离线回归测试（纯本地，不发起网络请求）。

背景：qa_scan_existing.py 此前**完全无测试覆盖**。compute_signability 是从
print_signability_report 拆出的纯计算函数（2026-10-11），本测试锁定其打分
口径与硬伤判定——报告文本可随意调整，但口径一旦漂移必须能离线回归。
"""
import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qa_scan_existing as q  # noqa: E402


def _row(idx, thrill=2.0, surge=1.5, echo=0.2, hook=True, opening=True):
    """合成一行扫描结果（字段名与真实 scan 行对齐）。"""
    return {
        "idx": idx,
        "thrill_per_k": thrill,
        "surge_per_k": surge,
        "ai_echo_pct": echo,
        "hook": hook,
        "side_per_k": 0.0,
        "opening": opening,
    }


def _chapters(n=5):
    """合成 n 章正文（爽点/世界观专名齐备，供 golden/dropdown 判定）。"""
    return [
        (i, "第%d章" % i,
         "少年握紧拳头，体内骤然发烫，传承苏醒。他当众打脸了对手，\n"
         "废物受辱的日子一去不返。系统给了他金手指，他一定要变强。\n" * 20)
        for i in range(1, n + 1)
    ]


class ComputeSignabilityTest(unittest.TestCase):
    """compute_signability 纯计算口径回归。"""

    def test_empty_rows_returns_none(self):
        self.assertIsNone(q.compute_signability([], []))

    def test_healthy_book_scores_and_no_hard_flag(self):
        res = q.compute_signability([_row(i) for i in range(1, 6)],
                                    _chapters(5), genre="玄幻")
        self.assertIsNotNone(res)
        self.assertEqual(res["n"], 5)
        self.assertEqual(res["hook_rate"], 1.0)
        self.assertEqual(len(res["dims"]), 5)
        self.assertEqual(res["flags"], [])  # 无硬伤
        # 满分覆盖（钩子30+黄金三章30+爽点20+反AI10+节奏10=100）
        self.assertGreaterEqual(res["possible"], 100)
        # 高分健康书应得正面结论（高潜或可投其一），且非硬伤否决的「不建议」
        self.assertTrue("高潜" in res["verdict"] or "可投" in res["verdict"])

    def test_exempt_genre_skips_thrill_and_pacing(self):
        # 悬疑属非力量幻想题材：爽点密度 / 节奏两维不评（不计分也不送分）
        res = q.compute_signability([_row(i) for i in range(1, 6)],
                                    _chapters(5), genre="悬疑")
        self.assertTrue(res["thrill_exempt"])
        unjudged = [d[0] for d in res["dims"] if d[1] is None]
        self.assertIn("爽点密度", unjudged)
        self.assertIn("节奏", unjudged)

    def test_low_hook_rate_triggers_hard_flag(self):
        # 仅 1/5 章有钩子 → 覆盖率 20% < 80% → 一票否决
        rows = [_row(i, hook=(i == 1)) for i in range(1, 6)]
        res = q.compute_signability(rows, _chapters(5), genre="玄幻")
        self.assertTrue(any("章末钩子覆盖率" in f for f in res["flags"]))
        # 有硬伤时结论不得高于「不建议」，且 notes 载明一票否决
        self.assertIn("不建议", res["verdict"])
        self.assertTrue(any("硬伤一票否决" in nt for nt in res["notes"]))

    def test_too_few_chapters_flag(self):
        # 仅 2 章 → 样本不足 → 硬伤；黄金三章维度不评
        res = q.compute_signability([_row(i) for i in range(1, 3)],
                                    _chapters(2), genre="玄幻")
        self.assertTrue(any("样本不足以判断" in f for f in res["flags"]))
        self.assertFalse(res["g3_judged"])

    def test_high_ai_echo_triggers_flag(self):
        # AI 囷痕密度 ≥ 1% → 硬伤
        rows = [_row(i, echo=1.5) for i in range(1, 6)]
        res = q.compute_signability(rows, _chapters(5), genre="玄幻")
        self.assertTrue(any("AI 囷痕密度" in f for f in res["flags"]))


class PrintSignabilityReportTest(unittest.TestCase):
    """渲染层回归：compute_signability 的拆出不得改变人读报告。"""

    def test_empty_rows_silent(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            q.print_signability_report([], [], genre="玄幻")
        self.assertEqual(buf.getvalue(), "")

    def test_renders_report_sections(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            q.print_signability_report([_row(i) for i in range(1, 6)],
                                       _chapters(5), genre="玄幻")
        out = buf.getvalue()
        self.assertIn("签约可行性报告", out)
        self.assertIn("对标番茄签约要素", out)
        self.assertIn("总分", out)
        self.assertIn("章末钩子", out)  # 五维之一


if __name__ == "__main__":
    unittest.main()
