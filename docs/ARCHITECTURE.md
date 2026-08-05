# 墨匠 InkSmith —— 架构文档

> 面向维护者。说明代码分层、关键抽象、AI 生成链路、数据流与测试策略。

## 1. 分层总览

```
lib/
├── main.dart / app.dart        # 入口、根组件、路由挂载
├── core/                       # 横切关注点
│   ├── di/providers.dart       # Riverpod 依赖注入（全应用单一来源）
│   ├── router/                 # go_router 路由表
│   ├── theme/                  # 主题
│   ├── constants/              # AppConstants（单章字数上限等）
│   └── exceptions/             # AppException 层级（sealed）
├── models/                     # 纯数据模型（不可变 + copyWith + 序列化）
│   ├── novel.dart / chapter.dart / character.dart / world_setting.dart
│   ├── generation_config.dart  # 生成配置（含 chapterCount/volumeOutline）
│   ├── llm_config.dart         # LLM 配置 + LlmSettingsRepository
│   └── reader_settings.dart    # 阅读设置（主题/字号/行距/衬线）+ Repository
├── storage/                    # 持久化
│   ├── app_database.dart       # 单例（私有构造 + init），JSON 文件存储
│   └── *_repository.dart       # Novel/Chapter/Setting 仓库（具体类）
├── engine/                     # 生成引擎（核心抽象）
│   ├── generation_engine.dart  # GenerationEngine 接口 + ContextBundle + CancelToken
│   ├── template_engine.dart    # 模板引擎（Isolate）
│   ├── llm_engine.dart         # LLM 引擎（流式 OpenAI 兼容）
│   ├── llm_chat_client.dart    # 对话客户端（标题/记忆/续写）
│   └── corpora/                # 题材语料（姓名/地名/句式/骨架）
├── services/                   # 业务服务
│   ├── sensitive_words.dart    # 敏感词检查（内置 5 类 100+ 词 + 自定义 + 历史命中统计）
│   └── search_service.dart     # 搜索
├── features/                   # 页面 + 状态管理（按功能聚合）
│   ├── project_list/           # 项目列表（搜索/筛选/归档）
│   ├── workspace/              # 三栏工作区 + 卷纲总览弹窗
│   ├── editor/                 # 编辑器（查找替换/番茄钟/敏感词/写作统计/章节分割）
│   ├── generate/               # 生成对话框 + GenerateViewModel
│   ├── export/                 # 导出（5 格式）+ 封面
│   └── reader/                 # 阅读模式（三主题/字号/行距/衬线）
└── widgets/                    # 通用组件
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

- **`GenerationConfig`**：题材 / 基调 / 目标字数 / 随机度 / 主角名 / 承接上文 / 大纲 / 章节数 / 卷纲 / 约束（敏感词禁入等）
- **`ContextBundle`**：角色列表 / 世界观 / 题材预设 / 情节骨架 / 大纲（多章循环中通过 `copyWith` 替换）
- **`GenerationResult`**：正文 / 实际字数 / 实际使用的配置（引擎可自行 clamp）
- **`CancelToken`**：协作式取消，模板引擎在 Isolate 内检查

### 引擎选择（DI）

```dart
// core/di/providers.dart
final generationEngineProvider = Provider<GenerationEngine>((ref) {
  final settings = ref.watch(llmSettingsProvider);
  return settings.useLlm ? LlmEngine(/* ... */) : const TemplateEngine();
});
```

### 模板引擎（TemplateEngine）

- **Isolate 隔离**：生成在后台 isolate 运行，主 isolate 只收进度，不阻塞 UI
- **种子随机**：`SeededRandom`，同一种子可复现结果（便于测试）
- **约束控制**：`ConstraintController` 按目标字数收敛；超上限（20000 字）clamp
- **句末断句**：到目标字数后在句末断句，避免半句截断

### LLM 引擎（LlmEngine）

- **OpenAI 兼容协议**：`POST /v1/chat/completions`，流式（SSE）读取
- **自动推算 max_tokens**：`目标字数 × 1.5 × 1.15`（中文 1 字 ≈ 1.5 token），封顶配置上限
- **连接超时**：8 秒
- **推理模型适配**：`chat_template_kwargs: { enable_thinking: false }`（Qwen3 系列等必须，否则思维链吃光 token）
- **Bearer 头条件化**：本地地址（localhost/127.0.0.1）免 API Key

## 3. AI 生成链路（GenerateViewModel）

```
generate()
│  1. state 置 generating，stage「第 i/N 章」
│  2. 引擎生成正文（onProgress 实时回报字数/阶段）
│  3. AI 标题（_generateTitle，8 秒超时回退「第 N 章」）
│  4. saveGeneratedChapter(order, title, content) 落库
│  5. 敏感词自查（sensitiveWordsProvider.check）
│  6. AI 记忆（_runMemory，8 秒等待 → 摘要入 memoryNote；超时后台继续）
│  7. continuation = 正文尾部 ≤300 字，供下一章承接
└── 循环 chapterCount 次；中途失败保留已生成章节
```

- **多章**：每章 `config.copyWith(continuation: 上一章结尾)`；卷纲按行拆分、按章节数均分
- **状态机**：`GenerateState` 含 `status / stage / progress / memoryPending / memoryNote / error`
- **取消**：`GenerationCancelledException` → 「已取消生成」，已保存章节保留

## 4. AI 记忆（story_memory）

- 生成后异步提取正文中的**新角色 / 新设定**，合并入全局角色/世界观
- `_parseJson` 容错：容忍代码块包裹 / 脏文本，失败返回空结果不阻塞
- 按名去重合并（`_mergeField`），避免重复角色

## 5. 持久化

- **AppDatabase**：单例（`AppDatabase._` + `static init()`，测试可用 `@visibleForTesting initForTest(path)`），JSON 文件存储
- **文件布局**：`<appSupport>/novels/index.json`（索引，含 archived/wordCount/chapterCount 冗余）+ `<id>.json`（单项目全量数据）
- **原子写**：临时文件 + rename（LLM 设置 / 阅读设置 / 敏感词同样模式）
- **Repository 是具体类**（非接口）：测试中 `implements` 需全量实现或 `noSuchMethod` 兜底；注意必须显式提供 `db` getter
- **归档**：`NovelRepository.setArchived(id, archived)` 同步落盘 + 刷新索引；列表按 `archived` 过滤显示

## 6. 依赖注入（Riverpod 2.6）

- `llmSettingsProvider`：`StateNotifierProvider<LlmSettingsController, LlmSettingsState>`
- `readerSettingsProvider`：阅读设置（同 StateNotifier 模式）
- `sensitiveWordsProvider`（customPath + statsPath）、`appDatabaseProvider` 等同在 `providers.dart`
- 引擎切换由 `generationEngineProvider` 统一出口

## 7. 异常体系

- `AppException` 是 **sealed 抽象类**，具体子类：`EngineException`（含 `GenerationCancelledException`）等
- 生成错误三分支：取消 / AppException（显示 message）/ 裸 catch（「生成出错：$e」）

## 8. 测试策略

```
test/
├── models/          # 序列化 round-trip（含 GenerationConfig / NovelSummary.archived / ReaderSettings）
├── engine/          # TemplateEngine 生成质量、ContextBundle.copyWith
├── storage/         # AppDatabase 原子写、NovelRepository CRUD + setArchived、ChapterRepository.splitChapter
├── services/        # 敏感词（内置/自定义/历史统计持久化）
└── features/        # GenerateViewModel 多章连写（9 用例）、编辑器体验（写作统计/分割）
```

当前共 **139 个用例**。

**ViewModel 测试要点**：
- 用 `ProviderContainer` + `override` 注入真实 provider（`ProviderContainer` 不 implements `Ref`，需包装）
- `LlmSettingsController('.')` 读不到文件 → 默认 `useLlm: false` → 不触发记忆路径
- Fake 引擎可编程 `failAt / cancelledAt` 模拟失败/取消

### 一键验证

```powershell
powershell -ExecutionPolicy Bypass -File verify-novel.ps1   # analyze + test + build
```

## 9. 已知限制与演进方向

- 模板引擎生成质量依赖语料规模（可扩充题材库）
- 无 CI 流水线（`ci.yml` 已备好，推 GitHub 后 `git init` + 提交即可用；当前本地 `verify-novel.ps1` 替代）
- 导出 / 记忆链路的 ViewModel 级测试待补
- 错误处理风格部分仍为裸 catch（`生成出错：$e` 透传技术细节），可统一为 AppException
- 敏感词内置词库按类别可继续扩充；命中统计支持按分类汇总展示
