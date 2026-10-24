# 变更日志

本项目的所有 notable 变更都记录在此文件。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

> 定位说明：墨匠是 **AI 辅助创作·人工把关** 的写作工具，不是全自动代笔。
> 本日志记录的是**工具能力**的演进，所有机器质量指标**未经与人评对齐**，
> 不代表投稿质量；成稿发表前须由作者完成人工复核与修改。

## [未发布] - 2026-10-24

### 新增（Added）
- **LLM 用量账本**：每次模型调用都解析端点返回的 `usage`（兼容 OpenAI 默认口径、
  Anthropic `input/output_tokens`、顶层拍平与 Ollama `prompt_eval_count`），按
  「角色 / 章节」记入任务账本并随任务落盘，断点续跑不丢；运行页质量面板新增
  「AI 用量」条，显示调用次数、输入/输出 token 与估算成本。**端点未返回 usage
  时显示「未知」而不是 0，也不按字数估算**——未知不等于免费，假账比没账更糟。

### 测试（Tests）
- 新增用量解析多口径（含只有 `total_tokens` 时不制造假拆分）、账本聚合/成本/
  序列化、路由透传、流水线按章记账与面板「未知」显示的行为测试。

## [未发布] - 2026-10-23

### 新增（Added）
- **书架导入 TXT / Markdown 原稿**：新增原稿解析与导入服务——识别
  「第 X 章 / 序章 / 楔子 / 番外」与 Markdown 标题，先预览拆章结果、
  字数、书名、题材与基调，再创建为新作品；源文件只读，现有项目不会被覆盖。
  支持 UTF-8（含 BOM）与 UTF-16 LE/BE（含 BOM；无 BOM 的 ASCII 也会嗅探）；
  Windows 桌面通过系统解码器直接支持 GBK / GB18030 中文 TXT，其他平台或无法
  识别的编码才提示另存为 UTF-8，不会静默解成乱码。解析失败不落半本空书。
- **作品信息编辑**：工作区「工具箱 → 作品信息」可修改书名、题材、基调与
  单章目标字数。此前新建对话框写着「之后都能在工作区里改」，但工作区并没有入口；
  现在题材/基调会随项目落库，并影响后续生成提示词与封面配色。同时修正新书
  单章目标默认值：原先误用生成上限 20000，进度条和统计会把 2 万字当目标，
  现改为 2000（导入原稿则取章均字数，夹在 500–20000 之间），并可在作品信息里改。
- **全书搜索快捷键**：`Ctrl+Shift+F` 直接打开全书搜索（正文/标题/大纲/
  角色/世界观）；编辑器聚焦时 `Ctrl+F` 仍是章内查找替换。新增 `Ctrl+N`
  新增章节，并补进 `Ctrl+/` 键位速查。
- **项目回收站**：删除作品不再直接销毁文件，而是移入 `novels/trash/projects/`，
  保留 30 天、最多 50 份。书架新增「回收站」入口，可逐本恢复、永久删除或
  清空；恢复沿用原作品 ID 并重建书架索引。删除确认文案同步改为「移入回收站」。
- **章节回收站**：删除单章前先把正文/大纲写入 `novels/trash/chapters/<novelId>/`，
  30 天内可从章节栏右上角恢复；恢复时尽量插回原位置并重建索引，每本最多保留
  50 章。写入失败会中止删除，不会出现「删了但找不回」。

### 修复（Fixed）
- **快捷键文档与实现不一致**：README / README_EN 原写「Ctrl+B 切换侧栏 /
  Ctrl+E 聚焦编辑器」，实际代码是「Ctrl+B 一键生成 / Ctrl+E 导出」。
  文档与顶栏提示已按真实绑定统一，避免用户按文档操作却触发另一动作。
- **书架导入入口语义收窄**：原「导入备份」按钮改为「导入」，先选择
  JSON 备份或 TXT/Markdown 原稿，两条路径共用错误提示与忙碌态。

### 测试（Tests）
- 新增原稿解析（章节识别/编码/误判防护）、导入服务（只读源文件/失败不落盘/
  书架索引）、导入预览与作品信息对话框、快捷键绑定与编辑器优先级的用户路径测试；
  Windows GBK/GB18030 解码与导入有独立用例（非 Windows 显式 skip）。
- 新增回收站存储测试（移入/恢复/永久删除/清空/30 天过期/meta 损坏兜底）与
  回收站对话框测试（二次确认、空态、读取失败重试）。
