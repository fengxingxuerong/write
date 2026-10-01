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
| `gateClichePhrases` / `GATE_CLICHE_PHRASES` | 19 | 网文高频套句（Dart 侧过审闸门「同质化」判定用）：distinct 命中 ×1000/字 > 1.2 判修改。**注意**：与 Python 的 reviewClicheSentences 是同一套指标公式、不同词表——Dart 19 条多为短词（如「命运的车轮」「仿佛在诉说」，匹配更宽），Python 34 条多为长句（匹配更准但覆盖更窄）。两侧漂移见 asymmetries.clicheTables。 |
| `reviewClicheSentences` / `REVIEW_CLICHE_SENTENCES` | 34 | 网文高频套句（Python 侧 fanqie_review.cliche_overlap「同质化」判定用）：同样按 distinct 命中 ×1000/字 > 1.2 触发「修改」。与 gateClichePhrases 公式同、词表不同（见 asymmetries.clicheTables）。 |
| `redlinePolitics` / `REDLINE_POLITICS` | 30 | Python 番茄过审红线·时政类（veto 级：命中即一票否决，部分词可经 REDLINE_WHITELIST 降级为提示）。分类名 `时政敏感`，共 30 词。 |
| `redlineReligion` / `REDLINE_RELIGION` | 29 | Python 番茄过审红线·宗教/民族类（含邪教、巫术、通灵等封建迷信渲染）。分类名 `宗教民族`，共 29 词。 |
| `redlineMinorRisk` / `REDLINE_MINOR_RISK` | 17 | Python 番茄过审红线·未成年人类（含校园、偷拍视频、性化描写；此类为平台最高风险之一）。分类名 `未成年风险`，共 17 词。 |
| `redlineGore` / `REDLINE_GORE` | 22 | Python 番茄过审红线·过度血腥类（分尸/肢解/凌迟等，多数词在 REDLINE_WHITELIST 中按叙事语境降级）。分类名 `过度血腥`，共 22 词。 |
| `redlineBrandCelebrity` / `REDLINE_BRAND_CELEBRITY` | 25 | Python 番茄过审红线·现实品牌与在世真人（平台禁止出现真实商业品牌与公众人物名）。分类名 `现实品牌与真人`，共 25 词。 |
| `redlineIllegalDetail` / `REDLINE_ILLEGAL_DETAIL` | 15 | Python 番茄过审红线·可被照做的违法/危险操作细节（配方、撬锁、洗钱、跑路等），属「方法可复现」类高危。分类名 `教唆与违法细节`，共 15 词。 |
| `sensitiveViolence` / `SENSITIVE_VIOLENCE` | 37 | Dart 编辑自查词库·暴力血腥类（自用提示，不做平台判定）。分类名 `暴力血腥`，共 37 词。 |
| `sensitiveSexual` / `SENSITIVE_SEXUAL` | 33 | Dart 编辑自查词库·色情低俗类。分类名 `色情低俗`，共 33 词。 |
| `sensitiveAbuse` / `SENSITIVE_ABUSE` | 27 | Dart 编辑自查词库·脏话辱骂类。分类名 `脏话辱骂`，共 27 词。 |
| `sensitiveIllegal` / `SENSITIVE_ILLEGAL` | 32 | Dart 编辑自查词库·违法违规类。分类名 `违法违规`，共 32 词。 |
| `sensitiveAds` / `SENSITIVE_ADS` | 28 | Dart 编辑自查词库·广告引流类（群号/私域引流等）。分类名 `广告引流`，共 28 词。 |
| `promptLeak` / `PROMPT_LEAK` | 11 | 骨架/提示词泄漏标记：规划/场景 prompt 的结构词漏进正文即判废（阻断级）。双端逐值一致（各 11 词）。 |
| `metaTalk` / `META_TALK` | 24 | 元话语/指令残留：补写与定点修把「我拿到的指令是…」当正文吐出来（实测被拼进成书）。双端逐值一致（各 24 词）。 |
| `modernMarkers` / `MODERN_MARKERS` | 38 | 现代词汇标记：古风题材出现手机/电梯/网络等即判题材漂移；与 ancientGenres 配套。双端逐值一致（各 38 词）。 |
| `ancientGenres` / `ANCIENT_GENRES` | 13 | 古风题材白名单：命中则不把现代词判定为题材漂移（玄幻/仙侠/武侠/修真/历史…）。双端逐值一致（各 13 词）。 |
| `negation` / `NEGATION` | 8 | 否定词（前缀 6 字内出现即视为否定表述）：世界观「同一关键词肯定/否定」冲突检测用。双端逐值一致（各 8 词）。 |
| `aiAdverbs` / `AI_ADVERBS` | 12 | AI 腔副词（微微/轻轻/淡淡…）：统计层 AI 味指标之一。双端逐值一致（各 12 词）。 |
| `sentenceConnectors` / `SENTENCE_CONNECTORS` | 10 | 句首连接词率：统计层 AI 味指标之一（然而/但是/因此…）。双端逐值一致（各 10 词）。 |
| `bodyReactionWords` / `BODY_REACTION_WORDS` | 19 | 身体反应词表：句式指纹 body_reaction_density 项（发烫/发凉/汗毛…）。双端逐值一致（各 19 词）。 |

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
| `intraRepeatMinBlock` / `INTRA_REPEAT_MIN_BLOCK` | 120 | 章内重复检测的最短重复块字数（超过此长度的重复块判「凑字」，rewrite 级）。Dart FanqieGateChecker.intraRepeatMinBlock 与本值同口径。 |
| `intraRepeatGram` / `INTRA_REPEAT_GRAM` | 12 | 章内重复检测的滑动指纹长度（n-gram）。Dart FanqieGateChecker._intraGram 同口径。 |

