#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""novel_pipeline.render_eval_card() 纯函数回归测试（不发起网络请求）。

背景：main() 是 ~950 行的触网编排函数，本身无单测覆盖。评估卡渲染是其中少有
的纯逻辑片段，已提取为模块级 render_eval_card()。本测试把它「无覆盖」变成
「有覆盖」——验证输出结构与关键业务规则，防止未来改动破坏：

1) 书名 / 题材 / 章节数 / 评审均分 汇总正确；
2) 成书残缺告警排在均分之前（scenes_written < scenes_planned 的章）；
3) 阻断级硬伤章数统计；
4) 逐章明细：评分、字数、阻断项、问题项、红线（veto）；
5) 缺键安全回退（空 reviews / 缺 score 等不抛异常）。

之所以单独立文件而非塞进 test_pipeline_reliability：该文件聚焦 call_chain/
health/fact_check 等**触网**路径的容错；本文件聚焦**纯渲染**，关注点不同，
分开更易维护，也便于未来 render_eval_card 进一步演进。
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import novel_pipeline as np  # noqa: E402


def _rev(idx, score=80, verdict="可投", words=3000, **extra):
    """构造一条 review_chapter 形状的 dict（缺省字段安全回退）。"""
    r = {"idx": idx, "score": score, "verdict": verdict, "words": words,
         "blockers": [], "problems": [], "redline": {}}
    r.update(extra)
    return r


def _chap(idx, title="", planned=3, written=3):
    """构造一条 state['chapters'] 形状的 dict（缺省视为无残缺）。"""
    return {"idx": idx, "title": title, "scenes_planned": planned,
            "scenes_written": written, "scenes": planned}


class RenderEvalCardTest(unittest.TestCase):
    def test_summary_line(self):
        text = np.render_eval_card(
            "书名", "玄幻",
            [_rev(1, 80), _rev(2, 90)],
            [_chap(1), _chap(2)],
        )
        # 书名、题材、章节数、均分 (80+90)/2=85.0
        self.assertIn("《书名》 番茄过审评估卡", text)
        self.assertIn("题材：玄幻｜章节：2｜评审均分：85.0", text)
        self.assertIn("阻断级硬伤章数：0", text)

    def test_empty_reviews_no_division_error(self):
        # 空 reviews：均分回退 0.0，不得抛 ZeroDivisionError
        text = np.render_eval_card("空书", "都市", [], [])
        self.assertIn("章节：0｜评审均分：0.0", text)
        self.assertIn("《空书》 番茄过审评估卡", text)

    def test_lost_chapters_warned_before_average(self):
        # 第 2 章残缺（写了 1/3 场景），告警必须出现在均分行之前
        chapters = [_chap(1, "起"), _chap(2, "承", planned=3, written=1)]
        text = np.render_eval_card(
            "残书", "玄幻", [_rev(1, 85), _rev(2, 60)], chapters)
        pos_warn = text.index("成书残缺告警")
        pos_avg = text.index("评审均分")
        self.assertLess(pos_warn, pos_avg,
                        "残缺告警必须排在均分之前，避免被均分掩盖")
        self.assertIn("1 章有场景未产出正文", text)
        self.assertIn("第 2 章：1/3 场景", text)

    def test_no_lost_chapters_no_warn(self):
        text = np.render_eval_card(
            "全书", "科幻", [_rev(1, 80)],
            [_chap(1, planned=3, written=3)])
        self.assertNotIn("成书残缺告警", text)

    def test_blockers_and_problems_and_redline(self):
        review = _rev(
            1, 55, "待修", words=2500,
            blockers=["设定矛盾", "时间线冲突"],
            problems=[{"action": "删", "type": "AI味", "msg": "过度解释"}],
            redline={"veto": [{"category": "低俗", "word": "某某",
                               "context": "……上下文……"}]},
        )
        text = np.render_eval_card("带伤书", "都市", [review], [_chap(1)])
        self.assertIn("阻断级硬伤章数：1", text)
        self.assertIn("⛔ 阻断项：设定矛盾、时间线冲突", text)
        self.assertIn("[删] AI味：过度解释", text)
        self.assertIn("☠ 红线（低俗）「某某」", text)

    def test_missing_keys_safe_fallback(self):
        # review 缺 verdict/words/problems/redline 等键，不得 KeyError
        bare = {"idx": 1, "score": 70}
        text = np.render_eval_card("", "武侠", [bare], [])
        self.assertIn("第 1 章", text)
        self.assertIn("70 分", text)

    def test_function_is_pure_and_at_module_level(self):
        # 防回退：render_eval_card 必须是模块级可调用函数
        self.assertTrue(hasattr(np, "render_eval_card"))
        self.assertTrue(callable(np.render_eval_card))


if __name__ == "__main__":
    unittest.main()
