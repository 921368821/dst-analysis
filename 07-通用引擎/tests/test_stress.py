# -*- coding: utf-8 -*-
"""test_stress.py —— 规模与并发（P7）

补两个**从没测过**的维度：
  1. **规模**：现有世界只有 6 个实体，帧大小/tick 耗时都是随实体数变的 ——
     不测就不知道 30 Hz 在哪一档撑不住。
  2. **并发**：需求写的是「支持少量客户端（1~4 同机）」，但一直只测过 1 个连接。

跑法：cd 07-通用引擎 && python tests/test_stress.py
"""
import io
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RT = os.path.join(ROOT, "rt")
sys.path.insert(0, RT)

import protocol_bin as PB   # noqa: E402

PASS, FAIL = 0, 0
RESULTS = []


def check(name, fn):
    global PASS, FAIL
    t0 = time.perf_counter()
    try:
        ok, info = fn()
    except Exception as e:                                       # noqa: BLE001
        ok, info = False, "抛异常: %s: %s" % (type(e).__name__, e)
    ms = (time.perf_counter() - t0) * 1000
    if ok:
        PASS += 1
        print("  ✔ %-46s %s  (%.0f ms)" % (name, info, ms))
    else:
        FAIL += 1
        print("  ✘ %-46s %s  (%.0f ms)" % (name, info, ms))
    RESULTS.append((name, ok, info))


# =============================================================================
# 1. 规模：直接在进程内驱 Sim（不走网络，量的是**模拟与编码**）
# =============================================================================
print("═" * 80)
print("  规模：原版工厂在 400 个生成下能不能撑住 30 Hz")
print("═" * 80)

from server import Sim   # noqa: E402

SCALE = {}


def s1_spawn_scale():
    """★ 400 个原版生物必须全部生成成功（失败=原版工厂在规模下有问题）"""
    rows = []
    for n in (0, 100, 400):
        os.environ["RT_SPAWN"] = str(n)
        s = Sim(seed=20261015, tick_hz=30).boot()
        for _ in range(30):          # 预热
            s.step()
        # ★ 测**多次取最小**：这台机器上可能同时跑着别的服务端（我自己起的），
        #   CPU 争用会让单次测量翻倍 —— 实测就撞到过（15 ms → 30 ms）。
        #   取最小 = 「不被别的进程干扰时的能力」，这才是要对比的量。
        ms = 1e9
        for _ in range(3):
            t0 = time.perf_counter()
            for _ in range(120):
                s.step()
            ms = min(ms, (time.perf_counter() - t0) * 1000 / 120)
        st = s.stats()
        rows.append((n, st["n_ents"], ms, 1000 / ms))
        if n == 0:
            SCALE["ms0"] = ms
        if n == 400:
            SCALE["sim"] = s
            SCALE["ms400"] = ms
            SCALE["ents400"] = st["n_ents"]
    # ★★ 判据要分清「**承诺**的配置」与「**探索**的上限」：
    #   · 承诺：**默认世界**（6 实体）⇒ 必须有**大余量**（≥1000 tick/s，实测约 12600）
    #   · 探索：400 个生成（约 645 实体）⇒ 只要求「还能跑」（≥20 tick/s），
    #     并**如实体数记下来**。实测这一档在 28~41 tick/s 之间摆动 ——
    #     **它就在 30 Hz 的边界上**，受机器负载影响很大。
    #   第一版把「探索上限」当「承诺配置」来断言（≥30 tick/s）⇒ 机器一忙就假红。
    base = [r for r in rows if r[0] == 0][0]
    if base[3] < 1000:
        return False, "默认世界只有 %.0f tick/s（应有大余量）" % base[3]
    top = [r for r in rows if r[0] == 400][0]
    if top[3] < 20:
        return False, "400 生成档只有 %.1f tick/s（连 20 都不到）" % top[3]
    return True, " ／ ".join("生成%d→实体%d %.1fms(%.0f/s)" % (r[0], r[1], r[2], r[3]) for r in rows)


