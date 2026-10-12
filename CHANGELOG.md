# 变更日志

本项目的所有 notable 变更都记录在此文件。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

> 定位说明：墨匠是 **AI 辅助创作·人工把关** 的写作工具，不是全自动代笔。
> 本日志记录的是**工具能力**的演进，所有机器质量指标**未经与人评对齐**，
> 不代表投稿质量；成稿发表前须由作者完成人工复核与修改。

## [未发布] - 2026-10-13

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
- **`quality_gate.dart` 分层不变量注释写清主语**：原文「保持 engine 不反向依赖」
  主语含糊到能被读成整个 `engine/`。复核后确认受约束的是 **`lib/engine/quality/`**
  这一层（该目录确实零 `ai_pipeline` import，全库 import 图无环）；
  而 `engine/generation_engine.dart` 与 `engine/multipass/multi_pass_chapter_engine.dart`
  import `ai_pipeline/services/pipeline_qa.dart` 是**有意设计**（`ChapterPayoff`
  等纯数据契约定义在那里）。仅改注释，未动代码——原先若按字面「重构」反而会破坏
  既有的单向设计。

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
