"""外显爽点断供带的双端对账（CI 可跑，输入随基线固化）。

背景（2026-10-14）：drought 与 payscene 是仅有的两份「真实成书上双端算法
一致性」检查，但它们原先只读 verify-logs/ 且 Dart 侧需要 data/generated/
语料（gitignore）→ 新克隆与 CI 上永远不跑。payscene 那份已于同日固化
（纯函数枚举）。本文件对应的 drought 份同样固化，差别只在输入来源：
断供带的输入是逐章 💥/侧反密度（float 列表），这些输入随基线一起提交，
Dart 侧从提交的输入重算断供带，无需读真机 jsonl。

三处闭环（与 payscene 同构）：
1. 本文件：rules/payoff_drought_parity.json == 当前 Python 重算（含过期检测）
2. tool/verify_payoff_drought_parity_test.dart：Dart 从提交输入重算 == 提交期望
3. 语义护栏：side 逃生通道、minRun 边界、阈值与单一数据源一致

注意 text→密度（thrill_per_thousand 逐词表命中）那半截**不在**闭环内：
那需要真机正文，本机由 tool/verify_drought_corpus_e2e_test.dart 手动跑
（Dart 密度无舍入、Python round 到 2 位，故该 e2e 只带容差比密度）。

阈值单一数据源：Dart 侧 payoffDroughtZones 默认值取 QualityRules（由
rules/quality_rules.json 生成），而 Python payoff_drought_zones 的默认值
是**硬编码在函数签名里**的——test_quality_rules_parity.py 只对账常量表，
不管函数默认值，故这里补一条钉住三者一致（JSON == 生成物 == Python 默认）。
"""
import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from gen_quality import payoff_drought_zones  # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

PINNED = ROOT / "rules" / "payoff_drought_parity.json"

# 与 rules/quality_rules.json 的 id 同名（rules_codegen 保证双端常量同形）。
THRESHOLD_IDS = ("droughtThrillPerK", "droughtMinRun", "droughtSidePerK")


def _load_pinned():
    return json.loads(PINNED.read_text(encoding="utf-8"))


def _json_thresholds():
    """从 rules/quality_rules.json 里捞出三个 drought 阈值的实际值。"""
    doc = json.loads((ROOT / "rules" / "quality_rules.json").read_text(
        encoding="utf-8"))
    found = {}

    def walk(node):
        if isinstance(node, dict):
            if node.get("id") in THRESHOLD_IDS:
                found[node["id"]] = node.get("value")
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(doc)
    return found


def _generated_dart_constants():
    """解析 quality_rules.g.dart 里的 drought 常量声明（生成物，勿手改）。"""
    src = (ROOT / "lib" / "engine" / "quality" / "quality_rules.g.dart"
           ).read_text(encoding="utf-8")
    found = {}
    for name in THRESHOLD_IDS:
        m = re.search(rf"static const \w+ {name} = ([^;]+);", src)
        if m:
            found[name] = m.group(1).strip()
    return found


