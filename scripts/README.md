# 墨匠 · Python 脚本与 AI 流水线说明

本目录存放「墨匠」小说写作项目的 Python 辅助脚本。**密钥一律经环境变量注入，不写入任何文件、不提交 git。**

## 脚本清单

| 脚本 | 用途 |
|---|---|
| `generate_novel.py` | 单模型长篇小说批量生成（多 pass + 断点续传 + 质检 + 导出） |
| `novel_pipeline.py` | **多模型协作流水线**：规划/正文/润色/标题/审校五角色分工生成 |
| `fanqie_review.py` | **番茄过审评审器**（本地零成本）：合规红线 / 首屏 / 对白占比 / 水段率 / 套句 / 主角漂移，输出分数与「定点修」提示 |
| `fanqie_prompts.py` | 番茄向写作准则与 prompt 库（与 `fanqie_review.py` 指标一一对应） |
| `demo_novel_gen.py` | 离线模板引擎演示（纯语料拼接，无 API，用于对比） |
| `watchdog_pipeline.ps1` | 守护脚本：检测 pipeline 进程退出自动续传重启（长任务防中断） |

---

## 环境变量（密钥注入）

| 变量 | 用途 |
|---|---|
| `NOVEL_KEY_AMD` | AMD Radeon 端点（正文写手主力） |
| `NOVEL_KEY_SENSE_K1/K2/K3` | Sensenova（商汤）三个工作区 Key（规划/润色/标题/审校） |

启动前设置（PowerShell 示例）：

```powershell
$env:NOVEL_KEY_AMD = "..."
$env:NOVEL_KEY_SENSE_K1 = "..."
$env:NOVEL_KEY_SENSE_K2 = "..."
$env:NOVEL_KEY_SENSE_K3 = "..."
```

---

## novel_pipeline.py 使用

```bash
# 10 万字全书（断点续传：中断后重跑同一命令自动继续）
python -u novel_pipeline.py --total-words 100000 --max-chapters 40 \
  --output D:\path\novel.jsonl

# 小规模验证（推荐先跑 3000~6000 字）
python -u novel_pipeline.py --total-words 3000 --max-chapters 1 --output test.jsonl

# 守护模式（防崩溃中断，自动拉起续传）
powershell -ExecutionPolicy Bypass -File watchdog_pipeline.ps1
```

输出：`--output` 指定 jsonl 进度文件（大纲 + 章节 + 评审卡 + 日志），完成自动导出同名 `.txt`、`.评估卡.txt`、`.上架包.txt`。

---

## 番茄过审闭环（2026-09-09）

目标：不靠换模型，把「写完就算」改成「写完必须过一把可量化的尺」。

```
写手（fanqie_prompts 准则）
   ↓ 每章
fanqie_review.review_chapter()  ← 对白占比/首屏/四件套/水段/套句/漂移/红线
   ↓ 不达标（默认 <78 分）
fix_prompt() → 编辑器只改问题处 → 重评，分数不升则丢弃
   ↓ 前 3 章额外一轮首屏 300 字强化（降分则丢弃）
全书末尾：.评估卡.txt + .上架包.txt（书名 3 选 1 / 简介 / 标签 / 卖点）
```

新增参数：

| 参数 | 默认 | 作用 |
|---|---|---|
| `--review-pass` | 78 | 单章评审低于此分触发一轮定点修 |
| `--golden-chapters` | 3 | 前 N 章额外做首屏强化 |
| `--no-fanqie-pack` | — | 不生成评估卡与上架包（评审闸门仍生效） |

单独评审已有成书（不调 API）：

```bash
python fanqie_review.py ../data/generated/genre_lishi_v2.txt --genre 历史 --protagonist 顾沉舟
python fanqie_review.py novel.txt --json          # 嗂给脚本或 CI 用

# 加 --outline-json 后额外做「大纲↔正文」一致性检查：
# 大纲 world 专名在正文一个都不命中 = 写手跑题，直接计为硬伤（旧版 14 本里 6 本属此种）
python fanqie_review.py novel.txt --genre 科幻 \
  --protagonist 奚照 --outline-json novel.jsonl
```

