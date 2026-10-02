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
        """
        pipeline = (ROOT / "scripts" / "novel_pipeline.py").read_text(
            encoding="utf-8")
        # Python：采纳下限绑定到生成常量，且不再出现裸字面量赋值。
        self.assertIn("EDITOR_MIN_RATIO = _gen.EDITOR_MIN_RATIO", pipeline)
        self.assertNotRegex(pipeline, r"EDITOR_MIN_RATIO\s*=\s*0\.\d",
                            "EDITOR_MIN_RATIO 退回硬编码，应改引生成常量")
        # Dart：两个消费点都引用 QualityRules.*，不再出现 * 0.85 这类裸阈值。
        dart = (ROOT / "lib" / "ai_pipeline" / "services"
                / "ai_pipeline_service.dart").read_text(encoding="utf-8")
        self.assertNotRegex(
            dart, r"\w+\s*\*\s*0\.85",
            "ai_pipeline_service.dart 出现裸 0.85，应改用 QualityRules.editorMinRatio")
        self.assertNotRegex(
            dart, r"=\s*0\.92\s*;",
            "ai_pipeline_service.dart 出现裸 0.92，应改用 QualityRules.fixMinRatio")


if __name__ == "__main__":
    unittest.main()
