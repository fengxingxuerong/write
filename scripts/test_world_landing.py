#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""世界观落地（门禁 v7 第 13 项「世界观未落地」）修复的离线回归测试。

只验证提示词组装与评审判定，不发起任何网络请求。
背景：评审按专名**字面命中**判定落地，而旧版写手提示词只给整段 world 描述、
定点修提示词里连一个专名都没有 → 三章连挂阻断项且修一轮仍残留。
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fanqie_review  # noqa: E402
from generate_novel import _quality_repair_prompt, scene_prompt  # noqa: E402

TERMS = ("星髓", "深渊回廊", "守夜令", "玄铁司", "燎原城")
WORLD = {"currency": "星髓", "org": "玄铁司", "city": "燎原城"}
WORLD_LINE = "【世界观专名·本条为阻断项"


def _world_review(msg="大纲世界观专名 5 个在正文一个都没出现"):
    return {"problems": [{"type": "一致性", "msg": msg, "action": "重写"}],
            "verdict": "需修", "blockers": ["第 1 章：世界观未落地"],
            "redline": {"veto": [], "warn": []}}


class WorldConsistencyTest(unittest.TestCase):
    def test_missing_terms_reported(self):
        wc = fanqie_review.world_consistency("正文里没有任何专名", TERMS)
        self.assertEqual(wc["hit"], 0)
        self.assertEqual(wc["missing_total"], len(TERMS))
        self.assertEqual(wc["missing"], list(TERMS))

    def test_hit_and_missing_split(self):
        wc = fanqie_review.world_consistency("星髓与守夜令各一次", TERMS)
        self.assertEqual(wc["hit"], 2)
        self.assertEqual(wc["missing_total"], len(TERMS) - 2)
        self.assertIn("深渊回廊", wc["missing"])

    def test_empty_terms_returns_none(self):
        self.assertIsNone(fanqie_review.world_consistency("正文", ()))


class ReviewChapterWorldTest(unittest.TestCase):
    def test_message_and_blocker_name_missing_terms(self):
        row = fanqie_review.review_chapter(
            "他推开门走了进去。", "", 1, "玄幻", "林舟", TERMS, has_hook=True)
        msgs = [p["msg"] for p in row["problems"] if "世界观专名" in p["msg"]]
        self.assertEqual(len(msgs), 1)
        self.assertIn("待补", msgs[0])
        self.assertIn("星髓", msgs[0])
        self.assertIn("世界观未落地", row["blockers"])
        self.assertEqual(row["metrics"]["world"]["missing_total"], len(TERMS))

    def test_no_blocker_when_all_terms_landed(self):
        text = "星髓在深渊回廊里，守夜令交给玄铁司，燎原城的人在看。"
        row = fanqie_review.review_chapter(
            text, "", 1, "玄幻", "林舟", TERMS, has_hook=True)
        self.assertNotIn("世界观未落地", row["blockers"])
        self.assertFalse([p for p in row["problems"] if "世界观专名" in p["msg"]])

    def test_single_hit_is_modify_level(self):
        text = "星髓还亮着。"
        row = fanqie_review.review_chapter(
            text, "", 1, "玄幻", "林舟", TERMS, has_hook=True)
        hits = [p for p in row["problems"] if "世界观专名" in p["msg"]]
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["action"], "修改")
        self.assertIn("题材锁定不够紧", hits[0]["msg"])


class FixPromptWorldTest(unittest.TestCase):
    def test_names_missing_terms_and_required_count(self):
        prompt = fanqie_review.fix_prompt(_world_review(), "他推开门走了进去。", TERMS)
        self.assertIn(WORLD_LINE, prompt)
        for term in TERMS:
            self.assertIn(term, prompt)
        self.assertIn("还缺 5 个", prompt)
        self.assertIn("至少 5 个", prompt)
        self.assertIn("禁止换成近义词", prompt)

    def test_required_count_capped_by_missing(self):
        # 专名互相之间不能有 3 字/尾 2 字重合——_term_hit 是局部命中口径，用「专名0/专名10」
        # 这种同构名会互相误命中（测试踩到过一次），改用完全独立的专名
        terms = ("甲山", "乙河", "丙关", "丁城", "戊阁", "己塔",
                 "庚桥", "辛渡", "壬台", "癸殿", "子渊", "丑岭")
        content = "".join(terms[:9])  # 命中 9，缺 3
        prompt = fanqie_review.fix_prompt(_world_review("大纲世界观专名 12 个"), content, terms)
        self.assertIn("还缺 3 个", prompt)
        self.assertIn("至少 3 个", prompt)
        self.assertIn("癸殿", prompt)  # 缺失项被点名
        self.assertIn("丑岭", prompt)

    def test_all_terms_present_adds_no_world_block(self):
        prompt = fanqie_review.fix_prompt(_world_review(), "".join(TERMS), TERMS)
        self.assertNotIn(WORLD_LINE, prompt)

    def test_without_world_terms_keeps_old_behavior(self):
        prompt = fanqie_review.fix_prompt(_world_review(), "他推开门走了进去。")
        self.assertNotIn(WORLD_LINE, prompt)
        self.assertIn("评审器给出以下硬伤", prompt)

    def test_no_problems_still_returns_empty(self):
        clean = {"problems": [], "verdict": "可投", "blockers": [],
                 "redline": {"veto": [], "warn": []}}
        self.assertEqual(fanqie_review.fix_prompt(clean, "正文", TERMS), "")


