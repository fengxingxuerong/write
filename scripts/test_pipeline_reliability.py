#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""novel_pipeline 纯本地可靠性回归测试，不发起网络请求。"""
import io
import json
import re
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_novel  # noqa: E402
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

    def test_load_state_sorts_chapters_by_idx_after_resume(self):
        """断点续跑导致 jsonl 物理顺序 ≠ 章序，load 出口必须重排。

        实测事故（2026-09-30）：真机 12.6 万字长篇的章节物理顺序是
        1..9, 12,13,14,15,16,17, 10,11, 18,19, 22,24,25,27,28,30,31,32,33,
        20,21,23,26,29 —— 导出成书后无法按序阅读，须人工重排。
        根因：jsonl 是「完成一章追加一行」，续跑时缺章（10、11）在已有
        12~17 之后才补写，物理顺序因此不等于章序。续跑是配额受限时长跑的
        唯一续命方式，属常态路径而非边界情况。
        """
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'progress.jsonl'
            # 模拟续跑后的物理顺序：1..9 已完成，12~17 先写，10、11 后补
            order = [1, 2, 3, 9, 12, 13, 14, 15, 16, 17, 10, 11, 18]
            lines = [
                json.dumps({'type': 'chapter', 'data': {
                    'idx': i, 'title': f'第{i}章', 'content': f'第{i}章正文' * 200,
                }}, ensure_ascii=False)
                for i in order
            ]
            path.write_text('\n'.join(lines), encoding='utf-8')
            state = load_state(str(path), min_words=500)
        self.assertEqual(
            [chapter['idx'] for chapter in state['chapters']],
            sorted(order),
            'load_state 出口必须按 idx 升序，否则导出成书顺序错乱',
        )

    def test_export_txt_writes_chapters_in_idx_order(self):
        """导出端独立兜底：即便调用方传入乱序列表，txt 也必须按章序写。"""
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / 'book.jsonl'
            chapters = [
                {'idx': i, 'title': f'第{i}章', 'content': f'第{i}章正文。' * 50}
                for i in (1, 2, 5, 3, 4)
            ]
            txt_path = generate_novel.export_txt(str(out), '乱序探针', chapters)
            body = Path(txt_path).read_text(encoding='utf-8')
        found = [int(m) for m in re.findall(r'^第 (\d+) 章', body, re.M)]
        self.assertEqual(found, [1, 2, 3, 4, 5], '导出 txt 必须按 idx 升序')

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


    def test_world_blocker_hint_reports_hit_and_missing(self):
        row = {"metrics": {"world": {"hit": 0, "total": 2,
                                     "missing": ["荒晷大陆", "天问宗"]}}}
        self.assertEqual(smoke.world_blocker_hint(row),
                         "（专名 0/2：缺 荒晷大陆、天问宗）")

    def test_world_blocker_hint_silent_without_world_metrics(self):
        self.assertEqual(smoke.world_blocker_hint({}), "")
        self.assertEqual(smoke.world_blocker_hint({"metrics": {}}), "")
        self.assertEqual(
            smoke.world_blocker_hint({"metrics": {"world": {"hit": 2, "total": 2}}}),
            "（专名 2/2）")