class DroughtParityTest(unittest.TestCase):
    """Python 侧行为 + 入库基线新鲜度 + 阈值单一数据源。"""

    # ---- 基线自身结构 ----

    def test_pinned_baseline_exists_and_has_enough_books(self):
        """基线在、且样本量足够（与 Dart 侧 >10 的守卫同口径）。

        为什么是 10 而不是别的数：断供带判定在 3~5 章的小样上几乎恒空，
        样本太少时「对账一致」不携带信息（全是空 zones 对空 zones）。
        现有基线 18 本（2026-10-14 实测），下限留到 10 以容忍语料自然增减。
        """
        self.assertTrue(
            PINNED.is_file(),
            "缺少 rules/payoff_drought_parity.json——它是 Dart 侧无语料对账"
            "（tool/verify_payoff_drought_parity_test.dart）的固化基线。生成：\n"
            "  python tool/gen_parity_baselines.py --pinned --only drought\n"
            "（需本机 data/generated/ 真机产物，生成后随本文件一起提交）")
        data = _load_pinned()
        self.assertGreater(
            len(data), 10,
            f"基线只有 {len(data)} 本书——样本过少时断供带几乎恒空，"
            "对账不携带信息（与 Dart 侧守卫同口径）")

    def test_every_book_has_required_fields(self):
        """每本书必须含 n / thrill / side / zones / in_zone 五个字段。

        少了 thrill/side（输入）Dart 侧就退回「需要语料」的老路；
        少了 zones（期望）则无从比对。形状契约被破坏时要红得可读。
        """
        required = {"n", "thrill", "side", "zones", "in_zone"}
        for book, rec in sorted(_load_pinned().items()):
            missing = required - set(rec)
            self.assertEqual(
                missing, set(),
                f"基线[{book}] 缺字段 {sorted(missing)}——"
                "Dart 侧 tool/verify_payoff_drought_parity_test.dart "
                "按这些键取值，缺一个都会崩或静默跳过")

    def test_n_matches_input_lengths(self):
        """n 必须等于输入数组长度（防手改基线时只改了一处）。"""
        for book, rec in sorted(_load_pinned().items()):
            self.assertEqual(rec["n"], len(rec["thrill"]),
                             f"基线[{book}] n={rec['n']} != len(thrill)="
                             f"{len(rec['thrill'])}")
            self.assertEqual(len(rec["thrill"]), len(rec["side"]),
                             f"基线[{book}] thrill/side 长度不等——"
                             "断供带按章序逐章对位，长度必须一致")

    # ---- 核心：基线 == 当前 Python 重算（新鲜度/预言机） ----

    def test_python_recompute_equals_pinned(self):
        """从提交的输入重算断供带，必须与提交的期望逐书一致。

        这是本文件的核心断言：它保证「固化基线 == 当前 Python 行为」。
        缺了它，Dart 侧的对账就成了「Dart 与一份过期 JSON 一致」——
        那份 JSON 可能几个月前就与 Python 脱节了，而两端照样全绿。
        """
        mismatches = []
        for book, rec in sorted(_load_pinned().items()):
            zones = payoff_drought_zones(rec["thrill"], side_per_k=rec["side"])
            got = [list(z) for z in zones]
            if got != rec["zones"]:
                mismatches.append(
                    f"{book}: pinned={rec['zones']} recompute={got}")
            in_zone = sum(z[2] for z in zones)
            if in_zone != rec["in_zone"]:
                mismatches.append(
                    f"{book}: in_zone pinned={rec['in_zone']} "
                    f"recompute={in_zone}")
        self.assertEqual(
            mismatches, [],
            "固化基线与当前 Python 重算不一致（基线过期或算法被改）：\n  "
            + "\n  ".join(mismatches[:5])
            + "\n若系有意改动算法：重新生成固化基线——\n"
              "  python tool/gen_parity_baselines.py --pinned --only drought"
              "（需本机语料）——并同步 Dart 侧实现与本文件断言。")

    # ---- 语义护栏（合成用例，不依赖基线） ----

    def test_side_escape_channel_semantics(self):
        """侧反逃生通道：💥 低但侧反达标 = 兑现已送达读者，不判断供。

        这条独立于基线——它保护的是**通道语义**。2026-09-29 真机 A/B 实测：
        THRILL_WORDS 是 96 词闭合套话表，不写套话的好稿 💥 命中 0 词，
        若只看 💥 会把它判成断供（该通道在真实成书上救回 10 章）。
        """
        thrill = [0.0, 0.0, 0.0]          # 三章全低于阈值 0.5
        rescued = [1.0, 1.0, 1.0]         # 侧反全部达标（>= 0.3）
        flat = [0.1, 0.1, 0.1]            # 侧反也枯
        # 有逃生通道：全被救回 → 无断供带
        self.assertEqual(
            payoff_drought_zones(thrill, side_per_k=rescued), [],
            "侧反达标章被判成断供——逃生通道语义被破坏（会误伤不写套话的好稿）")
        # 无侧反信息（None）：回退旧口径，💥 低即断供
        self.assertEqual(
            payoff_drought_zones(thrill), [(0, 2, 3)],
            "side_per_k=None 时应回退旧口径（只看 💥），旧调用零变化")
        # 侧反也枯：断供带成立
        self.assertEqual(
            payoff_drought_zones(thrill, side_per_k=flat), [(0, 2, 3)],
            "双通道皆枯却未判断供——检测器坏了")

    def test_min_run_boundary(self):
        """minRun=3 边界：连低 2 章不成带、3 章成带（阈值标定的核心结论）。

        标定依据（gen_quality.payoff_drought_zones 文档）：1~2 章连低属正常
        节奏起伏（6/14 本书出现且质量正常），>=3 章才判断供带。
        """
        two = [0.0, 0.0, 2.0]
        three = [0.0, 0.0, 0.0, 2.0]
        self.assertEqual(payoff_drought_zones(two), [],
                         "连低 2 章被判成断供带——minRun 边界被改坏了")
        self.assertEqual(payoff_drought_zones(three), [(0, 2, 3)],
                         "连低 3 章未成带——minRun 边界被改坏了")

    def test_trailing_zone_flushes_at_end(self):
        """末尾连低也要成带（循环结束后补 flush，别只在中途断点处收带）。"""
        self.assertEqual(payoff_drought_zones([2.0, 0.0, 0.0, 0.0]),
                         [(1, 3, 3)],
                         "末尾连低未收带——flush 逻辑被改坏（会漏掉「越写越淡」的书）")

    # ---- 阈值单一数据源 ----

    def test_threshold_defaults_match_single_source(self):
        """Python 函数默认值 == JSON == 生成物 Dart 常量（三者同源）。

        为什么必须单独钉：Dart 侧默认值取 QualityRules（JSON 生成），
        而 Python payoff_drought_zones 的默认值**硬编码在函数签名**里。
        test_quality_rules_parity.py 只对账常量表、不管函数默认值——
        有人改了 JSON 却没改 Python 签名时，双端阈值就静默分叉：
        基线生成仍用 0.5、Dart 实跑已用 0.6，zones 从此两套标准。
        """
        # payoff_drought_zones(thrill_per_k, threshold, min_run, side_per_k, side_threshold)
        thr_default, min_default, side_kw_default, side_thr_default = \
            payoff_drought_zones.__defaults__
        js = _json_thresholds()
        for name in THRESHOLD_IDS:
            self.assertIn(name, js,
                          f"rules/quality_rules.json 里找不到 {name}——"
                          "阈值被改名/删除？本对账的口径随之失效")
        self.assertEqual(thr_default, js["droughtThrillPerK"],
                         "Python payoff_drought_zones 的 threshold 默认值与"
                         "rules/quality_rules.json 不一致（硬编码 vs 单一数据源分叉）")
        self.assertEqual(min_default, js["droughtMinRun"],
                         "Python payoff_drought_zones 的 min_run 默认值与"
                         "rules/quality_rules.json 不一致")
        self.assertEqual(side_thr_default, js["droughtSidePerK"],
                         "Python payoff_drought_zones 的 side_threshold 默认值与"
                         "rules/quality_rules.json 不一致")
        self.assertIsNone(side_kw_default,
                          "side_per_k 默认值应为 None（旧口径回退），被改了？")

        # 与生成物 Dart 常量对拍（生成物由 rules_codegen 产出，--check 已保证
        # 它与 JSON 一致；这里直接对拍是为了让「Python 签名 vs Dart 常量」
        # 这条最长的链在同一断言里闭合，报错时无需跨文件拼因果）。
        dart = _generated_dart_constants()
        self.assertEqual(dart.get("droughtThrillPerK"), str(thr_default),
                         "quality_rules.g.dart 的 droughtThrillPerK 与 Python "
                         "默认值不一致")
        self.assertEqual(dart.get("droughtMinRun"), str(min_default),
                         "quality_rules.g.dart 的 droughtMinRun 与 Python "
                         "默认值不一致")
        self.assertEqual(dart.get("droughtSidePerK"), str(side_thr_default),
                         "quality_rules.g.dart 的 droughtSidePerK 与 Python "
                         "默认值不一致")


if __name__ == "__main__":
    unittest.main()
