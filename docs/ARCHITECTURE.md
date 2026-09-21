# 墨匠 InkSmith —— 架构文档

> 面向维护者。说明代码分层、关键抽象、AI 生成链路、数据流与测试策略。
> 本文档与最新代码同步（2026-08-05，含编辑器 mixin 拆分、数据可靠性、写作风格等全部新功能）。

## 1. 分层总览

```
lib/
├── main.dart / app.dart            # 入口、根组件、路由挂载
├── core/                           # 横切关注点
│   ├── di/providers.dart           # Riverpod 依赖注入（全应用单一来源）
│   ├── router/                     # go_router 路由表
│   ├── theme/                      # 主题
│   ├── constants/                  # AppConstants（单章上限/防抖/字数统计）
│   └── errors/                     # AppException 层级（sealed）
├── models/                         # 纯数据模型（不可变 + copyWith + 序列化）
│   ├── novel.dart                  # 聚合根（含 drafts/exportPrefs/preferredStyle/preferredProseStyle）
│   ├── chapter.dart                # 章节（含 outline）
│   ├── chapter_draft.dart          # 存稿箱草稿
│   ├── character.dart               # 角色（含 dialogueStyle 对话风格）
│   ├── world_setting.dart           # 世界观设定
│   ├── generation_config.dart       # 生成配置（含 chapterCount/volumeOutline/expandOutline/writingStyle/proseStyle）
│   ├── llm_config.dart             # LLM 配置 + isLocal/isConfigured
│   ├── export_prefs.dart           # 一键导出配置（lastFormat/includeSettings）
│   └── reader_settings.dart         # 阅读设置（主题/字号/行距/衬线）+ Repository
├── storage/                        # 持久化
│   ├── app_database.dart           # 单例（私有构造 + init），三层可靠性（原子写 + .bak.json 备份 + 读时自愈）
│   └── *_repository.dart           # Novel/Chapter/Setting 仓库（具体类）
├── engine/                         # 生成引擎（核心抽象）
│   ├── generation_engine.dart       # GenerationEngine 接口 + ContextBundle(+plotSummary)
│   ├── template_engine.dart         # 模板引擎（Isolate）
│   ├── llm_engine.dart             # LLM 引擎（流式 OpenAI 兼容 + 大纲扩写）
│   ├── llm_chat_client.dart         # 对话客户端（标题/记忆/续写/校对）
│   ├── editor_ai.dart              # 编辑器 AI（续写/修改/校对 + ProofreadResult 客户端修正）
│   ├── story_memory.dart            # AI 记忆（提取新角色/设定 + 去重合并）
│   └── corpora/                    # 题材语料（姓名/地名/句式/骨架）
├── services/                       # 业务服务
│   ├── sensitive_words.dart         # 敏感词检查（内置 5 类 100+ 词 + 自定义 + hitStats 历史命中）
│   └── search_service.dart          # 搜索
├── features/                       # 页面 + 状态管理（按功能聚合）
│   ├── project_list/               # 项目列表（搜索/筛选/归档）
│   ├── workspace/                  # 三栏工作区 + 卷纲总览/大纲编辑
│   ├── editor/                    # 编辑器（含 mixin 拆分：search/pomodoro/ai + 写作统计/章节分割）
│   │   ├── editor_page.dart        # 编辑器核心（346 行，with AutosaveMixin + 3 mixin）
│   │   ├── editor_search_mixin.dart # 查找替换（状态+操作+搜索条 UI）
│   │   ├── editor_pomodoro_mixin.dart # 番茄钟（计时/启停/标签）
│   │   ├── editor_ai_mixin.dart    # AI 动作（续写/修改/校对/存稿/统计/应用结果）
│   │   ├── autosave_mixin.dart    # 防抖 3 秒自动保存 + 失焦立即 flush
│   │   ├── writing_stats_dialog.dart # 写作统计（字数/段落/句子/今日量/均长）
│   │   ├── split_chapter_dialog.dart # 章节分割确认弹窗
│   │   └── sensitive_check_dialog.dart # 敏感词检查（含历史命中 TOP5）
│   ├── generate/                  # 生成对话框 + GenerateViewModel（多章/预览/偏好持久化）
│   ├── export/                   # 导出（5 格式）+ 封面
│   └── reader/                   # 阅读模式（三主题/字号/行距/衬线）
└── widgets/                      # 通用组件
```

**分层规则**：`features` → `engine`/`services` → `storage` → `models`；`core` 被任意层引用。依赖只允许向下，禁止反向。

