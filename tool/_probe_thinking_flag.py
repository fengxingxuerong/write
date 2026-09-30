# -*- coding: utf-8 -*-
"""真机探针：诊断「思考链吃满 max_tokens → 正文空」的真正成因。

【背景】真机 verify_effect 跑书出现 45 次 `[diag] 思考链有输出但正文为空`，
章节因场景成批丢失而残缺。Dart 侧 TokenBudget.needsExtraThinkingFlag 认为
部分模型需要两层 thinking 开关，据此曾给 Python 侧补发
`options.Thinking=false`。

【实测结论 2026-09-30】**该假设被推翻，已回退。** 本探针用真实
system(1735 字写作准则) + 真实场景 prompt 跑 8 次，结果：

  短prompt / 1500：不发第二层 → 正文   0（思考链 2044）
                      发第二层 → 正文 332（思考链   89）
  长prompt / 1500：不发 → 正文 784   ｜发 → 正文   0（思考链 2193）
  长prompt / 4000：不发 → 正文 1668  ｜发 → 正文 944
  长prompt / 6000：不发 → 正文 712   ｜发 → 正文   0（思考链 8925）

同一条件下「发/不发」的正文有无是**随机**的；思考链长度在 89~8925 之间
大幅波动。第二层开关既不能稳定关掉 thinking，还会偶发让思考链暴涨到
吃满 max_tokens，把正文挤空——**有害无益**。

【真根因】该端点对 deepseek 系的 enable_thinking=false 不完全生效，思考链
长度不可预测，偶发超过 max_tokens 即正文空。可靠对策只有两条：
  ① max_tokens 给足（实测 4000 时两次都出正文）；
  ② 靠 call_chain 健康池冷却 + 降级换模型（既有机制）。

复跑：python tool/_probe_thinking_flag.py [模型名]
"""
import json
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, "..", "scripts"))

SENSE = "https://token.sensenova.cn/v1/chat/completions"
MODEL = sys.argv[1] if len(sys.argv) > 1 else "deepseek-v4-flash"
MAX_TOKENS = 1500  # 故意给小预算：thinking 关不掉时正文必然被挤空

SYS = "你是一位中文小说作家。只输出正文。"
USER = "写一段约 300 字的武侠场景：少年在雨夜屋檐下拔剑。只输出正文。"


def _key():
    # 优先环境变量，再兜底 .env.local（项目用的是 NOVEL_KEY_SENSE_K1/K2/K3 三把 key）
    for name in ("NOVEL_KEY_SENSE_K1", "NOVEL_KEY_SENSE_K2", "NOVEL_KEY_SENSE_K3"):
        k = os.environ.get(name, "")
        if k:
            return k
    env = os.path.join(ROOT, "..", ".env.local")
    if os.path.exists(env):
        for line in open(env, encoding="utf-8"):
            if "=" not in line:
                continue
            k, _, v = line.partition("=")
            if k.strip().startswith("NOVEL_KEY_SENSE"):
                v = v.strip()
                if v:
                    return v
    return ""


def probe(key, extra_flag, system=None, user=None, max_tokens=None, model=None):
    payload = {
        "model": model or MODEL,
        "messages": [
            {"role": "system", "content": system or SYS},
            {"role": "user", "content": user or USER},
        ],
        "max_tokens": max_tokens or MAX_TOKENS,
        "temperature": 0.8,
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    if extra_flag:
        payload["options"] = {"Thinking": False}
    req = urllib.request.Request(
        SENSE, data=json.dumps(payload).encode("utf-8"), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer %s" % key)
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            d = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:
        return None, "请求失败: %s" % exc
    msg = d.get("choices", [{}])[0].get("message", {})
    return (msg.get("content") or ""), (msg.get("reasoning_content") or "")


def main():
    key = _key()
    if not key:
        print("!! 找不到 API key（试过 NOVEL_KEY_SENSE_K1/K2/K3 / .env.local）")
        return 1

    # ---- 用**真实** system/场景 prompt 复现真机条件 ----
    # 短 prompt 测不出来：真机的 system 有 1735 字写作准则，user 是长场景 prompt，
    # 思考链在这种长输入下会显著变长，才会出现「吃满 max_tokens → 正文空」。
    sys.path.insert(0, os.path.join(ROOT, "..", "scripts"))
    import novel_pipeline as np
    real_sys = np.SYSTEM_PROMPT
    real_user = np.scene_prompt(
        1, 4, "起", "赴约老鸦，获知考核三关与杀手情报",
        ["宿峥携竹简趁夜赴吞星楼后门", "老鸦从暗处现身，交代三关与杀手潜伏"],
        "上一章他刚在藏药阁拿到残缺丹方。", "", "玄幻")

    print("模型：%s" % MODEL)
    print("")
    print("=== 第 1 组：短 prompt（小预算 %d）——首轮探针条件 ===" % MAX_TOKENS)
    for flag in (False, True):
        c, r = probe(key, flag)
        print("  两层开关=%-5s 正文 %4d 字｜思考链 %4d 字"
              % (flag, len(c or ""), len(r or "")))

    print("")
    print("=== 第 2 组：真实长 prompt（system %d 字 + 场景 prompt %d 字）==="
          % (len(real_sys), len(real_user)))
    for mt in (1500, 4000, 6000):
        for flag in (False, True):
            c, r = probe(key, flag, system=real_sys, user=real_user, max_tokens=mt)
            mark = "  <-- 正文空！" if not (c or "").strip() else ""
            print("  max_tokens=%-5d 两层开关=%-5s 正文 %4d 字｜思考链 %4d 字%s"
                  % (mt, flag, len(c or ""), len(r or ""), mark))
        print("")
    return 0


if __name__ == "__main__":
    sys.exit(main())

