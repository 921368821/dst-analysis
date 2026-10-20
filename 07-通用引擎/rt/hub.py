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
from html import escape



# =============================================================================
# Lua 表 -> 纯 Python（存档要过 JSON，嵌套的 _LuaTable 不能直接序列化）
# =============================================================================

def _slots_html(players):
    """把 `stats()["players"]`（按槽位的存活/血量）拼成一行给人看的摘要。

    ★ 为什么要有：`player_alive`/`player_health` 只描述**槽位 0**；
      多客户端时运维需要一眼看到**每个槽位**是死是活 ——
      否则「杀了客户端却报玩家还活着」这种误判会消耗排查时间（E8 就踩过）。

    ★★ 2026-10-20：这个函数是 `/status` 的一半，而 `/status` 正是**出故障时**才打开的页面。
      原来它对输入有三处硬假设，任何一条不成立就把整页打成 500（诊断面自己先死）：
        · 键一定是数字字符串（`sorted(..., key=int)`）⇒ 键是 `"a"` 就 ValueError
        · 值一定是 dict（`v.get`）⇒ 值是字符串/None 就 AttributeError
        · 键直接拼进 HTML ⇒ 键里带 `<` 就变成注入点（今天键是槽位号，但这是**免费的防御**）
      ⇒ 键：数字优先、非数字按字符串排在后面；值：不是 dict 就当空；键一律 HTML 转义。
    """
    if not isinstance(players, dict) or not players:
        return "（无）"

    def _order(k):
        try:
            return (0, int(k), "")
        except (TypeError, ValueError):
            return (1, 0, str(k))

    def one(k):
        v = players.get(k)
        if not isinstance(v, dict):
            v = {}
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
                _esc(k), ("%.0f" % hp) if isinstance(hp, (int, float)) else "?", tag)
        if v.get("alive") is False:
            return "<b style='color:#f85149'>槽%s 已死亡</b>%s" % (_esc(k), tag)
        return "槽%s ?" % _esc(k)
    return " · ".join(one(k) for k in sorted(players, key=_order))


def _esc(v):
    """HTML 转义（`/status` 是给人看的页面，键值都当**文本**对待）。"""
    return escape(str(v), quote=False)


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


