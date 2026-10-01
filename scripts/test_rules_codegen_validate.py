#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rules_codegen.validate：数据源自检（挡住会生成坏产物的脏词条）。

背景（2026-10-01）：rules_codegen 的 Dart/Python 产出都**把词条原样塞进引号**，
不做转义。当前 803 个词条恰好都「干净」，所以历史上没炸——但那是运气不是护栏。
往 JSON 里加一个 don't / C:\\Users / 带首尾空格的词，就会生成语法错误的源码，
或生成一个永不命中的词条（历史上真出现过 " Jesus" 前导空格，b6e4a27 才修）。

故对 validate() 做逐条回归：每类脏数据都必须被报出来，且干净数据必须不误报。
本测试不碰真实数据源，只喂内存里的构造数据，因此 CI 恒定生效。
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import rules_codegen as g  # noqa: E402


def _list(iid, values, kind="list"):
    return {"id": iid, "kind": kind, "doc": "d", "values": values}


def _scalar(iid, value, dart_type="int"):
    return {"id": iid, "dartType": dart_type, "value": value}


class ValidateTest(unittest.TestCase):
    def assertCaught(self, rules, needle):
        """problems 里必须出现 needle（用子串匹配，避开中文标点差异）。"""
        problems = g.validate(rules)
        joined = " | ".join(problems)
        self.assertTrue(
            any(needle in p for p in problems),
            f"validate 未报出 {needle!r}；实得：{joined}")

    def test_clean_data_passes(self):
        rules = {"lists": [_list("ok", ["a", "b"], kind="set")],
                 "scalars": [_scalar("n", 1.5, "double")]}
        self.assertEqual(g.validate(rules), [])

    def test_real_repo_rules_pass(self):
        """真实数据源必须零问题——否则 codegen 直接拒绝跑，无从生成。"""
        self.assertEqual(g.validate(g.load_rules()), [])

    def test_rejects_padded_word(self):
        # b6e4a27 修过的真实缺陷：词表里混入前导空格，contains 判定永不命中。
        self.assertCaught({"lists": [_list("a", [" Jesus", "x"])], "scalars": []},
                          "首尾空白")

    def test_rejects_quote_and_backslash_and_newline(self):
        # 这三类会让「原样塞进引号」产出语法错误的 Dart/Python。
        self.assertCaught({"lists": [_list("b", ["don't"])], "scalars": []},
                          "不做转义")
        self.assertCaught({"lists": [_list("c", ["C:\\Users"])], "scalars": []},
                          "不做转义")
        self.assertCaught({"lists": [_list("c2", ["a\nb"])], "scalars": []},
                          "不做转义")

    def test_rejects_duplicate_word(self):
        # 重复词条会让命中数在两端算法里含义不一致（记两次）。
        self.assertCaught({"lists": [_list("d", ["x", "x"])], "scalars": []},
                          "重复词条")

    def test_rejects_duplicate_id(self):
        rules = {"lists": [_list("e", ["x"]), _list("e", ["y"])], "scalars": []}
        self.assertCaught(rules, "重复 id")

    def test_rejects_structural_problems(self):
        self.assertCaught({"lists": [{"id": "f", "doc": "d", "values": ["x"]}],
                           "scalars": []}, "kind 必须")
        self.assertCaught({"lists": [_list("f2", [])], "scalars": []},
                          "values 缺失或为空")
        self.assertCaught({"scalars": [_scalar("s", 1)]}, "lists 缺失或为空")
        self.assertCaught({"lists": [_list("g", ["x"])],
                           "scalars": [_scalar("s", "abc")]}, "必须是数字")
        self.assertCaught({"lists": [_list("h", ["x"])],
                           "scalars": [_scalar("s", 1, "str")]}, "dartType 必须")

    def test_rejects_non_string_word(self):
        self.assertCaught({"lists": [_list("i", [123])], "scalars": []},
                          "必须是字符串")