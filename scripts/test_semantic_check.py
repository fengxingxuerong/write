#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语义硬伤检测器（qa_semantic_check.py）的离线回归测试。

为什么补这个（2026-10-03）
--------------------------
`qa_semantic_check.py`（721 行，投前质检关卡 1~4）此前**零直接测试**：它只在
`run_smoke_gate` 里被间接调用，而门禁用的是**历史遗留成书产物**。后果是——
检测器逻辑被改坏时，全量测试仍然全绿，要等到下一次跑门禁（需端点配额、
耗时数十分钟）才会暴露，且那时很难定位是哪次改动引入的。

本测试钉住的不是「函数能跑」，而是那些**精妙但极易被误改的设计**：

- `POV_STABLE_RUN=2`：单块抖动不得报人称漂移（防对话噪声误报）；
- `dominant_pov` 的「≥3 块且过半数」：独白密集章不得被误标第一人称；
- `STOP_NAMES` / `OBJ_SUFFIX` / `PRON_SUFFIX`：木头、陶罐、连你 不得被当人名；
- 长名归并：「裴照没」应并入「裴照」而非成为独立人名；
- 关卡 4 排他型关系：无关系表述时零误报。

每个用例都配**负样本**，确保断言不是「怎么都绿」的恒真命题——这是本仓库
一贯的要求（见 test/engine/quality/writing_ability_test.dart 的负样本对照）。

全部离线、零 LLM 成本、不依赖 data/ 与 verify-logs/，CI 恒定生效。
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import qa_semantic_check as qa  # noqa: E402


def _ch(idx, title, content):
    """构造 (idx, title, content) 三元组（检测器统一吃这个形状）。"""
    return (idx, title, content)


def _first_person_block(n_repeat=5, pronoun="我"):
    """造一个能被判定为 first 的人称块。

    默认重复 5 次不是随手取的：`block_pov` 要求代词总数 >= POV_MIN_PRON(=5)，
    每次重复只贡献 1 个代词，4 次以下会被按设计判为「样本不足」而跳过。
    """
    unit = (f"{pronoun}握紧了手中的剑，指节微微发白，心中却是一片冷。"
            f"{pronoun}知道自己已经没有退路。")
    return "\n".join([unit] * n_repeat)


def _third_person_block(name="裴照", n_repeat=5):
    """造一个能被判定为 third 的人称块。

    两个约束都不是随手取的，踩过坑：
    1. 必须真的含「他」代词且总数 >= POV_MIN_PRON(=5)，否则按设计返回 None；
    2. **长度须与 [_first_person_block] 一致**——人称漂移判定要求「切换前后
       各凑出 >=2 个稳定块」，而块数由字数/阈值决定；若 third 组明显更长，
       同样的阈值下它只够凑出 1 块，稳定段条件永远不成立（实测 first 组
       184 字能出 2 块、third 组 239 字只能出 1 块，事件恒为 0）。
    """
    unit = (f"{name}握紧了手中的剑，指节微微发白，心中却是一片冷。"
            f"他知道自己已经没有退路。")
    return "\n".join([unit] * n_repeat)


class StripDialogueTest(unittest.TestCase):
    """对话剔除：人称判定必须只看叙述层。"""

    def test_removes_all_quote_styles(self):
        # 必须用**成对**引号（左…右）。正则形如 `‘[^’]*’`，若首尾都用同一个
        # 左引号（她‘内容‘）本来就配不上对——那是样例写错，不是剔除逻辑的问题。
        for _q in (("‘", "’"), ("“", "”"), ("「", "」"), ("『", "』"),
                   ('"', '"')):
            with self.subTest(q=_q):
                _l, _r = _q
                text = f"她{_l}我不知道他是谁{_r}，然后转身走了。"
                out = qa.strip_dialogue(text)
                self.assertNotIn("我不知道他是谁", out,
                                 f"{_l}{_r} 未被剔除：{out}")
                self.assertIn("转身走了", out,
                              "剔除时误伤了引号外的叙述")

    def test_keeps_narration(self):
        out = qa.strip_dialogue("她说他不知道，然后转身走了。")
        self.assertIn("她说他不知道", out)

    def test_nested_quotes_iterated(self):
        """嵌套引号须迭代到稳定——否则外层残留会把对话里的人称算进叙述层。"""
        out = qa.strip_dialogue("他说『里面还有“他的话”』，然后走了。")
        self.assertNotIn("他的话", out)

    def test_placeholder_prevents_word_sticking(self):
        """剔除后用标点占位，避免「他说的话我」黏成新词。"""
        out = qa.strip_dialogue("“我不去”，他补了一句“我真的不去”。")
        self.assertNotIn("不去我", out)