## 2. 核心抽象：生成引擎

```dart
abstract class GenerationEngine {
  Future<GenerationResult> generate(
    GenerationConfig config,
    ContextBundle ctx, {
    CancelToken? cancelToken,
    void Function(GenerationProgress)? onProgress,
  });
}
```

- **`GenerationConfig`**：题材 / 基调 / 目标字数 / 随机度 / 主角名 / 承接上文 / 大纲 / 章节数 / 卷纲 / **写作风格（标准/短句/细腻/对话）** / **文风（网文/古龙/金庸/日轻）** / **大纲扩写（expandOutline）** / 约束
- **`ContextBundle`**：角色列表 / 世界观 / 题材预设 / 情节骨架 / 大纲 / **剧情摘要（plotSummary）**（`copyWith({outline, plotSummary})`）
- **`GenerationResult`**：正文 / 实际字数 / 实际使用的配置
- **`CancelToken`**：协作式取消，Isolate 内检查

### 引擎选择（DI）

```dart
final generationEngineProvider = Provider<GenerationEngine>((ref) {
  final settings = ref.watch(llmSettingsProvider);
  return settings.useLlm ? LlmEngine(...) : const TemplateEngine();
});
```

### 模板引擎（TemplateEngine）

- **Isolate 隔离**：生成在后台 isolate 运行，主 isolate 只收进度
- **种子随机**：`SeededRandom`，同一种子可复现结果
- **约束控制**：`ConstraintController` 按目标字数收敛；超上限 clamp
- **句末断句**：到目标字数后在句末断句

### LLM 引擎（LlmEngine）

- **OpenAI 兼容协议**：`POST /v1/chat/completions`，流式（SSE）读取
- **自动推算 max_tokens**：`目标字数 × 1.5 × 1.15`（中文 1 字 ≈ 1.5 token），封顶配置上限
- **连接超时**：8 秒
- **推理模型适配**：`chat_template_kwargs: { enable_thinking: false }`（Qwen3 系列必须）
- **Bearer 头条件化**：本地地址免 API Key
- **大纲扩写**：expandOutline=true 且 outline 非空时，先用 LlmChatClient 把大纲扩写成场景序列（每场景：地点/人物/事件/情绪/字数），正文 prompt 注入扩写结果；8 秒超时回退原大纲
- **剧情摘要**：取最近 2 章取末尾 120 字进 prompt（前情提要）

### 写作风格与文风

| 维度 | 选项 | 效果 |
|---|---|---|
| **写作风格**（段落结构） | 标准 / 精炼短句 / 绵长细腻 / 对话密集 | 控制段落均长、对话占比 |
| **文风**（语言质感） | 网文 / 古龙 / 金庸 / 日轻 | 控制句式、半文白、心理描写比例 |

两者在 `_buildPrompt` 中**正交叠加**，均注入 system prompt。

## 3. AI 生成链路（GenerateViewModel）

```
generate()
│  1. state 置 generating，stage「第 i/N 章」
│  2. 引擎 generate（onProgress 实时 previewText + charsWritten）
│  3. AI 标题（_generateTitle，8 秒超时回退「第 N 章」）
│  4. saveGeneratedChapter 落库
│  5. 敏感词自查（check + recordStats）
│  6. AI 记忆（_runMemory，8 秒等待写 memoryNote；超时后台 unawaited 继续）
│  7. continuation = 正文尾部 ≤300 字，供下一章承接
└── 循环 chapterCount 次；中途失败保留已生成章节
```

- **偏好持久化**：生成成功后回写 `novel.preferredStyle/preferredProseStyle`，下次打开自动填入
- **状态机**：`GenerateState` 含 `status / stage / progress / previewText / memoryPending / memoryNote / error`
- **取消**：`GenerationCancelledException` → 「已取消生成」，已保存章节保留

## 4. AI 辅助（编辑器侧）

编辑器 AI 由 `EditorAi`（`editor_ai.dart`）封装，统一走 `LlmChatClient`：

| 功能 | 入口 | 特点 |
|---|---|---|
| **续写** | 编辑器工具栏「✨」 | 选目标字数（200~1000），流式预览，追加到章节末尾 |
| **修改** | 选中文本后「📝」 | 输入修改意见，流式展示，替换选中区域 |
| **校对** | 工具栏「🔍」 | 返回问题列表（错别字/病句/重复），勾选应用，`applyFixes` 客户端替换 |
| **标题提炼** | 生成弹窗后并行 | 读正文前 600 字，8~15 字，超时回退「第 N 章」 |

