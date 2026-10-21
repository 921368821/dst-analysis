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
    ★ U6/U7 要 lupa。**随便找个 python 跑会缺包**（实测 `versions/3.13.12/python.exe`
      没装 lupa、`envs/default` 里有 2.8）⇒ 缺 lupa 的用例报「跳过」而**不是失败**，
      并把这句提示打出来。想跑全集就用 env.sh 解析出的 PY：
      bash -c '. ../tools/env.sh >/dev/null; "$PY" -u tests/test_units.py'
退出码：0 = 全绿（**跳过不算绿，但也不判红**，汇总行会单独报数）；1 = 有失败
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                 # 07-通用引擎
RT = os.path.join(ROOT, "rt")
sys.path.insert(0, RT)
# ★★ P50㉜：源码里若还留着**上一轮被中断的变异**，开跑前就拒绝（§9bm）。
#   2026-10-20 23:10 的 `--fast` 被掐断在 ②f 中途，`rt/rt_boot.lua` 停在篡改态
#   **10 小时 3 分**；这期间所有「单独跑一个案子」的结论都是**假绿**。
#   `run_all.sh` 开头只 heal 一次，别的入口全踩进去了 ⇒ 每个 import rt/ 的入口各加一道闸门。
sys.path.insert(0, HERE)                     # noqa: E402  （脚本跑时 HERE 已在 path，这行是不靠这个语义）
from _src_guard import guard                 # noqa: E402
guard(quiet=True)                            # 干净时不说话；脏就 SystemExit(2) + 打印还原命令

PASS, FAIL, SKIP = 0, 0, 0
RESULTS = []
# 自检用例条数（开发计划 §9cd / §9cg）：加/删用例必须同步改这里，
# 并同步 tools/case_counts.txt —— 否则「删了一半用例、剩下全过」会让闸门照样绿。
WANT_CASES = 46


class Skip(Exception):
    """用例**跑不了**（环境缺依赖 / 平台不支持）—— 与「跑失败了」是两种结论。

    ★★ 为什么要这个类（2026-10-20 实测）：用 `versions/3.13.12/python.exe`
      （没装 lupa）跑本文件，U6/U7 报 `No module named 'lupa'`，
      而汇总行写的是「39 通过 / 2 失败」——**环境缺失被打成了代码失败**。
      与 H3（缺 lupa 那次 `verify_plan` 报「文档数字过期」）是同一个错：
      把「我这台机器少个包」说成「你的东西是错的」。
      ⇒ 单独立一类结论：跳过，并**显式计数**（跳过绝不并进「通过」）。
    """


def need_lupa():
    """缺 lupa 就 Skip，并把**当前解释器**写进原因（换 python 是用户能自己做的事）。

    ★ 用 `find_spec` 而不是 `import lupa`：后者会被 pyflakes 判成
      「imported but unused」（它不认 `# noqa`），而这里本来也只想问「在不在」。
    """
    import importlib.util
    if importlib.util.find_spec("lupa") is None:
        raise Skip("缺 lupa（当前解释器 %s 没装；用 tools/env.sh 解析出的 PY 跑）"
                   % sys.executable)


def check(name, fn):
    global PASS, FAIL, SKIP
    try:
        ok, info = fn()
    except Skip as e:
        RESULTS.append((name, None, str(e)))
        SKIP += 1
        print("  ⚠ %-58s 跳过：%s" % (name, e))
        return
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
    need_lupa()
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
    need_lupa()
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
# protocol_bin.py：二进制帧（P50）
# =============================================================================
#   ★★ 为什么补这一段：`protocol_bin.py` 是**服务端权威端**的编码器，
#     原来只有集成级覆盖（② 端到端 63 条、②b 跨实现 6 条）——
#     它们每跑一次都要起服务端（秒级），所以「改一个定点函数」要等很久才知道。
#     更关键的是：集成测试**只走正常数据**，边界（钳位 / 字典越界 / 坏帧）
#     要么不出现，要么以「客户端画面怪怪的」形式出现 —— 那种症状没人归因到编码器。
def _snap_bin(n_ent=2, **kw):
    s = {
        "tick": 120, "t": 4.0, "iseq": 7,
        "player": {"id": 9001, "x": 12.5, "z": -3.25},
        "ents": [
            {"id": 100, "x": 1.0, "z": 2.0, "p": "wilson", "a": "idle_loop",
             "bld": None, "fr": 3, "f": 0.5},
            {"id": 101, "x": -2.0, "z": 0.0, "p": "tree", "a": "sway_loop",
             "bld": "tree_1", "fr": 0, "f": 1.25},
        ][:n_ent],
        "world": {"phase": "day", "season": "autumn", "isday": True,
                  "isdusk": False, "isnight": False, "temperature": 18.5},
        "paused": False,
    }
    s.update(kw)
    return s


