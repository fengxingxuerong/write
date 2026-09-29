#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一键复验脚本的**闸门逻辑**离线回归（不联网）。

重点钉死两件最容易出错、且出错代价很大（白烧配额）的事：
  1. 体检必须用**真实规模**——短探针对「慢/坏」不可区分（第 34 节实锤：
     dsf 短探针 1.6s「OK」但真实规模 28.8s；AMD 更要 159s，都曾被误判为不可用）；
  2. 体检不通过必须**拒绝跑书**，而不是照样拉起。
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tool"))

import verify_effect_run as V  # noqa: E402


class HealthGateTest(unittest.TestCase):
    def test_probe_scale_is_realistic_not_toy(self):
        # 一次场景生成的量级；200~400 token 的短探针会让「慢」被误判成「坏」
        self.assertGreaterEqual(V.PROBE_CHARS, 1200,
                                "体检规模过小：短探针对慢/坏不可区分")
        # 窗口必须容得下最慢端点（AMD 实测 159s）
        self.assertGreaterEqual(V.PROBE_TIMEOUT, 180,
                                "体检窗口过小：AMD 实测需 159s，会被误杀")
        self.assertGreaterEqual(V.HEALTH_MIN, 1)

    def test_pass_criterion_needs_most_of_the_text(self):
        # 半篇不算通过：端点可能只吐了开头就断
        good = V.PROBE_CHARS
        self.assertTrue(good * 0.6 <= good)
        self.assertFalse(good * 0.5 >= good * 0.6)

    def test_refuses_to_run_when_gate_fails(self):
        """体检全挂 → 必须拒跑（此前正是跳过这步白烧了配额）。"""
        import contextlib
        import io as _io

        orig_h, orig_r = V.health_check, V.run_book
        ran = []
        V.health_check = lambda: ([{"model": "x", "ok": False, "chars": 0,
                                    "sec": 1, "note": "mock"}], 0)
        V.run_book = lambda a: ran.append(1) or "x"
        argv = sys.argv
        try:
            sys.argv = ["verify_effect_run.py"]
            with contextlib.redirect_stdout(_io.StringIO()), \
                    contextlib.redirect_stderr(_io.StringIO()):
                try:
                    V.main()
                except SystemExit:
                    pass
        finally:
            sys.argv = argv
            V.health_check, V.run_book = orig_h, orig_r
        self.assertEqual(ran, [], "体检 0 通过时仍调了 run_book —— 会白烧配额")

    def test_check_only_never_runs_book(self):
        """`--check-only` 是「只体检」的承诺：即使体检全通过也**绝不能**跑书。

        这条最容易被后续重构悄悄破坏——比如有人把 `if a.check_only: return`
        挪到 run_book 之后，语法上毫无问题，但「只体检」会变成真跑一本书，
        而这正是本脚本存在的意义所要防止的白烧配额。离线钉死。
        """
        import contextlib
        import io as _io

        orig_h, orig_r = V.health_check, V.run_book
        ran = []
        # 体检**全部通过**——比「体检失败」更严苛：只有「通过」才可能诱使代码继续往下走
        V.health_check = lambda: ([{"model": "x", "ok": True, "chars": V.PROBE_CHARS,
                                    "sec": 1, "note": "mock"}], 1)
        V.run_book = lambda a: ran.append(1) or "x"
        argv = sys.argv
        try:
            sys.argv = ["verify_effect_run.py", "--check-only"]
            with contextlib.redirect_stdout(_io.StringIO()), \
                    contextlib.redirect_stderr(_io.StringIO()):
                try:
                    V.main()
                except SystemExit:
                    pass
        finally:
            sys.argv = argv
            V.health_check, V.run_book = orig_h, orig_r
        self.assertEqual(ran, [], "--check-only 仍调了 run_book —— 「只体检」名不副实")

    def test_runs_when_gate_passes(self):
        """体检通过 → 才允许拉起流水线。"""
        import contextlib
        import io as _io

        orig_h, orig_r, orig_v = V.health_check, V.run_book, V.verdict
        ran = []
        V.health_check = lambda: ([{"model": "x", "ok": True, "chars": 10**6,
                                    "sec": 1, "note": ""}], 2)
        V.run_book = lambda a: ran.append(1) or "fake.jsonl"
        V.verdict = lambda p, b: None
        argv = sys.argv
        try:
            sys.argv = ["verify_effect_run.py"]
            with contextlib.redirect_stdout(_io.StringIO()), \
                    contextlib.redirect_stderr(_io.StringIO()):
                try:
                    V.main()
                except SystemExit:
                    pass
        finally:
            sys.argv = argv
            V.health_check, V.run_book = orig_h, orig_r
            V.verdict = orig_v
        self.assertEqual(len(ran), 1, "体检通过后应拉起一次流水线")


class VerdictHookTest(unittest.TestCase):
    def test_only_verdict_path_skips_health_and_run(self):
        # 书已跑完时只补判据：绝不能再体检/跑书
        called = []
        orig_h, orig_r = V.health_check, V.run_book
        V.health_check = lambda: called.append("health") or ([], 1)
        V.run_book = lambda a: called.append("run") or "x"
        try:
            import io as _io
            import contextlib
            sys_argv = sys.argv
            sys.argv = ["verify_effect_run.py", "--only-verdict", "x.jsonl"]
            with contextlib.redirect_stdout(_io.StringIO()), \
                 contextlib.redirect_stderr(_io.StringIO()):
                try:
                    V.main()
                except SystemExit:
                    pass
            sys.argv = sys_argv
        finally:
            V.health_check, V.run_book = orig_h, orig_r
        self.assertEqual(called, [], "--only-verdict 不得触发体检或跑书")


if __name__ == "__main__":
    unittest.main()