**校对客户端修正**：`proofread` 只返回问题数组（省 token），`_applyFixes` 把 `suggestion` replaceFirst 回 `original`（跳过 suggestion==original 的凑数条目）。

## 4.5 AI 长篇小说流水线与多模型路由

`lib/ai_pipeline/` 是应用内「多角色协作」流水线（与 `scripts/novel_pipeline.py` 双端同步）：

- **五角色**：规划官（Planner）/ 正文写手（Writer）/ 去AI味编辑（Editor）/ 标题官（Titler）/ 一致性审校（Verifier）
- **断点续传**：每章生成后原子落盘，中断可从下一章继续
- **幂等导入**：`NovelImporter.importTask` 已导入的任务返回既有 id，不重复建书

### 核心抽象：LlmRouter（多链 failover）

```dart
abstract interface class LlmRouter {
  Future<LlmRouteResult> call(
    List<LlmConfig> chain, {
    required String system,
    required String user,
    double? temperature,
    void Function(String logLine)? onLog,
  });
}
```

- **每个角色可配置主 + 有序备用链**：`AiRoleConfig{ llm, fallbacks: List<LlmConfig> }`，序列化向后兼容（无 fallbacks 的旧配置 chain=只含主）
- **配额感知路由**（对齐 Python `call_chain` + `_HEALTH`）：冷却跳过 → 沿链尝试 → 空/失败切下一个 → 首个非空返回
- **健康池**：以 `provider|baseUrl|model` 为粒度记录连续失败，达阈值进入冷却，命中非空正文自动恢复
- **分层重试**：单端点内重试由 `LlmChatClient`（RetryPolicy 指数退避）承担，跨端点 failover 由 `LlmRouter` 承担
- **`AiPipelineService.missingRoles`** 感知备用链：主或任一备用已配置即视为就绪

### 统一质检网关（QualityGate）

```dart
abstract interface class QualityGate {
  QualityGateReport check(String text, {String prevContent = '', int chapterIndex = 1});
}
```

- **模型**：`QualityGateReport`（score/pass/issues/metrics/summaries，可序列化）+ `QualityGateIssue`（source/type/message/severity 四级），位于 `engine/quality/quality_gate.dart`
- **组合实现**：`CompositeQualityGate`（`ai_pipeline/services/`）——文笔卫生 50% + 过审分 50%，veto 红线上限 60，无钩子/爽点双低各扣 5；商业指标问题与 `PipelineQa.chapterIssues` 同口径
- **分层**：接口与模型在 engine（纯模型），组合实现在 ai_pipeline（依赖 `PipelineQa`），避免 engine 反向依赖上层
- **用途**：UI 统一展示三套质检结果；「全书体检」等后续功能以此为入口

## 5. 敏感词（sensitive_words）

- **内置 5 类 100+ 词**：暴力血腥 / 色情低俗 / 脏话辱骂 / 违法违规 / 广告引流
- **自定义词**：`sensitive_words.json`（用户增删）
- **历史命中统计**：`sensitive_stats.json`（recordStats 每次生成落盘，`_buildStatsSection` 展示 TOP5 高频词）
- **检查时**：`SensitiveWordsService.check(text)` → `SensitiveCheckResult`（无命中 / 分类列表 + 上下文）

## 6. 持久化与数据可靠性

### AppDatabase 三层保障

```dart
writeNovel(novel):
  1. 写 $novelId.json.tmp
  2. rename → $novelId.json        ← 原子操作
  3. rename → $novelId.json.bak.json  ← 备份永远是最新数据
  ← 任何一步失败：删 tmp，重抛异常

readNovel(id):
  try 主文件 → 正常返回
  catch 解析失败:
    try 备份 → 恢复主文件 + 返回
  catch: 重抛 StorageException

readIndex():
  try 主索引 → 正常返回
  catch:
    try 备份 → 恢复 + 返回
  catch: 返回空列表（首页不崩溃）
```

### Repository

- **具体类**（非接口）：测试中 `implements` 需全量实现；注意必须显式提供 `db` getter
- **归档**：`NovelRepository.setArchived(id, archived)` → copyWith + writeNovel + _upsertIndex
- **存稿箱**：`ChapterRepository.addDraft / listDrafts / promoteDraft / deleteDraft`
- **偏好持久化**：`ExportPrefs`（lastFormat / includeSettings）、`preferredStyle / preferredProseStyle`（Novel 字段）