class BlockPovTest(unittest.TestCase):
    def test_first_person_block_judged_first(self):
        r = qa.block_pov(_first_person_block())
        self.assertIsNotNone(r)
        self.assertEqual(r[0], "first")

    def test_third_person_block_judged_third(self):
        r = qa.block_pov(_third_person_block())
        self.assertIsNotNone(r)
        self.assertEqual(r[0], "third")

    def test_too_short_returns_none(self):
        """样本不足必须返回 None（跳过），而不是硬判一个人称。"""
        self.assertIsNone(qa.block_pov("他走了。"))

    def test_dialogue_only_block_skipped(self):
        """整块都是对话 → 叙述字数不足 → 跳过。

        真实场景：小说里有整段独白体章节，若不跳过会把对话里的大量
        「我」误判为第一人称叙述。
        """
        dialogue = "\n".join(["“我不知道他是谁，我真的不知道。”"] * 6)
        self.assertIsNone(qa.block_pov(dialogue))
class SplitBlocksTest(unittest.TestCase):
    """分块本身也要单测——它是人称漂移检测的地基，分块错了后面全错。"""

    def test_each_paragraph_group_forms_blocks(self):
        a = "\n".join(["甲段落。"] * 10)   # 30 字
        b = "\n".join(["乙段落。"] * 10)   # 30 字
        blocks = qa.split_blocks(a + "\n" + b, block_chars=35)
        self.assertGreaterEqual(len(blocks), 2,
                                "两段各自超过阈值时必须切成两块")

    def test_separator_lines_excluded(self):
        """————/==== 分隔线不计入字数（否则会撑出空块干扰判定）。"""
        text = "\n".join(["甲段落。"] * 10) + "\n————\n"
        blocks = qa.split_blocks(text, block_chars=20)
        for b in blocks:
            self.assertNotIn("————", b)

    def test_empty_input_no_blocks(self):
        self.assertEqual(qa.split_blocks(""), [])
        self.assertEqual(qa.split_blocks("\n\n\n"), [])


