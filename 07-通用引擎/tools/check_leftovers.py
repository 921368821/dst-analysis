#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_leftovers.py —— 跑完全量之后，**本次新起的服务端口必须已经关掉**（P50⑦）

为什么需要它（2026-10-20 实测）
    `run_all.sh` 全量跑完（17m41s，总判定 ✔）之后，机器上还留着本工程的
    `rt/server.py`：端口 **8791 / 8794 / 8798 都还在 LISTENING**（另有两个
    `tests/test_rt.py` 进程也没退）。危害不止「占内存」：

      1. **日志被污染**：残留服务仍持有 `tee` 的写端，它之后的输出**继续追加进
         `tests/_run_all.log`** —— 实测 ⑤ 组的标题下面跟着 ② 组的 `A1 启动`。
         日志本来是「红了以后现场还在，不必靠重跑猜」，这么一混就没法读了。
      2. **下一轮撞端口**：端口被占 ⇒ 下一次跑在不相干的地方红，看着像代码坏了。
      3. 30 Hz 的世界还在推进（实测单进程 321 MB），跑得越久越糟。

判据
    `--snapshot F`：记下「跑之前就已经在听」的那批 (端口→PID)。
                    人工起的开发服不算本次的账（它在基线里）。
    `--verify F`：跑完再扫，**新出现且还在听**的 ⇒ 列出端口与 PID、终止、退出 1。
    这一条**故意判红**而不是只打 ⚠️：留残留就是失败，与「测试没跑完」同级。

口径（为什么按端口而不按命令行）
    最准的做法是看命令行里的 `rt/server.py`，但本机安全策略**禁用 `wmic`**、
    也禁止从脚本里起 PowerShell ⇒ 拿不到命令行。于是退一步按**端口**判：
      · 默认端口：8765（deploy）/ 8791（test_rt）/ 8793（stress）/ 8799（deploy 测试）
      · 再加整段 8790~8799（`falsify_server` 一类会自己挑号）
    代价：**只看得到在监听的残留**，看不到「不监听端口但没退」的进程。
    这个代价写在注释里，不假装它比实际更强。

用法
    python tools/check_leftovers.py --snapshot tests/_leftovers.json
    python tools/check_leftovers.py --verify   tests/_leftovers.json [--no-kill]
    python tools/check_leftovers.py --selftest     # ★ 自己证明自己有牙（改完这个文件必跑）
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

# 本工程测试/演练会用的端口（见 test_rt.py:571 / test_stress.py:172 /
# test_deploy.py:60 / deploy/start.sh:22）。新增端口记得加，否则漏杀。
FIXED_PORTS = {8765, 8790, 8791, 8792, 8793, 8794, 8795, 8796, 8797, 8798, 8799}


def _scan_windows():
    """`netstat -ano` → {port: pid}（只取 LISTENING）。"""
    try:
        r = subprocess.run(["netstat", "-ano"], capture_output=True, timeout=60)
        txt = r.stdout.decode("utf-8", "replace")
    except Exception:                                            # noqa: BLE001
        return None
    out = {}
    for line in txt.splitlines():
        f = line.split()
        if len(f) < 5 or "LISTENING" not in line.upper():
            continue
        addr, pid = f[1], f[-1]
        m = re.search(r":(\d+)$", addr)
        if not m or not pid.isdigit():
            continue
        port = int(m.group(1))
        if port in FIXED_PORTS:
            out[port] = int(pid)
    return out


def _scan_posix():
    """`ss -ltnp` 或 `netstat -ltnp`。"""
    for cmd in (["ss", "-ltnp"], ["netstat", "-ltnp"]):
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=60)
        except Exception:                                        # noqa: BLE001
            continue
        txt = r.stdout.decode("utf-8", "replace")
        out = {}
        for line in txt.splitlines():
            m = re.search(r":(\d+)\s", line)
            p = re.search(r"pid=(\d+)", line)
            if m and p and int(m.group(1)) in FIXED_PORTS:
                out[int(m.group(1))] = int(p.group(1))
        if out:
            return out
    return None


