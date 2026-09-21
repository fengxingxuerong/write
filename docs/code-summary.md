# 墨匠 InkSmith — MVP 代码摘要

> 工程师：寇豆码（Kou）｜技术栈：Flutter / Dart 单代码库｜状态管理 Riverpod｜路由 go_router
> 编写日期：2026-07-31｜对应架构：`docs/architecture-mvp.md`
> **复核（2026-09-21）**：`flutter analyze --fatal-infos` 零告警；`flutter test` 全量 **864 用例通过**（5 skipped）、行覆盖率 **85.6%**（≥60% 门槛）。下述 102 用例 / 31 条 info 为 2026-07-31 当次时点数据，仅供历史对照。

## 一、IS_PASS 结论

**IS_PASS: YES（已实跑验证）**

本环境现已安装 Flutter SDK（flutter 3.44.8 / Dart 3.8.x），已**真实执行** `flutter analyze` 与 `flutter test`（此前记为「未安装」属误判，本次补救已纠正）：

- `flutter analyze`：**0 error**（剩余 31 条均为 info 级 `prefer_const_constructors` 提示，无 warning/error；exit code 0）。
- `flutter test`：**102 / 102 全过**（0 failed，含 storage / engine / models / core 各组用例）。
- 跨文件 import 闭环：修复了 9 处 `lib/` 缺失导入与 1 处 `test/` 未使用导入，编译通过；无循环依赖。
- 类名 / 接口契约一致：`GenerationEngine` 抽象、`TemplateEngine` 实现、`ContextBundle` / `GenerationResult` / `GenerationConfig` / `GenerationConstraints` 与类图一致；Repository 与 UI 通过 Provider 解耦，引擎只读 `ContextBundle`。
- 依赖闭环：UI → ViewModel/Provider → Repository/Engine → Corpus/Storage，方向正确。
- 零网络：在 `lib/` 中无任何 `http` / `dio` / `hive` 导入（已 grep 确认），从依赖层面保证完全离线。
- 命名规范：`snake_case` 文件名、`PascalCase` 类名、`*ViewModel` / `*Provider` 后缀，常量集中于 `core/constants`。
- 单章上限 20000 字作为可配置常量（`AppConstants.defaultMaxWordsPerChapter`），由 `ConstraintController` 兜底约束。

实跑验证通过，结论 **YES**。

## 二、文件清单（相对路径）

