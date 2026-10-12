"""Dart 分层不变量护栏（CI 跑）：把注释里的架构约定变成机器门禁。

背景（2026-10-13 评审）：`lib/engine/quality/quality_gate.dart` 文件头写着
「保持 engine 不反向依赖」来约束分层，但这句约定**没有任何测试守着**——
2026-10-01 那次「按职责拆分 pipeline_qa.dart」就顺手造出了
`pipeline_qa.dart ↔ cross_chapter_qa.dart` 这个环，至今没人发现，
因为 Dart 允许循环 import（不像部分语言直接编译报错），编译与测试全绿。

本脚本只做确定性的事，不做「最佳实践建议」：

1. **环检测**：解析 `lib/**/*.dart` 的 `package:novel_writer/...` import/export
   边，跑 DFS 找环。环一旦出现就红——它意味着「编译期无法报错、只能靠人记得」
   的那类耦合。
2. **engine/quality 不得 import ai_pipeline**：这是 quality_gate.dart 声称的不变量
   （该目录是纯规则质检，必须在离线场景可用；被 LLM 管线拖着走就会崩）。

为什么不断环、只加护栏（为什么不按字面去「重构」）：
- 断掉 `pipeline_qa ↔ cross_chapter_qa` 需要把 `dialogueRatioOf` 挪走，
  它有 19 处引用（含 test/ 与 tool/ 对账脚本），收益远小于风险；
  且 `ChapterPayoff` 留在 pipeline_qa.dart 是**有意设计**（见该文件头第 16-17 行：
  让 `generation_engine → pipeline_qa` 单向成立）。
- 但环不该**隐形**：现在的处置是「环已知存在、被白名单登记、新环一出现就红」，
  既不动既有代码，也让「再造一个环」不再静默通过。
- 白名单收窄方向是唯一的：每次拆分若真断掉了旧环，就从列表里删掉对应条目，
  列表只减不增。故此处不设「新增白名单」的便利通道。

已知环白名单（每条都应附理由与断环成本评估，见下）：
- pipeline_qa.dart ↔ cross_chapter_qa.dart：薄封装转发模式的直接产物，
  `PipelineQa` 保留同名静态方法转调 `CrossChapterQa`（为了让 tool/ 双端对账
  脚本与 lib/ 各调用方零改动）。断环需搬 `dialogueRatioOf`（19 处引用）。
- providers.dart ↔ generate_viewmodel.dart：Riverpod DI 容器的固有形态，
  provider 与 viewmodel 互相引用属框架惯例（同 framework 的 import cycle），
  非本项目可自行消除的分层问题。
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "lib"
PKG = "package:novel_writer/"

# 已知且被登记的环（key/frozenset 两端的相对路径，均相对 lib/）。
# 新环不允许加入此表——发现新环应优先修掉，而不是登记。
KNOWN_CYCLES = [
    frozenset({"ai_pipeline/services/pipeline_qa.dart",
               "ai_pipeline/services/cross_chapter_qa.dart"}),
    frozenset({"core/di/providers.dart",
               "features/generate/generate_viewmodel.dart"}),
]

_IMPORT_RE = re.compile(r"""^\s*(?:import|export)\s+'([^']+)'""", re.M)


def _dart_import_graph():
    """返回 {相对 lib/ 的路径: set(相对 lib/ 的路径)}，仅含 lib/ 内部依赖。

    只解析 `package:novel_writer/` 绝对 import：项目内部代码一律这么写
    （相对 import 只在极少数 g.dart 场景出现），而 dart:/package: 外部依赖
    与分层无关，混进来只会让图变大、噪声变多。
    """
    graph = {}
    for path in sorted(LIB.rglob("*.dart")):
        rel = path.relative_to(LIB).as_posix()
        deps = set()
        for m in _IMPORT_RE.finditer(path.read_text(encoding="utf-8",
                                                    errors="replace")):
            target = m.group(1)
            if not target.startswith(PKG):
                continue
            sub = target[len(PKG):]
            cand = LIB / sub
            if cand.is_file():
                deps.add(cand.relative_to(LIB).as_posix())
                continue
            # library 名（如 quality_gate.dart 顶部 `library;`）→ 同目录同名文件
            base = sub.split("/")[-1]
            for name in (base + ".dart", base + "/" + base + ".dart"):
                if (cand.parent / name).is_file():
                    deps.add((cand.parent / name).relative_to(LIB).as_posix())
                    break
        graph[rel] = deps
    return graph


def _find_cycles(graph):
    """DFS 找所有二元及多元环，返回环的 frozenset 列表（去重）。"""
    WHITE, GREY, BLACK = 0, 1, 2
    color = {n: WHITE for n in graph}
    stack = []
    found = []

    def dfs(node):
        color[node] = GREY
        stack.append(node)
        for nxt in graph.get(node, ()):
            if nxt not in color:
                continue
            if color[nxt] == GREY:
                found.append(frozenset(stack[stack.index(nxt):]))
            elif color[nxt] == WHITE:
                dfs(nxt)
        stack.pop()
        color[node] = BLACK

    for node in sorted(graph):
        if color[node] == WHITE:
            dfs(node)
    return found


