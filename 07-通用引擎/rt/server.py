# -*- coding: utf-8 -*-
"""server.py —— 实时引擎服务端（P1：骨架通）

职责（对应开发计划 §2 的 M1/M2/M3）
    M1 权威模拟：**唯一**一个 lupa LuaRuntime，固定步长推进（默认 30 Hz）
    M2 输入：客户端 WS 消息 → 输入队列 → 每次 step 前一次性应用
    M3 传输：每帧把快照编成 JSON，广播给所有客户端

为什么「唯一一个 LuaRuntime + 单线程持它」
    lupa 的 LuaRuntime **不是线程安全的**。所以：
      · 模拟线程独占运行时；
      · 客户端线程只做两件事 —— 往输入队列塞事件、读最新的已编码帧；
      · 帧只编码**一次**，所有客户端复用（省 CPU，也保证大家看到的是同一帧）。

为什么固定步长
    与 DST 一致（30 tps，`tests.lua` 实测 10 tick = 0.3333 s）。
    固定步长 + 有序输入 ⇒ 世界**可复现**，这是本工程的核心纪律。

用法
    python server.py                      # 默认 127.0.0.1:8765，30 Hz
    python server.py --port 9000 --hz 60
    python server.py --seed 42 --quiet
"""
import argparse
import io
import json
import os
import queue
import signal
import socket
import socketserver
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                       # 07-通用引擎
ENGINE = os.path.join(os.path.dirname(ROOT), "06-引擎复刻")   # 06-引擎复刻（宿主在这里）
# 真实图集：元数据在 _out/json/，贴图在 anim_data/（**两个不同目录**，第一版搞错过一次）
ATLAS_JSON_DIR = os.path.join(ENGINE, "_out", "json")
ATLAS_PNG_DIR = os.path.join(ENGINE, "anim_data")

# ★★ P5/P6：自产素材（`tools/pack_atlas.py` 的产物）**优先于原版资产**。
#   为什么需要「优先级」而不是替换：发布版**不能带原版图集**（版权），
#   但引擎/客户端**不该为此改一行** —— 只要把自产素材放在**同名 build** 下
#   （例如把自画的身子打包成 `wilson`），客户端照样按 `/atlas/json/wilson.json` 取，
#   拿到的却是我们的图。这就是「换美术」在生产里的标准做法。
#   ⇒ 用 `--atlas-dir` 指定；给多份时**按顺序先命中先用**。
SELF_ATLAS_DIR = os.path.join(ROOT, "_demo_atlas")
sys.path.insert(0, HERE)

import ws  # noqa: E402  （同目录的最小 WebSocket 实现）
import protocol_bin as PB  # noqa: E402  （P5：二进制帧编码）