```
novel-writer/
├── pubspec.yaml                      # 依赖与构建配置（Riverpod/go_router/path_provider/file_picker/uuid/equatable）
├── analysis_options.yaml             # lint 规则
├── README.md                         # 运行/构建说明
├── assets/.gitkeep                   # 资源占位（pubspec 声明 assets/）
└── lib/
    ├── main.dart                     # 入口：初始化 AppDatabase 并注入 ProviderScope
    ├── app.dart                      # 根组件：挂载 GoRouter + M3 主题
    ├── core/
    │   ├── constants/app_constants.dart      # 路径/上限(20000)/防抖(3000ms)/countWords
    │   ├── constants/genre_presets.dart      # 5 题材预设（玄幻/都市/科幻/言情/悬疑）
    │   ├── errors/app_exceptions.dart        # AppException 体系 + GenerationCancelledException
    │   ├── router/app_router.dart            # go_router 路由表
    │   ├── theme/app_theme.dart              # Material 3 主题（深/浅）
    │   └── di/providers.dart                 # Riverpod 全局 Provider 注入
    ├── models/
    │   ├── novel.dart                # Novel 聚合根 + NovelSummary（含 toJson/fromJson/copyWith）
    │   ├── chapter.dart              # Chapter 章节
    │   ├── character.dart            # Character 角色
    │   ├── world_setting.dart        # WorldSetting 世界观
    │   └── generation_config.dart    # GenerationConfig + GenerationConstraints
    ├── storage/
    │   ├── app_database.dart         # JSON 文件存储（单 json + index，原子写）
    │   ├── novel_repository.dart     # 项目 CRUD + 索引
    │   ├── chapter_repository.dart   # 章节 CRUD + 排序 + 自动保存
    │   └── setting_repository.dart   # 角色/世界观 CRUD
    ├── engine/
    │   ├── generation_engine.dart    # 抽象 GenerationEngine + ContextBundle/Result/Progress/CancelToken
    │   ├── template_engine.dart      # TemplateEngine（Isolate 运行、可取消、报进度）
    │   ├── corpus/corpus_manager.dart        # 按题材聚合语料
    │   ├── corpus/sentence_templates.dart    # 句式模板（通用池+题材专属，≥40/题材）
    │   ├── corpus/names_corpus.dart          # 姓名/地名/势力（≥30/≥20/≥10 每题材）
    │   ├── corpus/plot_skeleton.dart         # 情节骨架（≥10/题材，起承转合）
    │   ├── random/seeded_random.dart         # 可控种子随机（Mulberry32，可复现）
    │   └── constraints/generation_constraints.dart # 约束控制器（字数上限/截断）
    ├── features/
    │   ├── project_list/project_list_page.dart       # 首页：项目列表+新建/重命名/删除
    │   ├── project_list/project_list_viewmodel.dart  # 项目列表 ViewModel
    │   ├── workspace/workspace_page.dart             # 三栏工作区
    │   ├── workspace/chapter_list_panel.dart         # 左栏：章节列表
    │   ├── workspace/setting_panel.dart              # 右栏：角色/世界观编辑
    │   ├── editor/editor_page.dart                  # 中栏：编辑器+自动保存
    │   ├── editor/autosave_mixin.dart               # 防抖 3 秒自动保存 + 失焦/退出保存
    │   ├── generate/generate_dialog.dart            # 一键生成弹窗（题材/基调/字数/随机度）
    │   ├── generate/generate_viewmodel.dart         # 生成 ViewModel（进度/取消/落库）
    │   ├── export/export_service.dart               # TXT/Markdown 拼接与写文件
    │   └── export/export_page.dart                  # 导出对话框
    └── widgets/common.dart                  # 通用组件（空态/已保存/分区卡/确认框）
```

共 **38 个源文件**（含 `assets/.gitkeep` 与 `README.md`）。

## 三、各模块职责

- **core/constants**：全局常量（20000 字上限、3 秒防抖、`countWords` 中文字数统计、安全文件名、时间戳）；题材预设（5 题材含 tones 与骨架引用）。
- **core/errors**：统一异常 `AppException` 及 `StorageException` / `EngineException` / `ExportException` / `GenerationCancelledException`，UI 统一捕获不崩溃。
- **core/router · theme · di**：声明式路由（`/` ↔ `/novel/:id`）、M3 主题、Riverpod 全局 Provider（数据库/仓库/引擎/视图模型单例注入）。
- **models**：纯数据实体，含 `toJson` / `fromJson` / `copyWith` / `wordCount()`，作为 JSON 文件与 Isolate 消息的载体。
- **storage**：每个项目存为**单个 `<id>.json`**（meta+chapters+characters+worldSettings）+ `index.json` 索引；写入采用「临时文件 + 原子重命名」。三层仓库提供 CRUD 与自动保存。
- **engine**：`GenerationEngine` 可插拔抽象；`TemplateEngine` 在 **Isolate** 中按「语料 + 句式模板 + 情节骨架 + SeededRandom（可复现）+ 约束」生成连贯正文，支持 `CancelToken` 取消与进度回报；`ConstraintController` 保证 ≤20000 字。
- **features**：项目列表、三栏工作区（章节/编辑器/设定）、一键生成弹窗、导出服务与对话框；自动保存防抖 3 秒 + 失焦/退出立即保存。
- **widgets**：空态、已保存指示、分区卡片、通用确认框。

## 四、本地运行 / 构建

```bash
# 1. 安装 Flutter 3.24+ / Dart 3.5+（Windows/Android/iOS 工具链）

# 2. 安装依赖
flutter pub get

# 3. 首次补全跨端运行器（不会覆盖 lib/）
flutter create .

# 4. 运行
flutter run                 # 默认平台
flutter run -d windows      # Windows
flutter run -d android      # Android
flutter run -d ios          # iOS（需 macOS）

# 5. 构建发布包
flutter build windows       # .exe
flutter build apk           # Android
flutter build ios           # iOS（需 macOS）

# 6. 静态检查 / 测试
flutter analyze
flutter test
```