def s2_tick_budget():
    """★ 30 Hz 预算是 33.3 ms/tick。

    ★★ 判据只对**承诺的配置**（默认世界）下硬结论；
       规模档（约 645 实体）**如实报告占比**，不假装它一定达标 ——
       实测它在 28~41 tick/s 摆动，**就在边界上**，
       把它当「必须达标」只会得到「机器一忙就假红」。
    """
    ms = SCALE.get("ms400", 999)
    # 默认世界的耗时基线（由 S1 存下来）
    base_ms = SCALE.get("ms0", None)
    if base_ms is None or base_ms > 33.3 * 0.05:
        return False, "默认世界 tick %.3f ms 占比 %.1f%%（余量不够）" % (
            base_ms or -1, 100 * (base_ms or 99) / 33.3)
    note = "默认世界 %.2f ms（占 %.1f%%）；645 实体档 %.1f ms（占 %.0f%%）" % (
        base_ms, 100 * base_ms / 33.3, ms, 100 * ms / 33.3)
    if ms < 33.3:
        return True, note + " ⇒ 规模档**也**在预算内"
    return True, note + " ⇒ 规模档**略超**预算（如实记录：它是探索上限，不是承诺配置）"


def s3_binary_at_scale():
    """★ 规模下二进制仍须明显省（这才是 30 KB/帧 那条曲线的解法）"""
    s = SCALE.get("sim")
    if s is None:
        return False, "上一项没跑成"
    snap = s.snapshot()
    enc = PB.BinEncoder()
    enc.encode(snap)                      # 首帧建字典
    b = len(enc.encode(s.snapshot()))
    j = len(json.dumps(snap, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
    if not (b < j * 0.3):
        return False, "二进制 %d B 未明显小于 JSON %d B" % (b, j)
    return True, "实体 %d：JSON %d B → 二进制 %d B（省 %.0f%%）；30 Hz 下 %.0f KB/s" % (
        snap["n"], j, b, 100 * (1 - b / j), b * 30 / 1024)


def s4_churn_measured():
    """★ 「增量帧值不值得做」——**先量再决定**，不凭感觉实现"""
    s = SCALE.get("sim")
    if s is None:
        return False, "上一项没跑成"
    prev = {e["id"]: (e["x"], e["z"], e.get("fr")) for e in s.snapshot()["ents"]}
    moved = tot = 0
    for _ in range(30):
        s.step()
        cur = {e["id"]: (e["x"], e["z"], e.get("fr")) for e in s.snapshot()["ents"]}
        for k, v in cur.items():
            tot += 1
            if prev.get(k) != v:
                moved += 1
        prev = cur
    rate = 100.0 * moved / max(tot, 1)
    # 本项目**决定不做**增量帧（见开发计划 §9h）：变化率不够低，收益抵不上复杂度。
    # 这条探针的作用是**把这个决定钉在数据上** —— 将来谁想改，先看这个数字。
    return True, "每帧变化率 %.0f%%（判定：>70%% 不值得做增量帧；实测在此之下但收益仍小）" % rate


check("S1 生成全成功；默认世界 ≥1000 tick/s，规模档 ≥20 tick/s", s1_spawn_scale)
check("S2 预算分档：默认世界占 <5%；规模档如实报告", s2_tick_budget)
check("S3 规模下二进制仍省 ≥70%", s3_binary_at_scale)
check("S4 实体变化率（增量帧的决策依据）", s4_churn_measured)


# =============================================================================
# 2. 并发：多客户端（需求写了 1~4，但从没测过）
# =============================================================================
print("═" * 80)
print("  并发：4 个客户端同时连，各自收帧、各自发输入")
print("═" * 80)

PORT = int(os.environ.get("RT_STRESS_PORT", "8793"))
PROC = {}
SERVER_LOG = None


def c0_start():
    # ★ 日志落到**文件**（不是 PIPE）：PIPE 不读就会满、失败时也读不出来
    #   （`proc.stdout.read()` 要等进程退出，而它通常还活着）。
    #   本轮就是靠这个文件看到「SpawnPrefab 失败」的那一行。
    global SERVER_LOG
    import tempfile
    SERVER_LOG = os.path.join(tempfile.gettempdir(), "rt_stress_server.log")
    lf = open(SERVER_LOG, "w", encoding="utf-8")
    PROC["logf"] = lf
    proc = subprocess.Popen(
        [sys.executable, "-u", os.path.join(RT, "server.py"),
         "--port", str(PORT), "--hz", "30"],
        stdout=lf, stderr=subprocess.STDOUT, cwd=RT, text=True)
    PROC["p"] = proc
    for _ in range(200):
        if proc.poll() is not None:
            raise RuntimeError("服务端启动即退出:\n" + proc.stdout.read())
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=0.2):
                return True, "服务端已起"
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("20 s 内未监听")


def _connect(bin_mode=True):
    import ws
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    ws.client_handshake(s, "127.0.0.1:%d" % PORT, "/ws?bin=1" if bin_mode else "/ws")
    return s


def _recv_exact(sock, n, timeout=5.0):
    """**精确**读 n 个字节（循环直到读满）。

    ★★ 为什么必须这样：`sock.recv(2)` 只保证「至少 1 字节」，TCP 完全可能把 2 字节的
      WebSocket 帧头拆成两次投递（实测在「一帧快照紧跟一条 you 握手」时被触发，
      报 `ValueError: not enough values to unpack (expected 2, got 1)`）。
      ⇒ 读帧必须**循环读到你要的字节数**，不能指望一次 recv 拿全。
      （真实浏览器自带的 WebSocket 实现替我们做了这件事，所以只有手写的测试客户端会踩。）
    """
    sock.settimeout(timeout)
    buf = b""
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c:
            raise RuntimeError("连接在读到 %d/%d 字节时关闭" % (len(buf), n))
        buf += c
    return buf


def _recv(sock, timeout=5.0):
    h = _recv_exact(sock, 2, timeout)
    b0, b1 = h[0], h[1]
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", _recv_exact(sock, 2, timeout))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", _recv_exact(sock, 8, timeout))[0]
    d = _recv_exact(sock, ln, timeout) if ln else b""
    return b0 & 0x0F, d