# =============================================================================
# M1 权威模拟
# =============================================================================
class Sim:
    """持有唯一 LuaRuntime；**只允许模拟线程调用**。"""

    def __init__(self, seed=20261015, tick_hz=30, max_ents=400, world_content=14):
        self.seed, self.tick_hz, self.max_ents = seed, tick_hz, max_ents
        # ★ 默认世界内容（见 rt_boot 的 `populate_world`）：0 = 空世界（测试用）
        self.world_content = int(world_content)
        self.dt = 1.0 / tick_hz
        self.lua = None
        self.api = None          # ★ 不叫 self.boot —— 那会**遮蔽 boot() 方法**
        self.boot_ms = 0.0
        self._terrain_cache = None   # 地形瓦片表（首次请求时算一次，之后复用）
        # ★ M7「回放」：每 tick 的指纹（录像的「画面」那半边）+ 停止记录标志
        self.hashes = []
        self.marks = []              # 每 30 tick 存一份**完整指纹串**（不一致时给人看）
        self.record_limit = 200000   # ≈1.8 小时 @30 Hz；超了就**停止并吵**，不静默丢
        self.record_truncated = False

    def boot(self):
        require_sources()      # ★ H3：环境缺失 ⇒ 一条判定，不是 14 份 Lua 栈
        from lupa import lua51
        t0 = time.perf_counter()

        # ★★★ 环境事实（已实测隔离）：**这个 lupa 构建下 Lua 的 io.open 打不开绝对路径** ——
        #   中英文路径、正反斜杠都试过，一律 FAIL；而**相对路径全部 OK**。
        #   （`_run_lua.py` 之所以一直能用，是因为它 cd 到入口目录、并且**由 Python 读文件**、
        #     只把代码字符串喂给 Lua，从不要求 Lua 自己开绝对路径。）
        #   ⇒ 对策：切到宿主目录，package.path 只用**相对**写法。
        #   同时仍然由 Python 读 rt_boot.lua（不让 Lua 去开文件）。
        os.chdir(ENGINE)
        os.environ["LUA_PATH_5_1"] = ""     # 不该生效，重置掉以防干扰
        L = lua51.LuaRuntime(unpack_returned_tuples=True)
        L.execute('package.path = "./?.lua;./?/init.lua;" .. package.path')
        # 让 rt_boot.lua 里的 os.getenv 拿到配置
        os.environ["RT_SEED"] = str(self.seed)
        os.environ["RT_TICK_HZ"] = str(self.tick_hz)
        os.environ["RT_MAX_ENTS"] = str(self.max_ents)
        # ★ 默认世界内容（见 rt_boot 的 `populate_world`）：以前默认世界**只有玩家**，
        #   用户打开链接周围什么都没有（砍不了、捡不了）。14 个植物全在 20 格内。
        #   测试要「空世界」时传 0。
        os.environ["RT_WORLD_CONTENT"] = str(self.world_content)

        def _load(name):
            """读一个 rt/ 下的 Lua 文件并执行，返回其结果（模块表）。
            ★ 为什么不 require：cwd 是宿主目录，`require("rt_input")` 会去
              06-引擎复刻/rt_input.lua 找（不存在）。由 Python 读文件最稳。"""
            with io.open(os.path.join(HERE, name), encoding="utf-8") as f:
                c = f.read()
            gname = "__rt_mod_" + name.replace(".", "_")
            L.globals()[gname] = c
            res = L.eval("(loadstring or load)")(L.globals()[gname], "@" + name)
            if isinstance(res, tuple):
                res = res[0]
            if res is None:
                raise RuntimeError("%s 编译失败" % name)
            return res()

        # 先加载 rt_input（rt_boot 要用它），再加载 rt_boot 本体
        L.globals()["__rt_mod_rt_input"] = _load("rt_input.lua")
        L.globals()["__rt_mod_rt_save"] = _load("rt_save.lua")
        self._rt_input_mod = L.globals()["__rt_mod_rt_input"]

        path = os.path.join(HERE, "rt_boot.lua")
        with io.open(path, encoding="utf-8") as f:
            code = f.read()
        L.globals()["__rt_code__"] = code
        loader = L.eval("(loadstring or load)")
        chunk = loader(L.globals()["__rt_code__"], "@rt_boot.lua")
        if isinstance(chunk, tuple):
            chunk = chunk[0]
        if chunk is None:
            raise RuntimeError("rt_boot.lua 编译失败")
        self.api = chunk()            # ★ 调用它 → 返回那个函数表（仍按名字 `boot` 语义，但字段名避开）
        self.lua = L
        # ★★ 地形表**在启动时**就算好并缓存 —— 这样 HTTP 处理线程**永远不需要碰 Lua**
        #   （Sim 只有一个 LuaRuntime，跨线程调用会和模拟线程抢状态）。
        #   失败也不该拖垮启动：拿不到就置 None，/terrain 会如实回 503。
        try:
            self.terrain()
        except Exception as e:                                   # noqa: BLE001
            self._terrain_cache = None
            print("[boot] ⚠ 地形表生成失败：%s: %s（/terrain 会回 503）" % (type(e).__name__, e))
        self.boot_ms = (time.perf_counter() - t0) * 1000.0
        return self

    # --- 以下都必须在模拟线程里调用 ---
    def step(self):
        self.api.step(self.dt)
        self._record_tick()

    # ---------- M7：录像（逐 tick 指纹）与回放 ----------
    def _record_tick(self):
        """记一帧指纹 —— 录像的「画面」那半边。

        ★★ 指纹**只在这里算一次**：录制与回放都走 `step()` ⇒ 永远是同一份实现。
           第一版的想法是「回放时自己算一遍再比」——那正是本工程反复踩的
           「**同一件事两处实现**」：两边只要有一点不同（顺序、时机、取哪个字段），
           就会出现「回放说不一致、其实世界是对的」这类最难查的假红。
        """
        if len(self.hashes) >= self.record_limit:
            if not self.record_truncated:
                self.record_truncated = True
                print("[rec] ⚠ 录像已达 %d tick 上限，**停止记录**（这个标志会进 stats，不静默）"
                      % self.record_limit)
            return
        fs, fh = self.api.fingerprint()
        self.hashes.append(int(fh))
        if len(self.hashes) % 30 == 1:
            self.marks.append([len(self.hashes), str(fs)])

    def act_targets(self, slot, radius=20):
        """附近可交互目标 → **纯 Python 结构**。

        ★★★ 必须在这里转干净：Lua 返回的是嵌套 `_LuaTable`，而 `json.dumps` **不认它**。
          第一版直接把 Lua 表塞进 `{"targets": ...}` 发出去 ⇒ 抛 TypeError ⇒
          处理线程写 500 并**关掉连接** ⇒ 客户端看到的是「连接在读到 90/101 字节时关闭」
          （症状与真因隔了三层）。**与当初 `stats()` 混进 Lua 表是同一个坑** ——
          所以这里走 `lua_to_py` 的思路：**跨语言边界一律显式转换**。
        """
        t = self.api.act_targets(int(slot), float(radius))
        out = []
        if t is not None:
            for i in range(1, len(t) + 1):
                try:
                    e = t[i]
                    out.append({"id": int(e["id"]), "p": str(e["p"]),
                                "x": round(float(e["x"]), 2),
                                "z": round(float(e["z"]), 2),
                                "a": str(e["a"])})
                except Exception:                                # noqa: BLE001
                    continue                    # 单条坏数据不该毁掉整张表
        return out

    def player_state(self, slot):
        """某个槽位玩家的自身状态（血/饿/理智/背包）→ **纯 Python 结构**。

        与 `act_targets` 同一个理由：跨语言边界**显式转换**（`lua_to_py`），
        否则 `json.dumps` 不认 `_LuaTable`，整条应答会 500 而客户端只看到断线。
        """
        d = self.api.player_state(int(slot))
        out = {}
        if d is not None:
            for k in ("ok", "slot", "guid", "alive", "health", "maxhealth",
                      "hunger", "maxhunger", "sanity", "maxsanity",
                      "used", "total", "slots", "why"):
                try:
                    v = d[k]
                except Exception:                                # noqa: BLE001
                    v = None
                out[k] = lua_to_py(v)
        items = []
        try:
            t = d["items"]
            for i in range(1, len(t) + 1):
                e = t[i]
                items.append({"p": str(e["p"]), "n": int(e["n"])})
        except Exception:                                        # noqa: BLE001
            items = []
        out["items"] = items
        return out

    # ------------------------------------------------------------------
    # 调试通道（P41）：/debug/spawn · /debug/give · /debug/stats
    # ------------------------------------------------------------------
    # ★ 三个都**必须在模拟线程里**被调用（由 hub.cmds 排队）——
    #   它们要碰 Lua（SpawnPrefab / inventory / 组件）。
    # ★ 返回值一律转成**纯 Python 结构**：Lua 表是 `_LuaTable`，
    #   `json.dumps` 不认它（这个坑 P39 已经踩过一次，评论区记着）。

    def debug_spawn(self, prefab, x=None, z=None):
        """生成一个预制体 → (ok, dict)。ok=True 时 dict 有 prefab/guid/x/z。"""
        try:
            ok, info = self.api.debug_spawn(prefab, x, z)
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        if not ok:
            return False, {"error": str(info)}
        return True, {"prefab": str(info["prefab"]),
                      "guid": int(info["guid"]),
                      "x": round(float(info["x"]), 2),
                      "z": round(float(info["z"]), 2)}

    def debug_act(self, slot, radius, impl, n):
        """交互目标列表（索引版/线性版）→ (ok, dict)。

        ok=True 时 dict：impl / n / ms / count / ids（逗号分隔 guid 串）/ builds / lookups / scanned。
        ★ `ids` 是**字符串**不是列表：Lua 侧已经确认过「嵌套表过 lupa 边界会变成
          `_LuaTable`，json.dumps 不认」，所以 Lua 那边就 `table.concat` 好了再交过来。
        """
        try:
            ok, info = self.api.debug_act(int(slot), float(radius), str(impl), int(n))
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        if not ok:
            return False, {"error": str(info)}
        out = {"impl": str(info["impl"]), "n": int(info["n"]),
               "ids": str(info["ids"]), "count": int(info["count"])}
        for k in ("ms", "builds", "lookups", "scanned"):
            try:
                out[k] = float(info[k])
            except Exception:                                    # noqa: BLE001
                out[k] = None
        out["ms"] = round(float(out["ms"]), 4) if out["ms"] is not None else None
        return True, out

    def debug_entity(self, guid):
        """按 guid 查实体 → (ok, dict)。用来证明 spawn 出来的东西**真的在世界里**。"""
        try:
            ok, info = self.api.debug_entity(int(guid))
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        if not ok:
            return False, {"error": str(info)}
        return True, {"guid": int(info["guid"]), "prefab": str(info["prefab"]),
                      "x": round(float(info["x"]), 2), "z": round(float(info["z"]), 2)}

    def debug_give(self, slot, prefab, n=1):
        """给某槽位发物品 → (ok, dict)。ok=True 时 dict 有 given/items_before/items_after。"""
        try:
            ok, info = self.api.debug_give(int(slot), prefab, int(n))
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        if not ok:
            return False, {"error": str(info)}
        out = {"given": int(info["given"])}
        for k in ("items_before", "items_after"):
            try:
                v = info[k]
                out[k] = None if v is None else int(v)
            except Exception:                                    # noqa: BLE001
                out[k] = None
        return True, out

    def input_log(self):
        """Lua 侧记的输入事件 → Python（`[[tick, 槽位, 键, 值], ...]` 紧凑形式）

        ★ P20 起带**槽位**：多人之后「谁按的」和「按了什么」一样重要。
          不带槽位的话，四个人连上来录下来的日志只有本地玩家那一份 ——
          而且**回放仍然会「一致」**（因为回放也只喂那一份）⇒ 一个看不出来的缺口。
        """
        lg = self.api.input_log()
        out = []
        if lg is not None:
            for i in range(1, len(lg) + 1):
                e = lg[i]
                out.append([int(e["tick"]), int(e["slot"] or 0), str(e["k"]), int(e["v"])])
        return out

    def dump_recording(self):
        """整份录像：种子 + 步长 + 输入事件 + 逐 tick 指纹。"""
        # v2：事件从 `[tick,键,值]` 变成 `[tick,槽位,键,值]`（P20 多人之后必须区分是谁按的）
        return {"v": 2, "seed": self.seed, "tick_hz": self.tick_hz,
                "players": int(self.api.player_count()),
                "ticks": len(self.hashes), "truncated": self.record_truncated,
                "events": self.input_log(), "hashes": self.hashes, "marks": self.marks}

    def _mark_near(self, tick):
        best = None
        for t, s in self.marks:
            if t <= tick:
                best = (t, s)
            else:
                break
        return "第 %d tick：%s" % best if best else None

    def replay(self, rec):
        """按录像重放。**调用方必须先给一个同种子的干净 Sim**（本方法不重置世界）。

        返回 `(首个不一致的 tick, 期望 hash, 实得 hash, 附近指纹串)`；全一致时 tick 为 None。
        """
        evs = {}
        need_slots = set()
        for ev in rec["events"]:
            # ★ 事件有两种长度：老录像 `[tick,键,值]`（只有本地玩家）与新录像
            #   `[tick,槽位,键,值]`。**两种都要能放**（不然老录像全部报「不一致」，
            #   而那是格式升级造成的假红）。
            if len(ev) == 4:
                t, slot, k, v = ev
            else:
                t, k, v = ev
                slot = 0
            evs.setdefault(int(t), []).append((int(slot), str(k), bool(v)))
            if int(slot) > 0:
                need_slots.add(int(slot))
        # ★★ 回放前必须把录像里用到的**槽位补出来**：否则 `set_input_for(1,…)` 会被
        #   拒（「槽位不存在」）⇒ 那个玩家全程不动 ⇒ 指纹从第一个事件起就不一致。
        #   槽位按**升序**补，保证 guids 的分配顺序与录制时一致（否则实体 id 不同，
        #   指纹必然不同 —— 那是**回放自身的问题**，不是世界变了）。
        for slot in sorted(need_slots):
            self.api.add_player(slot)
        want = rec["hashes"]
        self.api.clear_input_log()      # 重放产生的输入不再进日志（否则会越滚越长）
        for i in range(len(want)):
            for slot, k, v in evs.get(i, ()):
                if k == "*":
                    self.clear_input()      # ★ 与录制端同一个语义（见 rt_boot 的注释）
                else:
                    self.api.set_input_for(slot, k, v)
            self.step()
            got = self.hashes[-1] if self.hashes else None
            if got != int(want[i]):
                return i + 1, int(want[i]), got, self._mark_near(i + 1)
        return None, None, None, None

    def set_input(self, key, down):
        self.api.set_input(key, bool(down))

    def clear_input(self):
        """清空所有按键状态（测试与「重开一局」都要用）"""
        self.api.clear_input()

    def snapshot(self):
        """Lua table → Python dict（只取我们要送出去的字段，避免整表搬运）"""
        s = self.api.snapshot()
        ents = []
        for e in s["ents"].values():
            rec = {"id": e["id"], "x": round(float(e["x"]), 3), "z": round(float(e["z"]), 3)}
            for k, t in (("p", str), ("a", str), ("bld", str)):
                v = e[k]
                if v is not None:
                    rec[k] = t(v)
            fr = e["fr"]
            if fr is not None:
                rec["fr"] = int(fr)
            f = e["f"]
            if f is not None:
                rec["f"] = round(float(f), 2)
            ents.append(rec)
        # ★ `paused` 由**模拟循环**按 Hub 的状态填（Sim 自己不知道暂不暂停）——
        #   这里给个默认值，好让「帧里一定有这个字段」这件事在任何调用路径上都成立。
        out = {"t": round(float(s["t"]), 4), "tick": int(s["tick"]),
               "n": int(s["n"]), "ents": ents, "iseq": int(s["input_seq"]),
               "paused": False}
        pl = s["player"]
        if pl is not None:
            out["player"] = {"id": pl["id"], "x": round(float(pl["x"]), 3),
                             "z": round(float(pl["z"]), 3)}
        # ★ 世界环境（昼夜/季节/温度）：客户端据此做明暗与色调。
        #   可能为 None（TheWorld 尚未就绪）——那就**不发**这一段，客户端自己兜底。
        w = s["world"]
        if w is not None:
            out["world"] = {
                "phase":  str(w["phase"] or ""),
                "season": str(w["season"] or ""),
                "isday":  bool(w["isday"]),
                "isdusk": bool(w["isdusk"]),
                "isnight": bool(w["isnight"]),
                "temperature": round(float(w["temperature"] or 0.0), 2),
            }
        return out

    def terrain(self):
        """整张地形瓦片表（P10）。**只在启动后算一次**并缓存 —— 地形不变。

        ★ 为什么缓存而不是每次请求重算：Lua 侧要从 16384 个瓦片建一个表再跨边
          搬过来，纯属浪费；而且这个接口的正确用法就是「开局拉一次」。
        ★ 为什么缓存放在 Sim 里（而不是 handler）：Sim 是唯一允许碰 Lua 的对象，
          缓存也必须在它这一层，否则又会出现「处理线程去调 Lua」的跨线程问题。
        """
        if self._terrain_cache is None:
            t = self.api.terrain()
            self._terrain_cache = {
                "w": int(t["w"]), "h": int(t["h"]), "tile": int(t["tile"]),
                "tiles": [int(t["tiles"][i + 1] or 0) for i in range(int(t["w"]) * int(t["h"]))],
                "names": {str(k): str(v) for k, v in dict(t["names"]).items()},
            }
        return self._terrain_cache

    def stats(self):
        d = self.api.stats()
        out = {}
        for k, v in d.items():
            # ★ 只把 **整数**转 int；float 必须原样保留 ——
            #   第一版写成 `int(v) if isinstance(v,(int,float))`，
            #   于是 2.9999 被截成 2，读出来的「世界时间」少了一整秒，
            #   看起来像存档/读档丢了时间（其实引擎是对的，是包装错了）。
            # ★★★ 2026-10-16：同一个表达式里还藏着**第二个错**（由 `E4` 抓出来）：
            #   `isinstance(True, int)` 在 Python 里是 **True** ⇒ 所有 Lua 布尔
            #   会被 `int(v)` 变成 **1/0** ⇒ `/healthz` 里 `player_alive: 1` 而不是 `true`。
            #   ⇒ 消元顺序必须是 **bool 先判**、再判 int。
            #   （这一类「同一个判断里连着两个坑」正是本工程的老母题：
            #     上一处修好之后，同一行里剩下的那个坑**看起来已经修过了**。）
            if isinstance(v, bool):
                out[k] = v
            elif isinstance(v, float):
                out[k] = v
            elif isinstance(v, int):
                out[k] = int(v)
            else:
                # ★★ 非标量必须**转成 Python 类型**：`stats()` 的返回值会被 json.dumps 送出去
                #   （/healthz、/status），而 json.dumps 不认 lupa 的 _LuaTable ⇒
                #   整个 HTTP 请求 500。第一版把 Lua 表原样透传，就踩了这个：
                #   加了 `world_missing`（一个 Lua 数组）之后 /healthz 直接 500，
                #   而**报错信息只是个占位的 "500 x"**，看不出来是谁干的。
                #   ⇒ 一律走 lua_to_py（它本来就是为了这个场景写的）。
                out[k] = lua_to_py(v)
        # ★★ 把**模型版本**顶上来（2026-10-16 加）。
        #   此前 `rt_boot.lua` 里有 `M.version() return "rt_boot/4"`，但**没有任何调用者**
        #   （`grep version()` 只有定义那一行）⇒ 「发布记录表里写的那一版」与
        #   「服务端正在跑的那一版」之间只能靠人记。这正是本工程反复出现的形态：
        #   **声明在、消费不在**（词在≠行为在）。
        #   ⇒ 现在 /healthz 与 /status 都会报出来，发布检查单那一列**可以核**了。
        #   ⚠️ 用 try 包住：取版本失败**不许**把整个 /healthz 打成 500 ——
        #     这条教训本文件里记过一次（加了 world_missing 之后 /healthz 直接 500，
        #     而报错信息只是个占位的 "500 x"）。
        try:
            out["boot"] = str(self.api.version())
        except Exception as e:                      # noqa: BLE001
            out["boot"] = "?（取版本失败：%s）" % type(e).__name__
        # ★ 录像状态也进 stats：→ 会出现在 /healthz 与 /status 上。
        #   「录不上了」必须是**看得见**的（与「失败要吵」同一条纪律）。
        out["rec_ticks"] = len(self.hashes)
        if self.record_truncated:
            out["rec_truncated"] = True
        return out

    # ---------- 自动存档 / 启动读档（P3 遗留项的收口）----------
    def autosave(self, path, slot_keys=None):
        """写一份 JSON 存档。★ 先写临时文件再 `os.replace` ——
        直接覆写的话，进程在写一半时被杀就会留下**半截档案**，
        而半截档案会让下次启动读档失败（正是我们在 P3 用反向测试防的那种）。"""
        # ★ 父目录不存在就建：`Sim.boot()` 会 `os.chdir(ENGINE)`，
        #   于是**相对路径**会按宿主目录解析 —— 实测踩到：
        #   `--save-file ../deploy/logs/x.json` 变成「宿主目录的上一级」，
        #   既不是调用者想的那个目录，目录还不存在 ⇒ 第一次自动存档直接失败。
        #   （好消息：错误信息是明确的 `No such file or directory: ... .tmp`，
        #     不是静默——这正是「失败要吵」的设计该有的表现。）
        parent = os.path.dirname(os.path.abspath(path))
        if parent:
            os.makedirs(parent, exist_ok=True)
        if slot_keys is not None:
            # ★★ P36：把「哪个槽位用哪个会话 key」交给**引擎**再落盘 ——
            #   这张表以前只活在服务端内存里，所以重启之后谁都认不回自己的角色。
            #   用 `_py_to_lua` 转（**不能直接传 dict**：lupa 给过去是 userdata，
            #   Lua 那边 `pairs()` 会报 "table expected, got userdata"）。
            self.api.set_slot_keys(self._py_to_lua(dict(slot_keys)))
        data = self.save_collect()
        tmp = path + ".tmp"
        with io.open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, path)          # 原子替换
        return len(data.get("ents", [])), os.path.getsize(path)

    def save_recording(self, path):
        """把录像写成 JSON（同样**先写 .tmp 再 replace**：半截录像 = 一份没用的录像，
        比没有更糟 —— 它会让人以为「回放不一致」，其实是文件没写完）。"""
        parent = os.path.dirname(os.path.abspath(path))
        if parent:
            os.makedirs(parent, exist_ok=True)
        d = self.dump_recording()
        tmp = path + ".tmp"
        with io.open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, path)
        return d["ticks"], len(d["events"]), os.path.getsize(path)

    def try_load(self, path):
        """启动时读档。**读不了就明确报出来并继续用新世界**（不静默、也不拒绝启动）。"""
        if not os.path.isfile(path):
            return False, "没有存档文件（新世界）"
        try:
            with io.open(path, encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:                                   # noqa: BLE001
            return False, "存档读不动（%s: %s）—— 已改用新世界" % (type(e).__name__, e)
        ok, msg = self.save_apply(data)
        return ok, ("已读档：" + msg) if ok else ("存档被拒（%s）—— 已改用新世界" % msg)

    # ---------- 存档（P3 / M5）----------
    def save_collect(self):
        return lua_to_py(self.api.save_collect())

    def save_validate(self, data):
        """纯 Python 存档 -> 转回 Lua 表 -> 交给 Lua 侧 validate。
        ★ 为什么转回去：校验逻辑写在 Lua（rt_save.validate），
          而 Lua 侧没有 JSON 库 ⇒ 只能「Python 持数据、Lua 持规则」。
          第一版我在这儿写了一段自造的 Lua 片段，语法直接炸 —— 已废。"""
        res = self.api.save_validate(self._py_to_lua(data))
        # 防御：Lua 侧若只返回一个值（成功路径常这么写），lupa 给的是单个 bool
        ok, err = res if isinstance(res, tuple) else (res, "")
        return bool(ok), str(err or "")

    def save_apply(self, data):
        """把纯 Python 存档喂回 Lua（逐个字段塞进一张新 Lua 表）"""
        ok, err = self.api.save_apply(self._py_to_lua(data))
        return bool(ok), str(err or "")

    def _py_to_lua(self, obj, depth=0):
        """纯 Python → Lua 表（存档读档用）"""
        if depth > 12:
            return "<too-deep>"
        if isinstance(obj, dict):
            t = self.lua.table()
            if "__array__" in obj:
                for i, v in enumerate(obj["__array__"], 1):
                    t[i] = self._py_to_lua(v, depth + 1)
                for k, v in obj.items():
                    if k != "__array__":
                        t[k] = self._py_to_lua(v, depth + 1)
            else:
                for k, v in obj.items():
                    t[k] = self._py_to_lua(v, depth + 1)
            return t
        if isinstance(obj, (list, tuple)):
            t = self.lua.table()
            # ★ lupa 的 LuaTable **没有 append**（第一版用 append 直接
            #   'NoneType' object is not callable）⇒ 用下标赋值，Lua 语义一致。
            for i, v in enumerate(obj, 1):
                t[i] = self._py_to_lua(v, depth + 1)
            return t
        return obj

    def fingerprint(self):
        s, h = self.api.fingerprint()
        return str(s), int(h)


# =============================================================================
# 共享状态（模拟线程写，客户端线程读）
# =============================================================================
# =============================================================================
# Lua 表 -> 纯 Python（存档要过 JSON，嵌套的 _LuaTable 不能直接序列化）
# =============================================================================

def _slots_html(players):
    """把 `stats()["players"]`（按槽位的存活/血量）拼成一行给人看的摘要。

    ★ 为什么要有：`player_alive`/`player_health` 只描述**槽位 0**；
      多客户端时运维需要一眼看到**每个槽位**是死是活 ——
      否则「杀了客户端却报玩家还活着」这种误判会消耗排查时间（E8 就踩过）。
    """
    if not isinstance(players, dict) or not players:
        return "（无）"
    def one(k):
        v = players.get(k) or {}
        # ★ P38：把「在不在光里」也写出来 —— 夜里挨打的**直接原因**就是它，
        #   以前只能靠推断（`LIGHT_STATE` 是引擎内部的局部表）。
        lit = v.get("in_light")
        tag = ""
        if lit is True:
            tag = " ·<span style='color:#3fb950'>在光里</span>"
        elif lit is False:
            tag = " ·<span style='color:#d29922'>不在光里</span>"
        if v.get("alive") is True:
            hp = v.get("health")
            return "<b style='color:#3fb950'>槽%s 活着</b>(%s)%s" % (
                k, ("%.0f" % hp) if isinstance(hp, (int, float)) else "?", tag)
        if v.get("alive") is False:
            return "<b style='color:#f85149'>槽%s 已死亡</b>%s" % (k, tag)
        return "槽%s ?" % k
    return " · ".join(one(k) for k in sorted(players, key=lambda x: int(x)))


STATUS_HTML = """<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<title>实时引擎 · 状态</title><style>
body{background:#0d1117;color:#c9d1d9;font:14px/1.7 ui-monospace,Consolas,monospace;padding:24px}
h1{font-size:18px;color:#58a6ff}table{border-collapse:collapse;margin-top:8px}
td{padding:3px 14px 3px 0}td:first-child{color:#8b949e}
b{color:#3fb950}a{color:#58a6ff}</style></head><body>
<h1>实时引擎 · 运行状态</h1>
<table>
<tr><td>tick</td><td><b>{{TICK}}</b></td></tr>
<tr><td>世界时间</td><td><b>{{TIME}}</b> s</td></tr>
<tr><td>实体数</td><td><b>{{ENTS}}</b></td></tr>
<tr><td>在线客户端</td><td><b>{{CLIENTS}}</b></td></tr>
<tr><td>世界里的人数</td><td><b>{{PLAYERS}}</b>（每个客户端一个角色）</td></tr>
<tr><td>玩家实体</td><td><b>{{PLAYER}}</b></td></tr>
<tr><td>丢弃的坏帧</td><td><b>{{BADFRAMES}}</b></td></tr>
<tr><td>已发帧数</td><td><b>{{SENT}}</b></td></tr>
<tr><td>昼夜 · 季节</td><td><b>{{PHASE}}</b> · {{SEASON}}</td></tr>
<tr><td>温度</td><td><b>{{TEMP}}</b> ℃</td></tr>
<tr><td>世界组件</td><td>{{WORLDOK}}</td></tr>
<tr><td>运行状态</td><td>{{PAUSED}}</td></tr>
<tr><td>玩家存活</td><td>{{ALIVE}}（血量 {{HEALTH}}）</td></tr>
<tr><td>各玩家槽位</td><td>{{SLOTS}}</td></tr>
<tr><td>复活次数</td><td><b>{{RESPAWNS}}</b>（死后 3 s 自动换身体）</td></tr>
<tr><td>光源 · 点过的火</td><td><b>{{FIRES}}</b> / 共 {{FIRES_LIT}} 堆（黄昏自动补）</td></tr>
<tr><td>随身光源</td><td><b>{{PLAYER_LIGHT}}</b> 个槽位开着（P38：举火把走夜路那种；默认关）</td></tr>
<tr><td>模型版本</td><td><b>{{BOOT}}</b>（与发布记录对照用）</td></tr>
</table>
<p><a href="/pause?on=1">暂停</a> · <a href="/pause?on=0">继续</a> · <a href="/terrain">/terrain</a>（地形 JSON）</p>
<p><a href="/">进入游戏</a> · <a href="/healthz">/healthz</a>（JSON）</p>
<p style="color:#8b949e">本页每 2 s 自动刷新一次。</p>
<script>setTimeout(function(){location.reload()}, 2000);</script>
</body></html>"""

def lua_to_py(v, depth=0):
    """递归把 lupa 的 _LuaTable 转成 dict/list。
    ★ 为什么需要：json.dumps 不认 _LuaTable（**嵌套的也不行**）——
      第一次直接 dumps 存档表就是在这里炸的。"""
    if depth > 12:                      # 防御：别把环踩穿
        return "<too-deep>"
    if type(v).__name__ == "_LuaTable":
        try:
            n = len(v)
        except Exception:                                        # noqa: BLE001
            n = 0
        if n > 0:                        # 数组段 -> list
            out = [lua_to_py(v[i], depth + 1) for i in range(1, n + 1)]
            extra = {str(k): lua_to_py(val, depth + 1)
                     for k, val in v.items() if not isinstance(k, int)}
            return {"__array__": out, **extra} if extra else out
        return {str(k): lua_to_py(val, depth + 1) for k, val in v.items()}
    if isinstance(v, (str, int, float, bool)) or v is None:
        return v
    return str(v)


class Hub:
    def __init__(self):
        self.lock = threading.Lock()
        self.snap = None          # 最近一帧的**快照字典**（二进制客户端要按自己字典重编）
        self.frame = b""          # 最近一帧的 JSON 编码（文本客户端共用）
        self.frame_ver = 0        # 版本号：客户端据此判断「有新帧了」
        self.inputs = queue.Queue()   # 输入事件
        self.clients = 0
        self.client_ids = {}
        self.dropped_bad_frames = 0   # 坏帧计数（**不静默**：会出现在 stats 里）
        self.frames_sent = 0
        self.bytes_sent = 0
        # ★ 暂停（P3 目标里的「暂停」，2026-10-16 补）：世界时间停住，但**连接与发帧继续**。
        #   状态放在 Hub 里（带锁），因为请求线程写、模拟线程读。
        self.paused = False
        # ★★ P20：玩家槽位。**第一个连上来的客户端拿槽位 0**（= 开机时那个默认玩家），
        #   这样「只有一个客户端」时的行为与多人之前**完全一致**（预测/相机/存档都指着它）。
        self.slot_of = {}          # cid -> slot
        self.slot_guid = {}        # slot -> 实体 guid（模拟线程填，处理线程读）
        self.free_slots = []       # 断开后回收、下次优先复用（免得槽位号无限涨）
        self.next_slot = 1
        # ★★ 世界**变更**命令队列（加/删玩家）。为什么不能直接调：
        #   `Sim` 只有一个 LuaRuntime —— 从 WS 处理线程直接碰 Lua 会和模拟线程抢状态
        #   （这与 /terrain 当初的取舍是同一条：**只有模拟线程能碰 Lua**）。
        self.cmds = queue.Queue()
        self.player_count = 0      # 模拟线程填（给 /status 用）
        # ★★ 会话身份（P21）：客户端带一个稳定的 `key`（浏览器 localStorage 里存的随机串）。
        #   有 key 就能「刷新/掉线后**拿回同一个角色**」：
        #     · `by_key[key] = slot`：key → 槽位
        #     · `slot_key[slot] = key`：反向
        #     · `reserved[slot] = 到期时间`：断线后**保留**这个槽位一小段时间（宽限期），
        #       期间玩家**不删**、槽位**不回收** ⇒ 重连上来还是同一个 guid、同一个位置。
        #   为什么要有宽限期而不是「永不删」：不然每次刷新都留下一个站着的空角色（泄漏）。
        self.by_key = {}
        self.slot_key = {}
        self.reserved = {}         # slot -> 到期时间戳（time.time()）
        self.reconnect_grace = float(os.environ.get("RT_RECONNECT_GRACE", "60"))
        self.busy_kicks = 0        # 同一个 key 同时连第二个客户端时的拒绝计数
        # ★ P22：交互。目标列表由**模拟线程**算好放这里，处理线程只读 ——
        #   与谁处理 whoami 同一个理由：**只有模拟线程能碰 Lua**。
        self.targets_by_slot = {}  # slot -> [ {id,p,x,z,a}, ... ]（按距离升序）
        self.act_result = {}       # slot -> {"ok":bool, "msg":str}（最近一次动作结果）
        # ★ 2026-10-18 审计修：`/status` 与 `/healthz` 原先在处理线程里直接调
        #   `sim.stats()` → `api.stats()` → **进 Lua**。这与本文件开头那条纪律
        #   （「lupa 的 LuaRuntime 不是线程安全的：模拟线程独占运行时」）直接冲突 ——
        #   那两处甚至写着注释「不在处理线程里再调 Lua」，却正是这么做的。
        #   ⇒ 改成：模拟线程每 8 拍算一次放这里，处理线程**只读缓存**。
        #   代价是统计最多落后 0.27 s —— 对监控页与对账都无所谓，
        #   而「两个线程同时跑同一个 LuaRuntime」是随时可能炸的真问题。
        self.stats_cache = None        # dict | None（模拟线程填，处理线程读）
        # ★★★ C1（2026-10-18 P44）：**停帧看门狗**的状态
        #
        #   背景：§9v.5 报过「某种客户端节奏让模拟循环停住」，三次尝试（含 6 轮
        #   burst/paced 压测）都**没复现**。不复现不等于不存在 —— 它意味着
        #   **下一次发生时我们仍然没有证据**。所以这里补的不是「修好那个 bug」，
        #   而是「下一次发生时能说清它在哪一行停住」。
        #
        #   ★ 为什么必须是**独立线程**：单线程里的看门狗看不见自己卡死。
        #     只有另一个线程在看 `beat` 有没有推进，才可能发现「主循环不动了」。
        self.beat = 0.0                # 模拟线程每拍写一次 perf_counter()
        self.sim_ident = None          # 模拟线程 ident（停帧时抓它的 Python 栈）
        self.stalls = 0                # 累计停帧次数（≥ 阈值才算一次）
        self.last_stall = None         # dict: at / gap / threshold / trace
        # 阈值可用环境变量调（反向测试要把它调大/调小）
        self.stall_threshold = float(os.environ.get("RT_STALL_SEC", "3.0"))
        self._stall_marked = False
        # ★ P39：每个槽位的**自身状态**（血/饿/理智/背包），同样由模拟线程算好、处理线程只读。
        #   与 targets 分开缓存：频率一样（每 8 拍），但**消费者不同**
        #   （目标列表是「能干什么」，这个是「我怎么了」），混在一起会让两边互相拖累。
        self.me_by_slot = {}       # slot -> {health,maxhealth,hunger,...}

        # ★★★ 说明：「我是谁」曾经用**推送**（模拟线程塞进 outbox、处理线程取走后发）。
        #   实测在负载下不可靠：4 个客户端 + 646 实体时，处理线程会被 GIL 争用饿到，
        #   新连接的 `you` **有时十几秒都不发** —— 而客户端没有它就一直不知道自己是哪一条。
        #   ⇒ 改成**拉取**：客户端连上发 `{"cmd":"whoami"}`，处理线程**就地应答**。
        #   没有跨线程投递、没有等待、没有超时：**时序依赖被彻底去掉**。

    # ---------- 玩家槽位（P20/P21）----------
    def alloc_slot(self, cid, key=None):
        """给一个连接分配槽位。

        优先级：① 带 `key` 且这个 key **有保留中的槽位** ⇒ 复用它（= 拿回自己的角色）；
                ② 槽位 0 还没人用 ⇒ 给第一个连接；
                ③ 复用空闲槽位；④ 新开一个。
        返回 `slot`；若同一个 key **已经在别处连着**则返回 `-1`（busy，新连接不给角色）。
        """
        with self.lock:
            if key:
                slot = self.by_key.get(key)
                if slot is not None:
                    if slot in self.slot_of.values():
                        # 同一个 key 已经有一个**活着的**连接 ⇒ 拒绝第二个（免得两个人抢一个身体）
                        self.busy_kicks += 1
                        return -1
                    # 保留期内重连 ⇒ 拿回原槽位（并取消保留）
                    self.reserved.pop(slot, None)
                    self.slot_of[cid] = slot
                    self.slot_key[slot] = key
                    return slot
            # ★★ P37 修（这条是**跨进程判据第一次跑就抓到**的真 bug）：
            #   「有身份在身、但人现在没连回来」的槽位（`by_key` 里有、`slot_of` 里没有）
            #   **不许**分给新连接。症状：重启后 `prime_keys` 已把 K1→槽位 1 灌进 `by_key`，
            #   而 `next_slot` 还是初始的 1 ⇒ 第二个连接（key=K2 / 匿名）也被分到**槽位 1**
            #   ⇒ 两个客户端指向**同一个身体**（`whoami` 回同一个 guid）。
            #   进程内测不出来（`by_key` 在进程内本来就是热的那一份）；只有「重启 + 同 key 回来」
            #   这条路径才会让「已认领但未连接」的槽位真的存在。
            held = set(self.by_key.values()) - set(self.slot_of.values())
            if 0 not in self.slot_guid and 0 not in self.slot_of.values() and 0 not in held:
                slot = 0
            else:
                # 复用空闲槽位（跳过被身份认领的）
                slot = None
                while self.free_slots:
                    s = self.free_slots.pop(0)
                    if s not in held:
                        slot = s
                        break
                # 新开一个（同时跳过被认领的、在用的、以及默认玩家 0）
                if slot is None:
                    s = max(1, self.next_slot)
                    while s in held or s in self.slot_of.values() or s in self.slot_guid:
                        s += 1
                    slot = s
                    self.next_slot = s + 1
            # ★★★ 分配槽位时**清掉上一次的 guid** —— 这是第二个时序坑：
            #   槽位复用（上一个连接刚断开）时，`slot_guid[slot]` 里还留着**旧角色**的 guid，
            #   而那个角色正等着被 remove 处理掉。此时客户端一问 `whoami` 就拿到旧 guid
            #   ⇒ 它认了一个**马上就不存在的角色** ⇒ 症状是「帧里找不到自己」。
            #   ⇒ 清掉之后，whoami 会如实回 null，客户端重试到模拟线程把新角色建好为止。
            #   ⚠️ 槽位 0 不清：它是默认玩家，永远存在（也不参与回收）。
            if slot != 0:
                self.slot_guid.pop(slot, None)
                # ★★ P39 连带：槽位换主人时，把**按槽位缓存**的东西一并作废。
                #   它们（目标列表 / 自身状态 / 上次动作结果）都是「上一任」的观察结果，
                #   留着就会在新客户端问起时被当成「你的」。（`me` 那边还有一道 guid 对账，
                #   这里是**源头**就该断：缓存作废比事后比对更不容易漏。）
                #   ⚠️ 别在这里碰 Lua：那是模拟线程的事，本方法可能在任何线程里被调。
                self.me_by_slot.pop(slot, None)
                self.targets_by_slot.pop(slot, None)
                self.act_result.pop(slot, None)
            self.slot_of[cid] = slot
            if key:
                self.by_key[key] = slot
                self.slot_key[slot] = key
            return slot

    def prime_keys(self, mapping):
        """把**存档里带回来的**会话 key 灌进 `by_key`/`slot_key`（P36）。

        ★ 为什么必须在启动时做：客户端重连时只带一个 key，服务端要靠 `by_key`
          才知道「它上次用的是哪个槽位」。以前这张表每次重启都从零开始 ⇒
          同一个 key 回来也认不出自己（只能拿到新槽位、新角色）。
        ★ 返回灌进去的条数（0 = 存档里没有身份信息，这是**正常**情况）。
        """
        n = 0
        for slot_s, key in (mapping or {}).items():
            try:
                slot = int(slot_s)
            except (TypeError, ValueError):
                continue
            if not key:
                continue
            self.by_key[str(key)] = slot
            self.slot_key[slot] = str(key)
            n += 1
        return n

    def release_slot(self, cid):
        """连接断开：回收槽位 + **原子地**把「删掉这个槽位的玩家」排进命令队列。

        ★★★ 「放回空闲表」与「入队 remove」**必须在同一把锁里**做 —— 这是踩出来的：
          第一版先 release（把槽位放回 free_slots）、调用方再 `cmds.put(remove)`。
          中间那个窗口里，**新连接可以拿到同一个槽位**并把 `add_player` 排进队列，
          于是队列顺序变成 **add → remove** ⇒ 新角色的实体**刚建出来就被删掉**，
          而客户端已经拿到了它的 guid ⇒ 症状是「我在帧里找不到自己」（间歇性！）。
          ⇒ 修法：两件事在同一把锁内完成，新连接拿槽位时 remove 一定已经排在它前面。
        """
        with self.lock:
            slot = self.slot_of.pop(cid, None)
            if slot is None or slot < 0:
                return slot
            key = self.slot_key.get(slot)
            if key and self.reconnect_grace > 0:
                # ★ 注意：**包括槽位 0**。槽位 0 是「默认玩家」，但带 key 的客户端认领过它，
                #   它就得和普通角色一样有生命周期 —— 否则刷新一次就漏一个空壳（D2 抓到的）。
                #   无 key 的匿名连接仍然享受老行为（槽位 0 永久存在，向后兼容）。
                # ★★ 带身份的客户端断线 ⇒ **保留**这一小段时间（玩家不删、槽位不回收）：
                #   刷新页面 / 短暂掉线后重连，拿回的还是同一个角色（同一个 guid、同一个位置）。
                #   到期没回来才真正删掉（由模拟线程扫 reserved 表）。
                if slot != 0:
                    self.reserved[slot] = time.time() + self.reconnect_grace
                else:
                    self.reserved[0] = time.time() + self.reconnect_grace
                return slot
            if slot != 0:
                self.free_slots.append(slot)
                self.free_slots.sort()
                self.by_key.pop(key, None) if key else None
                self.slot_key.pop(slot, None)
                # ★ 与回收到空闲表**同时**入队（见上），顺序由 FIFO 保证
                self.cmds.put(("remove_player", slot))
            return slot

    def reap_reserved(self):
        """扫一遍保留期，到期的真正删掉（槽位回收 + 删玩家）。返回清掉的槽位列表。"""
        now = time.time()
        out = []
        with self.lock:
            for slot, deadline in list(self.reserved.items()):
                if deadline > now:
                    continue
                self.reserved.pop(slot, None)
                key = self.slot_key.pop(slot, None)
                if key:
                    self.by_key.pop(key, None)
                self.free_slots.append(slot)
                self.free_slots.sort()
                self.cmds.put(("remove_player", slot))
                out.append(slot)
        return out

    def is_paused(self):
        with self.lock:
            return self.paused

    def set_paused(self, on):
        with self.lock:
            was = self.paused
            self.paused = bool(on)
        return was, bool(on)

    def publish(self, payload: dict):
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        with self.lock:
            self.snap = payload        # ★ 也留一份原始快照
            self.frame = data
            self.frame_ver += 1

    def latest_snap(self, since_ver):
        with self.lock:
            if self.frame_ver == since_ver or self.snap is None:
                return None, since_ver
            return self.snap, self.frame_ver

    def latest(self, since_ver):
        with self.lock:
            if self.frame_ver == since_ver or not self.frame:
                return None, since_ver
            return self.frame, self.frame_ver


# =============================================================================
# 模拟线程：固定步长
# =============================================================================
# ★ 录像落盘周期（秒）。为什么要**单独**一个常量、而不是用存档那个 30 s：
#   `deploy/stop.sh` 是硬杀进程，收尾写根本不会执行 —— 周期就是「最多丢多少」。
RECORD_FLUSH_SEC = 5.0


def sim_loop(sim: Sim, hub: Hub, stop: threading.Event, quiet=False, save_file=None,
             autosave_sec=30, record_file=None):
    # ★ C1：让看门狗知道「该抓哪个线程的栈」
    hub.sim_ident = threading.get_ident()
    hub.beat = time.perf_counter()
    nxt = time.perf_counter()
    acc = 0.0
    last_report = time.perf_counter()
    last_save = time.perf_counter()
    last_record = time.perf_counter()
    frames = 0
    steps_seen = 0         # 循环迭代计数（只用于「每 N 次」这类节流）
    record_flushes = 0      # 录像落盘次数（只为把日志降频）
    paused_iters = 0        # 暂停期间的迭代计数（用于把发帧降到 ~10 Hz）
    while not stop.is_set():
        # 0) 世界变更命令（加/删玩家）——**只有这里能碰 Lua**（见 Hub.cmds 的注释）
        while True:
            try:
                cmd = hub.cmds.get_nowait()
            except queue.Empty:
                break
            kind = cmd[0]
            try:
                if kind == "add_player":
                    slot = int(cmd[1])
                    ok, res = sim.api.add_player(slot)
                    with hub.lock:
                        if ok:
                            hub.slot_guid[slot] = int(res)
                        hub.player_count = int(sim.api.player_count())
                    # ★★ 失败的**必须无条件打印**：`--quiet` 只是「别刷屏」，
                    #   不是「出错也别说话」。实测踩到：加玩家失败被 --quiet 吞掉，
                    #   症状是「客户端收不到 you 握手」，而日志里**一个字都没有**。
                    if ok:
                        if not quiet:
                            print("[player] 槽位 %d 加入 → %s" % (slot, res))
                    else:
                        print("[player] ✘ 槽位 %d 加入失败：%s" % (slot, res))
                elif kind == "act":
                    slot, guid = int(cmd[1]), int(cmd[2])
                    ok, res = sim.api.act(slot, guid)
                    with hub.lock:
                        hub.act_result[slot] = {"ok": bool(ok), "msg": str(res)}
                    if not ok and not quiet:
                        print("[act] 槽位 %d 被拒：%s" % (slot, res))
                elif kind == "unact":
                    slot = int(cmd[1])
                    sim.api.unact(slot)
                elif kind == "respawn":
                    # ★ 显式请求复活（HTTP `/respawn?slot=N`）—— 与自动复活是**同一个**入口
                    slot = int(cmd[1])
                    ok, res = sim.api.respawn(slot)
                    if not quiet:
                        print("[player] 槽位 %d 复活请求 → %s（%s）" % (slot, ok, res))
                elif kind == "kill":
                    # ★★ 只在 `--allow-debug` 时才会进队（见 HTTP 的 `/debug/kill`）。
                    #   为什么要有它：**跨进程**测「死亡 ⇒ 自动复活 ⇒ 客户端认回自己」这条链
                    #   需要一个从外部触发死亡的手段；否则这条链只能靠进程内测（§9aa.5 登记过）。
                    slot = int(cmd[1])
                    sim.api.force_kill(slot)
                    if not quiet:
                        print("[player] 槽位 %d 调试击杀（--allow-debug）" % slot)
                elif kind == "remove_player":
                    slot = int(cmd[1])
                    ok, res = sim.api.remove_player(slot)
                    with hub.lock:
                        hub.slot_guid.pop(slot, None)
                        hub.player_count = int(sim.api.player_count())
                    if not quiet:
                        print("[player] 槽位 %d %s → %s" % (slot, "移除" if ok else "失败", res))
                elif kind == "save":
                    # ★★ P37：**立即存档**（HTTP `/save`）。为什么必须有它：
                    #   `stop.sh` 是 `taskkill //F`（硬杀），进程**没有机会**保存；而周期
                    #   自动存档是 30 s 一次 ⇒ 直接杀会丢掉最后 30 s 的世界进度，刚连上的
                    #   客户端身份也可能还没落盘（P36 的「挺过重启」于是时灵时不灵）。
                    #   ⇒ 停服前先请求一次「立即存」，**等它回话**再杀。
                    #   ⚠️ 必须在这里做：**只有模拟线程能碰 Lua**（见 hub.cmds 的注释）。
                    ev, box = cmd[1], cmd[2]
                    try:
                        if not save_file:
                            box.update(ok=False, error="服务端没带 --save-file，无法立即存档")
                        else:
                            n, sz = sim.autosave(save_file, slot_keys=dict(hub.slot_key))
                            box.update(ok=True, n=int(n), sz=int(sz), path=save_file)
                            if not quiet:
                                print("[save] 立即存档（/save）：%d 实体 / %d 字节 → %s"
                                      % (int(n), int(sz), save_file))
                    except Exception as e:                      # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()                                # ★ 无论如何都要唤醒 HTTP 线程，否则它会干等 25 s
                elif kind == "stall":
                    # ★ C1：`/debug/stall?ms=N` —— 故意让模拟线程停 N 毫秒。
                    #   这是**唯一能让看门狗真的响一次**的手段；没有它就等于
                    #   「看门狗写好了，但从没被验证过会响」。
                    #   ⚠️ 只在 `--allow-debug` 时才会进队。
                    ms = int(cmd[1])
                    print("[debug] 故意让模拟线程停 %d ms（/debug/stall）" % ms)
                    time.sleep(ms / 1000.0)
                elif kind == "light":
                    # ★ P38：给某个槽位开/关「随身光源」（HTTP `/light?slot=N&r=R`）。
                    #   改的是 Lua 侧的表 ⇒ 必须在模拟线程里做（见 hub.cmds 的注释）。
                    slot, rr = int(cmd[1]), cmd[2]
                    ok, res = sim.api.set_player_light(slot, rr)
                    if not quiet:
                        print("[light] 槽位 %d 随身光源 → %s（%s）" % (slot, ok, res))
                elif kind == "debug_spawn":
                    # ★ P41：`/debug/spawn?prefab=X[&x=&z=]`
                    #   同步回话（ev/box）：调用方要拿到**真实结果**（guid / 失败原因），
                    #   而不是「已入队」。与 `/save` 同一套等待纪律。
                    prefab, xx, zz, ev, box = cmd[1], cmd[2], cmd[3], cmd[4], cmd[5]
                    try:
                        ok, info = sim.debug_spawn(prefab, xx, zz)
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "debug_give":
                    slot, prefab, n, ev, box = cmd[1], cmd[2], cmd[3], cmd[4], cmd[5]
                    try:
                        ok, info = sim.debug_give(slot, prefab, n)
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "debug_act":
                    # ★ T6：`/debug/act?slot=&radius=&impl=index|linear&n=` ——
                    #   交互目标列表的「索引版 vs 线性版」比对 + 计时。
                    slot, radius, impl, nn, ev, box = (cmd[1], cmd[2], cmd[3], cmd[4],
                                                       cmd[5], cmd[6])
                    try:
                        ok, info = sim.debug_act(slot, radius, impl, nn)
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=str(info))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "debug_entity":
                    guid, ev, box = cmd[1], cmd[2], cmd[3]
                    try:
                        ok, info = sim.debug_entity(guid)
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "debug_stats":
                    # 与 `/healthz` 的区别：那个读的是**缓存**（最多落后 0.27 s），
                    # 这个当场在模拟线程里算一次 —— 运维排查「缓存和真实对不上」时用它。
                    ev, box = cmd[1], cmd[2]
                    try:
                        box.update(ok=True, stats=sim.stats())
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                else:
                    print("[cmd] ⚠ 未知命令（忽略）: %r" % (kind,))
            except Exception as e:                              # noqa: BLE001
                print("[cmd] ✘ %s 执行失败：%s: %s" % (kind, type(e).__name__, e))

        # 0.5) 扫「重连保留期」（到期的角色真正删掉）
        if hub.reserved:
            for slot in hub.reap_reserved():
                if not quiet:
                    print("[player] 槽位 %d 保留期到，已清掉" % slot)

        # 0.6) 每 8 tick（≈0.27 s）刷一次「可交互目标」——供客户端显示与就近选择。
        #      ★ 放在模拟线程里算：它要读世界（组件），**只有模拟线程能碰 Lua**。
        #      ★ 没人连时不刷（省掉纯浪费的遍历）。
        # 0.55) guid 对账（每 ~0.27 s 一次）：**与有没有客户端无关**。
        #   ★★ 为什么不能放在「有客户端才做」的分支里（2026-10-16）：槽位 0 也可能在
        #      **没人连**的时候死掉并复活（`rt_boot` 的自动复活）⇒ `slot_guid` 会留旧 guid，
        #      之后客户端一连上问 `whoami`，拿到的就是**已经不存在**的那个 guid ⇒ 变瞎。
        #   ⇒ 对账要独立做，范围取「已知槽位的并集 + 槽位 0」。
        #   ★★ P37 补：并集里还要有 `slot_key`（= 存档带回来的**会话身份槽位**）。
        #      否则重启后 `slot_guid` 与 `slot_of` 都是空的 ⇒ 只对账槽位 0 ⇒
        #      槽位 1 的 guid 要**等客户端带 key 连上**才登记（whoami 于是要重试若干轮）。
        #      加上它之后：一读档就知道「槽位 1 该有角色」，模拟线程立刻把 guid 填好。
        if (steps_seen % 8) == 0:
            # ★ 统计缓存：让 /status 与 /healthz **不再**跨线程进 Lua（见 Hub.stats_cache 的说明）
            try:
                _st = sim.stats()
                with hub.lock:
                    hub.stats_cache = _st
            except Exception as e:                               # noqa: BLE001
                if not quiet:
                    print("[stats] 统计缓存刷新失败：%s" % e)
            with hub.lock:
                known_slots = sorted(set(hub.slot_guid) | set(hub.slot_of.values())
                                     | set(hub.slot_key) | {0})
            for sl in known_slots:
                try:
                    g = sim.api.player_guid(sl)
                except Exception:                                # noqa: BLE001
                    continue
                if g is None:
                    continue
                g = int(g)
                with hub.lock:
                    if hub.slot_guid.get(sl) != g:
                        hub.slot_guid[sl] = g
                        if not quiet:
                            print("[player] 槽位 %d 的实体变成了 guid=%d（复活/换身体）" % (sl, g))

        if hub.clients > 0 and (steps_seen % 8) == 0:
            with hub.lock:
                live_slots = sorted(set(hub.slot_of.values()))
            if live_slots:
                tg = {}
                for sl in live_slots:
                    try:
                        tg[sl] = sim.act_targets(sl, 20)
                    except Exception as e:                      # noqa: BLE001
                        if not quiet:
                            print("[act] 目标列表失败（槽位 %d）：%s" % (sl, e))
                with hub.lock:
                    hub.targets_by_slot = tg
                # ★ P39：同一节拍顺手把「我怎么了」也算好。
                #   放在这里（而不是每次请求现算）有两个理由：
                #   ① **只有模拟线程能碰 Lua**（hub.cmds 的纪律）；
                #   ② HUD 是 30 Hz 画面上的东西，但状态每 0.27 s 刷一次就够 ——
                #      现算会让「按一下背包」变成一次跨线程排队。
                me = {}
                for sl in live_slots:
                    try:
                        me[sl] = sim.player_state(sl)
                    except Exception as e:                      # noqa: BLE001
                        if not quiet:
                            print("[me] 玩家状态失败（槽位 %d）：%s" % (sl, e))
                with hub.lock:
                    hub.me_by_slot = me
        steps_seen += 1

        # 1) 应用输入（每次 step 前一次性清空队列）
        drained = 0
        while True:
            try:
                slot, k, v = hub.inputs.get_nowait()
            except queue.Empty:
                break
            # ★ 一律走 `set_input_for`：槽位 0 由 Lua 侧路由到 `M.set_input`（真实 TheInput），
            #   槽位 ≥1 走各自的输入表 ⇒ 驱动逻辑只有一份，不会出现「本地能走、远端不能走」。
            sim.api.set_input_for(slot, k, v)
            drained += 1
        # 2) 固定步长推进（**暂停时不推进**，见 P3「暂停」项）
        # ★ 输入**照收不误**：暂停期间按住的键会被记住，恢复后立刻生效 ——
        #   这与「暂停 = 世界时间停住」的语义一致，而不是「暂停 = 丢掉输入」。
        paused = hub.is_paused()
        if paused:
            # ★★ 暂停时也**必须继续发帧**，只是降频到 ~10 Hz。
            #   不发的话客户端收不到任何东西，看起来就像断线了
            #   （它会显示「已断开，重连中…」）—— 那是**误报**，而误报会训练人忽略它。
            paused_iters += 1
            if paused_iters % 3 == 0:
                snap = sim.snapshot()
                snap["paused"] = True          # ★ 帧里如实报「世界停住了」
                hub.publish(snap)
        else:
            paused_iters = 0
            sim.step()
            frames += 1
            # 3) 发布快照
            snap = sim.snapshot()
            snap["paused"] = False
            hub.publish(snap)
        # 4) 睡到下一 tick
        nxt += sim.dt
        now = time.perf_counter()
        sleep = nxt - now
        if sleep > 0.5:
            # ★★ 「睡超过半秒」在 30 Hz 的循环里**不可能**是好状态：
            #   要么时间基准被谁改了，要么循环被拖住过。必须吵（否则症状是
            #   「世界突然不动了，而日志一片安静」—— 今天为这个查了很久）。
            print("[sim] ⚠ 这一拍要睡 %.2f s（异常：30 Hz 下应按 ~0.033 s）—— "
                  "检查时间基准/是否有阻塞" % sleep)
            # ★★★ C1（P44）：**不能真的睡下去**。
            #   停帧 5 s 之后如果老老实实再睡 5 s，等于把一次停帧放大成两次；
            #   而且追帧逻辑（下面的 acc）会让之后每一拍都"补课"，
            #   表现为「世界恢复了但一直在快进」。
            #   ⇒ 重置时间基准：从"现在"重新开始，**不补课**。
            nxt = now
            acc = 0.0
            sleep = 0.0
        if sleep > 0:
            time.sleep(sleep)
        else:
            # 追不上：把 acc 记下来（P1 只在 stats 里体现，不静默吞）
            acc += -sleep
            if acc > 1.0:
                acc = 0.0
                nxt = now
        # ★★ 周期写下录像。**周期必须短**（5 s），不能沿用存档那个 30 s：
        #   `deploy/stop.sh` 在 Windows 上是 `taskkill /F`（**硬杀**，收不到信号、
        #   走不到 finally），所以「只在收尾写」= 大概率一个字都没落下。
        #   代价：每 5 s 写几 KB。收益：最多丢 5 s 录像 —— 而不是全丢。
        if record_file and (now - last_record) >= RECORD_FLUSH_SEC:
            try:
                tk, ne, sz = sim.save_recording(record_file)
                # 每 5 s 写一次但**不必每 5 s 都打日志**（30 s 报一次就够看）
                record_flushes += 1
                if not quiet and record_flushes % 6 == 0:
                    print("[rec] 录像落盘：%d tick / %d 事件 / %d 字节" % (tk, ne, sz))
            except Exception as e:                              # noqa: BLE001
                print("[rec] ✘ 写录像失败（不中断世界）：%s: %s" % (type(e).__name__, e))
            last_record = now

        # ★ 周期自动存档（**原子写**，见 Sim.autosave 的注释）
        if save_file and (now - last_save) >= autosave_sec:
            try:
                with hub.lock:
                    _keys_now = dict(hub.slot_key)
                n, sz = sim.autosave(save_file, slot_keys=_keys_now)
                if not quiet:
                    print("[save] 自动存档：%d 实体 / %d 字节 → %s" % (n, sz, save_file))
            except Exception as e:                              # noqa: BLE001
                print("[save] ✘ 自动存档失败（不中断世界）：%s" % e)
            last_save = now

        # ★ C1：心跳。**每拍**都要写 —— 这是看门狗唯一的输入。
        hub.beat = time.perf_counter()

        if not quiet and now - last_report >= 5.0:
            st = sim.stats()
            print("[sim] tick=%d t=%.1fs ents=%d clients=%d 落后累计=%.2fs"
                  % (st["tick"], st["time"], st["n_ents"], hub.clients, acc))
            last_report = now