class DartLayeringTest(unittest.TestCase):
    def setUp(self):
        self.graph = _dart_import_graph()

    def test_graph_covers_all_dart_files(self):
        """防空跑：图必须覆盖 lib/ 下每一个 Dart 文件，且边数与独立复算一致。

        为什么不用「文件数 > N」这种阈值判据（2026-10-13 自己踩过）：
        最初写的是 assertGreater(len(graph), 50)，注入故障验证时发现
        **删掉整个 lib/engine/ 目录它照样绿**——lib/ 有 123 个文件，删掉 20 个
        还剩 100+，阈值形同虚设。改成「图覆盖 == 磁盘文件集合」后**仍然不达标**：
        同一故障下两边同步变少、依旧相等。故判据必须能区分
        「检查对象整体缺失」与「解析逻辑失配」，用两条独立口径互校：

        1. 节点集合必须与磁盘上真实存在的 Dart 文件完全相等（抓路径失配）；
        2. 边总数必须与用**另一套写法**独立复算的结果相等（抓 import 正则失配）——
           若正则整体失配，边数会掉到 0 而节点数不变，仅靠第 1 条抓不到。
        """
        on_disk = {p.relative_to(LIB).as_posix()
                   for p in LIB.rglob("*.dart")}
        self.assertEqual(
            sorted(on_disk - set(self.graph)), [],
            "以下 Dart 文件未被 import 图覆盖——路径或 rglob 大概失配了，"
            "本检查正在空跑（环检测不出来 = 假绿）")
        self.assertEqual(
            sorted(set(self.graph) - on_disk), [],
            "import 图里出现了磁盘上不存在的文件——解析大概失配了")

        # 独立复算边数：不复用 _IMPORT_RE，用最朴素的逐行 find 判据。
        # 两套写法同时失配的概率远低于单独失配，且任一失配都会被这一条抓到。
        edge_total = sum(len(v) for v in self.graph.values())
        naive = 0
        for path in LIB.rglob("*.dart"):
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                s = line.strip()
                if (s.startswith("import ") or s.startswith("export ")) \
                        and "novel_writer/" in s:
                    naive += 1
        self.assertEqual(
            naive, edge_total,
            f"import 边数不一致：逐行朴素统计 {naive} vs 解析图 {edge_total}——"
            "import 正则大概失配了，环检测正在空跑")
        self.assertGreater(edge_total, 0, "解析出的 import 边为 0，检查已空跑")

    def test_no_unregistered_import_cycles(self):
        found = _find_cycles(self.graph)
        registered = set(KNOWN_CYCLES)
        # 只按 frozenset 比对：环的方向与起点不影响判定（A→B→A 与 B→A→B 是同一个问题）。
        unknown = [c for c in found if c not in registered]
        detail = "\n".join(
            "  " + " ↔ ".join(sorted(c)) for c in unknown) or "（无）"
        self.assertEqual(unknown, [],
                         "出现未登记的 import 环（Dart 不会为此报编译错，"
                         "只会让人「靠记得」维护分层）：\n" + detail +
                         "\n处置：优先拆掉环；确属框架固有形态再登记到 "
                         "KNOWN_CYCLES 并附理由。")

    def test_registered_cycles_still_exist(self):
        """反向守卫：白名单条目若已不存在（有人断掉了环），必须提醒删除登记项。

        没有这条，「删掉旧环」与「正则失配导致环检测不出来」在结果上不可区分——
        后者正是本项目最反对的假绿形态。
        """
        found = set(_find_cycles(self.graph))
        stale = [c for c in KNOWN_CYCLES if c not in found]
        detail = "\n".join("  " + " ↔ ".join(sorted(c))
                           for c in stale) or "（无）"
        self.assertEqual(stale, [],
                         "以下已登记的环已不存在——请从 KNOWN_CYCLES 删除，"
                         "否则本检查会随环检测逻辑退化而静默失效：\n" + detail)

    def test_engine_quality_does_not_import_ai_pipeline(self):
        """quality_gate.dart 声称的不变量：engine/quality/ 不得依赖 ai_pipeline/。

        理由（见该文件头）：这一层是纯规则质检，必须离线可用；一旦 import
        LLM 管线，离线/模板引擎场景会直接被拖崩，且崩溃点在依赖解析而非业务代码。
        """
        offenders = []
        for rel in sorted(k for k in self.graph
                          if k.startswith("engine/quality/")):
            for dep in sorted(self.graph[rel]):
                if dep.startswith("ai_pipeline/"):
                    offenders.append(f"{rel} -> {dep}")
        self.assertEqual(offenders, [],
                         "engine/quality/ 出现对 ai_pipeline/ 的依赖：\n  " +
                         "\n  ".join(offenders))


if __name__ == "__main__":
    unittest.main()
