#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""lint_names.py —— 静态检查：**只对「未定义名」判红**。

★★ 为什么单立这一条（2026-10-16）：
  压 §9v.5 的时候压出一个**真 bug** —— `rt/server.py` 里 `targets` 的出错分支打印 `cid`，
  而 `cid` 只是**另一个方法的局部变量** ⇒ 那里抛 `NameError` ⇒
  **错误处理路径自己崩了**，真正的错（`TimeoutError: timed out`）被 NameError 盖住，
  日志里只剩一句莫名其妙的 NameError。
  ★ 这与「失败要吵」是同一条纪律的**反面**：想吵，但吵的机制本身坏了 ——
    比不吵更糟，因为它会把人引到错的地方。
  这类 bug **跑得再全也测不出来**（它在「出错」的时候才走），只能静态发现。

判据（故意只判一种）：
  · **红**：未定义名（`Undefined*`）/ 语法错误 —— 这些**一定会崩**；
  · **只提示**：未使用的导入/变量等其它告警 —— 它们不会崩，
    而把它们也判红等于让这条守卫淹没在噪音里（这套工程最怕的就是「红了没人当回事」）。

用法：python tools/lint_names.py        退出码 0 = 没有未定义名
      ⚠️ 没装 `pyflakes` 时**直接判失败**：未跑的检查等于没有（不许静默跳过）。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REL = [
    "rt/server.py", "rt/ws.py", "rt/protocol_bin.py",
    "tests/test_rt.py", "tests/test_stress.py", "tests/test_protocol_parity.py",
    "tests/test_deploy.py",
    "tools/verify_plan.py", "tools/pack_atlas.py", "tools/lint_names.py",
]

try:
    from pyflakes import api as pf_api
except ImportError:
    print("  ✘ 没装 pyflakes ⇒ 这一项**没有跑**。")
    print("    未跑的检查等于没有（本工程的老规矩），所以这里判失败而不是跳过。")
    print("    装：%s -m pip install pyflakes" % sys.executable)
    raise SystemExit(1)


class Collect:
    """收集告警（避免 pyflakes 自己往 stderr 打印、不好分类）"""

    def __init__(self):
        self.items = []

    def unexpectedError(self, filename, msg):                    # noqa: N802
        self.items.append(("error", filename, 0, "内部错误: %s" % msg))

    def syntaxError(self, filename, msg, lineno, offset, text):  # noqa: N802
        self.items.append(("error", filename, lineno or 0, "语法错误: %s" % msg))

    def flake(self, m):
        cls = type(m).__name__
        kind = "error" if cls.startswith("Undefined") else "info"
        self.items.append((kind, m.filename or "?", m.lineno or 0, "%s: %s" % (cls, m.message % m.message_args)))


def main():
    print("  静态检查（pyflakes）：**只管「未定义名」这类一定会崩的**")
    print("  " + "─" * 68)
    rep = Collect()
    checked = 0
    for rel in REL:
        p = os.path.join(ROOT, rel)
        if not os.path.isfile(p):
            rep.items.append(("error", rel, 0, "文件不存在（清单过期了？）"))
            continue
        pf_api.checkPath(p, rep)
        checked += 1
    errs = [it for it in rep.items if it[0] == "error"]
    infos = [it for it in rep.items if it[0] == "info"]
    print("  扫了 %d 个文件" % checked)
    for _, f, ln, msg in infos:
        print("    · [提示·不判红] %s:%s %s" % (os.path.relpath(f, ROOT), ln, msg))
    for _, f, ln, msg in errs:
        print("    ✘ %s:%s %s" % (os.path.relpath(f, ROOT), ln, msg))
    print("  " + "─" * 68)
    if errs:
        print("  ✘ 有 %d 处**未定义名/语法错误**（这类一定会在运行时崩，而且往往是在出错处理里）" % len(errs))
        return 1
    print("  ✔ 没有未定义名（另有 %d 条无害提示，按设计不判红）" % len(infos))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
