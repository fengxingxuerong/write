<!-- GENERATED FILE — DO NOT EDIT. 由 scripts/rules_codegen.py 生成。 -->

# 当前质检判据与阈值总表

> 数据源：`rules/quality_rules.json`（version 1，updated 2026-10-01）。
> 改判据请改 JSON 再跑 `python scripts/rules_codegen.py`；本文档与双端常量会自动同步。

## 一、词表（双端逐值、逐序一致）

| 常量 | 条数 | 作用 |
|---|---|---|
| `hookWords` / `HOOK_WORDS` | 70 | 章末钩子信号词：结尾 200 字内命中即视为有钩子。含直白突变 / 隐喻式钩子（被跟踪感、身份伏笔、诡谲意象）/ 悬而未决三类。三件套词（triadHookOnly）单独出现时不采信。顺序无关（contains 判定）。 |
| `openingStrong` / `OPENING_STRONG` | 13 | 开场节奏强信号词：首屏命中 1 个即视为快速进入事件。 |
| `openingWeak` / `OPENING_WEAK` | 25 | 开场节奏弱信号词：单字动词/名词，需同屏命中 ≥2 个才达标（避免「像纸一样一碰就碎」式比喻误报）。 |
| `thrillWords` / `THRILL_WORDS` | 96 | 外显爽点（💥）信号词：打脸 / 升级 / 收获 / 揭露四类，闭合词表。**全表必须唯一**——重复登记会让 text.count() 把同一处命中记两次，造成 Python 侧密度高于 Dart 侧（2026-09-29 真机实测到的漂移）。Python 侧另有 GENRE_THRILL_EXTRA 题材加成词（见 asymmetries）。 |
| `powerSurgeWords` / `POWER_SURGE_WORDS` | 55 | 变强异动（✨）信号词：含蓄变强流的身体异动/器物微光表达。与 thrillWords 构成双通道，避免把「只有含蓄异动」的书误判为无爽点。 |
| `sideReactionWords` / `SIDE_REACTION_WORDS` | 47 | 侧面反响信号词（三视角震惊环：反派崩溃 / 路人倒吸冷气 / 权威暗惊）。同时是「爽点断供」判定的逃生通道——在场者确有反应的章不判断供。 |
| `triadEndWords` / `TRIAD_END_WORDS` | 12 | 章末三件套收尾词表（规则 20：禁止发烫/亮起/苏醒类收束）。**顺序敏感**——Dart endingTriad 返回首个命中词，长词必须排在前（像有什么东西醒了 > 醒了过来 > 醒了；亮了起来 > 亮了）。 |
| `triadHookOnly` / `TRIAD_HOOK_ONLY` | 2 | hookWords 中属三件套性质的成员：作为唯一尾部钩子信号时不采信。 |

## 二、阈值

| 常量 | 值 | 作用 |
|---|---|---|
| `triadEndWindow` / `TRIAD_END_WINDOW` | 60 | 三件套收束判定窗口（末尾字数）。校准：末句 6.9% / 末 60 字 11.2% / 末 200 字 25.9%；取 60 字，200 字窗会误伤「尾部另有真钩子、三件套只在中段出现」的章。 |
| `minDialogueRatio` / `MIN_DIALOGUE_RATIO` | 0.18 | 单章对白占比下限（低于即判「对白塌陷」，番茄口径建议 25%~45%，18% 是硬伤线）。 |
| `maxFillerRatio` / `MAX_FILLER_RATIO` | 12.0 | 水段率上限（%）：无对白且无推进词的 ≥40 字段落占比超过它即判注水。 |
| `droughtThrillPerK` / `DROUGHT_THRILL_PER_K` | 0.5 | 爽点断供判定的 💥 密度线（每千字命中数，低于即视为该章无外显兑现）。 |
| `droughtSidePerK` / `DROUGHT_SIDE_PER_K` | 0.3 | 断供逃生通道的侧面反响密度线：💥 低但侧面反响 ≥ 此值 = 兑现已送达读者，不判断供（防误伤不写套话的好稿）。 |
| `droughtMinRun` / `DROUGHT_MIN_RUN` | 3 | 连续多少章双低才算「断供带」（1~2 章连低属正常节奏起伏）。 |
| `fixMinRatio` / `FIX_MIN_RATIO` | 0.92 | 定点修提示词里的字数硬下限（改写后不得低于原文的该比例）。必须比采纳守卫（Python EDITOR_MIN_RATIO=0.85）更严一档，否则模型会照「删水段」整章压缩、产出被守卫整份拒绝、定点修白跑。 |

## 三、已知的端间不对称（**故意如此**，不要「顺手统一」）

| 项 | Dart 侧 | Python 侧 | 原因 |
|---|---|---|---|
| `editorMinRatio` | 尚未实现该守卫 | 0.85 | novel_pipeline.apply_text_patch 的整章级补丁采纳下限。比 FIX_MIN_RATIO 松一档是设计意图（提示词从严，守卫兜底）；Dart 端补齐前不要把两者合并。 |
| `genreThrillExtras` | 只用基础 thrillWords / powerSurgeWords | GENRE_THRILL_EXTRA / GENRE_SURGE_EXTRA 题材加成词 | 题材加成词仅 Python 侧存在（2026-09-10 题材感知质检）。因此断供判定（payoff_drought_*）在 Python 侧显式只用基础词表，否则双端不同口径。 |
| `countWords` | AppConstants.countWords | fanqie_review.count_words | 已知既有差异：Python 侧把「字母->数字」转换算新词、Dart 算同一个词，且 Python 缺 CJK 扩展 A 区。密度类指标因此允许极小的数值差异，**不要**为此改动字数口径（那是影响界面显示的产品级决定，见 docs/quality-enhancement-log.md 第 31 节）。 |

## 四、改判据的正确流程

1. 只改 `rules/quality_rules.json`（先想清是改词表还是改阈值）；
2. 跑 `python scripts/rules_codegen.py` 重新生成三份产物；
3. 跑 `python -m unittest discover -s scripts -p 'test_*.py'`（含双端对账）与 `flutter test`（含 Dart 侧对账）；
4. 涉及分数的词表变动，按 `docs/human-eval-workflow.md` 用人评样本复核（避免「指标涨了、人评没涨」）。

