#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一键真机复验：端点体检 → 跑书 → 三组判据出结论。

存在理由
--------
第 26~34 节把「外显爽点断供」的检测/预防/修复三层做完并双端对齐，**机制**侧证据
已足（三次真机确认预防链精准投放、规划链修复实测省 8 分钟）。但**效果**侧三组判据
始终缺数据，根因是端点长期降级：连续三轮跑书都因商汤 429 / glm 思考链吃满 / AMD 504
而中断。

而此前两次「先探针再跑书」都栽在同一处：**用 200 token 的短探针判健康**。
短探针对「慢」与「坏」不可区分——实测 dsf-flash 短探针 1.6s「OK」，真实规模却要
28.8s；AMD 更要 159s，两者一度都被我误判成「不可用」。

故本脚本把三件事绑在一起，**健康检查不通过就拒绝跑书**（不再白烧配额）：

  ① 真实规模体检：每个写手链端点要 **1500 字**正文，窗口 200s（覆盖 AMD 的 159s）；
  ② 体检通过 → 拉起流水线（带 --style-ref 以取判据③），后台脱离；
  ③ 书跑完后 → 调 tool/verify_quality_effect.py --compare 出三组判据。

用法
----
    # 只体检，不跑书
    python tool/verify_effect_run.py --check-only

    # 体检 + 跑书（默认 5 章 15000 字）
    python tool/verify_effect_run.py

    # 自定义规模
    python tool/verify_effect_run.py --chapters 8 --words 24000

    # 书已经跑完，只补判据
    python tool/verify_effect_run.py --only-verdict data/generated/xxx.jsonl
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

HEALTH_MIN = 1          # 至少 N 个写手端点体检通过才允许跑书
PROBE_CHARS = 1500      # 体检要求的正文规模（与真实场景同量级）
PROBE_TIMEOUT = 200     # 单端点体检窗口（AMD 实测 159s，留余量）
RUN_TIMEOUT_MIN = 90    # 跑书最长等待（分钟）


def load_env():
    env_file = ROOT / ".env.local"
    if not env_file.exists():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def probe(slot):
    """真实规模体检：要求 slot 写出约 PROBE_CHARS 字正文。

    返回 (ok, chars, sec, note)。**不能用短探针**——短探针对「慢/坏」不可区分。
    """
    import threading
    import novel_pipeline as nppl

    prompt = (f"请写一个玄幻小说场景，约 {PROBE_CHARS} 字：主角当众击败对手。\n"
              "要求：写出对手与围观者的外部反应；只用正文，不要解释。")
    box = {}

    def run():
        t0 = time.time()
        try:
            out = nppl.llm_call(dict(slot), "你是网文作者。", prompt,
                                max_tokens=PROBE_CHARS * 2, retries=0)
            box["v"] = (bool(out.strip()), len(out), round(time.time() - t0, 1), "")
        except Exception as e:  # noqa: BLE001 体检要看到任何失败原因
            box["v"] = (False, 0, round(time.time() - t0, 1), str(e)[:100])

    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(PROBE_TIMEOUT)
    if t.is_alive():
        return (False, 0, PROBE_TIMEOUT, f"超时 >{PROBE_TIMEOUT}s")
    return box.get("v", (False, 0, 0, "no-result"))


def health_check():
    load_env()
    import novel_pipeline as nppl
    nppl.setup_keys()
    seen, rows = set(), []
    for slot in nppl.WRITER_CHAIN:
        key = (slot.get("url"), slot.get("model"))
        if key in seen:
            continue
        seen.add(key)
        ok, chars, sec, note = probe(slot)
        rows.append({"model": slot.get("model"), "ok": ok, "chars": chars,
                     "sec": sec, "note": note})
        flag = "OK  " if ok and chars >= PROBE_CHARS * 0.6 else "BAD "
        print(f"  [{flag}] {slot.get('model'):24} {chars:>5} 字 {sec:>6}s {note}")
    passed = sum(1 for r in rows if r["ok"] and r["chars"] >= PROBE_CHARS * 0.6)
    return rows, passed


def run_book(args):
    load_env()
    out = ROOT / "data" / "generated" / args.output
    log = ROOT / "verify-logs" / (args.output.replace(".jsonl", ".log"))
    ref = ROOT / "data" / "generated" / "novel_10w_pipeline_final.txt"
    if out.exists():
        out.unlink()
    cmd = [sys.executable, "-u", str(ROOT / "scripts" / "novel_pipeline.py"),
           "--total-words", str(args.words), "--max-chapters", str(args.chapters),
           "--genre", args.genre, "--output", str(out), "--no-chief-review"]
    if ref.exists():
        cmd += ["--style-ref", str(ref)]
    else:
        print("  [WARN] 参考文不存在，本次不带 --style-ref（判据③ 将无数据）")
    with open(log, "w", encoding="utf-8") as f:
        proc = subprocess.Popen(cmd, cwd=str(ROOT), stdout=f,
                                stderr=subprocess.STDOUT,
                                env=dict(os.environ))
    print(f"  已拉起 pid={proc.pid}；日志 {log}")
    print(f"  等书跑完（最长 {args.wait} 分钟），期间可另开窗口看日志")
    deadline = time.time() + args.wait * 60
    while time.time() < deadline:
        time.sleep(20)
        if proc.poll() is not None:
            break
    if proc.poll() is None:
        print("  [WARN] 超时未跑完，进程仍在跑（可断点续跑：同命令重跑即续）")
        return str(out)
    print(f"  流水线结束，返回码 {proc.returncode}")
    return str(out)


def verdict(path, baseline):
    cmd = [sys.executable, str(ROOT / "tool" / "verify_quality_effect.py")]
    if baseline and Path(baseline).exists():
        cmd += ["--compare", baseline, path]
    else:
        cmd += [path]
    print()
    subprocess.run(cmd, cwd=str(ROOT), env=dict(os.environ))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check-only", action="store_true", help="只体检不跑书")
    ap.add_argument("--only-verdict", default="", help="书已跑完，只补判据")
    ap.add_argument("--chapters", type=int, default=5)
    ap.add_argument("--words", type=int, default=15000)
    ap.add_argument("--genre", default="玄幻")
    ap.add_argument("--output", default="verify_effect.jsonl")
    ap.add_argument("--wait", type=int, default=RUN_TIMEOUT_MIN)
    ap.add_argument("--baseline",
                    default=str(ROOT / "data" / "generated" / "novel_10w_pipeline.jsonl"))
    a = ap.parse_args()

    if a.only_verdict:
        verdict(a.only_verdict, a.baseline)
        return 0

    print("① 端点真实规模体检（要 %d 字，窗口 %ds）" % (PROBE_CHARS, PROBE_TIMEOUT))
    rows, passed = health_check()
    print(f"  → {passed} 个写手端点可用（需 ≥{HEALTH_MIN}）")
    if a.check_only:
        return 0
    if passed < HEALTH_MIN:
        print("\n❌ 体检不通过，**不跑书**（此前正因跳过这步白烧过配额）。")
        print("   端点恢复后重跑本脚本即可；健康检查刻意用真实规模——")
        print("   200 token 短探针对「慢/坏」不可区分（dsf 1.6s vs 28.8s、AMD 159s）。")
        return 2

    print("\n② 跑书（%d 章 / %d 字）" % (a.chapters, a.words))
    path = run_book(a)
    print("\n③ 三组判据")
    verdict(path, a.baseline)
    return 0


if __name__ == "__main__":
    sys.exit(main())