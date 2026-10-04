> 📦 归档件，原文第 22~25 节：2026-09-28 商业爽点闭环与文风指纹 P1-1。
> 只读参考，**不要照此改代码**；当前实态见 [`docs/README.md`](../../README.md) 索引的现行文档。

## 二十二、2026-09-28 商业爽点闭环二轮：压抑释放结构（爽点落点） + 上轮两处「指标静默失效」修复

> 上一轮 `12e7ffa`（三视角震惊环 + 侧面反响密度检测，未记日志）之后，本轮先按「真实成书回测」方法论选题，再补记上轮内容与其引入的两处残留缺陷。

### 选题证据（先确认问题在哪一层）

`tool/probe_quality_gaps.py` 扫 `data/generated/` 真实成书 14 本 156 章（≥800 字）量化各候选短板：

| 候选 | 实测 | 结论 |
|---|---|---|
| 跨章句子复读 | 0~0.76%/本 | 已被相邻段重复率等防线压住，非当前短板 |
| `仿佛/似乎/宛如` 超限（≤2/章） | 156 章仅 2 章 | 规则已基本被遵守 |
| 「不是…而是…」超限（≤1/章） | 0 章 | 同上 |
| **先抑后扬/压抑释放（爽点落点）** | **有指令、无检测** | ✅ 本轮选题 |

「爽点落点」是全文唯一「有指令无检测」的商业结构规则：`fanqie_prompts` 规则 27「爽点放在章内后半段：先压后扬，压抑蓄水不超过全章 60%，后半段瞬间打脸释放」、`scene_planning_prompt`「爽点场景放后半段」、`writing_guidelines` 全都承诺了，双端却没有任何指标核对——上轮 commit 标题里的「压抑释放张力」只改了评审 prompt 措辞，没有落地为检测器。

### 先修上轮残留缺陷两处（12e7ffa 引入，本轮发现）

1. **`composite_quality_gate.dart` 侧面反响 note 是永不可达的死代码**：该检查被插进 `else if (thrill < 0.5)` 块**内部**，而条件要求 `thrill >= 0.5` → 恒假；上轮新增断言只查 `metrics` 含 `sideReactionPerK` key、没查 issue 触发，CI 照常绿——正是本项目一直在猎杀的「指标静默失效」形态。修复：移出为与 if/else-if 平级的兄弟分支，补**可达性回归测试**（thrill≥0.5 且侧面反响 <0.3/千字必须出 note，且落点告警不出）。
2. **`scripts/test_generate_quality.py` 测试体被截走**：`class SideReactionMetricTest` 插在 `test_chunked_repair_reassembles_only_after_all_chunks_succeed` 方法体**中间**，后半段（`failed_calls` 两行断言）沦为类级永不执行代码——「分块修复失败即整章弃修」的保护断言**静默丢失**（发现器只跑 `test_*`，套件照常 OK）。修复：恢复为独立方法 `test_chunked_repair_aborts_when_one_chunk_fails`，方法体注记回归缘由防再犯。

### 新能力：压抑释放结构（爽点落点）双端检测

**指标**：`generate_novel.release_profile(text)` ↔ `PipelineQa.releaseProfile(text)`（双端同文、阈值同源）

- 只用基础 `THRILL_WORDS` 判落点（题材加成词仅 Python 侧存在，用了会破坏双端同口径）；
- 命中 n≥2 才有结构可言：`none`（0 命中）/ `single`（1 命中，单点无结构，密度指标负责）；
- `late_start`（压抑过长）= 首个爽点 > 全章 60%；`front_loaded`（前置泄洪）= 末个爽点 < 50%、后半段零释放；否则 `ok`。

**阈值校准**（`tool/probe_release_profile.py` 可复跑复现）：真实成书 157 章 → 适用章 61（39%），`ok` 51 / `late_start` 7（11%）/ `front_loaded` 3（5%）——信号存在且不构成大规模误报；按句式指纹（STYLE_FP）同定位为 **note 级「标记供人工复核」，不扣分、不阻断、不进冒烟门禁 FAIL 口径**。

