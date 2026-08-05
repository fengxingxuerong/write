# 墨匠 InkSmith —— 完全离线一键小说写作工具

[![CI](https://github.com/inksmith-dev/novel-writer/actions/workflows/ci.yml/badge.svg)](https://github.com/inksmith-dev/novel-writer/actions/workflows/ci.yml) ![Coverage](https://img.shields.io/badge/coverage-65%25-brightgreen) ![Tests](https://img.shields.io/badge/tests-174-blue) ![Dart](https://img.shields.io/badge/dart-3.5%2B-blue) ![Flutter](https://img.shields.io/badge/flutter-3.24%2B-blue)

> 单代码库 Flutter / Dart，核心链路零网络请求、零外部 API。所有生成与存储均在本机完成。
> 支持接入本地大模型（llama.cpp / Ollama）实现 AI 辅助写作，同样完全离线。

## 特性

### 写作体验
- **三栏工作区**：章节列表 / 编辑器 / 角色·世界观·设置面板
- **编辑器**：防抖 3 秒自动保存 + 失焦/退出立即保存；字数实时统计 + **字数目标进度条**；字号（10~28）/ 行距（1.4~2.0）调节
- **写作统计**：当前章节字数 / 段落数 / 句子数 / 今日写作量 / 平均句长
- **章节分割**：按空行块把长章节一键拆分为多章（自动重排顺序）
- **查找替换（Ctrl+F）**：实时匹配计数、↑/↓ 循环跳转、替换当前 / 全部替换；替换后自动触发敏感词复查
- **番茄钟**：25 分钟专注计时，编辑时随时开关
- **敏感词检查**：内置 100+ 词分 5 类词库（暴力血腥/色情低俗/脏话辱骂/违法违规/广告引流），命中列表带上下文展示、分类统计、**历史累计命中 TOP 排行**，支持自定义词增删；保存/替换时自动复查
- **专注模式（F11）**：一键隐藏侧栏沉浸写作
- **快捷键**：`Ctrl+S` 保存 / `Ctrl+B` 切换侧栏 / `Ctrl+E` 聚焦编辑器 / `F11` 专注模式

### 小说管理
- **JSON 文件存储**：每个小说项目单个 `.json` 文件（meta + chapters + characters + worldSettings），跨端拷贝即迁移
- **项目列表**：标题搜索、筛选（全部/进行中/已归档）、卡片显示题材·章数·字数·更新时间；支持**归档/取消归档**（不删数据）
- **角色 / 世界观 / 大纲**：结构化编辑，随章节推进持续维护；**卷纲总览**弹窗汇总全书各章大纲要点，可一键复制为多章连写的卷纲输入
- **阅读模式**：内置阅读器（白/米黄/夜间三主题，字号/行距/衬线可调并持久化）

### 生成引擎（可插拔）
- `GenerationEngine` 抽象接口，两种实现：
  - **模板引擎（TemplateEngine）**：完全离线、零依赖，内置中文网文语料（5 大题材 × 30+ 姓名 / 20+ 地名 / 40+ 句式 / 10+ 情节骨架），Isolate 中运行、可取消、回报进度、种子可控随机
  - **LLM 引擎（LlmEngine）**：接入本地大模型（llama-server / Ollama，OpenAI 兼容协议），支持流式输出、进度回报、8 秒连接超时
- **AI 生成配置**：题材（玄幻/都市/科幻/言情/悬疑）、基调、目标字数、随机度、主角名、大纲驱动
- **多章连写**：一次生成 1~10 章，每章承接上一章结尾（continuation），卷纲按行分配到各章；每章标题由 AI 提炼（超时自动回退）
- **AI 章节标题**：正文生成后并行提炼 8~15 字标题，失败不阻塞
- **AI 记忆**：自动提取新角色与设定并累积，生成时随上下文注入（最多等待 8 秒，超时后台继续）
- **单章上限 20000 字**：生成性能安全线（可配置常量）

### 本地 AI 接入（推荐 Qwen3-2B）
1. 启动本地推理服务（如 llama-server，端口 19110）
2. 墨匠 → AI 生成设置 →「检测本地模型」自动填入 `Qwen3-2B` + `http://127.0.0.1:19110`
3. 保存后即可 AI 生成

> ⚠️ 注意：本地模型走「云端 API」提供商分支 + Base URL 指向本机；llama-server 仅支持 OpenAI 格式 `/v1/chat/completions`；推理模型（如 Qwen3 系列）需关闭思维链（`enable_thinking: false`），否则思维链会吃光 token 导致正文空白。
>
> 🚀 GPU 加速：llama-server 自带 Vulkan 后端，NVIDIA 显卡可加 `--n-gpu-layers 999 --device Vulkan0` 启动，2B 模型生成速度可从 ~10 字/s 提升到 **~140 字/s**（2000 字章节约 15 秒）。

### 导出
- **纯文本（.txt）** / **Markdown（.md）** / **Word（.docx，纯 Dart 手写 OOXML）** / **HTML** / **PDF** 五种格式
- 由 `file_picker` 让用户自选保存路径

## 目录结构

```
lib/
├── main.dart / app.dart            # 入口与根组件
├── core/                           # 路由 / 主题 / DI / 常量 / 异常
│   └── di/providers.dart           # Riverpod 依赖注入（引擎切换、设置、敏感词等）
├── models/                         # Novel / Chapter / Character / WorldSetting / GenerationConfig / LlmConfig
├── storage/                        # AppDatabase(JSON) + Novel/Chapter/Setting 仓库
├── engine/                         # 生成引擎抽象 + TemplateEngine + LlmEngine + 语料 + 可控随机 + 约束
├── services/                       # 敏感词检查 / 搜索服务
├── features/                       # project_list / workspace / editor / generate / export / reader
│   ├── project_list/               # 项目列表（搜索/筛选/归档）
│   ├── generate/                   # 生成对话框 + GenerateViewModel（多章循环 / AI 标题 / AI 记忆）
│   ├── editor/                     # 编辑器（查找替换/番茄钟/敏感词/写作统计/章节分割）
│   ├── export/                     # 导出页 + 五种格式导出 + 封面生成
│   └── workspace/                  # 三栏工作区 + 设置面板 + LLM 设置 + 卷纲总览 / 统计
└── widgets/                        # 通用组件
```

## 本地运行与构建

### 前置

- 安装 [Flutter 3.24+ / Dart 3.5+](https://docs.flutter.dev/get-started/install) 与对应平台工具链（Windows / Android / iOS）。
- 国内镜像（可选）：
  ```bash
  $env:PUB_HOSTED_URL='https://pub.flutter-io.cn'
  $env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'
  ```

### 安装依赖

```bash
flutter pub get
```

### 运行（桌面 / 模拟器 / 真机）

```bash
flutter run            # 默认平台
flutter run -d windows # Windows 桌面
flutter run -d android # Android
flutter run -d ios     # iOS（需 macOS + Xcode）
```

### 跨端平台运行器（首次需要）

本仓库的 `windows/`、`android/`、`ios/` 由 Flutter 工具链生成。若目录下尚不存在这些运行器，请先执行一次：

```bash
flutter create .
```

该命令会按当前 `pubspec.yaml` 补齐全平台运行器与配置，**不会覆盖你已写的 `lib/` 代码**。

### 构建发布包

```bash
# Windows 可执行文件（.exe）
flutter build windows --release

# Android（apk / appbundle）
flutter build apk
flutter build appbundle

# iOS（需 macOS）
flutter build ios
```

### 一键验证（analyze + 测试 + 构建）

```powershell
powershell -ExecutionPolicy Bypass -File verify-novel.ps1            # 三步全跑
powershell -ExecutionPolicy Bypass -File verify-novel.ps1 -SkipBuild # 快速：analyze + 测试
```

> 日志输出到 `verify-logs/`，含 `test-<时间戳>.log` 与 `build-<时间戳>.log`。

### 静态检查与测试

```bash
flutter analyze
flutter test
```

当前测试覆盖：**174 个用例**（模型序列化 / 模板引擎生成质量 / 生成 ViewModel 多章连写 / 引擎抽象 / 存储层归档与数据可靠性 / 敏感词统计 / 编辑器体验 / 导出服务（txt·md·epub·docx·backup）/ AI 记忆链路 / 校对解析 / 阅读设置 / 其他核心逻辑）。

### CI 流水线

仓库已配置 GitHub Actions（`.github/workflows/ci.yml`）：push / PR 到 `main` 自动执行

1. **dart analyze** — 静态检查零告警
2. **flutter test --coverage** — 全量测试 + 覆盖率门槛 **50%**（当前约 65%）
3. **flutter build windows --release** — Windows 发布包构建，产物自动上传

本地等价格令：`powershell -ExecutionPolicy Bypass -File verify-novel.ps1`（三步全跑）。

## 数据存储位置

- 项目数据：各平台 `applicationSupportDirectory/novels/`，每个项目一个 `<id>.json` 文件 + 一个 `index.json` 索引。
- AI 设置：`llm_settings.json`（原子写 tmp+rename，本地地址免 API Key）。
- 阅读设置：`app_settings.json`（主题/字号/行距/衬线）。
- 敏感词：`sensitive_words.json`（自定义词）+ `sensitive_stats.json`（历史命中统计）。
- 跨端迁移：直接拷贝对应的 `<id>.json` 文件到目标设备的 `novels/` 目录即可。

## 架构要点

- **引擎切换**：`generationEngineProvider` 按设置 `useLlm` 切换 `LlmEngine` / `TemplateEngine`。
- **降级路径**：AI 标题失败回退「第 N 章」、AI 记忆超时后台继续、连接超时 8 秒、生成取消保留已生成章节。
- **本地模型接入**：走「云端 API」提供商分支 + Base URL `http://127.0.0.1:19110`（llama-server）或 `http://localhost:11434`（Ollama）。

## 说明

- 本工程为 MVP 基线的持续演进版本；模板生成质量依赖内置语料规模，可继续扩充题材与句式库。
- 测试由 QA 负责，详见各自的单元测试 / 组件测试。