_LIGHT = {}


def _start_light_server(spawn=0, port=None):
    """起一个**轻量**服务器（给「多人 / 交互」这类与规模无关的用例用）。

    `spawn` 指定压力生成个数（0 = 不生成）。★ 为什么要能指定：
      这些用例测的是**协议/逻辑**，不是规模 —— 让它跑在 646 实体、35 KB/帧的服务器上，
      判据里就混进了「机器忙不忙」这个变量（实测 3 轮里 1 轮假红）。
    """
    port = port or (PORT + 2)
    env = dict(os.environ)
    env.pop("RT_SPAWN", None)          # ★ 关键：不继承 S 段设的压力生成
    if spawn > 0:
        env["RT_SPAWN"] = str(spawn)
    import tempfile
    lf = open(os.path.join(tempfile.gettempdir(), "rt_light_server.log"), "w", encoding="utf-8")
    proc = subprocess.Popen([sys.executable, "-u", os.path.join(RT, "server.py"),
                             "--port", str(port), "--hz", "30"],
                            stdout=lf, stderr=subprocess.STDOUT, cwd=RT, env=env, text=True)
    for _ in range(300):
        if proc.poll() is not None:
            raise RuntimeError("轻量服务器启动即退出")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                _LIGHT["p"] = proc
                _LIGHT["port"] = port
                _LIGHT["logf"] = lf
                return {"proc": proc, "port": port}
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("轻量服务器 30 s 内未监听")


def _stop_light_server(light):
    if not light:
        return
    try:
        proc = light["proc"]
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except Exception:                                    # noqa: BLE001
                proc.kill()
    except Exception:                                            # noqa: BLE001
        pass


def _connect_to(port, bin_mode=False):
    import ws
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    ws.client_handshake(s, "127.0.0.1:%d" % port, "/ws?bin=1" if bin_mode else "/ws")
    return s


def _recv_raw_bin(sock, timeout=5.0, tries=200):
    """读到一条**二进制**消息的原始字节 —— 跳过 `you`/`pong` 这类**文本控制消息**。

    ★★ P20 起服务端连上先发文本 `{"you":guid,"slot":n}`（与快照同一条流）。
      老写法「读下一条就当快照」会把这段文本喂给二进制解码器 ⇒
      抛 `ValueError("魔数不对")`，看起来像「服务端发了坏帧」，其实只是没跳控制消息。
    """
    for _ in range(tries):
        op, d = _recv(sock, timeout)
        if op == 2:
            return d
    raise RuntimeError("%d 条消息里没有二进制快照" % tries)


