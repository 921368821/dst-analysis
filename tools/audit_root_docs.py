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
    扫根目录 `*.md` 的每一行；命中「过期基线」且**该行没有任何历史标记** ⇒ 报红。
      · **动态那条（P50㊱ 加）**：一行里同时出现 `N 组 … M 项` —— 这是「基线声明」的形状 ——
        且 (N, M) 与**现算**的当前值不同 ⇒ 红。这样它对「第几代」无所谓：
        下一代过期值不需要谁来加进白名单（硬编码只认识一代，实测漏了 19/178 与 18/177）。
      · 静态那条（保留作补充）：`13 组`、`133 项`、`130 项`、`138 编号`、`92 条断言`
      · 历史标记：`当时值`、`历史`、`快照`、`已过期`、`那一轮`
        ★★ 这里**故意没有** `§9ap`：它不是历史标记，它是**过期基线那一节的章节号**。
        删它之前，三份根文档里那句「当前基线的唯一出处：§9ap.1（18 组 / 177 项）」
        因为含 `§9ap` 而被豁免 —— 守卫的白名单正好保护了它该抓的那句话。
      · 当前值一律**现算**（`_current_numbers()`），本文不留副本。
    ★ 为什么不扫「所有数字」：根目录文档大量出现「15 项」「19 项」这类**任务清单计数**，
      它们不是基线，扫了只会制造假红 —— 假红会训练人忽略工具（本工程已写进纪律）。

用法
    "$PY" tools/audit_root_docs.py              # 检查，rc=0 通过 / 1 有未标记的过期数字
    "$PY" tools/audit_root_docs.py --selftest   # 规则自检（既不空转也不误报）
"""
import io
import os
import re
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
HIST = ["当时值", "历史", "快照", "已过期", "那一轮"]
# 「基线声明」的形状：同一行里 `N 组` 与 `M 项`（中间隔不超过 40 字）。
# ★ 为什么不扫「任何数字」：根目录文档大量出现「15 项」「19 项」这类任务清单计数，
#   它们不是基线，扫了只会制造假红。而「N 组 … M 项」一起出现，基本只能是基线。
BASE_RE = re.compile(r"(\d+)\s*组[^\n]{0,40}?(\d+)\s*项")


def _current_numbers():
    """→ (组数, 项数, 编号数)；算不出来返回 None（**不猜**）。"""
    try:
        sys.path.insert(0, os.path.join(ROOT, "07-通用引擎", "tools"))
        import verify_plan as vp
        total = 0
        for f in vp.TEST_FILES:
            p = os.path.join(vp.ROOT, f)
            if os.path.isfile(p):
                total += vp.file_items(p)
        groups = vp.count_groups(vp.read(os.path.join(vp.ROOT, "tests/run_all.sh")))
        return groups, total, len(vp.collect_ids())
    except Exception:                                            # noqa: BLE001
        return None


def _current_baseline():
    """「当前基线」这句话里的三个数字 —— **现算，不抄**。

    ★★ 2026-10-20（P49）：这里原来是一行硬编码常量
      `… §9aq.1（当前：19 组 / 178 项 / 162 编号）`。加了一条判据（B26b）之后
      总数从 178 变 179、编号 162 变 163，而这一行**还在说 178** ——
      它只是「打印给人看的」，没有判据盯着，于是成了同一数字的**第二份副本**。
      （本工程 P45c 抓的正是这类：一个数字抄两处，改一处必漏另一处。）
      ⇒ 改成从 `verify_plan.py` 的**同一套测量函数**里现算：
        `TEST_FILES`/`file_items`（项数）、`count_groups`（组数）、`collect_ids`（编号数）。
      算不出来（比如 07 目录被移走）就只说路径、不编数字 —— 说不准比说错强。
    """
    cur = _current_numbers()
    if cur is None:
        return "07-通用引擎/开发计划.md §9aq.1（数字现算失败，不显示值）"
    return "07-通用引擎/开发计划.md §9aq.1（当前：%d 组 / %d 项 / %d 编号）" % cur


def scan_text(text, cur=None):
    """返回 [(行号, 行内容, 命中的过期串)]。纯函数，便于自检。

    `cur` = (组数, 项数) 的当前值；不传就现算（自检时显式传入，避免依赖工程状态）。
    """
    if cur is None:
        n = _current_numbers()
        cur = (n[0], n[1]) if n else None
    bad = []
    for i, line in enumerate(text.splitlines(), 1):
        if any(h in line for h in HIST):
            continue
        hit = [p for p in STALE if p in line]
        m = BASE_RE.search(line)
        if m and cur and (int(m.group(1)), int(m.group(2))) != cur:
            hit.append("基线声明 %s 组 / %s 项 ≠ 当前 %d 组 / %d 项"
                       % (m.group(1), m.group(2), cur[0], cur[1]))
        if hit:
            bad.append((i, line.strip(), hit))
    return bad


def selftest():
    """规则自检。★ 用例里的「当前值」一律**现算**，不写死 —— 写死就是第二份副本。

    以前这里第 2 条是 `19 组 178 项 ⇒ 不该红`：自检亲手把**上一代**当成了当前值，
    等于给「只认一代过期值」这个缺陷盖章（P50㊱ 抓到的）。
    """
    n = _current_numbers()
    if n is None:
        print("  ✘ 现算不出当前基线（07-通用引擎 被移走了？）⇒ 自检**没有执行**，不是通过")
        return 2
    cur = (n[0], n[1])
    cg, ci = cur
    cases = [
        ("跑一遍 run_all：13 组 133 项全过\n", 1),                     # 静态那条
        ("当前基线：%d 组 %d 项全过\n" % (cg, ci), 0),                  # 现算值 ⇒ 不该红
        ("（当时值）13 组 133 项全过\n", 0),                            # 有历史标记
        ("任务清单共 19 项，其中 8 项已完成\n", 0),                     # 普通计数，别误伤
        # ↓ 这两条是 P50㊱ 新增：旧实现会判 0（静默通过）
        ("当前基线的唯一出处：§9ap.1（18 组 / 177 项 / 161 编号）\n", 1),
        ("某处写：%d 组 %d 项全过\n" % (cg + 1, ci), 1),                # 组数被改过 ⇒ 该红
        ("某处写：%d 组 %d 项全过\n" % (cg, ci - 1), 1),                # 项数被改过 ⇒ 该红
    ]
    ok = True
    for text, want in cases:
        got = len(scan_text(text, cur))
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
    print("扫描 %d 份基线文档（当前基线唯一出处：%s）" % (len(files), _current_baseline()))
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
