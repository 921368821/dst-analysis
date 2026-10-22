# -*- coding: utf-8 -*-
"""loops.py —— 模拟线程与看门狗（M4 从 server.py 拆出）

为什么放一起
    两者是一对：sim_loop 每拍写 hub.beat，watchdog_loop 读它判「停住」。
    判据（停多久算停）与心跳（多久写一次）必须能对着读，
    否则调阈值时两边各改一半。

★ 拆分只搬代码，不改逻辑。
"""
import os
import queue
import threading
import time

from hub import Hub
from sim import Sim


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
    last_trunc_log = 0.0    # H5：截断告警降频（每 5 s 至多一条，避免 30 Hz 刷屏）
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
                    # ★★ 录像要记「第几拍上线的」：只记输入不够 —— 玩家实体是**加入那一刻**
                    #   才出现在世界里的，回放若提前建好，第一拍的指纹就和录制时不同。
                    #   见 Sim.replay / dump_recording 的注释（B21 就是被这条咬到的）。
                    if ok:
                        sim.note_join(slot, up=True)
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
                    if ok:
                        sim.note_join(slot, up=False)   # 下线也要记（否则回放世界里他一直在）
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
                elif kind == "debug_entities":
                    # ★ P62：编辑器基础 —— 「世界里有谁」。同步回话，调用方要真数据。
                    limit, ev, box = cmd[1], cmd[2], cmd[3]
                    try:
                        ok, info = sim.debug_entities(limit)
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "debug_remove":
                    guid, ev, box = cmd[1], cmd[2], cmd[3]
                    try:
                        ok, info = sim.debug_remove(guid)
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "debug_move":
                    guid, xx, zz, ev, box = cmd[1], cmd[2], cmd[3], cmd[4], cmd[5]
                    try:
                        ok, info = sim.debug_move(guid, xx, zz)
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "spawn_undo":
                    # ★★ M1-1b：生成也进栈（撤销就是把它删掉）。
                    #   为什么不让它留在 debug_spawn 那条路上：那会变成
                    #   "移动能撤销、生成不能" —— 不一致比没有撤销更让人不敢用。
                    prefab, xx, zz, ev, box = cmd[1], cmd[2], cmd[3], cmd[4], cmd[5]
                    try:
                        ok, info = sim.spawn_via_stack(prefab, xx, zz)
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "remove_undo":
                    guid, ev, box = cmd[1], cmd[2], cmd[3]
                    try:
                        ok, info = sim.remove_via_stack(guid)
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "move_undo":
                    # ★ M1-1：带撤销的移动（走 Python 侧命令栈；push 会当场执行 do）
                    guid, xx, zz, ev, box = cmd[1], cmd[2], cmd[3], cmd[4], cmd[5]
                    try:
                        ok, info = sim.move_via_stack(guid, xx, zz)
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "undo":
                    ev, box = cmd[1], cmd[2]
                    try:
                        ok, info = sim.undo()
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"),
                                       empty=info.get("empty", False))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "redo":
                    ev, box = cmd[1], cmd[2]
                    try:
                        ok, info = sim.redo()
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"),
                                       empty=info.get("empty", False))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "undo_stats":
                    ev, box = cmd[1], cmd[2]
                    try:
                        box.update(ok=True, **sim.undo_stats())
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "recipes":
                    # ★ B2：配方列表。走模拟线程 —— AllRecipes 是 Lua 表，且 HasIngredients
                    #   会读背包组件，都不是线程安全的跨线程访问。
                    slot, limit, ev, box = cmd[1], cmd[2], cmd[3], cmd[4]
                    try:
                        ok, info = sim.recipes(slot, limit)
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind in ("scene_save", "scene_load", "scene_list"):
                    # ★ C3：场景落盘/读盘。走模拟线程 —— save 内部要导出世界（遍历实体表），
                    #   load 内部要清空+导入（SpawnPrefab），都不是 HTTP 线程能碰的。
                    ev, box = cmd[1], cmd[2]
                    try:
                        if kind == "scene_save":
                            ok, info = sim.scene_save(cmd[3])
                        elif kind == "scene_load":
                            ok, info = sim.scene_load(cmd[3])
                        else:
                            ok, info = sim.scene_list()
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"),
                                       removed=info.get("removed"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "scene_export":
                    # ★ C4：场景导出。**必须走模拟线程** —— 要遍历实体表并读 Transform，
                    #   在 HTTP 线程里直接碰 Lua 会撞上"边遍历边被 step 改表"。
                    ev, box = cmd[1], cmd[2]
                    try:
                        ok, info = sim.scene_export()
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "scene_clear":
                    # ★ C3b：清空**进栈**（整份文本装回来就是撤销）。
                    ev, box = cmd[1], cmd[2]
                    try:
                        ok, info = sim.scene_clear_stacked()
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "scene_import":
                    # ★★ C3b：导入**自己负责清空**，整次导入只占一步撤销。
                    #   客户端因此**不再**先发 scene_clear —— 两步之间失败会留下空世界，
                    #   而"清空 + 导入"本来就该是一次不可分割的编辑。
                    ev, box = cmd[1], cmd[2]
                    text = cmd[3]
                    try:
                        ok, info = sim.scene_import_stacked(text)
                        if ok:
                            box.update(ok=True, **info)
                        else:
                            box.update(ok=False, error=info.get("error"))
                    except Exception as e:                          # noqa: BLE001
                        box.update(ok=False, error="%s: %s" % (type(e).__name__, e))
                    finally:
                        ev.set()
                elif kind == "craft":
                    # ★ B1：合成/建造。**必须走模拟线程**：`Builder:DoBuild` 会 PushEvent、
                    #   会扣材料、会 SpawnPrefab —— 这些都不是线程安全的 Lua 调用。
                    slot, recname, xx, zz, ev, box = cmd[1], cmd[2], cmd[3], cmd[4], cmd[5], cmd[6]
                    try:
                        ok, info = sim.craft(slot, recname, xx, zz)
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
            # ★ H5：截断要**吵**。降频到 5 s 一条（30 Hz 下不能每帧都打）。
            #   为什么必须打：客户端只画 400 个，日志若只记 400，事后没人能判断
            #   「是世界里只有 400 个，还是被上限吃掉了」—— 这两种情况的结论完全相反。
            if snap.get("truncated"):
                _t = time.perf_counter()
                if _t - last_trunc_log >= 5.0:
                    last_trunc_log = _t
                    print("[snap] ⚠ 快照截断：可绘制实体 %d 个，只送 %d（丢 %d）—— 上限由 RT_MAX_ENTS 控制（当前 %s）"
                          % (snap["total"], snap["n"], snap["dropped"],
                             os.environ.get("RT_MAX_ENTS") or "400（默认）"))
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
