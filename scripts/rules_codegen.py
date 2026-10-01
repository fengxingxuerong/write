#!/usr/bin/env python3
"""质检规则单一数据源 -> 双端常量 + 阈值总表（代码生成）。

背景（2026-10-01）：
    词表与阈值此前在 Dart（lib/ai_pipeline/services/pipeline_qa.dart 等）与
    Python（scripts/generate_novel.py / scripts/fanqie_review.py）各写一份，
    靠注释约定「改一处必须同步另一处」。实测这份约定守得很稳（8 组词表逐值、
    逐序一致），但**没有任何机制**拦得住漏改——一旦漏改，双端质检口径不同，
    成书结论互相矛盾。

    故把词表/阈值收进 rules/quality_rules.json 作为唯一数据源，由本脚本生成：

        1. lib/engine/quality/quality_rules.g.dart    （Dart 常量）
        2. scripts/quality_rules_generated.py         （Python 常量）
        3. docs/quality-rules-current.md              （人读的阈值总表）

    生成物带「DO NOT EDIT」头，CI 用 `--check` 校验「生成物 == 数据源」；
    Dart 侧另有 test/engine/quality/quality_rules_parity_test.dart 运行时逐值
    对账，Python 侧 scripts/test_quality_rules_parity.py 同理。

用法:
    python scripts/rules_codegen.py            # 生成/刷新三份产物
    python scripts/rules_codegen.py --check    # 只校验（CI 门禁），不一致则 exit 1
"""
import argparse
import json
import re
import sys
from pathlib import Path

# 词条里出现这些字符时，本脚本的「原样塞进引号」产出会生成语法错误的源码。
# 含前导/尾随空白由 validate() 单独判定（错误信息不同：那是永不命中而非语法错）。
_UNSAFE = re.compile(r"""['"\\\n\r\t]|[\x00-\x1f]""")

ROOT = Path(__file__).resolve().parent.parent
RULES_PATH = ROOT / "rules" / "quality_rules.json"
DART_OUT = ROOT / "lib" / "engine" / "quality" / "quality_rules.g.dart"
PY_OUT = ROOT / "scripts" / "quality_rules_generated.py"
DOC_OUT = ROOT / "docs" / "quality-rules-current.md"

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def snake_upper(camel: str) -> str:
    """camelCase -> UPPER_SNAKE_CASE（Python 侧常量名，保持既有命名不变）。"""
    out = []
    for i, ch in enumerate(camel):
        if ch.isupper() and i > 0:
            out.append("_")
        out.append(ch.upper())
    return "".join(out)


def validate(rules: dict) -> list:
    """校验数据源本身，返回问题列表（空 = 通过）。

    为什么需要（2026-10-01）：本脚本的 Dart/Python 产出都**直接把词条原文塞进
    引号**（dart_literal / python_literal 均不做转义）。实测当前 803 个词条里
    没有任何词条含引号/反斜杠/换行/首尾空白，所以一直没炸——但这是**运气，
    不是护栏**：往 JSON 里加一个英文缩写（don't）、一个 Windows 路径或一个带
    首尾空格的词（历史上真出现过 " Jesus" 前导空格），就会生成**语法错误**的
    Dart/Python 源码，或者生成一个永不命中的词条。

    与其赌运气，不如在这里挡住：让问题在 codegen 阶段就以明确的报错出现。
    """
    problems = []
    lists = rules.get("lists")
    scalars = rules.get("scalars")
    if not isinstance(lists, list) or not lists:
        problems.append("lists 缺失或为空")
    if not isinstance(scalars, list):
        problems.append("scalars 缺失")
    for section, items in (("lists", lists or []), ("scalars", scalars or [])):
        for item in items:
            if not isinstance(item, dict):
                problems.append(f"{section}: 存在非对象条目")
                continue
            iid = item.get("id", "<无 id>")
            if section == "lists":
                values = item.get("values")
                kind = item.get("kind")
                if kind not in ("list", "set"):
                    problems.append(f"lists/{iid}: kind 必须是 'list' 或 'set'，实为 {kind!r}")
                if not isinstance(values, list) or not values:
                    problems.append(f"lists/{iid}: values 缺失或为空")
                    continue
                for v in values:
                    if not isinstance(v, str):
                        problems.append(f"lists/{iid}: 词条必须是字符串，实为 {v!r}")
                    elif v != v.strip():
                        problems.append(
                            f"lists/{iid}: 词条 {v!r} 有首尾空白——永不命中，请删掉空白")
                    elif _UNSAFE.search(v):
                        problems.append(
                            f"lists/{iid}: 词条 {v!r} 含引号/反斜杠/换行/控制字符，"
                            "本脚本的产出不做转义，会生成语法错误的 Dart/Python")
                # 重复项会让「命中数」在两端算法里含义不一致（记两次）。
                if len(set(values)) != len(values):
                    dupes = sorted({v for v in values if values.count(v) > 1})
                    problems.append(f"lists/{iid}: 存在重复词条 {dupes}")
            else:
                if not isinstance(item.get("value"), (int, float)):
                    problems.append(f"scalars/{iid}: value 必须是数字")
                if item.get("dartType") not in ("int", "double"):
                    problems.append(
                        f"scalars/{iid}: dartType 必须是 'int' 或 'double'，"
                        f"实为 {item.get('dartType')!r}")
    ids = [i.get("id") for i in (lists or []) if isinstance(i, dict)]
    dup_ids = sorted({i for i in ids if ids.count(i) > 1})
    if dup_ids:
        problems.append(f"lists: 存在重复 id {dup_ids}")
    return problems


