#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""文风指纹（P1-1 第一阶段）：分析 / 渲染 / 距离 / 注入 的离线回归测试。"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_novel import (  # noqa: E402
    fingerprint_distance,
    scene_prompt,
    style_fingerprint,
    style_fingerprint_block,
)

# 参考文风格 A：对白密集 + 短句
DIALOGUE_STYLE = "\n".join(
    "「你来做什么。」他推开门。\n「找你。」她抬头。" for _ in range(30))
# 参考文风格 B：叙述密集 + 长句
NARRATIVE_STYLE = "\n".join(
    "暮色四合的山道上，那个背着旧剑的旅人一步一步向山脊走去，"
    "风把他的衣角掀起又放下，像某种迟疑的手势。" for _ in range(20))


class StyleFingerprintTest(unittest.TestCase):
    def test_keys_complete_and_deterministic(self):
        fp = style_fingerprint(DIALOGUE_STYLE, source="ref.txt")
        keys = {"source", "words", "sent_len_mean", "sent_len_cv",
                "dialogue_ratio", "para_len_mean", "single_para_rate",
                "de_density", "adverb_density", "connector_rate",
                "metaphor_density"}
        self.assertEqual(set(fp), keys)
        self.assertEqual(fp["source"], "ref.txt")
        self.assertEqual(fp, style_fingerprint(DIALOGUE_STYLE, "ref.txt"))

    def test_empty_text_returns_zero_fp(self):
        fp = style_fingerprint("")
        self.assertEqual(fp["words"], 0)
        self.assertEqual(fp["sent_len_mean"], 0.0)

    def test_style_directions_distinguishable(self):
        dia = style_fingerprint(DIALOGUE_STYLE)
        nar = style_fingerprint(NARRATIVE_STYLE)
        # 对白风格的对白占比显著更高、句长更短
        self.assertGreater(dia["dialogue_ratio"], nar["dialogue_ratio"])
        self.assertLess(dia["sent_len_mean"], nar["sent_len_mean"])
        # 距离应显著大于 0
        self.assertGreater(fingerprint_distance(dia, nar), 0.2)


class FingerprintBlockTest(unittest.TestCase):
    def test_block_renders_numbers_and_guard(self):
        fp = style_fingerprint(DIALOGUE_STYLE, source="我的参考文")
        block = style_fingerprint_block(fp)
        self.assertIn("我的参考文", block)
        self.assertIn("禁止照抄", block)
        self.assertIn("对白占比", block)
        self.assertIn("句长", block)
        self.assertIn("向参考文靠拢", block)

    def test_empty_fp_renders_nothing(self):
        self.assertEqual(style_fingerprint_block({}), "")
        self.assertEqual(
            style_fingerprint_block(style_fingerprint("")), "")

    def test_distance_identical_is_zero(self):
        fp = style_fingerprint(NARRATIVE_STYLE)
        self.assertEqual(fingerprint_distance(fp, fp), 0.0)


class ScenePromptStyleInjectionTest(unittest.TestCase):
    def test_style_block_injected_before_handoff(self):
        p = scene_prompt(
            1, 2, "起", "目标", "节拍", "上一段",
            style_block="\n【目标文风指纹（参考《x》）】y")
        self.assertIn("目标文风指纹", p)
        # 注入块位于「上一段的情境」之前，钩子/状态等硬约束不受影响
        self.assertLess(
            p.index("目标文风指纹"), p.index("上一段的情境"))
        self.assertIn("只输出场景正文", p)

    def test_default_no_injection(self):
        # 不传 style_block 时 prompt 不含指纹头（旧调用行为完全不变）
        p = scene_prompt(1, 2, "起", "目标", "节拍", "")
        self.assertNotIn("目标文风指纹", p)


class LoadStyleBlockAndEvidenceTest(unittest.TestCase):
    def test_load_from_file_and_missing(self):
        import tempfile
        from generate_novel import load_style_block
        # 空路径 → 不注入
        self.assertEqual(load_style_block(""), ("", None))
        with tempfile.NamedTemporaryFile(
                "w", suffix=".txt", delete=False,
                encoding="utf-8") as f:
            f.write(DIALOGUE_STYLE)
            path = f.name
        try:
            block, fp = load_style_block(path)
            self.assertIn("目标文风指纹", block)
            self.assertGreater(fp["words"], 0)
            # source 用文件名（提示词里展示《xxx》）
            self.assertTrue(path.endswith(fp["source"]) or
                            fp["source"] in path)
        finally:
            Path(path).unlink(missing_ok=True)
        # 不存在的路径 → ("", None) 不抛异常
        self.assertEqual(
            load_style_block(path + ".nope"), ("", None))

    def test_style_ev_fragment(self):
        from generate_novel import style_ev_fragment
        self.assertEqual(style_ev_fragment(None, DIALOGUE_STYLE), "")
        ref = style_fingerprint(DIALOGUE_STYLE, source="ref")
        ev = style_ev_fragment(ref, NARRATIVE_STYLE)
        self.assertIn("文风：与参考文距离", ev)
        self.assertIn("句长均值", ev)
        self.assertIn("rhythm", ev)


class EditorPromptStyleKeepTest(unittest.TestCase):
    def test_editor_prompt_with_and_without_style(self):
        from novel_pipeline import editor_prompt
        plain = editor_prompt("正文")
        self.assertNotIn("文风分布", plain)
        self.assertIn("【章节正文】", plain)
        block = style_fingerprint_block(
            style_fingerprint(DIALOGUE_STYLE, source="ref"))
        kept = editor_prompt("正文", style_block=block)
        self.assertIn("不得把这些指标改离参考文", kept)
        self.assertIn("目标文风指纹", kept)
        self.assertIn("【章节正文】", kept)


if __name__ == "__main__":
    unittest.main()
