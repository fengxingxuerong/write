#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""关卡3 题材内容塌陷检测器（qa_content.detect_content_drift）离线回归测试。

为什么补这个（2026-10-11）
--------------------------
`detect_content_drift`（关卡 3：标题-内容脱节）此前**零直接单测**，只在
`run_smoke_gate` 里依赖历史成书产物被间接调用。检测器的告警分级口径一旦被改坏，
全量测试仍会全绿，要等下一次跑门禁（需端点配额、耗时数十分钟）才暴露。

本测试用合成输入钉住那些**精妙但极易被误改的设计**，每个分支都配负样本对照
（防「怎么都绿」的恒真命题）：

- 三级告警：`hits==0` 时按「标题词是否命中正文」分 high/medium；
  低密度走 suspect，但**必须同时满足** density < 全书中位数×0.15 **且** < 0.30 绝对值上限
  （后者是防误报闸门：密度绝对值不过低就不报，见 test_suspect_cap_blocks）；
- 短章豁免：< 800 字章不计入中位数、也不告警（见 test_short_chapter_exempt）；
- 自动题材探测：genre=None/未知题材时取全书各题材章密度中位数最高者。

全部离线、零 LLM 成本、不依赖 data/ 与 verify-logs/，CI 恒定生效。
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from qa_content import (  # noqa: E402
    CONTENT_MIN_CHARS,
    CONTENT_SUSPECT_CAP,
    CONTENT_SUSPECT_RATIO,
    detect_content_drift,
)

# 纯填充串：甲乙丙丁…不含任何题材词（尤其避开武侠单字 剑/刀/侠 等）。
FILLER = "甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥"
# 玄幻高密度词段（命中 GENRE_CONTENT_WORDS['玄幻']）。
XUAN = "灵气修为宗门丹田境界灵石功法真气经脉玉简长老弟子筑基炼气灵田妖兽法术储物"


def pad(base: str, n: int) -> str:
    """把 base 反复填充到 >= n 字（纯填充不含题材词）。"""
    out = base
    while len(out) < n:
        out += FILLER
    return out