def watchdog_loop(hub: Hub, stop: threading.Event, check_sec=0.5):
    """★ C1：独立看门狗 —— 发现「模拟循环停住」并把现场留下来。

    ★★★ 为什么必须是**另一个线程**
        如果把它写进 `sim_loop` 的循环体里，那么「循环停了」这件事本身
        就没人检查了 —— 看门狗会跟着一起停。这是本判据唯一不可妥协的设计点。

    ★ 为什么不是「发现就重启」
        Python 无法安全地中断一个卡在 C 扩展（lupa/Lua）里的线程。硬杀会丢存档、
        连客户端一起断，而且**把证据一起毁掉**。所以这里只做三件事：
          ① 计数（`/healthz` 的 `stalls`）
          ② 抓**卡住那一刻**的 Python 栈（`last_stall.trace`）—— 这是定位根因的唯一线索
          ③ 让主循环在恢复后重置时间基准（见 `sim_loop` 里 sleep > 0.5 的分支）
        「能自愈」在这里的正确含义是**留证 + 让下一拍不疯狂追帧**，不是假装没发生。

    ★ 去重：一次停帧只记一次（`_stall_marked`），否则每 0.5 s 记一次会把次数灌水。
    """
    import sys as _sys
    import traceback as _tb
    while not stop.wait(check_sec):
        beat = hub.beat
        if not beat:
            continue
        gap = time.perf_counter() - beat
        if gap <= hub.stall_threshold:
            hub._stall_marked = False
            continue
        if hub._stall_marked:
            continue
        hub._stall_marked = True
        trace = ""
        ident = hub.sim_ident
        if ident is not None:
            frame = _sys._current_frames().get(ident)
            if frame is not None:
                trace = "".join(_tb.format_stack(frame)[-8:])
        with hub.lock:
            hub.stalls += 1
            n = hub.stalls
            hub.last_stall = {
                "at": time.time(),
                "gap": round(gap, 3),
                "threshold": hub.stall_threshold,
                "clients": hub.clients,
                "trace": trace,
            }
        print("[watchdog] ⚠ 模拟循环已停 %.2f s（阈值 %.1f s）—— 第 %d 次" % (gap, hub.stall_threshold, n))
        if trace:
            print("[watchdog] 卡住时的模拟线程栈：\n" + trace)
        else:
            print("[watchdog] （取不到模拟线程栈 —— 可能卡在 C 扩展里）")


