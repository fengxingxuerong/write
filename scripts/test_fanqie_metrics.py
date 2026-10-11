#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fanqie_metrics 纯指标函数离线回归测试（filler/agency/name_drift/prompt_leak/dedup）。

为什么补这个（2026-10-11）
-----------------------
`fanqie_metrics.py` 是番茄评审**指标层**的核心：纯文本算法、零网络、零 LLM，
与 Dart 端 `FanqieGateChecker` 对账（同口径判据）。此前这些函数**零直接单测**，
只在 `fanqie_review` 评审链路里被间接调用。口径一旦被改松/改坏（水段判不出、
主角漂移漏报、提示词泄漏混进正文），评审会静默失准，全量测试仍全绿。

本测试用**合成输入**逐条钉住各函数的真实触发口径，全部经探针实证（不凭代码假设），
并对「放行类」用例配负样本对照（防恒真命题）。关键：这些函数命中依赖具体词表
（DRIVE_WORDS / NAME_PAT / PROMPT_LEAK / 主动被动词表），构造输入前先 dump 真实
词表再命中，避免「自以为在测某分支其实没触发」。

全部离线、不依赖 data/ 与 verify-logs/，CI 恒定生效。
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import fanqie_metrics as fm  # noqa: E402


# 纯描写长段（>40 字、无 DRIVE_WORDS、无对话引号）→ filler_ratio 应判水。
# DRIVE_WORDS 含 说/道/看/走/抓/推 等高频字，故水段须刻意避开这些字。
_WATER_PARA = ("寂静笼罩四野，无人言语，唯余风声穿过空旷殿堂，烛火摇曳不定，"
               "光影在墙壁上缓缓移动，时间仿佛在此刻凝固停滞，一切归于沉寂。"
               "远处山峦叠嶂，暮色渐浓，飞鸟绝迹，万籁俱寂。")


class FillerRatioTest(unittest.TestCase):
    """水段率：>=40 字且无驱动词、无对话的段落视为水段，返回 (百分比, 计入段数)。"""

    def test_empty_zero(self):
        self.assertEqual(fm.filler_ratio(""), (0.0, 0))

    def test_all_short_paragraphs_not_counted(self):
        # 全段 <40 字 → counted=0，不判水
        self.assertEqual(fm.filler_ratio("短句一。\n短句二。\n短句三。"), (0.0, 0))

    def test_pure_description_long_para_flagged(self):
        # 纯描写长段（无驱动词/对话）→ 100% 水段，计入 1 段
        ratio, counted = fm.filler_ratio(_WATER_PARA)
        self.assertEqual(ratio, 100.0)
        self.assertEqual(counted, 1)

    def test_para_with_drive_word_exempt(self):
        # 长段含 DRIVE_WORDS（如「转身」）→ 豁免，不算水段
        drive = _WATER_PARA + "他转身离去，抓起行囊便走。"
        ratio, _counted = fm.filler_ratio(drive)
        self.assertEqual(ratio, 0.0)

    def test_para_with_dialogue_exempt(self):
        # 长段含对话引号 → 豁免，不算水段
        dial = '"你到底还走不走？"' + _WATER_PARA
        ratio, _counted = fm.filler_ratio(dial)
        self.assertEqual(ratio, 0.0)


class AgencyCheckTest(unittest.TestCase):
    """主角主动性：每千字主动句 vs 被动句计数（主动词表/被动词表均命中真实词）。"""

    def test_empty_all_zero(self):
        r = fm.agency_check("")
        self.assertEqual((r["active"], r["passive"], r["ratio"]), (0, 0, 0.0))

    def test_active_words_counted(self):
        # 他决定/他伸手/主动/他点头 均为主动词
        r = fm.agency_check("他决定动手。他伸手一推。他主动上前。他点头应下。")
        self.assertEqual(r["active"], 5)
        self.assertEqual(r["passive"], 0)
        self.assertGreater(r["ratio"], 0)

    def test_passive_words_counted(self):
        # 只能/不得不/只好 均为被动词
        r = fm.agency_check("他只能认命。他不得不低头。他只好退让。")
        self.assertEqual(r["passive"], 3)
        self.assertEqual(r["active"], 0)

    def test_ratio_is_active_over_passive(self):
        r = fm.agency_check("他决定动手。他伸手一推。他主动上前。他点头应下。"
                            "他只能认命。他不得不低头。他只好退让。")
        # active=5, passive=3 → ratio = 5/3
        self.assertAlmostEqual(r["ratio"], round(5 / 3, 2), places=2)


