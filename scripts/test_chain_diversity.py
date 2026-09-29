#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""故障转移链结构回归（2026-09-29 真机跑书后补）。

真机证据：规划链原为 glm K1→K2→K3→AMD→NV，**三把 glm 同模型同端点只差 key**。
key 级失败（429 配额）时 key 多样性有效，但**模型级**失败（glm 思考链吃满
max_tokens 致正文为空）时三把 key 必然一起失败——实测白白多等约 8 分钟才落到
AMD。故规划链必须补**模型多样性**。
"""
import json
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import novel_pipeline as np  # noqa: E402


class PlannerChainDiversityTest(unittest.TestCase):
    def test_planner_chain_has_model_diversity(self):
        models = [s["model"] for s in np.PLANNER_CHAIN]
        self.assertGreater(
            len(set(models)), 1,
            "规划链不得全是同一模型：模型级失败时 key 多样性无效")
        # dsf-flash 必须在前 2 位——它专门用来接 glm 的思考链死循环
        self.assertIn("deepseek-v4-flash", models[:2], models)

    def test_llm_call_sends_caller_max_tokens_not_slot_config(self):
        """诊断/请求必须用**实发**的 max_tokens（调用方传参优先于槽位配置）。

        2026-09-30 真机：规划调用点曾硬编码 max_tokens=4000，把每个槽位配的
        8000 整个覆盖，思考链模型必然「吃满→正文空」，跑书卡在规划、一章没写成；
        而诊断打印的是槽位配置，日志显示「吃满 8000」——与实发的 4000 对不上，
        误导定位半天。本测试钉死「实发值 = 调用方传参」，防止再被静默覆盖。
        """
        sent = {}

        def fake_urlopen(req, timeout=None):
            sent["max_tokens"] = json.loads(req.data.decode("utf-8"))["max_tokens"]
            raise urllib.error.URLError("stop-after-capture")  # 捕获 payload 即退出

        provider = {"url": "http://x", "model": "m", "key": "k", "max_tokens": 8000}
        with patch.object(np.urllib.request, "urlopen", fake_urlopen):
            with patch("builtins.print"):
                with patch.object(np, "_in_cooldown", return_value=False):
                    np.llm_call(provider, "sys", "user", max_tokens=4000, retries=0)
        self.assertEqual(sent.get("max_tokens"), 4000,
                         "调用方传的 max_tokens 未生效（应优先于槽位配置 8000）")

    def test_planner_chain_covers_all_endpoints(self):
        urls = {s["url"] for s in np.PLANNER_CHAIN}
        self.assertIn(np.SENSE, urls)
        self.assertIn(np.AMD, urls, "AMD 是商汤全灭时唯一的实测可用兜底")
        self.assertIn(np.NVIDIA, urls)

    def test_all_chains_non_empty_and_budgeted(self):
        for name in ("PLANNER_CHAIN", "WRITER_CHAIN", "EDITOR_CHAIN"):
            chain = getattr(np, name)
            self.assertTrue(chain, name)
            for s in chain:
                self.assertTrue(s.get("model"), name)
                self.assertGreater(int(s.get("max_tokens", 0)), 0, name)


class AmdSkipSelectionTest(unittest.TestCase):
    """--skip-amd 的 AMD 槽必须按 url 选，不能按硬编码下标。

    2026-09-29 插 dsf 槽时，规划链下标整体后移，原 `PLANNER_CHAIN[3]`（AMD）
    变成了商汤槽——那会把商汤自己标成冷却，等于自己把自己踢下线。故钉死：
    链变动后，PLANNER_CHAIN[3] 不再是 AMD，但「按 url 选」仍必须拿到全部 AMD 槽。
    """

    def test_index_three_is_no_longer_amd(self):
        # 记录这个「陷阱」：若将来有人把 dsf 槽撤掉，本断言会失败提醒复查
        self.assertNotEqual(np.PLANNER_CHAIN[3].get("url"), np.AMD,
                            "规划链下标又变了——请复查 --skip-amd 的 AMD 选择方式")

    def test_url_based_selection_finds_every_amd_slot(self):
        for chain_name in ("PLANNER_CHAIN", "WRITER_CHAIN", "EDITOR_CHAIN",
                           "VERIFIER_CHAIN", "CHIEF_EDITOR_CHAIN"):
            chain = getattr(np, chain_name)
            amd_slots = [p for p in chain if p.get("url") == np.AMD]
            # 只有确实含 AMD 槽的链才要求非空
            if any(p.get("url") == np.AMD for p in chain):
                self.assertTrue(amd_slots, chain_name)
            # 反向：不能把商汤/NV 误当成 AMD
            for p in amd_slots:
                self.assertEqual(p["url"], np.AMD, chain_name)


if __name__ == "__main__":
    unittest.main()