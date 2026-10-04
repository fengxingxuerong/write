#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""instructionMarks 作用域白名单（Dart _narrativeOkCategories）的对齐回归。

背景（2026-10-03）：
`instructionMarks` 已收编进单一数据源，两端词表同源了，但它的**作用域白名单**
`narrativeOkCategories` 仍是两端各写一份、键集不同：

    Dart  : {违法违规, 宗教民族, 现实品牌与真人, 广告引流}
    Python: {教唆与违法细节, 宗教民族, 现实品牌与真人}

而 Dart 的 `_extraRedline` 里教唆类红线的**真实分类名是「教唆细节」**——
既不在 Dart 白名单里，也不等于 Python 的「教唆与违法细节」。三者互不相同。

真实缺陷：因「教唆细节」不在白名单，该类红线 `narrativeOk` 恒为 false →
`veto = !narrativeOk || ...` 恒为 true → **教唆语境判定形同虚设**，
小说里仅提及「土制炸弹」也会被判否决，正是 Python 注释记载要避免的
「误伤《碎星航线》第 1 章」。

本测试的价值（本机无 Flutter SDK，跑不了 flutter test）：
用 Python 精确复刻 Dart 的判定分支，对「修复前/修复后」两个白名单跑同一段
文本，给出「修复方向是否正确」的可执行证据，并钉死不得回退。
它**不替代** test/engine/quality/fanqie_gate_checker_test.dart 里的 Dart 用例
（那才是真正跑 Dart 逻辑的地方），只保证在 CI 上 Python 侧也能拦住这类回归。

