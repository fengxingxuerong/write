#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真机单发探针：文风指纹注入真实写手调用 + 距离度量真实产出。

背景：会话级 shell 30s 命令上限 + 后台进程回收让整章真机跑不可行，
本探针把验证面缩到**一次** scene_prompt 写手调用（守护线程 18s 硬闸，可重试）：
1) load_style_block 读真实参考文（106660 字《碎脉铸仙录》）；
2) llm_call 走商汤 dsf-flash 写手位（novel_pipeline TITLER 同链，角色冒烟 3-4s）；
3) 对真实产出算 fingerprint_distance（ref vs 生成）。
输出 PROBE_OK / PROBE_TIMEOUT 供轮询判定。

用法（装载 .env.local 后）：python tool/style_live_probe.py
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from generate_novel import (  # noqa: E402
    SYSTEM_PROMPT,
    fingerprint_distance,
    load_style_block,
    scene_prompt,
    style_fingerprint,
)

ROOT = Path(__file__).resolve().parent.parent
REF = ROOT / "data" / "generated" / "novel_10w_pipeline_final.txt"


def main():
    # 用法：python tool/style_live_probe.py [K1|K2|K3]（429 换 Key 重试）
    slot = sys.argv[1] if len(sys.argv) > 1 else "K1"
    key_env = f"NOVEL_KEY_SENSE_{slot}"
    if not os.environ.get(key_env, ""):
        print(f"PROBE_FAIL no key ({key_env})")
        return 1
    block, ref_fp = load_style_block(str(REF))
    if not block:
        print("PROBE_FAIL no fingerprint")
        return 1
    goal = ("新信息=主角裴照因灵脉破碎被贬为外门弟子，今日内门资格被当众剥夺｜"
            "变化=裴照从内门弟子降为外门杂役，失去资源与地位｜"
            "主角选择=裴照当众接下羞辱，主动选择接受传承，付出昏迷三日的代价｜"
            "钩子=威胁逼近（传承引动体内异变，宗门长老察觉异常）"
            "。样例输出控制在 400 字以内，保留场景任务全部要素（探针提速用）。")
    prompt = scene_prompt(1, 2, "起", goal, [], "", "玄幻",
                          protagonist="裴照", style_block=block)
    # 总时长硬闸：单次调用 20s 守护线程闸（启动+指纹+调用+打印 ≈26s < 30s 命令上限）。
    # llm_call(retries=0) 对 429 快速返回空（不睡眠），换 Key 槽跨命令重试。
    import threading

    import novel_pipeline as nppl
    provider = dict(nppl.TITLER)
    provider["key"] = os.environ[key_env]
    # 1200 上限：思考链（enable_thinking 常被忽略，实测吃 400+）+ 正文合计封顶，
    # 最坏生成时长 ≈ 1200 token / ~45 tok/s ≈ 27s 内可完成；截断可容忍——
    # 噪声采样只度量已产出文本的分布，且 400 字提示与上限双保险提速。
    provider["max_tokens"] = 1200
    result = {}

    def _run():
        try:
            result["out"] = nppl.llm_call(
                provider, SYSTEM_PROMPT, prompt,
                max_tokens=1200, retries=0)
        except Exception as e:  # noqa: BLE001 探针要打印任何失败原因
            result["err"] = f"{type(e).__name__}: {e}"

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    t.join(23)
    if t.is_alive():
        print(f"PROBE_TIMEOUT {slot} call slower than 23s deadline")
        return 2
    out = (result.get("out") or "").strip()
    if not out:
        if "err" in result:
            print(f"PROBE_FAIL {slot} {result['err']}")
        else:
            print(f"PROBE_EMPTY {slot}（429/限流见上方 [retry] 打印——"
                  "换 Key 槽或等待配额窗口后重试）")
        return 3
    gen_fp = style_fingerprint(out, source="probe-gen")
    dist = fingerprint_distance(ref_fp, gen_fp)
    print(f"PROBE_OK chars={len(out)} words={gen_fp['words']} "
          f"distance={dist}")
    print(f"gen_fp: sent_len={gen_fp['sent_len_mean']} "
          f"dialogue={gen_fp['dialogue_ratio']:.0%} "
          f"para={gen_fp['para_len_mean']}")
    print(f"ref_fp: sent_len={ref_fp['sent_len_mean']} "
          f"dialogue={ref_fp['dialogue_ratio']:.0%} "
          f"para={ref_fp['para_len_mean']}")
    print("HEAD:", out[:120].replace("\n", " "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
