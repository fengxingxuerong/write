#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""外部效度状态（quality_validation.py）的离线回归测试。

要守住的不只是「当前状态是 none」，而是三条结构性性质：
1. 状态**从真实标注数据推导**，不是手写常量——人评补上后必须自动升级；
2. 「真实标注」的判定足够严（字符串/布尔不算），防止批量生成的假数据混入；
3. 门禁在 PASS 时一定带上限定文本。

全部离线，不读 data/ 与 verify-logs/，CI 恒定生效。
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import quality_validation as qv  # noqa: E402


def _cfg(min_conclusion=10, path="docs/human-eval/annotations.jsonl"):
    """最小数据源（测试不依赖仓库里的真实标注数）。"""
    return {
        "annotationsPath": path,
        "minSamplesForConclusion": min_conclusion,
        "minSamplesForStrongConclusion": 30,
        "statusVocabulary": {
            "none": "无标注",
            "insufficient": "样本不足",
            "provisional": "待出结论",
            "validated": "已验证",
        },
    }


class CountRatingsTest(unittest.TestCase):
    def _write(self, lines):
        fh = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False,
                                         encoding="utf-8")
        fh.write("\n".join(lines))
        fh.close()
        return Path(fh.name)

    def test_counts_numeric_human_only(self):
        p = self._write([
            "# 注释行，不计入",
            "",
            json.dumps({"id": "a", "human": 82}),
            json.dumps({"id": "b", "human": None}),
            json.dumps({"id": "c", "human": 90, "rater": "K"}),
        ])
        ratings, total = qv.count_ratings(p)
        self.assertEqual((ratings, total), (2, 3))

    def test_string_human_does_not_count(self):
        """字符串分数多半是机器批量生成的，不能算「人评」。"""
        p = self._write([json.dumps({"id": "a", "human": "85"})])
        self.assertEqual(qv.count_ratings(p), (0, 1))

    def test_bool_human_does_not_count(self):
        # bool 是 int 子类，必须显式排除。
        p = self._write([json.dumps({"id": "a", "human": True})])
        self.assertEqual(qv.count_ratings(p), (0, 1))

    def test_malformed_line_skipped_not_crash(self):
        p = self._write(['{"id": "a", "human": 70}', "{坏行", "[]", '"纯字符串"'])
        ratings, total = qv.count_ratings(p)
        self.assertEqual((ratings, total), (1, 1))
