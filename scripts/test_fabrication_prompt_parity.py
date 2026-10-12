#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""双端编造核查 prompt 的逐行对账（纯文本，不需要 dart SDK）。

为什么值得单独一个护栏（2026-10-12 事故）：
    · 修复侧 `fact_fix_prompt` 明确允许第三条路径——「在本章内补出来龙去脉」；
    · 核查侧 `fabrication_check_prompt` 原先只认「前章台账」，第 4 条「无中生有」
      没有与数字那条同款的豁免；
    · 于是**按修复指令改出来的稿子必然被判更多编造** → 定点修永远不达标 → 恒回滚。
      冒烟门禁 v8b 第 3 章实测：首轮 1 处 → 复检 4 处 → 回滚（机制如实记录，行为正确，
      错在两侧口径不对称）。
两侧判据不一致是这类闭环空转的根因，且**改一侧忘另一侧**极难在单端测试里发现，
故这里用逐行对账把它钉死：Python 的 `fabrication_check_prompt` 与 Dart 的
`fabricationCheckPrompt` 正文必须逐字一致（仅占位符名与 f-string 转义不同）。
"""
import inspect
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import pipeline_prompts as pp  # noqa: E402

DART_PATH = ROOT / "lib" / "ai_pipeline" / "prompts" / "pipeline_prompts.dart"


def python_body():
    src = inspect.getsource(pp.fabrication_check_prompt)
    body = src.split('return f"""', 1)[1].rsplit('"""', 1)[0]
    return body


def dart_body():
    src = DART_PATH.read_text(encoding="utf-8")
    start = src.index("String fabricationCheckPrompt(")
    body = re.search(r"return '''(.*?)''';", src[start:], re.S).group(1)
    return body


def normalize(text):
    """抹平「实现语言差异」，只留判据文本本身。

    差异只有三类：f-string 的 `{{`/`}}` 转义、占位符名（{idx} vs $idx）、
    以及 Dart 三引号字符串开头那个换行。
    """
    text = text.replace("{{", "{").replace("}}", "}")
    text = text.replace("{idx}", "#IDX#").replace("$idx", "#IDX#")
    text = text.replace("{chapter_text}", "#TEXT#").replace("$text", "#TEXT#")
    text = text.replace("{reg}", "#REG#").replace("$reg", "#REG#")
    text = text.replace("{facts}", "#FACT#").replace("$fact", "#FACT#")
    text = text.replace('{state_track or "（无）"}', "#ST#").replace("$st", "#ST#")
    return [ln.rstrip() for ln in text.strip("\n").splitlines()]


class FabricationPromptParityTest(unittest.TestCase):
    def test_bodies_are_identical_line_by_line(self):
        py = normalize(python_body())
        dt = normalize(dart_body())
        self.assertEqual(
            py, dt,
            "编造核查 prompt 双端已漂移——改了一侧忘了另一侧？"
            "（两侧判据必须逐字一致，否则修复侧允许的路径会被核查侧判成编造）")

    def test_unknown_origin_exemption_present_on_both_sides(self):
        """「本章首次交代」豁免必须在两侧都在——它是定点修能收敛的前提。"""
        for name, body in (("python", python_body()), ("dart", dart_body())):
            with self.subTest(side=name):
                self.assertIn("豁免：本章内首次交代来龙去脉的", body)
                self.assertIn("属「本章首次确立」，不算问题", body)

    def test_evidence_must_point_somewhere(self):
        """命中必须指得出具体出处；只写「台账里没有」不算依据（防凭空满屏判负）。"""
        for name, body in (("python", python_body()), ("dart", dart_body())):
            with self.subTest(side=name):
                self.assertIn("判断口径：命中项必须指出前文/台账里的具体出处", body)
                self.assertIn("只写「台账里没有」不构成依据", body)

    def test_numeric_exemption_survives(self):
        """数字那条的旧豁免不能被这次改动碰掉。"""
        for name, body in (("python", python_body()), ("dart", dart_body())):
            with self.subTest(side=name):
                self.assertIn("新事项首次出现的数字不算问题", body)


if __name__ == "__main__":
    unittest.main()