class ScenePromptWorldTest(unittest.TestCase):
    def _prompt(self, **kw):
        return scene_prompt(1, 3, "起", "开场", ["开门"], "", "玄幻", world="玄铁司世界", **kw)

    def test_injects_term_checklist(self):
        prompt = self._prompt(world_terms=TERMS)
        self.assertIn("【世界观专名·本章必须落地】", prompt)
        self.assertIn("星髓", prompt)
        self.assertIn("至少自然带出其中 2 个", prompt)
        self.assertIn("按字面照抄", prompt)

    def test_default_keeps_old_prompt(self):
        self.assertNotIn("【世界观专名·本章必须落地】", self._prompt())

    def test_truncates_and_notes_extra_terms(self):
        prompt = self._prompt(world_terms=tuple(f"专名{i}" for i in range(12)))
        self.assertIn("专名9", prompt)
        self.assertNotIn("专名10", prompt)
        self.assertIn("另 2 个见大纲", prompt)


class RepairPromptWorldTest(unittest.TestCase):
    def test_quality_repair_prompt_names_terms(self):
        prompt = _quality_repair_prompt(
            "他推开门走了进去。", _world_review(),
            {"characters": [], "facts": []}, "玄幻", "林舟", "", TERMS)
        self.assertIn(WORLD_LINE, prompt)
        self.assertIn("深渊回廊", prompt)


class PipelineWiringTest(unittest.TestCase):
    """源码级守卫：两处写手调用与两处定点修调用都必须带上专名清单。"""

    def test_pipeline_call_sites_carry_world_terms(self):
        src = (Path(__file__).resolve().parent / "novel_pipeline.py").read_text(encoding="utf-8")
        self.assertIn("world_terms=review_world_terms", src)
        self.assertIn('world_terms=ctx["review_world_terms"]', src)
        self.assertIn('fix_prompt(rv, final_text, review_world_terms)', src)
        self.assertIn('fix_prompt(rv, final_text, ctx["review_world_terms"])', src)


class WorldTermsExtractionTest(unittest.TestCase):
    """专名池抽取：v7 实测《废柴修仙》world 三个字段只切出 1 个专名，瓶颈在全角分隔符。"""

    def test_fullwidth_slash_splits_factions(self):
        terms = fanqie_review.extract_world_terms(
            {"world": {"continent": "荒晷大陆", "faction": "天问宗／骨门／渊阁"}})
        self.assertIn("荒晷大陆", terms)
        self.assertIn("天问宗", terms)
        # 未加引号的 2 字片段仍按「片段 ≥3 字」规则挡掉，避免「秩序/资本」类噪声进池
        self.assertNotIn("骨门", terms)

    def test_quoted_two_char_name_still_accepted(self):
        terms = fanqie_review.extract_world_terms({"world": {"currency": "『星髓』"}})
        self.assertIn("星髓", terms)


class ThinTermPoolTest(unittest.TestCase):
    """专名池只有 1-2 个时，提示词必须给做得到的名额（v7 实测该书只切出 1 个）。"""

    def test_single_term_quota_degrades(self):
        prompt = scene_prompt(1, 3, "起", "开场", ["开门"], "", "玄幻",
                              world="荒晷大陆", world_terms=("荒晷大陆",))
        self.assertIn("其中 1 个（全章合计不少于 1 个）", prompt)

    def test_two_term_quota_degrades(self):
        prompt = scene_prompt(1, 3, "起", "开场", ["开门"], "", "玄幻",
                              world="x", world_terms=("荒晷大陆", "天问宗"))
        self.assertIn("其中 2 个（全章合计不少于 2 个）", prompt)


class FixPromptLengthFloorTest(unittest.TestCase):
    """定点修字数下限（门禁 v7 第 4 项「编辑链过度压缩」的根因修复）。

    实测证据：4 次告警全部来自定点修（`[评审修]`），产出比原文少 30%~75%，
    低于 apply_text_patch 的 0.85 下限 → 整份被拒、定点修白跑、问题原地复发。
    提示词里此前**没有任何字数下限**，只有「删水段/25 字句/3 行段」三条压缩指令。
    """

    def _prompt(self, content):
        return fanqie_review.fix_prompt(_world_review(), content, TERMS)

    def test_states_floor_and_conflict_resolution(self):
        content = "他推开门。" * 100  # 500 字
        prompt = self._prompt(content)
        words = fanqie_review.count_words(content)
        floor = int(words * fanqie_review.FIX_MIN_RATIO)
        self.assertIn(f"不得少于 {floor} 字", prompt)
        self.assertIn(f"原文 {words} 字", prompt)
        self.assertIn("最多允许压缩 8%", prompt)
        self.assertIn("以本下限为准", prompt)
        self.assertIn("总字数不得下降", prompt)

    def test_floor_is_stricter_than_pipeline_guard(self):
        # 采纳守卫默认 0.85；提示词下限必须更高一档，否则产出必然被拒
        import novel_pipeline
        self.assertGreater(fanqie_review.FIX_MIN_RATIO,
                           novel_pipeline.EDITOR_MIN_RATIO)

    def test_compression_instruction_qualified(self):
        prompt = self._prompt("他推开门。" * 100)
        self.assertNotIn("删掉所有「删了不影响剧情」的段落", prompt)
        self.assertIn("只删与剧情无关的水段", prompt)

    def test_empty_content_omits_floor(self):
        # 空正文时不发下限区块（引用它的那句「见上文【字数硬约束】」仍在，属无害悬空引用）
        prompt = fanqie_review.fix_prompt(_world_review(), "")
        self.assertNotIn("【字数硬约束·先看这条】", prompt)


if __name__ == "__main__":
    unittest.main()
