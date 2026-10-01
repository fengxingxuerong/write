"""真机跑书（**花钱**的脚本）：默认只体检 + 试算，加 --yes 才真正开跑。

为什么改成默认不跑（2026-10-01 评审）：
    原版一执行就读 .env.local 里的真 Key 并立刻拉起流水线——误触即真金白银，
    也没有任何「这次要花多少」的提示。现在：
        python tool/live_run.py           # 体检 + 试算，不发一次请求（默认）
        python tool/live_run.py --yes     # 确认后才跑真机流水线

用法:
    python tool/live_run.py [--yes] [--words 3000] [--chapters 1] [--genre 玄幻]
                            [--out data/generated/live_v1.jsonl]

前置：把 .env.example 复制成 .env.local 并填真值（该文件不入库，见
scripts/test_secret_hygiene.py 的校验）。
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV_PATH = ROOT / ".env.local"
REQUIRED_KEYS = ("NOVEL_KEY_AMD", "NOVEL_KEY_SENSE_K1", "NOVEL_KEY_SENSE_K2")


def load_env(path: Path) -> dict:
    """读 .env.local 的 KEY=VALUE（不覆盖已有环境变量；任何环节都不打印值）。"""
    if not path.exists():
        print(f"[ERR] 缺少 {path}——先复制 .env.example 并填真值（该文件不入库）")
        sys.exit(1)
    env = dict(os.environ)
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    return env


def mask(value: str) -> str:
    """只回显前缀与长度，避免密钥进终端历史/截图/日志。"""
    if not value:
        return "(未设置)"
    return f"{value[:6]}…（len={len(value)}）"


def main() -> int:
    ap = argparse.ArgumentParser(description="真机跑书（默认只体检，--yes 才花钱）")
    ap.add_argument("--yes", action="store_true",
                    help="确认开跑真机流水线（会真实消耗各家 API 额度）")
    ap.add_argument("--words", type=int, default=3000, help="目标字数（默认 3000）")
    ap.add_argument("--chapters", type=int, default=1, help="最大章数（默认 1）")
    ap.add_argument("--genre", default="玄幻", help="题材（默认 玄幻）")
    ap.add_argument("--out", default="data/generated/live_v1.jsonl", help="产物 jsonl 路径")
    args = ap.parse_args()

    env = load_env(ENV_PATH)
    print("== 体检 ==")
    missing = []
    for key in REQUIRED_KEYS:
        value = env.get(key, "")
        print(f"  {key:22s} {mask(value)}")
        if not value:
            missing.append(key)
    print(f"  本地模型 Base URL      {env.get('NOVEL_LLM_BASE_URL', '') or '(未设置，走云端角色)'}")

    per_chapter = max(1, args.words // max(1, args.chapters))
    print("\n== 试算 ==")
    print(f"  计划：{args.chapters} 章 × 约 {per_chapter} 字，题材 {args.genre}")
    print(f"  产物：{args.out}")
    print("  代价：多角色流水线（规划/写手/润色/标题/审校）会真实消耗各家 API 额度；"
          "单章通常数次请求，配额波动时会重试。")
    print("  提示：.env.local 是明文密钥文件；若它曾被分享或提交过，请到各平台轮换后再用。")

    if missing:
        print(f"\n[ERR] 缺少必需 Key：{'、'.join(missing)}——体检不通过，拒绝开跑")
        return 1
    if not args.yes:
        print("\n[DRY-RUN] 未加 --yes，本次不发任何请求。确认开跑请执行：")
        print(f"  python tool/live_run.py --yes --words {args.words} "
              f"--chapters {args.chapters} --genre {args.genre}")
        return 0

    out = ROOT / args.out
    log_dir = ROOT / "verify-logs"
    log_dir.mkdir(exist_ok=True)
    out.parent.mkdir(parents=True, exist_ok=True)
    log, err = log_dir / "live_v1.log", log_dir / "live_v1.err"
    for f in (log, err):
        f.unlink(missing_ok=True)
    cmd = [sys.executable, "-u", str(ROOT / "scripts" / "novel_pipeline.py"),
           "--total-words", str(args.words), "--max-chapters", str(args.chapters),
           "--genre", args.genre, "--output", str(out), "--no-chief-review"]
    print("\n== 开跑 ==")
    print("  " + " ".join(cmd[1:]))
    with log.open("w", encoding="utf-8", buffering=1) as lf, \
            err.open("w", encoding="utf-8", buffering=1) as ef:
        proc = subprocess.Popen(cmd, cwd=str(ROOT), env=env, stdout=lf, stderr=ef,
                                creationflags=0x08000000 if os.name == "nt" else 0)
    print(f"  PID {proc.pid}；日志 {log.relative_to(ROOT)} / {err.relative_to(ROOT)}")
    print("  断点续传：中断后重跑同一命令会自动继续。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
