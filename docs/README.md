# docs/ 文档索引

> 按「你现在要解决什么问题」组织，而不是按文件名排序。
> **时效性约定**：带 ⚠️ 的是历史归档，只供追溯，**不要照它改代码**。

## 我要改代码 → 先看这些

| 文档 | 用途 | 时效 |
| --- | --- | --- |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | **当前架构**：分层、关键抽象、生成链路、数据流、测试策略 | 当前 |
| [`quality-rules-current.md`](quality-rules-current.md) | **质检判据与阈值总表**（由 `rules/quality_rules.json` 生成，勿手改） | 生成物 |
| [`../README.md`](../README.md) | 功能清单、运行/构建、目录结构、CI 流水线 | 当前 |
| [`class-diagram.mermaid`](class-diagram.mermaid) / [`sequence-diagram.mermaid`](sequence-diagram.mermaid) | 类图 / 时序图 | 当前 |

## 我要改质检判据（词表 / 阈值）

流程是**单一数据源**，不要直接改生成物或两端字面量：

1. 改 `rules/quality_rules.json`
2. 跑 `python scripts/rules_codegen.py`
3. 跑双端对账（`python -m unittest discover -s scripts` + `flutter test`）
4. 分数相关变动，按 [`human-eval-workflow.md`](human-eval-workflow.md) 复核

| 文档 | 用途 | 时效 |
| --- | --- | --- |
| [`quality-rules-current.md`](quality-rules-current.md) | 阈值总表 + **已知的端间不对称**（第三节，收编前必读） | 生成物 |
| [`human-eval-workflow.md`](human-eval-workflow.md) | 人评相关性实验：回答「指标涨了，人评涨了吗」 | 当前 |
| [`optimization-report.md`](optimization-report.md) | 一次全方面排查的结论（27 处问题 + 覆盖率/写盘实测） | 快照 |

## 我要了解历史演进 / 为什么这么设计

| 文档 | 用途 | 时效 |
| --- | --- | --- |
| [`quality-enhancement-log.md`](quality-enhancement-log.md) | **逐轮改动日志（最大的一份，156 KB）**，含真机实测数据与踩坑记录 | 追加式 |
| [`交付文档.md`](交付文档.md) | 角色矩阵、终审三级权力、投前质检五关、**已知问题与遗留事项** | 追加式 |
| [`storage-stress-200k-report.md`](storage-stress-200k-report.md) | 20 万字级存储压测与写放大实测 | 快照 |

## ⚠️ 历史归档（勿照此改代码）

| 文档 | 快照时点 | 已被什么取代 |
| --- | --- | --- |
| ⚠️ [`code-summary.md`](code-summary.md) | 2026-07-31 MVP 交付 | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| ⚠️ [`architecture-mvp.md`](architecture-mvp.md) | 2026-07-31 MVP 设计 | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| ⚠️ [`prd-mvp.md`](prd-mvp.md) | 2026-07-31 MVP 需求 | [`../README.md`](../README.md) |

> 保留它们是为了追溯「当初为什么这么设计」，以及**看踩过的坑**。
> 三份文档自身已带归档警示标记（commit `60c9902`）。

## 人评实验数据

- `human-eval/annotations.jsonl` —— 标注表（**入库**）。⚠️ 当前 `human` 字段**真实标注 0 条**。
- `human-eval/samples/*.txt` —— 样本正文（**不入库**，换机器重跑 `python scripts/human_eval_sample.py` 重建）。
- 查看当前效度状态：`python scripts/quality_validation`。

## 两条命令先记住

```bash
python scripts/quality_validation     # 质量指标是否已与人评对齐（当前：未对齐）
python scripts/ab_rules_parity        # 双端词表 A/B（用真实成书量化收编影响面）
```