# -*- coding: utf-8 -*-
"""repro_v5.py —— §9v.5 的可重复复现尝试（第 3 次）

背景（§9v.5 / §9af.1）
    症状：客户端连上后**立刻连续猛发 `targets` + 紧循环读帧**（不等、不睡），
          服务端 tick 几乎不涨（实测 6 秒从 10 涨到 11）。
    历史：P22 观察到现象但根因未定；P31 用 `_probe_v5.py` 造同样条件**没复现**，
          脚本当时随手删了 ⇒ 下次要再试只能重写。

本工具要解决的就是最后那半句：**把复现条件固化成可重复执行的脚本**。
    两种节奏跑同一个服务端，对比 tick 增速：
      · burst —— 猛发（无 sleep）+ 紧循环读帧，即 §9v.5 的原始条件
      · paced —— 读线程 + 每 0.7 s 发一次，即真实客户端的做法（对照组）
    若 burst 出现「某秒 tick 增量 < 阈值」而 paced 正常 ⇒ 复现。
    若两者都正常 ⇒ 未复现（如实记录，不粉饰）。

用法
    python tools/repro_v5.py                       # 默认：起服务端，跑 burst
    python tools/repro_v5.py --both --rounds 3     # 两种节奏各 3 轮（推荐）
    python tools/repro_v5.py --port 18999 --seconds 12 --stall 5
    python tools/repro_v5.py --join 18999          # 连已有服务端，不自己起

退出码
    0 = 未复现（所有轮次都没出现 tick 停滞）
    1 = 复现（至少一轮出现停滞）—— 此时脚本会把该轮的秒级序列打出来
    2 = 环境/参数错误（起不来、连不上、healthz 不通）
"""
import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)          # 07-通用引擎
RT = os.path.join(PROJECT, "rt")         # server.py / ws.py 都在这里
if RT not in sys.path:
    sys.path.insert(0, RT)

# ★★ P50⑲：`/healthz` 走 urllib 连**本机**服务端 —— 不该被环境里的 http_proxy 接管。
#   否则「服务端不在」会被代理翻译成 **502**，本工具会把「环境错误」报成「复现了」。
os.environ["no_proxy"] = "127.0.0.1,localhost"
os.environ["NO_PROXY"] = "127.0.0.1,localhost"


# ---------------------------------------------------------------------------
# WebSocket 最小客户端（与 tests/test_stress.py 同一套做法：手写，不引三方库）
# ---------------------------------------------------------------------------
def _recv_exact(sock, n, timeout=5.0):
    """精确读 n 字节。★ 一次 recv 只保证「至少 1 字节」，TCP 会拆包。"""
    sock.settimeout(timeout)
    buf = b""
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c:
            raise RuntimeError("连接在读到 %d/%d 字节时关闭" % (len(buf), n))
        buf += c
    return buf


def _recv_frame(sock, timeout=5.0):
    h = _recv_exact(sock, 2, timeout)
    b0, b1 = h[0], h[1]
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", _recv_exact(sock, 2, timeout))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", _recv_exact(sock, 8, timeout))[0]
    d = _recv_exact(sock, ln, timeout) if ln else b""
    return b0 & 0x0F, d


def _send_text(sock, text):
    import ws
    sock.sendall(ws.encode_frame_masked(text.encode("utf-8")))


def _connect(port):
    import ws
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    ws.client_handshake(s, "127.0.0.1:%d" % port, "/ws")
    return s


