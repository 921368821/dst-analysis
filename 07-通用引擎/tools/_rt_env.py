# -*- coding: utf-8 -*-
"""
_rt_env.py —— 07 侧 Python 工具的**运行时与路径单一来源**

为什么有这个文件（2026-10-17）：
    工作区搬迁过一次（用户目录 `35916` → `admin`，工程从 `E:/DST-Analysis`
    挪到 `E:/xnb/DST-Analysis`），于是多处硬编码的解释器/引擎路径同时失效。
    本工程的母题之一是「同一件事两处实现 ⇒ 改一处、另一处悄悄过期」，
    所以这里做成一处置。

约定：
    * 解释器一律用 `sys.executable` —— 工具**是被某个 python 启动的**，
      「用哪一个 python 跑」这件事在启动时就已定下，工具自己再写死一个是重复来源。
    * node 走 `PATH`，找不到再扫 workbuddy 的版本目录（与 tools/env.sh 同序）。
"""

import os
import shutil
import sys

# 07-通用引擎
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 工程根（含 06-引擎复刻 / 03-参考架构 / 02-注释源码）
PROJECT_ROOT = os.path.dirname(ROOT)
ENGINE = os.path.join(PROJECT_ROOT, "06-引擎复刻")
RUNNER = os.path.join(PROJECT_ROOT, "03-参考架构", "_run_lua.py")

PY = sys.executable


def _find_node():
    env = os.environ.get("NODE")
    if env and os.path.exists(env):
        return env
    p = shutil.which("node")
    if p:
        return p
    base = os.path.join(os.path.expanduser("~"), ".workbuddy", "binaries", "node", "versions")
    cands = []
    if os.path.isdir(base):
        for d in sorted(os.listdir(base)):
            for exe in ("node.exe", "node"):
                f = os.path.join(base, d, exe)
                if os.path.exists(f):
                    cands.append(f)
    if cands:
        return cands[-1]
    raise RuntimeError(
        "找不到 node —— 客户端/协议测试需要它。"
        "装一个，或设环境变量 NODE 指向 node 可执行文件。"
    )


NODE = _find_node()


def dst_src():
    """DST 源码 scripts 根（ASCII 联接优先）。

    ★ Windows 上 Lua 5.1 的 io.open 走 ANSI 代码页，UTF-8 中文路径
      **无论存不存在都会报 No such file or directory** ⇒ 优先 `dstsrc` 联接。
    """
    for cand in (
        os.path.join(PROJECT_ROOT, "dstsrc", "scripts"),
        os.path.join(PROJECT_ROOT, "02-注释源码", "scripts"),
    ):
        if os.path.isfile(os.path.join(cand, "components", "health.lua")):
            return cand
    raise RuntimeError(
        "找不到 DST 源码根（components/health.lua 不存在）。"
        "试过 dstsrc/scripts 与 02-注释源码/scripts。"
    )
