"""密钥卫生回归（CI 跑）：入库文件里不得出现真密钥，.env.local 必须处于被忽略状态。

背景（2026-10-01 评审）：仓库根的 `.env.local` 里躺着 6 个真 Key（AMD/商汤×3/
NVIDIA/OpenRouter），`verify-logs/live_pipeline/*.json` 里也留了 Key 串。两者都
被 .gitignore 覆盖、git 历史也确实干净（评审时逐 ref 核对过），但「明文落盘 +
会被日志/agent 读到」这个组合很脆，需要一道**自动**闸门，而不是靠人记得检查。

本测试只做三件确定性的事：
1. 断言 `.env.local` 若存在则必须被 git 忽略（防止有人手滑 `git add -f`）；
2. 扫描**已入库文件**是否含高熵密钥串（按各平台前缀 + 熵判据，跳过明显的占位符）；
3. 断言 `.gitignore` 仍覆盖 `.env*` / `verify-logs/` / `data/`（历史事故区）。
"""
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 各平台密钥形态。占位符（rc-0000…、sk-aaaa…、nvapi-eeee…）会被熵判据排除：
# 要求长度 >= 20 且**不同字符数 >= 8**，重复字符的假值天然过不了。
KEY_PATTERNS = [
    re.compile(r"\brc-[0-9a-fA-F]{20,}\b"),
    re.compile(r"\bnvapi-[A-Za-z0-9_\-]{20,}\b"),
    re.compile(r"\bsk-or-v1-[0-9a-fA-F]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"),
]
# 这些是刻意放在测试夹具里的假值（含重复字符），扫描时仍需按熵过滤
IGNORE_FILES = {".env.example"}


def _git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args],
                          capture_output=True, text=True, encoding="utf-8", errors="replace")


def _is_high_entropy(token: str) -> bool:
    body = token.split("-", 1)[1] if "-" in token else token
    body = body.replace("-", "").replace("_", "")
    return len(body) >= 20 and len(set(body)) >= 8


class SecretHygieneTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if _git("--version").returncode != 0:
            raise AssertionError("需要 git（本测试用于校验入库内容的密钥卫生）")

    def test_env_local_is_ignored(self):
        env = ROOT / ".env.local"
        if not env.exists():
            self.skipTest("本机无 .env.local（模板见 .env.example）")
        r = _git("check-ignore", "-v", ".env.local")
        self.assertEqual(r.returncode, 0,
                         "危险：.env.local 未被 git 忽略——真 Key 可能被提交入库")
        self.assertIn(".env", r.stdout)

    def test_gitignore_still_covers_sensitive_paths(self):
        text = (ROOT / ".gitignore").read_text(encoding="utf-8")
        for pattern in (".env", ".env.*", "verify-logs/", "data/", "*.key"):
            self.assertIn(pattern, text, f".gitignore 缺少关键忽略项：{pattern}")

    def test_no_high_entropy_keys_in_tracked_files(self):
        listing = _git("ls-files")
        self.assertEqual(listing.returncode, 0, "git ls-files 失败")
        offenders = []
        for rel in listing.stdout.splitlines():
            if not rel or Path(rel).name in IGNORE_FILES:
                continue
            path = ROOT / rel
            try:
                raw = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            for pat in KEY_PATTERNS:
                for m in pat.finditer(raw):
                    if _is_high_entropy(m.group(0)):
                        offenders.append(f"{rel}: {m.group(0)[:12]}…（已截断）")
        self.assertEqual(offenders, [],
                         "已入库文件里出现疑似真密钥：\n" + "\n".join(offenders[:10]))


if __name__ == "__main__":
    unittest.main()
