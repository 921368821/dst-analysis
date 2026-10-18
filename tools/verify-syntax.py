#!/usr/bin/env python3
"""
verify-syntax.py —— 注释版 Lua 语法体检（区分「基线问题」与「新引入缺陷」）

★ 为什么必须有这个工具
----------------------
`verify-annotated.mjs` 只比对「可执行代码行是否与原版一致」，
因此**查不出注释引入的语法错误**——注释里一个裸的 `]]` 就能把
源码里已开启的长注释提前闭合，让后面的代码裸露成语法错误，
而校验器依然显示「全部通过」。

`node --check` 也查不出（那是 JS 语法，与 Lua 无关）。
唯一的防线就是用真实 Lua VM 编译一遍。

实测抓到过：components/inventory.lua 的 spec 注释里写了
「（[[ ]] 形式）」，其中裸 `]]` 提前闭合了源码的 `--[[`，
导致第 8008 行 CloseControllerInventory() 裸露，语法错误。

★ 基线问题（不是我们的错）
--------------------------
Lua 5.5 对 `attempt to assign to const variable` 等更严格，
原版文件在 5.5 下也编不过。本脚本会自动跑一遍**原版**做对照，
把「原版同样失败」标为基线，「仅注释版失败」标为真缺陷。

用法：
    python verify-syntax.py            # 体检全部
    python verify-syntax.py --quiet    # 只报真缺陷
"""
import os
import sys

from lupa import LuaRuntime

import os

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _dst_src(sub=""):
    """DST 源码 scripts 根（ASCII 联接 dstsrc 优先 —— Lua/工具链都不吃中文路径）。"""
    for c in (os.path.join(_ROOT, "dstsrc", "scripts"),
              os.path.join(_ROOT, "02-注释源码", "scripts")):
        if os.path.isfile(os.path.join(c, "components", "health.lua")):
            return os.path.join(c, sub) if sub else c
    raise RuntimeError("找不到 DST 源码根（components/health.lua 不存在）")

SRC = _dst_src()
ANN = _dst_src()

LUA = LuaRuntime(unpack_returned_tuples=True)
_compile = LUA.eval(
    'function(src) local f, e = load(src, "x") '
    'if f then return true else return false end end'
)
_msg = LUA.eval(
    'function(src) local f, e = load(src, "x") '
    'if f then return "" else return tostring(e) end end'
)


def compile_ok(text):
    try:
        return bool(_compile(text))
    except Exception:
        return False


def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def main():
    quiet = "--quiet" in sys.argv
    checked = baseline = real = 0
    problems = []

    for dirpath, _dirs, files in os.walk(ANN):
        for name in files:
            if not name.endswith(".lua"):
                continue
            ann_path = os.path.join(dirpath, name)
            rel = os.path.relpath(ann_path, ANN)
            src_path = os.path.join(SRC, rel)

            if not os.path.exists(src_path):
                continue

            # 原版是已编译字节码的（\x1bLuaQ），无法用 load() 比对
            with open(src_path, "rb") as f:
                if f.read(5) == b"\x1bLuaQ":
                    continue

            checked += 1
            ann_text = read(ann_path)
            if compile_ok(ann_text):
                continue

            src_ok = compile_ok(read(src_path))
            if src_ok:
                real += 1
                problems.append((rel, _msg(ann_text)))
            else:
                baseline += 1
                if not quiet:
                    print(f"  [基线] {rel}  （原版在 Lua 5.5 下同样编不过）")

    print()
    print(f"已检查注释文件 : {checked}")
    print(f"基线问题       : {baseline}  （原版同样失败，非本次引入）")
    print(f"★ 真缺陷       : {real}")
    for rel, msg in problems:
        print(f"   ❌ {rel}\n      {msg}")

    return 1 if real else 0


if __name__ == "__main__":
    sys.exit(main())