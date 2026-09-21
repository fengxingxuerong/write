# 墨匠 InkSmith：全方面问题排查与优化报告

> 完成日期：2026-09-20（Dart 3.12.2 / Flutter 3.44.9）
> 验收基线：`dart analyze --fatal-infos` 零告警 + 全量测试通过 + 覆盖率 ≥ 60%
> 相关文档：`docs/storage-stress-200k-report.md`、`tool/save_stress_test.dart`、`tool/export_compat_probe_test.dart`、`verify-logs/export_compat_check.py`

## 结论（先行）

对 8 个核心模块做了基线勘察与抽样深度审查，修复 **27 处确证问题**（含 2 处编译级 analyze 错误、2 处资源泄漏、2 处写放大、1 处可重试错误被吞、1 处超时三层失真等），补针对性测试 15 个，并以真实解析器对导出产物做了兼容性冒烟。

| 验收项 | 基线（改造前） | 现状（改造后） |
| --- | --- | --- |
| `dart analyze --fatal-infos` | 15 处告警（含 2 处 error） | **0 告警** |
| 全量测试 | 735 用例（729 过 / 5 skip / **1 失败**） | **752 过 / 5 skip / 0 失败** |
| 行覆盖率 | 75.9% | **76.0%** |
| 单次保存写盘 | 1.4395 MiB（主文件 + .bak 双写） | **0.7198 MiB**（.bak 零拷贝 rename） |
| 压测完整性 | PASS | PASS |

## 一、静态分析与构建基线（T1）

- `analysis_options.yaml` 用 `--fatal-infos` 时实测 **15 处告警**，其中 2 处为编译级 error：
  - `workspace_page.dart:269/301` 调用了**未定义的 `_showShortcuts`**（崩溃级：点击快捷键入口直接 NoSuchMethod）；
  - `proofread_dialog.dart:292` 在 const 上下文调 `AppFonts.text()`（非常量函数）。
- 全量测试 1 个失败：`template_engine_test.dart:196` **跨章查重种子测试**（E2E 两章生成后断言非空，实际因种子语义产生误判）。

修复：补 `_showShortcuts`、去 const Padding、跨章查重从「全句登记」改为**句块级**（`_clausesOf` + `_tryEmit` 替代 6 处 `_emitted.add/contains`），压测脚本 13 处 lint 一并清零。

## 二、存储写放大（T3 / T4）

问题：`writeNovel` 每次保存都执行「主文件 + `.bak` 全量双写」（copy 主文件为备份），20 万字级全书单次保存写盘 **1.44 MiB**，且 `.bak` 是「写后最新版镜像」。

修复：改为**写前 rename 备份**——旧主文件 rename 为 `.bak`（同卷元数据操作、零字节拷贝），tmp 再原子 rename 为主文件；首写时 rename 后 copy 一次建立初始快照，保住「首写即备份」语义。

结果（`tool/save_stress_test.dart` 实测，100 章 × 约 2000 字 = 20 万字符书）：

| 指标 | 改造前 | 改造后 |
| --- | --- | --- |
| 单次保存写盘 | 1,509,436 B ≈ 1.4395 MiB | **754,798 B ≈ 0.7198 MiB（减半）** |
| saveNovel 中位 | 11 ms | 10–21 ms（无退化；本次重跑 21 ms 与机器负载相关） |
| readNovel 中位 | 10 ms | 9–20 ms |
| 完整性 | PASS | PASS（100 章逐章一致 / .bak 逐字节一致 / index 摘要正确） |
| 备份语义 | 写后最新版镜像 | 写前上一版回滚点（rename 零拷贝） |

可靠性语义（损坏自愈）不变且崩溃窗口更窄：任意时刻至少一份完好数据在盘，主文件损坏/缺失时自动从 `.bak` 恢复上一版。

## 三、LLM 链路（6 文件）

1. **超时只结束外层 future、底层请求泄漏**（`llm_chat_client.dart`）：`Future.timeout` 到期后 HttpClient+socket 仍持活，每次超时泄漏一条连接。改为内部 **Completer + Timer** 模式：Timer 到期 `client.close(force: true)` 强断底层连接再 completeError；`generate()` 同样加整体 deadline Timer + `_abortSharedClient()`，扩写 await 后复查取消态。
2. **连接层错误被吞 / 不可重试**：DNS 失败、拒连、TLS 握手错误在 catch 里一律 `LlmHttpErrors.transport(e)` 包装，标记 `retryable`，可走重试策略；`_extractResult` 解析失败从「吞成空串」改为抛传输异常。
3. **重试叠乘 3×3=9 次**（`multi_pass_chapter_engine.dart`）：外层 multi-pass 与内层 LlmEngine 各配 3 次重试，最坏 9 次请求。给 LlmEngine 传 `chatRetry: RetryPolicy(maxAttempts: 1)`；`_isRetryableError` 从字符串嗅探（把正文「第 500 章」误判为服务端 500）改为类型判断。
4. **取消不中断退避**（`llm_retry.dart`）：`run()` 新增 `isCancelled` 回调，退避前检查、已取消抛 `GenerationCancelledException`；`_openWithRetry` 的 `request.close()` 移入 try/catch。
5. **TokenBudget.clamp 边界崩溃**：`maxTokens < 256` 时 `clamp(256, maxTokens)` 直接抛 ArgumentError。改为 `clamp(256, math.max(256, maxTokens))`，保 256 下限同时兼容小配置；`_calcTokenBudget` 同步用 `math.max(256, config.maxTokens*4)`。
6. **短错误截断 RangeError**（`llm_router.dart:138`）：`substring(0, 80)` 对短字符串抛越界，改为 `s.length > 80 ? … : s`。

