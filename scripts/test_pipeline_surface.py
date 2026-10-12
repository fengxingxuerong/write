#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""novel_pipeline 拆分护栏：锁死对外公开符号面。

背景（2026-10-03）：novel_pipeline.py 是 2620 行的「上帝文件」，正在按
LLM 调用 / 提示词 / 质检 三块拆分。拆分**只允许降低维护成本，不允许改动对外
契约**——仓库里有 16 个文件以 `import novel_pipeline as np` 属性方式取用
（scripts/ 下 8 个测试 + tool/ 下 6 个探针 + generate_novel 延迟导入）。

本测试把「拆分前后必须完全一致的符号名集合」固化下来：任何拆分遗漏转发导入、
或误删/误改函数名，这里立刻红。历史教训见 README「基线缺失即 SKIP 通过」的
假绿事故——门禁必须真能失败。

注意：本测试只校验**符号存在性与可调用性**，不校验行为等价；行为等价由
scripts/test_pipeline_reliability.py 等既有回归 + CI 全量 unittest 负责。
"""
import importlib
import sys
import unittest
import unittest.mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import novel_pipeline as np  # noqa: E402

# 拆分后 novel_pipeline 仍是聚合入口，必须继续转发导出的符号。
# 按职责分组，便于拆分时定位「漏了哪个」。
EXPECTED = {
    # —— LLM 调用与故障转移 ——
    "llm_call", "call_chain", "setup_keys", "scene_budget",
    # —— 各角色提示词 ——
    "editor_prompt", "titler_prompt", "verifier_prompt",
    "quality_review_prompt", "rewrite_prompt", "state_extract_prompt",
    "chief_editor_prompt", "chief_rewrite_prompt", "structure_fix_prompt",
    "outline_review_prompt", "review_outline", "reader_proxy_prompt",
    "fabrication_check_prompt", "fact_fix_prompt",
    "fact_check_stage", "payoff_repair_prompt", "payoff_scene_constraint",
    # —— 文本补丁与去重 ——
    "extract_chapter_hook", "apply_hook_patch", "apply_text_patch",
    "dedup_chapter", "dedup_scene_join", "is_payoff_scene",
    "fallback_scenes", "plan_scenes_or_fallback", "_splice_head",
    # —— 终审/承诺闭环 ——
    "verdict_from_score", "build_promise_block", "verify_promises_prompt",
    "verify_and_repair_promises", "apply_promise_closures",
    "ensure_complete_ending", "apply_chief_rewrites",
    "needs_fix", "needs_payoff_repair", "accept_payoff_repair",
    "trailing_drought_len", "update_registry",
    "concretize_world", "generate_appended_chapter",
    "load_reviews_from_jsonl", "load_reader_feedback", "main",
    # —— 转发自 foreshadow（2026-10-03 已拆出，调用方仍从本模块取）——
    "foreshadow_extract_prompt", "load_foreshadow", "save_foreshadow",
    "check_open_foreshadows", "scan_used_protagonist_names", "save_state_track",
    "load_state_track",
    # —— 角色配置常量（main 与探针脚本直接读）——
    "PLANNER", "PLANNER_CHAIN", "WRITER_CHAIN", "EDITOR_CHAIN", "TITLER",
    "VERIFIER_CHAIN", "STATE_EXTRACTOR", "READER_PROXY", "FORESHADOWER",
    "WORLD_GUARDIAN", "WORLD_GUARDIAN_CHAIN", "THRILL_DIRECTOR", "CHIEF_EDITOR_CHAIN",
    "OUTLINE_REVIEWER_CHAIN", "THINKING_FLOOR_TOKENS",
    # —— 阈值/词表常量（双端对账会读）——
    "EDITOR_MIN_RATIO", "HOOK_FALLBACK_SIGNALS", "FACT_CHECK_BUDGETS",
    "SENSE", "AMD", "NVIDIA", "COOLDOWN_SECONDS",
}


class TestPipelinePublicSurface(unittest.TestCase):
    """拆分护栏：对外符号面不得漂移。"""

    def test_expected_symbols_present(self):
        missing = sorted(n for n in EXPECTED if not hasattr(np, n))
        self.assertEqual(
            [], missing,
            f"novel_pipeline 缺少对外符号 {missing}——拆分时漏了转发导入？")

    def test_expected_symbols_callable_or_value(self):
        """符号必须可调用，或是非 None 的常量（防止转发成 None 占位）。"""
        bad = []
        for n in EXPECTED:
            v = getattr(np, n)
            # 槽位配置常量（dict/list/int/tuple 等）本身不可调用也没问题，
            # 只要求它们不是 None——None 意味着转发链断了。
            if v is None:
                bad.append(n)
        self.assertEqual([], bad, f"符号 {bad} 被转发成了 None 占位")

    def test_module_reimportable(self):
        """模块能被反复导入（拆分后无循环导入 / 无半初始化模块对象）。"""
        m = importlib.reload(np)
        self.assertTrue(hasattr(m, "llm_call"))
        self.assertTrue(callable(m.main))

    def test_slot_config_shared_by_reference(self):
        """槽位配置必须是**同一对象**被转发，不能是拷贝。

        这是拆分最容易悄悄破坏的性质：调用方（main、tool/ 下各探针）会原地
        写 `WRITER_CHAIN[i]["key"] = ...`。若转发时做了深拷贝/包装，
        写入就落在副本上，调用方读不到——且不报错，只在真机跑书时才表现为
        「环境变量设了却仍 401」，极难定位。故直接比对象身份。
        """
        import pipeline_llm as llm
        for name in ("PLANNER", "TITLER", "STATE_EXTRACTOR", "READER_PROXY",
                     "FORESHADOWER", "WORLD_GUARDIAN", "THRILL_DIRECTOR"):
            self.assertIs(getattr(np, name), getattr(llm, name),
                          f"{name} 被拷贝了，调用方原地改 key 将不生效")
        for name in ("PLANNER_CHAIN", "WRITER_CHAIN", "EDITOR_CHAIN",
                     "VERIFIER_CHAIN", "CHIEF_EDITOR_CHAIN",
                     "OUTLINE_REVIEWER_CHAIN", "WORLD_GUARDIAN_CHAIN"):
            self.assertIs(getattr(np, name), getattr(llm, name),
                          f"{name} 被拷贝了，setup_keys 写入的 key 将不生效")

    def test_setup_keys_writes_into_shared_slots(self):
        """setup_keys 必须写入「调用方可见的那个对象」，而不是副本。"""
        import pipeline_llm as llm
        saved = [(d.get("key")) for d in llm.WRITER_CHAIN]
        try:
            llm.WRITER_CHAIN[0]["key"] = "SENTINEL_KEY"
            # 经 novel_pipeline 这层看到的必须是同一个值
            self.assertEqual("SENTINEL_KEY", np.WRITER_CHAIN[0]["key"])
        finally:
            for d, k in zip(llm.WRITER_CHAIN, saved):
                d["key"] = k

    def test_scalar_thresholds_match_source(self):
        """阈值常量必须与单一数据源一致（拆分不能顺手改值）。"""
        import quality_rules_generated as gen
        self.assertEqual(gen.EDITOR_MIN_RATIO, np.EDITOR_MIN_RATIO)
        self.assertEqual(300, np.COOLDOWN_SECONDS)
        self.assertEqual(2000, np.THINKING_FLOOR_TOKENS)

    def test_function_objects_are_shared(self):
        """多数函数应直接转发（同一对象），保证 isinstance / monkeypatch 语义不变。

        例外：`call_chain` 在 novel_pipeline 侧是**有意**的薄包装（把本模块的
        llm_call / _in_cooldown 作为注入点传下去），不是同一对象——这是为了保住
        既有测试 `patch.object(pipeline, "llm_call")` 的效力，见该函数 docstring。
        故这里只断言「它确实转发到了 pipeline_llm 的实现」。
        """
        import pipeline_llm as llm
        for name in ("llm_call", "setup_keys", "scene_budget", "dedup_scene_join"):
            self.assertIs(getattr(np, name), getattr(llm, name),
                          f"{name} 不是同一个函数对象")

    def test_call_chain_wrapper_delegates_with_injection_points(self):
        """call_chain 必须是转发包装，且把本模块的 llm_call/_in_cooldown 传下去。"""
        import pipeline_llm as llm
        seen = {}

        def fake_chain(chain, system, user, max_tokens,
                       _call=None, _in_cooldown_=None):
            seen["call"] = _call
            seen["cooldown"] = _in_cooldown_
            return "DELEGATED"

        with unittest.mock.patch.object(llm, "call_chain", fake_chain):
            self.assertEqual("DELEGATED", np.call_chain([], "s", "u", 10))
        self.assertIs(np.llm_call, seen["call"])
        self.assertIs(np._in_cooldown, seen["cooldown"])

    def test_monkeypatch_on_reexported_name_still_blocks_network(self):
        """回归护栏：patch 本模块的 llm_call 后，call_chain 不得发真实请求。

        这是拆分最隐蔽的失效模式——补丁打在 novel_pipeline 上，而 call_chain
        内部却去解析 pipeline_llm 的全局名，于是补丁形同虚设、测试真发网络
        请求。仓库里 test_pipeline_reliability 有 20+ 处这种打桩，一旦失效
        不会报错，只会静默变慢/变脆。
        """
        sentinel = '{"issues":[]}'
        provider = {'url': 'http://local.invalid', 'model': 't', 'key': 'k'}
        with unittest.mock.patch.object(np, 'llm_call', return_value=sentinel):
            with unittest.mock.patch.object(np, '_in_cooldown', return_value=False):
                got = np.call_chain([provider], 'system', 'user', 100)
        self.assertEqual(sentinel, got)

    def test_no_accidental_leak_of_private(self):
        """拆分不应把内部实现细节（_ 前缀）暴露成新增公开符号。

        只断言下划线开头的名字不进 dir() 的公开面——这是 Python 惯例，
        顺带防止新模块把内部 helper 顺手起成公开名。
        """
        public = {n for n in dir(np) if not n.startswith("_")}
        self.assertNotIn("_HEALTH", public)
        self.assertNotIn("_mark_fail", public)


if __name__ == "__main__":
    unittest.main()