# 跨线程计数器的**白名单**（见 `Hub.bump`）：只有这几项允许被 `bump` 改。
# 为什么要有白名单：`setattr` 对任何名字都成立，等于留了一扇后门 ——
# 手滑写成 `hub.bump("paused")` 会静默地把暂停状态变成数字。
_COUNTERS = ("dropped_bad_frames", "rate_limited", "frames_sent", "bytes_sent")


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
        # ★★★ 2026-10-20（P49）：「在线人数」与「连接号」**是两个东西**，以前被合成一个。
        #   `clients` 是**活着**的连接数（加一/减一），拿它当 cid 会**复用号码**：
        #   A(1) B(2) C(3) 里 B 走了 ⇒ clients=2 ⇒ 新连接 D 也叫 3 —— 而 C 还活着。
        #   后果链：`slot_of[3]` 被 D 覆盖 ⇒ C 的槽位映射**丢了** ⇒ C 断开时
        #   `release_slot(3)` 释放的是 **D 的**槽位 ⇒ D 还连着却被塞回空闲表 ⇒
        #   下一个连接拿走同一个槽位 ⇒ **两个人共用一个身体**（`whoami` 回同一个 guid =
        #   B26 的现场）。更阴的是「槽位被重复分配」那条警报**不会响**：
        #   旧主人的 `slot_of` 早被覆盖掉了，`slot in slot_of.values()` 查不出来。
        #   ⇒ cid 必须**单调只增**，永不复用。
        self.cid_seq = 0
        # ★★★ P50⑱：**计数器必须有自己的一把锁 + 唯一入口**。
        #   这几项是跨线程的（每条连接一个处理线程），而
        #   `self.hub.dropped_bad_frames += 1` 在 Python 里是
        #   `LOAD_ATTR / LOAD_CONST / BINARY_ADD / STORE_ATTR` 四步，
        #   理论上 GIL 可以在中间切换 ⇒ 丢更新。实测有 9 处自增，
        #   其中只有 1 处在 `self.lock` 里 —— 其余 8 处全是裸 `+=`。
        #
        #   ⚠ **诚实边界（先量再说）**：实测 8 线程 × 5 万次 = **40 万次并发自增，
        #     一次都没丢**（把 `sys.setswitchinterval` 调到 1e-6 也一样）。
        #     所以在 CPython 上这**不是**一个可复现的 bug —— 不要拿它当「修了丢计数」邀功。
        #   那为什么还要改？两条实测收益：
        #     ① **读取一致性**：`/healthz` 原来逐个字段读，读一半被改就会出现
        #        「发帧 1200 / 字节 0」这种自相矛盾的一帧 —— 不一致的统计比没有更误导。
        #        现在 `stats_snapshot()` 在同一把锁里读全。
        #     ② **把计数挪出热点主锁**：原来限流那处在 `with self.hub.lock:` 里做
        #        `+= 1` —— 主锁是模拟线程与所有连接线程共用的热点，
        #        为一次整数加法去抢它，纯属白付。
        #   ⇒ 单独一把 `stat_lock`（与 `self.lock` 分开，避免嵌套/重入问题），
        #     统一走 `bump(name, n)`，名字受白名单约束。
        #   ★ 顺序约束：**持有 stat_lock 时绝不许再去拿 self.lock**。
        self.stat_lock = threading.Lock()
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

    # ---------- 跨线程计数器（唯一写入入口）----------
    def bump(self, name, n=1):
        """把计数器 `name` 原子地加 `n`。

        ★ 只允许改 `__init__` 里那几个统计项；用白名单挡住「手滑写成别的字段」
          （`setattr` 对任意名字都成立，等于给了一扇后门）。
        ★ 读也走 `stats_snapshot()`：读一半被改，`/healthz` 会出现
          「发帧 100 / 字节 0」这种自相矛盾的一帧 —— 不一致的统计比没有更误导。
        """
        if name not in _COUNTERS:
            raise AttributeError("bump() 只用于统计项，%r 不在白名单 %r" % (name, _COUNTERS))
        with self.stat_lock:
            setattr(self, name, getattr(self, name) + int(n))

    def stats_snapshot(self):
        """一次性读出所有统计项的**一致**快照（同一把锁里读）。"""
        with self.stat_lock:
            return {k: getattr(self, k) for k in _COUNTERS}

    # ---------- 连接的登记与注销（cid 的唯一来源）----------
    def open_client(self, path):
        """登记一条新连接，返回**永不复用**的连接号 `cid`。

        ★★★ 为什么单独一个方法：`cid` 是 `slot_of` 的键。号码一旦复用，
          「谁的槽位」这件事就没有答案了（见 `__init__` 里 `cid_seq` 的注释）。
          **在线人数**（`clients`，给 /stats 与日志看）与**连接身份**（`cid`）必须分开：
          前者会减，减了就会撞上还活着的那个。这两个量长得像、用途不同，
          合成一个字段是「看起来更简单」的典型—— B26 的偶发红正是它造成的。
        """
        with self.lock:
            self.clients += 1
            self.cid_seq += 1
            cid = self.cid_seq
            self.client_ids[cid] = path
        return cid

    def close_client(self, cid):
        """注销连接（在线人数减一 + 摘掉路径记录）。**不回收槽位**（那是 release_slot）。"""
        with self.lock:
            self.clients -= 1
            self.client_ids.pop(cid, None)

    # ---------- 玩家槽位（P20/P21）----------
    def alloc_slot(self, cid, key=None):
        """给一个连接分配槽位。

        优先级：① 带 `key` 且这个 key **有保留中的槽位** ⇒ 复用它（= 拿回自己的角色）；
                ② 槽位 0 还没人用 ⇒ 给第一个连接；
                ③ 复用空闲槽位；④ 新开一个。
        返回 `slot`；若同一个 key **已经在别处连着**则返回 `-1`（busy，新连接不给角色）。
        """
        with self.lock:
            # ★ P49 守卫：cid **刚由 `open_client` 发出来**，如果它已经在 `slot_of` 里，
            #   说明号码被复用了（历史 bug），此时**说什么都是错的** —— 必须吵。
            if cid in self.slot_of:
                print("[player] ✘✘ 新连接的 cid=%s 已经在 slot_of 里（占用槽位 %s）"
                      "—— 连接号被复用了，两个人的槽位会互相顶掉"
                      % (cid, self.slot_of[cid]))
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
            # ★★ 2026-10-20（P49）：「同一个槽位发给两个**还活着**的连接」必须**吵出来**。
            #   以前这里静默通过 —— 后果是两个人共用一个身体：`whoami` 回同一个 guid、
            #   我的输入动了别人的角色。更隐蔽的一种：槽位被回收进 `free_slots` 又被发出去，
            #   而一个迟到的 `remove_player` 把新主人的身体删掉 ⇒ `slot_guid` 里没有身体
            #   ⇒ `whoami` 永远回 null，而帧照常在流（B26 偶发红的现场就是
            #   `A: you=None slot=1 null×30 frames=206`，且 B 也拿到 slot=1）。
            #   「静默通过」在这类问题上是致命的：没有任何一条日志能把人指到这里。
            if slot in self.slot_of.values():
                others = [k for k, v in self.slot_of.items() if v == slot and k != cid]
                print("[player] ✘✘ 槽位 %d **被重复分配**（仍由连接 %s 占用）—— %d 个人共用一个身体"
                      % (slot, others, len(others) + 1))
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