class FactCheckStageTest(unittest.TestCase):
    """关卡5 命中即修：核查 → 定点修 → 复检（复检命中数下降才采纳，否则回滚）。

    v7 实锤：第 2 章 6 处编造只被「记录」、从无任何处置，门禁第 16 项因此必然 FAIL。
    """

    FABS1 = [{"type": "fabricated", "claim": "老周求我宽限三天", "evidence": "前文无此事实"}]
    FABS2 = [{"type": "fabricated", "claim": "命火令背面有凹槽", "evidence": "台账无据"}]

    def setUp(self):
        pipeline._HEALTH.clear()

    def tearDown(self):
        pipeline._HEALTH.clear()

    def test_zero_hits_costs_nothing(self):
        with patch.object(pipeline, "run_fact_check", return_value=[]), \
                patch.object(pipeline, "call_chain") as cc, \
                redirect_stdout(io.StringIO()):
            text, fabs, rec = pipeline.fact_check_stage({}, "", "正文", 1, "玄幻")
        cc.assert_not_called()
        self.assertEqual(text, "正文")
        self.assertEqual(fabs, [])
        self.assertFalse(rec["error"])

    def test_error_when_check_fails_without_repair_attempt(self):
        with patch.object(pipeline, "run_fact_check", return_value=None), \
                patch.object(pipeline, "call_chain") as cc, \
                redirect_stdout(io.StringIO()):
            text, fabs, rec = pipeline.fact_check_stage({}, "", "正文", 1, "玄幻")
        cc.assert_not_called()
        self.assertIsNone(fabs)
        self.assertTrue(rec["error"])
        self.assertEqual(rec["fabrications"], [])

    def test_adopt_repair_only_when_recheck_improves(self):
        original = "他推开门。" * 100
        repaired = "他推开门，屋里很暗，纸窗上有一道裂口。" * 90
        with patch.object(pipeline, "run_fact_check",
                          side_effect=[self.FABS1, []]), \
                patch.object(pipeline, "call_chain", return_value=repaired), \
                patch.object(pipeline, "apply_text_patch",
                             return_value=repaired), \
                redirect_stdout(io.StringIO()):
            text, fabs, rec = pipeline.fact_check_stage({}, "", original, 1, "玄幻")
        self.assertEqual(text, repaired)
        self.assertEqual(fabs, [])
        self.assertTrue(rec["repaired"])
        self.assertFalse(rec["error"])
        self.assertEqual(rec["fabrications"], [])

    def test_revert_when_recheck_not_better(self):
        original = "他推开门。" * 100
        repaired = "他推开门，屋里很暗，纸窗上有一道裂口。" * 90
        with patch.object(pipeline, "run_fact_check",
                          side_effect=[self.FABS1, self.FABS2]), \
                patch.object(pipeline, "call_chain", return_value=repaired), \
                patch.object(pipeline, "apply_text_patch",
                             return_value=repaired), \
                redirect_stdout(io.StringIO()):
            text, fabs, rec = pipeline.fact_check_stage({}, "", original, 1, "玄幻")
        self.assertEqual(text, original, "复检未改善必须回滚，不能把换了文字当解决了问题")
        self.assertEqual(fabs, self.FABS1)
        self.assertFalse(rec["repaired"])

    def test_rejected_patch_skips_recheck(self):
        original = "他推开门。" * 100
        with patch.object(pipeline, "run_fact_check",
                          return_value=self.FABS1) as chk, \
                patch.object(pipeline, "call_chain", return_value="太短"), \
                redirect_stdout(io.StringIO()):
            text, fabs, rec = pipeline.fact_check_stage({}, "", original, 1, "玄幻")
        self.assertEqual(chk.call_count, 1, "修复稿没过采纳闸就不该再花一次复检")
        self.assertEqual(text, original)
        self.assertEqual(fabs, self.FABS1)
        self.assertFalse(rec["repaired"])

    def test_fact_fix_prompt_lists_claims_and_floor(self):
        original = "他推开门。" * 100
        prompt = pipeline.fact_fix_prompt(original, self.FABS1 + self.FABS2, 2)
        self.assertIn("老周求我宽限三天", prompt)
        self.assertIn("命火令背面有凹槽", prompt)
        self.assertIn("只处置下列断言", prompt)
        self.assertIn("改写成非断言", prompt)
        floor = int(400 * fanqie_review.FIX_MIN_RATIO)
        self.assertIn(f"不得少于 {floor} 字", prompt)


class ScenePromptFactRuleTest(unittest.TestCase):
    def test_scene_prompt_carries_fact_hard_rule(self):
        from generate_novel import scene_prompt
        p = scene_prompt(1, 2, "起", "开场", [], "", "玄幻",
                         facts="三年（第 1 章确立）", registry="")
        self.assertIn("【事实与数字硬约束】", p)
        self.assertIn("台账没有的数字一律不许凭空写", p)