def load_rules() -> dict:
    if not RULES_PATH.exists():
        raise SystemExit(f"缺少数据源：{RULES_PATH}")
    rules = json.loads(RULES_PATH.read_text(encoding="utf-8"))
    problems = validate(rules)
    if problems:
        print("数据源 rules/quality_rules.json 自身有问题，已中止（避免生成坏产物）：")
        for p in problems:
            print("  -", p)
        raise SystemExit(1)
    return rules


def dart_literal(item: dict) -> str:
    """按 kind 产出 Dart 常量声明。"""
    name = item["id"]
    values = item["values"]
    doc = "  /// " + item["doc"].replace("\n", " ")
    if item["kind"] == "set":
        body = ", ".join("'%s'" % v for v in values)
        return f"{doc}\n  static const Set<String> {name} = <String>{{{body}}};"
    body = "".join("\n    '%s'," % v for v in values)
    return (f"{doc}\n  static const List<String> {name} = <String>[{body}\n  ];")


def dart_scalar(item: dict) -> str:
    doc = "  /// " + item["doc"].replace("\n", " ")
    val = item["value"]
    lit = str(int(val)) if item["dartType"] == "int" else repr(float(val))
    return f"{doc}\n  static const {item['dartType']} {item['id']} = {lit};"


def render_dart(rules: dict) -> str:
    header = (
        "// GENERATED FILE — DO NOT EDIT.\n"
        "//\n"
        "// 由 scripts/rules_codegen.py 从 rules/quality_rules.json 生成；\n"
        "// 要改词表或阈值，请改 JSON 后运行：python scripts/rules_codegen.py\n"
        "//\n"
        "// 校验：CI 跑 `python scripts/rules_codegen.py --check`；\n"
        "// 另有 test/engine/quality/quality_rules_parity_test.dart 运行时逐值对账。\n"
        "\n"
        "/// 质检规则常量（词表 / 阈值）——单一数据源见 rules/quality_rules.json。\n"
        "class QualityRules {\n"
        "  const QualityRules._();\n"
    )
    blocks = [dart_literal(i) for i in rules["lists"]]
    blocks += [dart_scalar(i) for i in rules["scalars"]]
    return header + "\n" + "\n\n".join(blocks) + "\n}\n"


def python_literal(item: dict) -> str:
    name = snake_upper(item["id"])
    lines = [f"# {item['doc']}"]
    if item["kind"] == "set":
        body = ", ".join('"%s"' % v for v in item["values"])
        lines.append(f"{name} = frozenset({{{body}}})")
        return "\n".join(lines)
    lines.append(f"{name} = [")
    for v in item["values"]:
        lines.append('    "%s",' % v)
    lines.append("]")
    return "\n".join(lines)


def python_scalar(item: dict) -> str:
    name = snake_upper(item["id"])
    val = item["value"]
    lit = str(int(val)) if item["dartType"] == "int" else repr(float(val))
    return f"# {item['doc']}\n{name} = {lit}"


