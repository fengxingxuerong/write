#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""md_projection 随书 Markdown 投影回归测试（纯本地，不发起网络请求）。"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from md_projection import (  # noqa: E402
    export_projections,
    load_projection_state,
    render_control_md,
    render_foreshadow_md,
    render_state_md,
)


def _write_jsonl(path, records):
    with open(path, "w", encoding="utf-8") as f:
        for rec in records:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def _sample_records():
    outline = {
        "title": "测试书",
        "hook": "开局就是钩子",
        "blurb": "一段简纲",
        "tags": ["玄幻", "热血"],
        "protagonist": {"name": "张三", "trait": "坚韧"},
        "chapter_outlines": [
            {"idx": 1, "title": "第一章", "goal": "目标一"},
            {"idx": 2, "title": "第二章", "goal": "目标二"},
            {"idx": 3, "title": "第三章", "goal": "目标三"},
        ],
    }
    ledger = {"foreshadows": [
        {"desc": "古剑来历不明", "planted": 1, "recovered": None, "status": "open"},
        {"desc": "超时伏笔", "planted": 1, "recovered": None, "status": "open"},
        {"desc": "已收伏笔", "planted": 1, "recovered": 2, "status": "closed"},
    ]}
    registry = {"characters": [{"name": "张三", "identity": "主角", "first_seen": 1}],
                "facts": [{"value": "三百", "first_seen": 1}]}
    return [
        {"type": "outline", "data": outline},
        {"type": "state_track", "data": "张三：淬体三层；地点：破庙"},
        {"type": "foreshadow", "data": json.dumps(ledger, ensure_ascii=False)},
        {"type": "registry", "data": registry},
        {"type": "chapter", "data": {"idx": 1, "title": "第一章", "content": "正文一", "words": 100}},
        {"type": "chapter", "data": {"idx": 2, "title": "第二章", "content": "正文二", "words": 200}},
        {"type": "chapter", "data": {"idx": 3, "title": "第三章", "content": "正文三", "words": 300}},
        {"type": "review", "data": {"idx": 3, "score": 82.0, "problems": [
            {"type": "句长", "msg": "超长句偏多"}], "blockers": []}},
        {"type": "reader_feedback", "data": {"idx": 3, "feedback": "追，想看打脸"}},
        # 坏行不应让投影崩溃
        {"type": "chapter", "data": {"idx": "bad", "content": "非法"}},
    ]


class MdProjectionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.jsonl = os.path.join(self.tmp.name, "book.jsonl")
        _write_jsonl(self.jsonl, _sample_records())
        # jsonl 中夹一行损坏数据
        with open(self.jsonl, "a", encoding="utf-8") as f:
            f.write("{broken json\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_load_state_last_wins_and_skips_bad(self):
        st = load_projection_state(self.jsonl)
        self.assertEqual(st["outline"]["title"], "测试书")
        self.assertEqual(len(st["chapters"]), 3)  # idx 非法的 chapter 被过滤
        self.assertEqual(st["reviews"][3]["score"], 82.0)
        self.assertEqual(st["reader_feedback"], "追，想看打脸")
        self.assertEqual(len(st["foreshadows"]), 3)

    def test_state_md_contains_state_registry_facts(self):
        md = render_state_md(load_projection_state(self.jsonl), self.jsonl)
        self.assertIn("张三：淬体三层", md)
        self.assertIn("| 张三 | 主角 | 第1章 |", md)
        self.assertIn("| 三百 | 第1章 |", md)

    def test_foreshadow_md_split_and_stale_warn(self):
        st = load_projection_state(self.jsonl)
        md = render_foreshadow_md(st, self.jsonl)
        self.assertIn("未回收（open）· 2 条", md)
        self.assertIn("已回收（closed）· 1 条", md)
        # 第 1 章埋、第 3 章末尾：超时阈值 5 未到，不告警；到 5 章才告警
        self.assertNotIn("⚠ 已", md)
        st["chapters"] = [{"idx": 7, "words": 1}]
        md7 = render_foreshadow_md(st, self.jsonl)
        self.assertIn("⚠ 已6章未收", md7)

    def test_control_md_intent_fallback_and_next_chapter(self):
        md = render_control_md(load_projection_state(self.jsonl), self.jsonl)
        self.assertIn("无 type=author_intent 记录", md)
        self.assertIn("核心钩子：开局就是钩子", md)
        self.assertIn("### 第 1 章", md)      # 近 3 章 = 1..3
        self.assertNotIn("### 第 0 章", md)
        # 末章=3，大纲只有 1..3 章 → 无下一章记录（而非错报第 1 章）
        self.assertIn("_大纲中无下一章记录_", md)
        self.assertNotIn("《第一章》目标", md)
        self.assertIn("追，想看打脸", md)

    def test_control_md_author_intent_record_wins(self):
        _write_jsonl(self.jsonl, _sample_records() + [
            {"type": "author_intent", "data": "本卷主线：三章内完成第一次打脸"}])
        md = render_control_md(load_projection_state(self.jsonl), self.jsonl)
        self.assertIn("三章内完成第一次打脸", md)
        self.assertNotIn("无 type=author_intent 记录", md)

    def test_export_projections_writes_three_files(self):
        written = export_projections(self.jsonl)
        self.assertEqual(len(written), 3)
        names = sorted(os.path.basename(p) for p in written)
        self.assertEqual(names, sorted(
            ["book.当前状态.md", "book.伏笔台账.md", "book.控制面.md"]))
        for p in written:
            self.assertTrue(os.path.getsize(p) > 0)
        # 权威账本不被改写
        self.assertTrue(os.path.exists(self.jsonl))

    def test_export_missing_file_returns_empty(self):
        self.assertEqual(export_projections(os.path.join(self.tmp.name, "nope.jsonl")), [])


if __name__ == "__main__":
    unittest.main()
