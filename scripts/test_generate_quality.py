#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""generate_novel 质量修复验收器的离线回归测试。"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_novel import _quality_repair_candidate, _quality_repair_prompt  # noqa: E402


class QualityRepairCandidateTest(unittest.TestCase):
    def test_accepts_non_degrading_repair(self):
        before = '主角推门。' * 300
        after = '“你。”主角推门。' * 200
        before_review = {'score': 60, 'blockers': []}
        after_review = {'score': 80, 'blockers': []}
        accepted, reason = _quality_repair_candidate(
            before, after, before_review, after_review, 1000)
        self.assertTrue(accepted, reason)

    def test_rejects_score_drop(self):
        before = '主角推门。' * 300
        after = '“你。”主角推门。' * 200
        accepted, reason = _quality_repair_candidate(
            before, after,
            {'score': 80, 'blockers': []},
            {'score': 70, 'blockers': []},
            1000)
        self.assertFalse(accepted)
        self.assertIn('质量分下降', reason)

    def test_rejects_large_length_drift(self):
        before = '主角推门。' * 300
        after = '主角推门。' * 100
        accepted, reason = _quality_repair_candidate(
            before, after,
            {'score': 60, 'blockers': []},
            {'score': 80, 'blockers': []},
            1000)
        self.assertFalse(accepted)
        self.assertIn('字数偏离', reason)

    def test_prompt_contains_quality_constraints(self):
        review = {
            'score': 50,
            'verdict': '需修',
            'problems': [{'action': '重写', 'type': '对白', 'msg': '对白太少'}],
            'redline': {'veto': [], 'warn': []},
        }
        prompt = _quality_repair_prompt(
            '正文', review, {'characters': [], 'facts': []},
            '玄幻', '林舟', '')
        self.assertIn('对白太少', prompt)
        self.assertIn('每句尽量不超过 25 字', prompt)
        self.assertIn('只输出改写后的正文', prompt)


if __name__ == '__main__':
    unittest.main()