class DetectPovDriftTest(unittest.TestCase):
    """关卡 1：人称漂移。核心是**防误报**。

    这里的用例直接喂「已分好组的长块」并把 block_chars 设得足够大，
    让 split_blocks 不再二次切分——本组要测的是游程/稳定段/主导人称
    这些**判定逻辑**，分块本身的边界行为由 SplitBlocksTest 负责。
    """

    def test_uniform_third_person_no_event(self):
        """全书统一第三人称 → 零事件（负样本，最重要的一条）。"""
        chapters = [_ch(1, "第1章", _third_person_block()),
                    _ch(2, "第2章", _third_person_block())]
        events, _summary = qa.detect_pov_drift(chapters, block_chars=10_000)
        self.assertEqual(events, [], "统一第三人称被误报为人称漂移")

    def test_uniform_first_person_no_event(self):
        chapters = [_ch(1, "第1章", _first_person_block())]
        events, _ = qa.detect_pov_drift(chapters, block_chars=10_000)
        self.assertEqual(events, [])

    def test_single_block_flip_not_reported(self):
        """只抖一块（first→third→first）不得报——须连续 >=2 块才算稳定段。

        这是 POV_STABLE_RUN 的意义：单块异常多来自分页/对白噪声。
        块划分与正样本用例取同一 block_chars，保证两组条件可比。
        """
        blk_f, blk_t = _first_person_block(), _third_person_block()
        content = "\n\n".join([
            blk_f, blk_f,   # 稳定 first×2
            blk_t,          # 单块 third（游程长度 1，不构成稳定段）
            blk_f, blk_f,   # 又 first×2
        ])
        events, _ = qa.detect_pov_drift([_ch(1, "第1章", content)], block_chars=170)
        self.assertEqual(events, [],
                         "单块抖动被误报为人称漂移（POV_STABLE_RUN 防抖失效）")

    def test_sustained_flip_reported(self):
        """连续 >=2 块换人称必须报出来（正样本）。

        block_chars 须落在「一组长度 + 余量」区间（约 150~180），这样两组
        各凑出 2 个稳定块，才会触发 first→third 切换事件。取值太小会把一行
        切成一块（代词不足被判样本不足），太大又会把两组并成一块。
        """
        blk_f, blk_t = _first_person_block(), _third_person_block()
        content = "\n\n".join([blk_f, blk_f, blk_t, blk_t])
        events, _ = qa.detect_pov_drift([_ch(1, "第1章", content)], block_chars=170)
        self.assertTrue(events, "持续 2 块以上的切换未被报出")
        kinds = {(e["from_pov"], e["to_pov"]) for e in events}
        self.assertIn(("first", "third"), kinds,
                      f"未报出 first→third 切换：{events}")

    def test_dominant_pov_requires_majority(self):
        """独白密集章（first×1 + third×2）不得被标成第一人称主导。

        用与其它用例同一 block_chars，保证三组各自成块、不被跳过
        （块被跳过时 n_first=0，会落到 mixed/`-`，测的就不是过半数门槛了）。
        """
        blk_f, blk_t = _first_person_block(), _third_person_block()
        content = "\n\n".join([blk_f, blk_t, blk_t, blk_t, blk_t])
        _, summary = qa.detect_pov_drift([_ch(1, "第1章", content)],
                                         block_chars=170)
        s = summary[0]
        self.assertGreater(s["first_blocks"], 0, "first 块被判样本不足，样例失效")
        self.assertGreaterEqual(s["third_blocks"], 3, "third 块数不足，样例失效")
        self.assertEqual(s["dominant_pov"], "third",
                         f"first×1/third×4 被误标为 {s['dominant_pov']}")

    def test_dominant_pov_dash_when_all_blocks_skipped(self):
        """全部块样本不足时 dominant_pov 为 `-`（不是 'mixed'）。

        钉住这个区分：'-' 表示「没数据」，'mixed' 表示「有数据但混杂」。
        两者混用会让上层把「无法判断」当成「判断为人称混杂」。
        """
        content = "\n\n".join(["他走了。"] * 6)   # 每块都太短
        _, summary = qa.detect_pov_drift([_ch(1, "第1章", content)],
                                         block_chars=10_000)
        s = summary[0]
        self.assertEqual(s["first_blocks"], 0)
        self.assertEqual(s["third_blocks"], 0)
        self.assertEqual(s["dominant_pov"], "-",
                         "无任何可判定块时应为 '-'（无数据），而非 'mixed'")


class DiscoverNamesTest(unittest.TestCase):
    """关卡 2 的人名发现：误报是这里的主要风险。"""

    def test_finds_normal_name(self):
        text = "裴照推门进来。裴照看向他，裴照没有说话。"
        cands, _f, _l = qa.discover_names(text)
        self.assertTrue(any("裴照" in n for n in cands),
                        f"未发现正常人名：{dict(cands)}")

    def test_ignores_stop_names(self):
        """木头/马上 这类必须被 STOP_NAMES 拦掉（否则聚簇后成假主角）。"""
        text = "木头推开门。马上走了过去。木头回头看了一眼。"
        cands, _f, _l = qa.discover_names(text)
        bad = [n for n in cands if n in ("木头", "马上")]
        self.assertEqual(bad, [], f"STOP_NAMES 失效，误收：{bad}")

    def test_ignores_object_suffix(self):
        """陶罐/方向 类器物地名不得当人名。"""
        text = "陶罐摔碎了。方向不对，王村很远。"
        cands, _f, _l = qa.discover_names(text)
        bad = [n for n in cands if n[:2] in ("陶罐", "方向")]
        self.assertEqual(bad, [], f"OBJ_SUFFIX 失效，误收器物：{bad}")

    def test_long_name_merged_into_short(self):
        """长名归并：「裴照没」这类懒匹配切片须并入「裴照」。

        若归并失效，聚簇会多出一个「裴照没」，进而把正常书报成称谓漂移。
        """
        text = ("裴照没说话。裴照没有动。裴照看了一眼。"
                "裴照没动。裴照没有说话。裴照站住了。")
        cands, _f, _l = qa.discover_names(text)
        self.assertFalse([n for n in cands if n.endswith("没") or n.endswith("有")],
                         f"长名未归并，出现切片人名：{list(cands)}")
        self.assertTrue(any(n == "裴照" for n in cands),
                        f"归并后主名丢失：{list(cands)}")
