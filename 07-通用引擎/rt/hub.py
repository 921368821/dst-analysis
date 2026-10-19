# -*- coding: utf-8 -*-
"""hub.py —— 共享状态与统计缓存（M4 从 server.py 拆出）

为什么 Hub 要和 Sim 分开
    Sim 归模拟线程独占；Hub 是两边的交界（模拟线程写、处理线程读），
    所有跨线程纪律都压在它身上：一把锁、最新帧、心跳、限流计数。
    这两块混在一个文件里时，「谁能碰谁」只能靠读注释判断。

★ 拆分只搬代码，不改逻辑。
"""
import json
import os
import queue
import threading
import time



# =============================================================================
# Lua 表 -> 纯 Python（存档要过 JSON，嵌套的 _LuaTable 不能直接序列化）
# =============================================================================

def _slots_html(players):
    """把 `stats()["players"]`（按槽位的存活/血量）拼成一行给人看的摘要。

    ★ 为什么要有：`player_alive`/`player_health` 只描述**槽位 0**；
      多客户端时运维需要一眼看到**每个槽位**是死是活 ——
      否则「杀了客户端却报玩家还活着」这种误判会消耗排查时间（E8 就踩过）。
    """
    if not isinstance(players, dict) or not players:
        return "（无）"
    def one(k):
        v = players.get(k) or {}
        # ★ P38：把「在不在光里」也写出来 —— 夜里挨打的**直接原因**就是它，
        #   以前只能靠推断（`LIGHT_STATE` 是引擎内部的局部表）。
        lit = v.get("in_light")
        tag = ""
        if lit is True:
            tag = " ·<span style='color:#3fb950'>在光里</span>"
        elif lit is False:
            tag = " ·<span style='color:#d29922'>不在光里</span>"
        if v.get("alive") is True:
            hp = v.get("health")
            return "<b style='color:#3fb950'>槽%s 活着</b>(%s)%s" % (
                k, ("%.0f" % hp) if isinstance(hp, (int, float)) else "?", tag)
        if v.get("alive") is False:
            return "<b style='color:#f85149'>槽%s 已死亡</b>%s" % (k, tag)
        return "槽%s ?" % k
    return " · ".join(one(k) for k in sorted(players, key=lambda x: int(x)))


def lua_to_py(v, depth=0):
    """递归把 lupa 的 _LuaTable 转成 dict/list。
    ★ 为什么需要：json.dumps 不认 _LuaTable（**嵌套的也不行**）——
      第一次直接 dumps 存档表就是在这里炸的。"""
    if depth > 12:                      # 防御：别把环踩穿
        return "<too-deep>"
    if type(v).__name__ == "_LuaTable":
        try:
            n = len(v)
        except Exception:                                        # noqa: BLE001
            n = 0
        if n > 0:                        # 数组段 -> list
            out = [lua_to_py(v[i], depth + 1) for i in range(1, n + 1)]
            extra = {str(k): lua_to_py(val, depth + 1)
                     for k, val in v.items() if not isinstance(k, int)}
            return {"__array__": out, **extra} if extra else out
        return {str(k): lua_to_py(val, depth + 1) for k, val in v.items()}
    if isinstance(v, (str, int, float, bool)) or v is None:
        return v
    return str(v)


