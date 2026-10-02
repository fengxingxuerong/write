#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""质量主张的外部效度状态（机器可读，单一事实源 = rules/quality_validation.json）。

为什么需要这个模块（2026-10-03）
--------------------------------
本项目的质量主张建立在本地启发式指标上（爽点密度 / 章末钩子 / 对白占比 /
AI 味深度…）。docs/human-eval-workflow.md 已写明：这些指标都是**表层统计量的
代理**，模型只要多堆词、切碎段落、把对白凑到 30%，分数自然上去——即「可刷分」；
它们与「人读了觉得好」之间**没有任何已验证的关系**。因此在真实人评补上之前，
「80 分达线」只是**自洽**，不是**有效**。

问题在于：这个限定只写在文档里，而机器输出是无条件的——`run_smoke_gate.py`
照常打印 `SMOKE GATE: PASS`，Dart UI 照常显示「达线章节 12/13」。看输出的人
很容易把自洽当有效。本模块把状态变成可查询的对象，让上述两处在报 PASS/达线的
同时**强制披露**限定。

设计要点：状态从**真实标注数据推导**，而不是在代码里手写声明
------------------------------------------------------------
`validation_status()` 的入参是 annotations.jsonl 里 human 非 null 的行数、
以及是否存在报告，两者都来自磁盘真实状态。手写一个 `STATUS = "none"` 的常量
必然会随时间腐化（人评补上了、代码还写着 none），而从数据推导则会自动升级。
这也意味着**不可能说谎**：想让状态变成 validated，必须真的有人读过章节。

用法:
    from quality_validation import validation_status, caveat_lines
    print("\\n".join(caveat_lines()))   # 打印给人看的限定
    if not validation_status().is_validated: ...
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RULES_PATH = ROOT / "rules" / "quality_validation.json"
REPORT_DIR = ROOT / "docs" / "human-eval"

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # pragma: no cover - 旧解释器无此 API
    pass

STATUS_NONE = "none"
STATUS_INSUFFICIENT = "insufficient"
STATUS_PROVISIONAL = "provisional"
STATUS_VALIDATED = "validated"


class ValidationStatus:
    """外部效度状态（不可变快照）。

    - status: none / insufficient / provisional / validated
    - ratings: 真实人工标注条数（human 为数值）
    - total_rows: 标注表数据行数（含未评分的）
    - has_report: docs/human-eval/ 下是否存在 report-*.md
    """

    __slots__ = ("status", "ratings", "total_rows", "message", "has_report",
                 "min_conclusion", "min_strong")

    def __init__(self, status, ratings, total_rows, message, has_report,
                 min_conclusion, min_strong):
        self.status = status
        self.ratings = ratings
        self.total_rows = total_rows
        self.message = message
        self.has_report = has_report
        self.min_conclusion = min_conclusion
        self.min_strong = min_strong

    @property
    def is_validated(self) -> bool:
        """样本足够**且**已产出报告时为真。

        注意：validated 只代表「跑过实验」，不代表指标全都好——实验结论
        可能是「降权」或「下线」，那属于指标设计问题，见报告。
        """
        return self.status == STATUS_VALIDATED

    @property
    def needs_caveat(self) -> bool:
        """是否需要在「达线/PASS」旁强制披露限定。"""
        return self.status in (STATUS_NONE, STATUS_INSUFFICIENT)

    def as_dict(self) -> dict:
        return {
            "status": self.status,
            "ratings": self.ratings,
            "total_rows": self.total_rows,
            "has_report": self.has_report,
            "message": self.message,
        }

    def __repr__(self) -> str:
        return (f"ValidationStatus(status={self.status!r}, ratings={self.ratings}, "
                f"total_rows={self.total_rows}, has_report={self.has_report})")


def _load_config() -> dict:
    if not RULES_PATH.exists():
        raise SystemExit(f"缺少数据源：{RULES_PATH}")
    return json.loads(RULES_PATH.read_text(encoding="utf-8"))


