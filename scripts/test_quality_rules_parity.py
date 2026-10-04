#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Python 侧质检常量 <-> 数据源 rules/quality_rules.json 的逐值、逐序对账。

与 Dart 侧 test/engine/quality/quality_rules_parity_test.dart 成对：两侧都对齐
同一份 JSON，因此任一侧被手改成与 JSON 不同即失败；生成物整体过期则由
scripts/rules_codegen.py --check 拦截（CI 三步齐备，词表漂移在结构上不可能）。

本测试不依赖任何本地数据产物（data/、verify-logs/ 均不参与），CI 恒定生效。
"""
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import quality_rules_generated as gen  # noqa: E402


def snake_upper(camel: str) -> str:
    out = []
    for i, ch in enumerate(camel):
        if ch.isupper() and i > 0:
            out.append("_")
        out.append(ch.upper())
    return "".join(out)


class QualityRulesParityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules_path = ROOT / "rules" / "quality_rules.json"
        if not cls.rules_path.exists():
            raise AssertionError(
                "缺少 rules/quality_rules.json —— 双端质检常量唯一数据源必须入库")
        cls.rules = json.loads(cls.rules_path.read_text(encoding="utf-8"))

    def test_lists_match_json(self):
        seen = set()
        for item in self.rules["lists"]:
            rid = item["id"]
            seen.add(rid)
            name = snake_upper(rid)
            self.assertTrue(hasattr(gen, name), f"{name} 未在生成物中定义")
            have = list(getattr(gen, name))
            values = list(item["values"])
            if item["kind"] == "set":
                self.assertEqual(sorted(have), sorted(values),
                                 f"{rid}（集合）与 JSON 不一致")
            else:
                self.assertEqual(have, values,
                                 f"{rid}（列表，顺序敏感）与 JSON 不一致")
                self.assertEqual(len(set(values)), len(values),
                                 f"{rid} 内有重复项——命中数会被记两次")
        extra = {n for n in gen.__all__
                 if n not in {snake_upper(i["id"]) for i in self.rules["lists"]}
                 and n not in {snake_upper(i["id"]) for i in self.rules["scalars"]}}
        self.assertEqual(extra, set(), f"生成物有 JSON 未登记的常量：{extra}")

    def test_scalars_match_json(self):
        for item in self.rules["scalars"]:
            name = snake_upper(item["id"])
            self.assertTrue(hasattr(gen, name), f"{name} 未在生成物中定义")
            self.assertEqual(float(getattr(gen, name)), float(item["value"]),
                             f"{item['id']} 阈值与 JSON 不一致")

    def test_generated_header_marks_do_not_edit(self):
        text = (ROOT / "scripts" / "quality_rules_generated.py").read_text(
            encoding="utf-8")
        self.assertIn("GENERATED FILE", text)
        self.assertIn("DO NOT EDIT", text)

    def test_python_consumers_reference_generated_thresholds(self):
        """双端消费方必须引用生成常量，而不是各自硬编码阈值。

        背景（2026-10-03）：editorMinRatio 此前是**唯一一条没进本 JSON 的阈值**，
        novel_pipeline.py 与 Dart 侧各自硬编码 0.85；fixMinRatio 在 Dart 侧也另有一份
        独立副本（factFixMinRatio = 0.92）。这类「手工同步的第二份」正是本对账体系
        要消灭的对象，故用源码级断言钉住。

        2026-10-03 拆分注记：阈值随 LLM 调用层搬到 scripts/pipeline_llm.py。
        门禁检查的是「**消费方代码里不得出现裸字面量**」这一性质，而非某个固定
        文件路径——故对两个文件都查，且各自都不得出现裸赋值。检查面比拆分前更宽
        （拆分前只查 novel_pipeline 一个文件，漏掉新文件里的硬编码）。
        """
        pipeline = (ROOT / "scripts" / "novel_pipeline.py").read_text(
            encoding="utf-8")
        llm = (ROOT / "scripts" / "pipeline_llm.py").read_text(encoding="utf-8")
        # Python：采纳下限绑定到生成常量，且不再出现裸字面量赋值。
        self.assertIn("EDITOR_MIN_RATIO = _gen.EDITOR_MIN_RATIO", llm)
        for name, text in (("novel_pipeline.py", pipeline), ("pipeline_llm.py", llm)):
            self.assertNotRegex(text, r"EDITOR_MIN_RATIO\s*=\s*0\.\d",
                                f"{name} 的 EDITOR_MIN_RATIO 退回硬编码，"
                                f"应改引生成常量")
        # Dart：两个消费点都引用 QualityRules.*，不再出现 * 0.85 这类裸阈值。
        dart = (ROOT / "lib" / "ai_pipeline" / "services"
                / "ai_pipeline_service.dart").read_text(encoding="utf-8")
        self.assertNotRegex(
            dart, r"\w+\s*\*\s*0\.85",
            "ai_pipeline_service.dart 出现裸 0.85，应改用 QualityRules.editorMinRatio")
        self.assertNotRegex(
            dart, r"=\s*0\.92\s*;",
            "ai_pipeline_service.dart 出现裸 0.92，应改用 QualityRules.fixMinRatio")


    def test_python_consumers_reference_generated_word_lists(self):
            """已收编词表的消费方不得再留字面量（收编的另一半，不做就等于白做）。

            背景（2026-10-03）：instructionMarks 收编进 JSON 并生成 INSTRUCTION_MARKS，
            但若 fanqie_review 仍保留自己的 24 词字面量，JSON 改了它不会跟着改——
            结构上「同源」只是看起来成立，实际仍是两份可各自漂移的副本。

            故用源码级断言钉住：消费方必须从生成物取值，且不再出现裸列表字面量。
            这与 test_python_consumers_reference_generated_thresholds 是同一条纪律
            在词表上的应用（那条管阈值，这条管词表）。
            """
            fr = (ROOT / "scripts" / "fanqie_review.py").read_text(encoding="utf-8")
            self.assertIn("INSTRUCTION_MARKERS = list(INSTRUCTION_MARKS)", fr,
                          "fanqie_review.INSTRUCTION_MARKERS 未引用生成物——"
                          "请改 INSTRUCTION_MARKS = list(INSTRUCTION_MARKS)")
            # 裸列表字面量回归检测：赋值右侧不得再是 [ ... ]。
            self.assertNotRegex(fr, r"INSTRUCTION_MARKERS\s*=\s*\[",
                                "fanqie_review.INSTRUCTION_MARKERS 退回字面量，"
                                "应改引生成物 quality_rules_generated.INSTRUCTION_MARKS")
            # 两个导入分支（相对导入 / 平铺导入）都要有该常量，否则「脚本直跑」
            # 与「作为模块导入」两种用法行为不一致。
            self.assertEqual(
                2, fr.count("        INSTRUCTION_MARKS,\n"),
                "fanqie_review 的两个导入分支应各有一条 INSTRUCTION_MARKS，"
                f"实为 {fr.count('        INSTRUCTION_MARKS,')} 条")

            # Dart 侧同样不得留字面量。
            dart = (ROOT / "lib" / "engine" / "quality"
                    / "fanqie_gate_checker.dart").read_text(encoding="utf-8")
            self.assertRegex(
                dart, r"_instructionMark\s*=\s*QualityRules\.instructionMarks",
                "Dart _instructionMark 未引用 QualityRules.instructionMarks")
            self.assertNotRegex(
                dart, r"_instructionMark\s*=\s*<String>",
                "Dart _instructionMark 退回字面量，"
                "应改用 QualityRules.instructionMarks")


if __name__ == "__main__":
    unittest.main()