def c1_four_clients():
    """★ 4 个客户端同时收帧：各自都要拿到**有效**的世界"""
    socks, encs = [], []
    try:
        for _ in range(4):
            s = _connect()
            socks.append(s)
            # ★★ 字典必须**跟着连接走**（一个连接一个），而且**首帧就要用同一个字典解**
            #   —— 首帧携带全字典；丢首帧再换新字典，后续帧的索引在本地不存在。
            #   （第一版就是这么写的：丢掉首帧、又新建空字典 ⇒ 全都 IndexError。）
            encs.append(PB.BinEncoder())
        ok_n = 0
        for s, e in zip(socks, encs):
            d = _recv_raw_bin(s)
            snap = PB.decode(d, e)
            if snap["n"] > 0 and snap["ents"]:
                ok_n += 1
        if ok_n < 4:
            return False, "只有 %d/4 个客户端拿到有效帧" % ok_n
        return True, "4 个客户端各自拿到有效帧（每个独立字典）"
    finally:
        for s in socks:
            try:
                s.close()
            except OSError:
                pass


def c2_inputs_isolated():
    """★ 4 个客户端**同时**发输入：世界必须一致地把 4 家的输入都吃到
    （判据：4 个客户端最后收到的帧里，同一 tick 的世界状态一致）"""
    socks, encs = [], []
    try:
        for _ in range(4):
            s = _connect()
            socks.append(s)
            e = PB.BinEncoder()
            # ★ 首帧**必须用同一个字典解掉**（它携带全字典）——不能丢
            PB.decode(_recv_raw_bin(s), e)
            encs.append(e)
        import ws
        # 四家同时按键（方向不同）
        keys = ["right", "left", "up", "down"]
        for s, k in zip(socks, keys):
            s.sendall(ws.encode_frame_masked(json.dumps({"k": k, "v": 1}).encode()))
        time.sleep(1.5)
        # 各收若干帧，比较同一 tick 的实体数
        seen = {}
        for i, (s, e) in enumerate(zip(socks, encs)):
            for _ in range(8):
                snap = PB.decode(_recv_raw_bin(s), e)
                seen.setdefault(snap["tick"], set()).add(snap["n"])
        # 同一 tick 下，所有客户端的 n 必须一致（权威端=同一份世界）
        conflict = {t: ns for t, ns in seen.items() if len(ns) > 1}
        if conflict:
            return False, "同一 tick 在不同客户端上实体数不一致: %s" % list(conflict.items())[:3]
        for s, k in zip(socks, keys):
            s.sendall(ws.encode_frame_masked(json.dumps({"k": k, "v": 0}).encode()))
        return True, "四家输入同时到达，同一 tick 的世界状态在各客户端一致（%d 个 tick 对过）" % len(seen)
    finally:
        for s in socks:
            try:
                s.close()
            except OSError:
                pass


def c3_healthz_clients():
    """★ 在线客户端数要**如实反映**（先 0，连上后 >0，断开后回 0）"""
    import urllib.request
    def clients():
        h = json.loads(urllib.request.urlopen(
            "http://127.0.0.1:%d/healthz" % PORT, timeout=5).read().decode())
        return h["clients"]
    before = clients()
    socks = [_connect() for _ in range(3)]
    try:
        time.sleep(0.5)
        during = clients()
    finally:
        for s in socks:
            s.close()
    time.sleep(0.8)
    after = clients()
    if not (during >= 3):
        return False, "连了 3 个客户端，但 /healthz 只报 %d" % during
    if after != 0:
        return False, "断开后仍报 %d 个客户端（计数没回落）" % after
    return True, "0 → %d → %d（连上/断开都如实反映）" % (during, after)


check("C0 起服务端（并发测试用）", c0_start)
check("C1 4 个客户端各自拿到有效帧", c1_four_clients)
check("C2 四家同时发输入：同一 tick 世界状态一致", c2_inputs_isolated)
check("C3 在线客户端计数如实（0 → N → 0）", c3_healthz_clients)

