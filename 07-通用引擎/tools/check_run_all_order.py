#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`tests/run_all.sh` 里**「截断日志」必须在「拿到锁」之后** —— 一条顺序判据。

═══ 为什么需要它（2026-10-21，B11） ═══

`run_all.sh` 原本在文件开头就 `: > "$LOG"`，而拿锁的 `mkdir "$LOCKD"` 在它下游几百行。
于是**任何一次启动都会先清空日志 —— 包括被锁正确拒绝（rc=3）的那种**。

实测事故：15:48:19，另一轮正在跑（PID 50445），我起一轮想看新列，锁拒得对，
但那一轮**已经写完的 15 行组日志**没了；它随后在「轮末对账」如实判红
（日志 15 行 vs 组数 21）—— 一条**正确的**红，起因却是一条本该只读的路径。

修法是把截断挪到 `mkdir` 成功之后。这条工具守的就是**这个顺序**。

═══ 为什么用「源码顺序」而不是「跑一遍看日志有没有被清」 ═══

跑一遍的版本要**自己伪造一把锁**、把一个哨兵写进**真的** `tests/_run_all.log`：
  · 它跑在 `run_all` 内部时，那把真锁是**在跑的**，哨兵会覆盖正在写的日志；
  · 那是「判据为了自证而毁现场」—— 与本判据要防的事故同一类。
顺序是**静态事实**，读源码就能判，且零副作用。
（动态验证不是不做：修完当次用伪锁 + 哨兵手验过，记在 开发计划 §9bw。静态判据负责**不再退回去**。）

═══ 判据 ═══

| 级别 | 条件 | 为什么是错的 |
|---|---|---|
| ✘ | 源码里找不到 `: > "$LOG"` | 判据无法判定 ≠ 通过（也可能被人改成了别的写法） |
| ✘ | 找不到 `mkdir "$LOCKD"` | 拿锁那行被删/改名 ⇒ 锁可能已经失效 |
| ✘ | 截断出现在**第一处** `mkdir "$LOCKD"` **之前** | B11 事故原形：被拒绝的启动会改别人的现场 |
| ✘ | 截断出现**多次** | 多一处截断就多一条「什么时候清空」的隐藏路径 |

⚠ 本判据**不**判断「截断该不该存在」，只判断它的**位置**。

用法：
    python tools/check_run_all_order.py             # 查真文件，有 ✘ 退出码 1
    python tools/check_run_all_order.py --selftest  # 合成用例，证明它会响
"""
import argparse
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(ROOT, "tests", "run_all.sh")
TRUNC = ': > "$LOG"'
LOCK = 'mkdir "$LOCKD"'


def scan(text):
    """→ (bad, warn)。纯函数，便于自检。"""
    bad, warn = [], []
    lines = text.split("\n")
    trunc = [i + 1 for i, l in enumerate(lines) if l.strip().startswith(TRUNC)]
    lock = [i + 1 for i, l in enumerate(lines) if LOCK in l]
    if not trunc:
        bad.append('源码里找不到 `%s` —— 无法判定，不当作通过' % TRUNC)
    if not lock:
        bad.append('源码里找不到 `%s` —— 拿锁那行被删或改名，锁可能已经失效' % LOCK)
    if not trunc or not lock:
        return bad, warn
    if len(trunc) > 1:
        bad.append("截断日志出现了 %d 次（第 %s 行）—— 多一处就多一条"
                   "「什么时候清空」的隐藏路径" % (len(trunc), "、".join(map(str, trunc))))
    if min(trunc) < min(lock):
        bad.append("第 %d 行 `%s` 出现在第 %d 行 `%s` **之前** —— "
                   "被锁拒绝的启动（rc=3）会先清空别人正在写的日志（B11 事故原形）"
                   % (min(trunc), TRUNC, min(lock), LOCK))
    return bad, warn


# ── 合成用例 ──────────────────────────────────────────────────────────────
_GOOD = """#!/usr/bin/env bash
LOG="$ROOT/tests/_run_all.log"
LOCKD="$ROOT/tests/_run_all.lock.d"
if ! mkdir "$LOCKD" 2>/dev/null; then
    printf '✘ 已有一轮在跑\\n'; exit 3
