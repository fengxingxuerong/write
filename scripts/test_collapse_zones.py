#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`qa_scan_existing._collapse_zones` 回归测试（纯本地，不发起网络请求）。

背景：`_collapse_zones` 是「外显爽点断供带」检测的核心算法——把连续多章
「爽点双低」的区段折叠成 [(起章, 止章, 章数)]，供全书体检与签约评估告警。
此前该函数**零直接单测**，只在依赖历史成书产物的门禁里被间接调用，改坏
要等真书复跑才暴露。

双通道判定（关键防误报设计，务必锁死）：
  - 直白爽点 `thrill_per_k < threshold` **且** 异动 `surge_per_k < 1.0` 才算「双低」；
  - 含蓄变强流（✨ 异动高、💥 直白低）**不算塌陷**——避免对含蓄文风误判。
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import qa_scan_existing as q  # noqa: E402


def row(idx, thrill, surge=0.0):
    return {"idx": idx, "thrill_per_k": thrill, "surge_per_k": surge}


class CollapseZonesTest(unittest.TestCase):
    def test_contiguous_low_run_forms_one_zone(self):
        rows = [row(i, 0.1) for i in range(1, 4)]
        self.assertEqual(q._collapse_zones(rows), [(1, 3, 3)])

    def test_high_thrill_splits_zone(self):
        # 第 2 章爽点高，把前 1 章的单章断供（<min_len）与后 2 章分开
        rows = [row(1, 0.1), row(2, 2.0), row(3, 0.1), row(4, 0.1)]
        self.assertEqual(q._collapse_zones(rows), [(3, 4, 2)])

    def test_high_surge_not_collapsed(self):
        # 含蓄变强流：异动 surge 高，即便直白低也不算塌陷（防含蓄文风误判）
        rows = [row(i, 0.1, surge=1.5) for i in range(1, 4)]
        self.assertEqual(q._collapse_zones(rows), [])

    def test_single_chapter_below_min_len_dropped(self):
        rows = [row(1, 0.1), row(2, 2.0)]
        self.assertEqual(q._collapse_zones(rows), [])

    def test_exactly_min_len_kept(self):
        rows = [row(1, 0.1), row(2, 0.1), row(3, 2.0)]
        self.assertEqual(q._collapse_zones(rows), [(1, 2, 2)])

    def test_trailing_low_run_closed_at_end(self):
        # 结尾连续双低：靠循环外的补算闭合，起点在第 2 章（第 1 章爽点高）
        rows = [row(1, 2.0), row(2, 0.1), row(3, 0.1), row(4, 0.1)]
        self.assertEqual(q._collapse_zones(rows), [(2, 4, 3)])

    def test_all_low_spans_whole_book(self):
        rows = [row(i, 0.3) for i in range(1, 6)]
        self.assertEqual(q._collapse_zones(rows), [(1, 5, 5)])

    def test_two_separate_zones(self):
        rows = ([row(1, 0.1), row(2, 0.1)] + [row(3, 2.0)]
                + [row(4, 0.1), row(5, 0.1), row(6, 0.1)])
        self.assertEqual(q._collapse_zones(rows), [(1, 2, 2), (4, 6, 3)])

    def test_thrill_equal_to_threshold_is_not_low(self):
        # 判定是严格小于 threshold：正好等于 0.5 不算低（防边界误判）
        rows = [row(1, 0.5), row(2, 0.5), row(3, 0.5)]
        self.assertEqual(q._collapse_zones(rows), [])

    def test_surge_equal_to_one_is_not_collapsed(self):
        # surge 判定也是严格小于 1.0：正好 1.0 不算塌陷
        rows = [row(i, 0.1, surge=1.0) for i in range(1, 4)]
        self.assertEqual(q._collapse_zones(rows), [])


if __name__ == "__main__":
    unittest.main()