def scan():
    return _scan_windows() if os.name == "nt" else _scan_posix()


def _alive(pid):
    try:
        if os.name == "nt":
            r = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid],
                               capture_output=True, timeout=20)
            return str(pid) in r.stdout.decode("utf-8", "replace")
        os.kill(pid, 0)
        return True
    except Exception:                                            # noqa: BLE001
        return False


def _kill(pid):
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                           capture_output=True, timeout=20)
        else:
            import signal
            os.kill(pid, signal.SIGTERM)
            time.sleep(0.2)
            if _alive(pid):
                os.kill(pid, signal.SIGKILL)
        return True
    except Exception:                                            # noqa: BLE001
        return False


def leaked_ports(now, base):
    """跑之前就在听、且 **PID 没变**的端口不算本次的账（人工起的开发服不背锅）。

    抽成函数是为了能被 `--selftest` 直接调用：判据的判据不能靠再抄一遍逻辑。
    """
    return {p: pid for p, pid in (now or {}).items() if base.get(p) != pid}


def _free_probe_port(taken):
    """从 8790~8799 里挑一个**当前没在听**的端口（selftest 用，不碰 8765）。"""
    for p in range(8790, 8800):
        if p not in taken:
            return p
    return None


def _hold_port(port):
    """起一个只监听、不退出的进程，用来模拟「残留服务」。"""
    code = ("import socket,time\n"
            "s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)\n"
            "s.bind(('127.0.0.1',%d));s.listen(4)\n"
            "time.sleep(120)\n" % port)
    return subprocess.Popen([sys.executable, "-c", code])