# =============================================================================
# HTTP + WebSocket（同端口）
# =============================================================================
def _stats_from_cache(self):
    """`/status` 与 `/healthz` 用的统计：**只读**模拟线程写好的缓存。

    ★★ 为什么不能写 `Handler.sim_stats = sim.stats`：
      `sim.stats()` → `api.stats()` → 直接**进 Lua**。处理线程每来一个请求就进一次，
      而 lupa 的 LuaRuntime 只有一个、且**不是线程安全的**（本文件开头就写着
      「模拟线程独占运行时」）。`/status` 与 `/healthz` 恰好是**最容易被高频访问**的
      两个端点（发布后就是给人刷的），把 Lua 暴露在它们上面，等于把纪律的口子
      开在流量最大的地方。
    ⇒ 缓存由 `sim_loop` 每 8 拍（≈0.27 s）刷新一次（见 Hub.stats_cache）。
    """
    with self.hub.lock:
        st = self.hub.stats_cache
        out = dict(st) if isinstance(st, dict) else {}
        # ★★ C1：把看门狗状态并进 stats —— `/healthz` 与 `/status` 都会带上。
        #   为什么放在这里而不是 `Sim.stats()`：`Sim.stats()` 要**进 Lua**，
        #   而这两个端点跑在处理线程（本文件开头那条纪律：只有模拟线程能碰 Lua）。
        out["stalls"] = self.hub.stalls
        out["stall_threshold"] = self.hub.stall_threshold
        out["stall_age"] = (round(time.perf_counter() - self.hub.beat, 3)
                           if self.hub.beat else None)
        out["last_stall"] = self.hub.last_stall
    return out