- 新增章节回收站存储与对话框测试（原位恢复、重复恢复拒绝、写入失败中止删除、
  过期清理、窄窗口）。

## [未发布] - 2026-10-13

### 新增（Added）
- **网页关系引导图（`web/relations.html`）**：纯前端零依赖的单文件页面，用于梳理
  **人物关系 / 情节线 / 伏笔**。三类节点（角色 / 情节 / 伏笔，伏笔区分「埋设中 /
  已回收」）与带说明的有向连线；拖动节点、空白平移、滚轮缩放、纯 JS 力导向
  「自动布局」；节点与连线增删改、按类型过滤、选中详情。数据存独立 localStorage
  键 `inksmith.relations.v1`（与工作台作品数据 `inksmith.web.v1` 隔离），
  支持导出 JSON 备份与导出 SVG。工作台（`web/index.html`）头部新增「关系图」
  按钮：新标签页打开并把当前作品的角色、世界观（含伏笔账本）、章节大纲自动
  播种成节点，角色「关系」文本中出现其他角色名的片段自动生成连线；
  「导入」亦支持桌面端项目 JSON（单本或备份数组），按「类型 + 名称」去重合并。
  验证：`node scripts/verify_relations.cjs`（headless Chrome 冒烟：自动播种
  5 节点 / 2 连线、重进去重、手动增删、刷新恢复、类型过滤、自动布局、
  320–1440px 响应式、无运行时异常）。
- **1 万字量级离线长文验证（`tool/write_long_novel.dart` +
  `test/smoke/write_long_novel_test.dart`）**：与三章 demo 同一条链路
  （TemplateEngine + NovelQualityChecker + FanqieGateChecker），但验的是
  **长篇幅下的稳定性**——跨章承接是否漂移、相邻章 8-gram 重复与节奏失衡是否
  随章节数恶化、番茄闸门是否逐章稳定达线。零网络、零 API 费，实测五章 10181
  汉字、逐章达线（文笔 90 / 闸门 96.8 均分）、产物落 `verify-logs/`（已 ignore）。

### 修复（Fixed）
- **`.env.example` 密钥模板实际未入库**：`.gitignore` 的 `.env.*` 把它一并忽略，
  而 README / CHANGELOG / `scripts/test_secret_hygiene.py` 的 `IGNORE_FILES` 白名单
  都声称它入库——新克隆仓库的人拿不到模板。已加 `!.env.example` 否定规则放行
  （放在 `.env.*` 之后，gitignore 后出现者覆盖先出现者），并收窄说明。
- **`scripts/watchdog_pipeline.ps1` 被忽略但文档当交付脚本教用户运行**：
  按 `generate_novel.py` 的同一条判据复核，全文只有 `NOVEL_KEY_*` 环境变量名、
  无任何密钥串，忽略理由不成立。已移出 `.gitignore` 并入库，
  `scripts/README.md` 第 33/74/164 行与 `docs/交付文档.md` 第 25 行的引导随之生效。
- **`run_smoke_gate.py` 冒烟门禁存在恒假断言**：`--total-words` 写死 6000，
  而流水线是「字数达标即停」、近两版质量调整后章均约 4000 字 →
  第 2 章就停下、第 3 章永不产出 → 门禁的「章节数 ≥ 3」**永远不可能过**
  （v8 实测 FAIL 14/17，三条 FAIL 全为此根因）。缺省值改为 `max_chapters × 4000`，
  显式传值时仍以用户给的数为准。
- **世界观守护官单槽位返回空即静默失声**：`main()` 每 5 章的一致性审校原先走
  单点 `llm_call(WORLD_GUARDIAN, ...)`，该槽位在模型下架后返回空 →
  `parse_json_from_llm` 解析失败 → 连告警都不打印。改走 `WORLD_GUARDIAN_CHAIN`
  （链长 2，自动落到备胎），`test_pipeline_surface.py` 同步锁死新符号面。
- **`pubspec.lock` 工作区副本携带国内镜像 URL**：与 CI 注释声明的不变量
  （lockfile 统一指向 pub.dev、本地镜像走 `PUB_HOSTED_URL`）冲突，且版本已漂移。
  已回退到 HEAD 版本（48 处 pub.dev），恢复 CI 可复现性。
- **文档数字与代码脱节**：Python 302 用例（22 文件）→ 440 用例（32 文件）；
  `fanqie_gate_checker.dart` 1119 → 926 行、`ai_pipeline_service.dart` 1435 → 1461 行；
  `docs/交付文档.md` 的 `unittest discover 65 例` → 440 例。

