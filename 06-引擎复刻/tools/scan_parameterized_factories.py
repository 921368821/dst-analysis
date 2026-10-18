#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
scan_parameterized_factories.py
==============================================================================
扫出「被直接注册、但工厂声明了首参」的预制体
==============================================================================
为什么需要它
    `carnivaldecor_figure` 用 `SpawnPrefab(name)` 生成时报：
        prefabs/carnivaldecor_figure.lua:189: attempt to index local 'data' (a nil value)
    它的注册是 `Prefab("carnivaldecor_figure", fn_season1, ...)`，而
    `fn_season1(data)` 把 `data` 原样转给 `fn(data, 1, bank)`。
    ⇒ 只要引擎不传参，`data` 就是 nil。

    DST 自身的**主流约定**是「引擎无参调用工厂，需要数据就自己包一层」：
        oar.lua:152             local function oar() return fn(CONST, "oar", ...) end
        schoolherd.lua:172      Prefab(..., function() return fn(data) end, ...)
        cotl_tabernacle.lua:324 local function fn_lvl1() return fn(data[1]) end
    这三处都显式包了无参 wrapper。

    但**无法从脚本内部**排除「引擎其实会传 (name, skin)」这一可能：
    若传，`data` 是**字符串** ⇒ 索引字符串只得到 nil、不崩（这能解释
    carnival 系列的雕像在游戏里是正常的）。⇒ 定性只能是「待定」。

为什么用静态扫描而不是运行时反射
    ✘ `debug.getinfo(fn, "u").nparams` —— 本工程的 Lua 5.1 实现里**恒为 nil**
       （`nups` 有值、`nparams` 没有）。
    ✘ `debug.getlocal(fn, 1)` —— Lua 5.1 的签名是 `getlocal(level, local)`，
       要栈层号，不能传函数对象。
    ⇒ 只能静态看源码。这也符合本工程一贯做法：**能从源码提取就别靠运行时猜**。

判据（三条同时成立才计入）
    ① 文件里有 `local function NAME(` 且第一个参数名不是 `(` 后紧跟 `)`
    ② 该 NAME 被 `Prefab("字面量名", NAME` 形式**直接**注册
    ③ 同名文件里没有 `function() return NAME(` 这种无参 wrapper

用法
    python tools/scan_parameterized_factories.py            # 打清单
    python tools/scan_parameterized_factories.py --count    # 只打数量
退出码：0 = 扫描完成（有命中也返回 0，命中本身不是错误）
==============================================================================
"""

import io
import os
import re
import sys

# ★ 源码根不写死：走 tools/_paths.py（ASCII 联接优先，见该文件的说明）
from _paths import SRC
PF = os.path.join(SRC, "prefabs")

# 已知的「引擎无参调用」正面证据（wrapper 写法），供报告引用
WRAPPER_EVIDENCE = [
    "prefabs/oar.lua:152",
    "prefabs/schoolherd.lua:172",
    "prefabs/cotl_tabernacle.lua:324",
]


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def strip_comments(text):
    """去掉 Lua 注释与字符串字面量，避免把**注释里**的注册当真的。

    ★★ 为什么要这一步（实测踩到，不是预防性设计）：
       `prefabs/farmplot.lua:375` 写的是
           return --Prefab("farmplot",  plot(1), assets, prefabs),
       —— 那句注册**被注释掉了**（DST 用 slow_farmplot / fast_farmplot 取代了它）。
       第一版扫描器不剥注释，于是扫出 `farmplot` 这条**根本不存在的注册**，
       它在可达性抽样里表现为「未注册」，我还差点把它记成宿主缺口。

    ⚠️ 边界：这里用正则剥注释，不解析字符串转义。
       对 DST 这类代码足够（注释里出现 `--` 的字符串极少），
       但**不是**一个完整的 Lua 词法分析器 —— 如实标注。
    """
    # 长注释 --[[ ... ]] / --[==[ ... ]==]（`=*` 同时覆盖 0 个与多个 `=`）
    text = re.sub(r"--\[=*\[.*?\]=\]", " ", text, flags=re.S)
    # 行注释（不处理「字符串里出现 --」这种情况，见边界说明）
    text = re.sub(r"--[^\n]*", " ", text)
    return text


def scan():
    hits = []
    files = sorted(f for f in os.listdir(PF) if f.endswith(".lua"))
    for fname in files:
        raw = read(os.path.join(PF, fname))
        text = strip_comments(raw)
        # ① 记录本文件里所有「首参非空」的 local function
        param_fns = {}
        for m in re.finditer(r"local\s+function\s+([A-Za-z_]\w*)\s*\(\s*([A-Za-z_]\w*)", text):
            param_fns[m.group(1)] = m.group(2)
        if not param_fns:
            continue
        # ③ 本文件里存在无参 wrapper（`function() return X(` 或 `function () return X(`）
        wrapped = set(re.findall(r"function\s*\(\s*\)\s*return\s+([A-Za-z_]\w*)\s*\(", text))
        # ② 直接注册：Prefab("字面量", NAME,  或  Prefab("字面量", NAME)
        #   ★★ 结尾必须是 `,` 或 `)` —— 否则 `Prefab("farmplot", plot(1), ...)`
        #      里的 `plot` 会被当成「工厂函数引用」，而它是**调用**。
        #      第一版就漏了这个负向条件（又是「判据错，不是代码错」）。
        for m in re.finditer(r'Prefab\(\s*"([^"]+)"\s*,\s*([A-Za-z_]\w*)\s*[,)]', text):
            prefabname, fnname = m.group(1), m.group(2)
            if fnname in param_fns and fnname not in wrapped:
                hits.append({
                    "prefab": prefabname,
                    "file": os.path.join("prefabs", fname),
                    "fn": fnname,
                    "firstparam": param_fns[fnname],
                    "line": text[:m.start()].count("\n") + 1,
                })
    return hits


def main():
    only_count = "--count" in sys.argv
    hits = scan()

    if only_count:
        print(len(hits))
        return 0

    print("=" * 78)
    print("  「被直接注册、但工厂声明了首参」的预制体")
    print("=" * 78)
    if not hits:
        print("  （无命中）")
    for h in hits:
        print("  %-34s %s" % (h["prefab"], h["file"]))
        print("      %-28s fn=%s(%s)  注册行 %d"
              % ("", h["fn"], h["firstparam"], h["line"]))
    print("")
    print("  命中 %d 条" % len(hits))
    print("")
    print("  ★ 对照：DST 主流的「无参 wrapper」写法（正面证据）")
    for e in WRAPPER_EVIDENCE:
        print("      " + e)
    print("")
    print("  定性（见 host/26_boundaries.lua 「待定(工厂声明参数)」）：")
    print("    · 引擎若不传参 ⇒ data 恒 nil ⇒ 原版自身缺陷")
    print("    · 引擎若传 (name, skin) ⇒ data 是字符串 ⇒ 索引得 nil、不崩")
    print("    · 脚本内部**无法区分**这两种 ⇒ 记为待定，不写成定论")
    return 0


if __name__ == "__main__":
    sys.exit(main())
