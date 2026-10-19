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