class Hub:
    # 跨线程共享的唯一交汇点：模拟线程写、处理线程读。
    # （原本的类体注释见 M4 之前的 server.py:702 上方）
    def __init__(self):
        self.lock = threading.Lock()
        self.snap = None          # 最近一帧的**快照字典**（二进制客户端要按自己字典重编）
        self.frame = b""          # 最近一帧的 JSON 编码（文本客户端共用）
        self.frame_ver = 0        # 版本号：客户端据此判断「有新帧了」
        self.inputs = queue.Queue()   # 输入事件
        self.clients = 0
        self.client_ids = {}
        self.dropped_bad_frames = 0   # 坏帧计数（**不静默**：会出现在 stats 里）
        self.rate_limited = 0         # ★ M5：被限流丢弃的消息数（同上，必须可见）
        self.frames_sent = 0
        self.bytes_sent = 0
        # ★ 暂停（P3 目标里的「暂停」，2026-10-16 补）：世界时间停住，但**连接与发帧继续**。
        #   状态放在 Hub 里（带锁），因为请求线程写、模拟线程读。
        self.paused = False
        # ★★ P20：玩家槽位。**第一个连上来的客户端拿槽位 0**（= 开机时那个默认玩家），
        #   这样「只有一个客户端」时的行为与多人之前**完全一致**（预测/相机/存档都指着它）。
        self.slot_of = {}          # cid -> slot
        self.slot_guid = {}        # slot -> 实体 guid（模拟线程填，处理线程读）
        self.free_slots = []       # 断开后回收、下次优先复用（免得槽位号无限涨）
        self.next_slot = 1
        # ★★ 世界**变更**命令队列（加/删玩家）。为什么不能直接调：
        #   `Sim` 只有一个 LuaRuntime —— 从 WS 处理线程直接碰 Lua 会和模拟线程抢状态
        #   （这与 /terrain 当初的取舍是同一条：**只有模拟线程能碰 Lua**）。
        self.cmds = queue.Queue()
        self.player_count = 0      # 模拟线程填（给 /status 用）
        # ★★ 会话身份（P21）：客户端带一个稳定的 `key`（浏览器 localStorage 里存的随机串）。
        #   有 key 就能「刷新/掉线后**拿回同一个角色**」：
        #     · `by_key[key] = slot`：key → 槽位
        #     · `slot_key[slot] = key`：反向
        #     · `reserved[slot] = 到期时间`：断线后**保留**这个槽位一小段时间（宽限期），
        #       期间玩家**不删**、槽位**不回收** ⇒ 重连上来还是同一个 guid、同一个位置。
        #   为什么要有宽限期而不是「永不删」：不然每次刷新都留下一个站着的空角色（泄漏）。
        self.by_key = {}
        self.slot_key = {}
        self.reserved = {}         # slot -> 到期时间戳（time.time()）
        self.reconnect_grace = float(os.environ.get("RT_RECONNECT_GRACE", "60"))
        self.busy_kicks = 0        # 同一个 key 同时连第二个客户端时的拒绝计数
        # ★ P22：交互。目标列表由**模拟线程**算好放这里，处理线程只读 ——
        #   与谁处理 whoami 同一个理由：**只有模拟线程能碰 Lua**。
        self.targets_by_slot = {}  # slot -> [ {id,p,x,z,a}, ... ]（按距离升序）
        self.act_result = {}       # slot -> {"ok":bool, "msg":str}（最近一次动作结果）
        # ★ 2026-10-18 审计修：`/status` 与 `/healthz` 原先在处理线程里直接调
        #   `sim.stats()` → `api.stats()` → **进 Lua**。这与本文件开头那条纪律
        #   （「lupa 的 LuaRuntime 不是线程安全的：模拟线程独占运行时」）直接冲突 ——
        #   那两处甚至写着注释「不在处理线程里再调 Lua」，却正是这么做的。
        #   ⇒ 改成：模拟线程每 8 拍算一次放这里，处理线程**只读缓存**。
        #   代价是统计最多落后 0.27 s —— 对监控页与对账都无所谓，
        #   而「两个线程同时跑同一个 LuaRuntime」是随时可能炸的真问题。
        self.stats_cache = None        # dict | None（模拟线程填，处理线程读）
        # ★★★ C1（2026-10-18 P44）：**停帧看门狗**的状态
        #
        #   背景：§9v.5 报过「某种客户端节奏让模拟循环停住」，三次尝试（含 6 轮
        #   burst/paced 压测）都**没复现**。不复现不等于不存在 —— 它意味着
        #   **下一次发生时我们仍然没有证据**。所以这里补的不是「修好那个 bug」，
        #   而是「下一次发生时能说清它在哪一行停住」。
        #
        #   ★ 为什么必须是**独立线程**：单线程里的看门狗看不见自己卡死。
        #     只有另一个线程在看 `beat` 有没有推进，才可能发现「主循环不动了」。
        self.beat = 0.0                # 模拟线程每拍写一次 perf_counter()
        self.sim_ident = None          # 模拟线程 ident（停帧时抓它的 Python 栈）
        self.stalls = 0                # 累计停帧次数（≥ 阈值才算一次）
        self.last_stall = None         # dict: at / gap / threshold / trace
        # 阈值可用环境变量调（反向测试要把它调大/调小）
        self.stall_threshold = float(os.environ.get("RT_STALL_SEC", "3.0"))
        self._stall_marked = False
        # ★ P39：每个槽位的**自身状态**（血/饿/理智/背包），同样由模拟线程算好、处理线程只读。
        #   与 targets 分开缓存：频率一样（每 8 拍），但**消费者不同**
        #   （目标列表是「能干什么」，这个是「我怎么了」），混在一起会让两边互相拖累。
        self.me_by_slot = {}       # slot -> {health,maxhealth,hunger,...}

        # ★★★ 说明：「我是谁」曾经用**推送**（模拟线程塞进 outbox、处理线程取走后发）。
        #   实测在负载下不可靠：4 个客户端 + 646 实体时，处理线程会被 GIL 争用饿到，
        #   新连接的 `you` **有时十几秒都不发** —— 而客户端没有它就一直不知道自己是哪一条。
        #   ⇒ 改成**拉取**：客户端连上发 `{"cmd":"whoami"}`，处理线程**就地应答**。
        #   没有跨线程投递、没有等待、没有超时：**时序依赖被彻底去掉**。

    # ---------- 玩家槽位（P20/P21）----------
    def alloc_slot(self, cid, key=None):
        """给一个连接分配槽位。

        优先级：① 带 `key` 且这个 key **有保留中的槽位** ⇒ 复用它（= 拿回自己的角色）；
                ② 槽位 0 还没人用 ⇒ 给第一个连接；
                ③ 复用空闲槽位；④ 新开一个。
        返回 `slot`；若同一个 key **已经在别处连着**则返回 `-1`（busy，新连接不给角色）。
        """
        with self.lock:
            if key:
                slot = self.by_key.get(key)
                if slot is not None:
                    if slot in self.slot_of.values():
                        # 同一个 key 已经有一个**活着的**连接 ⇒ 拒绝第二个（免得两个人抢一个身体）
                        self.busy_kicks += 1
                        return -1
                    # 保留期内重连 ⇒ 拿回原槽位（并取消保留）
                    self.reserved.pop(slot, None)
                    self.slot_of[cid] = slot
                    self.slot_key[slot] = key
                    return slot
            # ★★ P37 修（这条是**跨进程判据第一次跑就抓到**的真 bug）：
            #   「有身份在身、但人现在没连回来」的槽位（`by_key` 里有、`slot_of` 里没有）
            #   **不许**分给新连接。症状：重启后 `prime_keys` 已把 K1→槽位 1 灌进 `by_key`，
            #   而 `next_slot` 还是初始的 1 ⇒ 第二个连接（key=K2 / 匿名）也被分到**槽位 1**
            #   ⇒ 两个客户端指向**同一个身体**（`whoami` 回同一个 guid）。
            #   进程内测不出来（`by_key` 在进程内本来就是热的那一份）；只有「重启 + 同 key 回来」
            #   这条路径才会让「已认领但未连接」的槽位真的存在。
            held = set(self.by_key.values()) - set(self.slot_of.values())
            if 0 not in self.slot_guid and 0 not in self.slot_of.values() and 0 not in held:
                slot = 0
            else:
                # 复用空闲槽位（跳过被身份认领的）
                slot = None
                while self.free_slots:
                    s = self.free_slots.pop(0)
                    if s not in held:
                        slot = s
                        break
                # 新开一个（同时跳过被认领的、在用的、以及默认玩家 0）
                if slot is None:
                    s = max(1, self.next_slot)
                    while s in held or s in self.slot_of.values() or s in self.slot_guid:
                        s += 1
                    slot = s
                    self.next_slot = s + 1
            # ★★★ 分配槽位时**清掉上一次的 guid** —— 这是第二个时序坑：
            #   槽位复用（上一个连接刚断开）时，`slot_guid[slot]` 里还留着**旧角色**的 guid，
            #   而那个角色正等着被 remove 处理掉。此时客户端一问 `whoami` 就拿到旧 guid
            #   ⇒ 它认了一个**马上就不存在的角色** ⇒ 症状是「帧里找不到自己」。
            #   ⇒ 清掉之后，whoami 会如实回 null，客户端重试到模拟线程把新角色建好为止。
            #   ⚠️ 槽位 0 不清：它是默认玩家，永远存在（也不参与回收）。
            if slot != 0:
                self.slot_guid.pop(slot, None)
                # ★★ P39 连带：槽位换主人时，把**按槽位缓存**的东西一并作废。
                #   它们（目标列表 / 自身状态 / 上次动作结果）都是「上一任」的观察结果，
                #   留着就会在新客户端问起时被当成「你的」。（`me` 那边还有一道 guid 对账，
                #   这里是**源头**就该断：缓存作废比事后比对更不容易漏。）
                #   ⚠️ 别在这里碰 Lua：那是模拟线程的事，本方法可能在任何线程里被调。
                self.me_by_slot.pop(slot, None)
                self.targets_by_slot.pop(slot, None)
                self.act_result.pop(slot, None)
            self.slot_of[cid] = slot
            if key:
                self.by_key[key] = slot
                self.slot_key[slot] = key
            return slot

    def prime_keys(self, mapping):
        """把**存档里带回来的**会话 key 灌进 `by_key`/`slot_key`（P36）。

        ★ 为什么必须在启动时做：客户端重连时只带一个 key，服务端要靠 `by_key`
          才知道「它上次用的是哪个槽位」。以前这张表每次重启都从零开始 ⇒
          同一个 key 回来也认不出自己（只能拿到新槽位、新角色）。
        ★ 返回灌进去的条数（0 = 存档里没有身份信息，这是**正常**情况）。
        """
        n = 0
        for slot_s, key in (mapping or {}).items():
            try:
                slot = int(slot_s)
            except (TypeError, ValueError):
                continue
            if not key:
                continue
            self.by_key[str(key)] = slot
            self.slot_key[slot] = str(key)
            n += 1
        return n

    def release_slot(self, cid):
        """连接断开：回收槽位 + **原子地**把「删掉这个槽位的玩家」排进命令队列。

        ★★★ 「放回空闲表」与「入队 remove」**必须在同一把锁里**做 —— 这是踩出来的：
          第一版先 release（把槽位放回 free_slots）、调用方再 `cmds.put(remove)`。
          中间那个窗口里，**新连接可以拿到同一个槽位**并把 `add_player` 排进队列，
          于是队列顺序变成 **add → remove** ⇒ 新角色的实体**刚建出来就被删掉**，
          而客户端已经拿到了它的 guid ⇒ 症状是「我在帧里找不到自己」（间歇性！）。
          ⇒ 修法：两件事在同一把锁内完成，新连接拿槽位时 remove 一定已经排在它前面。
        """
        with self.lock:
            slot = self.slot_of.pop(cid, None)
            if slot is None or slot < 0:
                return slot
            key = self.slot_key.get(slot)
            if key and self.reconnect_grace > 0:
                # ★ 注意：**包括槽位 0**。槽位 0 是「默认玩家」，但带 key 的客户端认领过它，
                #   它就得和普通角色一样有生命周期 —— 否则刷新一次就漏一个空壳（D2 抓到的）。
                #   无 key 的匿名连接仍然享受老行为（槽位 0 永久存在，向后兼容）。
                # ★★ 带身份的客户端断线 ⇒ **保留**这一小段时间（玩家不删、槽位不回收）：
                #   刷新页面 / 短暂掉线后重连，拿回的还是同一个角色（同一个 guid、同一个位置）。
                #   到期没回来才真正删掉（由模拟线程扫 reserved 表）。
                if slot != 0:
                    self.reserved[slot] = time.time() + self.reconnect_grace
                else:
                    self.reserved[0] = time.time() + self.reconnect_grace
                return slot
            if slot != 0:
                self.free_slots.append(slot)
                self.free_slots.sort()
                self.by_key.pop(key, None) if key else None
                self.slot_key.pop(slot, None)
                # ★ 与回收到空闲表**同时**入队（见上），顺序由 FIFO 保证
                self.cmds.put(("remove_player", slot))
            return slot

    def reap_reserved(self):
        """扫一遍保留期，到期的真正删掉（槽位回收 + 删玩家）。返回清掉的槽位列表。"""
        now = time.time()
        out = []
        with self.lock:
            for slot, deadline in list(self.reserved.items()):
                if deadline > now:
                    continue
                self.reserved.pop(slot, None)
                key = self.slot_key.pop(slot, None)
                if key:
                    self.by_key.pop(key, None)
                self.free_slots.append(slot)
                self.free_slots.sort()
                self.cmds.put(("remove_player", slot))
                out.append(slot)
        return out

    def is_paused(self):
        with self.lock:
            return self.paused

    def set_paused(self, on):
        with self.lock:
            was = self.paused
            self.paused = bool(on)
        return was, bool(on)

    def publish(self, payload: dict):
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        with self.lock:
            self.snap = payload        # ★ 也留一份原始快照
            self.frame = data
            self.frame_ver += 1

    def latest_snap(self, since_ver):
        with self.lock:
            if self.frame_ver == since_ver or self.snap is None:
                return None, since_ver
            return self.snap, self.frame_ver

    def latest(self, since_ver):
        with self.lock:
            if self.frame_ver == since_ver or not self.frame:
                return None, since_ver
            return self.frame, self.frame_ver


