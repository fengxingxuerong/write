#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""字数口径收敛回归（2026-09-29）。

背景：此前仓库里有**三套**互不相同的字数实现（`fanqie_review.count_words` /
`generate_novel.count_words` / Dart `AppConstants.countWords`），三处都自称
「同口径」，实测同一本书两端差 0.028%（正文）/ 最多 20%（ASCII 密集报表）。
现统一到 Dart 版（Dart 是界面显示的那一套，故**对用户零可见变化**）。

本测试把「唯一定义 + 双端一致 + 关键边界语义」钉死，防止再次各自漂移。
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import fanqie_review as fr  # noqa: E402
import generate_novel as gn  # noqa: E402


def dart_reference(text):
    """Dart `AppConstants.countWords` 的逐字符等价实现（改 Dart 时同步改这里）。"""
    if not text:
        return 0
    count = 0
    in_ascii = False
    for ch in text:
        r = ord(ch)
        if (0x3400 <= r <= 0x4DBF or 0x4E00 <= r <= 0x9FFF
                or 0xF900 <= r <= 0xFAFF):
            count += 1
            in_ascii = False
        elif (0x41 <= r <= 0x5A or 0x61 <= r <= 0x7A
              or 0x30 <= r <= 0x39):
            if not in_ascii:
                count += 1
                in_ascii = True
        else:
            in_ascii = False
    return count


class CountWordsUnifiedTest(unittest.TestCase):
    """三套实现收敛为一套，且与 Dart 逐字符等价。"""

    def test_all_python_sites_are_one_implementation(self):
        # generate_novel 必须是薄转发而非第二份实现
        self.assertIs(gn.count_words("MVP2024"), fr.count_words("MVP2024"))
        for s in ("", "汉字", "MVP2024", "\u3400", "abc 123", "中英mixed混排"):
            self.assertEqual(gn.count_words(s), fr.count_words(s), s)

    def test_matches_dart_reference(self):
        for s in ("", "汉字", "MVP2024", "\u3400\u4DBF", "中英mixed混排",
                  "他推开门，鸦雀无声。", "第 1 章\n\n正文"):
            self.assertEqual(fr.count_words(s), dart_reference(s), s)

    def test_key_boundary_semantics(self):
        # 数字与字母连续算一个词（MVP2024 = 1）——中英混排的直觉
        self.assertEqual(fr.count_words("MVP2024"), 1)
        # CJK 扩展A 计入（旧 Python 口径漏算，是当初两端不一致的主因之一）
        self.assertEqual(fr.count_words("\u3400"), 1)
        # 标点/空白不单独计词
        self.assertEqual(fr.count_words("，。（） \n\t"), 0)
        # 空串
        self.assertEqual(fr.count_words(""), 0)
        self.assertEqual(fr.count_words(None), 0)


class CountWordsRealBookTest(unittest.TestCase):
    """真实成书回归：两端口径必须逐字相等。"""

    def test_real_book_matches_dart(self):
        book = ROOT / "data" / "generated" / "novel_10w_pipeline.txt"
        if not book.exists():
            self.skipTest("真实成书产物不在（data/ 已 gitignore）")
        text = book.read_text(encoding="utf-8")
        self.assertEqual(fr.count_words(text), dart_reference(text))
        # 收敛后的值应等于 Dart 侧（106636），不再是旧的 106660
        self.assertEqual(fr.count_words(text), 106636)


if __name__ == "__main__":
    unittest.main()