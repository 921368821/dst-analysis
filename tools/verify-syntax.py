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

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _has(p):
    return os.path.isfile(os.path.join(p, "components", "health.lua"))


def _ann_root(sub=""):
    """注释版根：固定取 02-注释源码/scripts（它就是「我们要体检的那棵树」）。"""
    c = os.path.join(_ROOT, "02-注释源码", "scripts")
    if not _has(c):
        raise RuntimeError("找不到注释版根：02-注释源码/scripts/components/health.lua")
    return os.path.join(c, sub) if sub else c


def _src_root():
    """原版根：$DST_PRISTINE → _baseline/pristine-scripts → dstsrc/scripts。

    ★★ 关键：**必须排除「和注释版是同一棵树」的候选**。
       本脚本 v1 直接把 `_dst_src()` 同时赋给 SRC 和 ANN ——
       而 `dstsrc` 是指向 `02-注释源码` 的联接，于是 `SRC == ANN`：
       「注释版编不过」在「原版」那里必然也编不过 ⇒ 一律记成**基线**，
       `★ 真缺陷` 恒为 0。SOP 里说「这是唯一能抓出注释引入语法错误的工具」，
       而它当时**根本没有判据**（原版副本丢失后一直如此）。
       ⇒ 现在：拿不到**真正不同**的原版根，就返回 None，由 main() 明确报「未分类」。
    """
    cands = [
        os.environ.get("DST_PRISTINE", ""),
        os.path.join(_ROOT, "_baseline", "pristine-scripts"),
        os.path.join(_ROOT, "dstsrc-pristine", "scripts"),
        os.path.join(_ROOT, "dstsrc", "scripts"),
    ]
    ann = _ann_root()
    for c in cands:
        if not c or not _has(c):
            continue
        try:
            if os.path.samefile(c, ann):   # 自己比自己 ⇒ 不是基线
                continue
        except OSError:
            continue
        return c
    return None


ANN = _ann_root()
SRC = _src_root()
HAS_BASELINE = SRC is not None

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
    checked = baseline = real = unknown = 0
    problems = []
    unknowns = []

    for dirpath, _dirs, files in os.walk(ANN):
        for name in files:
            if not name.endswith(".lua"):
                continue
            ann_path = os.path.join(dirpath, name)
            rel = os.path.relpath(ann_path, ANN)
            checked += 1
            ann_text = read(ann_path)
            if compile_ok(ann_text):
                continue

            if not HAS_BASELINE:
                # ★ 没有真正不同的原版根 ⇒ **无法分类**。
                #   记成「基线」就是自我欺骗：那等于宣称「原版也编不过」，
                #   而我们根本没看过原版。
                unknown += 1
                unknowns.append((rel, _msg(ann_text)))
                continue

            src_path = os.path.join(SRC, rel)
            if not os.path.exists(src_path):
                unknown += 1
                unknowns.append((rel, "原版缺该文件，无法判定是谁的问题"))
                continue
            # 原版是已编译字节码的（\x1bLuaQ），无法用 load() 比对
            with open(src_path, "rb") as f:
                if f.read(5) == b"\x1bLuaQ":
                    unknown += 1
                    unknowns.append((rel, "原版是字节码，无法用 load() 对照"))
                    continue
            if compile_ok(read(src_path)):
                real += 1
                problems.append((rel, _msg(ann_text)))
            else:
                baseline += 1
                if not quiet:
                    print(f"  [基线] {rel}  （原版在 Lua 5.5 下同样编不过）")

    print()
    print(f"已检查注释文件 : {checked}")
    if HAS_BASELINE:
        print(f"原版根         : {SRC}")
        print(f"基线问题       : {baseline}  （原版同样失败，非本次引入）")
        print(f"★ 真缺陷       : {real}")
    else:
        print(f"原版根         : ⊘ 无（找不到与注释版**不同**的原版树）")
        print(f"★ 真缺陷       : ⊘ 无法判定 —— {unknown} 个文件编不过，但**没有基线可比**")
        print("                  ⇒ 这些既不能记「基线」（没看过原版），也不能记「真缺陷」（可能本来就有）。")
        print("                  ⇒ 修法：按 M9 用 `bash tools/archive-pristine.sh <原版 scripts 根>` 归档，")
        print("                     或用 DST_PRISTINE=<原版根> 指过去，再重跑本脚本。")
    for rel, msg in problems:
        print(f"   ❌ {rel}\n      {msg}")
    if unknown and not quiet:
        show = len(unknowns) if HAS_BASELINE else min(len(unknowns), 30)
        for rel, msg in unknowns[:show]:
            print(f"   ⚠ {rel}\n      {msg}")
        if len(unknowns) > show:
            print(f"   ...另有 {len(unknowns) - show} 个")

    if real:
        return 1
    if not HAS_BASELINE:
        # 3 = 「跑了，但判据不成立」。与 0（真的没问题）严格分开。
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
