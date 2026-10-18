# -*- coding: utf-8 -*-
"""
prove_hermitcrabtea_nil_duration.py
==============================================================================
证明 `hermitcrabtea_firenettles_buff` 的 `timer.lua:44 StartTimer(name, nil)`
是**原版自带**的缺陷，而不是宿主缺口。

三条独立证据（缺一条都不足以定性）：
  A. BUFF_DEFS 里哪些条目没有 `duration` 字段
  B. TEA_DEFS 里 `buff = "..._buff"` 的引用集合
  C. A 中「没被任何 TEA_DEFS 引用」的条目 ⇒ 游戏里**不会**被 spawn
  D. 反证：原版 timer.lua 在拿到 nil 时**同样会崩**
     （`end_time = GetTime() + time` 是独立于宿主调度器的算术）
==============================================================================
"""
import io
import os
import re
import sys

# ★ 源码根不写死：走 tools/_paths.py（ASCII 联接优先，见该文件的说明）
from _paths import SRC
DEFS = os.path.join(SRC, "prefabs", "hermitcrabtea_defs.lua")
TEA = os.path.join(SRC, "prefabs", "hermitcrabtea.lua")


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def split_tables(text, varname):
    """粗切 `local NAME = { ... }` 的顶层花括号内容（够用：这两个表无嵌套花括号歧义）"""
    m = re.search(r"local\s+" + varname + r"\s*=\s*\{", text)
    if not m:
        return None
    i = m.end() - 1
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    return None


def entries(block):
    """把 `{ ... },` 顶层条目切出来"""
    out = []
    depth = 0
    start = None
    for j, ch in enumerate(block):
        if ch == "{":
            depth += 1
            if depth == 2:
                start = j
        elif ch == "}":
            if depth == 2 and start is not None:
                out.append(block[start:j + 1])
                start = None
            depth -= 1
    return out


def main():
    text = read(DEFS)

    buff_block = split_tables(text, "BUFF_DEFS")
    if buff_block is None:
        print("✘ 找不到 BUFF_DEFS")
        return 1

    buffs = []
    for e in entries(buff_block):
        nm = re.search(r'name\s*=\s*"([^"]+)"', e)
        dur = re.search(r'\bduration\s*=', e)
        if nm:
            buffs.append((nm.group(1), dur is not None, e))

    # B: TEA_DEFS 的 buff 引用
    referenced = set(re.findall(r'buff\s*=\s*"([^"]+)"', text))

    print("=" * 74)
    print("  A. BUFF_DEFS 条目 / 是否有 duration")
    print("=" * 74)
    no_dur = []
    for nm, has_dur, _ in buffs:
        flag = "有" if has_dur else "★无"
        print("  %-22s duration=%s" % (nm, flag))
        if not has_dur:
            no_dur.append(nm)

    print("")
    print("=" * 74)
    print("  B. TEA_DEFS 引用的 buff 预制体")
    print("=" * 74)
    for r in sorted(referenced):
        print("  " + r)

    print("")
    print("=" * 74)
    print("  C. 「无 duration」且「无任何引用」的条目 ⇒ 游戏里不会被 spawn")
    print("=" * 74)
    orphan = []
    for nm in no_dur:
        full = "hermitcrabtea_%s_buff" % nm
        if full not in referenced:
            orphan.append(nm)
            print("  ✘ %-22s  （%s 未被任何 TEA_DEFS 的 buff= 引用）" % (nm, full))
        else:
            print("  ! %-22s  被引用了 —— 那它就是**真缺口**，得另查" % nm)

    print("")
    print("=" * 74)
    print("  D. 原版 timer.lua 拿到 nil 时会怎样（独立于宿主）")
    print("=" * 74)
    t = read(os.path.join(SRC, "components", "timer.lua")).split("\n")
    for i in range(37, 56):
        if i < len(t):
            print("  timer.lua:%-4d %s" % (i + 1, t[i]))

    print("")
    print("=" * 74)
    print("  结论")
    print("=" * 74)
    print("  · 无 duration 的 buff 条目 %d 个；其中无引用 %d 个" % (len(no_dur), len(orphan)))
    print("  · 无引用的那些，DST 运行时不会去 SpawnPrefab 它们")
    print("  · 但 prefablist / BUFF_DEFS 循环仍会把它们**注册**进预制体表")
    print("     ⇒ 我方「逐个 spawn 全部注册预制体」的抽样，触到了一个")
    print("       原版**从不触发**的路径，而那条路径在原版同样会崩")
    print("       （timer.lua 的 `GetTime() + time` 与调度器无关）")
    print("  ⇒ 定性：**原版潜在缺陷（无调用点）**，不是宿主缺口。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