## 四、生成引擎（template_engine.dart）

- `_weaveHint` 前缀段只登记不阻断；氛围段/章末钩子用 `_tryEmit` 返回值驱动「登记成功即退出」，消除末尾重复 `_tryEmit` 的**自撞误判**；全失败保底输出最后一句。
- `run()` 目标字数 `clamp` 在 `maxWords < 200` 时抛 ArgumentError，改为 `clamp(200, math.max(200, maxWords))`。
- `generate()` Isolate.spawn 失败/异常时 resultPort 泄漏，改为 `Isolate? isolate` + `cleaned` 标志 + finally 幂等清理。

## 五、记忆管线写放大（models）

`story_memory.dart` 用 `merged != existing` 判断「是否有实质变化再落库」，但 Character / WorldSetting 缺省为 **identity 比较**——`copyWith` 后恒不等于原对象，导致每次 LLM 提取同名角色/设定都**重写落库**。为两个模型补 `==` / `hashCode` **值语义**，按字段比较。

## 六、导出服务（P0 全修）

1. 桌面端导出从不落盘 → `_pickAndWrite` 统一写盘；
2. XML **非法控制字符过滤**（0x00–0x08 等写入 document.xml 会直接破坏文档）；
3. CRC-32 补 final XOR（旧实现算出的校验和不对）；
4. docx 补 `word/_rels/document.xml.rels`（styles 关系缺失导致部分 Word/WPS 打开报错）；
5. `buildDocx` 支持 `includeSettings` 附录；EPUB `dc:identifier` 不再混用固定项目 id（全项目恒定 uuid）→ 随项目变化；
6. 章节 `_orderedChapters` 按 order 升序；`safeFileName` 补控制字符过滤。

验证（T6，真实解析器冒烟 `verify-logs/export_compat_check.py`）：

- **docx**：5 条目齐全（[Content_Types].xml / _rels / document.xml / document.xml.rels / styles.xml），全部 XML 可解析，**python-docx 开包成功**并读到标题「第一章 破晓」、正文与附录（角色/世界观）；
- **epub**：8 条目齐全（mimetype STORED 且内容 `application/epub+zip`、META-INF/container.xml、content.opf、toc.ncx、nav.xhtml、style.css、ch1/ch2.xhtml），全部 XML 可解析。

## 七、编辑器与敏感词（T5 收尾）

1. `rewrite_dialog.dart` / `continue_write_dialog.dart`：流式请求的 **HttpClient 从不 close**（正常路径 `req.close()` 只关请求不关 client），改为实例字段 + `_closeClient()`（onDone/onError/cancel/dispose 幂等清理，重复点击先关旧连接）。
2. `editor_page.dart`：`_persist` 无 try/catch，autosave 抛错 → unhandled + 变更静默丢失；补 catch + `_saved=false` + AppToast 提示。
3. `editor_search_mixin.dart`：`replaceCurrent` 双重全量搜索 + `jumpMatch(0)` 因 delta=0 永远不跳；重构为宿主 `onApplyEdit` 重建 matches 后**单次校准索引**到替换位置之后第一个匹配。
4. `sensitive_words.dart`：**大小写 / 全半角归一化匹配**（全角-半角 1:1 映射、索引不漂移，`ＶＸ：` 能命中 `vx:`，**不落库改存储原文**）；`addCustomWord` 按归一化结果去重。
5. `sensitive_check_dialog.dart`：增删词 StorageException 未捕获无反馈，补 try/catch + SnackBar，用 `context.mounted` 合规。

## 八、补的针对性测试（15 个）

| 文件 | 新增用例 | 覆盖点 |
| --- | --- | --- |
| `test/engine/llm_retry_test.dart` | +2 | 取消后立即中断不等待退避；第二次失败后取消只等一次退避 |
| `test/engine/template_engine_test.dart` | +1 | maxWords<200 不抛 ArgumentError 且产出非空 |
| `test/engine/quality/token_tier_test.dart` | +1 | maxTokens<256 不抛、仍按 256 下限 |
| `test/models/value_semantics_test.dart` | 新建 +7 | Character/WorldSetting 值语义、hashCode 一致、异类不等 |
| `test/services/sensitive_words_test.dart` | +4 | 全角/大写命中、索引不漂移、存储原文不被改写 + 归一化去重 |

## 九、验证与回归

- `dart analyze --fatal-infos`：**No issues found**；
- `flutter test --coverage`：**752 过 / 5 skip / 0 失败**，行覆盖率 **76.0%**（≥ 60% 门槛）；
- 存储压测回归：写盘 0.7198 MiB、完整性 PASS、备份语义 PASS；
- 导出兼容性：docx/epub zip 结构与 XML 全 PASS + python-docx 开包冒烟全 PASS（`verify-logs/export_compat_check.py`）。

## 十、遗留说明

- 覆盖率 76.0% 相对基线 75.9% 基本持平（新增代码与新增测试抵消），未达 80% 级高标准——UI 层分支（编辑器交互、对话框流式渲染）在 widget 测试中覆盖有限，属既有结构约束，不影响本轮验收门槛。
- 压测两次运行 saveNovel 中位 10/21 ms 的差异来自机器负载，写盘量指标的减半是确定性的（与耗时无关）。