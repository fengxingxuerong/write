#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""generate_novel 质量修复验收器的离线回归测试。"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_novel import (  # noqa: E402
    _quality_chunks,
    _sidecar_path,
    _quality_repair_candidate,
    _quality_repair_in_chunks,
    _quality_repair_prompt,
)


class QualityRepairCandidateTest(unittest.TestCase):
    def test_accepts_non_degrading_repair(self):
        before = '主角推门。' * 300
        after = '“你来做。”主角推门。' * 200
        before_review = {'score': 60, 'blockers': []}
        after_review = {'score': 80, 'blockers': []}
        accepted, reason = _quality_repair_candidate(
            before, after, before_review, after_review, 1000)
        self.assertTrue(accepted, reason)

    def test_rejects_score_drop(self):
        before = '主角推门。' * 300
        after = '“你来做。”主角推门。' * 200
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

    def test_rejects_unchanged_zero_dialogue(self):
        before = '主角推门。' * 150
        after = '主角继续推门。' * 150
        accepted, reason = _quality_repair_candidate(
            before, after,
            {'score': 60, 'blockers': []},
            {'score': 80, 'blockers': []},
            500)
        self.assertFalse(accepted)
        self.assertIn('对白占比没有改善', reason)

    def test_sidecar_never_overwrites_output_without_jsonl_suffix(self):
        self.assertEqual(_sidecar_path('book', '.txt'), 'book.txt')
        self.assertEqual(_sidecar_path('book.jsonl', '.txt'), 'book.txt')

    def test_chunks_bound_each_request(self):
        chunks = _quality_chunks('a' * 5 + '\n\n' + 'b' * 5, max_chars=5)
        self.assertEqual(chunks, ['aaaaa', 'bbbbb'])
        with self.assertRaises(ValueError):
            _quality_chunks('正文', max_chars=0)

    def test_chunked_repair_reassembles_only_after_all_chunks_succeed(self):
        calls = []

        def fake_call(prompt, max_tokens):
            calls.append((prompt, max_tokens))
            return f'修复稿{len(calls)}'

        result = _quality_repair_in_chunks(
            'a' * 5 + '\n\n' + 'b' * 5,
            {'score': 50, 'problems': [], 'redline': {'veto': [], 'warn': []}},
            {'characters': [], 'facts': []}, '玄幻', '林舟', '',
            fake_call, max_chars=5)
        self.assertEqual(result, '修复稿1\n\n修复稿2')
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(max_tokens >= 600 for _, max_tokens in calls))

        failed_calls = []

        def fail_second_call(prompt, max_tokens):
            failed_calls.append((prompt, max_tokens))
            return 'ok' if len(failed_calls) == 1 else ''

        failed = _quality_repair_in_chunks(
            'a' * 5 + '\n\n' + 'b' * 5,
            {'score': 50, 'problems': [], 'redline': {'veto': [], 'warn': []}},
            {'characters': [], 'facts': []}, '玄幻', '林舟', '',
            fail_second_call, max_chars=5)
        self.assertEqual(failed, '')
        self.assertEqual(len(failed_calls), 2)


if __name__ == '__main__':
    unittest.main()
