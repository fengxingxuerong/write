"""假绿形态回归：崩溃上报测试不得再用 HTTP 假装测 HTTPS 分支。

背景（2026-10-03）：`CrashReporterConfig.enabled` 只允许 HTTPS，而
`uploadCrashLog` 的第一道判断就是 `if (!config.enabled)` 抛异常。历史上有
一个用例名叫「服务器返回 500 抛异常」，却传 HTTP 地址——它在 HTTPS 校验处
就抛了，「500 处理」一行都没跑到，却绿着。

这类假绿的危害大于没有测试：它让人以为上传逻辑有回归保护。
本测试用源码级断言把「假绿形态」钉死——它的判据不是行为，而是**测试代码
本身是否诚实**（用例名/注释是否承认它测不到目标分支）。

背景二：状态码判定已抽为纯函数 `crashUploadFailureFor`，由单测直接覆盖，
不再依赖服务器，故不需要为了「覆盖 500」而去放松 HTTPS-only 约束。
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEST = ROOT / "test" / "core" / "crash_reporter_test.dart"
SRC = ROOT / "lib" / "core" / "crash_reporter.dart"


def _test_text() -> str:
    return TEST.read_text(encoding="utf-8")


def _upload_test_files():
    """所有调用 uploadCrashLog 的测试文件（2026-10-05 扩展）。

    原来只看硬编码的 crash_reporter_test.dart 一个文件——假栈（HttpOverrides
    注入假 HttpClient）测试出现后，上传主体用例可能拆到别的文件；守卫若不跟着
    扫描，就等于给「把假绿挪个文件」开了后门。范围扩到全 test/ 树后，
    任何调用 uploadCrashLog 的文件都在判据之内。
    """
    files = []
    for path in sorted((ROOT / "test").rglob("*.dart")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        if "uploadCrashLog(" in text:
            files.append(path)
    return files


def _test_names(text: str):
    """取出所有用例名（只取名字，不切分正文）。

    为什么只取名字、不切正文（2026-10-03 连续失败 5 次的教训）：
    最初的设计是「按用例切分正文 → 逐个检查」，但 Dart 的声明/闭合/跨行
    组合太多，正则与行扫描两种方案**各自都**在边界上给出错误切分，
    导致守卫对正确代码误报、对注入的假绿却放过。

    一条守卫如果对正确代码误报，它就等于噪音；如果切分不可靠，它连
    「注入故障后能转红」都做不到——负样本验证会直接把它标成假绿守卫。
    与其继续调参，不如**放弃切分**：本守卫只判断「用例名是否声称了它
    实际测不到的分支」，而这只需要名字，不需要正文。
    """
    names = []
    for i, ln in enumerate(text.split("\n")):
        if not re.match(r"^[ \t]*(?:test|testWidgets)\(", ln):
            continue
        # 名字可能跨行：往后看 4 行找第一个引号字符串。
        for j in range(i, min(i + 4, len(text.split("\n")))):
            m = re.search(r"'([^']*)'", text.split("\n")[j])
            if m:
                names.append("'" + m.group(1) + "'")
                break
    return names


NEGATION_MARKS = ("测不到", "测不了", "无法测", "未覆盖", "拿不到",
                 "不到", "不算", "非成功", "不视为")


def _claims_unreachable_branch(name: str):
    """用例名是否**声称**测了 HTTPS 传输之后的分支（而它其实到不了）。

    为什么不能只看「注释里有没有承认」（2026-10-03 实测踩过）：
    最初判据是「注释里出现『测不到』或『仅允许 HTTPS』就算诚实」。但负样本
    注入把用例名改回「服务器返回 500 抛异常」后，注释里的『仅允许 HTTPS』
    仍在——守卫判它诚实，放过了假绿。**关键词存在不等于诚实**：注释可以
    撒谎，而用例名是测试对外的契约。

    故改为按「名字声称的分支」判定：
      名字里出现 500/4xx/5xx/2xx 等状态码，且**没有**否定声明
      （「测不到」「测不了」「未覆盖」…）→ 声称测了状态码分支，
      而传 HTTP 时必然到不了 → 假绿。

    否定声明必须紧贴该状态码（同一对括号内或用例名末段），否则
    「名字里别处提了一句『测不到』」会把真问题洗白。
    """
    claims = re.search(r"\b([1-5]\d{2})\b", name)
    if not claims:
        return None
    code = claims.group(1)
    if 200 <= int(code) < 300:
        return None  # 2xx 不需要服务器外的分支假设
    # 否定声明须与该状态码**在同一对括号内**（如「（测不到 500 分支）」）。
    # 用固定字数窗口（试过 12 字）不可靠：中文标点与空格会随排版变化，
    # 而「同括号」是语义边界，稳定得多。实测这两种写法必须同判：
    #   合法：「…（测不到 500 分支）」
    #   假绿：「…（另有一处测不到 HTTPS 约束的用例）」——否定词在别的括号里。
    depth = 0
    for ch in name[:claims.start()]:
        if ch == "（":
            depth += 1
        elif ch == "）":
            depth -= 1
    # 两种合法写法都要放行：
    #   a) 否定词与状态码在同一对括号内：「…（测不到 500 分支）」
    #   b) 否定词紧跟在状态码之后：「…199 / 300 不算成功」
    # 只查前缀会漏掉 (b)；固定字数窗口会误伤远处无关的否定词，故按
    # 「同括号 或 紧随其后（到下一个标点为止）」判定。
    tail = name[claims.end():]
    tail = re.split(r"[，,。；;]", tail)[0]
    if depth > 0 or any(m in name[max(0, claims.start() - 6):claims.start()]
                        for m in NEGATION_MARKS) \
            or any(m in tail for m in NEGATION_MARKS):
        return None
    return f"名字声称测 HTTP {code}，但传 http:// 到不了状态码分支（" \
           f"应改为纯函数分项覆盖，或在名字里注明「测不到」）"


class NoFakeGreenCrashUploadTest(unittest.TestCase):
    """崩溃上报测试的假绿防护。"""

    def test_source_exposes_testable_pure_helpers(self):
        """上传主体的纯逻辑必须可独立测试（否则又只能靠假服务器凑覆盖）。"""
        src = SRC.read_text(encoding="utf-8")
        for fn in ("buildCrashPayload", "crashUploadFailureFor"):
            self.assertIn(
                fn, src,
                f"crash_reporter.dart 缺少 {fn}——上传主体应抽出纯逻辑供单测，"
                f"否则 HTTPS-only 设计会让这段代码长期零覆盖")

    def test_status_judgement_is_covered_directly(self):
        """状态码判定必须有直接单测（不依赖起服务器）。"""
        t = _test_text()
        self.assertIn(
            "crashUploadFailureFor", t,
            "crash_reporter_test.dart 未直接测试 crashUploadFailureFor——"
            "500/404 等分支将只能靠 HTTPS 服务器间接覆盖（实际不可行）")

    def test_no_case_name_claims_unreachable_http_branch(self):
        """任何用例名都**不得声称**测了 HTTPS-only 设计下到不了的分支。

        判据只看用例名，不需要切分正文——这是刻意的简化，见 _test_names
        的 docstring：切分 Dart 测试正文在实践中不可靠（连续 5 次误报/漏报），
        而「名字是否说谎」恰好只需要名字即可判断。

        它拦的是本项目真实发生过的假绿：用例名写着「服务器返回 500 抛异常」，
        实则传 http:// 在 enabled 校验处就抛了，500 分支一行没跑到。
        正确写法二选一：
          - 状态码判定由 crashUploadFailureFor 的纯函数用例直接覆盖；
          - 名字里明确注明测不到（如「（测不到 500 分支）」）。

        范围（2026-10-05 扩展）：扫描**所有**调用 uploadCrashLog 的测试文件，
        而不是只有 crash_reporter_test.dart——否则把用例挪个文件就绕过了守卫。
        每个文件仍按原有 skip 规则处理：文件里没有把 http:// 传给
        uploadCrashLog 时，「名字声称到不了的状态码分支」这一前提不成立
        （纯函数文件、假栈 https 文件都属此类），跳过。
        """
        files = _upload_test_files()
        if not files:
            self.skipTest("没有测试文件调用 uploadCrashLog")
        offenders = []
        checked = 0
        for path in files:
            t = path.read_text(encoding="utf-8")
            if "uploadUrl: 'http://" not in t:
                continue
            checked += 1
            rel = path.relative_to(ROOT).as_posix()
            for name in _test_names(t):
                claim = _claims_unreachable_branch(name)
                if claim:
                    offenders.append(f"{rel}: {name} —— {claim}")
        if checked == 0:
            self.skipTest("没有测试用 http:// 调 uploadCrashLog")
        self.assertEqual(
            [], offenders,
            "以下用例名声称测了 HTTPS-only 设计下到不了的分支（假绿形态）："
            f"{offenders}")

    def test_https_only_constraint_is_kept(self):
        """不得为了「让测试跑通」而放松 HTTPS-only 约束。"""
        src = SRC.read_text(encoding="utf-8")
        self.assertIn(
            "uri.scheme.toLowerCase() != 'https'", src,
            "crash_reporter.dart 不再强制 HTTPS——这是远程诊断的安全边界，"
            "不得为了让测试通过而放开")


class _ClaimCheckTest(unittest.TestCase):
    """判据自身的单测——守卫的判据若错，守卫就整体失效。

    这一组的存在本身就是教训：第一版守卫靠「注释里有没有承认」判定诚实性，
    而负样本注入把名字改回「服务器返回 500 抛异常」、注释却仍写着
    「仅允许 HTTPS」时，它把假绿放过了。故判据改看名字，并给判据本身加测。
    """

    def test_name_claiming_500_is_flagged(self):
        self.assertIsNotNone(
            _claims_unreachable_branch("'服务器返回 500 抛异常'"))

    def test_name_declaring_unreachable_is_allowed(self):
        self.assertIsNone(_claims_unreachable_branch(
            "'HTTP 地址被拒绝：抛 HTTPS 约束异常（测不到 500 分支）'"))

    def test_name_without_status_is_allowed(self):
        self.assertIsNone(
            _claims_unreachable_branch("'HTTP 地址被拒绝（不发送请求）'"))

    def test_2xx_is_not_treated_as_status_claim(self):
        self.assertIsNone(_claims_unreachable_branch("'返回 200 视为成功'"))

    def test_negation_must_be_near_the_code(self):
        """否定词离状态码太远（或在同一句的无关分句里）不算数。

        否则一句无关的「测不到」就能洗白假绿——这是守卫最容易被绕过的方式。
        """
        # 反例：否定词出现在**另一个分句**里（逗号之后），与 500 无关。
        self.assertIsNotNone(_claims_unreachable_branch(
            "'服务器返回 500 抛异常；另有一处测不到 HTTPS 约束的用例'"))
        # 反例：否定词在状态码**之前**但相隔太远，不构成对该码的声明。
        self.assertIsNotNone(_claims_unreachable_branch(
            "'这里测不到 HTTPS 分支，另外还要确认服务器返回 500 时会怎样'"))


class _TestNameExtractionTest(unittest.TestCase):
    """用例名提取的回归——切分不可靠，故只取名字，但取名字也要可靠。"""

    def test_extracts_names_including_multiline_declarations(self):
        text = (
            "void main() {\n"
            "  test('单行声明', () {});\n"
            "  test(\n"
            "    '跨行声明',\n"
            "    () {},\n"
            "  );\n"
            "}\n"
        )
        names = _test_names(text)
        self.assertIn("'单行声明'", names)
        self.assertIn("'跨行声明'", names)

    def test_ignores_non_test_lines(self):
        self.assertEqual([], _test_names("  final group = Group('x');\n"))


if __name__ == "__main__":
    unittest.main()