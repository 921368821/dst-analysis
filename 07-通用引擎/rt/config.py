# -*- coding: utf-8 -*-
"""config.py —— 运行时的路径与同目录依赖的唯一落点（M4 拆分的产物）

为什么单独一个文件
    `server.py` 原本 2440 行，路径常量、Sim、Hub、模拟循环、HTTP、WebSocket
    全挤在一起；改动热点（限流、来源校验、快照编码）散在 2000 行里，
    集成测试一旦红，只能靠读整份文件定位。
    M4 按职责拆开之后，每个模块都要知道工程在哪、`ws`/`protocol_bin` 在哪 ——
    如果各写一份，就又回到「同一件事多份实现」的老毛病（本工程的母题）。
    所以路径只在这里算一次。

★ `sys.path.insert` 必须在这里做
    `rt/` 不是一个 Python 包（没有 `__init__.py`，入口是 `python rt/server.py`）。
    同目录的 `ws.py` / `protocol_bin.py` 靠脚本目录自动进 sys.path 才能 import；
    被 `tests/` 用 `sys.path.insert(0, RT)` 拉起来时也一样。
    这里显式插一次，是为了让「谁先 import 谁就能拿到」不依赖调用姿势。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                                  # 07-通用引擎
ENGINE = os.path.join(os.path.dirname(ROOT), "06-引擎复刻")     # 宿主在这里

# 真实图集：元数据在 _out/json/，贴图在 anim_data/（两个不同目录，第一版搞错过一次）
ATLAS_JSON_DIR = os.path.join(ENGINE, "_out", "json")
ATLAS_PNG_DIR = os.path.join(ENGINE, "anim_data")

# ★★ P5/P6：自产素材（tools/pack_atlas.py 的产物）优先于原版资产。
#   为什么需要「优先级」而不是替换：发布版不能带原版图集（版权），
#   但引擎/客户端不该为此改一行 —— 只要把自产素材放在同名 build 下
#   （例如把自画的身子打包成 wilson），客户端照样按 /atlas/json/wilson.json 取，
#   拿到的却是我们的图。这就是「换美术」在生产里的标准做法。
#   ⇒ 用 --atlas-dir 指定；给多份时按顺序先命中先用。
SELF_ATLAS_DIR = os.path.join(ROOT, "_demo_atlas")

if HERE not in sys.path:
    sys.path.insert(0, HERE)

import ws                  # noqa: E402  同目录的最小 WebSocket 实现（转发导出）
import protocol_bin as PB  # noqa: E402  P5：二进制帧编码（转发导出）

# ★ 显式声明转发导出：`ws` / `PB` 在本文件里不直接用，
#   但下游模块统一从这里取 —— 这样「路径与同目录依赖只有一处」才成立。
__all__ = ["HERE", "ROOT", "ENGINE", "ATLAS_JSON_DIR", "ATLAS_PNG_DIR",
           "SELF_ATLAS_DIR", "require_sources", "ws", "PB"]


def require_sources():
    """★ 环境自检（H3，2026-10-18）：启动前确认 DST 源码**真的可读**。

    为什么放在这里而不是只放在 shell 入口
        ① `python rt/server.py` 是一条**独立于 tests/run_all.sh 的入口**；
           `deploy/start.sh` 会 source env.sh，但直连 python 不会。
        ② `Sim.boot()` 也会自己调（测试 import 本模块时同样要拦住）——
           否则报错会变成 `00_paths.lua` 的 Lua 栈，症状看起来像「代码坏了」。

    为什么退出码是 3 而不是 1
        1 在这套工程里表示「判据红了」（测试/核对失败）。**环境缺失不是判据红**，
        混用会让人去翻代码。3 = 「这台机器还没准备好」。

    `DST_SRC` 环境变量仍然可以覆盖（发布/容器里直接指到游戏目录）。
    """
    root = os.path.dirname(ROOT)                     # DST-Analysis
    env = os.environ.get("DST_SRC", "").strip()
    probe = (os.path.join(env, "components", "health.lua") if env
             else os.path.join(root, "dstsrc", "scripts", "components", "health.lua"))
    if os.access(probe, os.R_OK):
        return probe
    msg = [
        "✘ 环境自检失败：找不到可读的 DST 源码（校验文件 components/health.lua）",
        "  探测位置：%s" % probe,
        "  修法：bash \"%s/preflight.sh\" --fix" % os.path.join(root, "tools"),
        "  ★ 不再启动服务端（这不是代码错误，是环境缺失）",
    ]
    print("\n".join(msg), file=sys.stderr)
    raise SystemExit(3)