def render_python(rules: dict) -> str:
    names = [snake_upper(i["id"]) for i in rules["lists"] + rules["scalars"]]
    header = (
        "# GENERATED FILE — DO NOT EDIT.\n"
        "#\n"
        "# 由 scripts/rules_codegen.py 从 rules/quality_rules.json 生成。\n"
        "# 改词表/阈值请改 JSON 后运行：python scripts/rules_codegen.py\n"
        "# 校验：python scripts/rules_codegen.py --check 与 scripts/test_quality_rules_parity.py\n"
        '"""质检规则常量（词表/阈值）——单一数据源 rules/quality_rules.json。"""\n'
    )
    blocks = [python_literal(i) for i in rules["lists"]]
    blocks += [python_scalar(i) for i in rules["scalars"]]
    all_line = "__all__ = [\n" + "".join('    "%s",\n' % n for n in names) + "]\n"
    return header + "\n" + "\n\n".join(blocks) + "\n\n" + all_line


def render_doc(rules: dict) -> str:
    out = [
        "<!-- GENERATED FILE — DO NOT EDIT. 由 scripts/rules_codegen.py 生成。 -->",
        "",
        "# 当前质检判据与阈值总表",
        "",
        f"> 数据源：`rules/quality_rules.json`（version {rules['version']}，"
        f"updated {rules['updated']}）。",
        "> 改判据请改 JSON 再跑 `python scripts/rules_codegen.py`；"
        "本文档与双端常量会自动同步。",
        "",
        "## 一、词表（双端逐值、逐序一致）",
        "",
        "| 常量 | 条数 | 作用 |",
        "|---|---|---|",
    ]
    for i in rules["lists"]:
        out.append("| `%s` / `%s` | %d | %s |"
                   % (i["id"], snake_upper(i["id"]), len(i["values"]),
                      i["doc"].replace("|", "\\|")))
    out += ["", "## 二、阈值", "", "| 常量 | 值 | 作用 |", "|---|---|---|"]
    for i in rules["scalars"]:
        out.append("| `%s` / `%s` | %s | %s |"
                   % (i["id"], snake_upper(i["id"]), i["value"],
                      i["doc"].replace("|", "\\|")))
    out += [
        "",
        "## 三、已知的端间不对称（**故意如此**，不要「顺手统一」）",
        "",
        "| 项 | Dart 侧 | Python 侧 | 原因 |",
        "|---|---|---|---|",
    ]
    for a in rules.get("asymmetries", []):
        out.append("| `%s` | %s | %s | %s |"
                   % (a["name"], a["dart"], a["python"], a["why"]))
    out += [
        "",
        "## 四、改判据的正确流程",
        "",
        "1. 只改 `rules/quality_rules.json`（先想清是改词表还是改阈值）；",
        "2. 跑 `python scripts/rules_codegen.py` 重新生成三份产物；",
        "3. 跑 `python -m unittest discover -s scripts -p 'test_*.py'`（含双端对账）"
        "与 `flutter test`（含 Dart 侧对账）；",
        "4. 涉及分数的词表变动，按 `docs/human-eval-workflow.md` 用人评样本复核"
        "（避免「指标涨了、人评没涨」）。",
        "",
    ]
    return "\n".join(out) + "\n"


def build_all(rules: dict) -> dict:
    return {
        DART_OUT: render_dart(rules),
        PY_OUT: render_python(rules),
        DOC_OUT: render_doc(rules),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="质检规则代码生成（单一数据源 -> 双端常量）")
    ap.add_argument("--check", action="store_true",
                    help="只校验生成物是否与 rules/quality_rules.json 一致（CI 用）")
    args = ap.parse_args()

    rules = load_rules()
    outputs = build_all(rules)

    if args.check:
        stale = []
        for path, text in outputs.items():
            rel = path.relative_to(ROOT).as_posix()
            if not path.exists():
                stale.append(f"缺失：{rel}")
            elif path.read_text(encoding="utf-8") != text:
                stale.append(f"过期：{rel}")
        if stale:
            print("规则生成物与 rules/quality_rules.json 不一致：")
            for s in stale:
                print("  -", s)
            print("修复：python scripts/rules_codegen.py 并提交生成物。")
            return 1
        total = sum(len(i["values"]) for i in rules["lists"])
        print(f"规则生成物一致（{len(rules['lists'])} 组词表 / {total} 词 / "
              f"{len(rules['scalars'])} 项阈值）")
        return 0

    for path, text in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        # newline="\n"：仓库 .gitattributes 要求 LF，避免 Windows 上生成 CRLF 造成行尾抖动
        with path.open("w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        print("wrote", path.relative_to(ROOT).as_posix())
    return 0


if __name__ == "__main__":
    sys.exit(main())