另附源码级断言：Dart 侧白名单必须同时含「教唆细节」与「违法违规」——
两条教唆路径（番茄专有红线 / 编辑自查词库）缺一即红。
"""
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]   # scripts/ 的上一级 = 仓库根
sys.path.insert(0, str(ROOT / "scripts"))

import quality_rules_generated as gen  # noqa: E402

import ab_rules_parity as ab  # noqa: E402

# Dart _extraRedline 的分类名与词表（逐字抄自
# lib/engine/quality/fanqie_gate_checker.dart）——只取本测试用到的两类。
DART_EXTRA_REDLINE = {
    "教唆细节": ["制作炸药的方法", "土制炸弹", "开锁技巧", "伪造身份证", "办假证",
                 "洗钱方法", "下毒剂量", "自制枪支", "弩的图纸"],
    "宗教民族": ["邪教徒", "圣战", "异教徒该死", "侮辱", "藏传佛教活佛转世", "请神",
                 "问米", "通灵", "招魂", "借尸还魂", "苗疆蛊", "蛊毒", "降头",
                 "养小鬼"],
}
MARKERS = list(gen.INSTRUCTION_MARKS)      # 收编后的 24 词，两端同源

# 修复前 / 修复后的 Dart 白名单
OK_BEFORE = {"违法违规", "宗教民族", "现实品牌与真人", "广告引流"}
OK_AFTER = OK_BEFORE | {"教唆细节"}

DART_SRC = ROOT / "lib" / "engine" / "quality" / "fanqie_gate_checker.dart"

CASES = [
    ("教唆细节｜无语境", "教唆细节", "土制炸弹", "坊间传闻有人私藏土制炸弹，皆是谣传。"),
    ("教唆细节｜有语境", "教唆细节", "土制炸弹", "他写下土制炸弹的制作配方，照做即可。"),
    ("宗教民族｜无语境", "宗教民族", "请神", "老人说请神是旧俗，不可轻信。"),
    ("宗教民族｜有语境", "宗教民族", "请神", "书里附了请神的教程，教你怎么画符。"),
]


def dart_veto(cat: str, word: str, text: str, narrative_ok: set) -> bool:
    """复刻 Dart `_scanRedlines` 的 veto 分支：!narrativeOk || 窗口内有 marker。"""
    if cat not in narrative_ok:
        return True                      # 非叙事成立分类：恒为否决
    i = text.find(word)
    if i < 0:
        return False
    wide = text[max(0, i - 40):i + len(word) + 40]
    return any(m in wide for m in MARKERS)


def dart_narrative_ok_keys() -> set:
    """从 Dart 源码解析 _narrativeOkCategories 的实际键集。

    刻意解析源码而非手抄：手抄的那份会在修复后变成过期副本，得出「已修好」
    的假结论——本轮就是这么发现的（ab_rules_parity 里同类问题已修过一次）。
    """
    m = re.search(
        r"_narrativeOkCategories\s*=\s*<String>\{(.*?)\}",
        DART_SRC.read_text(encoding="utf-8"), re.S)
    assert m, "未在 fanqie_gate_checker.dart 找到 _narrativeOkCategories"
    return set(re.findall(r"'([^']+)'", m.group(1)))


class ExtraRedlineAdoptionTest(unittest.TestCase):
    """番茄红线五类的收编状态：4 类同源 + 1 类故意分歧。

    背景（2026-10-03）：Dart `_extraRedline` 原为 5 类 56 词硬编码，其中 4 类
    是生成物 `redline*` 的**真子集**（时政 13/30、未成年 11/17、品牌真人 17/25、
    教唆 9/15）。子集即漏判——Python 有词、Dart 无词 → 不判违规。
    实测这 4 类 Python 独有的 37 词在 134 份真实成书**零命中**，故取全集
    不新增误判，同时消除漏判。「宗教民族」双向独有且生成物独有的「礼拜」
    会命中真实成书，故**故意不收编**，须产品裁决。
    """

    EXPECTED_IDENTICAL = ["时政敏感", "未成年风险", "现实品牌与真人", "教唆细节"]
    EXPECTED_DIVERGENT = ["宗教民族"]

    @classmethod
    def setUpClass(cls):
        corpus = ab.load_corpus()
        if not corpus:
            raise unittest.SkipTest("真实语料为空（data/ 与人评样本章缺失）")
        cls.result = ab.analyze(corpus)["extraRedlineTables"]

    def test_four_categories_are_now_identical(self):
        for cat in self.EXPECTED_IDENTICAL:
            r = self.result[cat]
            self.assertEqual(
                "identical", r["kind"],
                f"{cat} 已收编但仍报 {r['kind']}（Python 独有 {r['py_only']} / "
                f"Dart 独有 {r['dart_only']}）——若 Dart 侧退回字面量，"
                f"ab_rules_parity 的源码解析会重新看到子集")

    def test_religion_stays_divergent_by_design(self):
        """宗教民族必须**保持分歧**——收编它会立刻改变真实成书的判定。"""
        r = self.result["宗教民族"]
        self.assertEqual(
            "divergent", r["kind"],
            "宗教民族不应被收编：生成物独有的「礼拜」在真实成书里会命中，"
            "合并即改变判定，属须产品裁决的口径分歧")
        self.assertIn("侮辱", r["dart_only"],
                      "Dart 侧自有词表被改动——「侮辱」等词极易误伤正常叙述，"
                      "改动前须重新评估")

    def test_no_new_misjudgement_introduced(self):
        """收编不得引入误判：Python 独有词在真实语料上仍应零命中。

        这是收编的核心风险——取全集意味着 Dart 会判更多词。若将来这些词
        开始在真实成书里高频出现，说明收编引入了误判，需重新裁决。
        """
        for cat in self.EXPECTED_IDENTICAL:
            r = self.result[cat]
            self.assertEqual(
                0, r["py_files_affected"],
                f"{cat} 收编后 Python 独有词命中 "
                f"{r['py_files_affected']}/{r['files_total']} 份："
                f"{r['py_hit_counts']} —— 收编引入了误判")

    def test_dart_source_parses_to_expected_shape(self):
        """Dart 源码解析必须能读出 5 个分类——解析失效会让 A/B 工具整节消失。"""
        keys = set(ab.DART_EXTRA_REDLINE)
        for cat in self.EXPECTED_IDENTICAL + self.EXPECTED_DIVERGENT:
            self.assertIn(
                cat, keys,
                f"_dart_extra_redline() 未解析到「{cat}」——Dart 侧写法变了，"
                f"或该分类被删除。实际解析到：{sorted(keys)}")


class NarrativeOkScopeTest(unittest.TestCase):
    """作用域白名单：教唆类必须能区分「叙事提及」与「教唆传授」。"""

    def test_bug_reproduces_with_pre_fix_whitelist(self):
        """修复前必须确实存在缺陷——否则「修复」可能什么都没修。"""
        self.assertTrue(
            dart_veto("教唆细节", "土制炸弹", CASES[0][3], OK_BEFORE),
            "未能复现缺陷：修复前「教唆细节」无语境应恒为否决")

    def test_narrative_only_mention_is_not_veto_after_fix(self):
        """修复后：仅叙事提及「土制炸弹」不得否决。"""
        self.assertFalse(
            dart_veto("教唆细节", "土制炸弹", CASES[0][3], OK_AFTER),
            "无语境的教唆类红线仍被否决——白名单仍缺「教唆细节」")

    def test_instruction_context_still_upgrades_to_veto(self):
        """修复后：有教唆语境必须仍升级为否决（不能一味放宽）。"""
        self.assertTrue(
            dart_veto("教唆细节", "土制炸弹", CASES[1][3], OK_AFTER),
            "有教唆语境却未升级为否决——修复过头了")

    def test_other_categories_unaffected(self):
        """修复不得波及其他分类（宗教民族路径前后一致）。"""
        for label, cat, word, text in CASES[2:]:
            self.assertEqual(
                dart_veto(cat, word, text, OK_BEFORE),
                dart_veto(cat, word, text, OK_AFTER),
                f"{label} 的判定被本次修复意外改变")

    def test_dart_source_whitelist_covers_both_teaching_paths(self):
        """源码级：白名单必须同时含「教唆细节」与「违法违规」。

        两条教唆路径缺一即红：
        - 教唆细节：番茄专有红线（_extraRedline）；
        - 违法违规：编辑自查词库（SensitiveWordsService）里的违法操作类。
        """
        keys = dart_narrative_ok_keys()
        for required in ("教唆细节", "违法违规"):
            self.assertIn(
                required, keys,
                f"Dart _narrativeOkCategories 缺 {required}——"
                f"该类红线将恒为否决（教唆语境判定失效）。当前：{sorted(keys)}")

    def test_dart_source_has_no_stale_duplicate_whitelist(self):
        """白名单只能有一处定义，多处必然漂移。"""
        text = DART_SRC.read_text(encoding="utf-8")
        self.assertEqual(
            1, text.count("_narrativeOkCategories ="),
            "fanqie_gate_checker.dart 出现多处 _narrativeOkCategories 定义")


if __name__ == "__main__":
    unittest.main()