def u25_protocol_roundtrip():
    """编码 → 解码逐字段一致（定点 1/16 的误差要**算得出来**，不是「差不多」）。"""
    from protocol_bin import BinEncoder, decode
    snap = _snap_bin()
    enc = BinEncoder()
    back = decode(enc.encode(snap), enc)
    tol = 1.0 / 16 + 1e-9
    bad = []
    if back["tick"] != snap["tick"] or back["iseq"] != snap["iseq"]:
        bad.append("tick/iseq")
    if abs(back["t"] - snap["t"]) > 1e-6:
        bad.append("t")
    if back["player"]["id"] != 9001 or abs(back["player"]["x"] - 12.5) > tol:
        bad.append("player")
    if [e["id"] for e in back["ents"]] != [100, 101]:
        bad.append("ids")
    if back["ents"][1]["p"] != "tree" or back["ents"][1]["bld"] != "tree_1":
        bad.append("字典")
    w = back["world"]
    if (w["phase"], w["season"], w["isday"], w["isdusk"], w["isnight"]) != \
            ("day", "autumn", True, False, False):
        bad.append("world")
    if abs(w["temperature"] - 18.5) > tol:
        bad.append("温度")
    return (not bad), ("player+2 ents+world 全字段一致" if not bad else "不符: %r" % (bad,))


def u26_protocol_i16_clamp():
    """定点**必须钳位**，不许回绕 —— 回绕的表现是「实体出现在世界另一边」。"""
    from protocol_bin import BinEncoder, decode
    hi, lo = 5000.0, -5000.0
    enc = BinEncoder()
    s = _snap_bin(n_ent=0, player=None,
                  ents=[{"id": 1, "x": hi, "z": lo, "p": None, "a": None,
                         "bld": None, "fr": 0, "f": 0.0}])
    e = decode(enc.encode(s), enc)["ents"][0]
    cap = 32767.0 / 16
    ok = e["x"] > 0 and abs(e["x"] - cap) < 0.1 and e["z"] < 0 and abs(e["z"] + cap) < 0.1
    return ok, "±5000 钳到 ±%.3f（未回绕成反号）" % (e["x"],)


def u27_protocol_dict_reuse():
    """字典是**连接级**的：同一批字符串的第二帧只带索引 ⇒ 字节数明显下降。"""
    from protocol_bin import BinEncoder, decode
    enc = BinEncoder()
    s = _snap_bin()
    b1 = enc.encode(s)
    b2 = enc.encode(s)
    back = decode(b2, enc)
    ok = (len(b2) < len(b1) * 0.8
          and back["ents"][0]["p"] == "wilson" and back["ents"][1]["a"] == "sway_loop")
    return ok, "第 1 帧 %d B → 第 2 帧 %d B（省 %.0f%%），解码仍对" % (
        len(b1), len(b2), 100.0 * (1 - len(b2) / float(len(b1))))


def u28_protocol_dict_miss_is_visible():
    """字典缺历史 ⇒ 返回 None 并**计数**，不许抛 IndexError（实测事故）。"""
    from protocol_bin import BinEncoder, decode
    enc = BinEncoder()
    enc.encode(_snap_bin())                     # 第 1 帧：带全字典
    enc.encode(_snap_bin())                     # 第 2 帧没有新字符串 ⇒ 全靠索引
    fresh = BinEncoder()                        # 模拟「客户端漏掉首帧就接上」
    try:
        out = decode(enc.encode(_snap_bin()), fresh)
        miss = getattr(fresh, "misses", 0)
        got_none = out["ents"][0]["p"] is None
        return (got_none and miss >= 1), "缺字典 ⇒ p=None 且 misses=%d（没抛异常）" % miss
    except IndexError:
        return False, "抛了 IndexError —— 正是注释里写的那个事故"


def u29_protocol_bad_frames_raise():
    """坏帧必须**明确拒绝**（ValueError + 说清哪一步），不是崩在随机下标上。"""
    from protocol_bin import decode, MAGIC0, MAGIC1, VERSION
    cases = {
        "太短": b"\x00\x01",
        "魔数": bytes([MAGIC0 ^ 0xFF, MAGIC1, VERSION, 0]),
        "版本": bytes([MAGIC0, MAGIC1, (VERSION + 1) & 0xFF, 0]),
        "过长varint": bytes([MAGIC0, MAGIC1, VERSION, 0]) + b"\x80" * 6,
    }
    got = {}
    for k, buf in cases.items():
        try:
            decode(buf)
            got[k] = "没抛"
        except ValueError:
            got[k] = "ValueError"
        except Exception as e:                                   # noqa: BLE001
            got[k] = type(e).__name__
    ok = all(v == "ValueError" for v in got.values())
    return ok, ("四类坏帧都 ValueError（%s）" % "、".join("%s=%s" % kv for kv in got.items())
                if ok else "不符: %r" % (got,))


