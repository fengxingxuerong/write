#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_llm.parse_json_from_llm / repair_json / _sanitize_ctrl 回归测试。

背景：这三个函数是**全流水线到处依赖**的 LLM 输出 JSON 提取器——规划官大纲、
终审六维、伏笔台账、编造核查等所有结构化产出都要经 parse_json_from_llm 落地。
此前它们**零直接单测**，只在依赖历史产物的门禁里被间接调用；改坏（比如误把
正常补丁当成垃圾、或对截断 JSON 报错而非安全返回 None）要等 1 小时真实门禁
跑完才暴露。本文件用合成输入把这些边界锁死，纯函数、不发起网络请求。

断言全部来自**先探针实证**（见开发记录），不凭代码假设。其中关于截断 JSON 的
两条（test_truncated_*）如实固化了一个反直觉事实：repair_json 的启发式修复
**只对特定 chapter_outlines 结构可能奏效，对普通截断基本救不回来，最终安全
返回 None**——固化它防的是「有人误以为截断总能被修复」而改松了错误处理。
"""
import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_llm import _sanitize_ctrl, parse_json_from_llm, repair_json  # noqa: E402


class ParseJsonFromLlmTest(unittest.TestCase):
    """parse_json_from_llm：从含噪音的 LLM 输出中安全提取 JSON 对象。"""

    def test_plain_object(self):
        self.assertEqual(parse_json_from_llm('{"a": 1, "b": [1, 2]}'),
                         {"a": 1, "b": [1, 2]})

    def test_strips_json_fence(self):
        self.assertEqual(parse_json_from_llm('```json\n{"a": 1}\n```'), {"a": 1})

    def test_strips_chatter_around(self):
        self.assertEqual(
            parse_json_from_llm('好的，以下是结果：{"a": 1} 希望对你有帮助'),
            {"a": 1})

    def test_nested_object_and_array(self):
        raw = '{"x": {"y": [1, 2, {"z": 3}]}}'
        self.assertEqual(parse_json_from_llm(raw), {"x": {"y": [1, 2, {"z": 3}]}})

    def test_scalar_values_null_true_false(self):
        self.assertEqual(
            parse_json_from_llm('{"n": null, "t": true, "f": false}'),
            {"n": None, "t": True, "f": False})

    def test_whitespace_and_fence_with_spaces(self):
        self.assertEqual(parse_json_from_llm('  \n```json {"k": "v"} ```\n  '),
                         {"k": "v"})

    def test_bare_newline_in_string_escaped(self):
        self.assertEqual(parse_json_from_llm('{"a": "第一行\n第二行"}'),
                         {"a": "第一行\n第二行"})

    def test_bare_tab_in_string_escaped(self):
        self.assertEqual(parse_json_from_llm('{"a": "x\ty"}'), {"a": "x\ty"})

    def test_bare_carriage_return_in_string_escaped(self):
        self.assertEqual(parse_json_from_llm('{"a": "x\ry"}'), {"a": "x\ry"})

    def test_bare_control_char_below_0x20(self):
        self.assertEqual(parse_json_from_llm('{"a": "x\x0by"}'), {"a": "x\x0by"})

    def test_escaped_quote_not_treated_as_boundary(self):
        self.assertEqual(parse_json_from_llm(r'{"a": "他说\"你好\""}'),
                         {"a": '他说"你好"'})

    def test_empty_string_returns_none(self):
        self.assertIsNone(parse_json_from_llm(''))

    def test_none_input_returns_none(self):
        self.assertIsNone(parse_json_from_llm(None))

    def test_no_brace_returns_none(self):
        self.assertIsNone(parse_json_from_llm('just text no braces'))

    def test_only_open_brace_returns_none(self):
        self.assertIsNone(parse_json_from_llm('{"a": 1'))

    def test_top_level_array_returns_none(self):
        self.assertIsNone(parse_json_from_llm('[1, 2, 3]'))

    def test_unrepairable_garbage_returns_none(self):
        self.assertIsNone(parse_json_from_llm('{这不是 json 完全是废话}'))

    def test_two_concatenated_objects_returns_none(self):
        self.assertIsNone(parse_json_from_llm('{"a": 1}{"b": 2}'))

    def test_truncated_array_returns_none(self):
        self.assertIsNone(parse_json_from_llm('{"title": "标题", "list": [1, 2'))

    def test_truncated_chapter_outlines_returns_none(self):
        self.assertIsNone(parse_json_from_llm(
            '{"title": "T", "chapter_outlines": [{"idx": 1, "goal": "G"'))

    def test_repair_false_on_bad_returns_none(self):
        with redirect_stdout(io.StringIO()):
            self.assertIsNone(parse_json_from_llm('{"a": 坏}', repair=False))

    def test_repair_false_on_good_still_parses(self):
        self.assertEqual(parse_json_from_llm('{"a": 1}', repair=False), {"a": 1})


class RepairJsonTest(unittest.TestCase):
    """repair_json 纯函数行为：括号计数与「已配平则原样返回」。"""

    def test_balanced_input_returned_stripped_unchanged(self):
        self.assertEqual(repair_json('  {"a": 1}  '), '{"a": 1}')

    def test_more_closes_than_opens_returned_unchanged(self):
        self.assertEqual(repair_json('{"a": 1}}'), '{"a": 1}}')

    def test_no_brace_returned_stripped(self):
        self.assertEqual(repair_json('  plain text  '), 'plain text')

    def test_truncated_produces_string_that_stays_invalid(self):
        out = repair_json('{"a": 1, "b": 22')
        self.assertIn('}', out)
        with self.assertRaises(Exception):
            json.loads(out)


class SanitizeCtrlTest(unittest.TestCase):
    """_sanitize_ctrl：字符串值内裸控制字符转义，已转义的不二次处理。"""

    def test_real_newline_escaped(self):
        self.assertEqual(_sanitize_ctrl('{"a": "x\ny"}'), r'{"a": "x\ny"}')

    def test_already_escaped_not_double_escaped(self):
        self.assertEqual(_sanitize_ctrl(r'{"a": "x\ny"}'), r'{"a": "x\ny"}')

    def test_tab_and_cr_escaped(self):
        self.assertEqual(_sanitize_ctrl('{"a": "x\ty\rz"}'),
                         r'{"a": "x\ty\rz"}')

    def test_low_control_char_escaped_as_unicode(self):
        self.assertEqual(_sanitize_ctrl('{"a": "x\x0by"}'),
                         r'{"a": "x\u000by"}')

    def test_escaped_quote_toggles_string_state_correctly(self):
        out = _sanitize_ctrl(r'{"a": "他说\"你好\""}')
        self.assertEqual(out, r'{"a": "他说\"你好\""}')


if __name__ == "__main__":
    unittest.main()
