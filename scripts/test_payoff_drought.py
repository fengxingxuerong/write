#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""外显爽点断供带（💥 通道枯竭）的离线回归测试。

选题依据（2026-09-29 真实成书回测，14 本 156 章）：既有爽点闸门一律用
「双低」（💥<0.5 且 ✨<1.0）判过淡，但 ✨ 含蓄异动稳定在 ~2.2/千字，
恒高分使「双低」几乎永不成立——💥 外显爽点全书性枯竭（中位数 0.18~0.79）
这件事没有任何检测器看得见（规则层漏检、LLM 终审看得见）。本测试按真实
成书实测序列定标。
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_novel import (  # noqa: E402
    payoff_drought_ev_fragment,
    payoff_drought_zones,
)


class PayoffDroughtZonesTest(unittest.TestCase):
    """payoff_drought_zones：连续 >=min_run 章 💥 连低。"""

    def test_no_zone_when_all_chapters_have_payoff(self):
        # 健康小样 short_sample 实测：0/3 章连低
        self.assertEqual(payoff_drought_zones([0.67, 0.79, 0.60]), [])

    def test_two_chapter_run_is_not_a_zone(self):
        # 阈值标定的关键：1~2 章连低属正常节奏起伏（6/14 本书出现且质量正常，
        # 如 smoke_gate_v6 / fulltest_20260913 最长连低均为 2），不得误报
        self.assertEqual(payoff_drought_zones([0.2, 0.3, 0.9, 0.2, 0.25]), [])

    def test_three_chapter_run_is_a_zone(self):
        self.assertEqual(payoff_drought_zones([0.9, 0.2, 0.3, 0.4, 0.9]),
                         [(1, 3, 3)])

    def test_multiple_zones_and_tail_run(self):
        # 末尾连低必须被收口（循环退出时 start 未闭合的分支）
        self.assertEqual(
            payoff_drought_zones([0.2, 0.2, 0.2, 1.2, 0.1, 0.1, 0.1, 0.1]),
            [(0, 2, 3), (4, 7, 4)])

    def test_boundary_equals_threshold_is_not_low(self):
        # 阈值语义：< 0.5 才算低（与「爽点过淡」双低闸同边界）
        self.assertEqual(payoff_drought_zones([0.5, 0.5, 0.5]), [])
        self.assertEqual(len(payoff_drought_zones([0.49, 0.49, 0.49])), 1)

    def test_min_run_is_configurable(self):
        self.assertEqual(payoff_drought_zones([0.1, 0.1], min_run=3), [])
        self.assertEqual(payoff_drought_zones([0.1, 0.1], min_run=2),
                         [(0, 1, 2)])

    def test_empty_and_short_inputs(self):
        self.assertEqual(payoff_drought_zones([]), [])
        self.assertEqual(payoff_drought_zones([0.1]), [])

    def test_real_book_long_run_shape(self):
        """长跑断供形态可被检出——《碎脉铸仙录》33 章实测 18 章连低。"""
        series = ([1.2] + [0.2] * 5 + [1.2] * 5 + [0.2] * 14
                  + [1.2] * 3 + [0.2] * 4 + [1.2])
        zones = payoff_drought_zones(series)
        self.assertTrue(zones)
        self.assertEqual(zones[0], (1, 5, 5))
        # 断供章数应达「多数章」量级（实测 26/33）
        in_zone = sum(z[2] for z in zones)
        self.assertGreater(in_zone / len(series), 0.5)

    def test_does_not_look_at_surge_channel(self):
        """与双低塌陷区互补：只看 💥 连低，✨ 高低不参与判定。

        真实成书里 ✨ 恒高（~2.2/千字）正是掩盖断供的原因——若本检测也看 ✨，
        就会退回既有闸门的老盲区。
        """
        # 抽象签名：只传 💥 序列即可判定，函数签名里没有 ✨ 入参
        self.assertEqual(
            payoff_drought_zones([0.2] * 4), [(0, 3, 4)])


