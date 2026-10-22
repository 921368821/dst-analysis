# -*- coding: utf-8 -*-
"""sim.py —— 权威模拟（M4 从 server.py 拆出）

职责（对应开发计划 §2 的 M1）
    持有唯一个 lupa LuaRuntime，固定步长推进（默认 30 Hz）。

为什么「唯一一个 LuaRuntime + 单线程持它」
    lupa 的 LuaRuntime 不是线程安全的。所以：
      · 模拟线程独占运行时；
      · 客户端线程只做两件事 —— 往输入队列塞事件、读最新的已编码帧；
      · 帧只编码一次，所有客户端复用（省 CPU，也保证大家看到的是同一帧）。

★ 拆分只搬代码，不改逻辑；与 M4 之前的 server.py 可逐段对照。
"""
import io
import json
import os
import time

from config import HERE, ROOT, ENGINE, require_sources
import commands                       # M1-1：撤销栈（纯 Python，不碰 Lua）
from hub import lua_to_py


# =============================================================================
# M1 权威模拟
# =============================================================================

# =============================================================================
# M1 权威模拟
# =============================================================================
class SimNotBooted(RuntimeError):
    """在 `boot()` 之前调用了需要 Lua 的接口。

    ★★ 为什么单独一个异常类型（2026-10-20）：
      原来这种情况的报错是 `'NoneType' object has no attribute 'save_apply'` ——
      一条**指不出原因**的错误（读者会怀疑存档、怀疑 lupa、怀疑 Python 版本，
      就是不会想到「忘 boot 了」）。
      更要紧的是**它和「存档坏了」必须分开**：`try_load` 会把失败当成
      「读不动」⇒ 把存档改名隔离。若原因其实是程序忘了 boot，
      那就是**程序缺陷连坐用户数据** —— 病历被当垃圾扔掉。
      ⇒ 用一个**独立类型**，让 try_load 能把它重新抛出去、不碰文件。
    """