class ClusterNamesTest(unittest.TestCase):
    def test_groups_by_surname(self):
        from collections import Counter
        cands = Counter({"裴照": 10, "裴远": 3, "苏小子": 8})
        clusters = qa.cluster_names(cands, {"裴照": 0, "裴远": 5, "苏小子": 2},
                                    {"裴照": 9, "裴远": 7, "苏小子": 6})
        self.assertIn("裴", clusters)
        self.assertIn("苏", clusters)
        self.assertEqual(clusters["裴"]["total"], 13)

    def test_sorted_by_frequency_desc(self):
        from collections import Counter
        cands = Counter({"裴照": 10, "苏小子": 8})
        clusters = qa.cluster_names(cands, {"裴照": 0, "苏小子": 1},
                                    {"裴照": 9, "苏小子": 2})
        vals = [c["total"] for c in clusters.values()]
        self.assertEqual(vals, sorted(vals, reverse=True))


class LoadChaptersTest(unittest.TestCase):
    def _tmp(self, text):
        import tempfile
        fh = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False,
                                         encoding="utf-8")
        fh.write(text)
        fh.close()
        return Path(fh.name)

    def test_splits_by_chapter_heading(self):
        # 章号必须用**阿拉伯数字**：CHAPTER_RE 是 `^\s*(第\s*\d+\s*章...)`，
        # 中文数字（第一章）匹配不上 —— 那是样例写错，不是切分逻辑的问题。
        text = "《测试书》" + "\n" + "第1章 起" + "\n" + "甲。" + "\n" \
               + "第2章 承" + "\n" + "乙。" + "\n"
        p = self._tmp(text)
        _title, chapters = qa.load_chapters(str(p))
        self.assertEqual(len(chapters), 2)
        self.assertEqual(chapters[0][1], "第1章 起")
        self.assertIn("甲", chapters[0][2])
        self.assertIn("乙", chapters[1][2])

    def test_extracts_book_title(self):
        p = self._tmp("《逆鳞焚天》" + "\n" + "第1章 起" + "\n" + "甲。" + "\n")
        title, _ = qa.load_chapters(str(p))
        self.assertEqual(title, "逆鳞焚天")

    def test_no_chapter_heading_treated_as_single_chapter(self):
        """无章标题的成书整本算第 1 章（不能返回空）。"""
        p = self._tmp("这是一本没有任何章标题的正文。")
        _title, chapters = qa.load_chapters(str(p))
        self.assertEqual(len(chapters), 1)
        self.assertEqual(chapters[0][0], 1)


class RelationDriftTest(unittest.TestCase):
    """关卡 4：人物关系张冠李戴（排他型关系）。"""

    def test_empty_input_no_crash(self):
        qa.detect_relation_drift([])

    def test_no_relation_text_no_alert(self):
        """负样本：没有排他型关系表述时不得报（零误报优先）。"""
        text = "他走进院子，看着天边的云。风吹过树梢，落下几片叶子。"
        r = qa.detect_relation_drift([_ch(1, "第一章", text)])
        alerts = r.get("alerts", r) if isinstance(r, dict) else r
        self.assertFalse(alerts, f"无关系表述被误报：{alerts}")


if __name__ == "__main__":
    unittest.main()

    def test_empty_text_no_crash(self):
        cands, f, l = qa.discover_names("")
        self.assertEqual(dict(cands), {})
        self.assertEqual(f, {})
        self.assertEqual(l, {})