class Handler(socketserver.BaseRequestHandler):
    hub = None
    slot = 0          # ★ P20：WS 连接会覆盖它；HTTP 连接保持 0
    sim_stats = None
    sim_terrain = None
    static_dir = None
    allow_debug = False        # ★ 默认关闭：`--allow-debug` 才开（见 /debug/kill）

    def handle(self):
        try:
            self.request.settimeout(0.2)
            raw = b""
            # 读请求头（到 \r\n\r\n 为止）
            deadline = time.time() + 5
            while b"\r\n\r\n" not in raw and time.time() < deadline:
                try:
                    chunk = self.request.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    return
                raw += chunk
                if len(raw) > 65536:
                    return
            if not raw:
                return
            method, path, headers = ws.parse_http_headers(raw)

            if headers.get("upgrade", "").lower() == "websocket":
                self._serve_ws(headers, path)
            else:
                self._serve_http(method, path)
        except Exception as e:                                  # noqa: BLE001
            # ★ 诊断：**不再静默**。之前这里把异常吞掉、只往 wfile 写一句，
            #   结果 /healthz 对客户端表现为「连接直接断」——查了半天。
            import traceback
            print("[handler] 异常（连接 %s）: %s: %s" % (self.client_address, type(e).__name__, e))
            traceback.print_exc()
            try:
                # ★★ 状态行**不要**用占位符（原来是 "500 x"）：客户端（urllib）只会把
                #   reason phrase 显示出来，于是所有 500 都长得一样、看不出是谁干的 ——
                #   加世界组件那次就是被这个坑掉的（`stats()` 里混进一个 Lua 表，
                #   /healthz 全 500，而看到的只是 "HTTP Error 500: x"）。
                #   现在：状态行用标准 reason phrase，body 里带异常类型 + 消息。
                body = json.dumps({"error": "%s: %s" % (type(e).__name__, e)},
                                  ensure_ascii=False).encode("utf-8")
                self._reply(b"HTTP/1.1 500 Internal Server Error\r\n"
                            b"Content-Type: application/json; charset=utf-8\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
            except Exception:                                    # noqa: BLE001
                pass

    def _serve_atlas(self, rel):
        """供图集资源（只读，且**限制在允许的目录内**）。

        ★ 两类资源在**不同目录**（第一版我以为是同一个，结果 PNG 全 404）：
             json/<build>.json          -> 06-引擎复刻/_out/json/
             anim_data/<build>__atlas-N.png -> 06-引擎复刻/anim_data/
        ★ 为什么单独一条路由：图集在**另一个工程目录**下，而静态目录是 rt/ 自己；
          混在一起会让 /../ 之类的东西有机可乘。
        ★ 额外防御：rel 里出现 ".." 直接拒（双保险，normpath 之前就拦）。"""
        if ".." in rel.replace("\\", "/").split("/"):
            self._reply(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 9\r\n\r\nforbidden")
            return
        if rel.startswith("json/"):
            sub = rel[len("json/"):]
            dirs = [os.path.join(SELF_ATLAS_DIR, "json"), ATLAS_JSON_DIR]
        elif rel.startswith("anim_data/"):
            sub = rel[len("anim_data/"):]
            dirs = [os.path.join(SELF_ATLAS_DIR, "anim_data"), ATLAS_PNG_DIR]
        else:
            self._reply(b"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found")
            return
        # ★ 按顺序找：**自产素材先命中**（发布版只放自产目录 ⇒ 天然不碰原版资产）
        full = None
        for base in dirs:
            cand = os.path.normpath(os.path.join(base, sub))
            if cand.startswith(os.path.abspath(base)) and os.path.isfile(cand):
                full = cand
                break
        if full is None:
            self._reply(b"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found")
            return
        ctype = "application/json" if full.endswith(".json") else "image/png"
        with open(full, "rb") as f:
            data = f.read()
        self._reply(("HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n"
                     "Cache-Control: max-age=3600\r\n\r\n" % (ctype, len(data))).encode() + data)

    def _reply(self, data: bytes):
        """统一下发。★ 注意：本类继承的是 `BaseRequestHandler`，
        它**不提供** `self.wfile`/`self.rfile`（那是 `StreamRequestHandler` 才装的）
        —— 一开始写成了 `self.wfile.write(...)`，异常又被一个宽 except 吞掉，
        对外表现为「连接直接断」，白查了一阵。现在直接写 socket，并且不再静默。"""
        self.request.sendall(data)

    def _debug_allowed(self) -> bool:
        """★ 调试端点的**唯一**开关判定（P41 收敛）。

        改之前 `/debug/kill` 与 `/debug/*` 各写了一遍
        `if not getattr(self, "allow_debug", False):` —— 两处字面量完全相同。
        后果有两个，第二个更麻烦：
          ① 同一份判据写两次，改一处忘一处就是「一个端点静默敞开」；
          ② 变异测试的锚点串**出现 2 次**，脚本拒绝盲改（`锚点串出现 2 次`）——
             它宁可报红也不猜，这点是对的，但也说明锚点选在了「重复的字面量」上。

        ⇒ 收敛成一个方法：语义仍然是「默认关，`--allow-debug` 才开」，
          但开关只有一处，变异也只需要改这一处。
        """
        return bool(getattr(self, "allow_debug", False))

    # ---------- 静态文件 / healthz ----------
    def _serve_http(self, method, path):
        # ★★★ T7：HTTP 方法校验 —— 本服务的**每一个** HTTP 端点都是「读」语义。
        #
        # 改之前：`method` 被解析出来后**从头到尾没人用**。
        #   后果不是崩溃，而是**语义错**：
        #     · `POST /healthz` 会照常返回 200 + 一份健康报告 ——
        #       调用方（监控/部署脚本）以为「写操作成功」；
        #     · `DELETE /save` 会**真的去执行存档流程**（路由只认 path 不认 method）；
        #     · `PUT /debug/kill?slot=0` 会**真的把人杀了**。
        #   「没人会这么发」不是理由：健康检查、反向代理、CDN 回源都可能改写方法，
        #   而 405 是唯一能让对方**知道**自己用错方法的回应。
        #
        # 为什么是 405 而不是 404：404 表示「这个路径不存在」，而路径是存在的、
        # 只是方法不对。RFC 7231 要求 405 必须带 `Allow` 头，把「该用什么」说清楚 ——
        # 少了这个头，客户端只能靠猜，等于把同一个问题又丢回去。
        # ⚠️ `Allow` 只写 `GET`，**不写 HEAD**：本服务没实现 HEAD
        #   （`_reply` 会照常写 body），写上去就是骗人。
        # ★ 放在**所有路由之前**：`/atlas/`、`/status`、`/healthz`、`/debug/*`、
        #   静态文件走的是同一个 `_serve_http`，一处拦住就全拦住 ——
        #   这也避免了「以后新增一个端点忘了校验」的漏网。
        if method is not None and str(method).upper() != "GET":
            body = json.dumps({"ok": False,
                               "error": "只支持 GET（收到 %s）" % str(method).upper()},
                              ensure_ascii=False).encode("utf-8")
            self._reply(b"HTTP/1.1 405 Method Not Allowed\r\n"
                        b"Allow: GET\r\n"
                        b"Content-Type: application/json; charset=utf-8\r\n"
                        b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
            return

        # ★★ P4：图集资源（真实图集在 06-引擎复刻/_out/ 下）
        #   /atlas/json/<build>.json          —— 图集元数据（symbols/anims/UV）
        #   /atlas/anim_data/<build>__atlas-N.png —— 真实贴图
        if path.split("?")[0].startswith("/atlas/"):
            self._serve_atlas(path.split("?")[0][len("/atlas/"):])
            return

        # ★ P6：状态页（给发布后的人看「现在什么情况」）
        if path.split("?")[0] == "/status":
            st = self.sim_stats()
            # ★ 世界环境从 **hub 里最近一帧快照** 取，而不是从处理线程里再调一次 Lua ——
            #   Sim 只有一个 LuaRuntime，跨线程调用会和模拟线程抢状态。
            #   帧里本来就有 world（snapshot() 每帧都带），直接用最省事也最安全。
            with self.hub.lock:
                w = dict((self.hub.snap or {}).get("world") or {})
            PH_CN = {"day": "白天", "dusk": "黄昏", "night": "夜晚"}
            SE_CN = {"autumn": "秋", "winter": "冬", "spring": "春", "summer": "夏"}
            body = STATUS_HTML.replace("{{TICK}}", str(st.get("tick", "?"))) \
                              .replace("{{TIME}}", "%.1f" % st.get("time", 0)) \
                              .replace("{{ENTS}}", str(st.get("n_ents", "?"))) \
                              .replace("{{CLIENTS}}", str(self.hub.clients)) \
                              .replace("{{PLAYERS}}", str(self.hub.player_count)) \
                              .replace("{{PLAYER}}", "在" if st.get("player_ok") else "缺") \
                              .replace("{{BADFRAMES}}", str(self.hub.dropped_bad_frames)) \
                              .replace("{{SENT}}", str(self.hub.frames_sent)) \
                              .replace("{{PHASE}}", PH_CN.get(w.get("phase"), w.get("phase") or "?")) \
                              .replace("{{SEASON}}", SE_CN.get(w.get("season"), w.get("season") or "?")) \
                              .replace("{{TEMP}}", "%.1f" % w.get("temperature", 0.0)) \
                              .replace("{{WORLDOK}}", "5/5 ✔" if st.get("world_ok")
                                                          else "<b style='color:#f85149'>缺 %s</b>"
                                                               % (st.get("world_missing"),)) \
                              .replace("{{PAUSED}}", "<b style='color:#d29922'>⏸ 已暂停</b>"
                                                     if self.hub.is_paused() else "▶ 运行中") \
                              .replace("{{BOOT}}", str(st.get("boot", "?"))) \
                              .replace("{{ALIVE}}", "<b style='color:#3fb950'>活着</b>"
                                                     if st.get("player_alive") is True
                                                     else "<b style='color:#f85149'>已死亡</b>"
                                                          if st.get("player_alive") is False
                                                          else str(st.get("player_alive", "?"))) \
                              .replace("{{HEALTH}}", "%.0f" % st["player_health"]
                                                     if isinstance(st.get("player_health"), (int, float))
                                                     else str(st.get("player_health", "?"))) \
                              .replace("{{SLOTS}}", _slots_html(st.get("players") or {})) \
                              .replace("{{RESPAWNS}}", str(st.get("respawns", "?"))) \
                              .replace("{{FIRES}}", str(st.get("fires", "?"))) \
                              .replace("{{FIRES_LIT}}", str(st.get("fires_lit", "?"))) \
                              .replace("{{PLAYER_LIGHT}}", str(st.get("player_light", "?")))
            data = body.encode("utf-8")
            self._reply(b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                        b"Content-Length: " + str(len(data)).encode() + b"\r\n"
                        b"Cache-Control: no-store\r\n\r\n" + data)
            return

        # ★ 显式复活：`/respawn?slot=N`（与 `/pause` 同族的「从外部控制世界」入口）
        #   ⚠️ 只是**请求**：真正的复活在**模拟线程**里做（命令队列），
        #     所以这里回的是「已入队」，结果要看 `/healthz` 的 `player_alive`/`respawns`。
        if path.split("?")[0] == "/respawn":
            q = path.split("?", 1)[1] if "?" in path else ""
            slot = 0
            bad = False
            for kv in q.split("&"):
                if kv.startswith("slot="):
                    try:
                        slot = int(kv[5:])
                    except ValueError:
                        bad = True
            if bad or slot < 0:
                body = b"slot must be a non-negative integer\n"
                self._reply(b"HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return
            self.hub.cmds.put(("respawn", slot))
            body = ("queued: respawn slot=%d\ncheck /healthz for player_alive / respawns\n" % slot).encode()
            self._reply(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                        b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
            return

        # ★★ C1：`/debug/stall?ms=N` —— 故意让模拟线程停 N 毫秒。
        #   为什么需要它：看门狗这种东西，**不真的响一次就不知道它会不会响**。
        #   这个端点是唯一能在集成层面把「停帧」造出来的手段（单元测试测不到线程）。
        #   ⚠️ 与 /debug/kill 同级：默认关闭，`--allow-debug` 才开。
        if path.split("?")[0] == "/debug/stall":
            if not self._debug_allowed():
                body = (b"debug endpoints disabled (start the server with --allow-debug)\n")
                self._reply(b"HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return
            q = path.split("?", 1)[1] if "?" in path else ""
            ms = 3000
            for kv in q.split("&"):
                if kv.startswith("ms="):
                    try:
                        ms = max(1, int(kv[3:]))
                    except ValueError:
                        ms = 3000
            self.hub.cmds.put(("stall", ms))
            body = ("queued: stall %d ms\ncheck /healthz for stalls / last_stall\n" % ms).encode()
            self._reply(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                        b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
            return

        # ★★ 调试击杀：`/debug/kill?slot=N` —— **默认关闭**，只有 `--allow-debug` 时才存在。
        #   为什么要有它：跨进程验「死亡 ⇒ 自动复活 ⇒ 客户端认回自己」需要一个外部触发死亡的
        #   手段（§9aa.5 登记过这个缺口）。为什么默认关：它能杀掉玩家的角色，
        #   **不该出现在公网部署上** —— 发布检查单里专门写了一条「别开 --allow-debug」。
        if path.split("?")[0] == "/debug/kill":
            if not self._debug_allowed():
                body = (b"debug endpoints disabled (start the server with --allow-debug)\n")
                self._reply(b"HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return
            q = path.split("?", 1)[1] if "?" in path else ""
            slot = 0
            for kv in q.split("&"):
                if kv.startswith("slot="):
                    try:
                        slot = int(kv[5:])
                    except ValueError:
                        pass
            self.hub.cmds.put(("kill", slot))
            body = ("queued: debug kill slot=%d\n" % slot).encode()
            self._reply(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                        b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
            return

        # ★ P41：调试通道三件套 —— `/debug/spawn` / `/debug/give` / `/debug/stats`
        #   与 `/debug/kill` 同一开关：**默认 404**，必须 `--allow-debug`（发布检查单里
        #   写着「公网部署别开」）。三个都**走 hub.cmds 排队** —— 它们要碰 Lua。
        #   `/debug/spawn` 与 `/debug/give` 是**同步**的（等模拟线程回话），
        #   因为调用方要的是「真的生成了没有 / 为什么没生成」，而不是「已入队」。
        if path.split("?")[0].startswith("/debug/"):
            if not self._debug_allowed():
                body = b"debug endpoints disabled (start the server with --allow-debug)\n"
                self._reply(b"HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return
            sub = path.split("?")[0]
            q = path.split("?", 1)[1] if "?" in path else ""
            arg = {}
            for kv in q.split("&"):
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    arg[k] = v                       # 名字都是 ASCII（prefab/数字），不做 unquote

            def _num(key, cast=float, default=None):
                v = arg.get(key)
                if v is None or v == "":
                    return default
                try:
                    return cast(v)
                except (TypeError, ValueError):
                    return default

            ev, box = threading.Event(), {}
            if sub == "/debug/spawn":
                self.hub.cmds.put(("debug_spawn", arg.get("prefab", ""),
                                   _num("x"), _num("z"), ev, box))
            elif sub == "/debug/give":
                self.hub.cmds.put(("debug_give", _num("slot", int, 0), arg.get("prefab", ""),
                                   _num("n", int, 1), ev, box))
            elif sub == "/debug/entity":
                self.hub.cmds.put(("debug_entity", _num("guid", int, -1), ev, box))
            elif sub == "/debug/stats":
                self.hub.cmds.put(("debug_stats", ev, box))
            elif sub == "/debug/act":
                # ★ T6：交互目标列表的索引版/线性版比对与计时。
                #   默认 impl=index、n=1（单次）；比对时再显式传 impl=linear。
                #   n 上限 200 在 Lua 侧夹紧（防止有人拿它当压测把服务打死）。
                self.hub.cmds.put(("debug_act", _num("slot", int, 0), _num("radius", float, 20.0),
                                   arg.get("impl", "index"), _num("n", int, 1), ev, box))
            else:
                body = b"unknown debug endpoint\n"
                self._reply(b"HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return

            if not ev.wait(timeout=10):
                body = json.dumps({"ok": False, "error": "10 s 内没等到模拟线程"
                                                        "（模拟循环卡住？）"},
                                  ensure_ascii=False).encode("utf-8")
                self._reply(b"HTTP/1.1 503 Service Unavailable\r\n"
                            b"Content-Type: application/json\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return
            code = b"200 OK" if box.get("ok") else b"400 Bad Request"
            body = json.dumps(box, ensure_ascii=False).encode("utf-8")
            self._reply(b"HTTP/1.1 " + code + b"\r\nContent-Type: application/json\r\n"
                        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                        b"Cache-Control: no-store\r\n"
                        b"Access-Control-Allow-Origin: *\r\n\r\n" + body)
            return

        # ★ P3 的「暂停」：`/pause?on=1|0`（POST 或 GET 都收；无 body，状态就是 URL 里的查询串）
        if path.split("?")[0] == "/pause":
            q = path.split("?", 1)[1] if "?" in path else ""
            raw = None
            for kv in q.split("&"):
                if kv.startswith("on="):
                    raw = kv[3:]
            if raw is None or raw.lower() not in ("1", "0", "true", "false", "on", "off"):
                # ★★ 取值不认就**明确回绝**，而不是「随手当成 true」——
                #   前者是「我不会做这件事」，后者是「我照做的另一件事」。
                #   一个拼错的 `?on=ture` 悄悄把世界冻住，会让人查半天。
                body = json.dumps({"ok": False, "error": "需要一个明确的 on=1 或 on=0",
                                   "got": raw}, ensure_ascii=False).encode("utf-8")
                self._reply(b"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                            b"Cache-Control: no-store\r\n\r\n" + body)
                return
            was, now = self.hub.set_paused(raw.lower() in ("1", "true", "on"))
            body = json.dumps({"ok": True, "was": was, "paused": now},
                              ensure_ascii=False).encode("utf-8")
            self._reply(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                        b"Cache-Control: no-store\r\n"
                        b"Access-Control-Allow-Origin: *\r\n\r\n" + body)
            return

        # ★★ P37：`/save` —— **立即存档，并等它真的写完**才回 200。
        #   为什么必须有它（不是「顺手加个便利端点」）：`stop.sh` 是 `taskkill //F`（硬杀），
        #   进程**没有机会**保存；周期自动存档是 30 s 一次 ⇒ 直接杀会丢掉最后 30 s 的世界
        #   进度，刚连上客户端的身份也可能还没落盘（P36 的「挺过重启」将时灵时不灵）。
        #   ⇒ 停服脚本先请求 `/save`、**等到回话**、再杀。
        #   排队与等待的纪律与 `/respawn` 同族：入队给模拟线程，回的是「已存完」，不是「已入队」。
        if path.split("?")[0] == "/save":
            ev = threading.Event()
            box = {}
            self.hub.cmds.put(("save", ev, box))
            if not ev.wait(timeout=25):
                body = json.dumps({"ok": False,
                                   "error": "25 s 内没等到存档完成（模拟循环卡住？）"},
                                  ensure_ascii=False).encode("utf-8")
                self._reply(b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return
            code = b"200 OK" if box.get("ok") else b"500 Internal Server Error"
            body = json.dumps(box, ensure_ascii=False).encode("utf-8")
            self._reply(b"HTTP/1.1 " + code + b"\r\nContent-Type: application/json\r\n"
                        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                        b"Cache-Control: no-store\r\n"
                        b"Access-Control-Allow-Origin: *\r\n\r\n" + body)
            return

        # ★ P38：`/light?slot=N&r=R` —— 给某个槽位开/关「随身光源」
        #   （与 `/respawn` 同族的「从外部控制世界」入口）。
        #   `r=0` / 缺省 = 关掉。异步入队即可：下一次 `sync_grue_light`（≤0.27 s）生效，
        #   结果看 `/healthz` 的 `players[slot].in_light`。
        #   ⚠️ 这是 07 侧的**代理**（原版靠火把的 Light 组件；本宿主没有那个组件）——
        #     默认关着，只在显式请求时才开。
        if path.split("?")[0] == "/light":
            q = path.split("?", 1)[1] if "?" in path else ""
            slot_raw, r_raw = None, None
            for kv in q.split("&"):
                if kv.startswith("slot="):
                    slot_raw = kv[5:]
                elif kv.startswith("r="):
                    r_raw = kv[2:]
            try:
                slot = int(slot_raw)
            except (TypeError, ValueError):
                body = json.dumps({"ok": False, "error": "需要 slot=<数字>", "got": slot_raw},
                                  ensure_ascii=False).encode("utf-8")
                self._reply(b"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return
            try:
                rr = float(r_raw) if r_raw not in (None, "") else 0.0
            except (TypeError, ValueError):
                body = json.dumps({"ok": False, "error": "r 必须是数字（0 = 关）", "got": r_raw},
                                  ensure_ascii=False).encode("utf-8")
                self._reply(b"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return
            self.hub.cmds.put(("light", slot, rr))
            body = json.dumps({"ok": True, "queued": {"slot": slot, "r": rr},
                               "note": "≤0.3 s 生效；看 /healthz 的 players[slot].in_light"},
                              ensure_ascii=False).encode("utf-8")
            self._reply(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                        b"Cache-Control: no-store\r\n"
                        b"Access-Control-Allow-Origin: *\r\n\r\n" + body)
            return

        # ★ P10：地形图层（开局拉一次，之后客户端本地缓存）
        if path.split("?")[0] == "/terrain":
            terr = self.sim_terrain()
            if terr is None:
                body = json.dumps({"error": "地形不可用（terrain() 未就绪）"}).encode("utf-8")
                self._reply(b"HTTP/1.1 503 Service Unavailable\r\n"
                            b"Content-Type: application/json\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return
            body = json.dumps(terr, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            self._reply(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                        b"Cache-Control: max-age=3600\r\n"
                        b"Access-Control-Allow-Origin: *\r\n\r\n" + body)
            return

        if path.split("?")[0] == "/healthz":            # 世界环境同样从最近一帧快照里取（不在处理线程里再调 Lua）
            with self.hub.lock:
                w = dict((self.hub.snap or {}).get("world") or {})
            # ★★★ 2026-10-18：顶层这个字段**从 `players` 改名成 `player_count`**（P39 踩到的）。
            #   原来一份 JSON 里有**两个叫 `players` 的东西**：
            #     顶层   `players` = 在线人数（**int**，就是这个值）
            #     `stats.players` = 按槽位的表（dict，`{槽位:{alive,health,guid}}`）
            #   两者含义完全不同、类型也不同，而顶层这个**既没文档也没消费方**
            #   （`grep '"players"'` 只剩它自己）⇒ 一个新判据想去对账「血量」
            #   时按直觉写了 `h["players"][str(slot)]`，拿到 int 后炸在
            #   `'int' object has no attribute 'get'`，白查一轮。
            #   ⇒ 起个说得清自己的名字（与 `Hub.player_count` 一致），也是本工程的老规矩：
            #     同名不同物是**陷阱**，不是简洁。
            body = json.dumps({"ok": True, "stats": self.sim_stats(),
                               "world": w,
                               "paused": self.hub.is_paused(),
                               "clients": self.hub.clients,
                               "player_count": self.hub.player_count,
                               "dropped_bad_frames": self.hub.dropped_bad_frames,
                               "frames_sent": self.hub.frames_sent},
                              ensure_ascii=False).encode("utf-8")
            self._reply(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                             b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                             b"Access-Control-Allow-Origin: *\r\n\r\n" + body)
            return
        name = path.split("?")[0].lstrip("/") or "client.html"
        full = os.path.normpath(os.path.join(self.static_dir, name))
        if not full.startswith(os.path.abspath(self.static_dir)) or not os.path.isfile(full):
            self._reply(b"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found")
            return
        ctype = "text/html; charset=utf-8" if full.endswith(".html") else "application/octet-stream"
        with open(full, "rb") as f:
            data = f.read()
        self._reply(("HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n"
                          "Cache-Control: no-store\r\n\r\n" % (ctype, len(data))).encode() + data)

    # ---------- WebSocket ----------
    def _serve_ws(self, headers, path):
        self.request.sendall(ws.handshake_response(headers))
        # ★ P5：`?bin=1` 走**二进制帧**（省 76~88% 带宽）；默认仍是 JSON（好读好调）
        bin_mode = "bin=1" in path
        enc = PB.BinEncoder() if bin_mode else None
        self.request.settimeout(0.05)
        with self.hub.lock:
            self.hub.clients += 1
            cid = self.hub.clients
            self.hub.client_ids[cid] = path
        # ★★ 把连接号挂到 self 上（2026-10-16 加，修一个**真 bug**）：
        #   `_on_frame` 里的 `targets` 出错分支打印的是 `cid`，而 `cid` 只是**本方法的局部变量**
        #   ⇒ 那里抛 `NameError: name 'cid' is not defined` ⇒ **错误处理路径自己崩了**，
        #     真正的错（下面实测到的 `TimeoutError: timed out`）被 NameError 盖住，
        #     日志里看到的是一句莫名其妙的 NameError。
        #   ★ 这与「失败要吵」是同一条纪律的**反面**：想吵，但吵的机制本身坏了 ——
        #     比不吵更糟，因为它会把人引到错的地方。
        #   （这个 bug 是 `_probe_v5.py` 压出来的：客户端猛发把 send 超时逼出来之后才显形。）
        self.cid = cid
        # ★★ P20：每个连接一个**玩家槽位**。槽位 0 给第一个连接（= 开机那个默认玩家），
        #   所以「只有一个客户端」的行为与多人之前**完全一致**。
        # ★ 从路径里取会话 key（`/ws?bin=1&key=xxxx`）；没有就当匿名连接（每次都是新角色）
        key = None
        if "key=" in path:
            for kv in path.split("?", 1)[-1].split("&"):
                if kv.startswith("key="):
                    key = kv[4:].strip()
        self.key = key or None
        slot = self.hub.alloc_slot(cid, self.key)
        self.slot = slot
        if slot < 0:
            # 同一个 key 已经在别处连着 ⇒ **明确拒绝**（不给角色），而不是让两个人抢一个身体
            print("[player] ⚠ 同一个会话 key 已在别处连接，拒绝第二个（累计 %d 次）"
                  % self.hub.busy_kicks)
            try:
                self._send(json.dumps({"you": None, "busy": True},
                                      separators=(",", ":")).encode("utf-8"))
            except OSError:
                pass
        # ★ 玩家**必须在模拟线程里建**（见 Hub.cmds 注释）；建好后由它把 you 投进本槽位的出箱。
        self.hub.cmds.put(("add_player", slot))
        ver = 0
        try:
            # 先发一帧 hello + 一帧快照，让客户端立刻有画面
            if bin_mode:
                snap, ver = self.hub.latest_snap(0)
                if snap is not None:
                    self._send(enc.encode(snap), binary=True)
            else:
                frame, ver = self.hub.latest(0)
                if frame:
                    self._send(frame)
            while True:
                # 1) 收：尽量把已到达的输入都处理掉
                got = False
                try:
                    op, payload = ws.read_frame(self.request)
                    got = True
                    self._on_frame(op, payload)
                except socket.timeout:
                    pass
                except ws.WSError as e:
                    # ★ 坏帧**显式计数**，不静默（本工程纪律）
                    self.hub.dropped_bad_frames += 1
                    print("[ws] 客户端 %d 坏帧: %s" % (cid, e))
                    return
                except Exception as e:                          # noqa: BLE001
                    # ★★ 除 WSError 之外的异常，原来会被外层 `except (ConnectionError, OSError)`
                    #   当成「连接结束」吞掉 —— 于是「收帧/派发里写错一行」表现成
                    #   「客户端莫名断线」，服务端日志干净得像没事（今天就栽在这上面）。
                    #   ⇒ 显式区分，并在 `RT_DBG_WS=1` 时打全栈。
                    if os.environ.get("RT_DBG_WS"):
                        import traceback
                        print("[WSDBG] 客户端 %s 收帧失败：%s: %s" % (cid, type(e).__name__, e))
                        traceback.print_exc()
                    raise
                # 2) 发：有新帧就发
                if bin_mode:
                    snap, nver = self.hub.latest_snap(ver)
                    if snap is not None:
                        self._send(enc.encode(snap), binary=True)
                        ver = nver
                else:
                    frame, nver = self.hub.latest(ver)
                    if frame is not None:
                        self._send(frame)
                        ver = nver
                if not got:
                    time.sleep(0.005)
        except (ConnectionError, OSError):
            pass
        finally:
            # ★ 断开就把这个槽位的玩家删掉（**槽位 0 除外** —— 它是默认玩家，删了世界就空了）
            # ★ 入队已经在 release_slot 里做了（与回收同锁，避免 add/remove 顺序翻转）
            self.hub.release_slot(cid)
            with self.hub.lock:
                self.hub.clients -= 1
                self.hub.client_ids.pop(cid, None)

    def _send(self, data: bytes, binary: bool = False):
        """下发一帧。★ binary=True 时必须用 **opcode=2（二进制帧）**：
        否则浏览器会把二进制载荷当**字符串**收（`binaryType='arraybuffer'` 也就
        永远不会触发），客户端解出来是乱码 —— 而服务端这边看不出任何异常。
        第一版就是忘了传这个标志，帧的魔数明明写着 'RT'，客户端却拿不到 ArrayBuffer。"""
        self.request.sendall(ws.encode_frame(data, ws.OP_BIN if binary else ws.OP_TEXT))
        with self.hub.lock:
            self.hub.frames_sent += 1
            self.hub.bytes_sent += len(data)

    def _on_frame(self, op, payload):
        if op == ws.OP_PING:
            self.request.sendall(ws.encode_frame(payload, ws.OP_PONG))
            return
        if op == ws.OP_CLOSE:
            raise ConnectionError("client closed")
        if op != ws.OP_TEXT:
            return
        try:
            msg = json.loads(payload.decode("utf-8"))
        except Exception:                                        # noqa: BLE001
            self.hub.dropped_bad_frames += 1
            print("[ws] 坏 JSON 帧（已丢弃并计数）")
            return
        # 前向兼容：未知字段**不崩**
        if "cmd" in msg and str(msg["cmd"]) == "whoami":
            # ★★「我是谁」= **拉取**（见 Hub.__init__ 的注释）：客户端连上就问，
            #   这里**就地**从 slot_guid 取答案回过去。玩家可能还没建出来
            #   （模拟线程异步建的）⇒ 如实回 `null`，客户端过一会儿再问。
            slot_no = getattr(self, "slot", 0)
            busy = slot_no is not None and slot_no < 0
            guid = None
            if not busy:
                with self.hub.lock:
                    guid = self.hub.slot_guid.get(slot_no)
            self._send(json.dumps({"you": (int(guid) if guid is not None else None),
                                   "slot": (slot_no if slot_no is not None else -1),
                                   "busy": bool(busy)},
                                  separators=(",", ":")).encode("utf-8"))
            return
        if "cmd" in msg and str(msg["cmd"]) == "me":
            # ★ P39：玩家自身状态（血/饿/理智/背包）—— 与 targets 同一个拉取模式。
            #   为什么走 WS 而不走 HTTP：它跟 `targets` 是**同一次 HUD 刷新**要的两半，
            #   分开两条链路会让「什么能砍」与「我还剩多少血」不同步到肉眼可见。
            sl = getattr(self, "slot", 0)
            with self.hub.lock:
                st = self.hub.me_by_slot.get(sl)
                g_now = self.hub.slot_guid.get(sl)
            # ★★★ 2026-10-18（基线跑出来的**真缺陷**）：缓存是按**槽位**存的，
            #   而槽位会换主人 —— 上一个角色被回收、这个槽位分给了新连接，
            #   在下一轮刷新（≤0.27 s）之前，缓存里躺着的仍是**上一个角色**的血/饿/背包，
            #   而且 `ok` 还是 `true` ⇒ 新客户端会看到**别人的（甚至已死角色的）**状态。
            #   实测现场：`E10` 单跑绿、整轮跑红 —— 因为整轮里前面几条判据
            #   （D2 的宽限期回收）刚好在槽位 1 上制造了「换主人」，
            #   于是 me 报 ok=true（旧角色）、/healthz 的 stats.players 里根本没有槽位 1。
            #   ⇒ 缓存条目自带 `guid`，回包前与 `slot_guid` 对账；对不上就**说还在算**，
            #     不编、也不给旧数据（「词在≠行为在」的同款：有字段 ≠ 那个字段说的是你）。
            if st is not None and g_now is not None and st.get("guid") != g_now:
                st = None
            if st is None:
                # ★ 还没算出来（刚连上 / 刚换角色）时说「稍后再问」，**不编一个 0 血**
                st = {"ok": False, "why": "还没算出来（稍后再问）", "slot": sl}
            try:
                self._send(json.dumps({"me": st}, separators=(",", ":"),
                                      ensure_ascii=False).encode("utf-8"))
            except OSError as e:
                print("[ws] 客户端 %s 回 me 失败（连接要断了）：%s: %s"
                      % (getattr(self, "cid", "?"), type(e).__name__, e))
            except Exception as e:                              # noqa: BLE001
                print("[ws] ✘ 回 me 序列化失败：%s: %s（缓存里是 %s）"
                      % (type(e).__name__, e, type(st).__name__))
                self.hub.dropped_bad_frames += 1
            return
        if "cmd" in msg and str(msg["cmd"]) == "targets":
            # ★ P22：可交互目标 + 最近一次动作结果（**拉取**，与 whoami 同一个理由）
            sl = getattr(self, "slot", 0)
            with self.hub.lock:
                tg = self.hub.targets_by_slot.get(sl) or []
                last = self.hub.act_result.get(sl)
            try:
                self._send(json.dumps({"targets": tg, "last_act": last},
                                      separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
            except OSError as e:
                # ★ 用 `getattr(self, "cid", "?")`：`cid` 在**另一个方法**里是局部变量，
                #   直接用会 NameError（把真正的错盖掉）—— 见 `_serve_ws` 里挂 self.cid 的说明。
                print("[ws] 客户端 %s 回 targets 失败（连接要断了）：%s: %s"
                      % (getattr(self, "cid", "?"), type(e).__name__, e))
            except Exception as e:                              # noqa: BLE001
                # ★ 序列化失败**必须说清**：否则表现成「客户端莫名断线」
                print("[ws] ✘ 回 targets 序列化失败：%s: %s（缓存里是 %s）"
                      % (type(e).__name__, e, type(tg).__name__))
                self.hub.dropped_bad_frames += 1
            return
        if "cmd" in msg and str(msg["cmd"]) == "act":
            sl = getattr(self, "slot", 0)
            if sl is not None and sl >= 0:
                try:
                    self.hub.cmds.put(("act", sl, int(msg.get("v"))))
                except (TypeError, ValueError):
                    self.hub.dropped_bad_frames += 1
            return
        if "cmd" in msg and str(msg["cmd"]) == "unact":
            sl = getattr(self, "slot", 0)
            if sl is not None and sl >= 0:
                self.hub.cmds.put(("unact", sl))
            return
        if "cmd" in msg and str(msg["cmd"]) == "ping":
            # ★★ 应用层 ping（计划 §4 的 2.4 要「延迟」）：浏览器 WebSocket **不暴露**
            #   ping/pong 帧，所以只能在应用层做。
            #   ⚠️ 直接在**本线程**回包是**安全的**：这条连接的读写都在这一个处理线程里
            #   （见 _serve_ws 的循环），所以不会与「广播快照」的交错写在同一 socket 上。
            #   ⇒ 若哪天广播改成别处写，这里必须一起改，否则会出现**半个 JSON 帧**。
            self._send(json.dumps({"pong": msg.get("v"), "st": time.time()},
                                  separators=(",", ":")).encode("utf-8"))
            return
        if "cmd" in msg:
            # ★ 控制指令（与「输入」分开）：`{"cmd":"pause","v":1}`。
            #   为什么不在 `k` 那条路上做：`k` 会被**原样**当成输入键名塞进输入层，
            #   于是 `cmd` 会被记成一个叫 "cmd" 的按键（症状很怪：TheInput 里多个怪键名）。
            cmd = str(msg["cmd"])
            if cmd == "pause":
                self.hub.set_paused(bool(msg.get("v", 1)))
            else:
                self.hub.dropped_bad_frames += 1
                print("[ws] 未知控制指令（已计数）: %r" % cmd)
        elif "k" in msg:
            # ★ P20：输入**必须带上「是谁按的」** —— 否则四个客户端共用一个玩家
            # ★ P21：被拒（busy，slot<0）的连接**不产生输入** —— 它没有角色可以动
            sl = getattr(self, "slot", 0)
            if sl is not None and sl >= 0:
                self.hub.inputs.put((sl, str(msg["k"]), bool(msg.get("v", 1))))
        elif "keys" in msg:
            for k, v in (msg["keys"] or {}).items():
                self.hub.inputs.put((getattr(self, "slot", 0), str(k), bool(v)))
        else:
            self.hub.dropped_bad_frames += 1


class ThreadedServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        """★ 处理线程**死掉**必须看得见。

        默认实现只把 traceback 打到 stderr —— 若 stdout/stderr 被重定向或没人看，
        症状就是「连接莫名被重置 / 线程凭空消失」，而日志里**一个字都没有**。
        （今天就是这么查了一小时的：C6 报「连接被重置」，服务端日志干净得像没事。）
        """
        import traceback
        print("[server] ✘ 处理线程异常（来自 %s）：" % (client_address,))
        traceback.print_exc()


def port_in_use(host, port):
    """★ 端口占用检查 —— 为什么必须有它：

    Windows 上 `SO_REUSEADDR` 允许**两个进程同时 bind 同一端口**
    （Linux 默认不允许），于是会出现：旧服务端没死透、新服务端照样起来，
    **两条监听并存**，连接随机落到哪一个。
    实测症状：同一个 `?bin=1` 连接，有时收到二进制帧、有时收到 JSON ——
    看起来像「二进制没生效」，实际是**连到了另一个世界**（另一个进程）。
    这类「静默脑裂」极难从表象定位，所以启动时必须**先查、再拒**。"""
    import socket as _s
    probe = _s.socket(_s.AF_INET, _s.SOCK_STREAM)
    try:
        probe.settimeout(1.0)
        if probe.connect_ex((host, port)) == 0:
            return True
        return False
    finally:
        probe.close()


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


def main():
    require_sources()
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--hz", type=int, default=30)
    ap.add_argument("--seed", type=int, default=20261015)
    ap.add_argument("--max-ents", type=int, default=400)
    ap.add_argument("--allow-debug", action="store_true",
                    help="打开调试端点（/debug/kill）—— **别在公网部署上开**，见发布检查单")
    ap.add_argument("--world-content", type=int, default=14,
                    help="默认在玩家周围放多少个可交互植物（0=空世界；见 rt_boot.populate_world）")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--save-file", default=None,
                    help="存档文件路径；给了就**启动时读档 + 每 30 s 自动存档**")
    ap.add_argument("--no-load", action="store_true",
                    help="忽略已有存档，强制从种子开新世界（存档仍会被覆盖）")
    ap.add_argument("--record", default=None,
                    help="录像输出路径：把「种子 + 输入事件 + 每 tick 指纹」写成 JSON（每 30 s 落盘一次）")
    ap.add_argument("--replay", default=None,
                    help="回放一份录像并与当时的逐 tick 指纹比对；**一致退出码 0 / 不一致 1**。给了它就只回放，不起服务端")
    a = ap.parse_args()

    if port_in_use(a.host, a.port):
        print("✘ 端口 %d 已被占用 —— **拒绝启动**。" % a.port)
        print("  为什么拒绝而不是照起：Windows 的 SO_REUSEADDR 允许两个进程同时监听同一端口，")
        print("  两条监听并存会让连接**随机**落到其中一个（静默脑裂）。")
        print("  请先停掉旧进程（netstat -ano | findstr :%d 查 PID，再 taskkill /F /PID <pid>）。"
              % a.port)
        return 2

    # ★★ 存档路径必须在 `boot()` **之前**定成绝对路径：
    #   boot() 里会 `os.chdir(ENGINE)`，之后再 abspath 就会按**宿主目录**解析 ——
    #   实测踩到：`../deploy/logs/x.json` 落到了 `E://DST-Analysis//deploy//logs//`
    #   （比调用者想的目录高了两级），而调用者根本不知道。
    if a.save_file:
        a.save_file = os.path.abspath(a.save_file)
        os.makedirs(os.path.dirname(a.save_file), exist_ok=True)
    # 录像路径同理必须在 boot() 之前定成绝对路径（boot 里会 chdir）
    if a.record:
        a.record = os.path.abspath(a.record)
        os.makedirs(os.path.dirname(a.record), exist_ok=True)
    if a.replay:
        a.replay = os.path.abspath(a.replay)

    print("[boot] 启动实时引擎：seed=%d hz=%d 宿主=%s" % (a.seed, a.hz, ENGINE))
    sim = Sim(seed=a.seed, tick_hz=a.hz, max_ents=a.max_ents,
              world_content=a.world_content).boot()
    print("[boot] 完成，用时 %.0f ms | %s" % (sim.boot_ms, sim.stats()))

    if a.save_file:
        print("[boot] 存档文件（绝对路径）：%s" % a.save_file)

    # ★ 启动读档（P3 遗留项）：把「重启就回到种子初始态」这个已知限制关掉
    if a.save_file and not a.no_load:
        ok, msg = sim.try_load(a.save_file)
        print("[boot] 读档：%s" % msg)

    # ★★ M7：回放模式 —— 给了 `--replay` 就**只回放**，不起服务端（也不占端口）。
    if a.replay:
        try:
            with io.open(a.replay, encoding="utf-8") as f:
                rec = json.load(f)
        except Exception as e:                                   # noqa: BLE001
            print("✘ 读不了录像 %s：%s: %s" % (a.replay, type(e).__name__, e))
            return 2
        if rec.get("seed") != a.seed:
            print("✘ 录像的种子是 %s，本次 --seed=%s —— **拒绝回放**。" % (rec.get("seed"), a.seed))
            print("  种子不同就是另一个世界，比出来的「不一致」没有任何意义。")
            print("  要用录像的种子请显式加 --seed %s。" % rec.get("seed"))
            return 2
        n_rec = rec.get("ticks") or 0
        print("[replay] %s：seed=%s hz=%s ticks=%s events=%d"
              % (a.replay, rec.get("seed"), rec.get("tick_hz"), n_rec, len(rec.get("events") or [])))
        if rec.get("truncated"):
            print("[replay] ⚠ 这份录像被截断过（truncated=true）—— 只比已记录的那一段")
        t0 = time.perf_counter()
        tick, want, got, near = sim.replay(rec)
        ms = (time.perf_counter() - t0) * 1000.0
        if tick is None:
            print("[replay] ✔ 一致：%d tick 逐 tick 指纹全同（用时 %.0f ms）" % (n_rec, ms))
            return 0
        print("[replay] ✘ **不一致**：第 %d tick 起（期望 %s，实得 %s）" % (tick, want, got))
        if near:
            print("          %s" % near)
        return 1

    hub = Hub()
    stop = threading.Event()
    # ★ 预热统计缓存：模拟线程要到第 8 拍才刷新它，
    #   而 `/healthz` 可能在**第一拍之前**就被访问（发布演练里就有这一步）。
    #   不预热 ⇒ 那一小段时间里 `stats` 是空对象 —— 看着像「世界还没起来」。
    try:
        hub.stats_cache = sim.stats()
    except Exception as _e:                                      # noqa: BLE001
        print("[boot] 统计缓存预热失败（不拦启动）：%s" % _e)
    th = threading.Thread(target=sim_loop,
                          args=(sim, hub, stop, a.quiet, a.save_file, 30, a.record), daemon=True)
    th.start()
    # ★ C1：看门狗与模拟线程**并列**（不能放进 sim_loop —— 它跟着停就没人看了）
    wd = threading.Thread(target=watchdog_loop, args=(hub, stop), daemon=True)
    wd.start()

    Handler.hub = hub
    # ★ 不是 `sim.stats`（那是**进 Lua**的，只能在模拟线程里调）——
    #   处理线程读的是模拟线程写好的缓存。见 Hub.stats_cache 的注释。
    Handler.sim_stats = _stats_from_cache
    Handler.sim_terrain = sim.terrain      # ★ boot 里已预热 ⇒ 这里只是读缓存，不碰 Lua
    Handler.allow_debug = bool(a.allow_debug)   # ★ 见 /debug/kill 的说明（默认关）

    # ★★★ P36：把**存档里的**会话身份灌回 hub —— 这样重启之后，客户端拿同一个 key
    #   回来仍会被分配到**原来的槽位**，而那个槽位的角色（带着它走过的路）已经被
    #   `rt_boot` 的读档逻辑重新绑好了。以前 `by_key` 每次重启都从零开始 ⇒ 认不回自己。
    #   ⚠️ 失败**不许**拦住启动：身份是增强项，不是启动前置（但要说出来，不静默）。
    try:
        _n_keys = hub.prime_keys(sim.api.slot_keys())
    except Exception as _e:                                      # noqa: BLE001
        _n_keys = 0
        print("[player] ✘ 恢复会话身份失败（不影响启动）：%s: %s" % (type(_e).__name__, _e))
    if _n_keys:
        print("[player] 从存档恢复 %d 条会话身份（同 key 重连可拿回原槽位/角色）" % _n_keys)
    Handler.static_dir = HERE
    srv = ThreadedServer((a.host, a.port), Handler)
    print("[http] http://%s:%d/            （客户端）" % (a.host, a.port))
    print("[http] http://%s:%d/healthz     （健康检查）" % (a.host, a.port))
    print("[ws]   ws://%s:%d/ws           （帧/输入）" % (a.host, a.port))
    # ★ 装信号处理：SIGINT/SIGTERM 时**让循环自己退出**，从而走到下面的 finally
    #   （Windows 上 `taskkill /F` 是硬杀、拦不住 —— 所以还有 RECORD_FLUSH_SEC 那道保险）。
    def _on_signal(signum, _frm):
        print("\n[stop] 收到信号 %s，正在停止…" % signum)
        stop.set()
        # ★ `srv.shutdown()` 必须**在另一个线程里调**：它要等 serve_forever 返回，
        #   而在主线程的信号处理器里调它就是等自己 —— 直接死锁。
        threading.Thread(target=srv.shutdown, daemon=True).start()

    try:
        signal.signal(signal.SIGINT, _on_signal)
        signal.signal(signal.SIGTERM, _on_signal)
    except Exception:                                            # noqa: BLE001
        pass

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[stop] 收到 Ctrl-C，正在停止…")
    finally:
        stop.set()
        srv.shutdown()
        # ★ 收尾再落一次盘：进程被杀（deploy/stop.sh）时，最后这几十秒的录像就靠它了
        if a.record:
            try:
                tk, ne, sz = sim.save_recording(a.record)
                print("[rec] 已写出录像：%d tick / %d 事件 / %d 字节 → %s" % (tk, ne, sz, a.record))
            except Exception as e:                               # noqa: BLE001
                print("[rec] ✘ 写录像失败：%s: %s" % (type(e).__name__, e))
    return 0


if __name__ == "__main__":
    # ★ 诊断开关：`RT_DUMP_STACKS=秒数` ⇒ 定期把所有线程的栈打进 stderr。
    #   用途：定位「循环卡住了」—— 光看症状（tick 不涨）分不清是在等锁、等 IO 还是在 Lua 里。
    _ds = os.environ.get("RT_DUMP_STACKS")
    if _ds:
        import faulthandler
        faulthandler.dump_traceback_later(float(_ds), repeat=True)
    sys.exit(main())
