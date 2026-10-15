#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""watchdog_smoke_gate 的纯函数单测（不碰时钟真值、不联网、不起进程）。

守候脚本最怕两件事，这里各钉一条：
  · **时间窗算错** → 守候要么立刻自认超时退出、要么跑到白天白耗（next_window）；
  · **熔断失效** → 环境故障轮次被无限重试，整夜空转白烧配额（should_retry）。
"""
import sys
import unittest
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import watchdog_smoke_gate as wd  # noqa: E402


class NextWindowTest(unittest.TestCase):
    def test_cross_midnight_window(self):
        """22:06 传 02:30/07:30 → 明天 02:30 / 明天 07:30（初版把 07:30 算成今天已过期）。"""
        now = datetime(2026, 10, 15, 22, 6)
        start, deadline = wd.next_window("02:30", "07:30", now=now)
        self.assertEqual(datetime(2026, 10, 16, 2, 30), start)
        self.assertEqual(datetime(2026, 10, 16, 7, 30), deadline)
        self.assertGreater(deadline, start)

    def test_same_day_window_when_start_ahead(self):
        now = datetime(2026, 10, 15, 1, 0)
        start, deadline = wd.next_window("02:30", "07:30", now=now)
        self.assertEqual(datetime(2026, 10, 15, 2, 30), start)
        self.assertEqual(datetime(2026, 10, 15, 7, 30), deadline)

    def test_start_already_passed_rolls_to_next_day(self):
        now = datetime(2026, 10, 15, 3, 0)
        start, deadline = wd.next_window("02:30", "07:30", now=now)
        self.assertEqual(datetime(2026, 10, 16, 2, 30), start)
        self.assertEqual(datetime(2026, 10, 16, 7, 30), deadline)

    def test_deadline_always_after_start_even_if_earlier_clock(self):
        """收工时刻早于开跑时刻（如 01:00 收工）也要顺延到 start 之后，不能倒挂。"""
        now = datetime(2026, 10, 15, 22, 0)
        start, deadline = wd.next_window("02:30", "01:00", now=now)
        self.assertEqual(datetime(2026, 10, 16, 2, 30), start)
        self.assertEqual(datetime(2026, 10, 17, 1, 0), deadline, "收工顺延一天，不倒挂")
        self.assertGreater(deadline, start)


class CountChaptersTest(unittest.TestCase):
    def test_counts_only_chapter_records(self):
        text = "\n".join([
            '{"type": "outline", "data": {}}',
            '{"type": "chapter", "data": {"idx": 1}}',
            "",                              # 空行
            "{坏行，半截",                    # 坏行不能抛异常
            '{"type": "chapter", "data": {"idx": 2}}',
            '{"type": "review", "data": {}}',
        ])
        self.assertEqual(2, wd.count_chapters(text))

    def test_empty_input(self):
        self.assertEqual(0, wd.count_chapters(""))
        self.assertEqual(0, wd.count_chapters(None))


class CompletionHasContentTest(unittest.TestCase):
    def test_plain_content_ok(self):
        self.assertTrue(wd.completion_has_content(
            {"choices": [{"message": {"content": "好"}}]}))

    def test_thinking_only_is_not_usable(self):
        """思考链吃满、正文为空 → 端点不可用（否则体检会放行产不出正文的窗口）。"""
        self.assertFalse(wd.completion_has_content(
            {"choices": [{"message": {"content": "", "reasoning_content": "想了很多"}}]}))

    def test_malformed_payload(self):
        for bad in ({}, {"choices": []}, {"choices": [{}]}, None):
            with self.subTest(bad=bad):
                self.assertFalse(wd.completion_has_content(bad))


class ShouldRetryTest(unittest.TestCase):
    NOW = datetime(2026, 10, 16, 3, 0)
    DEADLINE = datetime(2026, 10, 16, 7, 30)

    def test_enough_chapters_stops(self):
        retry, why = wd.should_retry(1, 3, self.NOW, self.DEADLINE)
        self.assertFalse(retry)
        self.assertIn("达标", why)

    def test_short_output_retries_once(self):
        retry, why = wd.should_retry(1, 0, self.NOW, self.DEADLINE)
        self.assertTrue(retry, "首轮零章 + 未到上限/截止 → 可以再试一轮")
        self.assertIn("产出不足", why)

    def test_fuse_on_attempt_limit(self):
        """熔断：到尝试上限就停，不无限重试（防空转整夜）。"""
        retry, why = wd.should_retry(wd.MAX_ATTEMPTS, 0, self.NOW, self.DEADLINE)
        self.assertFalse(retry)
        self.assertIn("尝试上限", why)

    def test_fuse_on_deadline(self):
        retry, why = wd.should_retry(1, 1, datetime(2026, 10, 16, 7, 31), self.DEADLINE)
        self.assertFalse(retry)
        self.assertIn("最晚收工", why)


if __name__ == "__main__":
    unittest.main()