def count_ratings(path: Path) -> tuple:
    """返回 (真实标注数, 数据行数)。

    以 `human` 字段为**数值**为准；`#` 开头为注释行不计入。
    判定刻意严格：`"human": "85"`（字符串）不算有效样本——那多半是机器批量
    生成的，而人评数据的全部价值来自「评分者是人」。
    """
    if not path.exists():
        return 0, 0
    ratings = 0
    total = 0
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        total += 1
        human = obj.get("human")
        if isinstance(human, bool):
            continue  # bool 是 int 子类，但显然不是评分
        if isinstance(human, (int, float)):
            ratings += 1
    return ratings, total


def _has_report() -> bool:
    if not REPORT_DIR.is_dir():
        return False
    return any(REPORT_DIR.glob("report-*.md"))


def validation_status(annotations: str = "", config: dict = None) -> ValidationStatus:
    """计算当前外部效度状态。

    annotations: 标注 JSONL 路径，默认取数据源里的 annotationsPath。
    config:      覆盖数据源（测试用）。
    """
    cfg = config if config is not None else _load_config()
    path = Path(annotations) if annotations else ROOT / cfg["annotationsPath"]
    ratings, total = count_ratings(path)
    report = _has_report()

    min_conclusion = int(cfg["minSamplesForConclusion"])
    min_strong = int(cfg["minSamplesForStrongConclusion"])
    vocab = cfg["statusVocabulary"]

    if ratings == 0:
        status = STATUS_NONE
    elif ratings < min_conclusion:
        status = STATUS_INSUFFICIENT
    elif not report:
        # 样本够了但没跑实验/没留报告：结论尚未产出，不能算 validated。
        status = STATUS_PROVISIONAL
    else:
        status = STATUS_VALIDATED

    return ValidationStatus(
        status=status,
        ratings=ratings,
        total_rows=total,
        message=vocab[status],
        has_report=report,
        min_conclusion=min_conclusion,
        min_strong=min_strong,
    )


def caveat_lines(indent: str = "  ") -> list:
    """返回可直接 print 的限定文本行（供 CLI 在 PASS/达线旁披露）。"""
    s = validation_status()
    bar = f"{indent}│"
    lines = [
        f"{indent}┌─ 质量指标外部效度限定（勿把『达线』当成『好看』）",
        f"{bar} 状态：{s.status}｜真实人评标注 {s.ratings}/{s.total_rows} 条"
        f"（结论需 ≥{s.min_conclusion} 条，建议 ≥{s.min_strong} 条）",
        f"{bar} {s.message}",
    ]
    if s.status == STATUS_NONE:
        lines.append(
            f"{bar} 本次分数只证明「规则自洽」，不代表「读者认可」；"
            f"指标可被刷分（多堆词/切碎段落/凑对白）。")
        lines.append(
            f"{bar} 补标注：web/human-eval.html 打分后导出覆盖 {cfg_path_hint()}")
    if s.is_validated:
        lines.append(f"{indent}└─ 报告：docs/human-eval/report-*.md")
    else:
        lines.append(f"{indent}└─ 详见 docs/human-eval-workflow.md（SKILL.md「诚实边界」）")
    return lines


def cfg_path_hint() -> str:
    try:
        return _load_config()["annotationsPath"]
    except SystemExit:
        return "docs/human-eval/annotations.jsonl"


def main() -> int:
    s = validation_status()
    print("墨匠 · 质量指标外部效度状态")
    print("=" * 56)
    print(f"状态        ：{s.status}")
    print(f"真实人评标注：{s.ratings} / {s.total_rows} 条")
    print(f"相关性报告  ：{'有' if s.has_report else '无'}")
    print(f"结论样本线  ：≥{s.min_conclusion} 条（建议 ≥{s.min_strong} 条）")
    print(f"释义        ：{s.message}")
    if s.needs_caveat:
        print()
        print("⚠ 当前「达线」结论仅为自洽，不具外部效度。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())