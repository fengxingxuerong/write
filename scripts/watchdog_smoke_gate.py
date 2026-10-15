#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""watchdog_smoke_gate.py — 低峰守候跑冒烟门禁（带熔断与留痕）。

为什么需要它：
  · 白天端点窗口很差（429 / 冷却 / 网关 504 轮番），长跑性价比低 → 等低峰自动开跑；
  · 守候进程必须**与会话解耦**：`--detach` 用 DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP |
    CREATE_BREAKAWAY_FROM_JOB 把自己重新拉起——否则 Bash/终端超时的树杀会把刚起的运行一起
    带走（本机实测踩过：`nohup` 挡不住 Windows 的进程树清杀）；
  · 必须带**熔断**：环境故障导致的「零章产出」轮次不无限重试（默认最多 2 次尝试），到点
    无论如何收工并留下结论——避免整夜空转白烧配额；
  · 每个决策点写进状态文件，便于次日一眼看出「跑了没 / 为什么没跑 / 结论是什么」。

用法：
    python scripts/watchdog_smoke_gate.py                          # 现场等 02:30 开跑
    python scripts/watchdog_smoke_gate.py --at 01:00 --until 06:30  # 自定义时间窗
    python scripts/watchdog_smoke_gate.py --detach                 # 与会话解耦地后台守候
    python scripts/watchdog_smoke_gate.py --name smoke_gate_v8e    # 产物名（默认带日期）

产物：`data/generated/<name>.jsonl` 与同名 sidecar；门禁原始输出进
`verify-logs/<name>_gate.log`，决策轨迹进 `verify-logs/<name>_status.txt`。
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "verify-logs"

SENSE = "https://token.sensenova.cn/v1/chat/completions"
AMD = "https://developer.amd.com.cn/radeon/api/v1/chat/completions"

DEFAULT_START = "02:30"
DEFAULT_DEADLINE = "07:30"
MAX_ATTEMPTS = 2
PROBE_WAIT_MIN = 20
MIN_CHAPTERS = 3          # 门禁要求 ≥3 章；少于这个数视为该轮没跑成


# ============================================================
# 纯函数区（可离线单测，不碰时钟/网络）
# ============================================================
def next_window(start_hhmm, end_hhmm, now=None):
    """返回 (开跑时刻, 最晚收工时刻)：两者都取「下一个该时刻」，且 end 严格晚于 start。

    跨天必须成立：22:06 传入 02:30/07:30 要得到「明天 02:30 / 明天 07:30」，
    不能把 07:30 算成「今天已过期」——那样守候会立刻自认为超时退出（初版踩过）。
    """
    now = now or datetime.now()

    def _next(hhmm, after):
        h, m = (int(x) for x in hhmm.split(":"))
        t = after.replace(hour=h, minute=m, second=0, microsecond=0)
        while t <= after:
            t += timedelta(days=1)
        return t

    start = _next(start_hhmm, now)
    return start, _next(end_hhmm, start)


def count_chapters(jsonl_text):
    """统计 `type == "chapter"` 的记录数（坏行/半截行跳过，不抛异常）。"""
    n = 0
    for line in (jsonl_text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            if json.loads(line).get("type") == "chapter":
                n += 1
        except Exception:  # noqa: BLE001
            continue
    return n


def completion_has_content(payload):
    """从 /chat/completions 响应判断是否真有正文。

    思考型模型「思考链吃满」会返回 200 但 content 为空（本机常见），那种不算可用端点——
    否则体检会放行一个实际产不出正文的窗口。
    """
    try:
        msg = payload["choices"][0]["message"]
    except Exception:  # noqa: BLE001
        return False
    return bool((msg.get("content") or "").strip())


def should_retry(attempt, chapters, now, deadline, max_attempts=MAX_ATTEMPTS):
    """熔断规则：返回 (是否再试一轮, 原因)。

    产出达标 → 收工；否则看次数上限与硬截止——**绝不无限重试**（环境故障轮次重试再多
    也是空烧配额，且会拖到白天窗口更差）。
    """
    if chapters >= MIN_CHAPTERS:
        return False, "达标（%d 章 ≥ %d）→ 收工" % (chapters, MIN_CHAPTERS)
    if attempt >= max_attempts:
        return False, "已达尝试上限 %d 次 → 熔断收工" % max_attempts
    if now >= deadline:
        return False, "已到最晚收工时间 → 收工"
    return True, "产出不足（%d 章）→ 再试一轮" % chapters


# ============================================================
# I/O 区
# ============================================================
def _load_env():
    env = dict(os.environ)
    env_file = ROOT / ".env.local"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def _probe(model, url, key, timeout=90):
    payload = {"model": model, "temperature": 0.8, "max_tokens": 300, "stream": False,
               "messages": [{"role": "user", "content": "回：好"}]}
    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + key)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return completion_has_content(json.loads(resp.read().decode("utf-8", errors="replace")))
    except Exception:  # noqa: BLE001
        return False