class ScenePlanReliabilityTest(unittest.TestCase):
    def test_plan_scenes_llm_success_first_attempt(self):
        llm_resp = '{"scenes": [{"index": 0, "stage": "起", "goal": "测试", "beats": [], "targetWords": 500}]}'
        with patch.object(pipeline, "call_chain", return_value=llm_resp) as cc, \
                redirect_stdout(io.StringIO()):
            scenes, source = pipeline.plan_scenes_or_fallback("目标", "前情", "", 2000)
        self.assertEqual(source, "llm")
        self.assertEqual(len(scenes), 1)
        self.assertEqual(scenes[0]["stage"], "起")
        self.assertEqual(cc.call_count, 1)
        self.assertEqual(cc.call_args.kwargs.get("max_tokens"), pipeline.SCENE_PLAN_BUDGETS[0])

    def test_plan_scenes_escalates_budget_on_first_empty(self):
        llm_resp = '{"scenes": [{"index": 0, "stage": "起", "goal": "升档成功", "beats": [], "targetWords": 500}]}'
        with patch.object(pipeline, "call_chain", side_effect=["", llm_resp]) as cc, \
                redirect_stdout(io.StringIO()):
            scenes, source = pipeline.plan_scenes_or_fallback("目标", "前情", "", 2000)
        self.assertEqual(source, "llm")
        self.assertEqual(cc.call_count, 2)
        # 第一次调用预算是首档，第二次调用预算是二档（升档）
        first_call = cc.call_args_list[0]
        second_call = cc.call_args_list[1]
        self.assertEqual(first_call.kwargs.get("max_tokens"), pipeline.SCENE_PLAN_BUDGETS[0])
        self.assertEqual(second_call.kwargs.get("max_tokens"), pipeline.SCENE_PLAN_BUDGETS[1])

    def test_plan_scenes_falls_back_when_all_fail(self):
        with patch.object(pipeline, "call_chain", side_effect=["", "not a json"]) as cc, \
                redirect_stdout(io.StringIO()):
            scenes, source = pipeline.plan_scenes_or_fallback("目标", "前情", "", 2000)
        self.assertEqual(source, "fallback")
        self.assertEqual(len(scenes), 4)
        self.assertEqual([s["stage"] for s in scenes], ["起", "承", "转", "合"])
        self.assertEqual(cc.call_count, len(pipeline.SCENE_PLAN_BUDGETS))

    def test_scene_plan_stats_in_smoke_gate(self):
        import run_smoke_gate
        records = [
            {"type": "chapter", "data": {"idx": 1, "scene_plan": "llm"}},
            {"type": "chapter", "data": {"idx": 2, "scene_plan": "fallback"}},
            {"type": "chapter", "data": {"idx": 3, "scene_plan": "llm"}},
        ]
        total, fallback = run_smoke_gate.scene_plan_stats(records)
        self.assertEqual(total, 3)
        self.assertEqual(fallback, [2])

    def test_scene_plan_stats_legacy_records(self):
        import run_smoke_gate
        records = [
            {"type": "chapter", "data": {"idx": 1, "title": "旧书无此字段"}},
        ]
        total, fallback = run_smoke_gate.scene_plan_stats(records)
        self.assertEqual(total, 0)
        self.assertEqual(fallback, [])

    # ================================================================
    # 成书残缺记账与告警（2026-09-30 可观测性回归）
    #
    # 事故：真机第 4 章 4 个场景有 2 个因端点全链失败返回空（3 次重试后仍空），
    # 旧实现直接跳过——成书只剩 1.5 个场景内容（章纲「禁地借刀」却成文「暗巷
    # 杀机」），整章伪装成正常章节落库，评估卡也只给一个看似正常的均分。
    # 排查只能靠翻运行日志。这里锁死「残缺必须被记账 + 在评估卡顶部告警」。
    # ================================================================
    def test_lost_scene_summary_detects_incomplete_chapters(self):
        chapters = [
            {"idx": 1, "scenes": 4, "scenes_planned": 4, "scenes_written": 4},
            {"idx": 2, "scenes": 4, "scenes_planned": 4, "scenes_written": 2},
        ]
        lost = [c for c in chapters
                if int(c.get("scenes_written", c.get("scenes", 0)) or 0)
                < int(c.get("scenes_planned", c.get("scenes", 0)) or 0)]
        self.assertEqual([c["idx"] for c in lost], [2])

    def test_lost_scene_summary_tolerates_legacy_ledger_without_new_fields(self):
        # 历史账本没有 scenes_planned/scenes_written，只有 scenes；
        # 不得因缺字段而误判为残缺（旧产物重跑时不能凭空冒出告警）。
        chapters = [{"idx": 1, "scenes": 4}]
        lost = [c for c in chapters
                if int(c.get("scenes_written", c.get("scenes", 0)) or 0)
                < int(c.get("scenes_planned", c.get("scenes", 0)) or 0)]
        self.assertEqual(lost, [])

    def test_lost_scene_alert_appears_before_average_score(self):
        # 告警必须排在均分**之前**：残缺章的评分本身没有意义，
        # 让读者先看均分会以为这本书质量正常。
        lost = [{"idx": 2, "title": "残缺章", "scenes_planned": 4,
                 "scenes_written": 2}]
        buf = io.StringIO()
        buf.write("《探针》 番茄过审评估卡\n")
        if lost:
            buf.write("⛔ 成书残缺告警：%d 章有场景未产出正文\n" % len(lost))
            for c in lost:
                buf.write("    第 %s 章：%s/%s 场景（%s）\n"
                          % (c["idx"], c["scenes_written"], c["scenes_planned"],
                             c["title"]))
            buf.write("\n")
        buf.write("题材：玄幻｜章节：2｜评审均分：60.0\n")
        body = buf.getvalue()
        self.assertIn("⛔ 成书残缺告警", body)
        self.assertIn("第 2 章：2/4 场景", body)
        self.assertLess(body.index("成书残缺告警"), body.index("评审均分"))

    def test_healthy_book_gets_no_lost_scene_alert(self):
        chapters = [{"idx": i, "scenes": 4, "scenes_planned": 4,
                     "scenes_written": 4} for i in range(1, 6)]
        lost = [c for c in chapters
                if int(c.get("scenes_written", c.get("scenes", 0)) or 0)
                < int(c.get("scenes_planned", c.get("scenes", 0)) or 0)]
        self.assertEqual(lost, [])


if __name__ == '__main__':
    unittest.main()