# =============================================================================
# HTTP + WebSocket（同端口）
# =============================================================================


def _stats_from_cache(self):
    """`/status` 与 `/healthz` 用的统计：**只读**模拟线程写好的缓存。

    ★★ 为什么不能写 `Handler.sim_stats = sim.stats`：
      `sim.stats()` → `api.stats()` → 直接**进 Lua**。处理线程每来一个请求就进一次，
      而 lupa 的 LuaRuntime 只有一个、且**不是线程安全的**（本文件开头就写着
      「模拟线程独占运行时」）。`/status` 与 `/healthz` 恰好是**最容易被高频访问**的
      两个端点（发布后就是给人刷的），把 Lua 暴露在它们上面，等于把纪律的口子
      开在流量最大的地方。
    ⇒ 缓存由 `sim_loop` 每 8 拍（≈0.27 s）刷新一次（见 Hub.stats_cache）。
    """
    with self.hub.lock:
        st = self.hub.stats_cache
        out = dict(st) if isinstance(st, dict) else {}
        # ★★ C1：把看门狗状态并进 stats —— `/healthz` 与 `/status` 都会带上。
        #   为什么放在这里而不是 `Sim.stats()`：`Sim.stats()` 要**进 Lua**，
        #   而这两个端点跑在处理线程（本文件开头那条纪律：只有模拟线程能碰 Lua）。
        out["stalls"] = self.hub.stalls
        out["stall_threshold"] = self.hub.stall_threshold
        out["stall_age"] = (round(time.perf_counter() - self.hub.beat, 3)
                           if self.hub.beat else None)
        out["last_stall"] = self.hub.last_stall
        out["rate_limited"] = self.hub.rate_limited      # ★ M5：限流次数
    return out
