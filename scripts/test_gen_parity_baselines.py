#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tool/gen_parity_baselines.py 的离线回归（合成输入，不依赖 data/generated）。

为什么测它：这份生成器是三个「真实成书双端对账」检查的**唯一**基线来源，
一旦它算错，Dart 侧会报出一堆「双端漂移」的假结论（而那些结论没人会去质疑生成器）。
故把三个易错点钉死：
    ① 章序：断点续传产物物理顺序 ≠ 章序，必须按 idx 升序（否则断供带算错）
    ② 形状：基线是 {n, zones:[[s,e,ch]], in_zone}，与 Dart 读取字段严格对应
    ③ 枚举：爽点场景矩阵必须是 240 例，且 verdict 随「转」场景位置变化

另外钉住 --check 的比对语义：新增成书只提示、共有项变化才报错（否则每跑一次新书就红）。
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

_spec = importlib.util.spec_from_file_location(
    "gen_parity_baselines", ROOT / "tool" / "gen_parity_baselines.py")
gen = importlib.util.module_from_spec(_spec)
sys.modules["gen_parity_baselines"] = gen
_spec.loader.exec_module(gen)


def chapter(idx, content):
    return json.dumps({"type": "chapter", "data": {"idx": idx, "content": content}},
                      ensure_ascii=False)


class ChapterLoaderTest(unittest.TestCase):
    def _jsonl(self, tmp, name, lines):
        p = Path(tmp) / name
        p.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return p

    def test_sorts_by_idx_not_file_order(self):
        with tempfile.TemporaryDirectory() as d:
            p = self._jsonl(d, "a.jsonl", [
                chapter(3, "三章内容"),
                chapter(1, "一章内容"),
                chapter(2, "二章内容"),
            ])
            chs = gen.load_chapters(p)
            self.assertEqual([i for i, _ in chs], [1, 2, 3])

    def test_skips_non_chapter_and_bad_lines(self):
        with tempfile.TemporaryDirectory() as d:
            p = self._jsonl(d, "b.jsonl", [
                chapter(1, "正文"),
                json.dumps({"type": "outline", "data": {"outline": "x"}}),
                "{ 这不是合法 JSON ",
                json.dumps({"type": "chapter", "data": {"idx": 2, "content": ""}}),
            ])
            chs = gen.load_chapters(p)
            self.assertEqual([i for i, _ in chs], [1])


class DroughtShapeTest(unittest.TestCase):
    def test_output_shape_matches_dart_reader(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "c.jsonl"
            # 三章全是高密度爽点词 -> 无断供带；结构仍必须是那三个字段
            body = "他一拳打脸，全场鸦雀无声，众人惊呼。"
            p.write_text("\n".join(chapter(i, body) for i in range(1, 4)) + "\n",
                         encoding="utf-8")
            old = gen.GEN_DIR
            gen.GEN_DIR = Path(d)
            try:
                out = gen.gen_drought()
            finally:
                gen.GEN_DIR = old
            self.assertIn("c", out)
            row = out["c"]
            self.assertEqual(set(row), {"n", "zones", "in_zone"})
            self.assertEqual(row["n"], 3)
            self.assertIsInstance(row["zones"], list)
            for z in row["zones"]:
                self.assertEqual(len(z), 3)
                self.assertIsInstance(z[0], int)

    def test_skips_books_with_fewer_than_three_chapters(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "d.jsonl"
            p.write_text("\n".join(chapter(i, "正文") for i in range(1, 3)) + "\n",
                         encoding="utf-8")
            old = gen.GEN_DIR
            gen.GEN_DIR = Path(d)
            try:
                out = gen.gen_drought()
            finally:
                gen.GEN_DIR = old
            self.assertNotIn("d", out)


class PayoffSceneMatrixTest(unittest.TestCase):
    def test_matrix_is_240_cases_and_verdicts_follow_position(self):
        rows = gen.gen_payscene()
        self.assertEqual(len(rows), 240)
        self.assertEqual(len({(r["g"], r["s"], r["i"], r["t"]) for r in rows}), 240)
        by_key = {(r["g"], r["s"], r["i"], r["t"]): r["r"] for r in rows}
        # 关键词通道：goal 命中「打脸/当众/外显爽点」即 true，与位置无关
        self.assertTrue(by_key[("设计一次打脸", "起", 0, 4)])
        # 位置通道：无关键词的普通目标，「转」场景进度 ≥55% 才算爽点场景
        self.assertFalse(by_key[("场景铺垫", "起", 0, 4)])
        self.assertTrue(by_key[("场景铺垫", "转", 2, 4)])


class CompareSemanticsTest(unittest.TestCase):
    def test_added_books_are_info_not_failure(self):
        old = {"a": {"n": 3, "zones": [], "in_zone": 0}}
        new = {"a": {"n": 3, "zones": [], "in_zone": 0},
               "b": {"n": 4, "zones": [], "in_zone": 0}}
        ok, diffs = gen.compare("drought", old, new)
        self.assertTrue(ok, diffs)

    def test_changed_common_book_fails(self):
        old = {"a": {"n": 3, "zones": [], "in_zone": 0}}
        new = {"a": {"n": 3, "zones": [[0, 1, 2]], "in_zone": 2}}
        ok, diffs = gen.compare("drought", old, new)
        self.assertFalse(ok)
        self.assertTrue(diffs)

    def test_stylefp_compare_ignores_words(self):
        old = {"ref": {"source": "x", "words": 100, "sent_len_mean": 20.0},
               "samples": [{"name": "y", "fp": {"source": "y", "words": 50,
                                               "sent_len_mean": 18.0}}]}
        new = {"ref": {"source": "x", "words": 104, "sent_len_mean": 20.0},
               "samples": [{"name": "y", "fp": {"source": "y", "words": 51,
                                               "sent_len_mean": 18.0}}]}
        ok, diffs = gen.compare("stylefp", old, new)
        self.assertTrue(ok, diffs)


if __name__ == "__main__":
    unittest.main()