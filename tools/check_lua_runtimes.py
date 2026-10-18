#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_lua_runtimes.py —— 同一份 Lua 文件在**多个真实 Lua 运行时**下的编译结果

为什么要这个工具
    T8 的结论是「`components/weather.lua` 在本工程的 Lua 5.1 下编译不过」。
    但「编译不过」有两种完全不同的性质，必须区分清楚：
      · 代码有语法错     → 任何版本都不过，那是**缺陷**
      · 运行时有个硬上限 → 只有某些版本不过，那是**约束**
    光用 5.1 跑一次是分不出来的 —— 这正是本工程最常犯的错：
    「一个失败样本被当成了结论」。所以必须**多版本对照**。

它做什么
    对每个目标文件，在 lupa 提供的 7 个运行时里各做一次 `loadfile`：
        5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT 2.0 / LuaJIT 2.1
    **只编译、不执行** —— 因为我们的问题是编译期问题，
    而执行需要整套宿主环境（那会引入一堆无关的失败原因）。

用法
    python tools/check_lua_runtimes.py                       # 默认查 weather.lua
    python tools/check_lua_runtimes.py <file.lua> [more...]  # 查指定文件
    python tools/check_lua_runtimes.py --all                 # 查 dstsrc 全部 .lua（慢）

退出码
    0 = 所有文件在**至少 5.1** 上编译通过（本工程的主运行时）
    1 = 有文件在 5.1 上编译不过（会打印具体错误）
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DSTSRC = os.path.join(ROOT, "dstsrc", "scripts")

# 逻辑名 → lupa 子模块。顺序即输出的行序（5.1 在最前：它是本工程的主运行时）
RUNTIMES = [
    ("5.1", "lua51"),
    ("5.2", "lua52"),
    ("5.3", "lua53"),
    ("5.4", "lua54"),
    ("5.5", "lua55"),
    ("jit2.0", "luajit20"),
    ("jit2.1", "luajit21"),
]

# 统一的探测函数：**把结果折成一个字符串**在 Lua 侧返回。
#  ★ 为什么不在 Python 侧解包 `loadfile` 的多个返回值：
#    5.1 成功时返回 1 个值、失败时返回 2 个（nil, err）；
#    各版本的多返回值解包行为在 lupa 里不一致（实测 5.2+ 直接
#    `TypeError: iteration is only supported for tables`）。
#    折成字符串就没有这个歧义 —— 判据只看「OK / FAIL ...」。
PROBE = """
function(p)
    local fn, err = loadfile(p)
    if fn ~= nil then return "OK" end
    return "FAIL " .. tostring(err)
end
"""


def runtimes():
    """返回 [(逻辑名, LuaRuntime 类)]，跳过本机 lupa 没装的。"""
    out = []
    for name, mod in RUNTIMES:
        try:
            m = __import__("lupa." + mod, fromlist=["LuaRuntime"])
        except ImportError:
            continue
        out.append((name, m.LuaRuntime))
    return out


def check_file(path, rts):
    """返回 {逻辑名: "OK" 或 "FAIL <err>"}。"""
    res = {}
    for name, cls in rts:
        L = cls(unpack_returned_tuples=True)
        probe = L.eval(PROBE)
        try:
            res[name] = str(probe(path))
        except Exception as e:                                   # noqa: BLE001
            res[name] = "ERR %s: %s" % (type(e).__name__, e)
    return res


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    if "--all" in argv:
        files = []
        for dirpath, _dirnames, filenames in os.walk(DSTSRC):
            for fn in filenames:
                if fn.endswith(".lua"):
                    files.append(os.path.join(dirpath, fn))
        files.sort()
    elif args:
        files = [os.path.abspath(a) for a in args]
    else:
        files = [os.path.join(DSTSRC, "components", "weather.lua")]

    rts = runtimes()
    if not rts:
        print("!! lupa 一个运行时都没有")
        return 1
    print("运行时：%s" % ", ".join(n for n, _ in rts))
    print("")

    bad51 = []
    for path in files:
        if not os.path.exists(path):
            print("!! 文件不存在：%s" % path)
            bad51.append(path)
            continue
        res = check_file(path, rts)
        rel = os.path.relpath(path, ROOT)
        v51 = res.get("5.1", "SKIP")
        mark = "✔" if v51 == "OK" else "✘"
        print("%s %s" % (mark, rel))
        for name, _ in rts:
            print("    %-7s %s" % (name, res.get(name, "SKIP")))
        if v51 != "OK":
            bad51.append(rel)
        print("")

    print("─" * 70)
    if bad51:
        print("5.1 下编译不过：%d 个" % len(bad51))
        for f in bad51:
            print("  · %s" % f)
        print("")
        print("★ 判断口径：若某个文件**只在 5.1/LuaJIT 下失败、5.2+ 全部通过**，")
        print("  那不是代码缺陷，而是运行时的硬上限（见 06-引擎复刻/host/26_boundaries.lua")
        print("  里 CLASS.LUA51_UPVALUE 那条**有条件的**规则）。")
        return 1
    print("全部在 5.1 下编译通过")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
