#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Lua 测试运行器（真实 Lua 虚拟机，非模拟器）

本机没有独立的 lua 可执行文件，这里用 lupa —— 它把**真实的 Lua 解释器**
以库的形式嵌入 Python。lupa 2.8 同时提供 lua51 / lua52 / lua53 / lua54 /
lua55 / luajit20 / luajit21 多个运行时，因此可以跨多个 Lua 版本验证代码，
而不只是某一个。

用法:
    python _run_lua.py 5.1 01_class.lua
    python _run_lua.py 5.4 main.lua
    python _run_lua.py all main.lua      # 在 5.1/5.3/5.4/LuaJIT 全部跑一遍

退出码: 0 = 全部通过；非 0 = 有模块失败
"""
import os
import sys
import traceback

BASE = os.path.dirname(os.path.abspath(__file__))

# 逻辑名 -> lupa 子模块
RUNTIMES = {
    "5.1": "lua51",
    "5.2": "lua52",
    "5.3": "lua53",
    "5.4": "lua54",
    "5.5": "lua55",
    "jit2.0": "luajit20",
    "jit2.1": "luajit21",
}


def run_one(version, script, prelude=None):
    import lupa
    mod = RUNTIMES[version]
    try:
        rtmod = __import__("lupa." + mod, fromlist=["LuaRuntime"])
    except ImportError:
        print("  [SKIP] lupa 未提供 %s (%s) 运行时" % (version, mod))
        return None

    # ★ 这里**保持默认的严格 UTF-8**，两条「绕过去」的路都试过、都不行：
    #
    #   症状：游戏里任何一个 print 打出**非 UTF-8 字节**时，
    #        lupa 在 `p_from_lua` 里抛 UnicodeDecodeError，
    #        **整个入口直接 FAIL，而真正的出错行被完全淹没**。
    #        崩溃点在 runner，症状却指向被测代码 —— 最坏的一种误导。
    #
    #   绕法一：`errors='replace'` —— lupa **不接受**这个参数，直接 TypeError。
    #   绕法二：`encoding='latin1'` —— 逐字节无损、永不抛异常，但**编不进去中文路径**
    #        （本 runner 要把 `E:/.../03-参考架构` 发给 Lua），
    #        立刻变成 UnicodeEncodeError，反而更早崩。
    #
    #   ⇒ 结论：只能在**游戏侧**根治 —— 谁打印坏字节就改谁。
    #      （本轮加 crow/dustmoth/eyeplant 时触发，已定位并修掉。）
    L = rtmod.LuaRuntime(unpack_returned_tuples=True)
    # package.path 指向本目录，使 require("01_class") 能找到 01_class.lua。
    # 注意：Windows 路径里的反斜杠必须转义后再塞进 Lua 字符串字面量。
    lua_base = BASE.replace("\\", "/").replace("%", "%%")
    L.execute('package.path = "%s/?.lua;%s/?/init.lua;" .. package.path' % (lua_base, lua_base))
    # 模拟 `lua <script>` 的命令行参数，让各模块的 IS_MAIN_CHUNK() 能正确判定
    L.execute('arg = { [0] = "%s" }' % script.replace("\\", "/"))
    version_str = str(L.eval("_VERSION"))

    # ★ C7：可选**前置垫片**（`--prelude host/compat52.lua`）。
    #   为什么放在这里：5.2+ 移走了 loadstring/setfenv/unpack 等 5.1 全局，
    #   而原版 4030 个脚本一行都不能改 ⇒ 只能在入口脚本**之前**补回全局环境。
    #   ⚠️ 垫片先于入口执行，且是**同一个全局环境**（不是独立沙箱）——
    #     这一点刻意如此：要验的是"5.2+ 能不能跑起来"，不是"能不能塞进沙箱"。
    if prelude:
        p_path = prelude if os.path.isabs(prelude) else os.path.join(BASE, "..", "06-引擎复刻", prelude)
        p_path = os.path.abspath(p_path)
        if not os.path.isfile(p_path):
            print("!!! 垫片不存在：%s" % p_path)
            return False
        with open(p_path, "r", encoding="utf-8") as f:
            p_code = f.read()
        L.globals()["__prelude__"] = p_code
        loader0 = L.eval("(loadstring or load)")
        r0 = loader0(L.globals()["__prelude__"], "@" + os.path.basename(p_path))
        ch0 = r0[0] if isinstance(r0, tuple) else r0
        if ch0 is None:
            print("!!! 垫片编译失败：%s" % (r0,))
            return False
        try:
            ch0()
        except Exception:                                        # noqa: BLE001
            print("!!! 垫片执行失败：")
            traceback.print_exc()
            return False

    lua_file = os.path.join(BASE, script)
    with open(lua_file, "r", encoding="utf-8") as f:
        code = f.read()

    print("-" * 70)
    print(">>> Lua %s (%s)  运行  %s" % (version_str, mod, script))
    print("-" * 70)

    try:
        # 用 load/loadstring 编译后调用（无参数），这样主 chunk 的 ... 为 nil，
        # 与 `lua script.lua` 的语义一致。
        # 注意：Lua 5.1 的 load() 只接受函数，字符串要用 loadstring。
        L.globals()["__code__"] = code
        loader = L.eval("(loadstring or load)")
        res = loader(L.globals()["__code__"], "@" + script)
        # loadstring 返回 (chunk, err) 两个值；lupa 在 unpack_returned_tuples=True
        # 下会把多返回值表示成 Python tuple，所以这里取第一个元素。
        chunk = res[0] if isinstance(res, tuple) else res
        if chunk is None:
            # ★★★ 编译失败的信息**必须解码安全地取出来**。
            #
            #   踩过的坑：`RuntimeError("compile failed: %s" % res[1])` 这行本身没问题，
            #   但真正炸的是**更早一步** —— lupa 在 unpack 多返回值时就要把
            #   Lua 的错误串解码成 Python str，而宿主加载的 prefabs 里
            #   有非 UTF-8 字节 ⇒ 抛 UnicodeDecodeError。
            #   结果：一个「第 263 行语法错误」被报成
            #        `UnicodeDecodeError: can't decode byte 0xe8 in position 71`
            #   —— **症状指向编码，真因是语法**，排查方向被完全带偏。
            #   （这一轮为此绕了半小时：先怀疑新生物、再怀疑宿主文件、
            #     再怀疑 runner 编码设置，全是错方向。）
            #
            #   修法：让 Lua 侧把错误串**逐字节转成数字再拼成纯 ASCII** 回来，
            #   这样无论原始字节是什么，Python 侧都一定解得开。
            esc = L.eval("function(e) local t={} for i=1,#e do t[i]=string.byte(e,i) end "
                         "return table.concat(t,',') end")(
                (res[1] if isinstance(res, tuple) else res) or "")
            raw = bytes(int(x) for x in str(esc).split(",") if x.strip())
            raise RuntimeError("compile failed: %s  [raw bytes: %s]"
                               % (raw.decode("utf-8", "replace"), raw[:120]))
        chunk()
        return True
    except Exception:
        print("!!! 运行时错误 (Lua %s, %s):" % (version_str, script))
        traceback.print_exc()
        # 把 Lua 侧错误信息也打出来
        try:
            print("Lua traceback:", L.eval("__last_error__") or "(n/a)")
        except Exception:
            pass
        return False


def main():
    argv = sys.argv[1:]
    prelude = None
    # ★ C7：`--prelude PATH` 可以出现在任意位置（放在版本/脚本前后都行），
    #   取走后剩下的仍是原来的「版本 脚本」两参数形式 —— 老的调用方式一个字不用改。
    if "--prelude" in argv:
        i = argv.index("--prelude")
        if i + 1 >= len(argv):
            print("--prelude 需要跟一个路径")
            return 2
        prelude = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]

    if len(argv) < 2:
        print(__doc__)
        return 2

    version = argv[0]
    script = argv[1]

    if version == "all":
        targets = ["5.1", "5.3", "5.4", "jit2.1"]
    elif version in RUNTIMES:
        targets = [version]
    else:
        print("未知运行时 %r，可选: %s, all" % (version, ", ".join(RUNTIMES)))
        return 2

    results = {}
    for v in targets:
        results[v] = run_one(v, script, prelude=prelude)
        print()

    print("=" * 70)
    print("汇总:")
    any_fail = False
    for v, ok in results.items():
        if ok is None:
            print("  %-8s SKIP" % v)
        elif ok:
            print("  %-8s PASS" % v)
        else:
            print("  %-8s FAIL" % v)
            any_fail = True
    print("=" * 70)
    return 1 if any_fail else 0


if __name__ == "__main__":
    sys.exit(main())