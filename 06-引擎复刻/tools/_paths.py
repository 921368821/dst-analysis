# -*- coding: utf-8 -*-
"""
_paths.py —— 06 侧工具的**路径单一来源**

为什么（2026-10-17）：工作区搬迁后，`SRC = "C:/Users/35916/.../scripts/scripts"`
这种字面量在多处失效。且新的源码目录是 `02-注释源码`（UTF-8 中文名），
而 **Lua 在 Windows 上打不开中文路径**（ANSI 代码页）⇒ 统一优先走 ASCII 联接
`<工程根>/dstsrc`。

本文件只被 06 的工具脚本使用（它们直接 `import _paths`，因为同目录）。
"""

import os

TOOLS_ROOT = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.dirname(TOOLS_ROOT)                     # 06-引擎复刻
PROJECT_ROOT = os.path.dirname(ENGINE)                   # 工程根
RUN = os.path.join(PROJECT_ROOT, "03-参考架构", "_run_lua.py")

_CANDIDATES = (
    os.path.join(PROJECT_ROOT, "dstsrc", "scripts"),
    os.path.join(PROJECT_ROOT, "02-注释源码", "scripts"),
    os.path.join(PROJECT_ROOT, "scripts", "scripts"),
)


def src_dir():
    """DST 源码 scripts 根；**找不到就抛**（不返回一个猜测值）。"""
    env = os.environ.get("DST_SRC")
    cands = (env,) + _CANDIDATES if env else _CANDIDATES
    for c in cands:
        if c and os.path.isfile(os.path.join(c, "components", "health.lua")):
            return c
    raise RuntimeError(
        "找不到 DST 源码根（components/health.lua 不存在）。试过：\n  "
        + "\n  ".join(c for c in cands if c)
        + "\n处置：设环境变量 DST_SRC，或在工程根建 ASCII 联接 dstsrc -> 02-注释源码"
    )


SRC = src_dir()
