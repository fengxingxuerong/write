#!/usr/bin/env python3
"""把 novel_pipeline.py 的「LLM 调用层」整段抽出为 pipeline_llm.py。

一次性工具（幂等）：按标记行定位整段，原样搬运，不改写任何代码内容——
搬运后再由 pipeline_llm.py 反向转发给 novel_pipeline，保证 16 个
`import novel_pipeline as np` 的调用方零改动。

用法：python tool/extract_pipeline_llm.py
"""
from __future__ import annotations

import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "scripts" / "novel_pipeline.py"
DST = ROOT / "scripts" / "pipeline_llm.py"

# 抽出区间：模型配置段起点 -> 各角色 Prompt 段起点（不含）
START = "# ============================================================\n# 模型配置（密钥经环境变量注入，不硬编码）"
END = "# ============================================================\n# 各角色 Prompt"

HEADER = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LLM 调用层 + 角色槽位配置：多模型协作的「传输层」。

2026-10-03 从 novel_pipeline.py 拆出（该文件 2620 行，属「上帝文件」）。
拆分依据是**内聚性边界**而非行数好看：本模块只负责「把一段 prompt 送到某个模型
并把文本拿回来」，不含任何写作判据（钩子/爽点/伏笔/一致性全在外面）。

本模块只依赖标准库 + quality_rules_generated（单一数据源），不含流水线状态，
可独立单测；导入本模块不会触发任何网络请求。

对外接口（调用方仍从 novel_pipeline 取同名转发，见该文件 import 处）：
  槽位常量：SENSE / AMD / NVIDIA / PLANNER / PLANNER_CHAIN / WRITER_CHAIN /
            EDITOR_CHAIN / TITLER / VERIFIER_CHAIN / STATE_EXTRACTOR /
            READER_PROXY / FORESHADOWER / WORLD_GUARDIAN / THRILL_DIRECTOR /
            CHIEF_EDITOR_CHAIN / OUTLINE_REVIEWER_CHAIN / THINKING_FLOOR_TOKENS
  函数：_key / setup_keys / scene_budget / llm_call / call_chain / dedup_scene_join
  阈值：EDITOR_MIN_RATIO / COOLDOWN_SECONDS

⚠ 拆分的红线（与 foreshadow.py 同一条）：拆分只降低维护成本，**不改对外契约**。
槽位配置是**可变 dict/list**，调用方（main、tool/ 下各探针）会原地改
`CHAIN[i]["key"]`；转发导入必须保持同一对象引用，**不能深拷贝**，否则
setup_keys 写进去的 key 在调用方看不到。故 novel_pipeline 侧直接 `from
pipeline_llm import (...)`，不做任何包装。
"""
import hashlib
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# 质检阈值单一数据源（rules/quality_rules.json 的生成物，无项目内依赖）。
import quality_rules_generated as _gen  # noqa: E402

'''

FOOTER = ''

REEXPORT = '''# ============================================================
# LLM 调用层 + 角色槽位配置（2026-10-03 从本文件拆出）
# ============================================================
# 转发导入而非直接定义，是为了让调用点（本文件 main / generate_appended_chapter /
# 以及仓库内 16 个 `import novel_pipeline as np` 的测试与探针脚本）都无需改动
# ——拆分只降低维护成本，不该顺手制造调用方迁移。槽位常量是**可变对象**，
# 这里不做任何拷贝，调用方原地改动与拆分前完全一致。
from pipeline_llm import (  # noqa: E402,F401
    SENSE, AMD, NVIDIA,
    PLANNER, PLANNER_CHAIN, WRITER_CHAIN, EDITOR_CHAIN, TITLER,
    VERIFIER_CHAIN, STATE_EXTRACTOR, READER_PROXY, FORESHADOWER,
    WORLD_GUARDIAN, THRILL_DIRECTOR, CHIEF_EDITOR_CHAIN,
    OUTLINE_REVIEWER_CHAIN, THINKING_FLOOR_TOKENS,
    _key, setup_keys, scene_budget, llm_call, call_chain, dedup_scene_join,
    EDITOR_MIN_RATIO, COOLDOWN_SECONDS,
)

'''


def main() -> int:
    if DST.exists():
        print("pipeline_llm.py 已存在，跳过（幂等）")
        return 0
    text = io.open(SRC, encoding="utf-8").read()
    i = text.find(START)
    j = text.find(END)
    if i < 0 or j < 0 or j <= i:
        print(f"标记未定位：start={i} end={j}", file=sys.stderr)
        return 1
    body = text[i:j].rstrip() + "\n"
    io.open(DST, "w", encoding="utf-8", newline="\n").write(
        HEADER + body + FOOTER)

    # 原文件：删掉抽出段，替换为转发导入块
    new_text = text[:i] + REEXPORT + text[j:]
    io.open(SRC, "w", encoding="utf-8", newline="\n").write(new_text)
    moved = body.count("\n")
    print(f"抽出 {moved} 行 -> scripts/pipeline_llm.py")
    print(f"novel_pipeline.py: {len(text.splitlines())} -> {len(new_text.splitlines())} 行")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