class PayoffSceneRoutingTest(unittest.TestCase):
    """爽点场景识别（关键词 **或** 位置双通道）——治「goal 20 字内不含关键词」。

    实测（2026-09-29）：14 本成书 108 章里仅 16 章 goal 含爽点键，
    写手侧按关键词触发的外显爽点硬约束几乎永不命中 → 💥 通道断供。
    """

    def test_keyword_channel_unchanged(self):
        import novel_pipeline as np
        for g in ("外显爽点：当众打脸", "设计一次打脸", "当众揭穿真凶"):
            self.assertTrue(np.is_payoff_scene(g, "承", 0, 4), g)

    def test_position_channel_catches_late_zhuan(self):
        # goal 无任何关键词，但位置在后半段且 stage=转 → 仍判为爽点场景
        import novel_pipeline as np
        self.assertTrue(np.is_payoff_scene("局势逆转，危机爆发", "转", 2, 4))
        self.assertTrue(np.is_payoff_scene("局势逆转，危机爆发", "转", 1, 3))

    def test_early_scenes_not_payoff(self):
        import novel_pipeline as np
        # 起/承阶段位置靠前，不因位置被判为爽点场景
        self.assertFalse(np.is_payoff_scene("场景铺垫", "起", 0, 4))
        self.assertFalse(np.is_payoff_scene("事件推进，冲突升级", "承", 1, 4))

    def test_late_zhuan_but_early_progress_not_payoff(self):
        # 2 场景章里 index0 的「转」进度 50% <55%，不算后半段
        import novel_pipeline as np
        self.assertFalse(np.is_payoff_scene("危机爆发", "转", 0, 2))

    def test_total_zero_disables_position_channel(self):
        import novel_pipeline as np
        self.assertFalse(np.is_payoff_scene("危机爆发", "转", 2, 0))
        self.assertTrue(np.is_payoff_scene("外显爽点：打脸", "转", 2, 0))

    def test_fallback_skeleton_has_payoff_scene(self):
        """兜底骨架必须含爽点场景——规划链失败时也不能没有爽点位。"""
        import novel_pipeline as np
        scenes = np.fallback_scenes("目标", 2000)
        goals = [s["goal"] for s in scenes]
        self.assertTrue(any("外显爽点" in g for g in goals), goals)
        # 且该场景须被 is_payoff_scene 认出来（关键词 + 位置双通道都应成立）
        hit = [s for i, s in enumerate(scenes)
               if np.is_payoff_scene(s["goal"], s.get("stage", ""), i,
                                     len(scenes))]
        self.assertEqual(len(hit), 1, goals)
        self.assertEqual(hit[0]["stage"], "转")

    def test_scene_planning_prompt_requires_marker(self):
        from generate_novel import scene_planning_prompt
        p = scene_planning_prompt("章纲", "")
        self.assertIn("外显爽点：", p)

    def test_constraint_text_shared(self):
        import novel_pipeline as np
        c = np.payoff_scene_constraint("x")
        self.assertIn("外显爽点", c)
        self.assertIn("禁止只写主角内心感受", c)


class PayoffRepairGateTest(unittest.TestCase):
    """补修触发 + 采纳判定：把「检测」接回「修复」闭环。"""

    def test_trailing_drought_len(self):
        import novel_pipeline as np
        self.assertEqual(np.trailing_drought_len([0.2, 0.1, 0.3, 0.9]), 0)
        self.assertEqual(np.trailing_drought_len([0.2, 0.1, 0.3]), 3)
        self.assertEqual(np.trailing_drought_len([]), 0)
        self.assertEqual(np.trailing_drought_len([0.2, 0.9, 0.1]), 1)

    def test_single_chapter_dual_low_kept(self):
        """旧行为必须保留：单章双低仍触发（零回归）。"""
        import novel_pipeline as np
        self.assertTrue(np.needs_payoff_repair(0.2, 0.5))
        self.assertTrue(np.needs_payoff_repair(0.49, 0.99))

    def test_drought_channel_catches_high_surge(self):
        """核心修复：断供带内「低💥但✨高」必须触发（旧口径漏 47 章）。"""
        import novel_pipeline as np
        self.assertFalse(np.needs_payoff_repair(0.2, 2.2))          # 旧口径不触发
        self.assertTrue(np.needs_payoff_repair(0.2, 2.2, drought_len=3))

    def test_no_history_disables_drought_channel(self):
        """未传历史（drought_len=0）时行为与旧版完全一致。"""
        import novel_pipeline as np
        self.assertFalse(np.needs_payoff_repair(0.2, 2.2, drought_len=0))
        self.assertFalse(np.needs_payoff_repair(0.2, 2.2, drought_len=2))

    def test_short_chapter_not_repaired(self):
        import novel_pipeline as np
        self.assertFalse(
            np.needs_payoff_repair(0.1, 0.1, min_words_ok=False))
        self.assertFalse(
            np.needs_payoff_repair(0.1, 0.1, min_words_ok=False,
                                   drought_len=9))

    def test_healthy_payoff_never_repaired(self):
        import novel_pipeline as np
        self.assertFalse(np.needs_payoff_repair(1.2, 2.0, drought_len=9))
        self.assertFalse(np.needs_payoff_repair(0.5, 2.0, drought_len=9))

    def test_prompt_carries_drought_context(self):
        import novel_pipeline as np
        p1 = np.payoff_repair_prompt("正文", drought_len=5)
        self.assertIn("连续 5 章", p1)
        self.assertIn("外显爽点", p1)
        p0 = np.payoff_repair_prompt("正文", drought_len=0)
        self.assertNotIn("【背景】", p0)
        # 无论是否断供，都必须保留「不另起情节 + 禁内心感受」两条底线
        for p in (p0, p1):
            self.assertIn("不要另起新情节", p)
            self.assertIn("禁止只写主角内心感受", p)