def u30_protocol_paused_bit():
    """`paused` 走 flags 的 bit3：**零字节成本**，但客户端必须能读出来。

    ★ 为什么值得一条：世界停住时，「t 不涨」和「网络卡了」长得一模一样；
      靠猜的客户端会把「暂停」显示成「断线」。
    """
    from protocol_bin import BinEncoder, decode
    enc = BinEncoder()
    buf = enc.encode(_snap_bin(paused=True))
    bit = bool(buf[3] & 8)
    back = decode(buf, enc)["paused"]
    plain = decode(BinEncoder().encode(_snap_bin(paused=False)))["paused"]
    return (bit and back is True and plain is False), \
        "bit3=%s 且解码 paused=%r（对照：未暂停 ⇒ %r）" % (bit, back, plain)


def u31_protocol_id_delta():
    """id 用 **delta**：第二个 id 跳到 5000 也只多 1 个字节，且解码精确还原。"""
    from protocol_bin import BinEncoder, decode

    def enc_with(second_id):
        e = BinEncoder()
        s = _snap_bin(n_ent=2, player=None)
        s["ents"][1]["id"] = second_id
        return e, e.encode(s)

    e1, a = enc_with(101)
    e2, b = enc_with(5000)
    got = [x["id"] for x in decode(b, e2)["ents"]]
    d = len(b) - len(a)
    return (got == [100, 5000] and 0 <= d <= 2), \
        "id 101→5000 只多 %d 字节，解码得 %r" % (d, got)


def u32_protocol_truncation_is_valueerror():
    """**任何截断长度**都只能抛 `ValueError` —— 不许漏出 IndexError / struct.error。

    ★★ 实测依据（fuzz 4000 条，2026-10-20）：修之前
      `IndexError` 995 次、`struct.error` 约 300 次、`UnicodeDecodeError` 约 30 次。
      也就是说「帧短了两个字节」在日志里长得像「index out of range」，
      调用方写 `except ValueError` 根本接不住。截断是**真实场景**（TCP 半帧、录像被截尾）。
    """
    from protocol_bin import BinEncoder, decode
    full = BinEncoder().encode(_snap_bin())
    bad = {}
    for cut in range(1, len(full)):
        try:
            decode(full[:cut])
            bad[cut] = "没抛"
        except ValueError:
            pass
        except Exception as e:                                   # noqa: BLE001
            bad[cut] = type(e).__name__
    if bad:
        return False, "截断后有非 ValueError：%r" % (dict(list(bad.items())[:5]),)
    return True, "1..%d 每一个截断长度都抛 ValueError（%d 档）" % (len(full) - 1, len(full) - 1)


def u33_protocol_bad_utf8():
    """字典里的字节不是合法 utf-8 ⇒ `ValueError` 且**说得出是 utf-8**。"""
    import struct
    from protocol_bin import decode, _varint, MAGIC0, MAGIC1, VERSION
    buf = (bytes([MAGIC0, MAGIC1, VERSION, 0]) + _varint(0) + struct.pack("<f", 0.0)
           + _varint(0)                      # n = 0 个实体
           + _varint(0)                      # iseq
           + _varint(1)                      # 字典 1 条
           + _varint(2) + b"\xff\xfe")       # 声明 2 字节，内容不是 utf-8
    try:
        decode(buf)
        return False, "非法 utf-8 竟然解过去了"
    except ValueError as e:
        return ("utf-8" in str(e)), "ValueError 且提到 utf-8：%s" % str(e)[:60]
    except Exception as e:                                       # noqa: BLE001
        return False, "抛的是 %s（应为 ValueError）" % type(e).__name__


def u34_path_inside_sibling_prefix():
    """目录白名单必须按**路径分量**判，不能按字符串前缀。

    ★★ 这是 `startswith` 的经典坑：`.../rt2/x` 以 `.../rt` 开头 ⇒ 被当成「在 rt 里」。
      真实后果：`http_api` 的静态文件路由允许 `GET /../rt2/secret` 读走兄弟目录的文件。
      本判据同时断言 **旧写法会误判**（否则这条测试就是恒真的摆设）。
    """
    import os as _os
    from net import path_inside
    base = _os.path.join(_os.getcwd(), "rt")
    cases = {
        "在里面": _os.path.join(base, "client.html"),
        "在里面(..绕回)": _os.path.join(base, "sub", "..", "client.html"),
        "逃出去": _os.path.join(base, "..", "secret.txt"),
        "同前缀兄弟": base + "2" + _os.sep + "secret.txt",
    }
    got = {k: path_inside(base, v) for k, v in cases.items()}
    old_style = {k: _os.path.abspath(v).startswith(_os.path.abspath(base))
                 for k, v in cases.items()}
    ok = (got["在里面"] and got["在里面(..绕回)"]
          and not got["逃出去"] and not got["同前缀兄弟"]
          and old_style["同前缀兄弟"])          # ← 旧写法在这里是 True（错的）
    return ok, "4 种路径判定正确，且旧 startswith 在同前缀兄弟上确实误判（%s）" % \
        ("已复现" if old_style["同前缀兄弟"] else "未复现——这条测试失去意义")