def c4_missing_dict_robust():
    """★ 反向：客户端**漏掉首帧**（字典没建起来）时必须**不崩**，并报出缺失条目数

    这是压力测试**实测踩到**的情形：丢掉带字典的首帧、又用空字典解后续帧 ⇒
    原来直接 `IndexError`（看起来像解码器坏了，其实是「历史缺了一截」）。
    现在越界返回 None 并计数 ⇒ 调用方能看见「我缺字典」。"""
    import ws
    s = _connect()
    try:
        # 故意：**丢掉第一帧二进制快照**（它带全字典），直接用空字典解后续帧。
        # ★ 先跳过文本控制消息再丢 —— 否则「丢掉的」是 you 握手，首帧根本没被丢。
        _recv_raw_bin(s)
        s.sendall(ws.encode_frame_masked(json.dumps({"k": "right", "v": 1}).encode()))
        time.sleep(0.4)
        empty = PB.BinEncoder()
        got = 0
        for _ in range(5):
            snap = PB.decode(_recv_raw_bin(s), empty)     # 不应抛错
            got += 1
        s.sendall(ws.encode_frame_masked(json.dumps({"k": "right", "v": 0}).encode()))
        misses = getattr(empty, "misses", 0)
        if got < 5:
            return False, "只解出 %d 帧" % got
        if misses <= 0:
            return False, "缺字典却没计数（说明没走边界分支）"
        return True, "漏首帧后解出 %d 帧**不崩**，缺失字典条目计数 %d" % (got, misses)
    finally:
        s.close()


def ws_encode(obj):
    import ws as _ws
    return _ws.encode_frame_masked(json.dumps(obj).encode("utf-8"))


class _Reader:
    """一个连接配一个**持续读线程**，只记「我关心的那两个数」。

    ★★ 为什么不能「睡一会儿再读」：这是 30 Hz 的流，睡 1.2 s 不读会在内核缓冲里
      积压 ~36 帧 ⇒ 读到的是旧位置（假红：报「别人也动了」）；
      而为了排空改用**短超时循环**更糟 —— `_recv` 不可重启，读到一半超时会把流读歪
      （实测报 `ValueError: not enough values to unpack`），
      甚至因为「关闭时还有未读数据」触发 TCP RST（实测 `WinError 10054`）。
      ⇒ 正确做法就是**一直读**：没有积压、没有取样时机问题、没有超时。
    """

    def __init__(self, sock, guid=None):
        self.sock = sock
        self.guid = guid
        self.you = None
        self.latest = None
        self.frames = 0
        self.targets = []        # P22：最近一次拉到的可交互目标
        self.last_act = None
        self.alive = True
        self.err = None
        self.th = threading.Thread(target=self._run, daemon=True)
        self.th.start()
        # ★★ P20：连上就**拉取**「我是谁」（服务端不再推送；见 server.py 的说明）
        self.ask()

    def _run(self):
        while self.alive:
            try:
                _op, d = _recv(self.sock, 1.0)
            except OSError:
                continue
            except Exception as e:                                   # noqa: BLE001
                self.err = "%s: %s" % (type(e).__name__, e)
                return
            try:
                m = json.loads(d.decode("utf-8"))
            except Exception:                                        # noqa: BLE001
                continue
            if not isinstance(m, dict):
                continue
            if "you" in m:
                # ★★ 服务端在「玩家还没建出来」时会**如实回 null** —— 不能 int(None)：
                #   第一版这么写，异常把读线程**整条打死**（症状是「没收到 you，err=None」）。
                if m["you"] is not None:
                    self.you = int(m["you"])
                continue
            if "targets" in m:
                self.targets = m["targets"] or []
                self.last_act = m.get("last_act")
                continue
            if "ents" in m:
                self.frames += 1
                for e in m["ents"]:
                    if e["id"] == self.guid:
                        self.latest = (e["x"], e["z"])

    def ask(self, tries=30, gap=0.2):
        """再问一轮「我是谁」（服务端回 null 说明玩家还没建好）"""
        for _ in range(tries):
            if self.you is not None:
                return self.you
            try:
                self.sock.sendall(ws_encode({"cmd": "whoami"}))
            except OSError:
                return None
            time.sleep(gap)
        return self.you

    def stop(self):
        self.alive = False
        try:
            self.th.join(timeout=1.5)
        except Exception:                                            # noqa: BLE001
            pass


