#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""测试有效性审计：找出「恒真断言」与「名义上测了、实际没跑到」的测试。

背景（2026-10-03）：覆盖率 86.93% 且无零覆盖文件，看起来很健康。但审计
crash_reporter_test.dart 时发现一个**假绿**：

    test('服务器返回 500 抛异常', () async {
      ...
      config: CrashReporterConfig(uploadUrl: 'http://127.0.0.1:$port/api/crash'),
      expect(..., throwsA(isA<CrashReportException>()));
    });

`CrashReporterConfig.enabled` 只允许 HTTPS，而这里传的是 HTTP →
函数在第一道 `if (!config.enabled)` 就抛异常了 → 期望的「500 处理」
一行都没执行，测试却绿。覆盖数据显示 160~209 行（整个 HTTP 上报主体）
未覆盖，正是这个原因。

**假绿比没测试更危险**：它让人以为上传逻辑有回归保护，实际没有。
且它伪装得很像真测试（有 server、有 listener、有断言）。

本工具做三件事，全部只读：
  1. 扫描 Dart 测试里的**恒真断言**（expect(…, isTrue) 之类无法失败的写法）；
  2. 报告「同一个异常类型被多个用例断言」而其中部分根本到不了目标分支；
  3. 列出覆盖率低于阈值的关键路径文件。
"""
import io
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

TEST_DIR = ROOT / "test"

# ---- 1) 恒真断言扫描 ----
# 只报**真正无判别力**的形态。
#
# 刻意不把 `expect(someBool, isTrue)` 列为可疑：那对布尔变量是完全有效的
# 断言，仓库里有大量正确用法（cfg.enabled / restored.useEditor 等），
# 全量报出来会淹没真信号——这本身就是一种噪音型门禁。
# 只抓两类「无论输入如何都成立」的写法。
TAUTOLOGY_PATTERNS = [
    # 字面量布尔做被断言对象：expect(true, isTrue) 恒过。
    (re.compile(r"expect\(\s*(true|false)\s*,"), "expect(字面量, …) — 恒真，无判别力"),
    # 单参 contains 空串/空列表为 true。
    (re.compile(r"\.contains\(\s*''\s*\)"), ".contains('') 恒为 true"),
]

print("=" * 76)
print("测试有效性审计（只读，不改任何测试）")
print("=" * 76)

dart_tests = sorted(TEST_DIR.rglob("*.dart"))
print(f"测试文件：{len(dart_tests)} 个\n")

print("=== 1) 恒真断言（仅报无判别力形态）===")
print("（expect(布尔变量, isTrue) 是有效断言，不在此列——全量报会淹没真信号）\n")
found = 0
for p in dart_tests:
    text = p.read_text(encoding="utf-8", errors="replace")
    for i, line in enumerate(text.split("\n"), 1):
        if line.lstrip().startswith("//"):
            continue
        for pat, why in TAUTOLOGY_PATTERNS:
            if pat.search(line):
                rel = p.relative_to(ROOT).as_posix()
                print(f"  {rel}:{i}")
                print(f"      {line.strip()[:110]}")
                print(f"      → {why}")
                found += 1
                break
print(f"\n可疑恒真断言：{found} 处")

# ---- 2) 同类型异常断言聚集 ----
# 一个 `throwsA(isA<X>())` 断言出现在多处，若它们的前置条件都到不了目标分支，
# 则其中多数是无效覆盖。列出以便人工核查。
print("\n=== 2) throwsA 断言聚集（同一异常类型的多个用例）===")
print("（若前置条件让它们都走不到目标分支，则为假绿嫌疑）\n")
by_exc: dict = {}
for p in dart_tests:
    text = p.read_text(encoding="utf-8", errors="replace")
    for m in re.finditer(r"throwsA\(\s*isA<\s*(\w+)\s*>\s*\(\)\s*\)", text):
        by_exc.setdefault(m.group(1), []).append(p)
for exc, ps in sorted(by_exc.items(), key=lambda kv: -len(kv[1])):
    uniq = sorted({p.relative_to(ROOT).as_posix() for p in ps})
    print(f"  {exc}: {len(ps)} 处，跨 {len(uniq)} 个文件")
    for f in uniq[:6]:
        print(f"      {f}")

# ---- 3) 覆盖率低的关键路径 ----
print("\n=== 3) 覆盖率低于 90% 的 lib 文件（潜在盲区）===")
lcov = ROOT / "coverage" / "lcov.info"
if not lcov.exists():
    print("  （无 coverage/lcov.info，跳过）")
else:
    data: dict = {}
    cur = None
    LF = LH = 0
    for ln in io.open(lcov, encoding="utf-8", errors="replace").read().split("\n"):
        if ln.startswith("SF:"):
            cur = ln[3:].strip()
        elif ln.startswith("LF:"):
            LF = int(ln[3:])
        elif ln.startswith("LH:"):
            LH = int(ln[3:])
        elif ln == "end_of_record" and cur:
            data[cur] = (LH, LF)
            cur = None
    rows = []
    for f, (lh, lf) in data.items():
        parts = Path(f).parts
        if "lib" not in parts or lf < 20:
            continue
        pct = 100 * lh / lf
        if pct < 90:
            rows.append((pct, lf - lh, f, lh, lf))
    rows.sort(key=lambda x: -x[1])
    for pct, miss, f, lh, lf in rows:
        print(f"  {pct:6.2f}%  未覆盖 {miss:4d} 行 / {lf:4d}  {f}")
    print(f"\n低于 90% 的文件：{len(rows)} 个")

print("\n" + "=" * 76)
print("说明：本工具只**报告**不改测试。恒真断言与假绿需人工判读上下文后处理。")
print("=" * 76)