def u35_path_inside_real_dirs():
    """用**真目录**再验一次：`a/` 与 `a2/` 并存时只认 `a/` 里的文件。"""
    import os as _os
    import tempfile
    from net import path_inside
    root = tempfile.mkdtemp(prefix="pinside_")
    try:
        base = _os.path.join(root, "a")
        sib = _os.path.join(root, "a2")
        _os.makedirs(base); _os.makedirs(sib)
        inside = _os.path.join(base, "ok.txt")
        outside = _os.path.join(sib, "secret.txt")
        for p in (inside, outside):
            with open(p, "w", encoding="utf-8") as f:
                f.write("x")
        # 从 base 出发能否走到 outside：`../a2/secret.txt`
        rel = _os.path.join("..", "a2", "secret.txt")
        walked = _os.path.normpath(_os.path.join(base, rel))
        ok = (path_inside(base, inside) and not path_inside(base, outside)
              and walked == outside)
        return ok, "a/ 内的文件放行；`../a2/secret.txt` 走到 %s 仍被拒" % _os.path.basename(walked)
    finally:
        import shutil
        shutil.rmtree(root, ignore_errors=True)


def u36_path_inside_cross_drive():
    """跨盘符/异构路径 ⇒ 一律 False（fail-closed：拿不准就拒）。"""
    import os as _os
    from net import path_inside
    base = _os.path.join(_os.getcwd(), "rt")
    cases = []
    if _os.name == "nt":
        cases.append(path_inside(base, "C:\\Windows\\win.ini"))     # 另一个盘
    cases.append(path_inside(base, _os.path.abspath(_os.sep)))      # 根目录
    cases.append(path_inside(base, base))                           # 自己算不算「里面」
    ok = (not any(cases[:-1]) and cases[-1] is True)
    return ok, "跨盘/根目录一律拒（%r），base 自身算在里（%r）" % (cases[:-1], cases[-1])


def u37_slots_html_never_raises():
    """`/status` 是**出故障时**才打开的页面 ⇒ 它自己不许被打成 500。

    ★★ 实测（2026-10-20，修之前）：
        `{"a": {...}}`  ⇒ ValueError: invalid literal for int() with base 10: 'a'
        `{"0": "notadict"}` ⇒ AttributeError: 'str' object has no attribute 'get'
      也就是说：只要引擎返回的 players 形状稍有不同（键不是槽位号、值是 None），
      你正要看的那一页就 500 了 —— **诊断面自己先死**。
    """
    from hub import _slots_html
    cases = {
        "空": {},
        "非数字键": {"a": {"alive": True, "health": 1}},
        "值不是 dict": {"0": "notadict"},
        "值是 None": {"0": None},
        "血量不是数字": {"0": {"alive": True, "health": "abc"}},
        "混合": {"0": {}, "x": {"alive": False}, "2": {"alive": True, "health": 5}},
    }
    bad = []
    for name, c in cases.items():
        try:
            out = _slots_html(c)
            if not isinstance(out, str) or not out:
                bad.append(name + "(空输出)")
        except Exception as e:                                   # noqa: BLE001
            bad.append("%s(%s)" % (name, type(e).__name__))
    return (not bad), ("六类畸形输入都返回可读文本" if not bad else "抛了: %r" % (bad,))


def u38_slots_html_escapes():
    """键当**文本**：`<script>` 必须变成 `&lt;script&gt;`（注入点不留给未来）。

    ★ 为什么还要直接测 `_esc`：组合断言（`_slots_html` 的输出）在「排序退回 int()」时
      会先抛 ValueError —— 那样这条判据虽然红，但红的是**排序**不是**转义**，
      两件事混在一个红灯里。分开断言才能各自定位。
    """
    from hub import _slots_html, _esc
    out = _slots_html({"<script>alert(1)</script>": {"alive": False}})
    raw_tag = "<script>" in out
    escaped = "&lt;script&gt;" in out
    direct = (_esc("<b>&") == "&lt;b&gt;&amp;")
    return (escaped and not raw_tag and direct), \
        "输出里是 &lt;script&gt;（原样 %s）；_esc(\"<b>&\")=%r" % (
            "仍在——没转义" if raw_tag else "不存在", _esc("<b>&"))


