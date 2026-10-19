# -*- coding: utf-8 -*-
"""check_protocol.py —— 控制指令三列一致性（2.5 的机械守卫）

要防的事故
    本工程反复出现的形态：**声明在、消费不在**。协议文档里写着 `{"cmd":"me"}`，
    服务端可能早就不认了；或者客户端偷偷发了个没写进文档的命令。
    这种人眼根本看不出来（`client.html` 1500 行、`server.py` 2000 行）。

它做什么
    从三处**各自独立地**提取命令集合，要求三者**完全相等**：
      · `rt/server.py`    —— `str(msg["cmd"]) == "x"` 与 `cmd == "x"` 两种写法
      · `rt/client.html`  —— `cmd: 'x'`
      · `rt/protocol.md`  —— 机器块 `PROTOCOL-CMDS` 里的表

用法
    python tools/check_protocol.py            # 打印三列
    python tools/check_protocol.py --write    # 重写协议文档里的机器块
    python tools/check_protocol.py --check    # 不一致退出 1

★ 为什么文档里的表也要从代码取：手写的表会腐烂。这里让文档**由代码生成**，
  再让 `--check` 拿生成的表跟文档比 —— 一旦有人改了命令没改文档，三件套立刻红。
"""
import io
import os
import re
import sys

TOOLS_ROOT = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOLS_ROOT)          # 07-通用引擎
# ★ 三个路径允许用环境变量覆盖 —— 只为**反向测试**服务（tests/test_protocol_guard_neg.py
#   要把这三份文件复制到临时目录里做定向篡改，证明这条判据**真的会红**）。
#   默认值与原行为逐字一致，不影响正常使用。
# ★★ M4 之后 `server.py` 只剩 `handle()` 分流，**命令分派搬到了 `ws_api.py`**。
#   这里的守卫原来只读 server.py ⇒ 拆分当天就报「服务端 缺少：act me pause ping …」
#   （判据本身没错，是它的**扫描范围**过期了）。改成读「所有可能分派 WS 命令的模块」。
SERVER = os.environ.get("PROTO_SERVER") or os.pathsep.join(
    os.path.join(PROJECT, "rt", f) for f in ("ws_api.py", "server.py"))
CLIENT = os.environ.get("PROTO_CLIENT") or os.path.join(PROJECT, "rt", "client.html")
DOC = os.environ.get("PROTO_DOC") or os.path.join(PROJECT, "rt", "protocol.md")

BEGIN = "<!-- PROTOCOL-CMDS:BEGIN 本块由 tools/check_protocol.py 生成，勿手改 -->"
END = "<!-- PROTOCOL-CMDS:END -->"

# 只有这几条是「拉取式」的（有回包）—— 写进表里，读者一眼能看出哪些是单向的
PULL = {"whoami", "me", "targets"}
CONTROL = {"pause"}          # 控制类（不进 cmds 队列，直接改 hub 状态）


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


# ★ 命令名的字符类：`[A-Za-z_][A-Za-z0-9_]*`，**必须允许数字**。
#   原来三处都写 `[a-z_]+` —— 反向测试当场抓出后果：服务端加一条 `sneak2`，
#   三列**全都看不见它**（正则匹配到 "sneak" 就卡住，然后整体失败不回退，
#   最终一个都捕获不到）⇒ 含数字的命令对这条守卫**完全隐形**，
#   既不报「客户端缺」也不报「文档缺」，`--write` 也不会把它写进表里。
#   这正是本工具要防的"声明在、消费不在"，只不过换成守卫自己犯。
CMD = r"[A-Za-z_][A-Za-z0-9_]*"


def server_cmds():
    # SERVER 可以是**多个文件**（os.pathsep 分隔）：M4 拆分后分派逻辑分散在
    # ws_api.py / server.py，只读一份必然漏。空路径直接跳过（不静默失败：真缺命令会被下面的比对抓到）。
    text = "\n".join(read(p) for p in SERVER.split(os.pathsep) if p and os.path.exists(p))
    found = set(re.findall(r'str\(msg\["cmd"\]\)\s*==\s*"(' + CMD + r')"', text))
    # 控制指令那条分支写成 `cmd = str(msg["cmd"])` 然后 `if cmd == "pause"`
    found |= set(re.findall(r'\bcmd\s*==\s*"(' + CMD + r')"', text))
    return found


