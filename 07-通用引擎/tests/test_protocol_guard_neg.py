# -*- coding: utf-8 -*-
"""test_protocol_guard_neg.py —— 控制指令三列一致性（tools/check_protocol.py）的**反向测试**

为什么必须有
    「7 条命令三列一致」只有在一个**能红**的判据守着的时侯才算事实。
    而这个工具自己就踩过一次"永远绿"：第一版把真值写成 `srv | cli | doc`
    —— 判据的输入里包含了被判定对象（文档自己），于是 `--write` 会把文档里
    多出来的假命令**照抄回文档**，怎么改都能过。

做法（全部在临时副本上做，不动 rt/ 下的真文件）
    ① 未篡改的副本先跑一遍，必须**是绿的**（否则"改坏也红"什么都没证明）
    ② 客户端偷偷多一条命令      → 红（服务端/文档都缺）
    ③ 文档偷偷少一条命令         → 红
    ④ 改掉说明列（表内容过期）   → 红
    ⑤ 删掉机器块标记             → 红（不能因为"找不到块"就当成空集合放行）
    ⑥ 服务端多一条命令           → 红（客户端/文档缺）

用法
    python tests/test_protocol_guard_neg.py
退出码：0 全部符合预期 / 1 有不符合 / 2 环境缺失
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, "tools", "check_protocol.py")
RT = os.path.join(ROOT, "rt")


def find_py():
    """用当前解释器即可（本脚本本身就用能跑通的 python 启动的）。"""
    return sys.executable


def run(py, d):
    """在临时副本目录 d 上跑一次 --check，返回 (退出码, stdout+stderr)。"""
    env = dict(os.environ)
    env["PROTO_SERVER"] = os.path.join(d, "server.py")
    env["PROTO_CLIENT"] = os.path.join(d, "client.html")
    env["PROTO_DOC"] = os.path.join(d, "protocol.md")
    p = subprocess.run([py, "-u", TOOL], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=env)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def main():
    py = find_py()
    for f in ("server.py", "client.html", "protocol.md"):
        if not os.path.isfile(os.path.join(RT, f)):
            print("✘ 缺少 rt/%s，无法做反向测试" % f)
            return 2

    tmp = tempfile.mkdtemp(prefix="proto_neg_")
    bad = []

    def fresh():
        """每次都从原始文件复制一份干净副本，避免篡改叠加。"""
        d = tempfile.mkdtemp(dir=tmp)
        for f in ("server.py", "client.html", "protocol.md"):
            shutil.copy2(os.path.join(RT, f), os.path.join(d, f))
        return d

    def patch(d, fname, old, new):
        p = os.path.join(d, fname)
        text = open(p, encoding="utf-8").read()
        if old not in text:
            return False
        open(p, "w", encoding="utf-8", newline="").write(text.replace(old, new, 1))
        return True

    try:
        # ---- ① 基准必须绿 ----
        d = fresh()
        rc, out = run(py, d)
        if rc == 0:
            print("基准：退出码 0（%s）" % out.strip().split("\n")[-1])
        else:
            bad.append("基准未通过（退出码 %d）—— 反向测试前提不成立" % rc)
            print("  ✘ 基准 → 退出码 %d\n%s" % (rc, out))

        # ---- ② 客户端偷偷多一条命令 ----
        d = fresh()
        ok = patch(d, "client.html", "cmd: 'ping'", "cmd: 'ping'}, {cmd: 'sneak'")
        if not ok:
            bad.append("篡改锚点失效：client.html 里找不到 `cmd: 'ping'`（判据从此没人守）")
            print("  ✘ 客户端多加命令 → 锚点找不到")
        else:
            rc, out = run(py, d)
            if rc == 1 and "sneak" in out:
                print("  ✔ 客户端偷偷多加一条 → 退出码 1，报出 sneak")
            else:
                bad.append("客户端多加命令没有变红（退出码 %d）" % rc)
                print("  ✘ 客户端多加一条 → 退出码 %d" % rc)

        # ---- ③ 文档偷偷少一条命令 ----
        d = fresh()
        # 删掉文档机器块里 `pause` 那一行
        ok = False
        p = os.path.join(d, "protocol.md")
        text = open(p, encoding="utf-8").read()
        lines = text.split("\n")
        for i, ln in enumerate(lines):
            if ln.startswith("| `pause`"):
                del lines[i]
                ok = True
                break
        if ok:
            open(p, "w", encoding="utf-8", newline="").write("\n".join(lines))
            rc, out = run(py, d)
            if rc == 1 and "文档" in out and "pause" in out:
                print("  ✔ 文档偷偷少一条 → 退出码 1，报出 文档缺少 pause")
            else:
                bad.append("文档少一条命令没有变红（退出码 %d）" % rc)
                print("  ✘ 文档少一条 → 退出码 %d" % rc)
        else:
            bad.append("篡改锚点失效：protocol.md 里找不到 `| `pause`` 行")
            print("  ✘ 文档少一条 → 锚点找不到")

        # ---- ④ 改掉说明列（表内容过期）----
        d = fresh()
        ok = patch(d, "protocol.md", "应用层心跳（浏览器不暴露 WS 的 ping/pong 帧）",
                   "（这段说明被人改过，与代码里的解释不一致）")
        if not ok:
            bad.append("篡改锚点失效：protocol.md 里找不到 ping 的说明列文案")
            print("  ✘ 改说明列 → 锚点找不到")
        else:
            rc, out = run(py, d)
            if rc == 1 and "不一致" in out:
                print("  ✔ 说明列过期 → 退出码 1，报「文档表与代码不一致」")
            else:
                bad.append("说明列过期没有变红（退出码 %d）" % rc)
                print("  ✘ 说明列过期 → 退出码 %d" % rc)

        # ---- ⑤ 删掉机器块标记 ----
        d = fresh()
        ok = patch(d, "protocol.md", "<!-- PROTOCOL-CMDS:BEGIN",
                   "<!-- XPROTOCOL-CMDS:BEGIN")
        if not ok:
            bad.append("篡改锚点失效：protocol.md 里找不到机器块 BEGIN 标记")
            print("  ✘ 删机器块 → 锚点找不到")
        else:
            rc, out = run(py, d)
            if rc == 1:
                print("  ✔ 机器块标记缺失 → 退出码 1（没有把「找不到块」放行成空集合）")
            else:
                bad.append("机器块标记缺失时没有变红（退出码 %d）" % rc)
                print("  ✘ 机器块缺失 → 退出码 %d" % rc)

        # ---- ⑥ 服务端多一条命令 ----
        d = fresh()
        ok = patch(d, "server.py", 'str(msg["cmd"]) == "ping"',
                   'str(msg["cmd"]) == "ping" or str(msg["cmd"]) == "sneak2"')
        if not ok:
            bad.append("篡改锚点失效：server.py 里找不到 ping 的分发分支")
            print("  ✘ 服务端多加命令 → 锚点找不到")
        else:
            rc, out = run(py, d)
            if rc == 1 and "sneak2" in out:
                print("  ✔ 服务端偷偷多加一条 → 退出码 1，报出 sneak2")
            else:
                bad.append("服务端多加命令没有变红（退出码 %d）" % rc)
                print("  ✘ 服务端多加一条 → 退出码 %d" % rc)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("")
    if bad:
        print("✘ %d 项不符合预期：" % len(bad))
        for b in bad:
            print("   - " + b)
        return 1
    print("✔ 反向测试全部符合预期：三列任何一边多/少/改都会红，锚点未过期")
    return 0


if __name__ == "__main__":
    sys.exit(main())
