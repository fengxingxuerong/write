#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`fanqie_metrics._dup_spans` 章内长重复块检测的离线回归（纯本地，不联网）。

背景：`_dup_spans` 用滑动指纹（gram 元组 + step 步长采样）找出长重复块的第二次
出现区间 [(起点, 终点)]，是 `intra_repeat`（章内大段重复/复制粘贴事故检测）的第一
通道。此前零直接单测。

探针要点（务必理解再改本文件）：
  - 函数签名 `_dup_spans(t, gram, step, min_block)`，默认值来自生成物
    （gram=12 / step=3 / min_block=120）。默认 step=3 是隔 3 字采样，
    导致「有间隔的非相邻重复」可能对不齐而检不出——这是采样算法的固有特性，
    不是 bug。故本测试统一用 gram=2 / step=1 精确控制采样，只锁定**确定性**行为，
    不去依赖 step=3 的采样对齐巧合。
  - 判定为「重复长度 k >= min_block」，区间为第二次出现的 [起点, 起点+k)。
  - 重叠区间会合并，独立区间各自成段。
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fanqie_metrics import _dup_spans  # noqa: E402


class DupSpansTest(unittest.TestCase):
    # gram=2/step=1：逐字采样，重复块位置可精确构造。
    G, STEP = 2, 1

    def test_exact_repeat_detected(self):
        # "WXYZ99WXYZ"：WXYZ(4字) 出现两次，重复长度 4。
        self.assertEqual(
            _dup_spans("WXYZ99WXYZ", gram=self.G, step=self.STEP, min_block=4),
            [(6, 10)],
        )

    def test_min_block_boundary_included(self):
        # 重复长度恰 == min_block → 计入。
        self.assertEqual(
            _dup_spans("WXYZ99WXYZ", gram=self.G, step=self.STEP, min_block=4),
            [(6, 10)],
        )

    def test_below_min_block_dropped(self):
        # 重复长度 3 < min_block=4 → 不报。
        self.assertEqual(
            _dup_spans("WXY99WXY", gram=self.G, step=self.STEP, min_block=4),
            [],
        )

    def test_min_block_just_above_dropped(self):
        # min_block 比实际重复长度大 1 → 不报（严格 >= 判定）。
        self.assertEqual(
            _dup_spans("WXYZ99WXYZ", gram=self.G, step=self.STEP, min_block=5),
            [],
        )

    def test_longer_repeat_spans_full_block(self):
        # 重复块 5 字 > min_block=4 → 区间覆盖完整第二次出现。
        self.assertEqual(
            _dup_spans("WXYZW99WXYZW", gram=self.G, step=self.STEP, min_block=4),
            [(7, 12)],
        )

    def test_two_independent_zones(self):
        # 两个互不重叠的独立重复 → 各自成段。
        self.assertEqual(
            _dup_spans("WXYZ99WXYZ33MNOP88MNOP",
                       gram=3, step=1, min_block=4),
            [(6, 10), (18, 22)],
        )

    def test_overlapping_blocks_merge(self):
        # 重叠的重复区间合并成一个（"ABCDEFG" 与 "BCDEFGH" 共享 BCDEFG）。
        spans = _dup_spans("ABCDEFG99BCDEFGH", gram=3, step=1, min_block=4)
        self.assertEqual(len(spans), 1)
        # 合并后区间连续，无断裂
        self.assertEqual(spans[0], (9, 15))

    def test_adjacent_repeat_no_gap(self):
        # 相邻重复（无间隔）："WXYZWXYZ"。
        self.assertEqual(
            _dup_spans("WXYZWXYZ", gram=3, step=1, min_block=4),
            [(4, 8)],
        )

    def test_no_repeat_returns_empty(self):
        self.assertEqual(
            _dup_spans("每一处都是独一无二与众不同的内容绝无半点重复", gram=2, step=1),
            [],
        )

    def test_empty_and_short_input(self):
        self.assertEqual(_dup_spans(""), [])
        self.assertEqual(_dup_spans("短"), [])
        # 长度不足一个 gram → 无采样点 → 空
        self.assertEqual(_dup_spans("A", gram=2, step=1), [])


if __name__ == "__main__":
    unittest.main()