### 变更（Changed）
- **界面「纸墨」体系精致化（第一轮·全局）**：在既有设计语言上做统一提升，
  **不改任何功能逻辑与既有 UI 契约**（`ui_kit_test` / `app_tokens_test` /
  书架 golden 版式体检全绿，全量 1282 用例零回归）。
  - **令牌**（`lib/core/theme/app_tokens.dart`）：补 `s5=20` 栅格档、`emphasized`
    强调曲线、`focusRing` 规格；`AppInk` 新增 `borderStrong`（描边正式分三档：
    `divider` → `border` → `borderStrong`）与 `skeleton`；深色模式提亮
    `surface/surfaceRaised/border/borderStrong`——原先卡面与纸底几乎糊在一起，
    描边层次立不住（`surface` 与 `paper` 对比度仍 ≥1.03，`paper` 亮度仍 <0.02）。
  - **主题**（`lib/core/theme/app_theme.dart`）：按钮叠加色由「三态共用一个」改为
    hover / pressed / focus 分别解析——桌面端鼠标与键盘是两套输入，旧实现键盘
    Tab 走到哪都看不出焦点；补齐菜单 / 下拉 / 徽标 / 折叠面板 / 导航栏主题；
    对话框在浅色下加一档层次阴影（深色仍纯描边，与「纸墨不靠重投影」一致）。
  - **组件**（`lib/widgets/app_card.dart`）：`Hoverable` 新增 `onHoverChanged`
    回调（父级据此改描边 / 底色）；`AppCard` 改为可感知悬浮，hover 时描边提亮一档，
    比单纯上浮更容易被看见。
  - **页面**：作品卡封面改三停渐变 + 书名排版（原两停渐变偏「平」，像占位图）；
    新建卡换圆底图标 + 副文案；书架网格 16→20 且卡片 200→212；排序控件补描边容器，
    看起来是控件而不是一行文字；    设置面板统计卡从原生 `Card` + 默认主题收编进
    `AppCard` + 令牌，数字统一等宽。
- **界面「纸墨」体系精致化（第二轮·工具栏 / 弹窗 / 加载态）**：继续按
  「组件 → 页面」推进，仍不动功能与既有 UI 契约（全量 1283 用例零回归）。
  - **编辑器工具栏**（`lib/features/editor/editor_toolbar.dart` +
    `lib/widgets/page_shell.dart`）：`ToolButton` 新增 `solid` 实心淡底，把
    「AI 续写」这个第一动作从一排图标里拎出来；**只加底色与描边、不加宽**——
    工具栏在窄视口会横向滚动，加宽会把后面的按钮挤出视口（会被测试的
    `tester.tap` 直接抓住）。
  - **左栏章节列表**：行内边距 6→8 更舒展，选中态左侧色条 2→3px 更明确。
  - **右栏设置面板**：角色 / 世界观空态从「一行灰字」改为弱色图标 + 说明行，
    统一走新增的 `_emptyHint`。
  - **弹窗统一**：删掉 3 处硬编码 `insetPadding`（续写 / 修改 / 校对）交由
    `dialogTheme` 统一；4 处 `contentPadding` 魔法数（`24/16/24/0`、`24/20/32/8`）
    换成 token；编辑器对话框内边距 `s4 + 4` → `s5`。
  - **加载态（新增骨架屏）**：新增 `lib/widgets/app_skeleton.dart`
    （`Skeleton` / `SkeletonList` / `SkeletonParagraph`）。类设计上刻意
    **默认不动画**——无限 `repeat` 动画会让 `pumpAndSettle()` 永不返回，而本项目
    widget 测试大量用它收尾；需要呼吸感时显式传 `animate: true`。「打开项目」与
    「书架冷启动」两处转圈换成骨架，加载时就能看到结构。