def _cleanup_filelist(path):
    """删掉 boot 时生成的目录清单目录。

    ★ 幂等：已经不在就当成功（`atexit` 与 `--clean-temp` 可能都删到同一个）；
    ★ 删不掉**必须打印**，而且要说清谁来收 —— 不许静默。
    """
    import shutil
    try:
        shutil.rmtree(path)
        return True
    except FileNotFoundError:
        return True
    except OSError as e:                                         # noqa: BLE001
        print("  ⚠ 目录清单没删掉（%s）：%s —— "
              "硬中断留下的会由 tools/check_leftovers.py --clean-temp 收走" % (path, e))
        return False


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
        # ★★ 玩家的**加入/离开时刻**（`[tick, 槽位, +1|-1]`，v3 录像才写）。
        #   见 replay() 的注释：不记它就必然出现「回放第一拍就不一致」——
        #   因为槽位 1 的玩家实体在录制时是**第 k 拍**才出现的，回放却在开演前就建好了。
        self.joins = []
        self.replay_note = None      # 回放的一次性说明（老录像缺 joins 时说明「哪部分不作数」）

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

        # ★★★ M6：给 Lua 侧准备一份**目录清单**（`$DST_FILELIST/<sub>.txt`）。
        #   为什么要这么绕：宿主侧有两处需要「列出某个目录下的 *.lua」
        #   （behaviours 预加载、prefab 索引），原来用 `io.popen('dir /b ...')` ——
        #   cmd.exe 专有，容器/WSL 里必然拿到空列表 ⇒ 静默少加载 ⇒
        #   「某个 brain 的行为类是 nil」这种离病因很远的症状。
        #   Python 的 os.listdir 在哪都能用，于是由这里生成，Lua 侧优先读它；
        #   读不到才退回 `ls -1` / `dir /b`（见 host/05_bootstrap.lua 的 list_lua_files）。
        try:
            import atexit
            import tempfile
            fl = os.path.join(tempfile.gettempdir(), "rt_filelist_%d" % os.getpid())
            os.makedirs(fl, exist_ok=True)
            # ★★★ P50⑰：这个目录**以前从不删**。
            #   实测 2026-10-20：一天下来 `%TEMP%\rt_filelist_*` 堆了 **1251 个（45 MB）** ——
            #   每 boot 一次一个新 pid 目录，而 boot 在 `test_rt.py` 里要跑几十次。
            #   于是注册退出钩子删自己的目录。
            #   ⚠ 诚实说明它的边界：`atexit` 在**硬中断**（`taskkill /F` / 超时被杀）时
            #     **不会执行**，所以它只能防「正常退出」；硬中断留下的由
            #     `tools/check_leftovers.py --clean-temp` 兜底（按「pid 已不存在」判）。
            atexit.register(_cleanup_filelist, fl)
            src = os.environ.get("DST_SRC") or os.path.join(os.path.dirname(ROOT), "dstsrc", "scripts")
            if not os.path.isdir(src):
                # 联接可能被换成原名目录（`02-注释源码`）；两条都试，别猜一个。
                src = os.path.join(os.path.dirname(ROOT), "02-注释源码", "scripts")
            n_written = 0
            for sub in ("behaviours", "prefabs"):
                d = os.path.join(src, sub)
                if os.path.isdir(d):
                    with open(os.path.join(fl, sub + ".txt"), "w", encoding="utf-8") as fh:
                        for nm in sorted(os.listdir(d)):
                            if nm.endswith(".lua"):
                                fh.write(nm + "\n")
                                n_written += 1
            os.environ["DST_FILELIST"] = fl
            print("[boot] 目录清单：%d 个文件名 → %s（Lua 侧不再依赖 cmd.exe）" % (n_written, fl))
        except Exception as e:                                   # noqa: BLE001
            # 失败不致命：Lua 侧会退回平台命令。但**要说出来**（否则就是静默降级）。
            print("[boot] ⚠ 目录清单生成失败：%s: %s（Lua 侧退回 ls/dir）" % (type(e).__name__, e))

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

    def note_join(self, slot, up=True):
        """记一条「槽位加入 / 离开」—— 录像里必须有它，回放才可能逐 tick 对上。

        ★ tick 取 `len(self.hashes)` = **已经走完的拍数**：加入发生在这一拍开始之前，
          所以回放时在同一拍的输入之前重放它，实体出现时机与录制时**完全一致**。
        ★ 老录像（v2 及更早）没有这一段，只能「开演前把所有槽位补出来」，
          那份录像的世界**从第一拍起就和录制时不一样**（多出了还没上线的玩家）。
          这个不公平比出来后**必须说出来**（见 replay 里的 `self.replay_note`），
          否则用户会以为「世界行为变了」。
        """
        if len(self.hashes) >= self.record_limit:
            return                  # 已经停止记录（record_truncated 会说出来）
        self.joins.append([len(self.hashes), int(slot), 1 if up else -1])

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
        out = {"guid": int(info["guid"]), "prefab": str(info["prefab"]),
               "x": round(float(info["x"]), 2), "z": round(float(info["z"]), 2)}
        # ★★ P61：血量 / 存活 / 当前可做的动作。
        #   为什么必须有：`Combat:DoAttack` **没有返回值**，判断「这一下到底打中没有」
        #   唯一不依赖实现细节的办法就是看目标血量差。缺这一项时，
        #   探针只能看到「atk_ok 在涨」，看不到「血在掉」——两者会分叉。
        #   ⚠️ 取不到时保持 None，**不填 0**：缺字段和「血空了」是两件事。
        for k in ("hp", "maxhp"):
            try:
                v = info[k]
                out[k] = None if v is None else round(float(v), 2)
            except Exception:                                    # noqa: BLE001
                out[k] = None
        try:
            out["dead"] = None if info["dead"] is None else bool(info["dead"])
        except Exception:                                        # noqa: BLE001
            out["dead"] = None
        try:
            out["action"] = None if info["action"] is None else str(info["action"])
        except Exception:                                        # noqa: BLE001
            out["action"] = None
        # ★★ B3：workleft / maxwork / hands。
        #   「装了斧头砍得更快」的唯一可观测证据就是 workleft 的**下降步长**。
        #   只看「树倒没倒」是分不出来的 —— 6 下倒和 3 下倒，结果都是"倒了"。
        #   同样地：`hands` 让「装备生效了吗」有一个事实来源，而不是靠调用方自述。
        for k in ("workleft", "maxwork"):
            try:
                v = info[k]
                out[k] = None if v is None else round(float(v), 3)
            except Exception:                                    # noqa: BLE001
                out[k] = None
        try:
            out["hands"] = None if info["hands"] is None else str(info["hands"])
        except Exception:                                        # noqa: BLE001
            out["hands"] = None
        for k in ("wtough",):
            try:
                out[k] = None if info[k] is None else bool(info[k])
            except Exception:                                    # noqa: BLE001
                out[k] = None
        try:
            out["waction"] = None if info["waction"] is None else str(info["waction"])
        except Exception:                                        # noqa: BLE001
            out["waction"] = None
        return True, out

    def debug_entities(self, limit=500):
        """列出全部实体 → (ok, {"count", "listed", "items": [...]})。

        ★ 为什么 Lua 侧给的是字符串、这里再解析：
          lupa 里 Lua table → Python 要逐条迭代，1000 个实体就是几千次跨语言调用。
          一次取回 `guid\tprefab\tx\tz\thp` 多行文本、在 Python 侧 split，成本低一个量级。
        """
        try:
            ok, info = self.api.debug_entities(int(limit))
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        if not ok:
            return False, {"error": str(info)}
        items = []
        for line in str(info["rows"] or "").split("\n"):
            if not line:
                continue
            f = line.split("\t")
            if len(f) < 2:
                continue
            try:
                it = {"guid": int(f[0]), "prefab": f[1] or "?"}
            except (TypeError, ValueError):
                continue
            # ⚠️ 空串 = 取不到，落成 None，**不填 0** —— 0 是个合法位置。
            for idx, key in ((2, "x"), (3, "z"), (4, "hp")):
                try:
                    it[key] = None if f[idx] == "" else round(float(f[idx]), 2)
                except (IndexError, TypeError, ValueError):
                    it[key] = None
            items.append(it)
        return True, {"count": int(info["count"]), "listed": int(info["listed"]),
                      "items": items}

    def debug_remove(self, guid):
        """删掉一个实体 → (ok, dict)。玩家实体会被 Lua 侧拒绝（返回 ok=False）。"""
        try:
            ok, info = self.api.debug_remove(int(guid))
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        if not ok:
            return False, {"error": str(info)}
        return True, {"guid": int(info["guid"]), "prefab": str(info["prefab"]),
                      "removed": True}

    # ---------------------------------------------------------------- M1-1 撤销栈
    # ★★★ 栈放在 Python 这一侧，不放进 Lua。三条理由：
    #   ① `commands.py` 已经用 6 条单测（U47~U52）锁住了语义，Lua 侧再写一遍就是两份实现
    #      （本工程母题：同一件事两处实现 ⇒ 改一处，另一处悄悄过期）；
    #   ② 编辑器改的是**服务端世界**，而 `/editor/*` 的请求已经在模拟线程里排队执行
    #      ⇒ push/undo 天然串行，不需要额外加锁；
    #   ③ 栈的 `apply` 只需要会调 `debug_move` 这类已有入口，是一层薄适配。
    #
    # ⚠️ 第一版**只让 move 走栈**，spawn/remove 仍直接改世界，接口里明确返回
    #   `reversible: false`。原因：撤销「删除」需要实体完整快照（组件、任务、计时器），
    #   而 `debug_remove` 走的是 `inst:Remove()` —— 不可逆。宁可如实说不支持，
    #   也不要给一个"撤销了但状态不对"的半成品（那比没有撤销更难查）。
    def _ensure_stack(self):
        if getattr(self, "_cmdstack", None) is None or self._cmdstack_for != id(self):
            self._cmdstack = commands.CmdStack(self._apply_cmd, max_steps=50, merge_window=1)
            self._cmdstack_for = id(self)
            # 命令里的 target(guid) → 当前实际 guid（重建会换号，见 _apply_cmd）
            self._ent_guid = {}
        return self._cmdstack

    def _apply_cmd(self, kind, target, state):
        """栈的执行器：把一份状态写进世界。失败**必须抛**（让事务回滚）。"""
        if kind == "move":
            ok, info = self.api.debug_move(int(target), float(state["x"]), float(state["z"]))
            if not ok:
                raise RuntimeError("move 失败：%s" % (info,))
            # 回读校验：SetPosition 不返回值，不验就会出现"撤销了但没生效"
            if abs(float(info["x"]) - float(state["x"])) > 0.01 \
               or abs(float(info["z"]) - float(state["z"])) > 0.01:
                raise RuntimeError("move 之后位置对不上：期望 (%s,%s) 实际 (%s,%s)"
                                   % (state["x"], state["z"], info["x"], info["z"]))
            return
        if kind == "ent":
            # ★★ M1-1b（2026-10-22）：**实体级的增删**。spawn 与 remove 共用一条路径：
            #   · spawn：before=None, after={"line": 场景行} ⇒ undo 时 apply(None) 删掉
            #   · remove：before={"line": 场景行}, after=None ⇒ undo 时 apply(before) 重建
            #   一条代码路径处理两件事，因为它们在栈里本来就是同一件事的镜像。
            #
            # ⚠️ **guid 会变**：重建出来的是新实体、新号。所以这里用一张映射表把
            #   "命令里的 target" 绑到"当前实际 guid"上 —— 不绑的话，
            #   remove→undo→redo 这条链上第二次 remove 会去删一个早就不存在的号，
            #   而 `debug_remove` 对不存在的号返回失败 ⇒ 栈会以为执行失败。
            if state is None:
                cur = self._ent_guid.get(int(target), int(target))
                ok, info = self.api.debug_remove(int(cur))
                if not ok:
                    raise RuntimeError("remove 失败：%s" % (info,))
                self._ent_guid.pop(int(target), None)
                return
            ok, info = self.scene_import(state["line"])
            if not ok:
                raise RuntimeError("重建实体失败：%s" % (info.get("error"),))
            # 回读：真的造出来了吗？（不验就等于自述）
            new_guid = None
            ok2, d = self.debug_entities(4000)
            if ok2:
                want = state["line"].split("\t")[0]
                cands = [e for e in d["items"] if e.get("prefab") == want]
                if cands:
                    new_guid = max(e["guid"] for e in cands)
            if new_guid is None:
                raise RuntimeError("重建之后找不到新实体（prefab=%r）" % (state["line"].split("\t")[0],))
            self._ent_guid[int(target)] = int(new_guid)
            return
        raise ValueError("命令栈不支持的操作类型：%r" % (kind,))

    def move_via_stack(self, guid, x, z):
        """带撤销的移动。返回 (ok, dict|错误)。

        ★ 为什么不直接调 debug_move：那样改了回不去。这里先把「移动前的位置」读出来
          作为 undo 快照，再 push —— push 会立刻执行 do。
        ★ 合并：同一个实体的连续 move 用 MERGE_ENDS，拖拽 60 帧只留一步。
        """
        ok, before = self.debug_entity(guid)
        if not ok:
            return False, {"error": "移动前读不到实体：%s" % (before.get("error"),)}
        b = {"x": float(before["x"]), "z": float(before["z"])}
        a = {"x": float(x), "z": float(z)}
        if abs(a["x"] - b["x"]) < 0.001 and abs(a["z"] - b["z"]) < 0.001:
            return True, {"guid": int(guid), "x": a["x"], "z": a["z"], "moved": False}
        st = self._ensure_stack()
        try:
            st.push("move", int(guid), b, a, merge=commands.MERGE_ENDS, label="移动")
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        return True, {"guid": int(guid), "x": a["x"], "z": a["z"],
                      "moved": True,
                      "undo_depth": st.depth, "version": st.version}

    def spawn_via_stack(self, prefab, x, z):
        """带撤销的生成。返回 (ok, dict)。

        ★ target 用**负数占位**：push 会立刻执行 apply，而 apply 之后才知道新 guid。
          （顺序反过来做不到 —— 栈的语义就是"push 即执行"。）
          占位号与真实 guid 不可能撞：宿主 guid 都是正的。
        """
        self._spawn_seq = getattr(self, "_spawn_seq", 0) + 1
        token = -int(self._spawn_seq)
        line = "%s\t%.3f\t%.3f" % (prefab, float(x), float(z))
        st = self._ensure_stack()
        try:
            st.push("ent", token, None, {"line": line}, merge=commands.MERGE_DISABLE,
                    label="生成 " + prefab)
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        return True, {"guid": self._ent_guid.get(token), "prefab": prefab,
                      "x": float(x), "z": float(z), "undo_depth": st.depth,
                      "version": st.version}

    def remove_via_stack(self, guid):
        """带撤销的删除。返回 (ok, dict)。

        ★ 撤销得到的是**新实体**（新 guid），只恢复 prefab/位置/白名单覆盖值。
          接口里显式给出 `restores` 与 `guid_will_change`，
          不让人以为"撤销 = 时间倒流"。
        """
        try:
            line = self.api.entity_describe(int(guid))
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        if not isinstance(line, tuple):
            line = (line,)
        if len(line) < 1 or line[0] is None:
            return False, {"error": str(line[1]) if len(line) > 1 else "描述失败"}
        text = str(line[0])
        st = self._ensure_stack()
        try:
            st.push("ent", int(guid), {"line": text}, None,
                    merge=commands.MERGE_DISABLE, label="删除")
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        return True, {"guid": int(guid), "described": text,
                      "restores": "prefab + 位置 + workleft/health（白名单）",
                      "guid_will_change": True,
                      "undo_depth": st.depth, "version": st.version}

    def undo(self):
        """撤销一步。返回 (ok, dict)。栈空返回 ok=False 且 error 里写"没有可撤销的"——
        调用方要把它当成 409，不是"成功但没变化"。"""
        st = self._ensure_stack()
        if not st.can_undo():
            return False, {"error": "没有可撤销的操作", "empty": True,
                           "undo_depth": 0, "version": st.version}
        try:
            cmd = st.undo()
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "撤销失败：%s: %s" % (type(e).__name__, e)}
        return True, {"kind": cmd.kind, "target": cmd.target, "label": cmd.label,
                      "to": cmd.before, "undo_depth": st.depth,
                      "can_redo": st.can_redo(), "version": st.version}

    def redo(self):
        st = self._ensure_stack()
        if not st.can_redo():
            return False, {"error": "没有可重做的操作", "empty": True,
                           "undo_depth": st.depth, "version": st.version}
        try:
            cmd = st.redo()
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "重做失败：%s: %s" % (type(e).__name__, e)}
        return True, {"kind": cmd.kind, "target": cmd.target, "label": cmd.label,
                      "to": cmd.after, "undo_depth": st.depth,
                      "can_redo": st.can_redo(), "version": st.version}

    # ---------------------------------------------------------------- C4 场景
    def scene_export(self):
        """导出当前世界为场景 → (ok, {"n", "version", "text"})。

        ★ 与 `save_collect()` 的区别：那个是**游戏存档**（含玩家/背包/时间），
          这个是**关卡**（只含摆了什么）。编辑器要存的是后者 ——
          用存档当场景会把"上次玩到哪"一起带过去。
        """
        try:
            res = self.api.scene_export()
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        if not isinstance(res, tuple):
            res = (res,)
        n = int(res[0]) if len(res) > 0 else 0
        ver = int(res[1]) if len(res) > 1 and res[1] is not None else 0
        text = str(res[2]) if len(res) > 2 and res[2] is not None else ""
        return True, {"n": n, "version": ver, "text": text}

    def scene_clear(self):
        try:
            return True, {"removed": int(self.api.scene_clear())}
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}

    def scene_import(self, text):
        """导入场景 → (ok, {"made"}) 或 (False, {"error"})。
        ★ 校验在 Lua 侧整份做完才动手 —— 一个坏在第 30 行的场景不该摆了一半。"""
        try:
            res = self.api.scene_import(str(text))
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        if not isinstance(res, tuple):
            res = (res,)
        ok = bool(res[0]) if len(res) > 0 else False
        info = res[1] if len(res) > 1 else None
        if not ok:
            return False, {"error": str(info)}
        return True, {"made": int(info)}

    def collide_pushes(self):
        """碰撞解算挡下了几次（N1）。0 = 从来没挡过（要么没障碍，要么碰撞没接上）。"""
        try:
            return int(self.api.collide_pushes())
        except Exception:                                        # noqa: BLE001
            return 0

    def death_drops(self):
        """死亡时一共掉了几件（N4）。**不是**"应该掉几件"——是事实读数。"""
        try:
            return int(self.api.death_drops())
        except Exception:                                        # noqa: BLE001
            return 0

    def death_dropped_of(self, slot=0):
        try:
            return int(self.api.death_dropped_of(int(slot)))
        except Exception:                                        # noqa: BLE001
            return 0

    def undo_stats(self):
        st = self._ensure_stack()
        return st.stats()

    def debug_move(self, guid, x, z):
        """把实体挪到 (x, z) → (ok, dict)。回读的位置是**事实**（SetPosition 不返回值）。"""
        try:
            ok, info = self.api.debug_move(int(guid), float(x), float(z))
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        if not ok:
            return False, {"error": str(info)}
        return True, {"guid": int(info["guid"]),
                      "x": round(float(info["x"]), 2), "z": round(float(info["z"]), 2)}

    def recipes(self, slot, limit=40):
        """列出配方 → (ok, dict)。dict: total/craftable/n/items/ms。

        ★ B2（2026-10-22）：`items` 在这里由**一个 Lua 字符串**解析出来，不是逐条跨语言取。
          Lua 侧原版配方 1122 个，逐条转 dict 会是几千次 lupa 调用（P41 的老坑）。
          代价是格式要约定死：`name\\tproduct\\t材料\\t可造`。

        ★ 返回 `ms` 是**故意**的：这个接口要遍历全部配方并逐个查背包，
          必须让调用方看得见它有多贵。面板打开时拉一次可以，挂进帧循环会把
          250 ms 的轮询压垮 —— 没有这个数就没人会去注意。
        """
        t0 = time.perf_counter()
        try:
            res = self.api.recipes(int(slot), int(limit))
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        if not isinstance(res, tuple):
            res = (res,)

        def _i(idx):
            try:
                return int(res[idx])
            except Exception:                                    # noqa: BLE001
                return 0

        total = _i(0)          # AllRecipes 全表数（1122）—— 与"有效"是两件事，分开报
        craftable = _i(1)      # 当前背包能造的
        valid_n = _i(2)        # 过了 GetValidRecipe 且**有材料**的（生存面板里真会显示的）
        skipped = _i(3)        # 被跳过的空材料配方（活动装饰/建造模式专用）—— 让它可见
        text = str(res[4]) if len(res) > 4 and res[4] is not None else ""
        err = res[5] if len(res) > 5 else None
        if err:
            return False, {"error": str(err)}

        items = []
        for line in text.split("\n"):
            if not line:
                continue
            f = line.split("\t")
            if len(f) < 4:
                continue
            items.append({
                "name": f[0],
                "product": f[1],
                "ingredients": f[2],
                "can": f[3] == "1",
            })
        return True, {"total": total, "valid": valid_n, "skipped": skipped,
                      "craftable": craftable,
                      "n": len(items),
                      "items": items,
                      "ms": round((time.perf_counter() - t0) * 1000, 2)}

    def equip(self, slot, guid):
        """把某件物品装到手上 → (ok, dict)。

        ★ B3：**回读**由 Lua 侧完成（`M.equip` 结尾查 `GetEquippedItem(HANDS)`），
          这里只搬 `equipped` 与 `hands_prefab`。装备这件事没有返回值可用
          （`inventory:Equip` 失败也不报错），所以"成功"只能是"手上真的是它"。
        """
        try:
            res = self.api.equip(int(slot), int(guid))
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        if not isinstance(res, tuple):
            res = (res,)
        ok = bool(res[0]) if len(res) > 0 else False
        info = res[1] if len(res) > 1 else None
        detail = res[2] if len(res) > 2 else None
        if not ok:
            return False, {"error": str(info)}
        out = {"equipped": True}
        for k in ("guid", "prefab", "hands_prefab"):
            try:
                out[k] = detail[k]
            except Exception:                                    # noqa: BLE001
                out[k] = None
        try:
            out["equipped"] = bool(detail["equipped"])
        except Exception:                                        # noqa: BLE001
            out["equipped"] = False
        return True, out

    def craft(self, slot, recname, x=None, z=None):
        """合成一个配方 → (ok, dict)。

        ★ B1（2026-10-22）：走原版 `Builder:DoBuild`，所以**成功与否由原版判定**，
          这里只做跨语言搬运。失败原因原样透出（原版的 "MOUNTED"/"HASPET"/"ITEMMIMIC"
          是**对外契约**，不在这一层翻译成别的话 —— 翻译一次就多一处会过期的措辞）。

        ★ 为什么返回 `ents_before/ents_after`：`DoBuild` **没有返回值说明产物在哪**
          （放置类配方产物在地上、制造类配方在背包、委托生成的连产物都没有）。
          能同时成立的观测只有「世界实体数变多了没有」+「背包里多了什么没有」。
          少了这一项，判据只能断言 `ok==True`，而 `ok==True` 在没有材料时也可能是真的
          —— 那就是一条自述结论式的假绿灯。
        """
        try:
            res = self.api.craft(int(slot), recname, x, z)
        except Exception as e:                                   # noqa: BLE001
            return False, {"error": "%s: %s" % (type(e).__name__, e)}
        # ★ 不用 `ok, info, detail = ...` 直接解包：Lua 侧少返回一个值就是 ValueError，
        #   而这条路径（材料不足）恰好是最常走的。首次实测就踩到过一次，
        #   报出来的是 "not enough values to unpack"，与真正的原因（材料不够）毫无关系。
        if not isinstance(res, tuple):
            res = (res,)
        ok = bool(res[0]) if len(res) > 0 else False
        info = res[1] if len(res) > 1 else None
        detail = res[2] if len(res) > 2 else None
        if not ok:
            return False, {"error": str(info)}
        out = {"recipe": str(recname)}
        d = detail
        for k in ("ents_before", "ents_after"):
            try:
                out[k] = int(d[k])
            except Exception:                                    # noqa: BLE001
                out[k] = None
        for k in ("x", "z"):
            try:
                out[k] = round(float(d[k]), 2)
            except Exception:                                    # noqa: BLE001
                out[k] = None
        return True, out

    def craft_stats(self):
        """(ok, refused, last_why) —— 与 `act_stats` 同风格：三个数分开报。"""
        try:
            ok, refused, why = self.api.craft_stats()
            return int(ok), int(refused), (None if why is None else str(why))
        except Exception:                                        # noqa: BLE001
            return 0, 0, None

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
        """整份录像：种子 + 步长 + 输入事件 + 玩家加入时刻 + 逐 tick 指纹。"""
        # v2：事件从 `[tick,键,值]` 变成 `[tick,槽位,键,值]`（P20 多人之后必须区分是谁按的）
        # v3：新增 `joins`（谁在第几拍上线/下线）。**不加它回放必然从第一拍就不一致**：
        #     录制时槽位 1 是第 k 拍才 `add_player` 的，而回放为了能喂输入会在开演前
        #     就把所有槽位建好 ⇒ 世界多出实体 ⇒ `ecnt` 不同 ⇒ 指纹不同。
        #     这是回放**自身**的缺陷（B21 抓到），不是世界变了。
        return {"v": 3, "seed": self.seed, "tick_hz": self.tick_hz,
                "players": int(self.api.player_count()),
                "ticks": len(self.hashes), "truncated": self.record_truncated,
                "events": self.input_log(), "joins": self.joins,
                "hashes": self.hashes, "marks": self.marks}

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
        另有副作用 `self.replay_note`：录像里缺 `joins` 时写清「哪一部分没法对上」。
        """
        self.replay_note = None
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

        # ★★★ 槽位必须在**它上线的那个 tick** 建出来，不能提前。
        #   B21（硬杀后回放）红了一整轮，根因就在这：录制时客户端是第 7 拍才按第一个键，
        #   但它**上线**是更早的一拍 ⇒ 第 1 拍的指纹里没有它。而老实现为了「能喂输入」
        #   在开演前就把槽位 1 建好了 ⇒ 第 1 拍多出 1 个玩家实体（ecnt 17 vs 20）
        #   ⇒ 回放从第一拍就报不一致，看起来像「世界变了」，其实是回放自己造的世界不同。
        #   ⇒ v3 起录像带 `joins`（`[tick, 槽位, ±1]`），这里按拍重放。
        joins = {}
        has_joins = False
        for j in (rec.get("joins") or ()):
            has_joins = True
            t, slot, d = j[0], j[1], (j[2] if len(j) > 2 else 1)
            joins.setdefault(int(t), []).append((int(slot), int(d)))
        if not has_joins:
            # 老录像（v2 及更早）**没有**上线时刻 ⇒ 只能退化成「开演前全补出来」：
            #   那样第一个 tick 的世界一定比录制时多出玩家 ⇒ 比对结果不作数。
            #   喊出来，不假装一致。
            for slot in sorted(need_slots):
                self.api.add_player(slot)
            if need_slots:
                self.replay_note = (
                    "这份录像没有 `joins`（v%d，早于 v3）：槽位 %s 只能**提前**建出来，"
                    "第一拍的世界比录制时多出这些玩家 ⇒ 逐 tick 比对**不作数**，"
                    "请用新版本重新录一份。" % (int(rec.get("v") or 1), sorted(need_slots)))
        want = rec["hashes"]
        self.api.clear_input_log()      # 重放产生的输入不再进日志（否则会越滚越长）
        for i in range(len(want)):
            # ① 先上线/下线（必须早于同一拍的输入：否则 set_input_for 会因「槽位不存在」被拒）
            for slot, d in joins.get(i, ()):
                if d > 0:
                    self.api.add_player(slot)
                else:
                    self.api.remove_player(slot)
            # ② 再喂输入
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
        # ★ H5：截断必须**显式**送到客户端。`n` 仍是「送出去的个数」，`total` 是真实总量。
        #   没有这三个字段时，客户端与日志都只能看到 400，会以为世界就这么大（实测丢过 56 个）。
        out["total"] = int(s["total"]) if s["total"] is not None else int(s["n"])
        out["dropped"] = int(s["dropped"]) if s["dropped"] is not None else 0
        out["truncated"] = bool(s["truncated"]) if s["truncated"] is not None else False
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
        """启动时读档。**读不了就明确报出来并继续用新世界**（不静默、也不拒绝启动）。

        ★★ 2026-10-20：读不动的时候**先把坏档挪走**（`<path>.bad-<时间戳>`），
          再继续用新世界。为什么必须挪：
            自动存档是**覆盖写**，而它在 30 s 后就会发生 ⇒ 如果只是「报一句然后继续」，
            那份坏档会在**半分钟内被新世界覆盖掉**，症状、时间点、内容全部消失，
            之后再想问「它到底坏在哪」已经**没有证据**了。
          这与本工程的纪律一致：**失败要吵，而且吵完现场还得在**。
          挪不动（只读目录 / 文件被占用）就只报告、不改文件 —— 不许因为清理失败而拒绝启动。
        """
        if not os.path.isfile(path):
            return False, "没有存档文件（新世界）"
        try:
            with io.open(path, encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:                                   # noqa: BLE001
            moved = self._quarantine(path)
            return False, "存档读不动（%s: %s）—— %s" % (
                type(e).__name__, e,
                ("已隔离为 %s，原文件不会再被覆盖；改用新世界" % moved) if moved
                else "改用新世界（**隔离失败，原文件保持不动**，请手工备份）")
        # ★★★ P50⑭：`save_apply` 也必须在这个 try 里（2026-10-20 实测）。
        #   原来它写在 try **外面**，于是「JSON 语法合法、但内容让 Lua 侧炸」的存档
        #   （实测：文件内容就是 `42` 或 `null`）会把 LuaError **直接抛给调用方**：
        #     · `server.py` 的启动读档没有 try ⇒ 服务端**起不来**；
        #     · 更糟的是坏档**没被隔离**，留在原地等下一次自动存档覆盖。
        #   ⇒ 口径统一成：**只要读档这一步出任何问题，都是「拒绝 + 隔离 + 说清原因」**。
        try:
            ok, msg = self.save_apply(data)
        except SimNotBooted:
            # ★★ 这一支**必须重新抛出、且绝不隔离**：原因是程序忘了 boot，
            #   不是存档坏了。把用户存档改名当垃圾，等于用程序缺陷毁数据。
            raise
        except Exception as e:                                   # noqa: BLE001            moved = self._quarantine(path)
            return False, "存档应用失败（%s: %s）—— %s" % (
                type(e).__name__, e,
                ("已隔离为 %s；改用新世界" % moved) if moved
                else "改用新世界（**隔离失败，原文件保持不动**，请手工备份）")
        if ok:
            return True, "已读档：" + msg
        moved = self._quarantine(path)
        return False, "存档被拒（%s）—— %s" % (
            msg, ("已隔离为 %s；改用新世界" % moved) if moved
            else "改用新世界（**隔离失败，原文件保持不动**，请手工备份）")

    @staticmethod
    def _quarantine(path):
        """把读不动的存档改名留证，返回新文件名；失败返回 None。

        名字带**时间戳 + 序号**：同一秒内连续坏两次时不许互相覆盖（`-1`、`-2`…）。
        """
        stamp = time.strftime("%Y%m%d-%H%M%S")
        for i in range(100):
            cand = "%s.bad-%s%s" % (path, stamp, "" if i == 0 else "-%d" % i)
            if os.path.exists(cand):
                continue
            try:
                os.replace(path, cand)
                return os.path.basename(cand)
            except OSError as e:                                 # noqa: BLE001
                print("  ⚠ 存档隔离失败（%s）：%s" % (cand, e))
                return None
        return None

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
        """把纯 Python 存档喂回 Lua（逐个字段塞进一张新 Lua 表）

        ★ P50⑭：没 boot 就抛 `SimNotBooted`（**不是**返回 False）。
          返回 False 会被 `try_load` 当成「存档坏了」⇒ 把用户存档隔离掉。
          程序缺陷连坐数据是最不能接受的一种失败。
        """
        if self.api is None:
            raise SimNotBooted("存档引擎未启动（Sim.boot() 还没调用）—— "
                               "这是调用方的问题，存档文件没有被改动")
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