def selftest():
    """★ 自己证明自己有牙（2026-10-20 加）。

    ★★ 为什么必须做：这条判据此前**从没被反向验证过** —— 它只在「本来就没有残留」
      的情况下跑过，而那时它输出 `✔ 都关掉了`，与「它根本不工作」**长得一模一样**。
      本工程已经栽过一次这个形状（`check` 死代码在干净状态下也输出 ✔）。
      三段，全部实测：
        ① 空基线 + 有残留  ⇒ 必须报 1 条，且那个进程真被杀掉
        ② 杀完再验        ⇒ 必须 0 条
        ③ 基线里本来就有（别人的开发服）⇒ 必须 0 条，且那个进程**还活着**（不许误杀）
    ★ 先看环境：若本工程端口本来就有服务在听，直接报「跳过」而不是硬跑 ——
      否则 selftest 会去杀别人正在用的服。
    """
    now = scan()
    if now is None:
        print("  ✘ 扫不出端口表 —— 无法判定（不当作通过）")
        return 2
    mine = leaked_ports(now, {})
    if mine:
        print("  ⊘ 跳过：本工程端口上已经有服务在听（%s）—— "
              "现在跑 selftest 会去杀它" % ", ".join(str(p) for p in sorted(mine)))
        return 0

    p1 = _free_probe_port(set())
    if p1 is None:
        print("  ⊘ 跳过：8790~8799 全被占，腾不出一个探测端口")
        return 0
    bad = []
    h1 = _hold_port(p1)
    try:
        time.sleep(2.0)
        now = scan() or {}
        n1 = leaked_ports(now, {})
        print("  ① 空基线 + 残留 %d：报 %d 条（期望 1）" % (p1, len(n1)))
        if len(n1) != 1 or p1 not in n1:
            bad.append("① 没报到残留 %d（实测 %r）" % (p1, sorted(n1)))
        if not _kill(n1.get(p1) or h1.pid):
            bad.append("① 杀不掉残留进程")
        time.sleep(1.0)
        now = scan() or {}
        n2 = leaked_ports(now, {})
        print("  ② 杀掉后再验：报 %d 条（期望 0）" % len(n2))
        if n2:
            bad.append("② 杀完还报 %r" % sorted(n2))
    finally:
        try:
            h1.terminate()
        except Exception:                                        # noqa: BLE001
            pass

    # ③ 「别人先占着」不算本次的账，且**不许误杀**
    p2 = _free_probe_port({p1})
    if p2 is None:
        print("  ③ 跳过：腾不出第二个探测端口")
    else:
        h2 = _hold_port(p2)
        try:
            time.sleep(2.0)
            base = scan() or {}
            n3 = leaked_ports(base, base)                         # 自己跟自己比 ⇒ 必须空
            print("  ③ 基线里本来就有的 %d：报 %d 条（期望 0）" % (p2, len(n3)))
            if n3:
                bad.append("③ 把基线里的 %d 当成残留了" % p2)
            if h2.poll() is not None:
                bad.append("③ 基线里的进程被杀掉了（误杀别人的开发服）")
            else:
                print("      基线里那个进程还活着 ✔（没被误杀）")
        finally:
            try:
                h2.terminate()
            except Exception:                                    # noqa: BLE001
                pass

    if bad:
        print("  ✘ selftest 不过：%s" % "；".join(bad))
        return 1
    print("  ✔ selftest 三段全过（有残留必报 + 杀得掉 + 基线里的不背锅也不误杀）")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", metavar="FILE")
    ap.add_argument("--verify", metavar="FILE")
    ap.add_argument("--no-kill", action="store_true", help="只报，不终止")
    ap.add_argument("--selftest", action="store_true", help="自己证明自己有牙（会临时起/杀进程）")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.snapshot and not a.verify:
        ap.error("要么 --snapshot，要么 --verify，要么 --selftest")

    now = scan()
    if now is None:
        # ★ 查不到 ≠ 干净：静默返回 0 会让「收尾卫生」变成永绿的装饰。
        print("  ✘ 扫不出端口表（netstat/ss 都不可用）—— **无法判定**，不当作通过")
        return 2

    if a.snapshot:
        with open(a.snapshot, "w", encoding="utf-8") as f:
            json.dump({"ts": time.strftime("%Y-%m-%d %H:%M:%S"),
                       "ports": {str(k): v for k, v in now.items()}},
                      f, ensure_ascii=False, indent=1)
        if now:
            print("  基线：跑之前已有 %d 个端口在听（%s）—— 不算本次的账"
                  % (len(now), ", ".join(str(p) for p in sorted(now))))
        else:
            print("  基线：跑之前没有本工程端口在听")
        return 0

    with open(a.verify, encoding="utf-8") as f:
        base = {int(k): v for k, v in (json.load(f).get("ports") or {}).items()}
    # 同端口同 PID ⇒ 跑之前就在的那个（别人的开发服），不动；
    # 端口原来没在听、或者换了个 PID ⇒ 都是本次留下的。
    # ★ 口径抽成 `leaked_ports`：`--selftest` 必须撞**同一份**逻辑，
    #   否则「判据的判据」验的是另一段代码（等于没验）。
    leaked = leaked_ports(now, base)
    if not leaked:
        print("  ✔ 本次用过的端口都关掉了（基线里的 %d 个与本次无关）" % len(base))
        return 0

    print("  ✘ 跑完后仍有 **%d 个**端口在听（本次留下）：" % len(leaked))
    for port, pid in sorted(leaked.items()):
        was = base.get(port)
        why = "跑之前没在用" if was is None else "跑之前是 PID %d" % was
        print("      127.0.0.1:%-5d PID %-6d (%s)" % (port, pid, why))
    if a.no_kill:
        print("      （--no-kill：没有终止它们）")
        return 1
    killed = [pid for pid in sorted(set(leaked.values())) if _kill(pid)]
    time.sleep(0.5)
    still = [p for p in killed if _alive(p)]
    print("      已终止 %d 个%s" % (len(killed) - len(still),
                                 ("，仍有 %s 在跑" % still) if still else ""))
    print("      ⇒ 残留会让**下一轮撞端口**，并且继续往 tests/_run_all.log 里写（日志串组）")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
