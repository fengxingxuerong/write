#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""负样本验证：新加的守卫**必须真能红**。

背景：本项目的核心纪律是「门禁必须真能失败」——仓库里有过「基线缺失即 SKIP
通过」的假绿事故。一个永远为真的断言比没有断言更糟：它给人虚假的安全感。

故逐条注入故障，确认对应用例确实转红，然后复原。
"""
import io
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

TARGETS = {
    # 故障注入点 -> 会转红的用例（同一模块内，避免跨模块依赖）
    "fanqie_review.py": "test_quality_single_source.InstructionMarkVerdictTest",
    "ab_rules_parity.py": "test_quality_single_source.InstructionMarkVerdictTest",
    "rules/quality_rules.json": "test_quality_rules_parity.QualityRulesParityTest",
    "lib/engine/quality/fanqie_gate_checker.dart":
        "test_quality_rules_parity.QualityRulesParityTest",
}


def run_suite(path_rel):
    """用**文件路径**加载测试模块，并在每次运行前清掉相关模块缓存。

    两个坑（都踩过）：
    1. 不能用 `loadTestsFromName("scripts.test_x")`——scripts 无 __init__.py，
       `python -m unittest scripts.test_x` 能过是因为 -m 走了不同的导入路径，
       程序内调用则 ModuleNotFoundError。而它**不会报错退出**，只是让每个用例
       变成 error——若不看 traceback，会误判成「守卫已验证通过」。
    2. 必须清 sys.modules：注入故障改的是磁盘文件，模块对象仍是旧的，
       下一轮会看到脏状态，得出「基线也红」的错误结论。
    """
    for name in [n for n in list(sys.modules)
                 if n in ("ab_rules_parity", "fanqie_review", "generate_novel",
                          "novel_pipeline", "pipeline_llm",
                          "quality_rules_generated", "foreshadow",
                          "fanqie_prompts")
                 or n.startswith("test_quality_")
                 or n.startswith("test_narrative_")]:
        del sys.modules[name]
    loader = unittest.TestLoader()
    return loader.discover(str(ROOT / "scripts"), pattern=path_rel)


def main() -> int:
    failures = []

    def check(label, path_rel, expect_red=True):
        suite = run_suite(path_rel)
        n = suite.countTestCases()
        if n == 0:
            print(f"BAD  {label}: 匹配到 0 个用例——守卫没被发现，验证无意义")
            failures.append(label)
            return
        res = unittest.TextTestRunner(verbosity=0, stream=io.StringIO()).run(suite)
        red = not res.wasSuccessful()
        ok = red == expect_red
        print(f"{'OK ' if ok else 'BAD'}  {label}: "
              f"{'如期转红' if red else '仍然全绿'}（期望{'红' if expect_red else '绿'}）")
        if not ok:
            failures.append(label)
            for _, tb in res.failures + res.errors:
                print(tb[-1400:])

    # 基线：未注入时必须全绿，否则下面的「转红」没有意义。
    check("基线 single_source", "test_quality_single_source.py", expect_red=False)
    check("基线 rules_parity", "test_quality_rules_parity.py", expect_red=False)
    check("基线 narrative_ok", "test_narrative_ok_scope.py", expect_red=False)
    check("基线 fake_green", "test_fake_green_guard.py", expect_red=False)

    # 故障 1：ab_rules_parity 退回「收编前的过期副本」（手抄 21 词）。
    p = ROOT / "scripts" / "ab_rules_parity.py"
    orig = p.read_text(encoding="utf-8")
    try:
        p.write_text(
            orig.replace(
                "DART_INSTRUCTION_MARK = list(gen.INSTRUCTION_MARKS)",
                'DART_INSTRUCTION_MARK = ["方法", "教程", "步骤"]'),
            encoding="utf-8")
        check("注入 A/B 工具过期副本", "test_quality_single_source.py")
    finally:
        p.write_text(orig, encoding="utf-8")

    # 故障 2：生成物里丢掉「招募」（模拟收编搬运中丢词）。
    p = ROOT / "scripts" / "quality_rules_generated.py"
    orig = p.read_text(encoding="utf-8")
    try:
        p.write_text(orig.replace('    "招募",\n', ""), encoding="utf-8")
        check("生成物丢失「招募」", "test_quality_single_source.py")
    finally:
        p.write_text(orig, encoding="utf-8")

    # 故障 3：Dart 侧退回字面量（模拟收编只做了一半）。
    p = ROOT / "lib" / "engine" / "quality" / "fanqie_gate_checker.dart"
    orig = p.read_text(encoding="utf-8")
    try:
        p.write_text(
            orig.replace(
                "static const List<String> _instructionMark = "
                "QualityRules.instructionMarks;",
                "static const List<String> _instructionMark = <String>['方法'];"),
            encoding="utf-8")
        check("Dart 侧退回字面量", "test_quality_rules_parity.py")
    finally:
        p.write_text(orig, encoding="utf-8")

    # 故障 4：把 Dart 白名单的「教唆细节」删掉（模拟本次修复被回退）。
    p = ROOT / "lib" / "engine" / "quality" / "fanqie_gate_checker.dart"
    orig = p.read_text(encoding="utf-8")
    try:
        p.write_text(
            orig.replace("'教唆细节', '违法违规', '宗教民族', '现实品牌与真人', '广告引流',",
                         "'违法违规', '宗教民族', '现实品牌与真人', '广告引流',"),
            encoding="utf-8")
        check("Dart 白名单缺「教唆细节」",
              "test_narrative_ok_scope.py")
    finally:
        p.write_text(orig, encoding="utf-8")

    # 故障 5：Dart _extraRedline 退回字面量（模拟 4 类收编被回退）。
    p = ROOT / "lib" / "engine" / "quality" / "fanqie_gate_checker.dart"
    orig = p.read_text(encoding="utf-8")
    try:
        p.write_text(
            orig.replace("'时政敏感': QualityRules.redlinePolitics,",
                         "'时政敏感': <String>['国家主席', '国务院'],")
                .replace("'教唆细节': QualityRules.redlineIllegalDetail,",
                         "'教唆细节': <String>['土制炸弹'],"),
            encoding="utf-8")
        check("Dart _extraRedline 退回字面量", "test_narrative_ok_scope.py")
    finally:
        p.write_text(orig, encoding="utf-8")

    # 故障 6：把「宗教民族」也收编了（模拟误把口径分歧类一并合并）。
    try:
        p.write_text(
            orig.replace(
                "    // 宗教民族：故意保留 Dart 自有词表（见上方说明），不引生成物。\n"
                "    '宗教民族': <String>[\n"
                "      '邪教徒', '圣战', '异教徒该死', '侮辱', '藏传佛教活佛转世', '请神', '问米',\n"
                "      '通灵', '招魂', '借尸还魂', '苗疆蛊', '蛊毒', '降头', '养小鬼',\n"
                "    ],",
                "    '宗教民族': QualityRules.redlineReligion,"),
            encoding="utf-8")
        check("宗教民族被误收编", "test_narrative_ok_scope.py")
    finally:
        p.write_text(orig, encoding="utf-8")

    # 故障 7：把 crash_reporter_test.dart 改回「用 HTTP 假装测 500」的假绿形态，
# 确认 test_fake_green_guard 能抓住它（即守卫本身不是恒真断言）。
    p = ROOT / "test" / "core" / "crash_reporter_test.dart"
    orig = p.read_text(encoding="utf-8")
    try:
        p.write_text(
            orig.replace(
                "test('HTTP 地址被拒绝：抛 HTTPS 约束异常（测不到 500 分支）', () async {",
                "test('服务器返回 500 抛异常', () async {"),
            encoding="utf-8")
        # 同时去掉其诚实性声明（注释与 received 断言），还原成原始假绿写法。
        txt = p.read_text(encoding="utf-8")
        txt = txt.replace("测不到", "XXX")
        p.write_text(txt, encoding="utf-8")
        check("崩溃上报测试退回假绿形态", "test_fake_green_guard.py")
    finally:
        p.write_text(orig, encoding="utf-8")

    print()
    if failures:
        print(f"❌ {len(failures)} 项守卫未能如期转红：{failures}")
        return 1
    print("✅ 全部负样本均如期转红——守卫是真的，不是恒真断言")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())