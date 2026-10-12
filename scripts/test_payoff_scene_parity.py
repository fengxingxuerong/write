"""爽点场景判定的双端对账（CI 可跑，零语料依赖）。

背景（2026-10-14 优化）：`tool/verify_payoff_scene_parity_test.dart` 是唯一的
「真实场景上双端算法是否一致」检查，但它读 `verify-logs/py_payscene.json`，
而 `verify-logs/` 与 `data/` 都被 gitignore -> **CI 上永远不跑**。作者为了
避开「基线缺失 -> SKIP 即通过」的假绿，选择把它移出 test/，代价是这唯一一份
双端算法对账失去了 CI 保护。

但 payscene 这一份**根本不需要语料**：它是 `is_payoff_scene(goal, stage,
index, total)` 的纯函数矩阵（10 目标 x 4 stage x 6 位置 = 240 例），枚举口径
与数据来源都由本文件自持。于是把期望值固化成常量表，就能在 CI 里直接断言，
既不留假绿、也不必依赖作者本机的 verify-logs/。

本脚本钉三件事（都是会静默漂移、且不会被 dart analyze 抓到的东西）：
1. **Python 侧行为**：240 例逐例与固化期望一致（改算法会立刻红）。
2. **口径未漂移**：枚举规模仍为 10x4x6、true/false 分布仍为 108/132——
   这分布变了说明语义被改过，而不是单纯多了几个用例。
3. **双端常量同源**：Python 的 PAYOFF_SCENE_KEYS 与 Dart 的
   `payoffSceneKeys` 必须逐字相同（P1-2 那类「同一指标两套实现」的漂移源）。

注意本文件**不能**证明 Dart 侧正确——Dart 代码本脚本读不到。它把 Dart 侧
期望值固化成表，由 `tool/verify_payoff_scene_parity_test.dart` 逐例比对；
两者合用才构成完整的双端对账（见该 Dart 文件头注释）。
"""
import json
import re
import sys
import unittest
from pathlib import Path

Q = chr(34) + "([^" + chr(34) + "]*)" + chr(34)

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from pipeline_quality import (  # noqa: E402
    PAYOFF_SCENE_KEYS,
    is_payoff_scene,
)

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# 与 tool/gen_parity_baselines.py 的 GOALS/STAGES/POSITIONS 同口径
# （改任一处必须同步另一处，否则本对账的口径本身就错了）。
GOALS = [
    "外显爽点：当众打脸", "设计一次打脸", "当众揭穿真凶", "局势逆转，危机爆发",
    "场景铺垫", "事件推进，冲突升级", "危机爆发", "收束本章并埋下钩子",
    "外显爽点：收获", "",
]
STAGES = ["起", "承", "转", "合"]
POSITIONS = [(0, 4), (1, 4), (2, 4), (1, 3), (0, 2), (2, 0)]

# Dart 侧 lib/engine/multipass/multi_pass_chapter_engine.dart 的 payoffSceneKeys。
# 逐字抄录：它是手抄的，故本断言**只能**发现「Python 改了、抄录没跟上」这一类
# 漂移；Dart 改了而两边都没动它抓不到。真正的双端机器校验见
# tool/verify_payoff_scene_parity_test.dart（读固化基线逐例比对 Dart 实跑结果）。
DART_PAYOFF_SCENE_KEYS = ["外显爽点", "打脸", "当众"]

# 固化期望：goal 下标 -> 该 goal 判定为 true 的 (stage, index, total) 集合。
# 生成方式（2026-10-14 实测）：python tool/gen_parity_baselines.py --only payscene
# 全表 240 例：108 true / 132 false。
_ALL_CELLS = {(s, i, t) for s in STAGES for (i, t) in POSITIONS}
EXPECTED_TRUE = {
    0: set(_ALL_CELLS),   # 含爽点词 -> 关键词通道恒真，与 stage/位置无关
    1: set(_ALL_CELLS),
    2: set(_ALL_CELLS),
    8: set(_ALL_CELLS),
    # 无爽点词 -> 只有位置通道：stage=='转' 且 (i+1)/t >= 0.55
    #   (2,4)->0.75 真 | (1,3)->0.667 真 | (1,4)=0.5、(0,4)=0.2、(0,2)=0.5 假
    3: {("转", 2, 4), ("转", 1, 3)},
    4: {("转", 2, 4), ("转", 1, 3)},
    5: {("转", 2, 4), ("转", 1, 3)},
    6: {("转", 2, 4), ("转", 1, 3)},
    7: {("转", 2, 4), ("转", 1, 3)},
    9: {("转", 2, 4), ("转", 1, 3)},
}