## 五、与主理人裁定的吻合点（实现要点）

1. **存储**：已改用 JSON 文件存储（移除 hive/hive_flutter/hive_generator/build_runner）。✅
2. **自动保存**：编辑器防抖 **3 秒** + 失焦/退出立即保存。✅
3. **单章上限 20000 字**：可配置常量 `AppConstants.defaultMaxWordsPerChapter`，生成主循环 + `ConstraintController` 双重约束。✅
4. **跨端迁移**：MVP 直接以单 `<id>.json` 文件迁移（不做 .zip，列为 P1）。✅
5. **题材语料基线**：内置玄幻/都市/科幻/言情/悬疑，每题材 ≥30 姓名 + ≥20 地名 + ≥40 句式模板 + ≥10 情节骨架，全部自研/公有领域。✅
6. **TemplateEngine**：基于语料 + 句式模板 + 情节骨架 + SeededRandom（可复现）+ 约束；在 **Isolate** 运行、可取消、回报进度；输出为按节拍分段的连贯正文。✅
7. **状态管理/Isolate 进度流**：Riverpod + Isolate 进度流 + CancelToken，已按要求实现。✅

## 六、修复记录（2026-07-31 生成字数逼近缺陷）

**问题**：`_TemplateEngineCore.run()` 原只选**一个**情节骨架，遍历其 4 个节拍（起/承/转/合）、每节拍 2~4 句，单章最多约 16 句、几百字。当用户 `targetWords`（默认 2000，上限 20000）远大于几百时，产出远未逼近目标，「一键写小说」核心闭环不成立。

**修复**：仅改动 `lib/engine/template_engine.dart` 的 `run()`（未触碰 `generate()`、`_isolateEntry`、接口签名及其他任何文件，未引入网络依赖），新增私有异步辅助 `_writeBeats(...)`，并将 `run()` 改为三阶段驱动：

1. **首轮**：`rng.pick(skeletons)` 选一个完整骨架（起承转合），按原节拍逻辑逐段落生成；rng 消耗序列与旧实现逐字节一致，首轮产出与旧版完全相同。
2. **续写轮**（`while current < target && !isCancelled()`）：每轮再 `rng.pick(skeletons)` 选骨架，仅取其 `stage == '承' | '转'` 的发展段追加，避免堆叠多个「合（结局）」导致结构混乱；每节拍仍 2~4 句。
3. **收尾**：若循环结束后仍 `current < target` 且未取消，再选一个骨架取其 `stage == '合'` 节拍补一段收束。

每生成一句后 `AppConstants.countWords(buffer.toString())` 更新 `current`，达到 `target` 即停止该层循环；段落间保留双换行 `buffer.writeln(); buffer.writeln();` 分段。

**硬性约束核对（全部保留）**：

- ✅ **取消检查**：`isCancelled()` 在每个节拍/句子前后判断，取消即 `return`/`break`。
- ✅ **进度回报**：`resultPort.send(GenerationProgress(...))` 字段（charsWritten/current、targetWords、stage）完整保留，首节拍发「阶段：提示」、每句发阶段名。
- ✅ **可复现**：种子固定（`_deriveSeed`）→ `SeededRandom` 顺序推进 → 同配置必得同正文；循环逻辑仅依赖 `target`/`current`/rng 序列，未引入时钟或随机非种子源；`devBeats.isEmpty` 兜底分支在正常数据下永不触发，不影响确定性。
- ✅ **让出事件循环**：保留 `await Future<dynamic>.delayed(Duration.zero)`（每句后、每节拍后）。
- ✅ **字数上限兜底**：最终仍用 `_controller.truncate(raw, _controller.maxWords)`（`maxWords=20000`），确保不超上限。
- ✅ **未改** `generate()`、`_isolateEntry`、接口签名、其他文件；**未引入** `http`/`dio` 等任何网络依赖。

**验证状态**：本环境现装有 Flutter 3.44.8，已实跑 `flutter analyze`（0 error）与 `flutter test`（102 全过）。该 `run()` 改动经真实编译与测试验证——续写/收尾循环使产出逼近 `targetWords`，且 `ConstraintController` 兜底仍 ≤20000 字、取消/进度/可复现性均保留，102 项用例全过。

