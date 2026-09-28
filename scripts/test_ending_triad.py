#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""章末三件套收尾检测 + 钩子降级（检测矛盾修正）的离线回归测试。"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fanqie_review import (  # noqa: E402
    ending_ev_fragment,
    ending_triad,
    fix_prompt,
    review_chapter,
)
from generate_novel import has_ending_hook, quality_check  # noqa: E402

# 中性填充：不含钩子词、不含三件套词（与 release 校准同一套路）
FILLER = "他数着砖缝，一共三百二十一道。"


class EndingTriadTest(unittest.TestCase):
    """ending_triad：末 60 字收束窗口 + 规则 20 词表。"""

    def test_final_sentence_hit(self):
        self.assertEqual(ending_triad("他摊开手一看，掌心发烫。"), "发烫")

    def test_hit_outside_window(self):
        # 三件套出现在窗口（60 字）之外 → 不算收尾违规
        text = "掌心发烫。" + FILLER * 12
        self.assertEqual(ending_triad(text), "")

    def test_mid_text_not_flagged(self):
        # 正文中段的身体异动是 POWER_SURGE 正常通道，只看收尾位置
        text = "掌心发烫，他继续赶路。" + FILLER * 12 + "他推开门，屋里空无一人。"
        self.assertEqual(ending_triad(text), "")

    def test_sky_dawn_excluded(self):
        # 「天亮了」是时间过渡，不是发光物件收束
        self.assertEqual(ending_triad("他收剑回鞘，天亮了。"), "")

    def test_object_lit_counts(self):
        self.assertEqual(ending_triad("他摊开手，玉符亮了。"), "亮了")

    def test_long_form_preferred(self):
        # 长词在前：命中「亮了起来」而非拆出的「亮了」
        self.assertEqual(ending_triad("他摊开手，玉符亮了起来。"), "亮了起来")

    def test_clean_ending(self):
        self.assertEqual(ending_triad("他推开门，屋里空无一人。"), "")

    def test_empty_text(self):
        self.assertEqual(ending_triad(""), "")


class HookTriadDowngradeTest(unittest.TestCase):
    """has_ending_hook：三件套唯一信号不算钩（检测矛盾修正）。"""

    def test_sole_triad_signal_is_not_hook(self):
        text = FILLER * 8 + "掌心发烫。"
        self.assertFalse(has_ending_hook(text))

    def test_triad_plus_real_hook_still_hook(self):
        text = FILLER * 8 + "掌心发烫，脚步声骤然逼近。"
        self.assertTrue(has_ending_hook(text))

    def test_triad_plus_question_still_hook(self):
        # 问号悬念通道独立于三件套降级
        text = FILLER * 8 + "掌心发烫，是谁？"
        self.assertTrue(has_ending_hook(text))

    def test_normal_hook_unchanged(self):
        text = FILLER * 8 + "就在这时，门外传来一阵脚步声。"
        self.assertTrue(has_ending_hook(text))

    def test_no_signal_is_not_hook(self):
        text = FILLER * 10
        self.assertFalse(has_ending_hook(text))


class EndingEvidenceAndReviewTest(unittest.TestCase):
    """证据串 + 评审问题 + 质检字段的闭环接线。"""

    def test_ev_fragment_hit_and_clean(self):
        hit = ending_ev_fragment("他摊开手一看，掌心发烫。")
        self.assertIn("三件套命中", hit)
        self.assertIn("发烫", hit)
        clean = ending_ev_fragment("他推开门，屋里空无一人。")
        self.assertIn("未见三件套", clean)

    def test_review_chapter_reports_ending_problem(self):
        # 三件套收尾 + 字数不足 → 收尾（修改）与结构（重写）并存
        text = FILLER * 40 + "掌心发烫。"
        row = review_chapter(text, has_hook=has_ending_hook(text))
        types = [p["type"] for p in row["problems"]]
        self.assertIn("收尾", types)
        self.assertIn("钩子", types)  # 唯一尾钩信号是三件套 → 已降级为无钩
        ending_probs = [p for p in row["problems"] if p["type"] == "收尾"]
        self.assertEqual(ending_probs[0]["action"], "修改")
        self.assertIn("规则20", ending_probs[0]["msg"])

    def test_fix_prompt_carries_ending_problem(self):
        review = {
            "score": 50,
            "verdict": "需修",
            "problems": [
                {"type": "收尾", "msg": "章末三件套收尾：以「发烫」收束", "action": "修改"},
            ],
            "redline": {"veto": [], "warn": []},
            "blockers": ["收尾"],
        }
        prompt = fix_prompt(review, "正文", ())
        self.assertIn("收尾", prompt)
        self.assertIn("发烫", prompt)

    def test_quality_check_records_ending_triad(self):
        content = FILLER * 40 + "掌心发烫。"
        chapters = [{"idx": 1, "content": content}]
        report = quality_check(chapters)
        self.assertEqual(report[0]["ending_triad"], "发烫")
        self.assertEqual(chapters[0]["_ending_triad"], "发烫")


if __name__ == "__main__":
    unittest.main()