# 口径自检用的结构断言：描述的是**算法语义**而非具体用例。
EXPECTED_STRUCTURE = {
    "goals": 10,
    "stages": 4,
    "positions": 6,
    "cases": 240,
    "true_total": 108,
    "false_total": 132,
}


class PayoffSceneParityTest(unittest.TestCase):
    """Python 侧 240 例矩阵 + 双端常量一致性。"""

    def _actual_true(self):
        out = set()
        for gi, g in enumerate(GOALS):
            for s in STAGES:
                for (i, t) in POSITIONS:
                    if is_payoff_scene(g, s, i, t):
                        out.add((gi, s, i, t))
        return out

    def test_enumeration_shape_unchanged(self):
        """枚举规模与 true/false 分布必须与固化基线一致。

        为什么断言分布而不只是数量：240 这个数字单独看没有信息量
        （把 GOALS 加一项、再删一项仍是 240）。分布 + 规模两者一起才
        能确定「枚举口径没被改过」。这也是防空跑——若 GOALS/POSITIONS
        被改动，这里的 true_total 会变。
        """
        cases = len(GOALS) * len(STAGES) * len(POSITIONS)
        self.assertEqual(cases, EXPECTED_STRUCTURE["cases"],
                         f"枚举规模从 {EXPECTED_STRUCTURE['cases']} 变为 {cases}："
                         "GOALS/STAGES/POSITIONS 被改动，固化期望表已失效")
        n_true = sum(len(v) for v in EXPECTED_TRUE.values())
        n_false = cases - n_true
        self.assertEqual(n_true, EXPECTED_STRUCTURE["true_total"],
                         f"true 例数从 {EXPECTED_STRUCTURE['true_total']} 变为 "
                         f"{n_true}——判定语义或枚举口径发生了变化")
        self.assertEqual(n_false, EXPECTED_STRUCTURE["false_total"])

    def test_python_matrix_matches_frozen_expectation(self):
        """240 例逐例比对固化期望（本文件的核心断言）。"""
        actual = self._actual_true()
        expected = {(gi, s, i, t)
                    for gi, cells in EXPECTED_TRUE.items()
                    for (s, i, t) in cells}

        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        detail = []
        if missing:
            detail.append("应为 true 却判 false（共 %d 例，最多列 5）：%s"
                          % (len(missing), missing[:5]))
        if extra:
            detail.append("应为 false 却判 true（共 %d 例，最多列 5）：%s"
                          % (len(extra), extra[:5]))
        self.assertEqual([], detail,
                         "is_payoff_scene 与固化期望不一致：\n  " +
                         "\n  ".join(detail) +
                         "\n若这是**有意**的算法改动：请重跑 "
                         "python tool/gen_parity_baselines.py --only payscene "
                         "取新值，同步更新 EXPECTED_TRUE 与 EXPECTED_STRUCTURE，"
                         "并同步 Dart 侧 payoffSceneKeys 附近的实现。")

    def test_keyword_channel_is_position_independent(self):
        """含爽点词的 goal：关键词通道必须恒真，且与 stage/位置无关。

        独立断言保护的是**通道语义**——若有人在关键词命中后又加了「只有
        后半段才算」之类的限制，上面的逐例表会红，但错误信息指不到根因；
        这条直接说清「关键词通道不该看位置」。
        """
        for gi in (0, 1, 2, 8):
            for s in STAGES:
                for (i, t) in POSITIONS:
                    self.assertTrue(
                        is_payoff_scene(GOALS[gi], s, i, t),
                        f"含爽点词的 goal[{gi}] 在 {s}/{i}/{t} 未被判为爽点场景")

    def test_position_channel_requires_stage_zhuan(self):
        """无爽点词的 goal：只有 stage=='转' 才可能为真。"""
        for gi in (3, 4, 5, 6, 7, 9):
            for s in STAGES:
                if s == "转":
                    continue
                for (i, t) in POSITIONS:
                    self.assertFalse(
                        is_payoff_scene(GOALS[gi], s, i, t),
                        f"无爽点词的 goal[{gi}] 在 stage={s} 被判为爽点场景，"
                        "位置通道只应认「转」")

    def test_position_channel_threshold_is_55pct(self):
        """后半段阈值：进度 >= 0.55 才算，< 0.55 不算（逐点验证）。"""
        for (i, t), expect in [((2, 4), True), ((1, 3), True),
                               ((1, 4), False), ((0, 4), False),
                               ((0, 2), False), ((2, 0), False)]:
            got = is_payoff_scene(GOALS[3], "转", i, t)
            self.assertEqual(got, expect,
                             f"位置通道阈值判定错：index={i} total={t} "
                             f"进度={(i + 1) / t if t else 0:.3f} "
                             f"期望 {expect} 实得 {got}")

    def test_zero_total_short_circuits(self):
        """total<=0 必须直接 false，不能触发除零或位置判定。"""
        self.assertFalse(is_payoff_scene(GOALS[3], "转", 0, 0))
        self.assertFalse(is_payoff_scene(GOALS[3], "转", 5, 0))

    def test_keyword_list_matches_dart_side(self):
        """双端词表逐字一致（P1-2 漂移源，见 DART_PAYOFF_SCENE_KEYS 注释）。"""
        self.assertEqual(
            list(PAYOFF_SCENE_KEYS), DART_PAYOFF_SCENE_KEYS,
            "PAYOFF_SCENE_KEYS 与 Dart 侧 payoffSceneKeys 不一致——"
            "这正是双端口径漂移的典型来源，请两侧同步修改")

    def test_frozen_expectation_is_internally_consistent(self):
        """固化期望表自身不能写错：手抄表 vs 规则推导必须同解。

        这条防的是「维护时手抄 EXPECTED_TRUE 抄错」。用**规则**重算一遍
        期望（含爽点词 -> 恒真；否则 -> 转 且进度>=0.55），与手抄表比对。
        注意它验的是期望表与规则一致，**不**验证规则本身正确——规则正确性
        由上面 test_python_matrix_matches_frozen_expectation 与 Dart 侧
        逐例对账共同承担。
        """

    def test_frozen_baseline_json_matches_python(self):
        """入库基线 rules/payoff_scene_parity.json 必须与本文件计算完全一致

        注意本 docstring 里**不嵌三引号字面量**（2026-10-14 踩过）：
        正文中写成三个连续双引号会提前终止 docstring，报
        SyntaxError: invalid character，且行号指向后面的无关行，
        极难排查（第一次误判成「中文句号 U+3002 作终止符」）。
        正确做法是用「三引号」三个字描述，或单引号。

        这条把「固化基线」和「本脚本的判定」绑在一起：Dart 侧
        tool/verify_payoff_scene_parity_test.dart 读的是那份 JSON，而它不会
        重算 Python——它只比对 Dart 实跑结果与 JSON。所以 JSON 若悄悄过期
        （比如 Python 改了算法、JSON 没重新生成），Dart 侧照样会绿，因为它
        和 Dart 一致。缺的正是「JSON == 当前 Python 行为」这一环，由本断言补齐。

        三处形成闭环：本断言（JSON == Python）+ Dart 对账（Dart == JSON）
        + 手抄表自洽（期望表 == 规则推导）。任一环失配都会红。
        """
        pinned = ROOT / "rules" / "payoff_scene_parity.json"
        self.assertTrue(
            pinned.is_file(),
            "缺少 rules/payoff_scene_parity.json——它是 Dart 侧双端对账"
            "（tool/verify_payoff_scene_parity_test.dart）的固化基线。\n"
            "生成方式：python tool/gen_parity_baselines.py --only payscene "
            "然后把 verify-logs/py_payscene.json 拷到该路径（或直接跑本脚本\n"
            "同款的枚举逻辑重写）。")
        rows = json.loads(pinned.read_text(encoding="utf-8"))

        self.assertEqual(len(rows), EXPECTED_STRUCTURE["cases"],
                         f"入库基线 {len(rows)} 例，应为 "
                         f"{EXPECTED_STRUCTURE['cases']} 例")
        # 键名与 Dart 侧读取的字段必须一致（Dart 读 m['g']/m['s']/m['i']/m['t']/m['r']）。
        self.assertEqual(sorted(rows[0].keys()),
                         ["g", "i", "r", "s", "t"],
                         "入库基线的字段键变了——Dart 侧按 g/s/i/t/r 读取，"
                         "改名会让 Dart 对账崩或静默取到 null")

        # 逐例重算比对：JSON 里记录的 r 必须等于当前 Python 的判定。
        mismatches = []
        for row in rows:
            got = is_payoff_scene(row["g"], row["s"], row["i"], row["t"])
            if got != row["r"]:
                mismatches.append(
                    f"g={row['g']!r} s={row['s']} i={row['i']} t={row['t']} "
                    f"json={row['r']} python={got}")
        self.assertEqual(
            mismatches[:5], [],
            f"入库基线有 {len(mismatches)} 例与当前 Python 判定不一致"
            f"（最多列 5）：\n  " + "\n  ".join(mismatches[:5]) +
            "\n说明基线已过期（Python 改了算法但基线没重新生成）。\n"
            "重新生成：python tool/gen_parity_baselines.py --only payscene，\n"
            "然后把 verify-logs/py_payscene.json 覆盖到 "
            "rules/payoff_scene_parity.json。\n"
            "注意：此时 Dart 侧可能仍然全绿（它与 JSON 一致），"
            "正是本断言要拦的那种「JSON 过期但没人发现」。")

    def test_goals_stages_positions_match_baseline_source(self):
        """枚举口径必须与 tool/gen_parity_baselines.py 的 GOALS/STAGES/POSITIONS 一致。

        本文件手抄了一份枚举口径（见模块顶部）。若生成脚本改了口径而本文件
        没跟上，上一条断言会因为「枚举出的行数/取值对不上」而红——但错误信息
        指不到根因。这条直接把三份口径摆在一起比，报错直指「抄录没同步」。
        """
        src = (ROOT / "tool" / "gen_parity_baselines.py").read_text(
            encoding="utf-8")
        # 只取字面量列表，避免抓到函数体里的同名变量。
        def _literal(name):
            m = re.search(rf"^{name} = \[(.*?)\]", src, re.S | re.M)
            self.assertIsNotNone(m, f"在 gen_parity_baselines.py 找不到 {name} 字面量")
            return re.findall(Q, m.group(1))

        self.assertEqual(GOALS, _literal("GOALS"),
                         "GOALS 与 tool/gen_parity_baselines.py 不一致——"
                         "本文件手抄的枚举口径已过期，双端对账比对的是两套不同输入")
        self.assertEqual(STAGES, _literal("STAGES"),
                         "STAGES 与 tool/gen_parity_baselines.py 不一致")
        # POSITIONS 是元组列表，字面量形如 (0, 4)；用独立正则取。
        # 注意：正则带两个捕获组时 findall 返回的是 **(str, str) 元组列表**
        # （不是字符串列表）——2026-10-14 踩过，写成 pair.split(',') 直接
        # AttributeError。故这里直接 int() 两个元素。
        m = re.search(r"^POSITIONS = \[(.*?)\]", src, re.S | re.M)
        self.assertIsNotNone(m, "找不到 POSITIONS 字面量")
        src_positions = [(int(a), int(b)) for a, b in
                         re.findall(r"\((\d+),\s*(\d+)\)", m.group(1))]
        self.assertEqual(POSITIONS, src_positions,
                         "POSITIONS 与 tool/gen_parity_baselines.py 不一致")


if __name__ == "__main__":
    unittest.main()
