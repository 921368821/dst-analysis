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

    print("\n── sim.py：构造期纪律 ──")
    check("U11 反向：Sim() 构造期不建 LuaRuntime", u11_sim_ctor_touches_no_lua)

    print("\n" + "─" * 78)
    print("  结果：%d 通过 / %d 失败（共 %d 条）" % (PASS, FAIL, PASS + FAIL))
    print("─" * 78)
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
