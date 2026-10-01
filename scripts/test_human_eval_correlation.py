#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""人评相关性工具的回归测试（数学正确性 + 拒绝小样本 + 输入校验）。

为什么值得测：这份工具的输出会用来**改评分权重**（甚至下线指标），
公式错一个并列秩就会给出反向结论。故把 Spearman 的关键性质钉死：
单调 -> 1、反向 -> -1、并列秩 -> 已知数值（手算）、常量输入 -> 0。
"""
import contextlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import human_eval_correlation as hec  # noqa: E402


class SpearmanTest(unittest.TestCase):
    def test_monotone_is_one(self):
        self.assertAlmostEqual(hec.spearman([1, 2, 3, 4], [10, 20, 30, 40]), 1.0, places=9)

    def test_reversed_is_minus_one(self):
        self.assertAlmostEqual(hec.spearman([1, 2, 3, 4], [40, 30, 20, 10]), -1.0, places=9)

    def test_ties_use_average_rank(self):
        # x=[1,2,2,3] 的秩为 [1,2.5,2.5,4]；手算 ρ=4.5/sqrt(4.5*5)=0.9486833…
        self.assertAlmostEqual(hec.spearman([1, 2, 2, 3], [1, 2, 3, 4]), 0.9486833, places=6)

    def test_constant_input_is_zero(self):
        self.assertEqual(hec.spearman([1, 1, 1, 1], [1, 2, 3, 4]), 0.0)

    def test_too_few_points_is_zero(self):
        self.assertEqual(hec.spearman([1, 2], [1, 2]), 0.0)

    def test_permutation_p_is_small_for_strong_signal(self):
        x = [1, 2, 3, 4, 5, 6, 7, 8]
        y = [2, 1, 4, 3, 6, 5, 8, 7]
        p = hec.permutation_p(x, y, hec.spearman(x, y), permutations=500, seed=7)
        self.assertLessEqual(p, 0.05)

    def test_permutation_p_is_large_for_noise(self):
        x = [1, 1, 2, 2, 3, 3]
        y = [3, 1, 2, 3, 1, 2]
        p = hec.permutation_p(x, y, hec.spearman(x, y), permutations=500, seed=7)
        self.assertGreater(p, 0.05)


class VerdictTest(unittest.TestCase):
    def test_strong_positive_keeps(self):
        self.assertEqual(hec.verdict_for(0.7, 0.01)[0], "保留")

    def test_negative_is_downgraded(self):
        # ρ 为负（越“好”越差）必须立刻降权/下线，不能当噪声放过
        self.assertIn(hec.verdict_for(-0.7, 0.01)[0], ("下线/重做", "降权"))

    def test_insignificant_is_retired(self):
        self.assertEqual(hec.verdict_for(0.4, 0.6)[0], "下线/重做")


class MetricsTest(unittest.TestCase):
    def test_metrics_of_returns_expected_keys(self):
        text = ("第一拳砸下去，赵天脸色铁青，说不出话。四周哗然，倒吸一口凉气。\n\n"
                "“怎么可能？”他踉跄后退。系统激活，暖流涌入体内，发烫。\n\n"
                "突然，门外传来脚步声。谁也不知道，那只眼正看着他。")
        m = hec.metrics_of(text)
        for key in ("fanqie_score", "thrill_per_k", "surge_per_k",
                    "side_reaction_per_k", "has_hook", "dialogue_ratio",
                    "filler_percent", "cliche_per_k", "sent_len_avg",
                    "ai_depth_level"):
            self.assertIn(key, m, f"缺少指标 {key}")
            self.assertIsInstance(m[key], float)


class LoadAnnotationsTest(unittest.TestCase):
    def test_skips_comments_and_unscored_lines(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "a.jsonl"
            p.write_text(
                "# 注释行\n"
                + json.dumps({"id": "x", "text": "正文", "human": 80}, ensure_ascii=False)
                + "\n"
                + json.dumps({"id": "y", "text": "未评分"}, ensure_ascii=False)
                + "\n",
                encoding="utf-8")
            items = hec.load_annotations(p)
            self.assertEqual([it[0] for it in items], ["x"])

    def test_rejects_bad_json(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "a.jsonl"
            p.write_text("{不是 JSON}\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                hec.load_annotations(p)

    def test_rejects_missing_file(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(SystemExit):
                hec.load_annotations(Path(d) / "nope.jsonl")


class CliTest(unittest.TestCase):
    def test_refuses_small_sample_with_exit_code_2(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "a.jsonl"
            p.write_text("\n".join(
                json.dumps({"id": f"c{i}", "text": "正文", "human": 70 + i},
                           ensure_ascii=False) for i in range(3)) + "\n",
                encoding="utf-8")
            argv = ["human_eval_correlation.py", "--annotations", str(p)]
            with contextlib.redirect_stdout(None):
                with _argv(argv):
                    self.assertEqual(hec.main(), 2)


@contextlib.contextmanager
def _argv(argv):
    old = sys.argv
    sys.argv = list(argv)
    try:
        yield
    finally:
        sys.argv = old


if __name__ == "__main__":
    unittest.main()