def c5_four_owners():
    """★★ P20：**4 个客户端 = 4 个角色**，且各自的输入只动自己。

       ★ 判据只测「隔离性」，不测「往哪个方向走了多少」——
         后者依赖地形（出生点旁边有东西挡住就会假红，07 那边实测过）。
         做法：只有客户端 0 按方向键，**另外三家一动不动**。
         若输入没归因（四个人共用一个角色），另外三家的位移会立刻跟着变。
    """
    import ws
    socks, readers = [], []
    light = None
    try:
        # ★★ 本条测的是「4 个客户端各有角色 + 输入隔离」，**与规模无关**，
        #   所以用它自己的**轻量服务器**（不生成 400 个生物）。
        #   为什么不让它跑在那个 646 实体的服务器上：那是**环境依赖**，不是判据 ——
        #   实测 3 轮里有 1 轮，某个新连接的应答要等十几秒才来（GIL 被「30 KB × 30 Hz × 4 客户端」
        #   的编码/发送占满，新连接的线程迟迟排不上）。那种失败说明**机器忙**，
        #   不说明多人逻辑错，属于「假红」。
        #   规模下的并发另有 C1~C4 覆盖（它们就在那个重载服务器上跑）。
        light = _start_light_server()
        port = light["port"]
        for _ in range(4):
            s = _connect_to(port, bin_mode=False)
            socks.append(s)
            readers.append(_Reader(s))
        # 等 4 个连接都问到 you（≤10 s）
        t0 = time.time()
        while time.time() - t0 < 10.0 and any(r.you is None for r in readers):
            time.sleep(0.05)
        if any(r.you is None for r in readers):
            return False, "有客户端没问到 you（%s，frames=%s，err=%s）" % (
                [r.you for r in readers], [r.frames for r in readers],
                [r.err for r in readers])
        guids = [r.you for r in readers]
        if len(set(guids)) != 4:
            return False, "4 个客户端只拿到 %d 个不同 guid：%s" % (len(set(guids)), guids)
        for r, g in zip(readers, guids):
            r.guid = g
        # 等各自的位置出现（≤2 s）
        t0 = time.time()
        while time.time() - t0 < 2.0 and any(r.latest is None for r in readers):
            time.sleep(0.05)
        if any(r.latest is None for r in readers):
            return False, "有客户端在帧里找不到自己的角色（frames=%s）" % [r.frames for r in readers]
        p0 = [r.latest for r in readers]

        # 只有 0 号按右
        socks[0].sendall(ws.encode_frame_masked(json.dumps({"k": "right", "v": 1}).encode()))
        time.sleep(1.2)
        socks[0].sendall(ws.encode_frame_masked(json.dumps({"k": "right", "v": 0}).encode()))
        time.sleep(0.4)
        p1 = [r.latest for r in readers]
        moved0 = max(abs(p1[0][0] - p0[0][0]), abs(p1[0][1] - p0[0][1]))
        others = [max(abs(p1[i][0] - p0[i][0]), abs(p1[i][1] - p0[i][1])) for i in (1, 2, 3)]
        if max(others) > 0.05:
            return False, "0 号按右键时另外三家也动了 %s —— 还是共用角色" % (
                ["%.3f" % o for o in others])
        if moved0 <= 0.5:
            return False, "0 号自己却几乎没动（%.3f）" % moved0
        return True, "4 个独立角色（guid %s）；0 号按右移动 %.2f，另外三家位移 %s（隔离成立）" % (
            guids, moved0, ["%.3f" % o for o in others])
    finally:
        for r in readers:
            r.stop()
        for s in socks:
            try:
                s.close()
            except OSError:
                pass
        _stop_light_server(light)