## 三、已知的端间不对称（**故意如此**，不要「顺手统一」）

| 项 | Dart 侧 | Python 侧 | 原因 |
|---|---|---|---|
| `editorMinRatio` | 尚未实现该守卫 | 0.85 | novel_pipeline.apply_text_patch 的整章级补丁采纳下限。比 FIX_MIN_RATIO 松一档是设计意图（提示词从严，守卫兜底）；Dart 端补齐前不要把两者合并。 |
| `genreThrillExtras` | 只用基础 thrillWords / powerSurgeWords | GENRE_THRILL_EXTRA / GENRE_SURGE_EXTRA 题材加成词 | 题材加成词仅 Python 侧存在（2026-09-10 题材感知质检）。因此断供判定（payoff_drought_*）在 Python 侧显式只用基础词表，否则双端不同口径。 |
| `countWords` | AppConstants.countWords | fanqie_review.count_words | 已知既有差异：Python 侧把「字母->数字」转换算新词、Dart 算同一个词，且 Python 缺 CJK 扩展 A 区。密度类指标因此允许极小的数值差异，**不要**为此改动字数口径（那是影响界面显示的产品级决定，见 docs/quality-enhancement-log.md 第 31 节）。 |
| `clicheTables` | gateClichePhrases（19 条，短词偏多） | reviewClicheSentences（34 条，长句偏多） | 同质化指标公式与阈值两端一致（distinct 命中 ×1000/字 > 1.2），但词表内容不同：Dart 独有「从这一刻起/命运的车轮/像有什么东西醒」等短词，Python 独有「莫欺少年穷/三十年河东三十年河西/命运的车轮开始转动」等长句。**待产品裁决**：统一成一张表会同时改变两端分数与定点修触发率，必须先用真机成书复验（A/B 分数变化）再落地——2026-10-01 只做收编与记录，不改语义。 |
| `complianceTables` | sensitiveViolence/Sexual/Abuse/Illegal/Ads（5 类 157 词，编辑自查） | redlinePolitics/Religion/MinorRisk/Gore/BrandCelebrity/IllegalDetail（6 类 137 词，番茄平台审核红线） | 两端作用域不同**且几乎不相交**（词级交集仅 17 / 合计 295，2026-10-01 实测），而 fanqie_review 的旧注释称「与 Dart 侧保持同步扩充」——该表述与事实不符，已改为如实描述。**不要合并成一张表**：合并会同时改变平台红线判定、编辑自查命中与 UI 分类展示（分类名是对外可见的），需产品先定「平台红线是否要覆盖色情/脏话、编辑自查是否要含时政/宗教」再动。 |
| `conflictWords` | _conflict（31 词） | CONFLICT_WORDS（40 词） | **同用途**（首屏「有无冲突信号」检查，Dart firstScreenCheck ↔ Python first_screen_check），但 Dart 表是 Python 的真子集，Python 多 9 词（今天必须/不交/递/按在/推到/盯上 等）→ 同一段文字两端可能一处判「首屏无冲突」、另一处判「有」。收编前需真机 A/B 定哪一侧更准。 |
| `driveWords` | _drive（44 词） | DRIVE_WORDS（45 词，多「一个亿」） | **同用途**（水段判定的「该段是否在推进」条件，Dart fillerStats ↔ Python filler_ratio）。Python 多一个「一个亿」→ 该段落一端算推进、另一端算水段，直接影响**水段率与评分**。收编前需真机 A/B。 |
| `aiClicheWords` | aiClicheWords（21 词） | AI_CLICHE（18 词） | 同用途（AI 味密度 aiEchoPct ↔ AI_CLICHE 命中数）。Dart 是 Python 的超集（多 空气凝固/嘴角勾起/眼底闪过）→ 同一章两端 AI 味数值不同、「AI 腔」告警阈值判定不同。收编前需真机 A/B。 |
| `instructionMarks` | _instructionMark（21 词，含「招募」） | INSTRUCTION_MARKERS（25 词，含错别字「招摹」、且「代办」重复两次） | Python 侧的「招摹」是错别字，**永远匹配不到**「招募」；实测 124 份真实成书里「招募」出现 2 次、「招摹」0 次 → Python 在这两处会漏判指令痕迹。是否补「招募」需评估误伤（阻断级判定），故本轮只记录不改。 |
| `narrativeOkCategories` | _narrativeOkCategories（4 个分类键） | NARRATIVE_OK_CATEGORIES（3 个分类键，多「教唆与违法细节」） | 「叙事成立的分类」白名单（例：教唆类词出现在叙述里不算违规）。两侧键集合不同（Dart 有 违法违规/广告引流，Python 有 教唆与违法细节）→ 白名单豁免范围不一致。 |

## 四、改判据的正确流程

1. 只改 `rules/quality_rules.json`（先想清是改词表还是改阈值）；
2. 跑 `python scripts/rules_codegen.py` 重新生成三份产物；
3. 跑 `python -m unittest discover -s scripts -p 'test_*.py'`（含双端对账）与 `flutter test`（含 Dart 侧对账）；
4. 涉及分数的词表变动，按 `docs/human-eval-workflow.md` 用人评样本复核（避免「指标涨了、人评没涨」）。