class PayoffRepairAcceptTest(unittest.TestCase):
    """采纳判定：绝不劣化原文，且断供补修必须真的补上 💥。"""

    ORIG = "他推开门。屋里空无一人。" * 60          # 无爽点，约 600 字
    GOOD = "他推开门。众人骇然色变，鸦雀无声。" * 60  # 补上外显反应

    def test_accepts_real_payoff_gain(self):
        import novel_pipeline as np
        ok, why = np.accept_payoff_repair(self.ORIG, self.GOOD)
        self.assertTrue(ok, why)

    def test_rejects_word_count_out_of_range(self):
        import novel_pipeline as np
        ok, why = np.accept_payoff_repair(self.ORIG, "打脸。" * 5)
        self.assertFalse(ok)
        self.assertIn("字数越界", why)

    def test_rejects_no_improvement(self):
        import novel_pipeline as np
        ok, _ = np.accept_payoff_repair(self.GOOD, self.GOOD)
        self.assertFalse(ok)

    def test_rejects_missing_character(self):
        import novel_pipeline as np
        ok, why = np.accept_payoff_repair(
            self.ORIG, self.GOOD, registry="薛启：外门执事")
        self.assertFalse(ok)
        self.assertIn("户籍角色丢失", why)

    def test_rejects_surge_only_gain_in_emergency(self):
        """只把 ✨ 写高、💥 没补上 → 必须拒绝（等于没修）。

        这条是本轮自测抓到的真缺陷：初版条件写成 `f_t < threshold and f_s <= o_s`，
        而 surge-only 稿的 ✨ 恰恰是**涨的**，于是条件不成立被误采纳——
        等于用「多写几处掌心发烫」冒充外显兑现，正是断供的成因本身。
        """
        import novel_pipeline as np
        surge_only = "他掌心发烫，丹田温热，气流涌动。" * 60
        ok, why = np.accept_payoff_repair(self.ORIG, surge_only)
        self.assertFalse(ok)
        self.assertIn("未补上外显爽点", why)


class PayoffDroughtEvFragmentTest(unittest.TestCase):
    """payoff_drought_ev_fragment：评审证据串。"""

    def test_empty_when_no_zone(self):
        self.assertEqual(payoff_drought_ev_fragment([1.0, 1.2, 0.9]), "")

    def test_contains_zone_and_guidance(self):
        ev = payoff_drought_ev_fragment([0.2, 0.2, 0.2, 0.2])
        self.assertIn("外显爽点断供", ev)
        self.assertIn("连续 4 章", ev)
        self.assertIn("第1-4章(4章)", ev)
        # 必须给出评审可执行的判档指引，否则评审仍会打「节奏紧凑」高分
        self.assertIn("不应高于 40 分", ev)
        # 必须点明含蓄异动不能替代外显兑现（这是本检测存在的根因）
        self.assertIn("含蓄异动不能替代外显兑现", ev)


if __name__ == "__main__":
    unittest.main()