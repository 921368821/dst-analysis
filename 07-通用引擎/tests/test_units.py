# -*- coding: utf-8 -*-
"""test_units.py —— 模块级单测（L6 的第一步；配合 M4 拆分）

为什么要有
    现有验证全是**集成级**：`tests/test_rt.py` 一跑 10 分钟起步（每次都要
    `Sim.boot()` ≈ 4 s），而 `run_all.sh` 更是 18 组。
    于是「我只改了一个 query 解析函数」也要等十分钟才知道对不对 ——
    这不是严谨，是**把反馈周期拉长到没人愿意跑**。
    M4 把 `rt/server.py` 拆成 7 个模块之后，纯函数终于**可以单独测**了。

判据设计（沿用本工程纪律）
    ① 先证「该发生的发生了」
    ② 再证「不该发生的没发生」——每条主判据都尽量配一条**反向判据**
       （例如：`_origin_host` 认得正常 Origin，也必须**认不出**畸形值 ⇒ 视为跨源）

范围（只测**不需要 LuaRuntime、不需要起服务端**的东西）
    · `net.py`   ：来源校验 / query 解析 / 控制端点清单
    · `hub.py`   ：`lua_to_py`（用 lupa 造真 `_LuaTable`）/ `_slots_html` 空表
                   ★ P50：**槽位分配与连接号**（U12~U18）—— B26 的根因在 `open_client`
                   用「在线人数」当 cid，症状却要 6 秒集成测试才偶发一次。
                   这一段把那条判据压到 1 毫秒，并且配了「旧写法必须红」的变异对照。
    · `config.py`：路径常量彼此自洽（`ENGINE` 在 `ROOT` 旁边、图集两目录不同）
    · `sim.py`   ：`Sim()` 构造**不许**碰 Lua（碰了就等于把线程纪律破在构造期）

跑法：
    cd 07-通用引擎 && python tests/test_units.py
退出码：0 = 全绿
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                 # 07-通用引擎
RT = os.path.join(ROOT, "rt")
sys.path.insert(0, RT)

PASS, FAIL = 0, 0
RESULTS = []


def check(name, fn):
    global PASS, FAIL
    try:
        ok, info = fn()
    except Exception as e:                                       # noqa: BLE001
        import traceback
        ok, info = False, "抛异常: %s" % e
        traceback.print_exc()
    RESULTS.append((name, ok, info))
    if ok:
        PASS += 1
        print("  ✔ %-58s %s" % (name, info))
    else:
        FAIL += 1
        print("  ✘ %-58s %s" % (name, info))


# =============================================================================
# net.py：来源校验
# =============================================================================
def u1_origin_host_normal():
    from net import _origin_host
    cases = {
        "http://127.0.0.1:8765": "127.0.0.1:8765",
        "https://Example.COM:443/path?q=1": "example.com:443",
        # ★ 无 scheme 且以 `//` 开头 ⇒ 取不到 host，返回空串。
        #   这不是缺陷，是**刻意的**：空串永远不等于本机 host ⇒ 一律判跨源。
        #   宁可把「看起来像同源」的写法判成跨源（要求同一份 HTML 走 http:// 加载），
        #   也不能把畸形值「善意解析」成同源 —— 那正是 CSRF 的口子。
        "//evil.com": "",
        "null": "null",                            # file:// / sandbox
        "": "",
        None: "",
    }
    bad = {k: _origin_host(k) for k, want in cases.items() if _origin_host(k) != want}
    return (not bad), ("6 例全部符合" if not bad else "不符: %r" % bad)


def u2_origin_host_reverse_malformed():
    """反向：畸形值**不许**被"善意解析"成合法同源。"""
    from net import _origin_host
    # 这些都是「不像本服务」的值；判据是「解析结果 != 本机 host:port」
    mine = "127.0.0.1:8765"
    samples = ["", "null", "javascript:alert(1)", " http://a b ", "////", "?"]
    leaked = [x for x in samples if _origin_host(x) == mine]
    return (not leaked), ("6 个畸形值都不等于本机" if not leaked else "误判为同源: %r" % leaked)


def u3_query():
    from net import _query_get, _query_of
    ok1 = _query_of("/a?x=1&y=2") == "x=1&y=2" and _query_of("/a") == ""
    ok2 = _query_get("/a?token=abc&x=1", "token") == "abc"
    ok3 = _query_get("/a?xtoken=abc", "token") is None      # ★ 不许「子串命中」
    ok4 = _query_get("/a", "token") is None
    return (ok1 and ok2 and ok3 and ok4), "of/取到/不误命中/无 query 均正确"


def u4_control_paths():
    """控制端点是**有副作用**的那四个 —— 少一个就是少一道门。"""
    from net import CONTROL_PATHS, MAX_WS_MSGS_PER_SEC
    want = {"/pause", "/save", "/respawn", "/light"}
    same = set(CONTROL_PATHS) == want
    lim = isinstance(MAX_WS_MSGS_PER_SEC, int) and 0 < MAX_WS_MSGS_PER_SEC <= 1000
    return (same and lim), "4 个控制端点齐全 / 限流上限 %s" % MAX_WS_MSGS_PER_SEC


def u4b_readonly_not_in_control():
    """反向：只读端点**不得**混进控制端点（混进去就等于给只读接口加了 token 要求）。"""
    from net import CONTROL_PATHS
    bad = [p for p in ("/healthz", "/status", "/terrain", "/atlas") if p in CONTROL_PATHS]
    return (not bad), ("只读端点未被误列为控制端点" if not bad else "误列: %r" % bad)


# =============================================================================
# hub.py：lua_to_py（存档要过 JSON，_LuaTable 不能直接 dumps）
# =============================================================================
def u5_lua_to_py_primitives():
    from hub import lua_to_py
    vals = [1, 1.5, "s", True, None]
    back = [lua_to_py(v) for v in vals]
    return (back == vals), "标量原样返回：%r" % (back,)


def u6_lua_to_py_table():
    """真 `_LuaTable` 必须转成 list/dict —— 这是 /healthz 与存档能 dumps 的前提。"""
    from lupa import LuaRuntime
    from hub import lua_to_py
    import json
    L = LuaRuntime(unpack_returned_tuples=True)
    t = L.eval("({1, 2, 3, name='wilson', nested={hp=100}})")
    out = lua_to_py(t)
    ok_arr = out[0] if isinstance(out, list) else out.get("__array__")
    as_json = json.dumps(out, ensure_ascii=False)             # ★ 不许抛
    ok = ok_arr == [1, 2, 3] and "wilson" in as_json and "100" in as_json
    return ok, "数组→list、键→dict、可 json.dumps（%d 字节）" % len(as_json)


def u7_lua_to_py_depth_guard():
    """反向：自引用表**不许**把递归踩穿（踩穿 = 进程崩，不是异常）。"""
    from lupa import LuaRuntime
    from hub import lua_to_py
    L = LuaRuntime(unpack_returned_tuples=True)
    # ★ Lua 5.5 的 eval 只吃**表达式**：语句必须包进立即执行的函数里
    t = L.eval("(function() local x = {} x.self = x return x end)()")
    out = lua_to_py(t)
    return ("too-deep" in str(out)), "自引用被 '<too-deep>' 截断，未爆栈"


def u8_slots_html_empty():
    from hub import _slots_html
    a = _slots_html({})
    b = _slots_html({"0": {"alive": True, "health": 100}})
    ok = a == "（无）" and "100" in str(b)
    return ok, "空表给出明确占位、非空表带血量"


# =============================================================================
# config.py：路径自洽
# =============================================================================
def u9_config_paths():
    from config import HERE, ROOT, ENGINE, ATLAS_JSON_DIR, ATLAS_PNG_DIR
    ok_root = os.path.isdir(ROOT) and os.path.basename(ROOT) == "07-通用引擎"
    ok_eng = os.path.isdir(ENGINE) and os.path.basename(ENGINE) == "06-引擎复刻"
    # ★ 两个图集目录**必须不同**：第一版把它们当成一个，导致 /atlas 恒 404
    ok_split = os.path.normcase(ATLAS_JSON_DIR) != os.path.normcase(ATLAS_PNG_DIR)
    ok_here = os.path.isdir(HERE)
    return (ok_root and ok_eng and ok_split and ok_here), \
        "ROOT/ENGINE 相邻、图集元数据与贴图分开、HERE 存在"


def u10_rt_dir_on_syspath():
    """`ws` / `protocol_bin` 能 import ⇒ sys.path 那条纪律没被拆坏。"""
    import ws
    import protocol_bin as PB
    return (hasattr(ws, "handshake_response") and hasattr(PB, "BinEncoder")), \
        "ws.handshake_response / PB.BinEncoder 均可取到"


# =============================================================================
# sim.py：构造期**不许**碰 Lua
# =============================================================================
def u11_sim_ctor_touches_no_lua():
    """★ 线程纪律：LuaRuntime 只许模拟线程用，**构造期**也不例外。

    判据：`Sim()` 之后 `sim.lua is None`（boot() 才建），
    且此时 `sim.snapshot` 之类不能已经拿到 Lua 的引用。
    """
    from sim import Sim
    s = Sim(seed=1, tick_hz=30)
    has_lua = getattr(s, "lua", "MISSING")
    return (has_lua is None), "Sim() 后 lua 仍为 None（boot 才建运行时）"


# =============================================================================
# hub.py：槽位分配与连接号（P50 —— B26 的根因，以前只有 6 秒集成级判据）
# =============================================================================
def _hub(grace=0.0, default_player=True):
    """造一个**不连服务端、不碰 Lua** 的 Hub。

    `default_player=True` 表示「世界已经启动，槽位 0 上的默认玩家存在」——
    这是**真实**状态（`alloc_slot` 里 `0 not in slot_guid` 这条会因此走另一分支）。
    不设它的话第一个连接会拿到槽位 0，而槽位 0 **永不回收**（`release_slot` 里
    `if slot != 0`），回收类判据就会测不到东西 —— 这一点我第一版就踩了：
    三条「回收」判据对着槽位 0 跑，全是假绿/假红。
    """
    from hub import Hub
    h = Hub()
    h.reconnect_grace = grace
    if default_player:
        h.slot_guid[0] = 9001
    return h


class _OldHub(object):
    """★ 变异对照：还原 P49 之前的写法 —— 拿「在线人数」当连接号。

    它存在的唯一目的是证明 U12/U13 这两条判据**有牙**：
    如果它们对旧写法也是绿的，那它们测的就不是这件事。
    """

    def __new__(cls, grace=0.0):
        from hub import Hub
        h = Hub()
        h.reconnect_grace = grace
        h.slot_guid[0] = 9001

        def open_client(path):                       # ← 旧写法就长这样
            with h.lock:
                h.clients += 1
                cid = h.clients                      # 「在线人数」当身份
                h.client_ids[cid] = path
            return cid
        h.open_client = open_client
        return h


def u12_cid_never_reused():
    """A/B/C 连上 → B 走 → D 连：D 的连接号**不许**等于任何活着的连接号。

    这是 B26 的第一环。旧写法下 `clients` 从 3 减到 2，新连接于是又叫 3，
    而 C 正拿着 3 —— 号码一复用，`slot_of` 的键就开始互相覆盖。
    """
    h = _hub()
    a, b, c = h.open_client("/"), h.open_client("/"), h.open_client("/")
    h.close_client(b)
    d = h.open_client("/")
    live = {a, c, d}
    ok = (d not in (a, b, c)) and len(live) == 3
    # 反向：同一个序列喂给旧写法，必须**撞上**
    o = _OldHub()
    oa, ob, oc = o.open_client("/"), o.open_client("/"), o.open_client("/")
    o.close_client(ob)
    od = o.open_client("/")
    collided = od in (oa, oc)
    return (ok and collided), \
        "新写法 cid=%s（不与 %s 撞）；旧写法 D=%s 撞上了活着的 %s ⇒ 判据有牙" % (
            d, (a, b, c), od, (oa, oc))


def u13_slot_map_invariant():
    """不变量：**分出去的槽位不许凭空消失** —— 要么由一个活连接持有，要么在空闲表里。

    旧写法下 C 活着，而 D 用同一个号码覆盖了它的条目 ⇒ C 的槽位 2 既不在
    `slot_of.values()` 也不在 `free_slots`（孤儿）。后果不是「日志难看」，
    而是 **C 断开时释放的是 D 的槽位** ⇒ 两个人共用一个身体。
    """
    def orphans(hh, allocated):
        held = set(hh.slot_of.values()) | set(hh.free_slots) | set(hh.reserved)
        return [s for s in allocated if s not in held]

    def run(hh):
        ids = [hh.open_client("/") for _ in range(3)]
        allocated = [hh.alloc_slot(c) for c in ids]
        hh.release_slot(ids[1])
        hh.close_client(ids[1])
        d = hh.open_client("/")
        allocated.append(hh.alloc_slot(d))        # ← 旧写法在这里覆盖别人的条目
        return ids, allocated, orphans(hh, allocated)

    h = _hub()
    ids, allocated, orphan_new = run(h)
    ok_slots = len(set(allocated)) == 3           # 三条连接三个不同槽位

    # 反向：旧写法必须留下孤儿槽位，而且守卫必须**吵出来**（不是静默通过）
    import contextlib
    import io
    o = _OldHub()
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        _, allocated_old, orphan_old = run(o)
    noise = buf.getvalue()
    shouted = ("连接号被复用了" in noise)
    return (ok_slots and not orphan_new and len(orphan_old) == 1 and shouted), \
        "新写法 0 个孤儿槽位；旧写法留下 %s 孤儿且守卫打印了「连接号被复用了」⇒ 判据有牙" % (
            orphan_old,)


def u14_release_only_own_slot():
    """`release_slot(cid)` **只**回收它自己的槽位，别人的映射一个都不许动。"""
    h = _hub()
    a, b, c = h.open_client("/"), h.open_client("/"), h.open_client("/")
    sa, sb, sc = h.alloc_slot(a), h.alloc_slot(b), h.alloc_slot(c)
    h.release_slot(c)
    ok = (h.slot_of.get(a) == sa and h.slot_of.get(b) == sb
          and c not in h.slot_of and len(h.slot_of) == 2)
    # 反向：回收确实发生了（否则「一个都没动」会被「什么都没做」冒充）
    ok2 = sc in h.free_slots
    return (ok and ok2), "只摘掉 C（槽 %s）；A/B 的槽 %s/%s 原样；槽 %s 进空闲表" % (
        sc, sa, sb, sc)


def u15_claimed_slot_not_handed_out():
    """★ P37 回归：**已认领但人还没连回来**的槽位，不许分给任何新连接。

    症状（历史上真发生过）：重启后 `prime_keys` 把 K1→槽位 1 灌进 `by_key`，
    而 `next_slot` 还是 1 ⇒ 第二个连接也被分到槽位 1 ⇒ 两个客户端指向同一个身体。
    """
    h = _hub()
    n = h.prime_keys({"1": "K1"})
    # 带别的 key 的连接、以及匿名连接，都不许拿到槽位 1
    c1 = h.open_client("/?k=K2")
    s1 = h.alloc_slot(c1, key="K2")
    c2 = h.open_client("/")
    s2 = h.alloc_slot(c2)
    ok = (n == 1 and s1 != 1 and s2 != 1 and s1 != s2)
    # 而 K1 本人回来时**必须**拿回 1
    c3 = h.open_client("/?k=K1")
    s3 = h.alloc_slot(c3, key="K1")
    return (ok and s3 == 1), "K2/匿名 分到 %s/%s（都避开已认领的 1）；K1 回来拿回 %s" % (
        s1, s2, s3)


def u16_busy_key_rejected():
    """同一个 key 已经有活连接 ⇒ 第二个连接拿 `-1`，且 `busy_kicks` 计数 +1（不静默）。"""
    h = _hub()
    a = h.open_client("/")
    sa = h.alloc_slot(a, key="K")
    b = h.open_client("/")
    sb = h.alloc_slot(b, key="K")
    ok = (sb == -1 and h.busy_kicks == 1 and h.slot_of.get(a) == sa and b not in h.slot_of)
    return ok, "第二个连接被拒（-1），第一个仍持有槽 %s，拒绝计数 %d" % (sa, h.busy_kicks)


def u17_release_is_atomic_with_remove():
    """★ 回收槽位与「排进 remove_player」必须在**同一把锁**里 —— 顺序不许反。

    第一版先 release、调用方再 `cmds.put(remove)`，中间那个窗口里新连接可以
    拿到同一槽位并把 `add_player` 排进队列 ⇒ 队列顺序变成 **add → remove**
    ⇒ 新角色刚建出来就被删掉（症状：我在帧里找不到自己，且是间歇性的）。
    """
    h = _hub()
    a = h.open_client("/")
    sa = h.alloc_slot(a)
    h.release_slot(a)
    # 两件事要么都发生、要么都没发生：可观测的只有「都发生了」
    cmds = []
    while not h.cmds.empty():
        cmds.append(h.cmds.get_nowait())
    ok = (sa in h.free_slots) and (("remove_player", sa) in cmds)
    # 反向：**带 key** 且宽限期 >0 时，两件事都不许发生（玩家要留着等重连）
    h2 = _hub(grace=60.0)
    b = h2.open_client("/")
    sb = h2.alloc_slot(b, key="K")
    h2.release_slot(b)
    ok2 = (sb not in h2.free_slots) and h2.cmds.empty() and h2.reserved.get(sb, 0) > 0
    return (ok and ok2), "无 key：槽 %s 进空闲表且 remove 已入队；带 key：两边都不动、留在保留期" % sa


def u18_slot_change_invalidates_cache():
    """槽位换主人时，**按槽位缓存**的观察结果必须作废（否则新客户端会读到上一任的）。"""
    h = _hub()
    a = h.open_client("/")
    sa = h.alloc_slot(a)
    h.slot_guid[sa] = 4242
    h.me_by_slot[sa] = {"health": 111}
    h.targets_by_slot[sa] = [{"id": 7}]
    h.act_result[sa] = {"ok": True}
    h.release_slot(a)
    # 断开后又把同一个槽位发给别人（空闲表复用路径）—— 只有 slot != 0 才会作废
    b = h.open_client("/")
    sb = h.alloc_slot(b)
    reused = (sb == sa)
    clean = (sa not in h.slot_guid and sa not in h.me_by_slot
             and sa not in h.targets_by_slot and sa not in h.act_result)
    # 骨架：这里不再断言 guid==4242 一定被清 —— 清了才对，没清就会「认一个不存在的角色」
    return (reused and clean), "槽 %s 被复用；gu/me/targets/act 四处缓存均已作废" % sa


# =============================================================================
# ws.py：帧编解码（P50 — B26 那条「坏帧: client frame must be masked」就是从这儿冒出来的）
# =============================================================================
class _FakeSock(object):
    """喂字节的假 socket：可以指定「每次最多吐几个字节」来逼出短读。

    ★ 为什么必须能**短读**：`_read_exact` 的全部价值就是「一次 recv 拿不全也要读满」。
      只喂整帧的假 socket 会让它退化成一个 `recv(n)` 调用，判据也就测不到循环。
    """

    def __init__(self, data, chunk=None):
        self.data = bytes(data)
        self.i = 0
        self.chunk = chunk            # None = 一次给完

    def recv(self, n):
        if self.i >= len(self.data):
            return b""                # 对端关闭
        take = n if self.chunk is None else min(n, self.chunk)
        out = self.data[self.i:self.i + take]
        self.i += len(out)
        return out


def u19_encode_frame_three_lengths():
    """服务端帧：长度三档（7bit / 16bit / 64bit）的头部必须逐字节对。

    这三档是最容易写错的地方（`126`/`127` 是**标记**，不是长度本身）。
    """
    from ws import encode_frame, OP_TEXT
    cases = [
        (0, b"\x81\x00"),
        (125, b"\x81\x7d"),
        (126, b"\x81\x7e\x00\x7e"),
        (65535, b"\x81\x7e\xff\xff"),
        (65536, b"\x81\x7f\x00\x00\x00\x00\x00\x01\x00\x00"),
    ]
    bad = []
    for n, head in cases:
        got = encode_frame(b"x" * n, OP_TEXT)[: len(head)]
        if got != head:
            bad.append((n, got, head))
    # 反向：服务端帧**不许**带掩码位（带了的客户端会按协议拒绝）
    masked = encode_frame(b"hello")[1] & 0x80
    return (not bad and masked == 0), \
        ("5 档长度头部全对、且第 2 字节掩码位为 0" if not bad else "不符: %r" % (bad,))


def u20_read_frame_short_reads():
    """客户端帧在**每次只到 1 字节**的情况下也必须解对（_read_exact 的循环）。"""
    from ws import read_frame, encode_frame_masked, OP_TEXT
    payload = b'{"cmd":"whoami"}' * 3
    frame = encode_frame_masked(payload, OP_TEXT)
    out = []
    for chunk in (None, 1, 3):
        op, got = read_frame(_FakeSock(frame, chunk=chunk))
        out.append((chunk, op == OP_TEXT and got == payload))
    # 反向：不带掩码的客户端帧必须被拒（RFC 6455 §5.1），且理由要说得出
    from ws import WSError
    plain = bytes([0x81, len(payload)]) + payload
    try:
        read_frame(_FakeSock(plain))
        rejected = False
    except WSError as e:
        rejected = "must be masked" in str(e)
    allok = all(ok for _, ok in out)
    return (allok and rejected), \
        "整帧/1 字节/3 字节三种短读都解对；无掩码帧被拒（理由含 must be masked）"


def u21_peer_close_is_not_bad_frame():
    """★ P49 回归：**对端正常关闭**必须抛 `ConnectionError`，不许抛 `WSError`。

    抛 WSError 的后果是：每个正常退出的客户端都被计一次「坏帧」，
    `dropped_bad_frames` 与日志被这条噪音占满，真正违反协议的帧反而看不出特别。
    """
    from ws import read_frame, WSError
    s = _FakeSock(b"")                       # 一个字节都没有 = 连上了就走
    try:
        read_frame(s)
        kind = "没抛"
    except ConnectionError:
        kind = "ConnectionError"
    except WSError:
        kind = "WSError"
    # 反向对照：读到**半帧**再断开，同样要算「连接结束」而不是「坏帧」
    s2 = _FakeSock(b"\x81\x7e\x00", chunk=1)
    try:
        read_frame(s2)
        kind2 = "没抛"
    except ConnectionError:
        kind2 = "ConnectionError"
    except WSError:
        kind2 = "WSError"
    return (kind == "ConnectionError" and kind2 == "ConnectionError"), \
        "空连接/半帧断开都抛 ConnectionError（%s / %s）—— 不会被记成坏帧" % (kind, kind2)


def u22_read_frame_rejects_bad_shape():
    """反协议帧必须**明确拒绝**：分片帧、超大长度（且在分配前就拒）。"""
    from ws import read_frame, encode_frame_masked, WSError
    # ① fin=0（分片）：替一个 0x01 的 b0（fin 位清零）
    frag = bytearray(encode_frame_masked(b"ab"))
    frag[0] &= 0x7F
    # ② 长度 0x7f 声明的 64 位长度 = 2^40，远超 8MB 上限，且**不该先去读 2^40 字节**
    huge = bytes([0x81, 0x7F]) + (1 << 40).to_bytes(8, "big")
    res = {}
    for tag, data in (("frag", bytes(frag)), ("huge", huge)):
        try:
            read_frame(_FakeSock(data))
            res[tag] = "没抛"
        except WSError as e:
            res[tag] = "WSError" if "not supported" in str(e) or "too large" in str(e) else "错理由"
        except OSError:
            res[tag] = "OSError"
    return (res["frag"] == "WSError" and res["huge"] == "WSError"), \
        "分片帧/超长帧都抛 WSError（%s / %s），不是静默吞掉" % (res["frag"], res["huge"])


def u23_accept_key_rfc_vector():
    """握手 accept 值用 RFC 6455 §1.3 的固定向量 —— 防止有人「顺手优化」这段哈希。"""
    from ws import accept_key
    got = accept_key("dGhlIHNhbXBsZSBub25jZQ==")
    want = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    return (got == want), "accept_key 与 RFC 6455 示例一致"


def u24_roundtrip_both_length_scales():
    """客户端编码 ↔ 服务端解码**互逆**（含 126 档的两字节长度）。"""
    from ws import read_frame, encode_frame_masked
    bad = []
    for n in (0, 1, 125, 126, 300):
        payload = bytes((i * 7) & 0xFF for i in range(n))
        op, got = read_frame(_FakeSock(encode_frame_masked(payload), chunk=5))
        if got != payload:
            bad.append(n)
    return (not bad), ("0/1/125/126/300 五档往返一致" if not bad else "不符: %r" % (bad,))


# =============================================================================
# 汇总
# =============================================================================
def main():
    print("═" * 78)
    print("  模块级单测（L6 / M4）：只测不需要 LuaRuntime、不需要起服务端的东西")
    print("═" * 78)

    print("\n── net.py：来源校验与 query 解析 ──")
    check("U1 _origin_host 认得出 6 种正常形态", u1_origin_host_normal)
    check("U2 反向：6 个畸形值不得被当作同源", u2_origin_host_reverse_malformed)
    check("U3 _query_of / _query_get（含「不许子串命中」）", u3_query)
    check("U4 控制端点清单齐全 + 限流上限合理", u4_control_paths)
    check("U4b 反向：只读端点不得混进控制端点", u4b_readonly_not_in_control)

    print("\n── hub.py：lua_to_py / 模板辅助 ──")
    check("U5 标量原样返回", u5_lua_to_py_primitives)
    check("U6 真 _LuaTable → list/dict，且能 json.dumps", u6_lua_to_py_table)
    check("U7 反向：自引用表被深度截断（不爆栈）", u7_lua_to_py_depth_guard)
    check("U8 空槽位摘要给出明确占位", u8_slots_html_empty)

    print("\n── hub.py：槽位与连接号（P50，B26 的根因层）──")
    check("U12 连接号不复用（旧写法必须撞）", u12_cid_never_reused)
    check("U13 不变量：slot_of 的键 == 活着的连接", u13_slot_map_invariant)
    check("U14 release_slot 只回收自己的槽位", u14_release_only_own_slot)
    check("U15 反向：已认领未连接的槽位不许分发", u15_claimed_slot_not_handed_out)
    check("U16 同 key 第二连接被拒 + 计数可见", u16_busy_key_rejected)
    check("U17 回收与 remove 入队原子（含带 key 反向）", u17_release_is_atomic_with_remove)
    check("U18 槽位换主人时按槽位缓存作废", u18_slot_change_invalidates_cache)

    print("\n── config.py：路径自洽 ──")
    check("U9 ROOT/ENGINE/图集目录彼此自洽", u9_config_paths)
    check("U10 rt/ 在 sys.path 上（ws / protocol_bin 可取）", u10_rt_dir_on_syspath)

    print("\n── ws.py：帧编解码（P50）──")
    check("U19 服务端帧三档长度头部逐字节对", u19_encode_frame_three_lengths)
    check("U20 客户端帧短读也能解对（整帧/1/3 字节）", u20_read_frame_short_reads)
    check("U21 反向：对端关闭抛 ConnectionError，不是 WSError", u21_peer_close_is_not_bad_frame)
    check("U22 反协议帧明确拒绝（分片/超长）", u22_read_frame_rejects_bad_shape)
    check("U23 握手 accept 值与 RFC 6455 向量一致", u23_accept_key_rfc_vector)
    check("U24 编解码往返（含 126 档）", u24_roundtrip_both_length_scales)

    print("\n── sim.py：构造期纪律 ──")
    check("U11 反向：Sim() 构造期不建 LuaRuntime", u11_sim_ctor_touches_no_lua)

    print("\n" + "─" * 78)
    print("  结果：%d 通过 / %d 失败（共 %d 条）" % (PASS, FAIL, PASS + FAIL))
    print("─" * 78)
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