def client_cmds():
    return set(re.findall(r"cmd:\s*'(" + CMD + r")'", read(CLIENT)))


def doc_cmds():
    text = read(DOC)
    if BEGIN not in text or END not in text:
        return set()
    block = text[text.index(BEGIN) + len(BEGIN):text.index(END)]
    return set(re.findall(r"^\|\s*`(" + CMD + r")`", block, re.M))


def render(cmds):
    rows = [BEGIN, "",
            "| 命令 | 服务端分发 | 客户端发送 | 回包 | 说明 |",
            "|---|---|---|---|---|"]
    srv, cli = server_cmds(), client_cmds()
    notes = {
        "whoami": "问「我是谁」；服务端**就地应答**（不经过模拟线程）。玩家还没建出来时回 `null`",
        "me": "自身状态（血/饿/理智/背包），与 `targets` 同一次 HUD 刷新拉取",
        "targets": "附近可交互目标 + 最近一次动作结果",
        "act": "对目标施放动作（**单向**，结果靠下一次 `targets` 带回）",
        "unact": "松开时取消持续动作（**单向**）",
        "ping": "应用层心跳（浏览器不暴露 WS 的 ping/pong 帧）",
        "pause": "暂停/恢复模拟（控制类，直接改 hub 状态，不进 `cmds` 队列）",
    }
    for c in sorted(cmds):
        back = "有" if c in PULL else ("—" if c in CONTROL else "无（单向）")
        rows.append("| `%s` | %s | %s | %s | %s |"
                    % (c,
                       "✔" if c in srv else "**✘**",
                       "✔" if c in cli else "**✘**",
                       back,
                       notes.get(c, "<未登记说明>")))
    rows += ["",
             "> `回包` 列：`有` = 服务端会回一条带结果的消息；`无` = 只排队执行，"
             "不回答（要结果就再发一次拉取命令）。",
             "",
             END]
    return "\n".join(rows)


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    srv, cli, doc = server_cmds(), client_cmds(), doc_cmds()
    # ★★★ 真值只有一处：**代码**（服务端 ∪ 客户端）。
    #   第一版写成 `srv | cli | doc` —— 于是文档里多写一条假命令时，
    #   `--write` 会把这条假命令**照抄回文档**（自己证明自己），检查也就永远过。
    #   这正是本工程的老母题：**判据的输入里不能包含被判定对象**。
    allc = srv | cli
    print("服务端 %d：%s" % (len(srv), " ".join(sorted(srv))))
    print("客户端 %d：%s" % (len(cli), " ".join(sorted(cli))))
    print("文档   %d：%s" % (len(doc), " ".join(sorted(doc))))

    if mode == "--write":
        text = read(DOC)
        if BEGIN not in text or END not in text:
            print("✘ 协议文档里没有 PROTOCOL-CMDS 机器块标记")
            return 1
        block = render(allc)
        i = text.index(BEGIN)
        j = text.index(END) + len(END)
        io.open(DOC, "w", encoding="utf-8", newline="").write(text[:i] + block + text[j:])
        print("✔ 已重写 rt/protocol.md 的命令表（%d 条）" % len(allc))
        return 0

    problems = []
    for name, got in (("服务端", srv), ("客户端", cli), ("文档", doc)):
        miss = allc - got
        if miss:
            problems.append("%s 缺少：%s" % (name, " ".join(sorted(miss))))
    if problems:
        for p in problems:
            print("✘ " + p)
        print("  处置：确认是代码漏了还是文档漏了；文档侧可 --write 重生成，"
              "但**先想清楚那条命令该不该存在**")
        return 1
    if doc and render(allc).strip() != read(DOC)[
            read(DOC).index(BEGIN):read(DOC).index(END) + len(END)].strip():
        print("✘ 文档里的命令表与代码不一致（可能是说明列过期）")
        print("  处置：python tools/check_protocol.py --write")
        return 1
    print("✔ 三列一致（%d 条），且文档表与代码同步" % len(allc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