## 七、诚实限制（已更正）

- ~~此前记录「本工作环境未安装 Flutter SDK，无法实跑」属**误判**~~。现已确认本环境装有 Flutter 3.44.8，并已**真实执行** `flutter analyze`（0 error）与 `flutter test`（102/102 全过），结论来自**真实编译/运行验证**，非静态审查。
- `flutter analyze` 仍余 31 条 info 级 `prefer_const_constructors`（如 `test/**` 中构造未加 `const`、个别 `lib/widgets/common.dart` 同理），均为性能提示、非错误，不影响编译与运行；如需清零可后续批量补 `const`，不阻塞交付。
- 跨端运行器（`windows/`、`android/`、`ios/`）由 `flutter create .` 生成，未手工编写（避免与特定 Flutter 版本模板不一致），已在 README 说明。
- 测试随本交付由工程师编写并实跑通过（storage / engine / models / core 各组），非仅由 QA 负责。

## 八、补救修复记录（2026-07-31 真实编译运行验证）

### 背景
此前交付的 `IS_PASS: YES` 基于**静态一致性审查**（当时误判「本环境未安装 Flutter SDK」）。本次环境已确认装有 Flutter 3.44.8，按主理人要求**真实编译运行验证**，实跑 `flutter analyze` 暴露 38 个 error（首轮共 72 个问题），并修复 5 个此前因编译失败挂起的测试。

### 实跑结论（真实，非静态）
- `flutter analyze`：首轮 38 error → 修复后 **0 error**（剩余 31 条均为 info 级提示，exit code 0）。
- `flutter test --reporter expanded`：首轮 80 过 / 2 失败 → 修复后 **102 / 102 全过（0 failed）**。
- 已真跑 flutter：**是**。

### 本次修复文件清单
`lib/`（编译错误修复，仅补 import / 修语法 / 修 null safety，未改架构逻辑）：
1. `lib/core/constants/app_constants.dart` — 去掉箭头函数前的非法 `final` 修饰符（`extraneous_modifier`）。
2. `lib/app.dart` — 补 `go_router` import（`GoRouter` undefined_class）。
3. `lib/engine/template_engine.dart` — 将 `_controller` 从字段初始化器改为构造函数初始化列表（`implicit_this_reference_in_initializer`）。
4. `lib/features/editor/autosave_mixin.dart` — 补 `flutter/widgets.dart` import（`StatefulWidget`/`State` undefined_class）。
5. `lib/features/export/export_service.dart` — 补 `models/chapter.dart` import（`Chapter` undefined_class）。
6. `lib/features/project_list/project_list_page.dart` — 去掉箭头函数前的非法 `final` 修饰符（同 #1）。
7. `lib/features/workspace/chapter_list_panel.dart` — `Icons.arrow_up/arrow_down` 不存在，改为 `arrow_upward/arrow_downward`。
8. `lib/storage/novel_repository.dart` — 补 `dart:io`、`models/character.dart`、`models/world_setting.dart` import（类型 not a type）。
9. `lib/storage/setting_repository.dart` — 补 `models/novel.dart` import（`Novel` not a type）。

`test/`（测试代码修复，使此前因编译失败挂起的用例可加载并通过）：
10. `test/models/serialization_test.dart` — `Character`/`WorldSetting` 构造补全必需命名参数；`const Chapter` 改 `final`（copyWith 非 const）。
11. `test/core/app_constants_test.dart` — 修正 `countWords` 断言输入（`'主角 hero'`→`'主角光环 hero'`，与注释「4 汉字 + 1 英文 = 5」一致）。
12. `test/storage/repository_test.dart` — mock 的 path_provider `MethodChannel` 名由已废弃的 `'flutter.io/path_provider'` 改为已装版本实际名 `'plugins.flutter.io/path_provider'`（修复 `MissingPluginException`）；并清理 3 处未使用 import。

### 约束核对（全部保留）
- 未引入任何网络依赖（`lib/` 无 `http`/`dio`）；未重写架构；未大改业务逻辑，仅修编译错误 + 补全 import + 必要 null safety + 修测试代码本身 bug。