def u39_bad_save_is_quarantined():
    """读不动的存档必须**挪走留证**，不许留在原地等着被自动存档覆盖。

    ★★ 为什么（2026-10-20）：`try_load` 原来只是「报一句然后继续用新世界」，
      而自动存档 30 s 后就会**覆盖写**同一个路径 ⇒ 坏档在半分钟内消失，
      症状/时间点/内容全没了。修法是先改名成 `<path>.bad-<时间戳>`。
      这条判据同时断言「原路径已不存在」——否则等于没挪。
    """
    import io as _io
    import os as _os
    import tempfile
    from sim import Sim
    d = tempfile.mkdtemp(prefix="badsave_")
    p = _os.path.join(d, "s.json")
    try:
        with _io.open(p, "w", encoding="utf-8") as f:
            f.write("{ 这不是 json")
        ok, msg = Sim(seed=1, tick_hz=30).try_load(p)
        left = sorted(_os.listdir(d))
        moved = [n for n in left if ".bad-" in n]
        still = _os.path.exists(p)
        # ★ 每条都要**实测**后再拼文案。第一版把 `good` 写成 and 链、
        #   info 里写死「原文件已不存在」——变异（不让它挪）时 and 链在 `moved` 处
        #   就短路了，`not exists(p)` 根本没求值，可打印的却是「已不存在」。
        #   与「词在≠行为在」同源：**证据文本必须是量出来的，不是写好的**。
        in_msg = bool(moved) and moved[0] in msg
        good = bool(ok is False and moved and not still and in_msg)
        return good, "隔离=%s；原路径=%s；消息带文件名=%s" % (
            ("已挪成 %s" % moved[0]) if moved else "**没挪**",
            "仍在" if still else "已不存在",
            "是" if in_msg else "否")
    finally:
        import shutil
        shutil.rmtree(d, ignore_errors=True)


def u40_quarantine_names_do_not_collide():
    """同一秒内连坏两次，隔离文件名不许互相覆盖（`-1`、`-2`…）。

    ★ 注意这里必须用「每轮快照做差集」拿新文件，不能写 `n not in names`——
      `names` 是**列表的列表**，拿字符串去 `in` 它永远为 False，
      于是第二轮会把第一轮的文件也再收一遍，总数变 3、判据假红。
    """
    import io as _io
    import os as _os
    import tempfile
    from sim import Sim
    d = tempfile.mkdtemp(prefix="badsave2_")
    try:
        seen = set()
        fresh = []
        for _ in range(2):
            p = _os.path.join(d, "s.json")
            with _io.open(p, "w", encoding="utf-8") as f:
                f.write("坏")
            ok, msg = Sim(seed=1, tick_hz=30).try_load(p)
            now = {n for n in _os.listdir(d) if ".bad-" in n}
            fresh.append(sorted(now - seen))
            seen |= now
        flat = [n for sub in fresh for n in sub]
        good = len(flat) == 2 and len(set(flat)) == 2 and all(len(s) == 1 for s in fresh)
        return good, "两轮各新增 1 个、共 2 个不同文件名：%r" % (flat,)
    finally:
        import shutil
        shutil.rmtree(d, ignore_errors=True)


def u42_not_booted_blames_the_caller_not_the_save():
    """反向：没 boot 就存档，**必须明说是调用方的问题**，且**不许动存档文件**。

    ★★ 为什么这条值得单独立（2026-10-20 实测）：
      未 boot 时 `try_load` 原来的报错是
      `'NoneType' object has no attribute 'save_apply'` —— 指不出原因。
      更糟的是：`try_load` 把「`save_apply` 返回 False」一律当「存档读不动」
      ⇒ **改名隔离**。若真实原因是程序忘了 boot，那就是
      **程序缺陷把用户数据当垃圾扔掉**。
      ⇒ 所以这里三条一起断言：① 抛 SimNotBooted（不是 NoneType 的锅）
        ② 消息里说得出「引擎未启动」 ③ 存档文件**原地不动、没有 .bad-**
    """
    import io as _io
    import os as _os
    import tempfile
    from sim import Sim, SimNotBooted
    s = Sim(seed=1, tick_hz=30)                     # ★ 故意不 boot
    d = tempfile.mkdtemp(prefix="noboot_")
    p = _os.path.join(d, "s.json")
    try:
        with _io.open(p, "w", encoding="utf-8") as f:
            f.write('{"version": 4, "ents": []}')   # 内容本身没问题
        raised, why = None, ""
        try:
            s.save_apply({"version": 4, "ents": []})
        except SimNotBooted as e:
            raised, why = "save_apply", str(e)
        except Exception as e:                       # noqa: BLE001
            raised, why = type(e).__name__, str(e)
        raised2, why2 = None, ""
        try:
            s.try_load(p)
        except SimNotBooted as e:
            raised2, why2 = "try_load", str(e)
        except Exception as e:                       # noqa: BLE001
            raised2, why2 = type(e).__name__, str(e)
        left = sorted(_os.listdir(d))
        good = (raised == "save_apply" and raised2 == "try_load"
                and "引擎未启动" in why and "引擎未启动" in why2
                and left == ["s.json"])              # ★ 原文件还在、且只有一个
        return good, "两个入口都抛 SimNotBooted 且带原因；存档原地未动（目录 %r）" % (left,)
    finally:
        import shutil
        shutil.rmtree(d, ignore_errors=True)