class ContentDriftTest(unittest.TestCase):
    def test_zero_hit_without_title_word_is_high(self):
        """零命中 + 标题词不在正文 → high。"""
        ch = [(1, "第1章 开篇", pad(XUAN + XUAN, 1500)),   # 高密度章垫中位数
              (2, "第2章 转折", pad("", 1500))]            # 纯填充 hits=0；"转折"不在正文
        res = detect_content_drift(ch, "玄幻")
        self.assertEqual(res["genre"], "玄幻")
        self.assertFalse(res["genre_auto"])
        by_idx = {a["idx"]: a for a in res["alerts"]}
        self.assertIn(2, by_idx)
        self.assertEqual(by_idx[2]["level"], "high")
        self.assertEqual(by_idx[2]["hits"], 0)
        # 负样本：高密度的第 1 章不得进告警
        self.assertNotIn(1, by_idx)

    def test_zero_hit_with_title_word_in_body_is_medium(self):
        """零命中 + 标题词命中正文 → medium（区别于 high）。"""
        # 标题词「公司」在正文出现，但全书无玄幻词 → hits=0 且 title_hit=True
        ch = [(1, "第1章 公司", pad("公司在甲乙丙丁公司", 1500))]
        res = detect_content_drift(ch, "玄幻")
        by_idx = {a["idx"]: a for a in res["alerts"]}
        self.assertIn(1, by_idx)
        self.assertEqual(by_idx[1]["level"], "medium")
        self.assertTrue(by_idx[1]["title_hit"])

    def test_low_density_suspect(self):
        """低密度（>0 命中但 density 双低于阈值）→ suspect。"""
        # 两章高密度抬高全书中位数；第 3 章 6000 字仅 1 个词 → density≈0.17
        ch = [(1, "第1章 a", pad(XUAN * 3, 1500)),
              (2, "第2章 b", pad(XUAN * 3, 1500)),
              (3, "第3章 c", pad("灵气", 6000))]
        res = detect_content_drift(ch, "玄幻")
        by_idx = {a["idx"]: a for a in res["alerts"]}
        self.assertIn(3, by_idx)
        self.assertEqual(by_idx[3]["level"], "suspect")
        self.assertEqual(by_idx[3]["hits"], 1)
        # 断言确实满足双阈值（实证 density=0.17）
        self.assertLess(by_idx[3]["density"], res["median_density"] * CONTENT_SUSPECT_RATIO)
        self.assertLess(by_idx[3]["density"], CONTENT_SUSPECT_CAP)

    def test_suspect_cap_blocks(self):
        """负样本：density 低于中位数×0.15 但绝对值 > 0.30 → 不报（防误报闸门）。"""
        # 第 3 章 density≈0.67：< med×0.15(≈5.34) 但 > 0.30 → 应被 CAP 挡住不告警
        ch = [(1, "第1章 a", pad(XUAN * 3, 1500)),
              (2, "第2章 b", pad(XUAN * 3, 1500)),
              (3, "第3章 c", pad(XUAN[:2] + "甲乙丙丁", 1500))]  # 仅 1 处"灵气"，density≈0.67
        res = detect_content_drift(ch, "玄幻")
        ch3 = next(p for p in res["per_chapter"] if p["idx"] == 3)
        self.assertEqual(ch3["hits"], 1)
        self.assertGreater(ch3["density"], CONTENT_SUSPECT_CAP)  # 绝对值超上限
        # 负样本：第 3 章不得进告警
        self.assertNotIn(3, {a["idx"] for a in res["alerts"]})

    def test_short_chapter_exempt(self):
        """短章豁免：< 800 字不计中位数、不告警。"""
        ch = [(1, "第1章 x", pad(XUAN, 500)),   # 短章（520 字左右）
              (2, "第2章 y", pad(XUAN, 1500))]
        res = detect_content_drift(ch, "玄幻")
        # 短章仍出现在 per_chapter（可见性），但被豁免
        short = next(p for p in res["per_chapter"] if p["idx"] == 1)
        self.assertLess(short["chars"], CONTENT_MIN_CHARS)
        # 中位数只由长章决定（单章 → 即该章密度），短章不拉低
        long_density = next(p["density"] for p in res["per_chapter"] if p["idx"] == 2)
        self.assertEqual(res["median_density"], long_density)
        # 短章即便 hits 低也不告警
        self.assertNotIn(1, {a["idx"] for a in res["alerts"]})

    def test_genre_auto_detection(self):
        """genre=None 自动探测：选各题材章密度中位数最高者，并置 genre_auto。"""
        ch = [(1, "第1章 a", pad(XUAN * 2, 1500)),
              (2, "第2章 b", pad(XUAN * 2, 1500))]
        res = detect_content_drift(ch, None)
        self.assertTrue(res["genre_auto"])
        self.assertEqual(res["genre"], "玄幻")  # 玄幻密度最高 → 被选中

    def test_unknown_genre_falls_back_to_auto(self):
        """未知题材字符串也走自动探测（与 None 同路径）。"""
        ch = [(1, "第1章 a", pad(XUAN * 2, 1500)),
              (2, "第2章 b", pad(XUAN * 2, 1500))]
        res = detect_content_drift(ch, "不存在的题材")
        self.assertTrue(res["genre_auto"])
        self.assertEqual(res["genre"], "玄幻")

    def test_empty_input(self):
        """空输入：返回空结构、不抛异常。"""
        res = detect_content_drift([], "玄幻")
        self.assertEqual(res["per_chapter"], [])
        self.assertEqual(res["alerts"], [])
        self.assertEqual(res["median_density"], 0.0)

    def test_return_shape(self):
        """返回 dict 键集合稳定（对外契约）。"""
        ch = [(1, "第1章 a", pad(XUAN, 1500))]
        res = detect_content_drift(ch, "玄幻")
        self.assertEqual(
            set(res.keys()),
            {"genre", "genre_auto", "median_density", "per_chapter", "alerts"},
        )
        # per_chapter 每条含必需字段
        self.assertEqual(
            set(res["per_chapter"][0].keys()),
            {"idx", "title", "chars", "hits", "density", "title_words", "title_hit"},
        )


if __name__ == "__main__":
    unittest.main()
