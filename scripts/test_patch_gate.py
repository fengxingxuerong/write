#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""补丁采纳闸 patch_gate（fanqie_review.patch_gate）离线回归测试。

为什么补这个（2026-10-11）
--------------------------
`patch_gate` 是补写 / 扩写 / 定点修产出的**采纳闸**：任何 LLM 补丁拼回正文前
都要过这道关，返回 (ok, reason)。它拦的是**已有实测案例的六类事故**——
① 空产出；② 超长；③ 指令 / 元话语残留；④ 题材漂移；⑤ 合规红线；⑥ 与正文尾部重复。
此前该函数**零直接单测**，只在生成链路里被间接调用。闸门口径一旦被改松/改坏，
坏补丁会静默混进正文，全量测试仍全绿，要等跑门禁才暴露。

本测试用合成输入逐条钉住六道闸的**真实触发口径**（均经探针实证，不凭代码假设），
并对每道「放行类」用例配负样本对照（防恒真命题）：

- 空产出 / 纯空白 → (False, 空产出)
- 超长：count_words > max_words → (False, 超长…)；贴着上限放行
- 元话语残留：`作为一个AI` / `我无法完成` 触发；正常改写话术（「请续写」/
  「根据您的要求」）经实证**不触发**、应放行
- 题材漂移：玄幻书里出现手机 → (False, 题材漂移…)；正常玄幻描写放行
- 合规红线：`虐杀`（无豁免的否决级词）触发；`分尸案`（命中白名单豁免）放行
- 尾部重复：补丁开头与正文尾部 >=20 字重合 → (False, 与正文尾部重复…)；不重合放行

全部离线、零 LLM 成本、不依赖 data/ 与 verify-logs/，CI 恒定生效。
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import fanqie_review as fr  # noqa: E402


class PatchGateTest(unittest.TestCase):
    # —— ① 空产出 ——
    def test_empty_rejected(self):
        ok, reason = fr.patch_gate("")
        self.assertFalse(ok)
        self.assertEqual(reason, "空产出")

    def test_whitespace_only_rejected(self):
        ok, reason = fr.patch_gate("   \n\t  ")
        self.assertFalse(ok)
        self.assertEqual(reason, "空产出")

    # —— ② 超长 ——
    def test_over_max_words_rejected(self):
        ok, reason = fr.patch_gate("字" * 300, max_words=50)
        self.assertFalse(ok)
        self.assertIn("超长", reason)

    def test_within_max_words_passes(self):
        # 负样本：贴着 max_words 之内应放行（不受超长闸拦截）
        ok, reason = fr.patch_gate("他运转灵力，一剑斩出。", max_words=50)
        self.assertTrue(ok)
        self.assertEqual(reason, "")

    # —— ③ 指令 / 元话语残留 ——
    def test_meta_talk_ai_rejected(self):
        ok, reason = fr.patch_gate("作为一个AI语言模型，我不能继续。")
        self.assertFalse(ok)
        self.assertIn("作为一个AI", reason)

    def test_meta_talk_refusal_rejected(self):
        ok, reason = fr.patch_gate("我无法完成这个请求，请提供更多信息。")
        self.assertFalse(ok)
        self.assertIn("我无法完成", reason)

    def test_normal_rewrite_phrasing_passes(self):
        # 负样本：模型常用的改写过渡话术（经实证不在 meta_talk 词表）应放行
        for s in ("请续写以下内容，承接上文，林啸天抬起眼运转灵力。",
                  "根据您的要求，我来续写这一段剧情，主角拔剑向前。",
                  "以下是修改后的正文，他转身离去，夜色深沉。"):
            ok, reason = fr.patch_gate(s, genre="玄幻", max_words=260)
            self.assertTrue(ok, f"{s!r} 应放行，实得 {reason!r}")

    # —— ④ 题材漂移 ——
    def test_genre_drift_phone_rejected(self):
        ok, reason = fr.patch_gate("他掏出手机屏幕亮了亮，打开微信发了条消息。", genre="玄幻")
        self.assertFalse(ok)
        self.assertIn("题材漂移", reason)

    def test_genre_consistent_passes(self):
        # 负样本：正常玄幻描写不触发漂移
        ok, reason = fr.patch_gate("他运转灵力，剑锋直指前方，寒气四溢。", genre="玄幻")
        self.assertTrue(ok)
        self.assertEqual(reason, "")

    # —— ⑤ 合规红线 ——
    def test_redline_veto_rejected(self):
        ok, reason = fr.patch_gate("他开始虐杀那些俘虏，手段残忍至极。")
        self.assertFalse(ok)
        self.assertIn("合规红线", reason)

    def test_redline_whitelist_passes(self):
        # 负样本：命中白名单的刑侦用法（「分尸案」）不否决
        ok, reason = fr.patch_gate("警方接手了这桩分尸案，连夜展开侦查。", genre="悬疑")
        self.assertTrue(ok, f"白名单豁免应放行，实得 {reason!r}")

    # —— ⑥ 与正文尾部重复 ——
    def test_tail_duplicate_rejected(self):
        # 补丁开头与正文尾部高度重合
        tail = "他缓缓抬起眼，望向长廊尽头那片沉沉的暮色，心底掠过一丝难以名状的惘然。"
        base = "前文很多内容，" * 30 + tail
        ok, reason = fr.patch_gate(tail, base_text=base, genre="玄幻")
        self.assertFalse(ok)
        self.assertIn("重复", reason)

    def test_tail_distinct_passes(self):
        # 负样本：补丁与尾部不重合应放行
        tail = "他缓缓抬起眼，望向长廊尽头那片沉沉的暮色。"
        base = "前文很多内容，" * 30 + tail
        ok, reason = fr.patch_gate("他拔出长剑，一剑斩落，石屑纷飞，血雾腾起。",
                                   base_text=base, genre="玄幻")
        self.assertTrue(ok, f"不重复应放行，实得 {reason!r}")


if __name__ == "__main__":
    unittest.main()
