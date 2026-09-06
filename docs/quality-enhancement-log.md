# 墨匠质量增强包 — 改动清单

> 记录一次系统性质量优化（2026-09），目标：成书质量对标番茄签约/上架标准。
> 改动覆盖生成侧、质检侧、质量闭环、工具链，Dart 与 Python 双端对齐。

---

## 一、仓库卫生（安全）

| 文件 | 改动 |
|---|---|
| `.gitignore` | 新增忽略：`data/`（大体积语料/产物）、`__pycache__/`、`*.py[cod]`、`.env`、`.env.*`、`*.key` |

⚠️ 遗留：`scripts/generate_novel.py` 第 8 行附近仍硬编码 AMD API Key，建议轮换并改环境变量注入。

---

## 二、生成侧（怎么写）

| 文件 | 改动 |
|---|---|
| `lib/engine/writing_guidelines.dart` | ① 新增「网文商业结构」块：黄金三章 / 爽点优先 / 章末钩子强制 / 追读欲；② 核心技法新增第 7 条「变强具象化」（含蓄爽点：丹田温热/掌心发烫式身体异动，直白"突破"限 1 次） |
| `lib/ai_pipeline/prompts/pipeline_prompts.dart` | 强化 5 处：写手系统准则（商业结构+变强具象化）、规划官（黄金三章链/每章爽点+钩子）、场景规划（爽点场景/末场景「合」/第一章快速触发）、场景正文（末场景强制钩子）、编辑（保留并强化章末钩子）；新增 `qualityReviewPrompt`（五维评分）、`rewritePrompt`（低分定向重写）、`stateExtractPrompt`（跨章状态提取）；`scenePlanningPrompt`/`scenePrompt` 加 `state` 参数 |
| `lib/engine/multipass/scene_builder.dart` | 场景规划加爽点/钩子要求；兜底骨架末场景钩子强化 |
| `lib/engine/multipass/multi_pass_chapter_engine.dart` | 末场景强制「章末钩子」指令 |
| `scripts/generate_novel.py` | SYSTEM_PROMPT 商业结构+变强具象化；规划/场景/写手/编辑 prompt 同步；`scene_planning_prompt`/`scene_prompt` 加 `state` 参数 |

## 三、质检侧（怎么查）

| 文件 | 能力 |
|---|---|
| `lib/ai_pipeline/services/pipeline_qa.dart` | ① 章末钩子检测（直白+隐喻双通道，词表经 33 章实测校准，命中率 82%）；② 开场节奏检测（强/弱双级信号，修复"一碰就碎"式比喻误报）；③ 爽点双通道：直白爽点 💥 + 变强异动 ✨（含蓄变强流不再误判"爽点过淡"）；④ AI 味深度检测（句长变异系数 CV / 「的」字密度 / 叠词修饰 / 句首连接词，统计层反 AI 腔） |
| `scripts/generate_novel.py` | 同源同步：`HOOK_WORDS`、`THRILL_WORDS`、`POWER_SURGE_WORDS`、`deep_ai_metrics`、`has_quick_opening`（双级）；质检汇总打印 🪝/⚡/💥/✨/🤖 |

**词表校准历程（真实成书实测驱动）**
- 钩子词表：初版 39% 命中 → 补隐喻式钩子（监视/诡谲意象/悬而未决）→ 82%
- 爽点词表：直白词仅命中 5 处 → 发现含蓄文风爽点藏在身体异动（58 处）→ 新增变强异动通道
- 开场词表：修复单字词比喻误报 → 强/弱双级判定

## 四、质量闭环（怎么改）

| 能力 | 位置 | 说明 |
|---|---|---|
| 语义五维评分 | `ai_pipeline_service.dart` + `novel_pipeline.py` | 审校官每 3 章评分开篇/爽点/钩子/动机/节奏，`<60` 标记告警 |
| 低分自动重写 | 同上 | 评分 `<55` 自动触发编辑官定向重写（保留情节/钩子，针对薄弱维度），失败保留原文 |
| 跨章状态追踪 | 同上 + models | 每章提取人物伤势/修为/物品/承诺状态清单，注入下一章 prompt 防穿帮；断点续传自动恢复 |

配置字段（`AiPipelineConfig`，序列化向后兼容）：`useQualityReview`/`qualityReviewEvery`/`autoRewriteLowScore`/`rewriteThreshold`/`useStateTrack`

## 五、工具链（怎么判断）

| 工具 | 能力 |
|---|---|
| `scripts/qa_scan_existing.py` | 单本扫描：逐章指标（钩子/开场/爽点/异动/AI味/AI深度）+ 爽点密度曲线 + 节奏塌陷检测 + 黄金三章专项体检（变故/落差/金手指/目标/钩子）+ 签约可行性报告（五维 100 分制 + 对标番茄要素） |
| `scripts/ab_compare.py` | A/B 对比：两本成书并排（新旧标准/双模型/校对前后），自动判定胜负与显著差异 |
| `scripts/run_quality_test.ps1` | 一键实测：新版生成 3000 字 + 基线扫描连跑 |

## 六、流水线运行效果示例

```
  [规划] 5 场景：起/承/转/转/合
  [评分] 第 3 章 综合 82 分（开篇85/爽点60/钩子90/动机75/节奏80）节奏紧凑
  [评分] 第 6 章 综合 47 分 过渡章注水严重
  [重写] 第 6 章 47 分 < 55，触发自动重写...  2876 字 -> 3012 字
  [状态] 已更新跨章状态清单（5 行）
  [质检] ⚠ 第 6 章 AI 腔偏重：句长过于均匀（CV=0.49）
  [完成] 第 6 章：3012 字 | 累计 15678 字
```

## 七、验证结论

- 全部检测器经《碎脉铸仙录》10.6 万字真实文本逐项验证：钩子 82% 命中、含蓄变强流正确识别、黄金三章体检能发现真实短板（第 2 章目标偏弱）、AI 深度判定与真实文风一致（且修正了人工直觉的两次误判）
- 词表校准方法论：真实成书回测 → 发现漏检/误报 → 修正 → 双端同步 → 复测