def critical_path_ok(env):
    """关键路径体检：规划官主（glm K1）+（写手主 dsf K1 或 末备 AMD）。"""
    ok_glm = _probe("glm-5.2", SENSE, env.get("NOVEL_KEY_SENSE_K1", ""))
    time.sleep(4)
    ok_dsf = _probe("deepseek-v4-flash", SENSE, env.get("NOVEL_KEY_SENSE_K1", ""))
    time.sleep(4)
    ok_amd = _probe("DeepSeek-V4-Flash", AMD, env.get("NOVEL_KEY_AMD", ""))
    return ok_glm and (ok_dsf or ok_amd), (ok_glm, ok_dsf, ok_amd)


def detach(argv):
    """把自己以「与会话解耦」的方式重新拉起（Windows 专用 creationflags）。"""
    DETACHED_PROCESS = 0x00000008
    CREATE_NEW_PROCESS_GROUP = 0x00000200
    CREATE_BREAKAWAY_FROM_JOB = 0x01000000
    cmd = [sys.executable, "-u", str(Path(__file__).resolve())] + argv
    LOGS.mkdir(exist_ok=True)
    log = open(LOGS / "watchdog_smoke_gate.log", "a", encoding="utf-8", newline="\n")
    for flags in (DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB,
                  DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP):
        try:
            p = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, cwd=str(ROOT),
                                 creationflags=flags, close_fds=True)
            print("WATCHDOG_STARTED pid=%d flags=0x%X" % (p.pid, flags))
            return 0
        except OSError as e:
            print("flags 0x%X 失败: %s" % (flags, e))
    print("拉起失败")
    return 1


def main():
    ap = argparse.ArgumentParser(description="低峰守候跑冒烟门禁（带熔断与留痕）")
    ap.add_argument("--at", default=DEFAULT_START, help="开跑时刻 HH:MM（默认 02:30）")
    ap.add_argument("--until", default=DEFAULT_DEADLINE, help="最晚收工时刻 HH:MM（默认 07:30）")
    ap.add_argument("--name", default="smoke_gate_night", help="产物名（data/generated/<name>.jsonl）")
    ap.add_argument("--genre", default="玄幻")
    ap.add_argument("--detach", action="store_true", help="以会话解耦方式后台守候")
    a = ap.parse_args()

    if a.detach:
        rest = [x for x in sys.argv[1:] if x != "--detach"]
        return detach(rest)

    LOGS.mkdir(exist_ok=True)
    status_path = LOGS / ("%s_status.txt" % a.name)
    gate_log = LOGS / ("%s_gate.log" % a.name)
    jsonl = ROOT / "data" / "generated" / ("%s.jsonl" % a.name)

    def log(msg):
        line = "[%s] %s" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
        print(line, flush=True)
        with open(status_path, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    env = _load_env()
    start, deadline = next_window(a.at, a.until)
    log("守候启动：计划 %s 开跑，最晚 %s 收工，最多 %d 次尝试，产物 %s"
        % (start.strftime("%m-%d %H:%M"), deadline.strftime("%m-%d %H:%M"), MAX_ATTEMPTS, a.name))

    while datetime.now() < start and datetime.now() < deadline:
        time.sleep(60)
    if datetime.now() >= deadline:
        log("到点前已过最晚收工时间，放弃")
        return 0

    for attempt in range(1, MAX_ATTEMPTS + 1):
        if datetime.now() >= deadline:
            log("已达最晚收工时间，停止（第 %d 次尝试未开始）" % attempt)
            break
        while True:
            ok, detail = critical_path_ok(env)
            log("体检：glm K1=%s dsf K1=%s AMD=%s → %s"
                % (detail[0], detail[1], detail[2], "可用" if ok else "不可用"))
            if ok or datetime.now() >= deadline:
                break
            log("关键路径不可用，等 %d 分钟再试" % PROBE_WAIT_MIN)
            time.sleep(PROBE_WAIT_MIN * 60)
        if not ok:
            log("体检始终不通过，放弃")
            break

        log("第 %d 次尝试：开跑 %s" % (attempt, a.name))
        with open(gate_log, "a", encoding="utf-8") as f:
            f.write("\n===== attempt %d @ %s =====\n"
                    % (attempt, datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
            f.flush()
            proc = subprocess.run(
                [sys.executable, "-u", str(ROOT / "scripts" / "run_smoke_gate.py"),
                 "--output", "data/generated/%s.jsonl" % a.name, "--genre", a.genre],
                cwd=str(ROOT), env=env, stdout=f, stderr=subprocess.STDOUT)
        chapters = count_chapters(jsonl.read_text(encoding="utf-8", errors="replace")
                                  if jsonl.exists() else "")
        log("第 %d 次尝试结束：退出码 %d，产出 %d 章" % (attempt, proc.returncode, chapters))
        retry, why = should_retry(attempt, chapters, datetime.now(), deadline)
        log("熔断判定：%s" % why)
        if not retry:
            break

    log("守候退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