## 7. 编辑器架构（Mixin 拆分）

```
EditorPage（ConsumerStatefulWidget）
  with AutosaveMixin         // 防抖保存，_controller listener → 3s debounce → flush
  with EditorSearchMixin     // 查找替换：_doSearch/_jumpMatch/_replaceCurrent/_replaceAll
  with EditorPomodoroMixin  // 番茄钟：_togglePomodoro / _pomodoroLabel
  with EditorAiMixin         // AI 动作：_continueWrite / _rewriteSelected / _proofread / _saveDraft
```

- mixin 通过**抽象 getter** 访问宿主状态（`editorController / currentNovel / onApplyEdit` 等）
- mixin 的状态字段直接进 mixin，宿主 `with` 后自动获得
- `EditorToolbar` 是纯展示组件，所有交互通过回调上抛

## 8. 性能基准

`countWords`（编辑器每次输入触发）：**37.5× 加速**（20 万字 24ms → 0.64ms）。

| 实现 | 20 万字耗时 | 方式 |
|---|---|---|
| 旧 | 24 ms/次 | 两次全量正则（cjk.allMatches + asciiWord.allMatches） |
| 新 | 0.64 ms/次 | 单次 runes 状态机（CJK 按码点分段计 1，ASCII 连续词计 1） |

## 9. 测试策略

```
test/
├── core/app_constants_test.dart      # countWords（8 用例，含混排边界）
├── models/                            # 序列化 round-trip
│   ├── serialization_test.dart        # Novel（含 drafts/exportPrefs）/ Chapter / Character / ReaderSettings
│   └── generation_constraints_test.dart
├── engine/
│   ├── template_engine_test.dart      # 生成质量/循环/clamp
│   ├── generation_engine_test.dart    # ContextBundle.copyWith
│   ├── story_memory_test.dart         # AI 记忆全链路（本地 HttpServer 假 LLM）
│   └── proofread_test.dart            # ProofreadResult.applyFixes 客户端修正
├── storage/
│   ├── repository_test.dart           # Novel CRUD + setArchived + 存稿箱 CRUD
│   └── reliability_test.dart          # 备份生成/自愈/索引容错（5 用例）
├── services/
│   └── sensitive_words_test.dart      # 内置/自定义/命中统计/hitStats 持久化
└── features/
    ├── generate_viewmodel_test.dart  # 多章/取消/卷纲/previewText/reset（9 用例）
    ├── editor_experience_test.dart    # 写作统计/splitChapter（6 用例）
    └── export_service_test.dart      # txt/md/epub/docx/backup 结构（8 用例）
```

**当前：735 个用例，覆盖率 75.9%**，CI 流水线设 60% 门槛。

### ViewModel 测试要点

- 用 `ProviderContainer` + `override` 注入（`ProviderContainer` 不 implements `Ref`，直接当 `Ref` 用）
- `LlmSettingsController('.')` 读不到文件 → 默认 `useLlm: false` → 不触发记忆路径
- `AppDatabase.initForTest(path)` 避免 path_provider 插件在测试环境缺失

## 10. 依赖注入（Riverpod 2.6）

| Provider | 类型 | 用途 |
|---|---|---|
| `generationEngineProvider` | Provider | 按 useLlm 切换 LlmEngine / TemplateEngine |
| `llmSettingsProvider` | StateNotifier | AI 配置（useLlm / config） |
| `readerSettingsProvider` | StateNotifier | 阅读设置（含持久化） |
| `sensitiveWordsProvider` | Provider | 含 customPath + statsPath |
| `appDatabaseProvider` | Provider | 单例（runApp 前 overrideWithValue） |

## 11. 异常体系

- `AppException` 是 **sealed 抽象类**，具体子类：`EngineException`（含 `GenerationCancelledException`）、`StorageException`、`ExportException`
- 生成错误三分支：取消 → 「已取消生成」；AppException → `e.message`；裸 catch → 「生成出错：$e」

## 12. 已知限制与演进方向

- 模板引擎质量依赖语料规模（可扩充题材库）
- 校对（proofread）目前只返回问题列表，`revised` 全文受 max_tokens 限制——如需全文重写可考虑分段或增大 max_tokens
- 2B 模型生成速度正常，3B+ 或更高精度模型可进一步提升质量（当前配置可无缝切换 Base URL）
- 番茄钟功能为本地计时，关闭应用后不复位（可加持久化）