fi
# ★ 拿到锁之后才截断
: > "$LOG" 2>/dev/null || true
"""

_BAD_ORDER = """#!/usr/bin/env bash
LOG="$ROOT/tests/_run_all.log"
LOCKD="$ROOT/tests/_run_all.lock.d"
: > "$LOG" 2>/dev/null || true
if ! mkdir "$LOCKD" 2>/dev/null; then
    printf '✘ 已有一轮在跑\\n'; exit 3
fi
"""

_TWO_TRUNC = _GOOD + ': > "$LOG" 2>/dev/null || true\n'

_NO_TRUNC = """#!/usr/bin/env bash
LOG="$ROOT/tests/_run_all.log"
LOCKD="$ROOT/tests/_run_all.lock.d"
if ! mkdir "$LOCKD" 2>/dev/null; then exit 3; fi
"""

_NO_LOCK = """#!/usr/bin/env bash
LOG="$ROOT/tests/_run_all.log"
: > "$LOG" 2>/dev/null || true
"""

WANT_CASES = 5                   # 自检用例条数：加/删必须同步改这里（开发计划 §9cd / §9cg）

SELFTEST = [
    # (说明, 源码, 期望 ✘ 条数)
    ("正确顺序（先拿锁、后截断）⇒ 不报", _GOOD, 0),
    ("截断在拿锁之前 ⇒ 必须报（B11 原形）", _BAD_ORDER, 1),
    ("截断出现两次 ⇒ 必须报", _TWO_TRUNC, 1),
    ("找不到截断 ⇒ 必须报（无法判定 ≠ 通过）", _NO_TRUNC, 1),
    # ★ 这里期望 **1** 条而不是 2：拿锁行都没有时，「顺序」无从判定，
    #   scan() 会提前返回（只报「拿锁那行不见了」）。期望写成 2 是我第一版的错 ——
    #   自检报红时先问「是判据错了，还是我的期望错了」。
    ("找不到拿锁 ⇒ 必须报（顺序无从判定，只报一条）", _NO_LOCK, 1),
]


def selftest():
    bad = 0
    for name, text, want in SELFTEST:
        got, _ = scan(text)
        ok = len(got) == want
        if not ok:
            bad += 1
        print("    %s %-32s 期望 ✘%d，实际 ✘%d" % ("✔" if ok else "✘", name, want, len(got)))
        if not ok:
            for m in got:
                print("         · ✘ %s" % m)
    if len(SELFTEST) != WANT_CASES:
        bad += 1
        print("  ✘ 自检用例 %d 条，期望 %d 条 —— 加/删用例时必须同步 WANT_CASES，"
              "否则这条自检会静默变松" % (len(SELFTEST), WANT_CASES))
    print("  %s %d 条合成用例（用例 %d 条）"
          % ("✔" if bad == 0 else "✘", len(SELFTEST), len(SELFTEST)))
    return 0 if bad == 0 else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=TARGET)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not os.path.isfile(a.file):
        print("  （没有 %s —— 本检查**没有执行**，不是通过）" % a.file)
        return 2
    text = io.open(a.file, encoding="utf-8", errors="replace").read()
    bad, warn = scan(text)
    lines = text.split("\n")
    trunc = [i + 1 for i, l in enumerate(lines) if l.strip().startswith(TRUNC)]
    lock = [i + 1 for i, l in enumerate(lines) if LOCK in l]
    print("  顺序判据：`%s` 在 `%s` 之后" % (TRUNC, LOCK))
    print("    拿锁行 %s ｜ 截断行 %s" % (lock or "（无）", trunc or "（无）"))
    for m in bad:
        print("  ✘ %s" % m)
    for m in warn:
        print("  ⚠ %s" % m)
    if bad:
        return 1
    print("  ✔ 截断只在拿到锁之后（被拒绝的启动不会改别人的日志）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