**接线（检测 → 证据 → 评审 → 展示）**：

| 端 | 位置 | 内容 |
|---|---|---|
| Py | `generate_novel.release_ev_fragment` | 评审证据串，异常档带「rhythm 维度不应高于 60 分」（与钩子证据同风格） |
| Py | `novel_pipeline` qa_ev | 五维评审证据扩为 钩子/爽点密度/变强异动/侧面反响/**爽点落点** |
| Py | `quality_check` | 落 `_release` + report 行 `release` 字段；生成收尾逐章落点告警 |
| Py | `qa_scan_existing` | 逐章 `release` 字段（`--json` 含）+ 异常 ↳ 明细行 |
| Dart | `PipelineQa.releaseEvFragment` | 与 Python **同文**的证据串，接 `ai_pipeline_service` qaEv（评审双端同证据） |
| Dart | `PipelineQa.chapterIssues` / `chapterReport` | 落点告警 + `release` 摘要键 |
| Dart | `CompositeQualityGate` | `type=落点` note（与死代码修复同一块） |
| Dart | `BookQaService` | extraIssues 落点告警——全书体检 GUI 直接可见，零模型改动 |

**写手/规划侧数值对齐**（检测阈值与指令同源）：`writing_guidelines.webNovelStructure` 明示「首个爽点不晚于全章 60% 处、末个必须落在 50% 之后」；`scene_planning_prompt` 同步 60%/50% 数值；`fanqie_prompts` 规则 27 原本就有——本轮是**给既有承诺补上检测器**，不是新增套路。

### 验证

- `python -m unittest discover -s scripts -p "test_*.py"` → **Ran 75 tests OK**（67→75：落点 7 项含 quality_check 落字段与证据串四档 + 恢复分块中断 1 项）
- `ruff check --select=F,E9 scripts tool` 全绿；`compileall` 0；`python -m scripts.generate_novel --help` 等模块入口回归（CI 同款）
- 真书复测：`release_profile` 全量 157 章 verdict 分布与校准探针一致（适用 61 = ok 51 / late 7 / front 3）
- `python scripts/qa_scan_existing.py data/generated/smoke_gate_v7.txt` 干跑正常：v7 四章落点均非异常、报告结构与列宽不变
- **Dart 侧未验证项**：本机无 Flutter/Dart SDK，`pipeline_qa` / `composite_quality_gate` / `book_qa_service` / `ai_pipeline_service` 改动与 3 个测试文件（pipeline_qa_test +8、composite_quality_gate_test +2、book_qa_service_test +1）只经人工审读，须由 CI `dart analyze --fatal-infos` + `flutter test --coverage` 复核
- **观察项**：落点告警只提示、无自动定点修（移动爽点风险高于收益，先观察告警质量）；冒烟门禁不加第 18 项——note 级口径未经真机门禁验证前不进 FAIL 判据

---

## 二十三、2026-09-28 章末三件套收尾检测 + 钩子检测矛盾修正（规则 20 落地）

### 选题证据（有指令无检测 + 检测互相矛盾）

- **规则层全端承诺、检测层空白**：FANQIE 规则 20「禁止『三件套』收尾：发烫、亮起、苏醒（含『像有什么东西醒了』）」、规则 10「钩子禁止自行改成身体异动/发光物件」、`scene_prompt`/Dart `scenePrompt` 末场景「禁止用发热/发光/苏醒类身体异动收束」、`writing_guidelines` 第 8 条——四层提示词全都有，没有任何检测器核对。
- **检测矛盾实锤**（`tool/probe_ending_triad.py`，真实成书 116 章）：`has_ending_hook` 把「发烫」「醒了过来」当钩子词 → 末 200 字命中三件套的 **30 章里 93% 反被判「有钩」**。历史事故「实测 52% 章节落在发光物件+苏醒一种钩子上」（HOOK_TYPES 轮换的立项依据）正是它纵容的形态——当年用提示词侧轮换压制，检测侧一直没补。
- **窗口 × 词表校准**：

| 窗口 | core 词表 | core+亮了 |
|---|---|---|
| 末句 | 5 章（4.3%） | 8 章（6.9%） |
| **末 60 字（采用）** | 9 章（7.8%） | **13 章（11.2%）** |
| 末 200 字 | 22 章（19.0%） | 30 章（25.9%） |

取**末 60 字**收束窗口：200 字会把「尾部另有真钩、三件套只在中段」的章误伤；末句太窄（漏跨句收束）。`亮了` 收录但带**天字排除**（实测末句「天亮了」= 0 章，`玉符亮了`类才是发光物件）。钩子降级对拍（旧语义任一钩词即有钩 → 新语义全三件套词无问号悬念即无钩）：116 章语料仅 **1 章**翻转，157 章全语料（含短章）3 章——降级半径极小、方向正确。

### 改动（检测 → 评审 → 修复回路，全部复用既有机制）

| 端 | 位置 | 内容 |
|---|---|---|
| Py | `fanqie_review` | `TRIAD_END_WORDS`（长词优先 + 亮字族天字逐位置排除）/ `TRIAD_HOOK_ONLY` / `TRIAD_END_WINDOW=60` / `ending_triad()` / `ending_ev_fragment()` |
| Py | `fanqie_review.review_chapter` | 新增「收尾」**修改级**问题（-4 分，`fix_prompt` 收「修改」级 → **自动进定点修链路**） |
| Py | `generate_novel.has_ending_hook` | 降级：存在任一**非三件套**尾钩词才算钩；全是三件套词且无 ？/… → 无钩 |
| Py | `quality_check` | 落 `_ending_triad` + report 行字段；生成收尾逐章告警 |
| Py | `novel_pipeline` | qa_ev 追加 `ending_ev_fragment`（评审证据第六项：钩子/爽点/异动/侧面反响/落点/收尾）；Phase 3 汇总打印 |
| Py | `qa_scan_existing` | 逐章 `ending_triad` 字段（`--json` 含）+ 异常 ↳ 明细 |
| Dart | `PipelineQa` | `_triadEndWords` / `_triadHookOnly` / `endingTriad()` / `endingEvFragment()`（与 Python 同文）/ `hasEndingHook` 同款降级 / chapterIssues 告警 / chapterReport `endingTriad` 键 |
| Dart | `CompositeQualityGate` | `type=收尾` **warn** 级（与钩子 warn 并列） |
| Dart | `BookQaService` | extraIssues 三件套告警（全书体检 GUI） |
| Dart | `ai_pipeline_service` | qaEv 追加 `endingEvFragment` |

**零新增 LLM 调用点亮三条既有修复回路**（降级判无钩自动触发）：① Python `apply_hook_patch` 章末钩子兜底补写（2 处调用）② `review_chapter(has_hook=False)` 重写级问题 + `fix_prompt` 定点修 ③ Dart「章末缺钩，自动补写钩子」。

**写手侧零改动**：四层提示词承诺本就存在——本轮仍是「给既有承诺补检测器」。

### 验证

- `python -m unittest discover -s scripts -p "test_*.py"` → **Ran 92 tests OK**（75→92：`test_ending_triad.py` 17 项——窗口/天亮排除/长词优先/降级四态/证据串/评审收尾问题/fix_prompt 透传/quality_check 落字段）
- `ruff check --select=F,E9 scripts tool` 全绿；`compileall` 0；`generate_novel/novel_pipeline/fanqie_review` 模块入口回归（CI 同款）
- 真书生产口径复测：157 章 → `ending_triad` 命中 **16 章（10.2%）**，其中仅 **1 章**因降级判无钩（其余 15 章尾部另有真实钩子信号，钩子判定不动）——与校准探针一致
- `qa_scan_existing` v7 干跑正常、报告结构不变；探针改名 `tool/probe_ending_triad.py`（比喻复用候选本轮放弃：长度≥6 归一化全等仅 5 处/全语料，信号太弱）
- **冒烟门禁零影响（导入面证明 + 实测对拍）**：`run_smoke_gate` 只 import `blocking_reasons/genre_drift/intra_repeat/meta_talk/prompt_leak/_sidecar_path`（均未改动），不触钩子/评审函数；v7 `--check-only` 改动前后同为 FAIL 14/16（与文档 13/16 的差异系历史 live 与 replay 口径差，非本轮引入）
- **Dart 侧未验证项**：4 个 lib 文件 + 3 个测试文件（pipeline_qa_test +8 断言组、composite +1、book_qa +1）本机无 SDK 只经人工审读，须 CI `dart analyze --fatal-infos` + `flutter test` 复核
- **观察项**：`收尾` 在门禁为 warn 级、不进 FAIL 判据（与落点同口径，待真机门禁观察）

---

## 二十四、2026-09-28 规则-检测覆盖矩阵清扫 + 文风指纹第一阶段（P1-1 落地）

### 方法：把「有指令无检测」从零散观察升级为全量对照

新增 `tool/probe_rule_gaps.py`，把 `fanqie_prompts` 28 条规则与 `writing_guidelines` 全量对照检测器，逐候选真实成书取数——**本轮先证明哪里没有缺口，再决定在哪建能力**。

### 清扫结论（六候选、五个被证据否决）

| 候选（规则） | 真实成书实测 | 判定 |
|---|---|---|
| 说话标签频率（规则 4，≤1/3） | 113 适用章：中位 0.05、**最大 0.26、超线 0 章** | ❌ 死——上游已守住 |
| 总结式抒情收尾（规则 22 收尾侧） | 0/116 章末句命中 | ❌ 死——钩子生态（缺钩即补写）上游压制 |
| 情绪直陈（规则 15，叙述层） | 0/116 章、0 次命中 | ❌ 死 |
| 非视觉五感（规则 17，≥2 类） | 92% 章达标（分布 4类:22/3:47/2:38/1:9） | ❌ 信号弱不值规则化 |
| 钩子承接（上章钩 vs 下章开篇） | 均值提升 1.7×（0.206 vs 0.123），但**逐书人工复核判死**：被标章对里有教科书式转述承接（青苔/斜阳同一场景仍低于基线——词面 bigram 被母题复用污染），宁可不做 | ❌ 假阳性否决 |
| **goal 四元组（GOAL_FORMAT「缺一项视为不合格」）** | 209 份章纲 **150 份四键全缺**；近期产物缺的全是**结构补章路径**（补章 prompt 自己只要求「60~120 字自由文本」） | ✅ 唯一实锤，修根因 |

### 改动一：结构补章 goal 格式与 GOAL_FORMAT 对齐（缺陷 #19）

- `structure_fix_prompt`：goal 改按四元组（新信息=｜变化=｜主角选择=｜钩子=，各键值 15~40 字）+「回收伏笔=」键，缺任一四元组键视为不合格；JSON 输出示例同步
- **只修根因不建校验闸**：补章自带 `hook` 字段本有 `extract_chapter_hook` 兜底，影响弱——先对齐 prompt，观察后续产物四键齐全率再决定是否加校验（与「note 级先观察」同一哲学）

### 改动二：文风指纹第一阶段（P1-1，人类审读短板②的正面解）

前几轮都是「查错」，本轮做「学好」——把参考文的风格变成可注入、可度量的分布目标：

- **`style_fingerprint(text, source)`**（generate_novel）：九项分布指标（句长均值/句长 CV/对白占比/段落均长/单句成段/的字密度/叠词密度/句首连接词率/比喻密度），**全部复用 `deep_ai_metrics`/`dialogue_ratio` 既有口径**，不另起标准；返回值只含数值不含可照抄内容
- **`style_fingerprint_block(fp)`**：数字 + 可执行翻译（长短句错落、段落呼吸）+ **禁抄条款**（防仿写变抄袭）
- **`fingerprint_distance(a,b)`**：比值式归一化 L1（量纲自归一，无需定权），0=同分布——收敛验收的度量
- **`novel_pipeline --style-ref <txt>`**：提取指纹 → 注入写手 `scene_prompt`（`style_block` 参数，**默认空=旧调用零变化**；结构补章经 `ctx["style_block"]` 同流）→ **逐章打印与参考文的指纹距离**（收敛趋势真机可观测）
- 真书渲染冒烟：v7 指纹「句长均值 16.2 字、CV 0.6、对白 28%、段落均长 28.4、单句成段 31%、比喻 1.29/千字」；`distance(self)=0`、跨书 `0.467` ✓
- **端位说明**：Dart 侧无 `GOAL_FORMAT`、无该 CLI（P1-1 是 Python 流水线先行），本轮 Python-only 无双端漂移面；Dart 分析器/导入 UI 后续阶段

### 验证

- `python -m unittest discover -s scripts -p "test_*.py"` → **Ran 100 tests OK**（92→100：`test_style_fingerprint.py` 8 项——九键完整性/空文本/风格方向可分/块渲染含禁抄/零距离/注入位置/默认不注入）
- `ruff check --select=F,E9 scripts tool` 全绿；`compileall` 0；三模块 `--help` 回归（`--style-ref` 已见于 help）
- 门禁兼容：v7 `--check-only` 仍为 FAIL 14/16（改动前同分，门禁不触 novel_pipeline）
- **未验证项**：`--style-ref` 的真实收敛效果需真机生成对比距离趋势（离线只能验证注入与度量本身）；补章四键齐全率待下一次结构打回产物复查




---

## 二十五、2026-09-28 文风指纹 P1-1 收口：共享装载 + 评审证据 + 编辑保文风 + 双入口 + 真机单发验证

### 背景：二十四留下的三个半成品面

二十四把指纹「可注入、可度量」做出来了，但只接了 `novel_pipeline` 单入口：`generate_novel` 独立入口即将复制第二份装载逻辑；评审侧看不到收敛证据；编辑链不知有文风约束，可能把注入的节奏改回「编辑腔」。另有注入前检查发现的准则冲突（见改动 4）。

### 改动（Python-only，Dart 无此 CLI 面无漂移）

1. **共享装载器 `load_style_block(path)`**（`generate_novel` 定义，`novel_pipeline` 复用）：读参考 txt → 指纹 + 注入块；读取失败打印 `[文风] --style-ref 读取失败…本轮不注入` 降级——「默认空 = 旧调用零变化」语义不变，装载逻辑单点不漂移
2. **评审证据 `style_ev_fragment(gen_fp, ref_fp)`**：逐章「与参考文的距离分解」注入 `qa_ev`（与落点/三件套证据同款套路），收敛过程从终端打印升级为**评审可见**；`novel_pipeline` qa_ev 同流
3. **编辑保文风条款**：`editor_prompt(..., style_block=...)` 增「保留本章句式节奏与段落呼吸，仅可修错别字与事实错误；与风格块冲突以风格块为准」——主循环润色与定点修**两处调用点**都传入，堵「写手学了风格、编辑改回去」的链路抵消
4. **指纹块优先级条款**：注入前检查发现参考文对白 6% 与准则 25%~45% 直接冲突——描述性数字会诱导模型少写对白，`style_fingerprint_block` 块头加「与准则冲突时以准则为准」，防「学分布」变「学低对白」
5. **第二入口 `generate_novel --style-ref`**：独立生成入口同款注入 + 逐章打印距离

### 真机单发验证：`tool/style_live_probe.py` → PROBE_OK，distance=0.48

整章真机跑在本会话不可行（30s 命令上限 + 后台进程回收反复杀任务），验证面缩到**一次**真实写手调用：106660 字真书指纹装载 → `scene_prompt` 注入 → 商汤 `deepseek-v4-flash` 单发 → 对真实产出算 `fingerprint_distance`。23s 守护线程硬闸保证单次预算，`--key-slot K1|K2|K3` 支持 429 换 Key 重试。

- **调试轨迹（三轮真机失败各留下一个真实教训）**：① AMD 流式响应两次拖过 18s 闸（「慢速但持续」的流，socket timeout 拦不住）→ 换商汤 dsf-flash；② 商汤 K1 撞 429（tpm 配额），`llm_call` 内部重试「等 20s」直接吞掉闸预算 → 探针改 `retries=0` 快速失败 + Key 槽换配额桶；③ 非 429 时是**真实生成中** 20s 压线 → 闸提 23s + 样例限 400 字 → **PROBE_OK**
- **结果**：`chars=982 words=823 distance=0.48`；gen 指纹句长 17.9 / 对白 12% / 段落 41.1 vs ref 22.1 / 6% / 53.9；产出开头「裴照垂着眼，看那枚青玉简在执律长老指间碎成两截。玉屑落在第三级石阶上。」——短句 + 具体物象，贴参考文节奏且非照抄
- **度量解读（单点不证收敛）**：0.48 与既有跨书基线 0.467 同量级——本轮真机证明的是「**注入链路真机通、度量可跑、产出可用**」，不是风格已收敛；982 字单样本对九维分布比值偏噪，收敛验收须看真机 `--style-ref` **多章距离下降趋势**（见遗留）

### 验证

- `python -m unittest discover -s scripts -p "test_*.py"` → **Ran 103 tests OK**（100→103：`LoadStyleBlockAndEvidenceTest` 装载成功/失败降级不注入 + `EditorPromptStyleKeepTest` 保文风条款透传/空块不注入）
- `ruff check --select=F,E9 scripts tool` 全绿；`compileall` 0
- 真机 PROBE_OK（上）；探针与主链共用同一 `scene_prompt`/`load_style_block`，无第二套组装路径
- **遗留**：① 多章收敛趋势需真机 `--style-ref` 全链长跑（会话进程回收限制，待下轮）；② Dart 侧指纹分析器/导入 UI 后续阶段；③ 探针可复用：`python tool/style_live_probe.py [K1|K2|K3]`（先装载 `.env.local`）

### 补记：单点噪声带（n=5 独立采样，为多章收敛验收定标）

长跑暂不可得，但「多大变化才算真变化」可以先定——同一 prompt（同参考文、同场景 goal、temp=0.8）独立采样 5 次（每点一次真实写手调用；429 时等配额窗口 ~25s 重试；探针 `max_tokens` 已封顶 1200 提速，截断容忍）：

| # | distance | 产出字数 | 句长均值 | 对白 | 段落均长 |
|---|---|---|---|---|---|
| 1 | 0.480 | 982 | 17.9 | 12% | 41.1 |
| 2 | 0.527 | 1067 | 20.1 | 13% | 34.0 |
| 3 | 0.374 | 691 | 16.7 | 18% | 29.0 |
| 4 | 0.550 | 1370 | 18.1 | 17% | 30.7 |
| 5 | 0.555 | 618 | 18.3 | 38% | 21.7 |

- **均值 0.497、σ≈0.075、极差 0.181（0.374~0.555）**：单点噪声远大于「0.5→0.45」这类变化——单点永不判收敛
- **收敛判据（据此定标）**：① 单点不判；② **3 章滑动均值 ≤0.35（≈ 均值 −2σ）** 才判「收敛开始」；③ 判读优先看 `style_ev_fragment` 分维分解（句长/对白/段落），总距离只看趋势不看绝对值
- **结构性地板**：对白维参考 6% 与准则 25%~45% 冲突，优先级条款生效后对白维**永不向 6% 收敛**——总距离存在不收敛分量，这正是「只看趋势＋看分解」的原因；采样对白 12%~38% 也恰是五维里最噪的
- 采样注记：样本字数 618~1370 不齐（400 字提示 + token 封顶双保险下模型服从度仍随机），单样本九维比值天然偏噪——噪声带上限估计偏保守（真实多章 600~800 字口径下 σ 或略小）

---
