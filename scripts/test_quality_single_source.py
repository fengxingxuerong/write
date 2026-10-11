#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""质检阈值单一数据源 + INSTRUCTION_MARKERS 词表卫生的离线回归测试。

背景（2026-10-03）：审查双端收敛时发现两处问题——

1. `editorMinRatio`（编辑产出采纳下限）是**唯一一条没进 rules/quality_rules.json
   的阈值**：Python novel_pipeline.py 与 Dart ai_pipeline_service 各自硬编码 0.85。
   quality_rules.json 还把它记成 asymmetries 里「Dart 尚未实现该守卫」，而 Dart
   实际早已实现（只是硬编码）——即那条记录本身是错的。已升格为 scalars.editorMinRatio，
   由 rules_codegen 下发双端。本测试守住它不再退化回「两端各写一份」。

2. `INSTRUCTION_MARKERS` 里「招摹」是「招募」的错别字（contains 永远匹配不到），
   且「代办」重复登记两次。已修正；修正前的误伤面用
   scripts/probe/probe_instruction_marker.py 在 174 份真实成书上实测为 +0。

全部离线，不发起任何网络请求。
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import ab_rules_parity as ab  # noqa: E402
import fanqie_review  # noqa: E402
import quality_rules_generated as gen  # noqa: E402
import novel_pipeline  # noqa: E402


class EditorMinRatioSingleSourceTest(unittest.TestCase):
    def test_python_consumes_generated_value(self):
        # novel_pipeline 必须引用生成常量，而不是自己写死 0.85。
        self.assertEqual(novel_pipeline.EDITOR_MIN_RATIO, gen.EDITOR_MIN_RATIO)

    def test_value_is_the_expected_guard(self):
        self.assertAlmostEqual(gen.EDITOR_MIN_RATIO, 0.85, places=6)

    def test_still_looser_than_fix_min_ratio(self):
        # 设计意图：提示词下限（fixMinRatio）从严，代码守卫（editorMinRatio）兜底。
        # 若两者调换，模型照提示词压缩后必被守卫整份拒绝、定点修白跑。
        self.assertGreater(gen.FIX_MIN_RATIO, gen.EDITOR_MIN_RATIO)


class InstructionMarkersHygieneTest(unittest.TestCase):
    def test_typo_absent(self):
        """「招摹」是「招募」的错别字，出现即说明修正被回退。"""
        self.assertNotIn("招摹", fanqie_review.INSTRUCTION_MARKERS)

    def test_correct_word_present(self):
        self.assertIn("招募", fanqie_review.INSTRUCTION_MARKERS)

    def test_no_duplicate_entries(self):
        markers = fanqie_review.INSTRUCTION_MARKERS
        dupes = sorted({m for m in markers if markers.count(m) > 1})
        self.assertEqual(dupes, [], f"词表存在重复词条：{dupes}")

    def test_recruit_actually_upgrades_to_veto(self):
        """回归核心：正文出现「招募」时，教唆类红线必须由「提示」升级为「否决」。

        修正前因「招摹」错别字匹配不到「招募」，这里只会得到「提示」——即漏判。
        样例刻意取「教唆与违法细节」（属 NARRATIVE_OK_CATEGORIES，走 marker 分支）
        + 其真实词「土制炸弹」，并让「招募」落在 ±40 字窗口内。
        """
        text = "星轨局正在招募主角，谁有土制炸弹的制作方法，速来报名。"
        hits = fanqie_review.redline_scan(text)
        self.assertTrue(hits, "样例文本应命中至少一条红线")
        vetoed = [h for h in hits
                  if h["level"] == "否决"
                  and h["category"] == "教唆与违法细节"]
        self.assertTrue(
            vetoed,
            "「招募」未把教唆类红线升级为否决——错别字修正可能被回退",
        )

    def test_without_marker_stays_warn(self):
        """反向对照：无 marker 语境时必须仍是「提示」。

        与上一条成对，证明升级确由「招募」触发，而非该红线词一律否决。
        """
        text = "坊间传闻有人能做出土制炸弹，皆是谣传，不可轻信。"
        hits = fanqie_review.redline_scan(text)
        educ = [h for h in hits if h["category"] == "教唆与违法细节"]
        self.assertTrue(educ, "样例文本应命中教唆类红线")
        self.assertTrue(all(h["level"] != "否决" for h in educ),
                        "无 marker 语境时不应升级为否决")


