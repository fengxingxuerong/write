#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""关卡1 叙述人称漂移检测器（qa_pov.detect_pov_drift）离线回归测试。

为什么补这个（2026-10-11）
--------------------------
`detect_pov_drift`（关卡 1：叙述人称漂移）此前**零直接单测**，只在
`run_smoke_gate` 里依赖历史成书产物被间接调用。检测器的防误报口径一旦被改坏，
全量测试仍全绿，要等下一次跑门禁（需端点配额、耗时数十分钟）才暴露。

本测试用合成输入钉住那些**精妙但极易被误改的防误报设计**，每个都配负样本对照
（防恒真命题）：

- `POV_STABLE_RUN=2`：单块抖动（first,third,first,third 交错，每段仅 1 块）
  **不得**报漂移——只有连续 >=2 块的稳定段才参与比较（见
  test_single_block_jitter_not_reported）；
- `dominant_pov` 须过半数且 >=3 块：独白章（first×1 + mixed×5）不得误标 first
  （见 test_monologue_dominant_not_first）；
- 样本不足跳过：叙述层 <100 字或代词 <5 的块不判（对话章整块跳过）；
- 三级判定 first(>=0.70) / third(<=0.30) / mixed(中间)，mixed 不进稳定段比较。

全部离线、零 LLM 成本、不依赖 data/ 与 verify-logs/，CI 恒定生效。
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from qa_pov import (  # noqa: E402
    POV_STABLE_RUN,
    block_pov,
    detect_pov_drift,
    split_blocks,
)

# 长句人称块：剥离对话后叙述层人称纯粹。每块约 600 字（> block_chars=500）。
THIRD = "他缓缓抬起眼，望向长廊尽头那片沉沉的暮色，心底掠过一丝难以名状的惘然。"
FIRST = "我死死攥住袖口，指甲陷进掌心，逼着自己不要在此刻露出半分怯意与动摇。"
MIXED = "我望着他，他也望着我，我心头一紧，他眉头微皱，我们都沉默着不再言语。"


def _block(sent: str, chars: int = 600) -> str:
    """把单句重复填充到约 chars 字（叙述层人称纯粹，无引号）。"""
    return (sent * (chars // len(sent) + 1))[:chars]


def _mk(sent: str, nblocks: int) -> str:
    """nblocks 个独立块，以空行分隔（触发 split_blocks 切多块）。"""
    return "\n\n".join([_block(sent)] * nblocks)


class PovDriftTest(unittest.TestCase):
    def test_split_blocks_multi(self):
        """前置验证：构造确实切出多块（否则后续比较无从发生）。"""
        self.assertEqual(len(split_blocks(_mk(THIRD, 4), 500)), 4)

    def test_uniform_third_no_drift(self):
        """统一第三人称多块 → 无漂移事件，dominant=third。"""
        events, summary = detect_pov_drift([(1, "第1章", _mk(THIRD, 4))])
        self.assertEqual(events, [])
        self.assertEqual(summary[0]["dominant_pov"], "third")
        self.assertEqual(summary[0]["third_blocks"], 4)
        self.assertEqual(summary[0]["first_blocks"], 0)

    def test_stable_first_to_third_reported(self):
        """first×2 + third×2 → 稳定段切换 → 恰 1 次 first->third 事件。"""
        content = _mk(FIRST, 2) + "\n\n" + _mk(THIRD, 2)
        events, summary = detect_pov_drift([(1, "第1章", content)])
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["from_pov"], "first")
        self.assertEqual(events[0]["to_pov"], "third")
        self.assertEqual(events[0]["chapter"], 1)
        # 两个块 first、两个块 third 均达标
        self.assertEqual(summary[0]["first_blocks"], 2)
        self.assertEqual(summary[0]["third_blocks"], 2)

    def test_single_block_jitter_not_reported(self):
        """核心防误报：单块交错 first,third,first,third（每段仅 1 块）→ 无事件。

        每段长度 1 < POV_STABLE_RUN=2，不构成稳定段，故不参与比较——
        这是防对话噪声造成单块抖动误报的关键设计。
        """
        content = (_mk(FIRST, 1) + "\n\n" + _mk(THIRD, 1) + "\n\n" +
                   _mk(FIRST, 1) + "\n\n" + _mk(THIRD, 1))
        events, summary = detect_pov_drift([(1, "第1章", content)])
        # 负样本：有 first 与 third 块，但因无稳定段，不得报漂移
        self.assertEqual(events, [])
        self.assertEqual(summary[0]["first_blocks"], 2)
        self.assertEqual(summary[0]["third_blocks"], 2)
        self.assertGreaterEqual(POV_STABLE_RUN, 2)  # 固化阈值语义

    def test_monologue_dominant_not_first(self):
        """独白章 first×1 + mixed×5 → dominant 不得误标 first（须过半数且 >=3）。"""
        content = _mk(FIRST, 1) + "\n\n" + _mk(MIXED, 5)
        events, summary = detect_pov_drift([(1, "第1章", content)])
        self.assertEqual(summary[0]["first_blocks"], 1)
        self.assertEqual(summary[0]["mixed_blocks"], 5)
        # 负样本：first 仅 1 块，即使存在也不得成为主导
        self.assertNotEqual(summary[0]["dominant_pov"], "first")

    def test_dialogue_heavy_chapter_skipped(self):
        """对话密集章（叙述层剥离后不足）→ 块被跳过，dominant=-。"""
        content = ('"我不管，你必须今夜就动身，否则一切皆休。"他沉声道。\n\n' * 2)
        events, summary = detect_pov_drift([(1, "第1章", content)])
        self.assertEqual(events, [])
        self.assertEqual(summary[0]["skipped_blocks"], 1)
        self.assertEqual(summary[0]["dominant_pov"], "-")

    def test_pure_mixed_dominant_dash(self):
        """纯 mixed 多块 → first/third 均为 0 → dominant=-（n_first+n_third==0）。"""
        events, summary = detect_pov_drift([(1, "第1章", _mk(MIXED, 4))])
        self.assertEqual(events, [])
        self.assertEqual(summary[0]["mixed_blocks"], 4)
        self.assertEqual(summary[0]["dominant_pov"], "-")

    def test_block_pov_thresholds(self):
        """块级判定：纯 third / 纯 first 各自归类；样本不足返回 None。"""
        self.assertEqual(block_pov(_block(THIRD))[0], "third")
        self.assertEqual(block_pov(_block(FIRST))[0], "first")
        # 样本不足（代词 <5、叙述 <100）→ None
        self.assertIsNone(block_pov("他走了。"))

    def test_empty_and_short(self):
        """空内容：不抛异常，dominant=-，无事件。"""
        events, summary = detect_pov_drift([(1, "第1章", "")])
        self.assertEqual(events, [])
        self.assertEqual(summary[0]["dominant_pov"], "-")

    def test_return_shape(self):
        """返回 (events, chapter_summary) 结构稳定（对外契约）。"""
        events, summary = detect_pov_drift([(1, "第1章", _mk(THIRD, 4))])
        self.assertIsInstance(events, list)
        self.assertIsInstance(summary, list)
        self.assertEqual(
            set(summary[0].keys()),
            {"idx", "title", "first_blocks", "third_blocks",
             "mixed_blocks", "skipped_blocks", "dominant_pov"},
        )


if __name__ == "__main__":
    unittest.main()