口径提醒：词表与阈值是「编辑初审」的代理，不是番茄官方规则；命中不等于被拒。
它的作用是给生成端一把能量化的尺，取代旧的「爽点词命中次数」——那个指标会奖励套路。

> **双端同步**：`fanqie_prompts.py` ↔ `lib/engine/writing_guidelines.dart`（`fanqieGate` 块）、
> `lib/ai_pipeline/prompts/pipeline_prompts.dart`（`writerSystemPrompt`）。
> 改任一处必须同步另一处，并跑 `test/engine/writing_guidelines_test.dart`（里面钉住了
> 「通用技法不得含修仙意象」「非修仙题材拿不到丹田/周天」两条防渗漏断言）。

---

## 角色分配（2026-09-05 全量实测定稿）

| 角色 | 主用 | 备选 | 参数要点 |
|---|---|---|---|
| 规划官（大纲/场景） | AMD `DeepSeek-V4-Flash` | NVIDIA `deepseek-v4-flash-0731` | temp=0.8，max_tokens=4000；正常延迟可达 240s，与 300s 硬超时很贴 |
| 正文写手 | AMD `DeepSeek-V4-Flash` | dsf (K2) | temp=0.8，约 17~20 字/s |
| 去AI味编辑 | Sensenova `kimi-k3` (K2) | AMD 兜底 → 保原文 | temp=1.0；kimi 配额波动大，失败自动降级 |
| 标题官 | dsf (K2) | — | temp=0.8，max_tokens≈300 |
| 一致性审校 | Sensenova `glm-5.2` (K1) | dsf (K2) | temp=1.0，max_tokens≥3000，每 5 章一次 |

Key 负载：K1=glm 低频角色；K2=dsf+kimi 中频；AMD=写手主+编辑兜底；K3 闲置应急。

> **所有 Sensenova 系模型必须传 `chat_template_kwargs.enable_thinking=false`**
> （推理模型默认开思维链，会把 token 吃光导致 content 为空）。

---

## API 实测状态（2026-09-05）

**✅ 可用**：AMD `DeepSeek-V4-Flash`、Sensenova `glm-5.2`(K1/K3)、`deepseek-v4-flash`(K2)、`kimi-k3`(K2)

**❌ 弃用**：
- `sensenova-6.8-flash-lite`：当日全灭（429/空响应）
- `deepseek-v4-pro`：思维链不可控，content 常空
- OpenRouter：账户 402 余额不足；模型 `stealth/ox-alpha` 已更名 `z-ai/glm-5.3-flash`
- NVIDIA：`z-ai/glm-5.2` 已 EOL（410），其余常见模型 404/410

> 商汤平台配额**波动剧烈**（同一组合几小时内 可用→429→恢复 都发生过）。
> 某角色频繁失败时：① 先查该 key 配额状态 ② 检查 glm 系 max_tokens 是否 ≥4000。

---

## 常见问题

| 现象 | 处理 |
|---|---|
| 规划输出为空/JSON 截断 | glm 需 temp=1.0 + max_tokens≥4000；换 dsf(K2) 备选 |
| kimi 429（token plan / RPM） | 自动切 AMD 兜底润色，再失败保原文（不影响成书） |
| 进程无输出 | `Start-Process` 重定向时 Python 全缓冲，用 `python -u` 或看 jsonl 行数 |
| 长任务中途退出 | 断点续传自动恢复；配合 `watchdog_pipeline.ps1` 自动拉起 |
| 章节缺失 | 大纲 33 章实际生成可能跳章，重跑同一命令会自动补缺章 |

---

## 与墨匠应用的关系

`lib/ai_pipeline/`（Dart）是同一流水线的应用内实现，角色分工与参数要点与本文件一致。
端到端冒烟脚本：`tool/pipeline_smoke.dart`（`dart run tool/pipeline_smoke.dart`，需设置上述环境变量）。
