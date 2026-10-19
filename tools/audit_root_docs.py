#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""audit_root_docs.py —— 根目录文档的「过期基线数字」守卫（H6）

为什么需要它
    `07-通用引擎/tools/verify_plan.py` 只核对 `07-通用引擎/` 下的 .md，
    它的扫描根是那个目录。而**根目录**还躺着三份文档（`引擎审计报告.md`、
    `后续计划单.md`、`引擎作用单.md`），它们同样写着「13 组 133 项」这类会过期的数字 ——
    于是同一天里，全仓能读出 13/130、13/133、18/177 三套基线，谁都不知道该信哪套。

    H6 的目标只有一个：**当前基线只有一个出处**（`07-通用引擎/开发计划.md §9aq.1`）。
    其余文档要写历史数字可以，但必须**明说是历史**，否则读者会当成现状。

判定规则（简单到不会误报）
    扫根目录 `*.md` 的每一行；命中「过期基线模式」且**该行没有任何历史标记** ⇒ 报红。
      · 过期模式：`13 组`、`133 项`、`130 项`、`138 编号`、`92 条断言`
        （都是 P40 前后那一轮的基线值；当前是 19 组 / 178 项 / 162 编号 / 104 条）
      · 历史标记：`当时值`、`历史`、`快照`、`§9ap`、`已过期`、`那一轮`
    ★ 为什么不扫「所有数字」：根目录文档大量出现「15 项」「19 项」这类**任务清单计数**，
      它们不是基线，扫了只会制造假红 —— 假红会训练人忽略工具（本工程已写进纪律）。

用法
    "$PY" tools/audit_root_docs.py              # 检查，rc=0 通过 / 1 有未标记的过期数字
    "$PY" tools/audit_root_docs.py --selftest   # 规则自检（既不空转也不误报）
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                 # 工程根（DST-Analysis）

# ★ 只扫这三份「H1 之前的基线文档」。
#   为什么不扫全部根目录 .md：`代码审查与架构分析-2026-10-18.md`、`高优先级阶段实施计划-H1至H4.md`、
#   `阶段验收记录…`、`校验报告-P43…` 里出现「133 项」是**在描述缺陷本身**
#   （「计划写 133、实测 177」），那正是它们该写的内容。把它们也算红，
#   等于逼人删掉证据 —— 假红比不查更糟。
BASELINE_DOCS = ["引擎审计报告.md", "后续计划单.md", "引擎作用单.md"]

STALE = ["13 组", "133 项", "130 项", "138 编号", "92 条断言"]
HIST = ["当时值", "历史", "快照", "§9ap", "已过期", "那一轮"]
CURRENT = "07-通用引擎/开发计划.md §9aq.1（当前：19 组 / 178 项 / 162 编号）"


def scan_text(text):
    """返回 [(行号, 行内容, 命中的过期串)]。纯函数，便于自检。"""
    bad = []
    for i, line in enumerate(text.splitlines(), 1):
        hit = [p for p in STALE if p in line]
        if not hit:
            continue
        if any(h in line for h in HIST):
            continue
        bad.append((i, line.strip(), hit))
    return bad


def selftest():
    """规则自检：一条该红的、一条不该红的、一条历史标记的。"""
    cases = [
        ("跑一遍 run_all：13 组 133 项全过\n", 1),                     # 该红
        ("当前基线：19 组 178 项全过\n", 0),                            # 不该红（没有旧数字）
        ("（当时值）13 组 133 项全过\n", 0),                            # 有历史标记
        ("见 07-通用引擎/开发计划.md §9aq.1：178 项\n", 0),             # 指向当前基线
        ("任务清单共 19 项，其中 8 项已完成\n", 0),                     # 普通计数，别误伤
    ]
    ok = True
    for text, want in cases:
        got = len(scan_text(text))
        flag = "✔" if got == want else "✘"
        if got != want:
            ok = False
        print("  %s 期望 %d 处，实测 %d 处：%s" % (flag, want, got, text.strip()[:40]))
    print("  自检%s" % ("通过" if ok else "**失败**"))
    return 0 if ok else 1


def main():
    if "--selftest" in sys.argv:
        return selftest()

    files = [f for f in BASELINE_DOCS if os.path.isfile(os.path.join(ROOT, f))]
    total = 0
    print("扫描 %d 份基线文档（当前基线唯一出处：%s）" % (len(files), CURRENT))
    for f in files:
        p = os.path.join(ROOT, f)
        text = io.open(p, encoding="utf-8", errors="replace").read()
        bad = scan_text(text)
        if bad:
            total += len(bad)
            for ln, line, hit in bad:
                print("  ✘ %s:%d  %s  ← 命中 %s（未标历史）" % (f, ln, line[:70], "/".join(hit)))
    if total:
        print("✘ 共 %d 处未标记的过期基线数字 —— 要么改成引用 §9aq.1，要么标「（当时值）」" % total)
        return 1
    print("✔ 根目录文档没有未标记的过期基线数字")
    return 0


if __name__ == "__main__":
    sys.exit(main())