class InstructionMarkVerdictTest(unittest.TestCase):
    """instructionMarks 的收编后状态：两端必须已一致，且判定结果未变。

    时间线（2026-10-03）：
      收编前——Dart 21 词 vs Python 24 词，需先测「否决条数增量」确认零风险；
      收编后——两端同源，差异应恒为 0，且否决数与收编前基线一致。

    为什么收编后仍要钉住否决数：收编若误改了词表（例如少了「招募」），
    增量会显示 +0（因为已经没有「Python 独有词」可比了），但**否决数本身会变**。
    只断言「无差异」是恒真命题——它无法区分「正确收编」与「收编时丢词」。

    这与 test_pipeline_surface 里「门禁必须真能失败」是同一条纪律：
    一个永远为真的断言比没有断言更糟，它给人虚假的安全感。
    """

    def test_two_ends_are_now_identical(self):
        """收编后两端必须同源——若仍报「建议收编」，说明工具在拿过期副本比。

        本断言**不依赖真实语料**：py_only / dart_only 是两端词表直接做差集得到的，
        与语料无关。早期实现先断言语料非空，等于把「不需要语料」的检查错绑成
        「需要语料」——CI 干净检出（data/ 已 gitignore）下必然红，而本地有 data/
        所以一直没暴露。改为传空语料，让它在任何环境都能跑，仍能抓到
        「工具拿过期副本比」这类回归。
        """
        r = ab.analyze([])["instructionMarks"]
        self.assertEqual([], r["py_only"],
                         "两端仍有 Python 独有词——若已收编，说明 ab_rules_parity.py "
                         "里的 DART_INSTRUCTION_MARK 是过期副本（应取 gen.INSTRUCTION_MARKS）")
        self.assertEqual([], r["dart_only"],
                         "两端仍有 Dart 独有词——若已收编，同上")

    def test_veto_count_unchanged_since_pre_adoption_baseline(self):
        """否决数必须仍等于收编前实测的 5 条。

        这是「收编没改判定」的实证：若收编时动了词表（如删掉「招募」），
        教唆类红线将不再升级为否决，本断言立刻红。

        语料依赖：本断言的有效性完全来自**真实成书语料**（否决条数是跑遍语料
        数出来的，不是纯函数值）。`data/` 已 gitignore，CI 干净检出下语料为空，
        此时算出的 0 条否决只是「没有样本」，不是「收编改了判定」——故按仓库
        既有约定（test_narrative_ok_scope.py / test_count_words.py）SkipTest，
        既不让缺语料伪装成断言失败，也不让它伪装成断言通过。
        """
        corpus = ab.load_corpus()
        if not corpus:
            raise unittest.SkipTest("真实语料为空（data/ 与人评样本章缺失）")
        r = ab.analyze(corpus)["instructionMarks"]
        self.assertEqual(5, r["veto_with_dart_table"],
                         "否决条数与收编前基线（5）不符——收编改了判定，"
                         "或语料扩了需同步更新基线")
        self.assertEqual(0, r["veto_delta"],
                         f"两端否决条数出现差异（+{r['veto_delta']}）")

    def test_recruit_marker_survives_adoption(self):
        """「招募」必须仍在两端词表内——它是 2026-10-03 修正错别字的成果。

        「招摹」是「招募」的错别字，contains 永远匹配不到，即正文出现「招募」时
        漏判指令痕迹。收编是一次大规模搬运，这类成果最容易被悄悄弄丢。
        """
        self.assertIn("招募", gen.INSTRUCTION_MARKS)
        self.assertNotIn("招摹", gen.INSTRUCTION_MARKS)


class GeneratedArtifactCleanTest(unittest.TestCase):
    def test_editor_min_ratio_exported(self):
        """生成物必须把新阈值写进 __all__，否则 test_quality_rules_parity 的
        「生成物有 JSON 未登记的常量」反向校验会失败。"""
        self.assertIn("EDITOR_MIN_RATIO", gen.__all__)


if __name__ == "__main__":
    unittest.main()