- **界面「纸墨」体系精致化（第三轮·阅读器 / AI 流水线 / 骨架铺开）**：全量 1283
  用例零回归。
  - **阅读器**（`lib/features/reader/reader_page.dart`）：正文**限宽居中**
    （`maxWidthReading`）——原先桌面窗口拉到 2000px+ 时一行 60+ 字，眼睛回下一行
    找不到起点，这是阅读器最要命的一处；章名与正文之间加一条短横线分层；底部导航加
    **阅读进度条**；空态由一行灰字改为图标 + 说明。
  - **AI 流水线首页**（`lib/features/ai_pipeline/ai_pipeline_pages.dart`）：任务卡从
    原生 `Card` + `ListTile` + 自制状态胶囊，改为 `AppCard`（左侧状态色条）+
    `TintBadge`（与全应用状态色口径一致）；空态改用 `EmptyState`（保留
    「还没有生成任务」文案，有测试依赖它）；加载态改骨架；列表在宽屏下夹到面板宽度。
  - **编辑器加载态**：转圈 → 正文骨架，与「纸面」布局同宽同构，加载完成不跳版。
  - **修一处既有隐患**：`AppCard` 的 `accent` 色条原先用
    `CrossAxisAlignment.stretch`，在高度无界的父级（典型是 `ListView` 的 item）
    会抛 `BoxConstraints forces an infinite height`——本次在 AI 首页用 accent 才踩到；
    补 `IntrinsicHeight` 先把行高确定下来，色条才能真正通高。
- **界面「纸墨」体系精致化（第四轮·深色 / 键盘 / 动效 / 视觉回归）**：全量 1287
  用例零回归，另新增阅读器 golden 回归（三主题）。
  - **深色模式专项**：角色头像圆点原先写死白字，而深色模式的语义色偏亮
    （`primary` 是 `#7FB7B2`）→ 白字直接糊在底上；改为按底色亮度选前景。
    全书体检弹窗的底部分隔线原先写死「黑色 10%」，深色模式下等于没有 → 改走
    `ink.divider`。
  - **键盘可达性**：`Hoverable`（所有可点卡片 / 列表行 / 工具按钮的底座）原先
    「鼠标能点、键盘 Tab 走不到」，补 `Focus` + 焦点环；焦点环用 `spreadRadius`
    画在外圈而**不用 border**（border 会让内容缩 2px），Enter/Space 可触发。
    新增测试钉住「Tab 可达 + 回车可触发」。
  - **动效统一**：5 处魔法时长 / 曲线（250 / 260 / 200ms、`Curves.easeOut` 等）
    收敛到 `AppTokens.normal` / `AppTokens.curve` / `AppTokens.emphasized`。
  - **视觉回归补全**：新增 `test/golden/reader_golden_test.dart`——阅读器三主题
    （白 / 米黄 / 夜间）各有版式体检 + 本地截图基线，并把「正文限宽」钉成断言。
- **界面「纸墨」体系精致化（第五轮·回归扩容 / 打包验证）**：全量 1291 用例零回归。
  - **工具栏 golden**：新增 `test/golden/editor_toolbar_golden_test.dart`——亮 / 暗 ×
    宽 / 窄视口，把全应用**元素密度最高**的一条纳入回归。这一条是横向滚动的，
    「随手加个东西把后面的按钮挤出视口」这类事故只有溢出断言 + 截图能抓到。
  - **打包验证**：`flutter build windows --release` 通过（63.8s），产物 32MB；
    启动冒烟（起 6 秒确认不崩、再按精确 PID 收掉）通过——四轮 UI 改动在真实
    Windows 产物上无问题。
- **`quality_gate.dart` 分层不变量注释写清主语**：原文「保持 engine 不反向依赖」
  主语含糊到能被读成整个 `engine/`。复核后确认受约束的是 **`lib/engine/quality/`**
  这一层（该目录确实零 `ai_pipeline` import，全库 import 图无环）；
  而 `engine/generation_engine.dart` 与 `engine/multipass/multi_pass_chapter_engine.dart`
  import `ai_pipeline/services/pipeline_qa.dart` 是**有意设计**（`ChapterPayoff`
  等纯数据契约定义在那里）。仅改注释，未动代码——原先若按字面「重构」反而会破坏
  既有的单向设计。
- **CI 浏览器回归从 3 套扩到 4 套**：`scripts/verify_relations.cjs` 纳入
  `verify-web` 任务的 Browser regression 步骤（原只跑 `verify_web` /
  `verify_ai_failure` / `verify_web_ai`），关系引导图自此有 CI 门禁。
- **更正一处文档失实**：`test/smoke/write_long_novel_test.dart` 原注释称
  「本测试不进 CI 默认路径」，但该文件位于 `test/` 下，而 CI 的
  `flutter test --coverage` 会递归收 `test/` 全部 `*_test.dart`——实测
  `verify-logs/desktop-coverage.log` 里确实跑过 `test/smoke/write_demo_novel_test.dart`
  可证。已改为如实说明（该步骤同时也是 1 万字写作能力的 CI 门禁），
  并在 `ci.yml` 对应步骤写明两条命令的关系，避免后续有人误删显式步骤或
  误判覆盖率任务的耗时来源。