class NameDriftTest(unittest.TestCase):
    """名字漂移：NAME_PAT 抓「人名+说/道/抬头…」；looks_like_name 过滤称呼词。"""

    def test_no_dialogue_marker_no_drift(self):
        # 无对话标记 → 抓不到人名 → 无漂移
        self.assertEqual(fm.name_drift("这是一段没有任何对话标记的叙述文字。", protagonist=""), [])

    def test_protagonist_frequent_no_drift(self):
        # 主角高频且设了 protagonist → 无漂移
        self.assertEqual(fm.name_drift("林啸说道。林啸道。林啸抬头。", protagonist="林啸"), [])

    def test_protagonist_absent_flagged(self):
        # 主角设了但本章仅出现 1 次 → 报「没接住主角」
        probs = fm.name_drift("林啸开口。少年点头。", protagonist="林啸")
        self.assertTrue(any("仅出现 1 次" in p for p in probs))

    def test_multiple_hot_names_flagged(self):
        # 3 个真实人名各 >=3 次 → 报「视角/主角漂移」
        text = "".join(f"{nm}{v}。" for nm in ("林啸", "苏婉清", "叶无尘")
                       for v in ("说", "道", "抬头"))
        probs = fm.name_drift(text, protagonist="")
        self.assertTrue(any("漂移" in p for p in probs))

    def test_two_hot_names_not_flagged(self):
        # 仅 2 个人名（未超 >2 阈值）→ 不报漂移（防误报）
        text = "林啸说道。林啸抬头。林啸转身。苏婉清说道。苏婉清抬头。苏婉清转身。"
        self.assertEqual(fm.name_drift(text, protagonist=""), [])

    def test_address_term_not_counted_as_name(self):
        # 称呼词「少年」被 looks_like_name 过滤 → 不误报为人名漂移
        text = "少年说道。少年道。少年抬头。少年点头。" * 2
        self.assertEqual(fm.name_drift(text, protagonist=""), [])


class PromptLeakTest(unittest.TestCase):
    """提示词泄漏：正文里残留任务/节拍/字段标记。命中即须拦（PROMPT_LEAK 词表）。"""

    def test_scene_marker_leaked(self):
        self.assertIn("【场景", fm.prompt_leak("【场景一】他开始修炼。"))

    def test_targetwords_field_leaked(self):
        self.assertIn("targetWords", fm.prompt_leak("targetWords: 3000"))

    def test_thrill_and_hook_markers_leaked(self):
        # 「爽点：」「钩子：」是节拍标记，同时命中
        leaks = fm.prompt_leak("爽点：打脸。钩子：反转。")
        self.assertIn("爽点：", leaks)
        self.assertIn("钩子：", leaks)

    def test_normal_prose_no_leak(self):
        # 正常正文不误报
        self.assertEqual(fm.prompt_leak("他走到山巅，望着翻涌的云海。"), [])


class DedupIntraRepeatTest(unittest.TestCase):
    """章内长重复去重：仅对 >=min_para_words 的整段全同去重，返回 (文本, 删除字数)。"""

    def test_empty_unchanged(self):
        self.assertEqual(fm.dedup_intra_repeat(""), ("", 0))

    def test_short_para_repeat_not_removed(self):
        # 短段重复（<40 字）不触发去重
        text, removed = fm.dedup_intra_repeat("短。\n短。\n短。")
        self.assertEqual(removed, 0)
        self.assertIn("短。", text)

    def test_long_para_repeat_removed(self):
        # 同一长段出现 3 次 → 去重后仅剩 1 份
        para = ("这是一个很长的段落用来测试去重逻辑需要超过四十个汉字才可以触发"
                "去重判断的条件所以要多写一些内容确保长度足够。")
        dup = f"{para}\n\n{para}\n\n{para}"
        text, removed = fm.dedup_intra_repeat(dup)
        self.assertEqual(text.count("这是一个"), 1)
        self.assertGreater(removed, 0)

    def test_unique_long_paras_kept(self):
        # 两段不同的长段 → 都不删
        a = "第一段完全独特的内容没有任何重复需要超过四十个汉字才能计入去重判断的逻辑条件。"
        b = "第二段也是完全不同的文字内容同样需要足够的长度才能参与去重判断的阈值计算过程。"
        text, removed = fm.dedup_intra_repeat(f"{a}\n\n{b}")
        self.assertEqual(removed, 0)
        self.assertIn("第一段", text)
        self.assertIn("第二段", text)


if __name__ == "__main__":
    unittest.main()