def u43_filelist_cleanup_really_deletes_and_is_idempotent():
    """反向：目录清单的清理必须**真删掉**，且**删两次不抛**（幂等）。

    ★★ 为什么（2026-10-20 实测）：`Sim.boot()` 每次都建
      `%TEMP%\\rt_filelist_<pid>` 用来给 Lua 侧提供目录清单（M6 绕开 cmd.exe），
      而它**从来没人删**。实测一天下来堆了 **1251 个 / 45 MB** ——
      每跑一轮全量要 boot 几十次，泄漏是线性的。
      修法两道：① `atexit` 删自己的（只覆盖正常退出）；
                ② `check_leftovers.py --clean-temp` 按「pid 已不存在」收别人的。
      这里锁住①的函数本身：真的删掉、删两次不抛、父目录不许被误删。
    """
    import os as _os
    import tempfile
    from sim import _cleanup_filelist
    d = tempfile.mkdtemp(prefix="fl_")
    sub = _os.path.join(d, "rt_filelist_999")
    try:
        _os.makedirs(sub)
        with open(_os.path.join(sub, "behaviours.txt"), "w", encoding="utf-8") as f:
            f.write("a.lua\n")
        ok1 = _cleanup_filelist(sub)
        gone = not _os.path.exists(sub)
        ok2 = _cleanup_filelist(sub)                     # 幂等：已经不在了也不抛
        parent_kept = _os.path.isdir(d)                  # ★ 只删自己，不许往上删
        good = bool(ok1 and gone and ok2 and parent_kept)
        return good, "首次删=%s/目录已消失=%s；再删一次=%s（幂等）；父目录还在=%s" % (
            ok1, gone, ok2, parent_kept)
    finally:
        import shutil
        shutil.rmtree(d, ignore_errors=True)


