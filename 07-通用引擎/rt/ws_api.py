# -*- coding: utf-8 -*-
"""ws_api.py —— WebSocket 端点（M4 从 server.py 拆出）

为什么和 HTTP 分开
    WS 是长连接 + 每帧可执行：握手、帧循环、限流（M5 的 200 msg/s）都在这里。
    它和 HTTP 的唯一交集是 handle() 里按 Upgrade 头分流 —— 那一处分流留在
    server.py，正好当两者的分界线。

★ 拆分只搬代码，不改逻辑。
"""
import json
import os
import socket
import time

from config import PB, ws
from net import MAX_WS_MSGS_PER_SEC

__all__ = ["WsMixin"]


class WsMixin:
    # WebSocket 侧方法集合：握手 / 帧循环 / 发送 / 单帧分派。


    def _serve_ws(self, headers, path):
        self.request.sendall(ws.handshake_response(headers))
        # ★ P5：`?bin=1` 走**二进制帧**（省 76~88% 带宽）；默认仍是 JSON（好读好调）
        bin_mode = "bin=1" in path
        enc = PB.BinEncoder() if bin_mode else None
        self.request.settimeout(0.05)
        with self.hub.lock:
            self.hub.clients += 1
            cid = self.hub.clients
            self.hub.client_ids[cid] = path
        # ★★ 把连接号挂到 self 上（2026-10-16 加，修一个**真 bug**）：
        #   `_on_frame` 里的 `targets` 出错分支打印的是 `cid`，而 `cid` 只是**本方法的局部变量**
        #   ⇒ 那里抛 `NameError: name 'cid' is not defined` ⇒ **错误处理路径自己崩了**，
        #     真正的错（下面实测到的 `TimeoutError: timed out`）被 NameError 盖住，
        #     日志里看到的是一句莫名其妙的 NameError。
        #   ★ 这与「失败要吵」是同一条纪律的**反面**：想吵，但吵的机制本身坏了 ——
        #     比不吵更糟，因为它会把人引到错的地方。
        #   （这个 bug 是 `_probe_v5.py` 压出来的：客户端猛发把 send 超时逼出来之后才显形。）
        self.cid = cid
        # ★★ P20：每个连接一个**玩家槽位**。槽位 0 给第一个连接（= 开机那个默认玩家），
        #   所以「只有一个客户端」的行为与多人之前**完全一致**。
        # ★ 从路径里取会话 key（`/ws?bin=1&key=xxxx`）；没有就当匿名连接（每次都是新角色）
        key = None
        if "key=" in path:
            for kv in path.split("?", 1)[-1].split("&"):
                if kv.startswith("key="):
                    key = kv[4:].strip()
        self.key = key or None
        slot = self.hub.alloc_slot(cid, self.key)
        self.slot = slot
        if slot < 0:
            # 同一个 key 已经在别处连着 ⇒ **明确拒绝**（不给角色），而不是让两个人抢一个身体
            print("[player] ⚠ 同一个会话 key 已在别处连接，拒绝第二个（累计 %d 次）"
                  % self.hub.busy_kicks)
            try:
                self._send(json.dumps({"you": None, "busy": True},
                                      separators=(",", ":")).encode("utf-8"))
            except OSError:
                pass
        # ★ 玩家**必须在模拟线程里建**（见 Hub.cmds 注释）；建好后由它把 you 投进本槽位的出箱。
        self.hub.cmds.put(("add_player", slot))
        ver = 0
        try:
            # 先发一帧 hello + 一帧快照，让客户端立刻有画面
            if bin_mode:
                snap, ver = self.hub.latest_snap(0)
                if snap is not None:
                    self._send(enc.encode(snap), binary=True)
            else:
                frame, ver = self.hub.latest(0)
                if frame:
                    self._send(frame)
            # ★ M5：单连接速率窗口（1 s）。超限的**丢弃并计数**，不静默。
            win_start = time.perf_counter()
            win_count = 0
            while True:
                # 1) 收：尽量把已到达的输入都处理掉
                got = False
                try:
                    op, payload = ws.read_frame(self.request)
                    got = True
                    _now = time.perf_counter()
                    if _now - win_start >= 1.0:
                        win_start, win_count = _now, 0
                    win_count += 1
                    if win_count > MAX_WS_MSGS_PER_SEC:
                        # 丢弃这一条（不派发），但仍然继续发帧 —— 客户端不会因此「看起来断线」。
                        with self.hub.lock:
                            self.hub.rate_limited += 1
                    else:
                        self._on_frame(op, payload)
                except socket.timeout:
                    pass
                except ws.WSError as e:
                    # ★ 坏帧**显式计数**，不静默（本工程纪律）
                    self.hub.dropped_bad_frames += 1
                    print("[ws] 客户端 %d 坏帧: %s" % (cid, e))
                    return
                except Exception as e:                          # noqa: BLE001
                    # ★★ 除 WSError 之外的异常，原来会被外层 `except (ConnectionError, OSError)`
                    #   当成「连接结束」吞掉 —— 于是「收帧/派发里写错一行」表现成
                    #   「客户端莫名断线」，服务端日志干净得像没事（今天就栽在这上面）。
                    #   ⇒ 显式区分，并在 `RT_DBG_WS=1` 时打全栈。
                    if os.environ.get("RT_DBG_WS"):
                        import traceback
                        print("[WSDBG] 客户端 %s 收帧失败：%s: %s" % (cid, type(e).__name__, e))
                        traceback.print_exc()
                    raise
                # 2) 发：有新帧就发
                if bin_mode:
                    snap, nver = self.hub.latest_snap(ver)
                    if snap is not None:
                        self._send(enc.encode(snap), binary=True)
                        ver = nver
                else:
                    frame, nver = self.hub.latest(ver)
                    if frame is not None:
                        self._send(frame)
                        ver = nver
                if not got:
                    time.sleep(0.005)
        except (ConnectionError, OSError):
            pass
        finally:
            # ★ 断开就把这个槽位的玩家删掉（**槽位 0 除外** —— 它是默认玩家，删了世界就空了）
            # ★ 入队已经在 release_slot 里做了（与回收同锁，避免 add/remove 顺序翻转）
            self.hub.release_slot(cid)
            with self.hub.lock:
                self.hub.clients -= 1
                self.hub.client_ids.pop(cid, None)

    def _send(self, data: bytes, binary: bool = False):
        """下发一帧。★ binary=True 时必须用 **opcode=2（二进制帧）**：
        否则浏览器会把二进制载荷当**字符串**收（`binaryType='arraybuffer'` 也就
        永远不会触发），客户端解出来是乱码 —— 而服务端这边看不出任何异常。
        第一版就是忘了传这个标志，帧的魔数明明写着 'RT'，客户端却拿不到 ArrayBuffer。"""
        self.request.sendall(ws.encode_frame(data, ws.OP_BIN if binary else ws.OP_TEXT))
        with self.hub.lock:
            self.hub.frames_sent += 1
            self.hub.bytes_sent += len(data)

    def _on_frame(self, op, payload):
        if op == ws.OP_PING:
            self.request.sendall(ws.encode_frame(payload, ws.OP_PONG))
            return
        if op == ws.OP_CLOSE:
            raise ConnectionError("client closed")
        if op != ws.OP_TEXT:
            return
        try:
            msg = json.loads(payload.decode("utf-8"))
        except Exception:                                        # noqa: BLE001
            self.hub.dropped_bad_frames += 1
            print("[ws] 坏 JSON 帧（已丢弃并计数）")
            return
        # 前向兼容：未知字段**不崩**
        if "cmd" in msg and str(msg["cmd"]) == "whoami":
            # ★★「我是谁」= **拉取**（见 Hub.__init__ 的注释）：客户端连上就问，
            #   这里**就地**从 slot_guid 取答案回过去。玩家可能还没建出来
            #   （模拟线程异步建的）⇒ 如实回 `null`，客户端过一会儿再问。
            slot_no = getattr(self, "slot", 0)
            busy = slot_no is not None and slot_no < 0
            guid = None
            if not busy:
                with self.hub.lock:
                    guid = self.hub.slot_guid.get(slot_no)
            self._send(json.dumps({"you": (int(guid) if guid is not None else None),
                                   "slot": (slot_no if slot_no is not None else -1),
                                   "busy": bool(busy)},
                                  separators=(",", ":")).encode("utf-8"))
            return
        if "cmd" in msg and str(msg["cmd"]) == "me":
            # ★ P39：玩家自身状态（血/饿/理智/背包）—— 与 targets 同一个拉取模式。
            #   为什么走 WS 而不走 HTTP：它跟 `targets` 是**同一次 HUD 刷新**要的两半，
            #   分开两条链路会让「什么能砍」与「我还剩多少血」不同步到肉眼可见。
            sl = getattr(self, "slot", 0)
            with self.hub.lock:
                st = self.hub.me_by_slot.get(sl)
                g_now = self.hub.slot_guid.get(sl)
            # ★★★ 2026-10-18（基线跑出来的**真缺陷**）：缓存是按**槽位**存的，
            #   而槽位会换主人 —— 上一个角色被回收、这个槽位分给了新连接，
            #   在下一轮刷新（≤0.27 s）之前，缓存里躺着的仍是**上一个角色**的血/饿/背包，
            #   而且 `ok` 还是 `true` ⇒ 新客户端会看到**别人的（甚至已死角色的）**状态。
            #   实测现场：`E10` 单跑绿、整轮跑红 —— 因为整轮里前面几条判据
            #   （D2 的宽限期回收）刚好在槽位 1 上制造了「换主人」，
            #   于是 me 报 ok=true（旧角色）、/healthz 的 stats.players 里根本没有槽位 1。
            #   ⇒ 缓存条目自带 `guid`，回包前与 `slot_guid` 对账；对不上就**说还在算**，
            #     不编、也不给旧数据（「词在≠行为在」的同款：有字段 ≠ 那个字段说的是你）。
            if st is not None and g_now is not None and st.get("guid") != g_now:
                st = None
            if st is None:
                # ★ 还没算出来（刚连上 / 刚换角色）时说「稍后再问」，**不编一个 0 血**
                st = {"ok": False, "why": "还没算出来（稍后再问）", "slot": sl}
            try:
                self._send(json.dumps({"me": st}, separators=(",", ":"),
                                      ensure_ascii=False).encode("utf-8"))
            except OSError as e:
                print("[ws] 客户端 %s 回 me 失败（连接要断了）：%s: %s"
                      % (getattr(self, "cid", "?"), type(e).__name__, e))
            except Exception as e:                              # noqa: BLE001
                print("[ws] ✘ 回 me 序列化失败：%s: %s（缓存里是 %s）"
                      % (type(e).__name__, e, type(st).__name__))
                self.hub.dropped_bad_frames += 1
            return
        if "cmd" in msg and str(msg["cmd"]) == "targets":
            # ★ P22：可交互目标 + 最近一次动作结果（**拉取**，与 whoami 同一个理由）
            sl = getattr(self, "slot", 0)
            with self.hub.lock:
                tg = self.hub.targets_by_slot.get(sl) or []
                last = self.hub.act_result.get(sl)
            try:
                self._send(json.dumps({"targets": tg, "last_act": last},
                                      separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
            except OSError as e:
                # ★ 用 `getattr(self, "cid", "?")`：`cid` 在**另一个方法**里是局部变量，
                #   直接用会 NameError（把真正的错盖掉）—— 见 `_serve_ws` 里挂 self.cid 的说明。
                print("[ws] 客户端 %s 回 targets 失败（连接要断了）：%s: %s"
                      % (getattr(self, "cid", "?"), type(e).__name__, e))
            except Exception as e:                              # noqa: BLE001
                # ★ 序列化失败**必须说清**：否则表现成「客户端莫名断线」
                print("[ws] ✘ 回 targets 序列化失败：%s: %s（缓存里是 %s）"
                      % (type(e).__name__, e, type(tg).__name__))
                self.hub.dropped_bad_frames += 1
            return
        if "cmd" in msg and str(msg["cmd"]) == "act":
            sl = getattr(self, "slot", 0)
            if sl is not None and sl >= 0:
                try:
                    self.hub.cmds.put(("act", sl, int(msg.get("v"))))
                except (TypeError, ValueError):
                    self.hub.dropped_bad_frames += 1
            return
        if "cmd" in msg and str(msg["cmd"]) == "unact":
            sl = getattr(self, "slot", 0)
            if sl is not None and sl >= 0:
                self.hub.cmds.put(("unact", sl))
            return
        if "cmd" in msg and str(msg["cmd"]) == "ping":
            # ★★ 应用层 ping（计划 §4 的 2.4 要「延迟」）：浏览器 WebSocket **不暴露**
            #   ping/pong 帧，所以只能在应用层做。
            #   ⚠️ 直接在**本线程**回包是**安全的**：这条连接的读写都在这一个处理线程里
            #   （见 _serve_ws 的循环），所以不会与「广播快照」的交错写在同一 socket 上。
            #   ⇒ 若哪天广播改成别处写，这里必须一起改，否则会出现**半个 JSON 帧**。
            self._send(json.dumps({"pong": msg.get("v"), "st": time.time()},
                                  separators=(",", ":")).encode("utf-8"))
            return
        if "cmd" in msg:
            # ★ 控制指令（与「输入」分开）：`{"cmd":"pause","v":1}`。
            #   为什么不在 `k` 那条路上做：`k` 会被**原样**当成输入键名塞进输入层，
            #   于是 `cmd` 会被记成一个叫 "cmd" 的按键（症状很怪：TheInput 里多个怪键名）。
            cmd = str(msg["cmd"])
            if cmd == "pause":
                self.hub.set_paused(bool(msg.get("v", 1)))
            else:
                self.hub.dropped_bad_frames += 1
                print("[ws] 未知控制指令（已计数）: %r" % cmd)
        elif "k" in msg:
            # ★ P20：输入**必须带上「是谁按的」** —— 否则四个客户端共用一个玩家
            # ★ P21：被拒（busy，slot<0）的连接**不产生输入** —— 它没有角色可以动
            sl = getattr(self, "slot", 0)
            if sl is not None and sl >= 0:
                self.hub.inputs.put((sl, str(msg["k"]), bool(msg.get("v", 1))))
        elif "keys" in msg:
            for k, v in (msg["keys"] or {}).items():
                self.hub.inputs.put((getattr(self, "slot", 0), str(k), bool(v)))
        else:
            self.hub.dropped_bad_frames += 1
