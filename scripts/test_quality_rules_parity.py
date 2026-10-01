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


if __name__ == "__main__":
    unittest.main()
