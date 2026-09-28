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

    def test_chunked_repair_aborts_when_one_chunk_fails(self):
        # 回归护栏：本方法体曾在 2026-09-28 被 SideReactionMetricTest 类插入截走，
        # 沦为类级永不执行代码（覆盖静默丢失）——恢复后必须继续被发现器执行。
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


class SideReactionMetricTest(unittest.TestCase):
    def test_side_reaction_density_zero_for_empty(self):
        from generate_novel import side_reaction_per_thousand
        self.assertEqual(side_reaction_per_thousand(''), 0.0)

    def test_side_reaction_density_counts_hits(self):
        from generate_novel import side_reaction_per_thousand
        text = '全场倒吸一口凉气，众人失声惊呼，脸色惨白，难以置信。' * 20
        d = side_reaction_per_thousand(text)
        self.assertGreater(d, 1.0)


class ReleaseProfileTest(unittest.TestCase):
    """压抑释放结构（爽点落点）——双端口径同测（Dart PipelineQa.releaseProfile）。"""

    FILLER = '文字填充。'  # 不含任何 THRILL_WORDS 的中性填充

    def test_empty_and_no_hit_is_none(self):
        from generate_novel import release_profile
        self.assertEqual(release_profile('')['verdict'], 'none')
        self.assertEqual(
            release_profile(self.FILLER * 200)['verdict'], 'none')

    def test_single_hit_is_single_not_structure(self):
        from generate_novel import release_profile
        # 单点即使位置极端也判 single：落点无结构可言，密度指标负责
        text = self.FILLER * 180 + '顿悟。' + self.FILLER * 10
        p = release_profile(text)
        self.assertEqual(p['verdict'], 'single')
        self.assertEqual(p['hits'], 1)

    def test_front_loaded_when_all_hits_in_first_half(self):
        from generate_novel import release_profile
        text = ('顿悟。' + self.FILLER * 60 + '识破。'
                + self.FILLER * 150)
        p = release_profile(text)
        self.assertEqual(p['verdict'], 'front_loaded')
        self.assertEqual(p['hits'], 2)
        self.assertLess(p['last'], 0.5)

    def test_late_start_when_first_hit_after_60pct(self):
        from generate_novel import release_profile
        text = (self.FILLER * 160 + '顿悟。'
                + self.FILLER * 40 + '识破。')
        p = release_profile(text)
        self.assertEqual(p['verdict'], 'late_start')
        self.assertGreater(p['first'], 0.6)

    def test_ok_when_release_spans_second_half(self):
        from generate_novel import release_profile
        text = (self.FILLER * 70 + '顿悟。'
                + self.FILLER * 60 + '识破。'
                + self.FILLER * 60)
        p = release_profile(text)
        self.assertEqual(p['verdict'], 'ok')
        self.assertGreaterEqual(p['last'], 0.5)
        self.assertLessEqual(p['first'], 0.6)

    def test_ev_fragment_carries_review_evidence(self):
        from generate_novel import release_ev_fragment
        ok_text = (self.FILLER * 70 + '顿悟。'
                   + self.FILLER * 60 + '识破。' + self.FILLER * 60)
        self.assertIn('结构正常', release_ev_fragment(ok_text))
        late_text = self.FILLER * 160 + '顿悟。' + self.FILLER * 40 + '识破。'
        self.assertIn('rhythm 维度不应高于 60', release_ev_fragment(late_text))
        front_text = ('顿悟。' + self.FILLER * 60 + '识破。'
                      + self.FILLER * 150)
        self.assertIn('前置泄洪', release_ev_fragment(front_text))
        self.assertIn('不适用', release_ev_fragment(self.FILLER * 200))

    def test_quality_check_records_release_verdict(self):
        from generate_novel import quality_check
        content = '顿悟。' + self.FILLER * 60 + '识破。' + self.FILLER * 150
        chapters = [{'idx': 1, 'content': content}]
        report = quality_check(chapters)
        self.assertEqual(report[0]['release'], 'front_loaded')
        self.assertEqual(chapters[0]['_release'], 'front_loaded')


if __name__ == '__main__':
    unittest.main()