def u44_counter_bump_is_single_entry_and_exact():
    """计数器的三条：**唯一入口（白名单）** / 并发下精确 / 读出来是同一把锁。

    ★★ 先给结论再说理由：实测 8 线程 × 5 万次 = **40 万次并发 `+=`，一次都没丢**
      （`sys.setswitchinterval(1e-6)` 也一样）。所以在 CPython 上
      「裸 `+=` 丢计数」**不是**一个可复现的 bug —— 本条判据**不是**在测那个。
      （负面结果照样记下来：不写「已修复丢计数」，因为没量到。）
    ★ 真正测的是这次改造给出的三样东西：
      ① `bump()` 只认白名单里的名字 —— 挡住「手滑写成 `bump("paused")`
         把暂停状态变成数字」这种后门（`setattr` 对任何名字都成立）；
      ② 并发下计数**精确**（回归保护：以后谁把 `bump` 改成「先读后写」的分步实现，
         40 万次里会很明显）；
      ③ `stats_snapshot()` 一次锁里读全 —— 不允许出现「发帧 100 / 字节 0」
         这种自相矛盾的一帧（原来逐个字段读，读一半被改就会这样）。
    """
    import threading
    from hub import Hub, _COUNTERS
    h = Hub()
    bad_name_raised = False
    try:
        h.bump("paused")
    except AttributeError:
        bad_name_raised = True
    except Exception:                                            # noqa: BLE001
        bad_name_raised = False

    n_thr, n_iter = 8, 50000
    def worker():
        for _ in range(n_iter):
            h.bump("frames_sent")
            h.bump("bytes_sent", 2)
    ts = [threading.Thread(target=worker) for _ in range(n_thr)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    want = n_thr * n_iter
    snap = h.stats_snapshot()
    exact = (snap["frames_sent"] == want and snap["bytes_sent"] == want * 2)
    # ② 快照里必须**恰好**是那 4 个统计项，不多不少（多一项说明有人往白名单里塞了别的）
    keys_ok = set(snap) == set(_COUNTERS)
    good = bool(bad_name_raised and exact and keys_ok)
    return good, ("非白名单名被拒=%s；%d 次并发计数精确=%s（发帧 %d/%d、字节 %d/%d）；"
                  "快照键=%s" % (bad_name_raised, n_thr * n_iter, exact,
                               snap["frames_sent"], want, snap["bytes_sent"], want * 2,
                               sorted(snap)))


# =============================================================================
# 汇总
# =============================================================================
def _host_default_problem(src):
    """从 server.py 源码里读出 `--host` 的默认值；返回问题描述（None = 没问题）。

    抽成函数是为了**让判据能对自己做反向**：把同一份逻辑喂给一份篡改过的源码，
    它必须报出问题。否则「默认绑回环」只是一句**声明**，没有任何东西守着它。
    """
    import re as _re
    m = _re.search(r'add_argument\("--host",\s*default="([^"]+)"\)', src)
    if m is None:
        return "在 server.py 里找不到 `--host` 的默认值声明（锚点变了 ⇒ 判据已失效）"
    host = m.group(1)
    if host not in ("127.0.0.1", "localhost"):
        return "`--host` 默认是 %r，不是回环地址 —— 起服就直接暴露到网络" % (host,)
    return None


def u45_default_bind_is_loopback():
    """★★★ P61「发布决策」落地：**默认只绑回环**，且这条决策有判据守着。

    决策（2026-10-21 定，取代 `发布检查单.md` §6 原来那个「待用户决定」）：
      · **形态 A（本机 / 内网）采纳** —— 默认 `127.0.0.1`，同一台机器开浏览器就能玩；
        要让同网段的人进来，必须**显式** `--host 0.0.0.0`（一次知情动作）。
      · **形态 B（公网）暂不执行** —— 需要一台能跑 Python 3.13 + lupa 的机器，
        本机不具备；**不假装发布过**，检查单里如实写着「未执行 + 前置条件」。

    为什么这条要写成判据、而不是只写在文档里：
      「默认绑定」是最容易被顺手改掉的一行 —— 想用手机看，第一反应就是改默认值；
      而改错的方向**恰好是危险的**（`0.0.0.0` + `--allow-debug` = 任何人都能 kill 角色）。
      文档拦不住这种改动，判据能。
    """
    path = os.path.join(RT, "server.py")
    with open(path, encoding="utf-8") as f:
        src = f.read()
    p = _host_default_problem(src)
    if p:
        return False, p
    # 反向：把默认改成 0.0.0.0，同一个函数必须报问题
    bad = src.replace('add_argument("--host", default="127.0.0.1")',
                      'add_argument("--host", default="0.0.0.0")')
    if bad == src:
        return False, "反向用例没改到（锚点已经不是那句话了）—— 这条判据守不住"
    if _host_default_problem(bad) is None:
        return False, "把默认改成 0.0.0.0 之后判据**仍然是绿的**"
    return True, "默认 --host=127.0.0.1；反向改成 0.0.0.0 会被抓住"


def u46_editor_gate_is_loopback_and_orthogonal_to_debug():
    """★★★ P62 编辑器通道的门槛：**本次请求来自回环**，且**与 --allow-debug 正交**。

    为什么门槛要分成两个（而不是顺手复用 `_debug_allowed`）：
      · `/debug/*` 是**运维**通道：默认关、要 `--allow-debug`、发布检查单明写「公网别开」；
      · `/editor/*` 是**本机开发工具**：诉求正相反 —— 打开就要能用。
      共用一个开关 = 让「想做编辑器」和「不想开运维口子」互相绑死。

    为什么这条必须写成判据（而不是只写在注释里）：
      最省事的写法是 `_editor_allowed` 直接 `return True`，理由是「反正服务只绑 127.0.0.1」。
      那一刻本机确实没问题 —— 但「服务只绑回环」和「这个端点只接受回环」是**两层**。
      把第二层删掉后，第一层一旦被 `--host 0.0.0.0` 打开（想用手机看画面时就会），
      编辑器就整个暴露了：能删对象、能挪玩家、能刷物品。
      这条判据把「两层」这个事实钉住，让删掉第二层的人当场红。
    """
    import http_api

    class Fake(object):
        """只要能拿到 client_address 与 allow_debug 就够 —— 不构造真 socket。"""
        _editor_allowed = http_api.HttpMixin._editor_allowed

        def __init__(self, peer, allow_debug=False):
            self.client_address = (peer, 12345)
            self.allow_debug = allow_debug

    # ① 回环的四种写法都要放行。
    #    `::ffff:127.0.0.1` 是双栈监听下的 IPv4 映射形式 —— 实测出现过，
    #    只认 `"127.0.0.1"` 的写法会在这类连接上「本机也打不开编辑器」。
    for peer in ("127.0.0.1", "::1", "::ffff:127.0.0.1", "localhost"):
        if not Fake(peer)._editor_allowed():
            return False, "回环来源被拒了：%r" % (peer,)

    # ② 非回环必须拒 —— 这条是整个判据的核心（反向）
    for peer in ("8.8.8.8", "192.168.1.5", "10.0.0.1", "0.0.0.0", ""):
        if Fake(peer)._editor_allowed():
            return False, "非回环来源被放行了：%r" % (peer,)

    # ③ 与 allow_debug 正交。这是最容易静默退化的地方：
    #    有人会图省事把实现改成 `return self._debug_allowed()` ——
    #    那一刻「本机还能用」，但外网只要开了 --allow-debug 也一起开了。
    if not Fake("127.0.0.1", allow_debug=False)._editor_allowed():
        return False, "--allow-debug 关着时编辑器被连坐关掉了（两个门槛被绑在一起）"
    if Fake("8.8.8.8", allow_debug=True)._editor_allowed():
        return False, "--allow-debug 开着就把外网也放进了编辑器 —— 门槛退化成了运维开关"

    # ④ 拿不到 client_address 时必须**拒**（缺信息 ≠ 放行）
    class NoPeer(object):
        _editor_allowed = http_api.HttpMixin._editor_allowed
    if NoPeer()._editor_allowed():
        return False, "没有 client_address 时被放行了 —— 缺信息不等于许可"

    return True, ("回环 4 种写法放行 / 外网 5 种拒绝 / 缺地址拒绝 / "
                  "与 --allow-debug 正交（关着能用、开着不放外网）")


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
    check("U37 反向：/status 的槽位摘要对畸形输入不抛", u37_slots_html_never_raises)
    check("U38 反向：槽位键当文本（HTML 转义）", u38_slots_html_escapes)

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

    print("\n── protocol_bin.py：二进制帧（服务端权威端）──")
    check("U25 编码→解码逐字段一致（含 world 块）", u25_protocol_roundtrip)
    check("U26 反向：定点越界**钳位**，不回绕", u26_protocol_i16_clamp)
    check("U27 字典连接级复用：第二帧只带索引", u27_protocol_dict_reuse)
    check("U28 反向：字典缺历史 ⇒ None + 计数，不抛 IndexError", u28_protocol_dict_miss_is_visible)
    check("U29 反向：四类坏帧都明确 ValueError", u29_protocol_bad_frames_raise)
    check("U30 paused 走 flags bit3（零字节成本）", u30_protocol_paused_bit)
    check("U31 id 用 delta（跳号不多花字节）", u31_protocol_id_delta)
    check("U32 反向：每个截断长度都只抛 ValueError", u32_protocol_truncation_is_valueerror)
    check("U33 反向：字典非法 utf-8 ⇒ ValueError", u33_protocol_bad_utf8)

    print("\n── net.py：目录白名单（静态文件 / 图集）──")
    check("U34 反向：同前缀兄弟目录不算「在里面」", u34_path_inside_sibling_prefix)
    check("U35 真目录回归：a/ 与 a2/ 并存时只认 a/", u35_path_inside_real_dirs)
    check("U36 反向：跨盘/根目录一律拒", u36_path_inside_cross_drive)

    print("\n── sim.py：构造期纪律 ──")
    check("U11 反向：Sim() 构造期不建 LuaRuntime", u11_sim_ctor_touches_no_lua)
    check("U39 反向：坏存档被隔离（原路径不再被覆盖）", u39_bad_save_is_quarantined)
    check("U40 反向：同秒连坏两次不互相覆盖", u40_quarantine_names_do_not_collide)
    check("U42 反向：没 boot 就存档 ⇒ 怪调用方，不许隔离存档", u42_not_booted_blames_the_caller_not_the_save)
    check("U43 反向：目录清单清理真删 + 幂等，且不往上删", u43_filelist_cleanup_really_deletes_and_is_idempotent)
    check("U44 计数器唯一入口 + 40 万次并发精确 + 快照同锁", u44_counter_bump_is_single_entry_and_exact)
    check("U45 发布决策落地：默认只绑 127.0.0.1；反向：改成 0.0.0.0 必红", u45_default_bind_is_loopback)
    check("U46 编辑器门槛=来源回环，且与 --allow-debug 正交；反向：外网必拒", u46_editor_gate_is_loopback_and_orthogonal_to_debug)

    print("\n" + "─" * 78)
    total = PASS + FAIL + SKIP
    if SKIP:
        print("  结果：%d 通过 / %d 失败 / %d 跳过（共 %d 条）（用例 %d 条）"
              % (PASS, FAIL, SKIP, total, total))
        skipped = [n for (n, ok, _i) in RESULTS if ok is None]
        print("  ⚠ 跳过**不算通过**：本次结论不覆盖 %s" % "、".join(s.split(" ")[0] for s in skipped))
    else:
        print("  结果：%d 通过 / %d 失败（共 %d 条）（用例 %d 条）"
              % (PASS, FAIL, total, total))
    # ★ 用例数自守：删掉几条用例、剩下全过，rc 仍是 0，而这份单测就在静默变松。
    if total != WANT_CASES:
        print("  ✘ 自检用例 %d 条，期望 %d 条 —— 加/删用例时必须同步 WANT_CASES，"
              "否则这条自检会静默变松" % (total, WANT_CASES))
    print("─" * 78)
    return 1 if (FAIL != 0 or total != WANT_CASES) else 0


if __name__ == "__main__":
    sys.exit(main())