def _healthz(port, timeout=3.0):
    with urllib.request.urlopen("http://127.0.0.1:%d/healthz" % port, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


# ---------------------------------------------------------------------------
# 服务端生命周期
# ---------------------------------------------------------------------------
def start_server(port, world_content=None):
    env = dict(os.environ)
    env.pop("RT_SPAWN", None)
    if world_content is not None:
        env["RT_WORLD_CONTENT"] = str(world_content)
    logpath = os.path.join(tempfile.gettempdir(), "rt_repro_v5_%d.log" % port)
    lf = open(logpath, "w", encoding="utf-8")
    proc = subprocess.Popen(
        [sys.executable, "-u", os.path.join(RT, "server.py"),
         "--port", str(port), "--hz", "30"],
        stdout=lf, stderr=subprocess.STDOUT, cwd=RT, env=env, text=True)
    for _ in range(400):
        if proc.poll() is not None:
            raise RuntimeError("服务端启动即退出，日志：%s" % logpath)
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return proc, lf, logpath
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("40 s 内未监听，日志：%s" % logpath)


# ---------------------------------------------------------------------------
# 一轮测量
# ---------------------------------------------------------------------------
def one_round(port, mode, seconds, stall_thresh):
    """跑一轮，返回 (每秒 tick 增量列表, 统计)。

    burst：主线程紧循环读帧，另一个线程无 sleep 猛发 targets。
    paced：一个读线程持续读，主线程每 0.7 s 发一次 targets（对照组）。
    """
    sock = _connect(port)
    stop = threading.Event()
    stats = {"sent": 0, "recv": 0, "recv_err": None}

    def reader():
        while not stop.is_set():
            try:
                _op, _d = _recv_frame(sock, 1.0)
                stats["recv"] += 1
            except socket.timeout:
                continue
            except Exception as e:                        # noqa: BLE001
                stats["recv_err"] = "%s: %s" % (type(e).__name__, e)
                return

    rt = threading.Thread(target=reader, daemon=True)
    rt.start()

    # 预热：等第一帧快照到，避免把启动抖动算进第一秒
    time.sleep(1.0)
    # ★ tick 在 stats 里，不在顶层（第一版写成顶层 ⇒ KeyError；/healthz 的顶层只有 ok/world/…）
    t0 = _healthz(port)["stats"]["tick"]
    samples = [t0]
    sender_err = []

    if mode == "burst":
        def burst():
            # ★ §9v.5 的原始条件：**不等、不睡**地猛发
            while not stop.is_set():
                try:
                    _send_text(sock, json.dumps({"cmd": "targets"}))
                    stats["sent"] += 1
                except Exception as e:                    # noqa: BLE001
                    sender_err.append("%s: %s" % (type(e).__name__, e))
                    return
        th = threading.Thread(target=burst, daemon=True)
        th.start()
    else:
        # 对照组：真实客户端节奏（每 0.7 s 一次，与 client.html 的 actPoll 一致）
        def paced():
            while not stop.is_set():
                try:
                    _send_text(sock, json.dumps({"cmd": "targets"}))
                    stats["sent"] += 1
                except Exception as e:                    # noqa: BLE001
                    sender_err.append("%s: %s" % (type(e).__name__, e))
                    return
                time.sleep(0.7)
        th = threading.Thread(target=paced, daemon=True)
        th.start()

    for _ in range(seconds):
        time.sleep(1.0)
        try:
            samples.append(_healthz(port)["stats"]["tick"])
        except Exception as e:                            # noqa: BLE001
            samples.append(None)
            sender_err.append("healthz 失败：%s" % e)

    stop.set()
    deltas = []
    for i in range(1, len(samples)):
        if samples[i] is None or samples[i - 1] is None:
            deltas.append(None)
        else:
            deltas.append(samples[i] - samples[i - 1])
    stalled = [i + 1 for i, d in enumerate(deltas) if d is not None and d < stall_thresh]
    try:
        sock.close()
    except Exception:                                     # noqa: BLE001
        pass
    return {
        "mode": mode, "samples": samples, "deltas": deltas,
        "stalled_sec": stalled, "sent": stats["sent"], "recv": stats["recv"],
        "recv_err": stats["recv_err"], "send_err": sender_err[:3],
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="§9v.5 复现尝试（可重复执行）")
    ap.add_argument("--port", type=int, default=18931)
    ap.add_argument("--seconds", type=int, default=12, help="每轮采样秒数")
    ap.add_argument("--stall", type=int, default=5, help="tick 增量低于此值即视为停滞")
    ap.add_argument("--rounds", type=int, default=1)
    ap.add_argument("--both", action="store_true", help="burst 与 paced 都跑（推荐）")
    ap.add_argument("--join", type=int, default=None, help="连已有服务端端口，不自己起")
    ap.add_argument("--world-content", type=int, default=None)
    args = ap.parse_args(argv)

    modes = ["burst", "paced"] if args.both else ["burst"]
    own = args.join is None
    port = args.join or args.port
    proc = lf = None
    if own:
        try:
            proc, lf, logpath = start_server(port, args.world_content)
        except Exception as e:                            # noqa: BLE001
            print("REPRO=2 起服务端失败：%s" % e)
            return 2
    else:
        logpath = "(外部服务端)"

    results = []
    try:
        try:
            _healthz(port)
        except Exception as e:                            # noqa: BLE001
            print("REPRO=2 /healthz 不通：%s" % e)
            return 2
        for r in range(args.rounds):
            for mode in modes:
                res = one_round(port, mode, args.seconds, args.stall)
                res["round"] = r + 1
                results.append(res)
                tag = "复现" if res["stalled_sec"] else "正常"
                ds = ",".join("-" if d is None else str(d) for d in res["deltas"])
                print("  [第%d轮/%s] %s  每秒增量=[%s]  发送=%d 收帧=%d%s"
                      % (r + 1, mode, tag, ds, res["sent"], res["recv"],
                         ("  收帧错误：" + res["recv_err"]) if res["recv_err"] else ""))
                for se in res["send_err"]:
                    print("        发送侧：%s" % se)
    finally:
        if own:
            try:
                proc.terminate()
                proc.wait(timeout=8)
            except Exception:                             # noqa: BLE001
                try:
                    proc.kill()
                except Exception:                         # noqa: BLE001
                    pass
            if lf:
                lf.close()

    bad = [r for r in results if r["stalled_sec"]]
    print("")
    print("服务端日志：%s" % logpath)
    if bad:
        print("REPRO=1 复现：%d/%d 轮出现 tick 停滞（阈值 <%d 增量/秒）"
              % (len(bad), len(results), args.stall))
        for r in bad:
            print("  第%d轮/%s 停滞在第 %s 秒" % (r["round"], r["mode"], r["stalled_sec"]))
        return 1
    lo = min((min(d for d in r["deltas"] if d is not None) for r in results
              if any(d is not None for d in r["deltas"])), default=None)
    print("REPRO=0 未复现：%d 轮全部正常（最低单秒增量 %s）" % (len(results), lo))
    return 0


if __name__ == "__main__":
    sys.exit(main())
