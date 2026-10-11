# 变更日志

本项目的所有 notable 变更都记录在此文件。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

> 定位说明：墨匠是 **AI 辅助创作·人工把关** 的写作工具，不是全自动代笔。
> 本日志记录的是**工具能力**的演进，所有机器质量指标**未经与人评对齐**，
> 不代表投稿质量；成稿发表前须由作者完成人工复核与修改。

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
- **测试规模**：Dart ~1261 用例（104 文件），Python 302 用例（22 文件），测试量接近
  生产代码量

### 已知问题（Known Issues）
- 所有机器质量指标**未经与人评对齐**，当前人评标注 0 条（见 `docs/human-eval-workflow.md`）
- 终审卡 / 伏笔打勾 / 结构打回轨迹的可视化在 GUI 侧仍是缺口
- Dart 侧部分大文件（`ai_pipeline_service.dart` 1435 行 / `fanqie_gate_checker.dart` 1119 行）
  待按职责拆分

[1.0.0]: https://github.com/fengxingxuerong/write/releases/tag/v1.0.0