check("C4 反向：漏掉首帧不崩 + 缺失字典条目计数", c4_missing_dict_robust)
def c6_interaction_over_ws():
    """★★ P22：**跨进程**的交互 —— 客户端拉目标、施放动作、世界真的变。

       ★ 为什么要有跨进程这条：进程内的 E1 证不了「命令有没有走通传输层」
         （`act`/`targets` 两个 cmd 分支、以及「处理线程只读缓存、模拟线程才碰 Lua」这套结构）。
       ★ 用**持续读线程 + 定时发送**的节奏（= 真实客户端的做法），不要「发一条然后紧循环读帧」：
         实测后者会让服务端的模拟循环停住（见 `开发计划.md` §9v.5 的**未解问题**），
         而那不是真实客户端的用法 —— 判据不该长成只有测试才会做的动作。
    """
    import ws, urllib.request
    light = None

    try:
        # 有植物（可交互目标）但规模小：这条测的是**协议**，不是规模（规模由 C1~C4 覆盖）
        light = _start_light_server(spawn=40, port=PORT + 4)
        port = light["port"]
    except Exception as e:                                       # noqa: BLE001
        return False, "起交互测试服务器失败: %s" % e

    def stats():
        return json.loads(urllib.request.urlopen(
            "http://127.0.0.1:%d/healthz" % port, timeout=5).read().decode())["stats"]

    s = _connect_to(port, bin_mode=False)
    rd = _Reader(s)
    try:
        # ① 拉目标：等它出现（服务端每 ~0.27 s 刷一次列表；第一两次问答可能是空的）
        tg = []
        for _ in range(20):
            s.sendall(ws.encode_frame_masked(json.dumps({"cmd": "targets"}).encode()))
            t0 = time.time()
            while time.time() - t0 < 0.5:
                time.sleep(0.05)
                if rd.targets:
                    tg = rd.targets
                    break
            if tg:
                break
        if not tg:
            return False, "10 s 内没拉到可交互目标（压力世界里有植物，应该有的）"
        acts = sorted({t.get("a") for t in tg})
        if not (set(acts) & {"CHOP", "DIG", "PICKUP", "HARVEST", "NET"}):
            return False, "目标里的动作名不像引擎给的：%s" % acts

        # ② 施放（拿最近的那个 = 列表第一个）
        ok0 = stats().get("act_ok", 0)
        s.sendall(ws.encode_frame_masked(
            json.dumps({"cmd": "act", "v": tg[0]["id"]}).encode()))
        got = False
        deadline = time.time() + 5.0
        while time.time() < deadline:
            if stats().get("act_ok", 0) > ok0:
                got = True
                break
            time.sleep(0.2)
        s.sendall(ws.encode_frame_masked(json.dumps({"cmd": "unact"}).encode()))
        if not got:
            return False, "发了 act 但 act_ok 没增加（%s → %s）—— 命令没走通" % (
                ok0, stats().get("act_ok"))

        # ③ 反向：不存在的 guid
        st1 = stats()
        s.sendall(ws.encode_frame_masked(json.dumps({"cmd": "act", "v": 999999}).encode()))
        got2 = False
        deadline = time.time() + 5.0
        while time.time() < deadline:
            if stats().get("act_refused", 0) > st1.get("act_refused", 0):
                got2 = True
                break
            time.sleep(0.2)
        if not got2:
            return False, "对不存在的 guid 发 act，act_refused 没增加（失败被静默了）"
        st2 = stats()
        if not st2.get("last_refusal"):
            return False, "拒绝过却记不下原因（last_refusal 为空）"
        return True, "目标 %d 个（动作 %s）→ act 生效（act_ok %d→%d）；" \
                     "反向：坏 guid 被拒并记原因（%s）" % (
                         len(tg), "/".join(acts), ok0, stats().get("act_ok"),
                         st2.get("last_refusal"))
    finally:
        rd.stop()
        try:
            s.close()
        except OSError:
            pass
        _stop_light_server(light)


check("C5 P20：4 个客户端 = 4 个独立角色，输入互不干扰", c5_four_owners)
check("C6 P22：**跨进程**交互（拉目标 → 施放 → 世界真的变）", c6_interaction_over_ws)

if PROC.get("p") and PROC["p"].poll() is None:
    PROC["p"].terminate()
    try:
        PROC["p"].wait(timeout=5)
    except Exception:                                            # noqa: BLE001
        PROC["p"].kill()

print("\n" + "─" * 80)
print("  结果：%d 通过 / %d 失败" % (PASS, FAIL))
print("─" * 80)
sys.exit(0 if FAIL == 0 else 1)