class StatusDerivationTest(unittest.TestCase):
    """核心：状态必须随真实数据变化，而不是一个写死的常量。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "ann.jsonl"

    def tearDown(self):
        self.tmp.cleanup()

    def _write_n(self, n):
        rows = [json.dumps({"id": f"c{i}", "human": 80 + i % 10})
                for i in range(n)]
        self.path.write_text("\n".join(rows), encoding="utf-8")

    def test_zero_ratings_is_none(self):
        self._write_n(0)
        s = qv.validation_status(str(self.path), config=_cfg())
        self.assertEqual(s.status, "none")
        self.assertTrue(s.needs_caveat)
        self.assertFalse(s.is_validated)

    def test_fewer_than_min_is_insufficient(self):
        self._write_n(4)
        s = qv.validation_status(str(self.path), config=_cfg())
        self.assertEqual(s.status, "insufficient")
        self.assertTrue(s.needs_caveat)

    def test_enough_but_no_report_is_provisional(self):
        self._write_n(12)
        # 无 report-*.md 时不得判 validated ——「样本够」不等于「跑过实验」。
        s = qv.validation_status(str(self.path), config=_cfg())
        self.assertEqual(s.status, "provisional")
        self.assertFalse(s.needs_caveat)
        self.assertFalse(s.is_validated)

    def test_status_upgrades_as_ratings_increase(self):
        """防回归关键用例：状态随标注数单调升级，不会永远停在 none。"""
        seen = []
        for n in (0, 5, 12):
            self._write_n(n)
            seen.append(qv.validation_status(str(self.path), config=_cfg()).status)
        self.assertEqual(seen, ["none", "insufficient", "provisional"])

    def test_report_present_upgrades_to_validated(self):
        self._write_n(12)
        s = qv.validation_status(str(self.path), config=_cfg())
        self.assertEqual(s.status, "provisional")
        orig = qv.REPORT_DIR
        try:
            qv.REPORT_DIR = Path(self.tmp.name)
            (Path(self.tmp.name) / "report-20261003.md").write_text(
                "# 报告", encoding="utf-8")
            s2 = qv.validation_status(str(self.path), config=_cfg())
        finally:
            qv.REPORT_DIR = orig
        self.assertEqual(s2.status, "validated")
        self.assertTrue(s2.is_validated)


class RealRepoStateTest(unittest.TestCase):
    """对仓库真实状态的自检：数据源必须在库、状态必须可算。"""

    def test_data_source_committed(self):
        self.assertTrue(qv.RULES_PATH.exists(),
                        "rules/quality_validation.json 是外部效度状态的数据源，必须入库")

    def test_status_computable(self):
        s = qv.validation_status()
        self.assertIn(s.status, {"none", "insufficient", "provisional", "validated"})
        self.assertGreaterEqual(s.total_rows, 0)

    def test_current_state_needs_caveat_until_human_ratings_exist(self):
        """只要真实标注仍为 0，就必须要求披露限定。

        这条断言写死「当前是 none」是有意的：它是本项目最大科学缺口的哨兵。
        将来真补上人评后它会失败——那时应当**显式更新本测试**并在新测试里写清
        结论依据（而不是让它悄悄红着或悄悄变绿）。
        """
        s = qv.validation_status()
        if s.ratings == 0:
            self.assertEqual(s.status, "none")
            self.assertTrue(s.needs_caveat)
        else:
            self.assertNotEqual(s.status, "none")

    def test_caveat_mentions_self_consistency(self):
        """限定文本必须说清「达线 ≠ 好看」，否则披露没有意义。"""
        text = "\n".join(qv.caveat_lines())
        self.assertIn("外部效度", text)
        self.assertIn("human-eval-workflow.md", text)
        if qv.validation_status().status == "none":
            self.assertIn("不代表「读者认可」", text)

    def test_smoke_gate_prints_caveat_next_to_pass(self):
        """门禁源码必须真的调用了 caveat_lines（防止有人把披露删掉）。"""
        src = (ROOT / "scripts" / "run_smoke_gate.py").read_text(encoding="utf-8")
        self.assertIn("caveat_lines", src)


class ValidationDataSourceTest(unittest.TestCase):
    """外部效度状态的数据源必须在库，且字段齐备。

    背景：rules/quality_validation.json 是「达线是否与人评对齐」的唯一事实源。
    它缺失时 quality_validation.py 会 SystemExit，但**双端对账与 UI 限定都会
    悄悄失去依据**——所以在 CI 里硬性要求它存在且字段完整。
    """

    def test_data_source_exists_and_valid(self):
        self.assertTrue(qv.RULES_PATH.exists(),
                        "rules/quality_validation.json 必须入库")
        cfg = json.loads(qv.RULES_PATH.read_text(encoding="utf-8"))
        for key in ("annotationsPath", "minSamplesForConclusion",
                    "minSamplesForStrongConclusion", "statusVocabulary"):
            self.assertIn(key, cfg, f"数据源缺少字段 {key}")
        vocab = cfg["statusVocabulary"]
        for key in ("none", "insufficient", "provisional", "validated"):
            self.assertIn(key, vocab, f"statusVocabulary 缺少 {key} 释义")
        self.assertGreater(cfg["minSamplesForConclusion"], 0)
        self.assertGreaterEqual(cfg["minSamplesForStrongConclusion"],
                                cfg["minSamplesForConclusion"])

    def test_annotations_path_points_at_committed_file(self):
        cfg = json.loads(qv.RULES_PATH.read_text(encoding="utf-8"))
        target = ROOT / cfg["annotationsPath"]
        self.assertTrue(target.exists(),
                        f"{cfg['annotationsPath']} 必须入库（标注表）")


class NetworkClaimGuardTest(unittest.TestCase):
    """守卫「默认离线」这一对外承诺的可核查部分。

    本项目对外的说法是「默认离线、联网须用户主动启用」，而不是「完全零网络」。
    pubspec.yaml 曾写着「从依赖层面保证『完全离线、零 API、零网络请求』」——
    那句话与代码事实不符（lib/ 下多个文件用 dart:io HttpClient 发真实请求），
    已于 2026-10-03 更正。

    这条注释属于**会腐化的文档**：新增一个网络调用点时没人会想到去改它。
    故用测试钉住可核查的部分：
      1) lib/ 不引入 pub 网络库（这才是「从依赖层面」的真正保证）；
      2) 含 HttpClient 的文件清单与 pubspec 里写的一致（防止清单本身腐化）。
    """

    PUB_NETWORK_PACKAGES = ("package:http", "package:dio", "package:chopper",
                            "package:http_client", "package:retrofit")

    def _lib_files(self):
        return sorted((ROOT / "lib").rglob("*.dart"))

    def test_lib_imports_no_pub_network_package(self):
        """「不引入 pub 网络库」是真实的、可测的依赖约束。"""
        offenders = {}
        for f in self._lib_files():
            text = f.read_text(encoding="utf-8", errors="replace")
            hits = [p for p in self.PUB_NETWORK_PACKAGES if f"import '{p}" in text]
            if hits:
                offenders[str(f.relative_to(ROOT))] = hits
        self.assertEqual(offenders, {},
                         f"lib/ 出现 pub 网络库导入：{offenders}")

    def test_pubspec_dependencies_have_no_network_package(self):
        pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
        # 只看 dependencies 段（dev_dependencies 里的测试工具不算运行时网络能力）。
        dep_block = pubspec.split("dev_dependencies:")[0]
        for pkg in self.PUB_NETWORK_PACKAGES:
            name = pkg.split("/")[-1]
            self.assertNotIn(f"  {name}:", dep_block,
                             f"pubspec dependencies 出现网络库 {name}")

    def test_network_caller_list_matches_pubspec_claim(self):
        """pubspec 里列的「含 HttpClient 的文件」必须与实际一致。

        方向性刻意做成**双向**：既不许文档漏写新文件，也不许文档写着已不存在的
        文件——两种腐化都会让「离线承诺」的可信度归零。
        """
        actual = set()
        for f in self._lib_files():
            text = f.read_text(encoding="utf-8", errors="replace")
            if "HttpClient" in text:
                actual.add(str(f.relative_to(ROOT)).replace("\\", "/"))

        pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
        claimed = set()
        for line in pubspec.splitlines():
            s = line.strip()
            if not s.startswith("#"):
                continue
            body = s.lstrip("# ").strip()
            # 清单形如 `#   lib/engine/llm_engine.dart              流式生成`
            # ——路径后面跟中文说明，故不能要求整行以 .dart 结尾。
            if not body.startswith("lib/"):
                continue
            path = body.split()[0] if body.split() else ""
            if path.endswith(".dart"):
                claimed.add(path)

        self.assertTrue(claimed, "pubspec 应显式列出含 HttpClient 的文件")
        self.assertEqual(
            actual - claimed, set(),
            "新增了 pubspec 未记录的网络调用点——请在 pubspec.yaml 注明它对应"
            "哪个用户主动开启的能力（默认离线承诺的可核查部分）")
        self.assertEqual(
            claimed - actual, set(),
            "pubspec 记录的网络调用点已不存在——请删掉过期条目")


if __name__ == "__main__":
    unittest.main()

    def test_missing_file_is_zero(self):
        self.assertEqual(
            qv.count_ratings(Path("no-such-file-xyz.jsonl")), (0, 0))