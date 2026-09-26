#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""novel_pipeline 纯本地可靠性回归测试，不发起网络请求。"""
import io
import json
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import novel_pipeline as pipeline  # noqa: E402
import run_smoke_gate as smoke  # noqa: E402
import fanqie_review  # noqa: E402
from generate_novel import load_state  # noqa: E402


class PipelineReliabilityTest(unittest.TestCase):
    def setUp(self):
        pipeline._HEALTH.clear()

    def tearDown(self):
        pipeline._HEALTH.clear()

    def test_call_chain_keeps_short_json(self):
        short_json = '{"issues":[]}'
        provider = {'url': 'http://local', 'model': 'test', 'key': 'k1'}
        with patch.object(pipeline, 'llm_call', return_value=short_json):
            result = pipeline.call_chain([provider], 'system', 'user', 100)
        self.assertEqual(result, short_json)

    def test_health_isolated_by_api_key(self):
        first = {'url': 'http://local', 'model': 'test', 'key': 'key-a'}
        second = dict(first, key='key-b')
        for _ in range(3):
            pipeline._mark_fail(first)
        self.assertTrue(pipeline._in_cooldown(first))
        self.assertFalse(pipeline._in_cooldown(second))

        pipeline._mark_ok(second)
        self.assertFalse(pipeline._in_cooldown(second))
        self.assertGreater(len(pipeline._HEALTH), 1)

    def test_fact_check_rejects_wrong_schema(self):
        with patch.object(pipeline, 'call_chain', return_value='{"fabrications":"bad"}'):
            with patch('builtins.print'):
                self.assertIsNone(
                    pipeline.run_fact_check({'characters': [], 'facts': []}, '', '正文', 1))
        with patch.object(pipeline, 'call_chain', return_value='{"fabrications":[]}'):
            self.assertEqual(
                pipeline.run_fact_check({'characters': [], 'facts': []}, '', '正文', 1), [])

    def test_fact_check_retries_with_bigger_budget(self):
        """思考型规划官链吃满 max_tokens 导致正文为空时，须提预算重试而非静默记 error
        （2026-09-26 门禁 v7 实锤：3 章核查执行失败，第 16 项判负）。"""
        calls = []

        def fake_call(chain, system, user, max_tokens):
            calls.append(max_tokens)
            return "" if len(calls) == 1 else '{"fabrications":[]}'

        with patch.object(pipeline, 'call_chain', side_effect=fake_call):
            with patch('builtins.print'):
                result = pipeline.run_fact_check({'characters': [], 'facts': []}, '', '正文', 1)
        self.assertEqual(result, [])
        self.assertEqual(calls, list(pipeline.FACT_CHECK_BUDGETS))

    def test_fact_check_gives_up_after_all_budgets(self):
        """全部预算档都失败仍返回 None（调用方记 error），不得伪装成「0 处编造」。"""
        with patch.object(pipeline, 'call_chain', return_value='') as call:
            with patch('builtins.print'):
                result = pipeline.run_fact_check({'characters': [], 'facts': []}, '', '正文', 1)
        self.assertIsNone(result)
        self.assertEqual(call.call_count, len(pipeline.FACT_CHECK_BUDGETS))

    def test_fact_check_budget_clears_thinking_floor(self):
        """首档预算须 ≥ 规划官链自身 max_tokens 且不低于 8000，否则退回「吃满即空」复发态。"""
        self.assertGreaterEqual(pipeline.FACT_CHECK_BUDGETS[0],
                                pipeline.PLANNER_CHAIN[0]['max_tokens'])
        self.assertGreaterEqual(pipeline.FACT_CHECK_BUDGETS[0], 8000)
        self.assertLess(pipeline.FACT_CHECK_BUDGETS[0], pipeline.FACT_CHECK_BUDGETS[1])

    def test_foreshadow_save_reports_failure(self):
        with patch('builtins.open', side_effect=OSError('disk full')):
            with patch('builtins.print') as output:
                pipeline.save_foreshadow('missing.jsonl', '[]')
        self.assertTrue(any('伏笔台账保存失败' in str(call) for call in output.call_args_list))

    def test_load_state_skips_bad_and_duplicate_chapters(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'progress.jsonl'
            lines = [
                json.dumps({'type': 'outline', 'data': {'title': '测试'}}, ensure_ascii=False),
                json.dumps({'type': 'chapter', 'data': {
                    'idx': 1, 'title': '第一章', 'content': '有效正文' * 200,
                    'words': 999999,
                }}, ensure_ascii=False),
                json.dumps({'type': 'chapter', 'data': {
                    'idx': 1, 'title': '重复章', 'content': '重复正文' * 200,
                }}, ensure_ascii=False),
                '{not-json}',
                json.dumps({'type': 'chapter', 'data': {'idx': 2}}, ensure_ascii=False),
            ]
            path.write_text('\n'.join(lines), encoding='utf-8')
            state = load_state(str(path), min_words=500)
        self.assertEqual(state['outline'], {'title': '测试'})
        self.assertEqual([chapter['idx'] for chapter in state['chapters']], [1])
        self.assertEqual(state['chapters'][0]['words'], 800)

    def test_smoke_jsonl_reader_reports_malformed_records(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'progress.jsonl'
            path.write_text(
                '{"type":"chapter","data":{"idx":1,"content":"正文"}}\n'
                '{broken\n'
                '{"type":"review"}\n',
                encoding='utf-8')
            records, malformed, invalid, last_line = smoke._read_jsonl_records(str(path))
        self.assertEqual(len(records), 1)
        self.assertEqual(malformed, [2])
        self.assertEqual(invalid, 1)
        self.assertEqual(last_line, 3)

    def test_smoke_gate_deduplicates_chapter_records(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'book.jsonl'
            chapter = {'idx': 1, 'title': '第一章', 'content': '正文内容' * 100}
            records = [
                {'type': 'chapter', 'data': chapter},
                {'type': 'chapter', 'data': chapter},
                {'type': 'review', 'data': {'idx': 1, 'score': 90}},
                {'type': 'fact_check', 'data': {'idx': 1, 'fabrications': []}},
            ]
            output.write_text(
                '\n'.join(json.dumps(record, ensure_ascii=False) for record in records),
                encoding='utf-8')
            Path(directory, 'book.txt').write_text('正文内容。' * 2000, encoding='utf-8')
            Path(directory, 'book.评估卡.txt').write_text('章节：1', encoding='utf-8')
            Path(directory, 'book.终审卡.txt').write_text(
                '终审官总评\n最终：综合 90', encoding='utf-8')
            Path(directory, 'book.smokegate.log').write_text('', encoding='utf-8')
            output_chunks = io.StringIO()
            with redirect_stdout(output_chunks):
                smoke.check(str(output), 1, genre='玄幻')
        report = output_chunks.getvalue()
        self.assertIn('实际 1 章', report)
        self.assertNotIn('实际 2 章', report)

    def test_redline_allows_narrative_ratio_but_rejects_instruction(self):
        narrative = fanqie_review.redline_scan('两人配比武器')
        self.assertTrue(narrative)
        self.assertTrue(all(hit['level'] == '提示' for hit in narrative))

        instruction = fanqie_review.redline_scan('配比武器教程')
        self.assertTrue(any(hit['level'] == '否决' for hit in instruction))

    def test_cooldown_expires(self):
        provider = {'url': 'http://local', 'model': 'test', 'key': 'k'}
        for _ in range(3):
            pipeline._mark_fail(provider)
        pipeline._HEALTH[pipeline._health_key(provider)]['cooldown_until'] = time.time() - 1
        self.assertFalse(pipeline._in_cooldown(provider))


if __name__ == '__main__':
    unittest.main()