## [1.0.0] - 2026-10-11

首个正式版本号对齐发布。功能基线自 2026-08-05 首提交「1.0 全功能版」起，
历经 150+ 次提交持续演进至此。此前 `pubspec.yaml` 版本号停留在 `0.1.0+1`，
与项目实际成熟度不符，本次对齐至 1.0.0。

### 新增（Added）
- **三栏工作区**：章节列表 / 编辑器 / 角色·世界观·设置面板
- **文风参考（学分布，不抄句子）**：导入参考文提取九项文风指纹（句长、对白占比、
  段落均长、「的」字密度、叠词、句首连接词、比喻密度等），注入写手提示词让句长与
  段落呼吸向参考文靠拢；只存分布数值不留原文，附禁抄规则；样本不足 500 字不采用
- **外显爽点闭环**：每章至少一处读者可感知的外显兑现（打脸/收获/揭露/当众反应）；
  跨章连续多章无外显兑现判定为**爽点断供**并告警；章末自动补修一轮
- **可插拔生成引擎**：`GenerationEngine` 抽象接口，模板引擎（完全离线、种子可控随机）
  与 LLM 引擎（本地 llama.cpp / Ollama，OpenAI 兼容协议）两种实现
- **12 角色多模型协作流水线**（Python 侧 `novel_pipeline.py`）：规划官 / 写手 / 编辑 /
  标题 / 世界观守护 / 爽点总监 / 伏笔 / 读者官 / 终审官等角色链，含有序备用链与
  健康池冷却降级
- **五大导出格式**：纯文本 / Markdown / EPUB（纯 Dart 手写 zip）/ Word（纯 Dart 手写
  OOXML）/ JSON 备份
- **本地规则质检门禁**：判据单一数据源 `rules/quality_rules.json`，经 `rules_codegen.py`
  生成 Dart 常量 / Python 常量 / 人读总表三份产物，CI 强制校验一致性
- **AI 辅助**：编辑器内续写 / 修改 / 校对，均注入角色对话风格
- **存稿箱、专注模式（F11）、番茄钟、查找替换、全书检索**
- **敏感词检查**：100+ 词分 5 类词库，命中带上下文与累计排行，保存/替换自动复查

### 安全与合规（Security）
- **本地优先、默认离线**：默认零外部 API；用户主动启用云端 LLM / 崩溃日志上报 /
  网页端 AI 请求时才联网
- **密钥不落明文**：API Key 经 Windows DPAPI 加密存储（`secret_store.dart`）；
  `.env.local` 真值不入库（.gitignore 忽略），仅 `.env.example` 模板入库
  （`.gitignore` 用 `!.env.example` 否定规则放行——否则 `.env.*` 会把模板一并盖掉，
  新克隆仓库就拿不到模板）
- **CI 密钥卫生扫描**：扫描已入库文件的高熵密钥，防误提交

### 工程化（DevEx）
- **CI 流水线**（`.github/workflows/ci.yml`）：analyze（`--fatal-infos`）→ Python 门禁
  （compileall / ruff F 类 / rules_codegen --check / unittest）→ 测试 + 80% 覆盖率门槛 →
  Web 浏览器回归 → Windows 打包上传
- **防假绿测试**：`test_fake_green_guard.py` / `audit_test_effectiveness.py` /
  `verify_new_guards_can_fail.py` 确保测试真能失败；负样本对照（注水稿必须跌破能力线）
- **双端判据对账**：Dart 与 Python 质检阈值/词表同口径，`test_quality_single_source.py`
  防两端漂移
- **Python 静态检查配置**（`pyproject.toml`）：钉住 `line-length=120` /
  `target-version=py310`；lint.select = F（运行时 bug）/ I（导入排序）/ W（末尾换行），
  增量开启、逐类修债
- **测试规模**：Dart ~1238 用例（104 文件），Python 440 用例（32 文件），测试量接近
  生产代码量

### 已知问题（Known Issues）
- 所有机器质量指标**未经与人评对齐**，当前人评标注 0 条（见 `docs/human-eval-workflow.md`）
- 终审卡 / 伏笔打勾 / 结构打回轨迹的可视化在 GUI 侧仍是缺口
- Dart 侧部分大文件（`ai_pipeline_service.dart` 1461 行 / `fanqie_gate_checker.dart` 926 行）
  待按职责拆分

[1.0.0]: https://github.com/fengxingxuerong/write/releases/tag/v1.0.0
