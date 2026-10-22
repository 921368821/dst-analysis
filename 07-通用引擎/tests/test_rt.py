# -*- coding: utf-8 -*-
"""test_rt.py —— P1 端到端验证（含反向测试）

跑法：
    cd 07-通用引擎 && python tests/test_rt.py
退出码：0 = 全绿

分两部分：
  A. **进程内**探针：直接驱动 Sim（快、定位准）
  B. **跨进程**探针：起真服务端，用真 WebSocket 客户端连它（验证传输层）
每个探针都配**反向判据** —— 沿用本工程纪律：
「只证明该发生的发生了」不够，还要证明**不该发生的没发生**。
"""
import io
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                  # 07-通用引擎
RT = os.path.join(ROOT, "rt")
sys.path.insert(0, RT)
# ★★ P50㉜：源码里若还留着**上一轮被中断的变异**，开跑前就拒绝（§9bm）。
#   2026-10-20 23:10 的 `--fast` 被掐断在 ②f 中途，`rt/rt_boot.lua` 停在篡改态
#   **10 小时 3 分**；这期间所有「单独跑一个案子」的结论都是**假绿**。
#   `run_all.sh` 开头只 heal 一次，别的入口全踩进去了 ⇒ 每个 import rt/ 的入口各加一道闸门。
sys.path.insert(0, HERE)                     # noqa: E402  （脚本跑时 HERE 已在 path，这行是不靠这个语义）
from _src_guard import guard                 # noqa: E402
guard(quiet=True)                            # 干净时不说话；脏就 SystemExit(2) + 打印还原命令

# ★★ P50⑲：连**本机**起的服务端**不该走代理**。
#   实测事故（第 8 轮全量的 ② 组 7 条红）：环境注入了
#   `http_proxy=http://127.0.0.1:59817` 而 `no_proxy` 为空 ⇒ `urllib` 把
#   `http://127.0.0.1:8791/...` 也发给了代理。服务端**在**的时候它能转发，
#   所以 B6 一直是绿的；服务端一旦不在，拿回来的**不是**「连接被拒」而是
#   **502 Bad Gateway** —— 于是 E8/E11 斩钉截铁地报「/debug/kill 返回 502
#   ⇒ 默认关没生效」，而真因是**那个服务端已经没了**（一个完全指错方向的结论）。
#   同一个坑 `tests/test_deploy.py`、`tests/test_stall_watchdog.py` 早填过，
#   唯独这个文件（35 处 urllib）漏了 —— 「同一串规则抄三份、漏一份」。
#   ⇒ 除了这里补上，`tools/verify_plan.py` 里加了一条静态判据：
#     凡是用 `urllib.request` 的测试/工具文件，必须设 no_proxy。
os.environ["no_proxy"] = "127.0.0.1,localhost"
os.environ["NO_PROXY"] = "127.0.0.1,localhost"

PASS, FAIL = 0, 0
RESULTS = []


def check(name, fn):
    global PASS, FAIL
    # ★★ `RT_ONLY=<子串>` 时**只跑名字里含该子串的判据**（2026-10-16 加）。
    #   为什么需要：服务端侧的「变异测试」（`tests/falsify_server.py`）要对每条篡改
    #   只跑**它该被抓住的那条判据**；否则 7 条篡改 × 整套端到端（约 3 分钟）＝ 20 分钟，
    #   没人会愿意跑。顺带也让「只查一条」的排查快很多。
    #   ⚠️ 跳过的判据**不计数**（既不通过也不失败），所以 `RT_ONLY` 下的汇总行
    #     说的是「跑了的那几条」，不能拿来当基线数字 —— 工具里已注明。
    #   ★ 因此：**正式判定必须跑全量**（`bash tests/run_all.sh`）。`RT_ONLY` 只用于
    #     单条排查与变异验证；拿它当「绿了」的证据，等于只跑了 1/61 的端到端。
    only = os.environ.get("RT_ONLY")
    # ★ `B0`（起服务端）**永远跑**：它是后面所有跨进程判据的前置。
    #   第一版没豁免它 ⇒ 过滤到跨进程判据时服务端根本没起 ⇒ 一条**假红**。
    if only and only not in name and not name.startswith("B0"):
        return
    t0 = time.perf_counter()
    try:
        ok, info = fn()
    except Exception as e:                                        # noqa: BLE001
        ok, info = False, "抛异常: %s: %s" % (type(e).__name__, e)
        # ★ 2026-10-18：**异常要带栈**。原来只留一行 `抛异常: AttributeError: ...`，
        #   结果 E10 在「'int' object has no attribute 'get'」上耗了很久 —— 判据里
        #   有 6 处 `.get()`，光看这一行根本不知道是哪一处。（本合同「失败要吵」：
        #   吵的内容要够定位，否则只是噪音。）栈打到 stderr，不打乱 ✔/✘ 的对齐。
        if os.environ.get("RT_TB") != "0":
            traceback.print_exc(file=sys.stderr)
    ms = (time.perf_counter() - t0) * 1000
    if ok:
        PASS += 1
        print("  ✔ %-46s %s  (%.0f ms)" % (name, info, ms))
    else:
        FAIL += 1
        print("  ✘ %-46s %s  (%.0f ms)" % (name, info, ms))
    RESULTS.append((name, ok, info))


def hr(t):
    print("\n" + "═" * 74)
    print("  " + t)
    print("═" * 74)


# =============================================================================
# A. 进程内探针
# =============================================================================
hr("A. 进程内：Sim 探针（固定步长 / 输入 / 快照 / 可复现 / 反向）")

from server import Sim   # noqa: E402

SIM = {}


def a1_boot():
    sim = Sim(seed=20261015, tick_hz=30, max_ents=400).boot()
    SIM["s"] = sim
    st = sim.stats()
    if not st["player_ok"]:
        return False, "玩家实体没建起来"
    return True, "boot %.0f ms / %d 实体 / 玩家 ok" % (sim.boot_ms, st["n_ents"])


def a2_time_advances():
    sim = SIM["s"]
    s0 = sim.snapshot()
    for _ in range(60):
        sim.step()
    s1 = sim.snapshot()
    dt = s1["t"] - s0["t"]
    if not (1.9 < dt < 2.1):
        return False, "60 tick 应推进约 2.0 s，实际 %.3f" % dt
    return True, "60 tick → %.3f s（30 Hz 正确）" % dt


def a3_dir_input_moves_correctly():
    """★★ 方向必须**真的**跟着输入走 —— 四个方向**各自**断言，不只测「右」。

       ★★★ 为什么这条要单独写（这是踩出来的真缺陷）：
       第一版把 `Vector3(x, 0, z)` 传给了 `loco:WalkInDirection`，而那个参数其实是
       **朝向角（度）**（取证见 `rt/rt_boot.lua` 的 `dir_to_angle` 注释）⇒
       宿主把非数字收敛成 0 ⇒ **朝向恒为 0** ⇒ 物理沿 0 度积分 ⇒
       **玩家永远朝 +x 走，四个方向键没有任何区别**。

       而当时那条「按右 ⇒ x 变大」**照样是绿的** —— 因为 +x 恰好就是它要的方向。
       典型的「**判据通过但什么都没证明**」：只测一个方向，
       就分不清「按右生效」和「不管按什么都往 +x」。

       判据有三层（缺一层都可能漏）：
         ① 主方向必须动（在期望的轴上 > 5 格）；
         ② **不许有侧向位移**（另一个方向 ≤ 0.5 格）—— 这条直接打死「恒定 +x」；
         ③ 宿主**不得**把非数字喂给 `SetRotation`（跨文件语义守卫，
            换个写法绕过 ①② 它也会响）。
    """
    want = [("right", +1, 0), ("left", -1, 0), ("up", 0, +1), ("down", 0, -1)]
    rows = []
    for k, wx, wz in want:
        sim = Sim(seed=777, tick_hz=30).boot()
        sim.set_input(k, True)
        for _ in range(60):
            sim.step()
        p = sim.snapshot()["player"]
        x, z = p["x"], p["z"]
        main = x * wx + z * wz          # 期望轴上的分量
        side = x * wz - z * wx          # 垂直轴上的分量（叉积）
        if main < 5.0:
            return False, "按 %s：主方向只有 %+.3f（期望朝 %+d,%+d，且 > 5）" % (k, main, wx, wz)
        if abs(side) > 0.5:
            return False, "按 %s：出现侧向位移 %+.3f（x=%.3f z=%.3f）—— 方向没生效？" % (k, side, x, z)
        rows.append("%s(%+.1f,%+.1f)" % (k, x, z))

    # 斜向：两轴都动且对称（对角归一化要对，否则斜着走会快 41%）
    sim = Sim(seed=777, tick_hz=30).boot()
    sim.set_input("right", True)
    sim.set_input("down", True)
    for _ in range(60):
        sim.step()
    p = sim.snapshot()["player"]
    if p["x"] < 5.0 or p["z"] > -5.0:
        return False, "斜向（右+下）没有两轴同时动：x=%.3f z=%.3f" % (p["x"], p["z"])
    if abs(p["x"] + p["z"]) > 0.05:
        return False, "斜向两轴不对称：x=%.3f z=%.3f" % (p["x"], p["z"])

    # ③ 跨文件语义守卫：朝向必须是**数字**传进 SetRotation
    # ⚠️ 不能写 `StubCount.get(...)`：lupa 的 `_LuaTable.get` 会**返回 Lua 字段 get**（nil）
    #    ⇒ 调用它得到 "TypeError: 'NoneType' object is not callable"。
    #    （又一次「同一个名字在两种语言里含义不同」。）
    _sc = sim.api._core.StubCount
    cnt = (_sc["Transform:SetRotation(非数字:table)"] if _sc is not None else 0) or 0
    if cnt:
        return False, "有 %d 次把**表**喂给了 SetRotation（朝向会被静默丢弃）—— 见 dir_to_angle 注释" % cnt
    we, first = sim.api.walk_errors()
    if we:
        return False, "WalkInDirection 抛错 %d 次：%s" % (we, first)
    return True, "四方向各自对位 %s；斜向右下 (%.1f, %.1f) 对称；SetRotation 无非数字、walk 0 错" % (
        " ".join(rows), p["x"], p["z"])


def a3_input_moves_player():
    """★ 核心探针：输入必须**真的**改变世界状态"""
    sim = SIM["s"]
    sim.clear_input()
    for _ in range(10):
        sim.step()
    p0 = sim.snapshot()["player"]
    # 按「右」走 60 tick
    sim.set_input("right", True)
    for _ in range(60):
        sim.step()
    p1 = sim.snapshot()["player"]
    sim.set_input("right", False)
    dx = p1["x"] - p0["x"]
    if dx <= 0.2:
        return False, "按右 60 tick 后 x 只变了 %.3f（应明显 >0）" % dx
    return True, "按右 60 tick：x %+.3f（%.3f → %.3f）" % (dx, p0["x"], p1["x"])


def a3b_no_input_no_move():
    """★ 反向：不输入时**不得**自己动"""
    sim = SIM["s"]
    sim.clear_input()
    for _ in range(10):
        sim.step()
    p0 = sim.snapshot()["player"]
    for _ in range(60):
        sim.step()
    p1 = sim.snapshot()["player"]
    dx = abs(p1["x"] - p0["x"]) + abs(p1["z"] - p0["z"])
    if dx > 0.05:
        return False, "无输入却移动了 %.3f（说明有别的东西在推它）" % dx
    return True, "无输入 60 tick 位移 %.4f（≈0）" % dx


def a4_snapshot_shape():
    s = SIM["s"].snapshot()
    if not s["ents"]:
        return False, "ents 为空"
    if "player" not in s:
        return False, "缺 player 字段"
    need = {"t", "tick", "n", "ents", "iseq", "world"}
    miss = need - set(s)
    if miss:
        return False, "缺字段: %s" % miss
    e = s["ents"][0]
    if not ({"id", "x", "z"} <= set(e)):
        return False, "实体缺 id/x/z: %s" % e
    w = s["world"]
    if w is None:
        return False, "world 为空（世界组件没挂上？）"
    wneed = {"phase", "season", "isday", "isdusk", "isnight", "temperature"}
    wmiss = wneed - set(w)
    if wmiss:
        return False, "world 缺字段: %s" % wmiss
    return True, "n=%d，字段齐（含 player + world：%s/%s %.1f°）" % (
        s["n"], w["phase"], w["season"], w["temperature"])


def a5_reproducible():
    """固定种子 + 相同输入序列 ⇒ 指纹应逐次相同（本工程核心纪律）"""
    def run():
        sim = Sim(seed=777, tick_hz=30, max_ents=400).boot()
        sim.set_input("right", True)
        for _ in range(45):
            sim.step()
        sim.set_input("right", False)
        sim.set_input("up", True)
        for _ in range(45):
            sim.step()
        return sim.fingerprint()
    f1 = run()
    f2 = run()
    if f1[1] != f2[1]:
        return False, "两次不一致:\n     %s\n     %s" % (f1[0], f2[0])

    # ★★★ M1 反向：动一个**非玩家**实体 ⇒ 指纹必须变。
    #   M1 之前指纹只含 px/pz/moved，这一段会**全绿**（NPC 走岔、植被被清都看不见）。
    #   现在要求指纹里含有「所有 prefab 实体的 (名字, 量化坐标)」的滚动和。
    sim = Sim(seed=777, tick_hz=30, max_ents=400).boot()
    L = sim.lua
    L.globals().RT = sim.api
    for _ in range(20):
        sim.step()
    before, h_before = sim.fingerprint()
    n_moved = L.eval("""(function()
        local n = 0
        for _, inst in pairs(Ents or {}) do
            if n >= 1 then break end
            if inst.prefab ~= nil and inst ~= RT.player and inst.Transform ~= nil then
                local x, y, z = inst.Transform:GetWorldPosition()
                if x ~= nil then
                    inst.Transform:SetPosition(x + 1, y or 0, z or 0)
                    n = n + 1
                end
            end
        end
        return n
    end)()""")
    if not n_moved:
        return False, "找不到可移动的非玩家实体 —— 这条反向测不到东西"
    after, h_after = sim.fingerprint()
    if h_before == h_after:
        return False, ("把 1 个非玩家实体挪了 1 格，指纹**没变**（hash 仍 %d）—— "
                       "指纹没覆盖实体，NPC/植被走岔了也发现不了\n     before %s\n     after  %s"
                       % (h_before, before, after))

    return True, "两次一致 hash=%d；挪 1 个 NPC 后指纹变为 %d（实体已被覆盖）" % (h_before, h_after)


def a6_negative_dt():
    """★ 反向：dt<=0 必须报错，不能静默推进"""
    sim = SIM["s"]
    bad = []
    for dt in (0, -0.5):
        try:
            sim.api.step(dt)
            bad.append(dt)
        except Exception:                                        # noqa: BLE001
            pass
    if bad:
        return False, "dt=%s 竟然没报错（会静默推进）" % bad
    return True, "dt=0 / dt=-0.5 都报错 ✔"


check("A1 启动：世界 + 玩家实体建起来", a1_boot)
check("A2 世界时间随步进推进（30 Hz 正确）", a2_time_advances)
check("A3 **四方向各自对位**（不只测「右」——曾因只测一个方向漏掉「恒定 +x」）", a3_dir_input_moves_correctly)
check("A3c 输入真的改变世界状态（按右→x 变大）", a3_input_moves_player)
check("A3b 反向：**无输入不得自己动**", a3b_no_input_no_move)
check("A4 快照结构完整（ents/player/字段）", a4_snapshot_shape)
check("A5 可复现：同种子+同输入 ⇒ 指纹相同", a5_reproducible)
check("A6 反向：dt<=0 必须报错（不得静默推进）", a6_negative_dt)

# ---- P2-2：真实 TheInput + 原版 locomotor 路径 ----
def a7_theinput_real():
    """★ 真实 TheInput：不是空壳，未知接口也不静默 nil"""
    sim = SIM["s"]
    TI = sim.api.input.TI
    sim.set_input("right", True)
    down = TI.IsKeyDown(TI, "right")
    ctrl = TI.IsControlPressed(TI, "CONTROL_MOVE_RIGHT")
    ctrl2 = TI.IsControlPressed(TI, "CONTROL_MOVE_LEFT")
    unk = TI.IsKeyDown(TI, "never_pressed_key")
    pad = TI.ControllerAttached(TI)
    sim.clear_input()
    up = TI.IsKeyDown(TI, "right")
    if not down or not ctrl or ctrl2 or unk or pad or up:
        return False, ("down=%s ctrl=%s ctrl2=%s unk=%s pad=%s up=%s"
                       % (down, ctrl, ctrl2, unk, pad, up))
    return True, "IsKeyDown/IsControlPressed 真实生效；未知键=false；无手柄=false"


def a8_moves_via_locomotor():
    """★ 移动必须走**原版** locomotor，而不是 Physics 兜底"""
    sim = SIM["s"]
    sim.clear_input()
    st0 = sim.stats()
    p0 = sim.snapshot()["player"]
    sim.set_input("right", True)
    for _ in range(60):
        sim.step()
    sim.set_input("right", False)
    st1 = sim.stats()
    p1 = sim.snapshot()["player"]
    dx = p1["x"] - p0["x"]
    d_loco = st1["used_locomotor"] - st0["used_locomotor"]
    d_phys = st1["used_physics"] - st0["used_physics"]
    if dx <= 0.5:
        return False, "按右 60 tick 后 x 只变了 %.3f" % dx
    if d_loco < 60:
        return False, "原版 locomotor 只被调了 %d 次（应 60）" % d_loco
    if d_phys != 0:
        return False, "Physics 兜底被用了 %d 次（应为 0）" % d_phys
    return True, "x %+.2f，locomotor×%d，Physics 兜底×%d" % (dx, d_loco, d_phys)


def a9_physics_errors_zero():
    """★ 反向：物理积分**不得有错误**（宿主曾把 rotation 表传进 cos()，
       并被 pcall 静默吞掉 —— 现在会计数，所以这条能抓到回归）"""
    sim = SIM["s"]
    n = sim.api._sim.PhysicsErrors or 0
    if n != 0:
        return False, "物理积分报错 %d 次：%s" % (n, sim.api._sim.PhysicsErrorFirst)
    return True, "0 次 ✔（若再出现会被计数而非静默）"


# ---- 世界环境：昼夜 / 季节 / 温度（真实世界组件，不是宿主硬编码） ----
def a14_world_cycles():
    """★★ 修复前的实测缺口：TheWorld 一个世界组件都没挂 ⇒
       `state.phase` 永远是 day、温度恒 35 ⇒ **世界里永远是大白天**。

       这条测试要证明的不是「字段存在」，而是「**值真的随时间变**」：
       跑满一个秋天（8/6/2 段 ×30 s = 240/180/60 s，共 480 s）应看到
       day → dusk → night 三态齐全，`cycles` 从 0 涨到 1，温度不再是常数。
    """
    sim = Sim(seed=4242, tick_hz=30).boot()
    comp = sim.api.world_components()
    if not comp["ok"]:
        return False, "世界组件没挂全，缺: %s" % (comp["missing"],)
    w0 = sim.api.world_state()
    if w0 is None:
        return False, "world_state 读不到"
    phases, temps, cycles0 = set(), set(), w0["cycles"]
    # 秋天一天 = 8/6/2 段 × 30 s = 480 s ⇒ 跑 500 s（15000 tick）刚好跨过第 2 天开头。
    # ★ 为什么不是刚好 480 s：TheSim.time 是浮点累加（实测 300 s 存成 300.000000000023），
    #   卡在边界上会因 1e-13 的误差判成「还没到」——那是**判据太紧**，不是缺陷。
    #   真实 30 Hz 口径，不放大 dt 走捷径。
    for i in range(15000):
        sim.step()
        if i % 120 == 0:                     # 每 4 s 世界时间采一次
            w = sim.api.world_state()
            phases.add(w["phase"])
            temps.add(round(w["temperature"], 1))
    w1 = sim.api.world_state()
    if not ({"day", "dusk", "night"} <= phases):
        return False, "500 s 内只观察到相位 %s（应有 day/dusk/night）" % sorted(phases)
    if len(temps) < 10:
        return False, "温度几乎不变（%d 个不同值）—— worldtemperature 没在跑" % len(temps)
    if w1["cycles"] < cycles0 + 1:
        return False, "跑满 500 s 后 cycles 仍是 %d（应有第 2 天）" % w1["cycles"]
    return True, "500 s：相位 %s，温度 %d 个不同值（%.1f~%.1f），cycles %d→%d" % (
        "/".join(sorted(phases)), len(temps), min(temps), max(temps), cycles0, w1["cycles"])


def a15_world_reverse_not_frozen():
    """★ 反向：**不挂**世界组件时（= 修复前的旧行为），世界必须退回「恒为大白天」，
       而且 `world_components().ok` 必须为 False。

       为什么必须做这条：A14 断言「相位会变」。如果实现是「不管挂没挂都返回
       一组会变的假值」，A14 照样绿 —— 那就成了自满足的空检查。
       这里用启动开关 `RT_NO_WORLD_COMPONENTS=1` 造出「没挂」的状态，
       证明 A14 的绿确实来自真组件在跑。
    """
    os.environ["RT_NO_WORLD_COMPONENTS"] = "1"
    try:
        sim = Sim(seed=4243, tick_hz=30).boot()
    finally:
        os.environ.pop("RT_NO_WORLD_COMPONENTS", None)
    comp = sim.api.world_components()
    if comp["ok"]:
        return False, "开关设了却仍报 world_components.ok=True（开关没生效）"
    before = sim.api.world_state()
    for _ in range(14400):                    # 同样跑 480 s
        sim.step()
    after = sim.api.world_state()
    if before is None or after is None:
        # 没挂组件时连 state 都读不到 —— 同样是「旧症状可被检出」的一种形态
        return True, "不挂组件时 world_state 直接为 nil ⇒ A14 不可能自满足"
    if before["phase"] != after["phase"] or abs(after["temperature"] - before["temperature"]) > 1e-9:
        return False, "没挂组件后相位/温度仍在变（%s→%s, %.2f→%.2f）—— 说明值不是来自世界组件" % (
            before["phase"], after["phase"], before["temperature"], after["temperature"])
    return True, "不挂组件时相位恒为 %s、温度恒为 %.2f ⇒ A14 确实指向真行为" % (
        after["phase"], after["temperature"])


def a16_stats_json_safe():
    """★ 反向：`stats()` 必须能**直接 json.dumps** —— /healthz 与 /status 就是把它
       dumps 出去的。

       踩过的坑：加世界组件那轮，我往 `stats` 里塞了一个 Lua 数组（`world_missing`），
       `json.dumps` 不认 lupa 的 `_LuaTable` ⇒ **所有** HTTP 请求 500；
       而当时状态行写的是占位符 "500 x"，客户端只显示出 "HTTP Error 500: x"，
       完全看不出是 stats 干的。这条测试就是钉住这个形态。
    """
    s = SIM["s"].stats()
    lua_keys = [k for k, v in s.items() if type(v).__name__ == "_LuaTable"]
    if lua_keys:
        return False, "stats() 里有 Lua 表字段: %s（json.dumps 会炸）" % lua_keys
    try:
        blob = json.dumps(s, ensure_ascii=False)
    except Exception as e:                                       # noqa: BLE001
        return False, "stats() 不可序列化: %s: %s" % (type(e).__name__, e)
    return True, "%d 个字段全部 JSON 安全（%d 字节）" % (len(s), len(blob))


check("A16 反向：stats() 必须能直接 json.dumps（/healthz 依赖它）", a16_stats_json_safe)
check("A14 **昼夜/季节/温度真的随世界时间推进**（480 s 走完一天）", a14_world_cycles)
check("A15 反向：摘掉世界组件即退回「恒为大白天」——证明 A14 不是空检查", a15_world_reverse_not_frozen)
check("A7 真实 TheInput（IsKeyDown/IsControlPressed/无手柄）", a7_theinput_real)
check("A8 移动走**原版 locomotor**（非 Physics 兜底）", a8_moves_via_locomotor)
check("A9 反向：物理积分错误数必须为 0", a9_physics_errors_zero)

# ---- P3：存档 / 读档 ----
def _mk_save():
    """造一份存档：跑 90 tick（有位移）后 collect，再过 JSON 往返"""
    sim = SIM["s"]
    sim.clear_input()
    sim.set_input("right", True)
    for _ in range(90):
        sim.step()
    sim.set_input("right", False)
    snap = sim.snapshot()
    rec = sim.save_collect()
    blob = json.dumps(rec, ensure_ascii=False)
    return snap, rec, json.loads(blob), blob


def a10_save_roundtrip():
    """★ 存档→JSON→读档：玩家位置与世界时间都必须逐值恢复"""
    sim = SIM["s"]
    snap, rec, back, blob = _mk_save()
    ok, err = sim.save_validate(back)
    if not ok:
        return False, "存档校验不过: %s" % err
    # 改动世界后再读档
    sim.set_input("right", True)
    for _ in range(60):
        sim.step()
    sim.set_input("right", False)
    ok2, msg = sim.save_apply(back)
    if not ok2:
        return False, "读档失败: %s" % msg
    after = sim.snapshot()
    st = sim.stats()
    dx = abs(after["player"]["x"] - snap["player"]["x"])
    dt = abs(st["time"] - snap["t"])
    if dx > 0.01:
        return False, "玩家位置没恢复：差 %.3f" % dx
    if dt > 0.01:
        return False, "世界时间没恢复：差 %.4f" % dt
    if not st["player_ok"]:
        return False, "读档后玩家实体没了"
    return True, "位置/时间逐值恢复（JSON %d 字节）" % len(blob)


def a11_load_then_play():
    """★ 读档之后世界必须**还能玩**（不是一具尸体）"""
    sim = SIM["s"]
    snap, rec, back, blob = _mk_save()
    sim.set_input("right", True)
    for _ in range(60):
        sim.step()
    sim.set_input("right", False)
    sim.save_apply(back)
    p0 = sim.snapshot()["player"]
    st0 = sim.stats()
    sim.set_input("right", True)
    for _ in range(60):
        sim.step()
    sim.set_input("right", False)
    p1 = sim.snapshot()["player"]
    st1 = sim.stats()
    dx = p1["x"] - p0["x"]
    d_loco = st1["used_locomotor"] - st0["used_locomotor"]
    if dx <= 0.5:
        return False, "读档后按右只动了 %.3f" % dx
    if d_loco < 60:
        return False, "读档后 locomotor 只被调 %d 次" % d_loco
    return True, "读档后仍可操控：x %+.2f（locomotor×%d）" % (dx, d_loco)


def a12_bad_save_safe():
    """★ 反向：坏档案必须**报错且不破坏当前世界**"""
    sim = SIM["s"]
    snap, rec, back, blob = _mk_save()
    st0 = sim.stats()
    bad = json.loads(blob)
    bad["ents"][1]["x"] = "这不是数字"
    ok, err = sim.save_apply(bad)
    st1 = sim.stats()
    if ok:
        return False, "坏档案竟然被接受了"
    if st1["n_ents"] != st0["n_ents"] or abs(st1["time"] - st0["time"]) > 0.01:
        return False, "世界被坏档案破坏了（实体 %d→%d，t %.2f→%.2f）" % (
            st0["n_ents"], st1["n_ents"], st0["time"], st1["time"])
    return True, "拒绝且世界原样（%s）" % err[:40]


def a13_bad_save_variants():
    """★ 反向：三种结构性坏档案都要被拒（且都要说得出原因）"""
    sim = SIM["s"]
    _s, _r, _b, blob = _mk_save()
    cases = [("空 ents", lambda d: d.update(ents=[])),
             ("缺 version", lambda d: d.pop("version")),
             ("ents 非表", lambda d: d.update(ents="oops")),
             ("缺 time", lambda d: d.pop("time"))]
    bad = []
    for name, mut in cases:
        d = json.loads(blob)
        mut(d)
        ok, err = sim.save_validate(d)
        if ok:
            bad.append(name + " 竟被接受")
        elif not err:
            bad.append(name + " 没给原因")
    if bad:
        return False, "；".join(bad)
    return True, "4 种坏档案全部拒绝且都带原因 ✔"


def a13b_bad_savefile_any_shape_is_rejected():
    """★ 反向：**任何形态的坏存档文件**都必须「拒绝 + 隔离 + 说得出原因」，不许抛

    ★★ 为什么单独立（2026-10-20 实测）：A13 测的是「**字典**里某个字段坏了」，
      而真正把服务端搞崩的是**顶层不是字典**的那几种：
        存档文件内容为 `42` 或 `null` —— 都是**合法 JSON**，`json.load` 照样成功，
        于是 `M.save_apply` 拿到一个**标量**；`SaveMod.validate` 已经正确拒了，
        但 `M.save_apply` 少了 `if not ok then return`，控制流继续走到
        `pairs(t.players or {})` ⇒ `attempt to index local 't' (a number value)`
        ⇒ **LuaError 冒出 Python** ⇒ ① server 启动读档没有 try ⇒ 起不来
        ② `try_load` 的 except 只包住 `json.load` ⇒ 坏档**连隔离都做不到**。
      ⚠ 11 种里只崩 2 种：字符串 `"abc"` 在 Lua 里索引是**合法**的（返回 nil），
        所以「大部分坏档都没事」—— 这正是这类缺口能活下来的原因。
    """
    import tempfile as _tf
    sim = SIM["s"]
    cases = {
        "顶层是数字": 42,
        "顶层是 null": None,
        "顶层是字符串": "abc",
        "顶层是布尔": True,
        "顶层空数组": [],
        "顶层空对象": {},
        "ents 是字符串": {"ents": "x"},
        "ents 是 null": {"ents": None},
        "ents 里是数字": {"ents": [1, 2]},
        "seed 是字符串": {"seed": "abc", "ents": []},
        "ents 里缺字段": {"ents": [{"id": 1}]},
    }
    bad = []
    for name, val in cases.items():
        d = _tf.mkdtemp(prefix="a14_")
        p = os.path.join(d, "s.json")
        try:
            with io.open(p, "w", encoding="utf-8") as f:
                f.write(json.dumps(val))
            try:
                ok, msg = sim.try_load(p)
            except Exception as e:                       # noqa: BLE001
                bad.append("%s ⇒ 抛了 %s（坏档也没被隔离）" % (name, type(e).__name__))
                continue
            left = sorted(os.listdir(d))
            moved = [n for n in left if ".bad-" in n]
            if ok:
                bad.append(name + " 竟被接受")
            elif not msg:
                bad.append(name + " 没给原因")
            elif not moved:
                bad.append("%s 被拒但**没留证**（%r）" % (name, left))
            elif os.path.exists(p):
                bad.append(name + " 原路径还在（隔离没生效）")
        finally:
            import shutil
            shutil.rmtree(d, ignore_errors=True)
    if bad:
        return False, "；".join(bad)
    return True, "%d 种形态的坏存档：全部拒绝 + 隔离 + 带原因（无一条抛）" % len(cases)


check("A10 存档→JSON→读档：位置与时间逐值恢复", a10_save_roundtrip)
check("A11 读档后世界**还能玩**（输入仍驱动 locomotor）", a11_load_then_play)
check("A12 反向：坏档案被拒且**不破坏世界**", a12_bad_save_safe)
check("A13 反向：4 种结构性坏档案全部拒绝且带原因", a13_bad_save_variants)
check("A13b 反向：11 种形态的坏存档都只「拒绝+隔离」，一条都不抛", a13b_bad_savefile_any_shape_is_rejected)

# =============================================================================
# B. 跨进程：真服务端 + 真 WebSocket 客户端
# =============================================================================
hr("B. 跨进程：服务端 + WebSocket 传输层")

PORT = int(os.environ.get("RT_TEST_PORT", "8791"))
PROC = {}


def _log_text(path):
    """读（可能还在被写的）子进程日志；读不到就返回空串（不抛）。"""
    try:
        with io.open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def _world_time(port, timeout=5):
    """问 `/healthz` 的世界时间（秒）。**显式绕代理**（环境里注入了 http_proxy）。"""
    import urllib.request
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open("http://127.0.0.1:%d/healthz" % port, timeout=timeout) as r:
            d = json.loads(r.read().decode("utf-8"))
        return float((d.get("stats") or {}).get("time") or 0.0)
    except Exception:                                            # noqa: BLE001
        return None


def _wait_own_world(proc, logp, port, what, t0, timeout=20.0, logfile=None):
    """等到「**我起的那个进程**」在自己的端口上监听 —— 挡住两种假绿灯。

    ★★ 2026-10-20 第 8 轮全量实测事故（② 组 7 条红），证据链：
        · `B0 起服务端` 绿了，用时 **9 ms**；而这个服务端 boot 实测要 3.7~5.2 s；
        · 紧接着 `B2` 看到的世界时间是 **173 s**（刚起的世界是 **0.27 s**，
          单独重跑一次即可对照）；
        · 等"那个东西"消失，B24 起全组 ConnectionRefused，E10 也一样。
       ⇒ 「端口能连上」证明不了「端口上是我」。原来的判据两头都漏：
         ① 别人的服务端在听 ⇒ 我的进程启动即退出（端口已被占用），
            而 `poll()` 还没来得及反映，探测就先连上了**别人**；
         ② 就算连的是别人，绿得一样漂亮，后面的判据在一份**陌生的世界**上跑。
       ⇒ 现在要求两件事同时成立：
         ① **我自己的日志里有 banner**（`[http] http://127.0.0.1:<port>/`）——
            别人的进程不会写我的日志文件。banner 在 bind **之后**才打印，
            所以「见到 banner」⇒「端口是我的」。
         ② **世界年龄不能超出「我这个进程存在了多久」** ——
            我这进程才活了 0.1 s，世界却跑了 173 s，那只可能是别人的世界。
            ⚠ 这条只在**没传 `--save-file`** 时成立（读档会让年龄合理地变大）；
              本文件三个起法都没传，注释写在这里，免得以后有人加了存档又说判据疯了。
    """
    deadline = t0 + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            if logfile is not None:
                try:
                    logfile.close()
                except Exception:                                # noqa: BLE001
                    pass
            raise RuntimeError("%s 启动即退出：\n%s" % (what, _log_text(logp)))
        text = _log_text(logp)
        mine = ("[http] http://" in text) and (":%d/" % port in text)
        if mine:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    pass
            except OSError:
                time.sleep(0.1)
                continue
            t_world = _world_time(port)
            age = time.time() - t0
            if t_world is not None and t_world > age + 5.0:
                raise RuntimeError(
                    "%s 的端口 %d 上，世界已经跑了 %.1f s，而我这个进程才存在 %.1f s "
                    "—— **连到别人的世界了**（不是我刚起的那个）。日志：%s"
                    % (what, port, t_world, age, logp))
            return
        # banner 还没出现，端口却已经能连上 ⇒ 那不是我的进程
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                raise RuntimeError(
                    "端口 %d 上已经有**别人的**服务端在听（我起的那个还没打印 banner，"
                    "很可能正因「端口已被占用」退出）—— 拒绝在别人的世界上跑这一组。"
                    "日志：%s" % (port, logp))
        except OSError:
            pass
        time.sleep(0.1)
    raise RuntimeError("%s %.0f s 内未监听（日志：%s）" % (what, timeout, logp))


def _start_server():
    """起跨进程测试用的服务端。

    ★★ 2026-10-20（P49）：stdout 从 `subprocess.PIPE` 改成**日志文件**。
      原来写的是 `stdout=subprocess.PIPE, stderr=subprocess.STDOUT`，而整个文件里
      没有任何一处读它（只有启动失败分支会 `proc.stdout.read()`）。两个后果：
      ① **现场留不下**：服务端所有「失败必须无条件打印」的话（`[player] ✘ 槽位 N 加入失败`
         `[handler] 异常`）全进了没人读的管道 —— 正是本工程明令禁止的那类事故
         （「判据可以吵，但前提是现场还在」）。B26 偶发红时，日志里一个字的原因都没有。
      ② **可能把服务端卡死**：管道缓冲区写满后，写 stdout 的线程会阻塞
         （Windows 匿名管道默认只有几 KB）。服务端一旦卡在 print 上，模拟线程就停，
         `add_player` 排队也永远不执行 ⇒ 客户端看到的是「帧在流 / you 一直是 null」。
      改成文件后：现场能翻，也不会因为没人读而反压。
      ★ 但还有一层：**必须 `-u`（不缓冲）**。第一次改成文件后日志是 0 字节 ——
        因为 stdout 不是 tty 时 Python 是块缓冲（8 KB），而这个进程最后是被 terminate
        掉的，缓冲区直接丢了。**「有日志文件」不等于「有日志」**，与「有判据不等于判据会红」
        是同一类错觉。
    """
    import tempfile
    _PROC_N = PROC.get("n", 0) + 1
    PROC["n"] = _PROC_N
    logp = os.path.join(tempfile.gettempdir(), "rt_main_%02d_p%d.log" % (_PROC_N, PORT))
    lf = open(logp, "w", encoding="utf-8")
    PROC["log"] = logp
    print("  [main] 服务端日志：%s" % logp)
    env = dict(os.environ)
    env["PYTHONUNBUFFERED"] = "1"
    t0 = time.time()
    proc = subprocess.Popen(
        [sys.executable, "-u", os.path.join(RT, "server.py"),
         "--port", str(PORT), "--hz", "30", "--seed", "20261015", "--quiet"],
        stdout=lf, stderr=subprocess.STDOUT, env=env,
        cwd=RT, text=True)
    PROC["p"] = proc
    PROC["lf"] = lf
    # ★ 等「**我起的那个**」监听（见 _wait_own_world：端口能连 ≠ 端口是我的）
    _wait_own_world(proc, logp, PORT, "服务端", t0, timeout=20.0, logfile=lf)


def b0_start():
    _start_server()
    return True, "服务端已起在 127.0.0.1:%d" % PORT


def b1_handshake():
    import ws
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    resp = ws.client_handshake(sock, "127.0.0.1:%d" % PORT)
    sock.close()
    if "101" not in resp.split("\r\n")[0]:
        return False, "握手未返回 101: %r" % resp.split("\r\n")[0]
    if "sec-websocket-accept" not in resp.lower():
        return False, "缺 Sec-WebSocket-Accept"
    return True, "101 Switching Protocols + Accept 头齐 ✔"


def _recv_exact(sock, n, timeout=5.0):
    """**精确**读 n 个字节（循环直到读满）。

    ★★ 为什么必须这样：`sock.recv(2)` 只保证「至少 1 字节」，TCP 完全可能把 2 字节的
      WebSocket 帧头拆成两次投递（实测在「一帧快照紧跟一条 you 握手」时被触发，
      报 `ValueError: not enough values to unpack (expected 2, got 1)`）。
      ⇒ 读帧必须**循环读到你要的字节数**，不能指望一次 recv 拿全。
      （真实浏览器自带的 WebSocket 实现替我们做了这件事，所以只有手写的测试客户端会踩。）
    ★★ P49：**只在超时值真的不同时才 settimeout**。
    原来每次 `recv` 都调一次。读线程用 1.0 s、主线程同时在同一个 socket 上 `sendall`
    （`_Reader.ask()` 每 0.2 s 发一次 whoami），而 `settimeout()` 在 CPython 里会动
    socket 的阻塞模式（ioctl FIONBIO）—— 与并发的 `sendall` 抢同一个 fd。
    现场：服务端日志里出现 `[ws] 客户端 1 坏帧: client frame must be masked`，
    而客户端发的帧**都是** `encode_frame_masked` 的 —— 那只可能是**半帧**：
    `sendall` 被超时切换打断，服务端把后半截当成新帧头，掩码位自然是 0。
    半帧再往下就是「whoami 丢了、you 一直是 null」，而客户端这边**看不出任何异常**。
    ⇒ 值不变就一次都不碰它（读线程固定 1.0 s，实际只在第一帧设一次）。
  """
    if sock.gettimeout() != timeout:
        sock.settimeout(timeout)
    buf = b""
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c:
            raise RuntimeError("连接在读到 %d/%d 字节时关闭" % (len(buf), n))
        buf += c
    return buf


def _recv_frame(sock, timeout=5.0):
    """收一帧（复用 ws.read_frame；注意那是服务端视角的函数，
    客户端收到的帧**没有掩码**，所以这里自己解）"""
    import struct
    h = _recv_exact(sock, 2, timeout)
    b0, b1 = h[0], h[1]
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", _recv_exact(sock, 2, timeout))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", _recv_exact(sock, 8, timeout))[0]
    data = _recv_exact(sock, ln, timeout) if ln else b""
    return b0 & 0x0F, data


def ws_encode(obj):
    """把一个 dict 编成**带掩码**的客户端帧（测试客户端只发，不发大帧）"""
    import ws as _ws
    return _ws.encode_frame_masked(json.dumps(obj).encode("utf-8"))


class _Reader:
    """一个连接配一个**持续读线程**：只记「you 握手」与「我那个实体的最新位置」。

    ★★ 为什么必须持续读：这是 30 Hz 的流，「睡一会儿再读」会在内核缓冲里积压几十帧
      ⇒ 读到的仍是**旧位置**（假红：「A 按右时 B 也动了」「B 按上时 A 也动了」）。
      想靠「多读几帧」排空也不行 —— 读的是积压队列的**前**几帧，不是后几帧。
      想靠「短超时循环」排空更糟：`_recv_frame` 不可重启，读一半超时会把流读歪
      （实测 `ValueError: not enough values to unpack` / `WinError 10054`）。
      ⇒ 唯一稳的做法就是**一直读**（这也正是真实客户端做的事）。
    """

    def __init__(self, sock, whoami=True):
        self.sock = sock
        self.you = None
        self.slot = 0
        self.latest = None
        self.frames = 0
        self.last_ids = set()      # 最新一帧里出现的 id 集合（B25 要查「两个角色都在同一帧」）
        self.last_p = {}           # id → prefab（B25 要判「两个角色都是 wilson」）
        self.busy = False          # P21：同一个会话 key 已在别处连接（服务端拒绝给角色）
        self.you_null = 0           # P49：服务端回了多少次 `you: null`（= 角色还没建出来）
        self.alive = True
        self.err = None
        self.th = threading.Thread(target=self._run, daemon=True)
        self.th.start()
        # ★★ P20：连上就**拉取**「我是谁」（服务端不再推送）——
        #   这是唯一可靠的时序：问一次、拿到为止（玩家是模拟线程异步建的）。
        if whoami:
            self.ask()

    def _run(self):
        while self.alive:
            try:
                _op, d = _recv_frame(self.sock, 1.0)
            except socket.timeout:
                continue
            except OSError as e:
                # ★★ 连接断了**必须记下来**（2026-10-20，P49）。
                #   原来这里是 `except (socket.timeout, OSError): continue` —— 两者一起吞。
                #   后果：socket 已经被对端关掉时，recv 循环会立刻抛 OSError、立刻 continue，
                #   空转 30 Hz × N 秒，而 `err` 一直是 None。于是判据报出来的是
                #   「没收到 you 握手（None / None）」——「连接断了」和「服务端还没回」
                #   长得**一模一样**，查的人只能猜。实测 B26 偶发红时就是这个文本，
                #   单跑 3 轮又全过，靠的就是这条假象把人绕进去。
                #   ⇒ 断线要吵：记 err 并退出线程（timeout 仍然 continue，那是正常的）。
                if self.alive:
                    self.err = "%s: %s" % (type(e).__name__, e)
                return
            except Exception as e:                                   # noqa: BLE001
                self.err = "%s: %s" % (type(e).__name__, e)
                return
            try:
                m = json.loads(d.decode("utf-8"))
            except Exception:                                        # noqa: BLE001
                continue
            if not isinstance(m, dict):
                continue
            if "you" in m:
                if m.get("busy"):
                    self.busy = True
                    self.you_null += 1
                    continue
                # ★★ 服务端在「玩家还没建出来」时**如实回 null** —— 这时**不能** int(None)：
                #   第一版就是这么写的，异常直接把读线程**整条打死**（而症状是
                #   `没收到 you 握手（err=None）`：err 还没赋值线程就没了）。
                # ★ P49：null 也要**记数并记下服务端给的 slot** —— B26 的偶发红就是
                #   「帧一直在流（frames=193）、you 永远是 None」，光看 you 分不清
                #   「服务端没建出角色」和「服务端根本没看到我这条连接」。slot 一摆出来就清楚了。
                self.slot = int(m.get("slot", self.slot))
                if m["you"] is not None:
                    self.you = int(m["you"])
                else:
                    self.you_null += 1
                continue
            if "ents" in m:
                self.frames += 1
                self.last_ids = set(e["id"] for e in m["ents"])
                self.last_p = dict((e["id"], e.get("p")) for e in m["ents"])
                for e in m["ents"]:
                    if e["id"] == self.you:
                        self.latest = (e["x"], e["z"])

    def wait_you(self, timeout=5.0):
        end = time.time() + timeout
        while time.time() < end and self.you is None:
            time.sleep(0.02)
        return self.you

    def wait_pos(self, timeout=2.0):
        end = time.time() + timeout
        while time.time() < end and self.latest is None:
            time.sleep(0.02)
        return self.latest

    def ask(self, tries=30, gap=0.2):
        """再问一轮「我是谁」（服务端回 null 说明玩家还没建好）"""
        for _ in range(tries):
            if self.you is not None:
                return self.you
            try:
                self.sock.sendall(ws_encode({"cmd": "whoami"}))
            except OSError:
                return None
            time.sleep(gap)
        return self.you

    def stop(self):
        self.alive = False
        try:
            self.th.join(timeout=1.5)
        except Exception:                                            # noqa: BLE001
            pass


def _recv_snap(sock, timeout=5.0, tries=200):
    """读到一条**真快照**为止 —— 跳过 `you` 握手 / `pong` 这类**控制消息**。

    ★★ P20 起服务端连上就先发 `{"you":guid,"slot":n}`；pong 也在同一条流里。
      任何「读下一条消息就当快照」的老写法都会踩到它们（实测：B2 报「帧缺字段 t」、
      B3 的基线读成了握手、B8 报「opcode=1」）。
      ⇒ 这里显式跳过控制消息，**而不是把断言放松** —— 放松等于让它们不再检查
        真正该检查的东西（那是本工程最防的「假绿」）。
    """
    for _ in range(tries):
        op, d = _recv_frame(sock, timeout)
        try:
            m = json.loads(d.decode("utf-8"))
        except Exception:                                        # noqa: BLE001
            continue                     # 二进制帧在文本路径里解不出来 ⇒ 跳过
        if isinstance(m, dict) and "ents" in m:
            return op, m
    raise RuntimeError("%d 条消息里没有真快照" % tries)


def _connect():
    import ws
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    ws.client_handshake(sock, "127.0.0.1:%d" % PORT)
    return sock


def b2_frames_arrive():
    import ws
    sock = _connect()
    try:
        op, s = _recv_snap(sock)
        if op != ws.OP_TEXT:
            return False, "首帧不是文本帧（opcode=%d）" % op
        for k in ("t", "tick", "ents"):
            if k not in s:
                return False, "帧缺字段 %s" % k
        if not s["ents"]:
            return False, "帧里没有实体"
        # 再收一帧，t 应更大（世界在走）
        t0 = s["t"]
        for _ in range(20):
            _op, s2 = _recv_snap(sock)
            if s2["t"] > t0:
                return True, "收到帧（n=%d，t %.2f → %.2f，世界在走）" % (
                    s2["n"], t0, s2["t"])
        return False, "连续 20 帧时间里 t 没有增长"
    finally:
        sock.close()


def b3_input_over_ws():
    """★ 跨进程的核心：从 WS 发输入 ⇒ **我自己那个角色**的位置变化。

    ★★ P20 之后不能再看帧里的 `player` 字段了：它指的是**槽位 0** 的角色，
      而「第一个连上的连接」才拿槽位 0（B2 已经用掉了）⇒ 本用例拿的是槽位 1。
      ⇒ 用 `you` 握手给的 guid 去帧里查**自己**的位置（这也更贴近真实客户端）。
    ★★ 位置必须由**持续读线程**给：睡 2 s 再读只会读到积压里的旧帧。
    """
    import ws
    sock = _connect()
    rd = _Reader(sock)
    try:
        if rd.wait_you(5.0) is None:
            return False, "没收到 you 握手（err=%s）" % rd.err
        p0 = rd.wait_pos(2.0)
        if p0 is None:
            return False, "帧里找不到自己的角色 guid=%s（收到 %d 帧）" % (rd.you, rd.frames)
        x0 = p0[0]
        sock.sendall(ws.encode_frame_masked(
            json.dumps({"k": "right", "v": 1}).encode("utf-8")))
        time.sleep(2.0)
        sock.sendall(ws.encode_frame_masked(
            json.dumps({"k": "right", "v": 0}).encode("utf-8")))
        time.sleep(0.3)
        x1 = rd.latest[0]
        dx = x1 - x0
        if dx <= 0.2:
            return False, "通过 WS 发输入后 x 只变了 %.3f" % dx
        return True, "WS 输入生效（槽%d）：自己的 x %+.3f（%.2f → %.2f）" % (
            rd.slot, dx, x0, x1)
    finally:
        rd.stop()
        sock.close()


def b4_bad_json_survives():
    """★ 反向：坏 JSON 不得让服务端崩"""
    import ws, urllib.request
    sock = _connect()
    try:
        sock.sendall(ws.encode_frame_masked(b"{ this is not json"))
        time.sleep(0.4)
    finally:
        sock.close()
    # 服务端还活着吗？
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/healthz" % PORT, timeout=5) as r:
            h = json.loads(r.read().decode("utf-8"))
    except Exception as e:                                        # noqa: BLE001
        return False, "坏帧之后服务端不可用了: %s" % e
    if h.get("dropped_bad_frames", 0) < 1:
        return False, "坏帧没被计数（说明被静默吞了）"
    return True, "服务端存活，坏帧计数=%d ✔" % h["dropped_bad_frames"]


def b5_bad_masking_rejected():
    """★ 反向：不带掩码的客户端帧必须被拒（RFC 6455 §5.1）"""
    sock = _connect()
    try:
        # ★ 先排空连接后**已经在路上**的帧，否则下面 recv 收到的是那些帧，
        #   会把「服务端拒帧」误判成「帧被接受了」——第一版就是这么错的。
        # ★★ 必须**限时限次**：服务端 30 Hz 一直在发帧，用「直到超时」当条件
        #   会永远排不完 —— 第一版就是这么把自己挂死的（跑测试时整体超时被 SIGTERM）。
        sock.settimeout(0.2)
        drained, t_end = 0, time.time() + 0.8
        while time.time() < t_end and drained < 40:
            try:
                if not sock.recv(65536):
                    break
                drained += 1
            except OSError:
                break
        # 手工构造一个**未掩码**的文本帧（协议违规，RFC 6455 §5.1）
        payload = b'{"k":"right","v":1}'
        frame = bytes([0x81, len(payload)]) + payload
        sock.sendall(frame)
        # 服务端应当断开连接
        time.sleep(0.5)
        sock.settimeout(2.0)
        try:
            data = sock.recv(64)
        except OSError:
            data = b""
        if data == b"":
            return True, "未掩码帧被拒并断连 ✔（排空了 %d 帧后判定的）" % drained
        return False, "未掩码帧被接受了（协议违规未拦截）"
    finally:
        try:
            sock.close()
        except OSError:
            pass


def b6_healthz():
    import urllib.request
    with urllib.request.urlopen("http://127.0.0.1:%d/healthz" % PORT, timeout=5) as r:
        h = json.loads(r.read().decode("utf-8"))
    st = h.get("stats", {})
    if not h.get("ok") or st.get("tick", 0) <= 0:
        return False, "healthz 异常: %s" % h
    # ★★ 模型版本必须**报出来、而且与 rt_boot.lua 里写的那个字面量一致**（2026-10-16 加）。
    #   为什么值得写进判据：此前 `M.version()` 有定义、**没有任何调用者** ——
    #   「发布记录里那一版」与「跑着的这一版」只能靠人记；而人对不上时会说「应该一样吧」。
    #   这里做**跨文件语义核对**（与本工程 B22 的动画名三方一致同一手法）：
    #   改了一处忘了另一处 ⇒ 立刻红，而不是等发布时才发现记录是假的。
    boot = st.get("boot")
    if not boot or not re.match(r"^rt_boot/\d+$", str(boot)):
        return False, "/healthz 未报出模型版本（got %r）—— M.version() 又变成没人调用了吗" % boot
    src = io.open(os.path.join(RT, "rt_boot.lua"), encoding="utf-8").read()
    # ★ **行首锚定**：只认真正那一行 `function M.version() return "..."`。
    #   不锚行首的话，注释里引用同一句就会被当成真定义 ——
    #   本工程在「按子串找、不问这段文本是什么身份」上翻过车（一次插坏整个文件）。
    m = re.search(r'^\s*function\s+M\.version\(\)\s*return\s*"([^"]+)"', src, re.M)
    if not m:
        return False, "在 rt_boot.lua 里找不到 M.version() 的字面量（判据锚点失效）"
    if m.group(1) != boot:
        return False, "版本不一致：/healthz 报 %s，rt_boot.lua 写 %s（改了一处漏了另一处）" % (boot, m.group(1))
    # ★ 状态页也必须**真的**显示出来。模板里加一行容易、忘了加替换就会留在 `?` 上 ——
    #   那是「词在≠行为在」的典型：页面上有「模型版本」四个字，值却永远是问号。
    with urllib.request.urlopen("http://127.0.0.1:%d/status" % PORT, timeout=5) as r:
        html = r.read().decode("utf-8")
    if boot not in html:
        return False, "/status 页面上看不到模型版本 %s（模板加了行但漏了替换？）" % boot
    # ★★ 玩家生死必须能看见（2026-10-16 加）。为什么它值得守在 /healthz 上：
    #   查「树为什么砍不倒」时发现玩家会在世界开始约 12 s 后**掉血致死**，
    #   死后状态机停在 `death`、**`act` 再也推不动任何动作，但 push 依旧返回成功**
    #   ⇒ 症状是「世界安静地不动了」，日志里一个字都没有（最坏的失败形态）。
    #   ⇒ 现在 `player_alive` 必须出现在健康检查里（判据守着它，防止哪天被删掉）。
    if "player_alive" not in st:
        return False, "/healthz 没报 player_alive —— 玩家死了却看不出来（失败必须吵）"
    return True, "tick=%d t=%.1fs 实体=%d · 模型 %s（源文件一致 · /status 也显示 · 玩家存活=%s）" % (
        st["tick"], st["time"], st["n_ents"], boot, st.get("player_alive"))


def b7_http_client():
    import urllib.request
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/client.html" % PORT, timeout=5) as r:
            body = r.read()
        return True, "client.html 可取（%d 字节）" % len(body)
    except Exception as e:                                        # noqa: BLE001
        return False, "取不到 client.html: %s（P2 才做，P1 可接受）" % e


def _http_get(path, timeout=5):
    import urllib.request
    with urllib.request.urlopen("http://127.0.0.1:%d%s" % (PORT, path), timeout=timeout) as r:
        return r.status, r.read().decode("utf-8")


def b16_pause_ws():
    """★ P3「暂停」：世界时间停住，但**连接与发帧继续**。

       为什么「继续发帧」是必须的：不发的话客户端收不到任何东西，
       会显示「已断开，重连中…」——那是**误报**，而误报会训练人忽略它。
    """
    import ws as wsmod
    sock = _connect()
    try:
        for _ in range(6):
            _recv_snap(sock)
        sock.sendall(wsmod.encode_frame_masked(json.dumps({"cmd": "pause", "v": 1}).encode()))
        # ★ 先让「暂停」生效并冲掉在途的帧，再开始观察 ——
        #   刚发完指令就取样会把**暂停前**那一两帧算进来，
        #   于是「t 还在涨」是**采样方式**的问题，不是暂停没生效。
        #   第一版就是这么写的，然后假红了一次（t 差了一个 tick：13.9000 → 13.9333）。
        time.sleep(0.5)
        deadline = time.time() + 2.0
        ts, n, last = [], 0, None
        while time.time() < deadline:
            _, last = _recv_snap(sock)
            ts.append(last["t"])
            n += 1
        if n < 3:
            return False, "暂停后 2 s 内只收到 %d 帧（客户端会误报断线）" % n
        # ★ 判据是「**观察窗口内 t 恒定**」，不是「t 等于发指令前那一刻的值」
        if max(ts) - min(ts) > 1e-9:
            return False, "暂停后窗口内 t 仍在涨：%.4f → %.4f（%d 帧）" % (min(ts), max(ts), n)
        if not last.get("paused"):
            return False, "帧里没有如实报 paused"
        _, body = _http_get("/healthz")
        if not json.loads(body).get("paused"):
            return False, "/healthz 没报 paused"
        # 恢复
        sock.sendall(wsmod.encode_frame_masked(json.dumps({"cmd": "pause", "v": 0}).encode()))
        deadline = time.time() + 2.0
        t1 = None
        m_paused = "（没收到帧）"
        while time.time() < deadline:
            _, m = _recv_snap(sock)
            t1 = m["t"]
            m_paused = m.get("paused")
        if t1 is None or t1 <= last["t"]:
            return False, "恢复后 t 没涨（%s）" % t1
        # ★ 恢复方向也要**明确**报 `paused=false`（2026-10-16 补）：
        #   原来只验了「暂停时帧里报 true」，没验「恢复后必须报 false」——
        #   若某天那条赋值被删掉，字段会**消失**，而「字段缺失」与「没暂停」
        #   在客户端读起来是同一个意思（`typeof f.paused === 'boolean'` 才更新镜像）
        #   ⇒ 界面会一直显示「⏸ 已暂停」。这类**符号消失**只能靠显式断言抓住。
        if m_paused is not False:
            return False, "恢复之后帧里的 paused 不是明确的 false（实得 %r）" % (m_paused,)
        return True, "暂停 2 s：t 恒为 %.2f 且仍收到 %d 帧（不误报断线）→ 恢复后涨到 %.2f" % (
            last["t"], n, t1)
    finally:
        # ★ 兜底：无论成功失败都把世界解冻 —— 否则后面所有测试都会在「世界停着」上跑，
        #   而且症状是「时间不涨」这种看起来像引擎坏了的东西。
        try:
            import urllib.request
            urllib.request.urlopen("http://127.0.0.1:%d/pause?on=0" % PORT, timeout=3).read()
        except Exception:                                        # noqa: BLE001
            pass
        sock.close()


def b17_pause_http_and_bad_value():
    """★ `/pause` 的 HTTP 通道 + **反向**：取值不认就必须明确回绝。

       为什么这条重要：如果实现是「不认就当成 true」，一个拼错的 `?on=ture`
       会把世界**悄悄冻住**（画面静止，但连接正常、帧照发）——
       这种症状排查起来非常贵（看起来像「引擎卡死」）。
    """
    st, body = _http_get("/pause?on=1")
    if st != 200 or not json.loads(body)["paused"]:
        return False, "on=1 没生效: %s %s" % (st, body)
    # 反向：不认的取值必须 400 **且不改状态**
    ok400 = False
    try:
        _http_get("/pause?on=ture")
    except Exception as e:                                       # noqa: BLE001
        ok400 = "400" in str(e)
    if not ok400:
        return False, "非法取值没有回 400（可能被当成了 true）"
    st, body = _http_get("/healthz")
    if not json.loads(body).get("paused"):
        return False, "非法取值把暂停状态改掉了（应保持暂停）"
    # 恢复
    st, body = _http_get("/pause?on=0")
    if st != 200 or json.loads(body)["paused"]:
        return False, "on=0 没生效: %s %s" % (st, body)
    return True, "on=1 → 暂停；on=ture → 400 且状态不变；on=0 → 恢复 ✔"


def b18_replay_roundtrip():
    """★★ M7：录一段 → 回放 ⇒ **逐 tick 指纹全同**。"""
    rec_sim = Sim(seed=20261016, tick_hz=30).boot()
    rec_sim.set_input("right", True)
    for _ in range(90):
        rec_sim.step()
    rec_sim.set_input("right", False)
    rec_sim.set_input("down", True)
    for _ in range(60):
        rec_sim.step()
    rec_sim.set_input("down", False)
    for _ in range(30):
        rec_sim.step()
    rec = rec_sim.dump_recording()
    p = rec_sim.snapshot()["player"]
    if rec["ticks"] != 180 or len(rec["events"]) < 3:
        return False, "录像内容不对：ticks=%s events=%s" % (rec["ticks"], rec["events"])
    if rec["truncated"]:
        return False, "180 tick 不该被截断"
    sim2 = Sim(seed=20261016, tick_hz=30).boot()
    tick, want, got, near = sim2.replay(rec)
    if tick is not None:
        return False, "回放不一致 @tick %d（期望 %s 实得 %s；%s）" % (tick, want, got, near)
    if sim2.hashes != rec["hashes"]:
        return False, "指纹列表不同：%d vs %d" % (len(sim2.hashes), len(rec["hashes"]))
    return True, "180 tick 逐 tick 指纹全同（%d 个输入事件；末帧 x=%.2f z=%.2f）" % (
        len(rec["events"]), p["x"], p["z"])


def b19_replay_tamper_rejected():
    """★★ 反向：录像被人为改动 ⇒ 回放**必须**报不一致，并且**定位到 tick**。

       三种篡改各证明一件事：
         ① 改**事件值**（右→不按）⇒ 世界从一开始就不同 ⇒ 必须第 1 tick 就分叉；
         ② 改**事件时间戳**（60 → 10）⇒ 必须**从挪动处之后**分叉（而不是「整条都对不上」）；
         ③ 只改**指纹表第 30 项**（世界本身完全一样）⇒ 必须第 31 tick 分叉 ——
            ★ 这条最关键：它证明比的是**逐 tick**，而不是「只看最后一帧」。
              只看末帧的实现，在 ①②③ 里 ③ 是发现不了的。
    """
    mk = Sim(seed=20261016, tick_hz=30).boot()
    mk.set_input("right", True)          # 事件 0：第 0 tick 按下
    for _ in range(40):
        mk.step()
    mk.set_input("right", False)         # 事件 1：第 40 tick 松开（**必须有第 2 个事件**，
    for _ in range(20):                  #   否则下面「挪动事件时间戳」那条无从下手）
        mk.step()
    rec = mk.dump_recording()
    if rec["ticks"] != 60 or len(rec["events"]) != 2:
        return False, "录像应为 60 tick / 2 个事件，实际 %s tick / %s" % (
            rec["ticks"], rec["events"])

    bad1 = json.loads(json.dumps(rec))
    bad1["events"][0][2] = 0                     # 按下 → 不按
    t1, w1, g1, _ = Sim(seed=20261016, tick_hz=30).boot().replay(bad1)
    # ★ 为什么不是第 1 tick：locomotor 的 `StartUpdatingInternal()` 让**第一个 tick 不动**
    #   （原版行为，实测 tick1 位移 0.000、tick2 起每 tick 0.200）。所以「第 1 个输入事件被改」
    #   最早只能在**第 2 tick** 被观察到。刻舟求剑地要求「第 1 tick」是**判据写错**，不是缺陷。
    if t1 != 2:
        return False, "① 事件值被改后应在第 2 tick 分叉（locomotor 首 tick 不动），实际 %s" % t1

    bad2 = json.loads(json.dumps(rec))
    bad2["events"][1] = [10, "right", 0]         # 松开从第 40 tick 挪到第 10 tick
    t2, w2, g2, _ = Sim(seed=20261016, tick_hz=30).boot().replay(bad2)
    # 松开提前 ⇒ 从第 11 tick 起位置就少了 ⇒ **必须**在第 11 tick 分叉（而不是第 1 或第 41）
    if t2 != 11:
        return False, "② 事件挪到第 10 tick 后应在第 11 tick 分叉，实际 %s" % t2

    bad3 = json.loads(json.dumps(rec))
    bad3["hashes"][30] = (bad3["hashes"][30] + 1) % 4294967296
    t3, w3, g3, _ = Sim(seed=20261016, tick_hz=30).boot().replay(bad3)
    if t3 != 31:
        return False, "③ 指纹表第 30 项被改应在第 31 tick 分叉，实际 %s（只看末帧的实现会漏掉这条）" % t3

    return True, "三种篡改全被抓到且**定位准确**：事件值→第 2 tick、事件时间戳→第 11 tick、指纹表→第 31 tick"


def b20_replay_cli():
    """★ 用户真正会走的路径：`--replay` 命令的**退出码**与拒绝逻辑。"""
    rec_sim = Sim(seed=20261017, tick_hz=30).boot()
    rec_sim.set_input("left", True)
    for _ in range(45):
        rec_sim.step()
    rec_sim.set_input("left", False)
    for _ in range(15):
        rec_sim.step()
    path = os.path.join(RT, "_replay_test.json")
    rec_sim.save_recording(path)
    try:
        # ① 正确种子 ⇒ 一致，退出码 0
        r = subprocess.run([sys.executable, os.path.join(RT, "server.py"),
                            "--replay", path, "--seed", "20261017", "--quiet"],
                           capture_output=True, text=True, cwd=RT, timeout=180)
        if r.returncode != 0 or "✔" not in r.stdout:
            return False, "同种子回放应一致且退出 0，实际 rc=%s\n%s" % (r.returncode, r.stdout[-400:])
        # ② 种子不符 ⇒ **拒绝**（退出码 2），并且**不能**报「一致」
        r2 = subprocess.run([sys.executable, os.path.join(RT, "server.py"),
                             "--replay", path, "--seed", "12345", "--quiet"],
                            capture_output=True, text=True, cwd=RT, timeout=180)
        if r2.returncode != 2:
            return False, "种子不符应拒绝（退出 2），实际 rc=%s" % r2.returncode
        if "✔" in r2.stdout:
            return False, "种子不符却报了「一致」"
        # ③ 文件不存在 ⇒ 明确报错，退出 2
        r3 = subprocess.run([sys.executable, os.path.join(RT, "server.py"),
                             "--replay", os.path.join(RT, "_nope.json"), "--seed", "1", "--quiet"],
                            capture_output=True, text=True, cwd=RT, timeout=120)
        if r3.returncode != 2:
            return False, "录像不存在应退出 2，实际 rc=%s" % r3.returncode
    finally:
        if os.path.exists(path):
            os.remove(path)
        if os.path.exists(path + ".tmp"):
            os.remove(path + ".tmp")
    return True, "同种子 → rc=0 且报一致；种子不符 / 文件不存在 → rc=2 且**不**报一致 ✔"


def b21_record_survives_hard_kill():
    """★★ 录像必须**挺过「进程被硬杀」** —— 因为 `deploy/stop.sh` 就是这么停服的。

       ★ 为什么必须单独测这条：落盘有**两条路**（周期落盘 / 收尾落盘）。
         只测「优雅退出」的话，生产上（Windows `taskkill /F` 硬杀，收不到信号、
         走不到 `finally`）**一个字节都不会有** —— 而且没人会知道，直到真的要用录像。
       判据：起服务端 → 发脚本化输入 → **硬杀** → 录像文件必须存在、非空，
       并且能被 `--replay` **一致地**放出来（只比已记录的那一段，允许尾部缺一点）。
    """
    import tempfile
    import ws as wsmod
    rec = os.path.join(tempfile.gettempdir(), "rt_b21_rec.json")
    for p in (rec, rec + ".tmp"):
        if os.path.exists(p):
            os.remove(p)
    port = PORT + 7
    proc = subprocess.Popen(
        [sys.executable, os.path.join(RT, "server.py"),
         "--port", str(port), "--hz", "30", "--seed", "20261020", "--quiet",
         "--record", rec],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=RT, text=True)
    try:
        # 等端口可用
        started = False
        for _ in range(120):
            if proc.poll() is not None:
                return False, "服务端启动即退出:\n%s" % (proc.stdout.read() or "")[:400]
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    started = True
                    break
            except OSError:
                time.sleep(0.1)
        if not started:
            return False, "服务端 12 s 内未监听"
        import ws
        sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        ws.client_handshake(sock, "127.0.0.1:%d" % port)
        for k, v, ms in (("right", 1, 700), ("right", 0, 300), ("up", 1, 700), ("up", 0, 300)):
            sock.sendall(wsmod.encode_frame_masked(
                json.dumps({"k": k, "v": v}).encode("utf-8")))
            time.sleep(ms / 1000.0)
        sock.close()
        # ★ 再等一个落盘周期（RECORD_FLUSH_SEC=5），确保周期落盘至少跑过一次 ——
        #   然后**硬杀**（模拟 taskkill /F）
        time.sleep(6.5)
    finally:
        proc.kill()
        try:
            proc.wait(timeout=5)
        except Exception:                                        # noqa: BLE001
            pass
    if not os.path.isfile(rec):
        return False, "硬杀之后**录像文件不存在** —— 收尾写没机会跑，周期写也没跑？"
    with io.open(rec, encoding="utf-8") as f:
        data = json.load(f)
    if not data.get("hashes") or not data.get("events"):
        return False, "录像内容为空：ticks=%s events=%s" % (
            len(data.get("hashes") or []), len(data.get("events") or []))
    # 回放它（只比已记录的部分）—— 必须一致
    sim = Sim(seed=20261020, tick_hz=30).boot()
    tick, want, got, near = sim.replay(data)
    if tick is not None:
        return False, "硬杀后写出的录像回放不一致 @tick %d（%s vs %s）" % (tick, want, got)
    return True, "硬杀后录像仍在：%d tick / %d 事件，且回放**逐 tick 一致**（尾部可能缺 ≤5 s）" % (
        len(data["hashes"]), len(data["events"]))


def _connect_ws_slot(timeout=6.0):
    """连接并读第一条消息。服务端连上就先发 `{"you":guid,"slot":n}`。

    返回 `(sock, guid, slot)`。
    """
    import ws as wsmod
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
    wsmod.client_handshake(sock, "127.0.0.1:%d" % PORT)
    # ★★ 拉取式握手（见 _Reader 的注释）：主动问，问到为止
    deadline = time.time() + timeout
    seen = 0
    while time.time() < deadline:
        sock.sendall(ws_encode({"cmd": "whoami"}))
        for _ in range(20):
            _op, d = _recv_frame(sock, timeout)
            try:
                m = json.loads(d.decode("utf-8"))
            except Exception:                                    # noqa: BLE001
                continue
            if "you" in m and m["you"] is not None:
                return sock, int(m["you"]), int(m.get("slot", 0))
            seen += 1
    raise RuntimeError("没问到 you（期间收到 %d 条其它消息）" % seen)


def _frame_ents(sock, fresh=3):
    """读到一条**带 ents** 的帧（跳过 you/pong 这类控制消息），并**多读几条取最新**。

    ★★ 为什么要 `fresh`：客户端连上时服务端**立刻**发一帧 hello ——
      而「给这个连接建玩家」是在模拟线程里稍后完成的 ⇒ 那一帧里**还没有我**。
      第一版只读一条快照就断言「找不到自己的 guid」（实测就是这么假红的）。

    ⚠️ 它只适合「**刚连上**就要一帧」的场景。对**闲置过**的 socket 用它会读到
      积压队列的**前**几帧：B25 曾用它（fresh=3）去查「两个角色在同一帧」，
      而 A 的 socket 在 B 握手期间没人读、积压几十帧 ⇒ 偶发假红
      「帧里找不到这两个 guid（57 / 60）」。要「最新一帧」必须用 `_Reader`
      （持续读线程，`last_ids` 永远是队尾）。
    """
    last = None
    for _ in range(200):
        _op, d = _recv_frame(sock)
        try:
            m = json.loads(d.decode("utf-8"))
        except Exception:                                        # noqa: BLE001
            continue
        if isinstance(m, dict) and "ents" in m:
            last = m
            fresh -= 1
            if fresh <= 0:
                return last
    if last is None:
        raise RuntimeError("200 帧里没有真快照")
    return last


def _ent_of(frame, guid):
    for e in frame["ents"]:
        if e["id"] == guid:
            return e
    return None


def _latest_ent(sock, guid, frames=4):
    """**排空积压**后返回最新一帧里某个实体的 (x, z)。

    ★★ 为什么需要它：测试里常有「发输入 → time.sleep(1.2) → 再读帧」的写法，
      而 1.2 s 不读会让 socket 里积压 ~36 帧（30 Hz）⇒ 只读一两条拿到的是
      **1.2 秒前**的位置。第一版就是因此报「B 按上时 A 也动了 2.2」——
      那 2.2 其实是 A **上一阶段**的残余位移，被当成「B 的输入影响了 A」。
      ⇒ 判据本身没错，错的是**取样**。取样必须取**最新**的，而不是「下一条」。

    ★ 但**不能**用「短超时循环」去排空：`_recv_frame` 不可重启 ——
      读完帧头、还没读完帧体时超时，流就被读歪了，之后全乱
      （实测报 `ValueError: not enough values to unpack`）。
      ⇒ 固定读 N 帧（30 Hz 下 4 帧 ≈ 0.13 s，足够新），不依赖超时。
    """
    newest = None
    for _ in range(frames):
        _op, d = _recv_frame(sock, 5.0)
        try:
            m = json.loads(d.decode("utf-8"))
        except Exception:                                        # noqa: BLE001
            continue
        if isinstance(m, dict) and "ents" in m:
            e = _ent_of(m, guid)
            if e is not None:
                newest = (e["x"], e["z"])
    return newest


def b25_每个客户端有自己的角色():
    """★★ P20：每个连接一个**独立角色** —— 在此之前四个客户端共用同一个 wilson。

       判据：① 两个连接拿到的 `you` **不同**；② 两个 guid 在**同一帧**里都是实体；
             ③ 两个槽位不同；④ 断开后那个槽位被回收（下一个连接复用）。

       ★★ P45d（2026-10-20）：这一条曾在全量里**偶发假红** —— 报
          「帧里找不到这两个 guid（57 / 60）」。根因不是产品，是**取帧方式**：
          旧写法 `_frame_ents(a, fresh=3)` 是「再读 3 帧」，可 A 这个 socket 在
          B 握手期间**没人读**，内核缓冲里积压了十几帧 ⇒ 读 3 帧还停在 B 出生**之前**。
          积压多少取决于 B 握手花了多久（6 s 超时内浮动）⇒ 典型的时间依赖假红。
          现在与 B26 同用一套：**每个连接一个持续读线程**（`_Reader`），
          判据改成「等到 A 的**最新**一帧里同时出现两个 guid」（5 s 上限）。
          比「多读几帧」强的地方：它读的是**队尾**，不是队头。
    """
    ra = rb = rc = None
    sa = sb = sc = None
    try:
        sa = _connect()
        ra = _Reader(sa)
        if ra.wait_you(5.0) is None:
            return False, "A 没收到 you 握手（err=%s）" % ra.err
        you_a, slot_a = ra.you, ra.slot

        sb = _connect()
        rb = _Reader(sb)
        if rb.wait_you(5.0) is None:
            return False, "B 没收到 you 握手（err=%s）" % rb.err
        you_b, slot_b = rb.you, rb.slot

        if you_a == you_b:
            return False, "两个客户端拿到**同一个**实体 guid（%s）—— 还是共用一个角色" % you_a
        if slot_a == slot_b:
            return False, "两个客户端拿到同一个槽位 %d" % slot_a

        # ② 两个 guid 必须在**同一帧**里 —— 等 A 的读线程把积压排到队尾
        end = time.time() + 5.0
        while time.time() < end:
            if ra.err or rb.err:
                return False, "读线程挂了：%s / %s" % (ra.err, rb.err)
            if you_a in ra.last_ids and you_b in ra.last_ids:
                break
            time.sleep(0.02)
        else:
            return False, ("5 s 内 A 的帧里没同时出现两个 guid（%s / %s）——"
                           "frames=%d，最近一帧 %d 个实体"
                           % (you_a, you_b, ra.frames, len(ra.last_ids)))

        pa, pb = ra.last_p.get(you_a), ra.last_p.get(you_b)
        if pa != "wilson" or pb != "wilson":
            return False, "两个角色不都是 wilson：%s / %s" % (pa, pb)

        # ④ 断开 B ⇒ 槽位回收，下一个连接应复用它（且是**新角色**）
        rb.stop()
        rb = None
        sb.close()
        sb = None
        time.sleep(0.6)
        sc = _connect()
        rc = _Reader(sc)
        if rc.wait_you(5.0) is None:
            return False, "断开 B 后的新连接没收到 you 握手（err=%s）" % rc.err
        if rc.slot != slot_b:
            return False, "断开后槽位没被回收（应复用 %d，实得 %d）" % (slot_b, rc.slot)
        if rc.you == you_b:
            return False, "复用了槽位却没建新角色（guid 仍是 %s）" % you_b
        return True, ("A(槽%d,guid%d) / B(槽%d,guid%d) 是两个独立角色（同一帧里都在）；"
                      "B 断开后槽位被复用（C=槽%d,guid%d）"
                      % (slot_a, you_a, slot_b, you_b, rc.slot, rc.you))
    finally:
        for r in (ra, rb, rc):
            if r is not None:
                try:
                    r.stop()
                except Exception:                                # noqa: BLE001
                    pass
        for s_ in (sa, sb, sc):
            if s_ is not None:
                try:
                    s_.close()
                except Exception:                                # noqa: BLE001
                    pass


def b26_输入互不干扰():
    """★★★ P20 的**核心判据**：一个客户端的输入只能动**它自己**的角色。

       ★ 判据只测**隔离性**（不依赖地形走不走得动）：
         ① A 按右、**B 完全不动** ⇒ B 的位置必须一点不变；
         ② 反过来：B 按上、A 不动 ⇒ A 的位置必须一点不变；
         ③ 两人同时各按一个方向 ⇒ A 不许出现在 z 轴上、B 不许出现在 x 轴上。
       ① 之所以能抓到「共用一个角色」：那时两人 guid 相同，A 的输入会让 B 一起动。
       ★ 位置全部来自**持续读线程** —— 「睡一会儿再读」只会读到积压的旧帧（实测假红）。
    """
    import ws as wsmod
    sa = sb = None
    ra = rb = None
    try:
        sa = _connect()
        ra = _Reader(sa)
        sb = _connect()
        rb = _Reader(sb)
        if ra.wait_you(5.0) is None or rb.wait_you(5.0) is None:
            # 报错要把「为什么」带上：err 现在是可信的（断线会置 err），
            # 再加上帧数与 you，才能区分「服务端没回」和「连接断了」
            return False, ("没收到 you 握手（A: you=%s slot=%s null×%d frames=%d err=%s / "
                           "B: you=%s slot=%s null×%d frames=%d err=%s）"
                           % (ra.you, ra.slot, ra.you_null, ra.frames, ra.err,
                              rb.you, rb.slot, rb.you_null, rb.frames, rb.err))
        if ra.you == rb.you:
            return False, "两个客户端是同一个角色（guid=%s）" % ra.you
        if ra.wait_pos(2.0) is None or rb.wait_pos(2.0) is None:
            return False, "帧里找不到角色（frames=%d/%d）" % (ra.frames, rb.frames)

        def press(sock, k, v):
            sock.sendall(wsmod.encode_frame_masked(json.dumps({"k": k, "v": v}).encode()))

        def delta(a0, b0, a1, b1):
            return (max(abs(a1[0] - a0[0]), abs(a1[1] - a0[1])),
                    max(abs(b1[0] - b0[0]), abs(b1[1] - b0[1])))

        # ① A 按右、B 不动
        pa0, pb0 = ra.latest, rb.latest
        press(sa, "right", 1)
        time.sleep(1.2)
        press(sa, "right", 0)
        time.sleep(0.4)
        dA, dB = delta(pa0, pb0, ra.latest, rb.latest)
        if dB > 0.05:
            return False, "A 按右时 **B 也动了 %.3f** —— 输入没归因（还是共用角色）" % dB
        if dA <= 0.5:
            return False, "A 按右自己却几乎没动（%.3f）—— 输入没到自己身上" % dA

        # ② 反过来：B 按上、A 不动
        pa2, pb2 = ra.latest, rb.latest
        press(sb, "up", 1)
        time.sleep(1.2)
        press(sb, "up", 0)
        time.sleep(0.4)
        dA2, dB2 = delta(pa2, pb2, ra.latest, rb.latest)
        if dA2 > 0.05:
            return False, "B 按上时 **A 也动了 %.3f** —— 输入没归因" % dA2
        if dB2 <= 0.5:
            return False, "B 按上自己却几乎没动（%.3f）" % dB2

        # ③ 同时各按一个方向：不许跨轴串
        qa0, qb0 = ra.latest, rb.latest
        press(sa, "right", 1)
        press(sb, "up", 1)
        time.sleep(1.2)
        press(sa, "right", 0)
        press(sb, "up", 0)
        time.sleep(0.4)
        dza = abs(ra.latest[1] - qa0[1])
        dxb = abs(rb.latest[0] - qb0[0])
        if dza > 1.0:
            return False, "A 只按了右，却往 z 走了 %.2f（串轴了）" % dza
        if dxb > 1.0:
            return False, "B 只按了上，却往 x 走了 %.2f（串轴了）" % dxb
        return True, ("隔离性成立：A 按右时 B 位移 %.3f、B 按上时 A 位移 %.3f；"
                      "同时操作时 A 的 dz=%.2f、B 的 dx=%.2f（都 <1.0）") % (
            dB, dA2, dza, dxb)
    finally:
        for r in (ra, rb):
            if r is not None:
                r.stop()
        for s_ in (sa, sb):
            if s_ is not None:
                try:
                    s_.close()
                except Exception:                                # noqa: BLE001
                    pass


def b26b_连接号不复用():
    """★★★ P49：**连接号（`cid`）不许复用** —— 它是 `slot_of` 的键。

    现场（B26 偶发红的**真根源**）：`cid` 以前是「在线人数」加一得来的
    （`hub.clients += 1; cid = hub.clients`），而 `clients` 在断开时会**减**。
    于是 A(1) B(2) C(3) 里 **B 走了** ⇒ 人数回到 2 ⇒ 新连接 D 也叫 **3**，而 C 还活着。
    后果链（每一步都静默）：

      D 的 `slot_of[3]` **覆盖**了 C 的 ⇒ C 的槽位映射丢了
      ⇒ C 断开时 `release_slot(3)` 释放的是 **D 的**槽位（D 还连着！）
      ⇒ D 被塞回空闲表 ⇒ 下一个连接 E 拿走同一个槽位
      ⇒ **E 与 D 共用一个身体**（`whoami` 回同一个 guid）—— 正是 B26 报的那句
        「两个客户端是同一个角色（guid=66）」，也正是 B26 里
        `A: you=None slot=1 null×30`（角色被迟到的 remove_player 删掉了）。

    ★ 为什么「槽位被重复分配」那条警报**没响**：旧主人的 `slot_of` 条目已经被覆盖，
      `alloc_slot` 里查 `slot in slot_of.values()` 当然查不到 —— **警报能查的只是症状，
      而真正的病在更上游（号码被复用）**。所以这条判据只能盯**行为**：
      中途有人进出之后，D 与 E 必须**不是同一个角色**。

    ★ 判据不需要看 `cid`（客户端根本看不到），只看「谁顶掉了谁」。
    """
    ra = rb = rc = rd = re_ = None
    sa = sb = sc = sd = se = None
    try:
        sa = _connect(); ra = _Reader(sa)
        sb = _connect(); rb = _Reader(sb)
        sc = _connect(); rc = _Reader(sc)
        for nm, r in (("A", ra), ("B", rb), ("C", rc)):
            if r.wait_you(6.0) is None:
                return False, ("%s 没收到 you 握手（you=%s null×%d frames=%d err=%s）"
                               % (nm, r.you, r.you_null, r.frames, r.err))
        ga, gb, gc = ra.you, rb.you, rc.you
        slot_a, rb_slot, slot_c = ra.slot, rb.slot, rc.slot
        if len({ga, gb, gc}) != 3:
            return False, "前提不成立：三条连接就撞了角色（%s / %s / %s）" % (ga, gb, gc)
        if len({slot_a, rb_slot, slot_c}) != 3:
            return False, ("前提不成立：三条并存连接占了同一批槽位（%s / %s / %s）"
                           % (slot_a, rb_slot, slot_c))

        # ① 中间那条断开 —— 「在线人数」减一，于是**空出一个号码**（这就是传染的入口）
        rb.stop(); rb = None
        sb.close(); sb = None
        time.sleep(0.6)

        # ② 新连接 D：修之前它叫 C 的号码
        sd = _connect(); rd = _Reader(sd)
        if rd.wait_you(6.0) is None:
            return False, ("D 没收到 you 握手（you=%s null×%d frames=%d err=%s）"
                           % (rd.you, rd.you_null, rd.frames, rd.err))
        gd = rd.you

        # ③ C 断开 —— 修之前这一下释放的是 **D 的**槽位（D 还连着）
        rc.stop(); rc = None
        sc.close(); sc = None
        time.sleep(0.6)

        # ④ 再连 E：修之前它拿到 D 的槽位 ⇒ 同一个角色
        se = _connect(); re_ = _Reader(se)
        if re_.wait_you(6.0) is None:
            return False, ("E 没收到 you 握手（you=%s null×%d frames=%d err=%s）"
                           % (re_.you, re_.you_null, re_.frames, re_.err))
        ge = re_.you

        # ★ 两个并存连接**不可能**共用一个槽位（每个连接一个人物）——
        #   这条比 guid 更早、更确定地炸：实测旧代码里 E 会拿到 D 的槽位，
        #   而 guid 反而不一定相同（`alloc_slot` 会清掉旧 guid、再建一个新角色，
        #   于是「槽位撞了、角色却不同」，D 变成了没有身体的孤儿）。
        if re_.slot == rd.slot:
            return False, ("E 拿到了 D 的槽位 %s（D 还连着，guid=%s / E 的 guid=%s）——"
                           "连接号被复用了：C 断开时释放的是 D 的槽位"
                           % (re_.slot, gd, ge))
        if ge == gd:
            return False, ("E **顶掉了** D：两个客户端是同一个角色（guid=%s）——"
                           "连接号被复用了，槽位互相顶掉（C=%s D=%s E=%s）"
                           % (gd, gc, gd, ge))
        if rd.err:
            return False, "C 断开后 D 掉线了：%s（连接被别人的 release 收走了）" % rd.err
        if rd.you != gd:
            return False, "D 的角色被换了（%s → %s）" % (gd, rd.you)
        if gd in (ga, gb, gc) or ge in (ga, gb, gd):
            return False, "出现了复用角色（A/B/C=%s/%s/%s D=%s E=%s）" % (
                ga, gb, gc, gd, ge)
        return True, ("连接号不复用：A/B/C=%s/%s/%s（槽 %s/%s/%s）→ B 走后 D=%s（槽%s）"
                      "→ C 走后再连 E=%s（槽%s），D 仍是 %s、槽位没被顶掉"
                      % (ga, gb, gc, slot_a, rb_slot, slot_c, gd, rd.slot,
                         ge, re_.slot, rd.you))
    finally:
        for r in (ra, rb, rc, rd, re_):
            if r is not None:
                try:
                    r.stop()
                except Exception:                                # noqa: BLE001
                    pass
        for s_ in (sa, sb, sc, sd, se):
            if s_ is not None:
                try:
                    s_.close()
                except Exception:                                # noqa: BLE001
                    pass


# ---------------------------------------------------------------- P21：会话身份
_SESS = {}


def _start_sess_server(grace=3):
    """起一个**独立**的服务端，带短的重连宽限期（默认 3 s）。

    ★ 为什么单起一个：宽限期要短到能在测试里观察到「到期被回收」，
      而 B0 那个服务端用的是默认 60 s（那是给人用的值）。
    """
    import tempfile
    if _SESS.get("p") is not None and _SESS["p"].poll() is None:
        return _SESS["port"]
    port = PORT + 3
    env = dict(os.environ)
    env["RT_RECONNECT_GRACE"] = str(grace)
    env.pop("RT_SPAWN", None)
    # ★★ 日志文件**每次都换名字**（2026-10-18）：原来固定写 `rt_sess_server.log` 且用 "w"，
    #   于是 D2 红了之后，D3 一起服务端就把**现场覆盖掉了** —— 我手上只剩「最后那台」的日志，
    #   而红的是**前一台**。查到这一步只能靠猜（「失败要吵」的另一半：**现场要留得下**）。
    _SESS["n"] = int(_SESS.get("n", 0)) + 1
    logp = os.path.join(tempfile.gettempdir(), "rt_sess_%02d_p%d.log" % (_SESS["n"], port))
    lf = open(logp, "w", encoding="utf-8")
    print("  [sess] 第 %d 台会话服务端，日志：%s" % (_SESS["n"], logp))
    _SESS["log"] = logp
    t0 = time.time()
    proc = subprocess.Popen([sys.executable, "-u", os.path.join(RT, "server.py"),
                             "--port", str(port), "--hz", "30"],
                            stdout=lf, stderr=subprocess.STDOUT, cwd=RT, env=env, text=True)
    # ★ P50⑲：同一个坑 —— 「端口能连上」不等于「是我起的那台」（见 _wait_own_world）。
    #   这里原来还有一句「探针连上后再确认进程活着」，它只挡得住「我的进程崩了」，
    #   挡不住「连的是别人」。
    _wait_own_world(proc, logp, port, "会话服务器", t0, timeout=30.0, logfile=lf)
    _SESS["p"] = proc
    _SESS["port"] = port
    return port
def _stop_sess_server():
    proc = _SESS.get("p")
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:                                        # noqa: BLE001
            proc.kill()
    _SESS["p"] = None
    # ★★ 等端口**真的放开**再返回（2026-10-18）。原来 terminate 完就返回，
    #   下一台服务端紧接着在**同一个端口**上起 —— Windows 上偶尔会出现
    #   「新进程以为自己绑上了、客户端却被 RST」（实测 D2 报
    #   `ConnectionResetError: 远程主机强迫关闭了一个现有的连接`，35 ms 就红）。
    #   判「放开」的办法就是**连一下**：连不上（refused）才算干净。
    port = _SESS.get("port")
    if port:
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    pass                      # 还有人在听 ⇒ 端口没放开，继续等
            except OSError:
                return
            time.sleep(0.1)


def _sess_diag(e):
    """把「连不上会话服务器」变成**带现场**的一句话（日志尾部一起给）。"""
    logp = _SESS.get("log")
    tail = ""
    if logp and os.path.exists(logp):
        try:
            with io.open(logp, encoding="utf-8", errors="replace") as f:
                tail = "".join(f.readlines()[-12:])
        except OSError as e2:                                    # noqa: BLE001
            tail = "（日志读不出来：%s）" % e2
    return ("连接失败：%s: %s\n    该台会话服务端日志（%s）尾部：\n%s"
            % (type(e).__name__, e, logp, tail))


def _connect_keyed(port, key):
    """带**会话 key** 连上去，返回 (sock, reader)。key=None ⇒ 匿名。"""
    import ws as wsmod
    path = "/ws" + (("?key=" + key) if key else "")
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    wsmod.client_handshake(sock, "127.0.0.1:%d" % port, path)
    return sock, _Reader(sock)


def _sess_pos(sock, port, key, guid, press=None, hold=1.0):
    """连上（可带 key）→ 拿 guid → 可选出位置 → 可选按方向走一会儿 → 断开。"""
    s_, rd = _connect_keyed(port, key)
    try:
        if rd.ask(20, 0.2) is None:
            return None, None
        g = rd.you
        if guid is not None and g != guid:
            return g, None
        p0 = rd.wait_pos(2.0)
        if press:
            s_.sendall(ws_encode({"k": press, "v": 1}))
            time.sleep(hold)
            s_.sendall(ws_encode({"k": press, "v": 0}))
            time.sleep(0.3)
        return g, (rd.latest or p0)
    finally:
        rd.stop()
        try:
            s_.close()
        except OSError:
            pass


def d1_session_key_reclaims_avatar():
    """★★ P21：带**会话 key** 的连接，断线后（宽限期内）重连要**拿回同一个角色**。

       ★ 为什么重要：没有它，刷新页面 = 丢掉自己的角色 —— 重连拿到一个新 wilson，
         而站在原地的是个**没人控制的空壳**（而且每刷新一次多一个）。
       判据：① 重连后 guid **完全相同**；② 位置**基本没变**（宽限期内玩家没被删、也没人动它）。
    """
    try:
        port = _start_sess_server(grace=3)
    except Exception as e:                                       # noqa: BLE001
        return False, "起会话服务器失败: %s" % e
    key = "k_d1_%d" % (int(time.time() * 1000) % 100000)
    try:
        g1, p1 = _sess_pos(None, port, key, None, press="right", hold=1.0)
        if g1 is None or p1 is None:
            return False, "第一次连接没拿到角色/位置"
        time.sleep(0.5)                       # 断开后进入保留期
        g2, p2 = _sess_pos(None, port, key, g1)
        if g2 is None:
            return False, "重连后没拿到角色"
        if g2 != g1:
            return False, "重连拿到了**另一个**角色（%s → %s）—— 会话身份没生效" % (g1, g2)
        if max(abs(p2[0] - p1[0]), abs(p2[1] - p1[1])) > 0.5:
            return False, "重连后位置变了：%s → %s" % (p1, p2)
        # ② 反向：换一个 key 必须是**新**角色
        g3, _ = _sess_pos(None, port, key + "_other", None)
        if g3 == g1:
            return False, "换了 key 却还是同一个角色（%s）—— 判据没区分身份" % g1
        return True, "同 key 重连拿回同一个角色 guid=%s（位置 %s 保持）；换 key 得到新角色 guid=%s" % (
            g1, p1, g3)
    finally:
        _stop_sess_server()


def d2_session_grace_expiry():
    """★ 反向：宽限期过了就必须**真的回收** —— 否则每次刷新都留一个空壳角色（泄漏）。

       做法：连一次（3 s 宽限期的服务器）→ 断开 → 等 5 s → 用**同一个 key** 再连：
       必须拿到**新**角色（旧的那个已经被回收）。再顺手确认世界里的人数回到 1。
    """
    try:
        port = _start_sess_server(grace=3)
    except Exception as e:                                       # noqa: BLE001
        return False, "起会话服务器失败: %s" % e
    key = "k_d2_%d" % (int(time.time() * 1000) % 100000)
    try:
        try:
            g1, _ = _sess_pos(None, port, key, None)
        except OSError as e:                                     # noqa: BLE001
            # ★ 连不上时**带上那台服务端的日志尾部**（2026-10-18）：
            #   上一次它只报 `ConnectionResetError`，而真正的现场在日志里，
            #   而且被后一台服务端覆盖了 —— 白查一轮。
            return False, _sess_diag(e)
        if g1 is None:
            return False, "第一次连接没拿到角色"
        # ★ 记下「第一次连上之后」的威尔逊实体数当**基线**。
        #   为什么不直接断言「等于 1」：这个世界里本来就可能已经有**槽位 0 的开机默认玩家**
        #   （客户端可能被分配到别的槽位）⇒ 2 个是正常的，泄漏的标志是**回收之后再连会变多**。
        #   （第一版直接断言 ==1，于是报「威尔逊实体数 2」，而那两个其实是默认玩家 + 客户端自己。）
        import urllib.request

        def player_ents():
            h = json.loads(urllib.request.urlopen(
                "http://127.0.0.1:%d/healthz" % port, timeout=5).read().decode())
            return int(h["stats"].get("player_ents", -1))

        base = player_ents()
        time.sleep(5.0)                       # 超过 3 s 宽限期
        try:
            g2, _ = _sess_pos(None, port, key, None)
        except OSError as e:                                     # noqa: BLE001
            return False, _sess_diag(e)
        if g2 is None:
            return False, "宽限期后重连没拿到角色"
        if g2 == g1:
            return False, "宽限期过了旧角色还在（guid 仍是 %s）—— 会泄漏" % g1
        now = player_ents()
        if now != base:
            # ★ 这里原来是 `n_ents > 20` —— 一个**跟世界大小绑死的魔法数**。
            #   2026-10-16 默认世界加了 14 个植物之后它立刻误报（报「实体数 25」，
            #   其实空壳早清干净了）。⇒ 改成问**它真正关心的东西**：
            #   威尔逊实体的个数在「回收 + 重连」之后**有没有变多**。
            return False, "威尔逊实体数从 %d 变成 %d（回收+重连之后不该变多）—— 空壳没被回收" % (base, now)
        return True, "宽限期（3 s）后旧角色 guid=%s 被回收，重连拿到新角色 guid=%s" \
                     "（威尔逊实体数保持 %d，没有累积空壳）" % (g1, g2, now)
    finally:
        _stop_sess_server()


def d3_same_key_twice_is_refused():
    """★ 反向：同一个 key **同时**连两个客户端 ⇒ 第二个必须被**明确拒绝**。

       不然两个人会控制同一个身体（互相抢），而且没有任何提示。
       判据：第二条连接收到 `busy=true`，且 `you=null`（没角色）。
    """
    try:
        port = _start_sess_server(grace=3)
    except Exception as e:                                       # noqa: BLE001
        return False, "起会话服务器失败: %s" % e
    key = "k_d3_%d" % (int(time.time() * 1000) % 100000)
    sa = sb = None
    ra = rb = None
    try:
        sa, ra = _connect_keyed(port, key)
        if ra.ask(20, 0.2) is None:
            return False, "第一个客户端没拿到角色"
        sb, rb = _connect_keyed(port, key)
        # 第二个：应该收到 busy
        t0 = time.time()
        busy_seen = False
        while time.time() - t0 < 3.0:
            if rb.busy:
                busy_seen = True
                break
            time.sleep(0.05)
        if not busy_seen:
            return False, "同一个 key 连第二次没被拒（busy 标志没收到）"
        if rb.you is not None:
            return False, "被拒的连接竟然也拿到了角色（you=%s）" % rb.you
        if ra.you is None:
            return False, "第一个客户端的角色反而没了"
        return True, "同 key 第二连接被明确拒绝（busy），第一个仍持有角色 guid=%s" % ra.you
    finally:
        for r in (ra, rb):
            if r is not None:
                r.stop()
        for s_ in (sa, sb):
            if s_ is not None:
                try:
                    s_.close()
                except OSError:
                    pass
        _stop_sess_server()


def e1_interaction_chain():
    """★★ P22：交互链路（进程内）——「找到目标 → 走过去 → 砍倒」。

       ★ 为什么这条必须存在：在这之前引擎**只能移动**，世界里的一切都碰不到。
       判据（每一环都要能证伪）：
         ① 目标列表里**有**那棵树，且动作名是引擎自己声明的（`workable.action.id` = CHOP）；
         ② 超出作用范围时 `act` **不是失败**，而是「走过去」（pending 被记下）——
            原版 PushAction 超范围时**不报错也不做事**，属于静默无效，必须自己补这段；
         ③ 走过去之后 `workleft` 真的下降；
         ④ 反向：不存在的 guid / 对自己做动作 / 太远 —— **都拒绝且说得出原因**。
    """
    s = Sim(seed=20261015, tick_hz=30).boot()
    L = s.lua
    L.globals().RT = s.api
    _pin_player_alive(L)            # ★ 钉住与「动作链跑不跑得通」无关的变量（玩家生死）
    g = L.eval("""(function()
      local C = require("host.01_core")
      local p = RT.player
      local x, y, z = p.Transform:GetWorldPosition()
      local ok, tree = pcall(C.SpawnPrefab, "evergreen")
      if not ok or tree == nil then return -1 end
      tree.Transform:SetPosition(x + 8, 0, z)     -- 放 8 格外：先走过去
      RT._tree = tree
      return tree._guid
    end)()""")
    if int(g) < 0:
        return False, "造不出 evergreen（引擎里没有这个预制体？）"

    def wl():
        return L.eval("(function() local t = RT._tree "
                      "if not t:IsValid() then return -1 end "
                      "return t.components.workable.workleft end)()")

    def pos():
        return L.eval("(function() local x, y, z = RT.player.Transform:GetWorldPosition() "
                      "return x, z end)()")

    # ① 目标发现
    tg = s.api.act_targets(0, 20)
    if len(tg) < 1:
        return False, "20 格内没找到任何可交互目标（树没被认出来？）"
    first = dict(tg[1])
    if first.get("a") != "CHOP":
        return False, "最近的目标动作名是 %r，应为 CHOP" % first.get("a")

    w0 = int(wl())
    x0, z0 = pos()
    # ② 太远 ⇒ 不是失败，而是「走过去」
    ok, msg = s.api.act(0, int(g))
    if not ok:
        return False, "在 8 格外发 act 被拒了：%s（应记成「走过去」）" % msg
    pending, pg = s.api.pending_act(0)
    if not pending:
        return False, "超范围的 act 没记下「待做动作」"
    if "走" not in str(msg):
        return False, "超范围的 act 返回了 %r，没说清是在走过去" % msg

    # ③ 走过去 + 砍：给它 15 s
    for _ in range(450):
        s.step()
    x1, z1 = pos()
    w1 = int(wl())
    if max(abs(x1 - x0), abs(z1 - z0)) < 3.0:
        return False, "玩家没朝目标走过去（位移 %.2f）" % max(abs(x1 - x0), abs(z1 - z0))
    # ★★ 2026-10-16：`wl()` 返回 -1 表示**树已经不在**（被砍倒并移除了）。
    #   这**不是失败**，恰恰是「动作真的做了」的最强证据。
    #   以前这里把它当失败，是因为当时玩家会在砍的过程中死掉（§9y.7）⇒ 从来没走到这一步；
    #   把生死钉住之后，树会被砍倒并**移除**（而不是原地变树桩），所以必须认这种情况。
    felled = w1 < 0
    if not felled and w1 >= w0:
        return False, "走过去之后 workleft 没下降（%d → %d）—— 动作没真的做" % (w0, w1)

    # ④ 反向
    ok2, why2 = s.api.act(0, 999999)
    if ok2:
        return False, "对不存在的 guid 发 act 竟然成功了"
    if not why2:
        return False, "被拒却没说原因（失败要吵）"
    ok3, why3 = s.api.act(0, int(s.api.player_guid(0)))
    if ok3:
        return False, "对自己做动作竟然成功了"
    # 太远：必须用一棵**还活着**的树 —— 上面那棵在 ③ 里可能已经被砍倒并移除了，
    # 那样拒绝原因会变成「目标不存在」（也是对的，但**测的不是同一件事**）。
    # ★ 这条反向要测的是「距离由服务端判」，所以先补一棵站在玩家**原处**的树，再把玩家挪远。
    g2 = int(L.eval("""(function()
      local C = require("host.01_core")
      local ok, t = pcall(C.SpawnPrefab, "evergreen")
      if not ok or t == nil then return -1 end
      t.Transform:SetPosition(%f, 0, %f)
      RT._tree2 = t
      return t._guid
    end)()""" % (x0, z0)))
    if g2 < 0:
        return False, "补不出第二棵树（无法测「太远」）"
    L.eval("(function() RT.player.Transform:SetPosition(400, 0, 400) return 1 end)()")
    ok4, why4 = s.api.act(0, g2)
    if ok4:
        return False, "400 格外发 act 竟然成功了（距离应由服务端判）"
    if "远" not in str(why4):
        return False, "太远的拒绝原因没说清「远」：%r" % why4
    ao, ar, _ = s.api.act_stats()
    return True, "目标 %s·CHOP（20 格内 %d 个）→ 走过去 %.1f 格 → %s；" \
                 "反向三种（不存在/自己/太远）全拒且带原因（act_ok=%d refused=%d）" % (
                     first.get("p"), len(tg), max(abs(x1 - x0), abs(z1 - z0)),
                     ("被砍倒并移除" if felled else "workleft %d→%d" % (w0, w1)), ao, ar)


def _pin_player_alive(L):
    """把与「动作链能不能跑通」**无关的变量钉住**：玩家的生死。

    ★★★ 为什么必须钉住（2026-10-16 查出来的真因，见 §9y.7）：
      世界一开始玩家的 health 就在**持续掉**（实测逐秒采样：150 → 49.95（6 s）→ 0（12 s）），
      随后状态机停在 `sg=death`，**之后 `act` 再也推不动任何动作**（但 push 依然「成功」，
      所以表现是**静默无效**）。
      §9w.2 当年那句「60 次 act（≈90 s）内没观察到树倒下」**正是这个原因** ——
      不是引擎砍不动，是**玩家中途死了**。
      把这条变量钉住之后，三次连跑**稳定在 15~16 s 砍倒 + 掉 3 个 log**（见 §9y.7 的实测）。
      ⇒ 生死与「动作链」无关，必须从判据里摘出去，而不是让判据去赌「玩家恰好还活着」。
      （同类先例：§9t.4.1「负载依赖要从判据里摘出去」。）

    ⚠️ 这只是**测试侧的隔离**，不是修引擎：真正的缺陷（持续掉血 + 死后无复活且无提示）
      另行登记，不许因为这里钉住了就当它不存在。
    """
    L.eval("""(function()
      local p = RT.player
      local h = p.components.health
      if h == nil then return false end
      if h.SetInvincible ~= nil then h:SetInvincible(true) end
      h:SetPercent(1)
      return true
    end)()""")


def e4_daylight_is_safe():
    """白天不该被「黑暗」打死（grue 光照代理）；反向：造出**真黑暗**必须掉血。

    ── 背景（2026-10-16 查实）────────────────────────────────────────────────
    宿主当时把 `EntityScript:IsInLight` 桩成恒 `false`，而 `components/grue.lua:120`
    的 `CheckForStart()` 读的正是它 ⇒ grue 永远认为「玩家在黑暗里」⇒ 开局 5~10 s
    就来一发 `combat:GetAttacked(nil, TUNING.GRUEDAMAGE=100.05, nil, "darkness")`
    ⇒ **玩家 12 秒必死**（实测逐秒 `150 → 49.95 → 0`）。
    07 侧的修法：用「昼夜相位 + 离点着的营火足够近」当光照代理
    （`rt_boot.lua` 的 `sync_grue_light` / `in_light_for_slot`），在光里就
    `grue:AddImmunity("light")`。⚠️ 是**代理不是等价**（宿主没有逐点光照）。

    ── ★★★ 2026-10-18（H2）：旧反向是**假判据**，已重写 ────────────────────
    旧反向做的是 `grue:RemoveImmunity("light")`，然后等 25 s 看血量掉不掉。
    实测**一滴不掉**（150 → 150，25 s），因为：
      · 宿主后来补了光照：`06_entityscript.lua:228` 已把 `IsInLight` 委派给
        `LightWatcher`，而 `01_core.lua:255` 的 `IsInLight` 读 `AmbientLightLevel()`
        （`01_core.lua:196-206`：**day=1.0 / dusk=0.5 / night=0.0**，阈值 0.2）；
      · `CheckForStart()` 里还有一条 `self.inst:IsInLight()` —— 白天恒 `true`
        ⇒ 即使免疫表被清空，grue 也**不会 `Start()`**。
    ⇒ 「撤掉免疫」在白天**物理上不可能**掉血。那条反向实际证明的是
      「白天 `IsInLight` 是 true」，**不是**「我们的补丁在起作用」——
      判据恒真，等于没有判据（这也解释了为什么 `②f` 的「光照代理不生效」那条
      篡改一直显示「被抓住」：E4 本来就是红的，抓住它不需要任何篡改）。
    ⇒ 现在改成**造真黑暗**：`TheWorld:PushEvent("ms_setphase", "night")`
      （`clock.lua:453` 注册的生产事件，存档载入/管理指令走同一入口，不是测试后门），
      再对比「光照半径默认 vs 0」——**只差一个变量**。

    ── 判据（②③ 是对照组）────────────────────────────────────────────────
      ① 白天 30 s：血量一滴不掉，且从没进过 `death`；
      ② 夜里 + 光照半径默认：25 s 血量**不掉**（证明「离火近 = 在光里」真的挡住了 grue）；
      ③ 夜里 + 光照半径 0：25 s 血量**必须掉**（证明 ② 不是「夜里其实不危险」）。
    """
    s = Sim(seed=20261015, tick_hz=30).boot()
    L = s.lua
    L.globals().RT = s.api

    def ev(code):
        """包一层 IIFE：`code` 是**函数体**（自己写 `return …`）"""
        return L.eval("(function() " + code + " end)()")

    def snap():
        """一次取值拿回 `血量|状态机状态`（每拍调用两次会明显拖慢，所以合并）"""
        return str(ev("""local p = RT.player
          local h = p.components and p.components.health or nil
          local cs = "?"
          local ok, v = pcall(function() return p.sg.currentstate and p.sg.currentstate.name end)
          if ok then cs = tostring(v) end
          return tostring(h and h.currenthealth or -1) .. "|" .. cs"""))

    def hp():
        return float(snap().split("|")[0])

    def phase():
        return str(ev("return tostring(TheWorld.state.phase)"))

    def islight():
        return bool(ev("return RT.player:IsInLight()"))

    def ambient():
        return float(ev('return require("host.01_core").AmbientLightLevel()'))

    def immunity():
        """★ 读**组件里的免疫表本身**，不信 `stats().grue_immune`。
        后者是代理的**缓存意图**：实测 `RemoveImmunity` 之后它仍报 `true`。"""
        v = str(ev("""local g = RT.player.components.grue
          local n, has = 0, false
          for k in pairs(g.immunity) do n = n + 1; if k == "light" then has = true end end
          return tostring(n) .. "|" .. tostring(has)"""))
        n, has = v.split("|")
        return int(n), has == "true"

    def run(ticks):
        """跑 N 拍，返回 (最低血量, 是否进过 death)"""
        lo = hp()
        died = False
        for _ in range(ticks):
            s.step()
            cur, cs = snap().split("|")
            cur = float(cur)
            if cur < lo:
                lo = cur
            if cs == "death":
                died = True
        return lo, died

    for _ in range(60):                      # 2 s：让世界/相位稳定
        s.step()

    # ① 白天：血量恒为 h0，且从不 death
    if phase() != "day":
        return False, "开局相位是 %s 而不是 day —— ① 的前提不成立（判据没有测到要测的东西）" % phase()
    h0 = hp()
    lo_day, died_day = run(900)              # 30 s
    if died_day:
        return False, "白天 30 s 内玩家进了 `death`（光照代理没生效？）"
    if lo_day < h0 - 0.01:
        return False, "白天 30 s 玩家掉血了（%.2f → %.2f）—— grue 又把它当成黑暗了" % (h0, lo_day)
    st = s.stats()
    if st.get("grue_immune") is not True:
        return False, "stats().grue_immune 不是 true：%r" % (st.get("grue_immune"),)
    if int(st.get("grue_sync", 0)) < 1:
        return False, "光照代理一次都没动手（grue_sync=0）—— 那就成了死代码"
    n_imm, has_light = immunity()
    if not has_light:
        return False, "白天 `grue.immunity` 里没有 `light`（实际 %d 项）—— 代理没真的加上免疫" % n_imm

    # ── 造真黑暗（②③ 的共同前提）─────────────────────────────────────────
    L.eval('(function() TheWorld:PushEvent("ms_setphase", "night") return 1 end)()')
    for _ in range(10):
        s.step()
    ph = phase()
    amb = ambient()
    lit = islight()
    if ph != "night":
        return False, "`ms_setphase(\"night\")` 没生效（phase=%s）—— ②③ 没法测" % ph
    if amb > 0.01 or lit:
        return False, ("夜里环境光仍是 %.2f / IsInLight=%s —— 那不是黑暗，"
                       "②③ 的前提不成立" % (amb, lit))

    # ② 夜里 + 半径默认（火在挡）：血量必须不掉
    h_night = hp()
    lo_lit, died_lit = run(750)              # 25 s
    st2 = s.stats()
    if int(st2.get("fires_lit", 0)) < 1:
        return False, ("夜里 25 s 一次火都没点过（fires_lit=%s）—— "
                       "② 「不掉血」就无从解释" % st2.get("fires_lit"))
    if died_lit or lo_lit < h_night - 0.01:
        return False, ("夜里站在火边仍然掉血（%.0f → 最低 %.0f，died=%s）—— "
                       "火光代理没挡住 grue" % (h_night, lo_lit, died_lit))

    # ③ 夜里 + 半径 0（同样的夜、同样的火，只是「不算光」）：血量必须掉
    lr = float(s.api.light_radius())
    s.api.set_light_radius(0)
    for _ in range(5):                        # 让 sync_grue_light 把免疫撤掉
        s.step()
    lo_dark, died_dark = run(750)             # 25 s（第一发在 5~10 s）
    _, has_light_end = immunity()
    s.api.set_light_radius(lr)
    if lo_dark >= h_night - 0.01:
        return False, ("夜里光照半径设 0 之后 25 s 血量**全程没掉过**（最低仍 %.2f）—— "
                       "这条反向证明不了任何事（「黑暗」根本没造成伤害）%s" % (
                           lo_dark,
                           "；旁证：`grue.immunity` 里仍有 `light`，说明代理压根没被撤掉"
                           if has_light_end else ""))

    return True, ("白天 30 s 血量恒 %.0f、从未 death ✔ / grue_immune=true · grue_sync=%s · "
                  "immunity 含 light ✔ / 夜里（amb=%.2f、IsInLight=false）火边 25 s 最低 %.0f 不掉血 ✔ / "
                  "同一夜把光照半径设 0 ⇒ 最低掉到 %.2f（died=%s）✔" % (
                      h0, st.get("grue_sync"), amb, lo_lit, lo_dark, died_dark))


def e5_death_and_respawn():
    """★★ 2026-10-16 新增：**死亡 ⇒ 自动复活**（否则世界**永久停摆**）。

    背景（实测，见 §9y.7）：玩家死后状态机停在 `death`，而 `SGwilson` 的 death 状态
    **出不去** —— 实测 `sg:GoToState("idle")` 直接报
      `stategraphs/SGwilson.lua:3839: Left death state.`
    此后 `act` 仍然返回成功但**什么都推不动**（拿一棵树试：workleft 一动不动）
    ⇒ 表现是「世界安静地不动了」，只能重启服务端。
    原版这里是**变成 ghost**（本宿主没有 `SGghost`），所以 07 侧用
    「移除尸体 + 生成新身体」来表达重生，并在 3 秒后自动执行（`rt_boot` 的 `M.respawn`）。

    判据：
      ① 把血扣光 ⇒ `player_alive=false` 且 **`act` 推不动**（把这个失败形态记录下来）；
      ② 等自动复活 ⇒ `player_alive=true` 且 `respawns ≥ 1`；
      ③ **复活后 `act` 必须真的又能推动动作**（workleft 下降）——
         这才是「恢复」的判据，而不是「血量回到 150」这种弱信号；
      ④ 反向：**没死**的时候调 `respawn` 必须被拒绝，且**说得出原因**。
    """
    s = Sim(seed=20261015, tick_hz=30).boot()
    L = s.lua
    L.globals().RT = s.api

    def st():
        return s.stats()

    def sg_name():
        return str(L.eval("(function() local ok, v = pcall(function() "
                          "return RT.player.sg.currentstate and RT.player.sg.currentstate.name end) "
                          "if ok then return tostring(v) end return '?' end)()"))

    def workleft(ref):
        return int(L.eval("(function() local t = RT.%s "
                          "if t == nil or not t:IsValid() then return -1 end "
                          "return t.components.workable.workleft end)()" % ref))

    def spawn_tree(ref, dx=1.0):
        return int(L.eval("""(function()
          local C = require("host.01_core")
          local p = RT.player
          local x, y, z = p.Transform:GetWorldPosition()
          local ok, t = pcall(C.SpawnPrefab, "evergreen")
          if not ok or t == nil then return -1 end
          t.Transform:SetPosition(x + %f, 0, z)
          RT.%s = t
          return t._guid
        end)()""" % (dx, ref)))

    # ① 打死
    L.eval("(function() RT.player.components.health:DoDelta(-9999) return 1 end)()")
    for _ in range(30):
        s.step()
    if st().get("player_alive") is not False:
        return False, "扣光血之后 player_alive 仍是 %r（没死成？）" % st().get("player_alive")
    if sg_name() != "death":
        return False, "死了却没进 death 状态：sg=%s" % sg_name()
    g = spawn_tree("_t1")
    if g < 0:
        return False, "造不出树（测不了「死后推不动」）"
    w_before = workleft("_t1")
    s.api.act(0, g)
    for _ in range(300):                       # 10 s
        s.step()
    w_after = workleft("_t1")
    if w_after >= 0 and w_after < w_before:
        return False, "死后竟然还能砍动（%d → %d）—— 本判据描述的那个失败形态不成立了" % (w_before, w_after)

    # ② 自动复活
    for _ in range(600):                       # 20 s 预算（延迟是 3 s）
        s.step()
        if st().get("player_alive") is True:
            break
    if st().get("player_alive") is not True:
        return False, "死后 20 s 仍未自动复活（respawns=%r）" % st().get("respawns")
    if int(st().get("respawns", 0)) < 1:
        return False, "复活了但 respawns 计数没涨（静默复活？）"
    if sg_name() == "death":
        return False, "player_alive 为真但 sg 仍是 death（自相矛盾）"

    # ③ 复活后必须**真的又能动**
    g2 = spawn_tree("_t2")
    if g2 < 0:
        return False, "复活后造不出树"
    w2 = workleft("_t2")
    s.api.act(0, g2)
    for _ in range(600):                       # 20 s
        s.step()
    w3 = workleft("_t2")
    if w3 >= 0 and w3 >= w2:
        return False, "复活后 act 仍然推不动（workleft %d → %d）—— 那就只是「血回来了」" % (w2, w3)

    # ④ 反向：活着的时候不许复活，而且要说得出原因
    r = str(L.eval("(function() local ok, why = RT.respawn(0) "
                   "return tostring(ok) .. '|' .. tostring(why) end)()"))
    ok_s, why_s = r.split("|", 1)
    if ok_s == "true":
        return False, "活着的玩家竟然也能「复活」"
    if not why_s or why_s == "nil":
        return False, "被拒却没说原因（失败要吵）"
    return True, "死后 %s（act 推不动 %d→%d）；自动复活后 respawns=%s、%s；" \
                 "复活后 act 又能推动（%d→%s）；反向：活着时被拒「%s」" % (
                     sg_name(), w_before, w_after, st().get("respawns"),
                     "既能动", w2, (w3 if w3 >= 0 else "树被砍倒"), why_s)


def e6_default_world_has_content():
    """★★★ 2026-10-16 新增：**默认世界必须有东西可交互**（发布演练抓出来的）。

    起因：`tests/test_deploy.py`（走 `deploy/start.sh` 的发布演练）量出 ——
    默认世界**只有玩家一个实体**，`act_targets(0, 200)` 还是空的：
    用户打开链接能走能跳，但**周围什么都没有**，砍不了、捡不了。
    ⇒ 「服务端没问题」≠「用户那条路能玩」。这正是演练该抓的东西。

    修法（07 侧）：`rt_boot` 多了 `populate_world(n)`，默认在**玩家周围**（3.5~9.9 格）
    撒 14 个可交互植物（树 / 树苗 / 浆果丛）；`RT_WORLD_CONTENT=0` 可关。

    判据：
      ① 默认世界里，**不额外生成任何东西**，`act_targets(0, 20)` 必须非空，
         且最近的那个必须是引擎自己声明的动作（CHOP/DIG/PICKUP 之一）；
      ② 最近的目标必须在 **12 格内**（不然「一进游戏就能砍」这句话是假的）；
      ③ **反向**：`RT_WORLD_CONTENT=0` 时必须真的是**空**的 ——
         证明这条判据测的是「内容生成」，而不是「某个别的生成器顺手撒了点东西」。
    """
    import os as _os
    # ① 默认（不设 RT_WORLD_CONTENT，用 rt_boot 的默认值）
    _os.environ.pop("RT_WORLD_CONTENT", None)
    s = Sim(seed=20261015, tick_hz=30).boot()
    L = s.lua
    L.globals().RT = s.api
    tg = s.api.act_targets(0, 20)
    n = len(tg) if tg is not None else 0
    if n < 1:
        return False, "默认世界 20 格内**一个可交互目标都没有**（用户打开链接会看到空世界）"
    first = dict(tg[1])
    if first.get("a") not in ("CHOP", "DIG", "PICKUP", "HARVEST"):
        return False, "最近目标的动作名是 %r，不是引擎声明的动作" % first.get("a")
    px, pz = float(first["x"]), float(first["z"])
    # 玩家在原点附近（出生环），所以直接量到原点的距离就够
    d = (px ** 2 + pz ** 2) ** 0.5
    if d > 12.0:
        return False, "最近的可交互目标在 %.1f 格外（>12）—— 「一进游戏就能砍」不成立" % d
    n_kinds = len({dict(t).get("p") for t in (tg[i] for i in range(1, n + 1))})
    # ③ 反向：关掉世界内容 ⇒ 必须真的是空的
    # ★ 必须**通过构造参数**关，不能只设环境变量 —— `Sim.__init__` 会拿
    #   `self.world_content`（默认 14）**覆盖** `RT_WORLD_CONTENT`。
    #   （第一版就是只设了环境变量，于是反向跑到一半仍然是 12 个目标、判据报红；
    #     这条反向因此顺带证明了「关内容」这件事**真的**是由构造参数决定的。）
    s2 = Sim(seed=20261015, tick_hz=30, world_content=0).boot()
    tg2 = s2.api.act_targets(0, 20)
    n2 = len(tg2) if tg2 is not None else 0
    if n2 != 0:
        return False, "world_content=0 时居然还有 %d 个目标 —— 那这条判据没测到「内容生成」" % n2
    return True, "默认世界 20 格内 %d 个可交互目标（%d 种，最近 %.1f 格 · %s·%s）；" \
                 "反向：内容关掉后确实为空" % (n, n_kinds, d, first.get("p"), first.get("a"))


def e7_night_is_survivable():
    """★★★ 2026-10-16 新增：**夜里能活下来**（把 §9z 那条「夜里必死」的限制真正去掉）。

    做法（07 侧，见 §9ae）：光照代理除了昼夜相位，还认「离**点着的营火**足够近」
    （`M.in_light_at`，半径 `LIGHT_R` 默认 7）；黄昏时若没有点着的火，
    就在玩家附近点一堆（**本世界的配置**：原版要玩家自己造火）。
    实测（探针）：**火不会点燃旁边的树**（5 分钟里树的 burning 一直 false）——
    所以加火是安全的；但它自己会烧完（约 140 s）⇒ 黄昏补一堆。

    判据：
      ① **纯函数**（把 `isnight` 当参数喂 ⇒ 不用等 430 秒的世界时间）：
         白天到处都算在光里；夜里**火边算、远处不算**；
      ② **反向**：把光照半径设成 0 ⇒ 站在火边也**不算**在光里
         （证明 ③「活下来」靠的是这条规则，而不是「夜里其实不危险」）；
      ③ **整段集成**：不打任何输入，跑过一整个 `day→dusk→night`（约 460 s 世界时间），
         玩家必须**活着**（血量从没归零、`respawns` 没有增长），且期间**点过火**。
    """
    s = Sim(seed=20261015, tick_hz=30).boot()
    L = s.lua
    L.globals().RT = s.api

    def ev(code):
        """包一层 IIFE：`code` 是**函数体**（自己写 `return …`）"""
        return L.eval("(function() " + code + " end)()")

    def evx(code):
        """**直接** eval：`code` 自带 `(function() … end)()`。
        ★★ 为什么必须分开（今天第三次踩）：把自带的 IIFE 再套进 `ev()` 的 IIFE ⇒
           外层函数体只剩一个表达式、**没有 return** ⇒ Lua 返回 nil ⇒ Python 收到 None
           ⇒ 报出来的是 `int(None)` / `not enough values to unpack` 这种**看起来像取值失败**
           的错，而真相是**包装套了两层**。规矩：**一个文件里只允许一种包装约定**，
           要混用就必须分成两个名字（`ev` / `evx`）。"""
        return L.eval(code)

    # 先放一堆火并**登记成光源**（走的是生产代码同一个入口 `add_light_source`）
    r = str(evx("""(function()
      local C = require("host.01_core")
      local p = RT.player
      local px, py, pz = p.Transform:GetWorldPosition()
      local ok, f = pcall(C.SpawnPrefab, "campfire")
      if not ok or f == nil then return "-1" end
      f.Transform:SetPosition(px + 3.0, 0, pz)
      RT._fire = f
      RT.add_light_source(f._guid)
      local x, y, z = f.Transform:GetWorldPosition()
      return string.format("%.2f|%.2f|%.2f", px, pz, math.sqrt((x - px) ^ 2 + (z - pz) ^ 2))
    end)()"""))
    if r.startswith("-1"):
        return False, "造不出 campfire（夜里就没法待在光里）"
    px, pz, fdist = r.split("|")
    px, pz, fdist = float(px), float(pz), float(fdist)
    lr = float(s.api.light_radius())
    # ① 纯函数：白天到处算在光里；夜里火边算、远处不算
    if not bool(ev("return RT.in_light_at(%.2f, %.2f, false)" % (px + 500, pz + 500))):
        return False, "白天（isnight=false）远处居然不算在光里"
    if not bool(ev("return RT.in_light_at(%.2f, %.2f, true)" % (px, pz))):
        return False, "夜里站在火边（距离 %.2f < 半径 %s）竟然不算在光里" % (fdist, lr)
    far = lr + 5.0
    if bool(ev("return RT.in_light_at(%.2f, %.2f, true)" % (px + far, pz))):
        return False, "夜里离火 %.1f 格（> 半径 %s）竟然还算在光里" % (far, lr)
    # ② 反向：半径设 0 ⇒ 火边也不算在光里
    s.api.set_light_radius(0)
    if bool(ev("return RT.in_light_at(%.2f, %.2f, true)" % (px, pz))):
        s.api.set_light_radius(lr)
        return False, "光照半径设成 0 之后，火边竟然还算在光里 —— 那这条反向没测到东西"
    s.api.set_light_radius(lr)
    if not bool(ev("return RT.in_light_at(%.2f, %.2f, true)" % (px, pz))):
        return False, "半径设回 %s 之后火边又不算在光里了" % lr

    # ③ 集成：不打输入，跑过 day→dusk→night，玩家必须活着
    saw_night = False
    night_secs = 0
    min_hp = 9999.0
    for _ in range(18000):                      # 最多 600 s 世界时间
        s.step()
        st = s.stats()
        ph = str(ev("return tostring(TheWorld.state.phase)"))
        hp = st.get("player_health")
        if isinstance(hp, (int, float)):
            min_hp = min(min_hp, float(hp))
        if ph == "night":
            saw_night = True
            night_secs += 1
        if saw_night and night_secs > 30 * 20:  # 夜里再过 20 s 就够说明问题了
            break
    st = s.stats()
    if not saw_night:
        return False, "600 s 世界时间里没走到夜里（没测到要测的东西）"
    if int(st.get("respawns", 0)) != 0:
        return False, "夜里死了（respawns=%s）—— 火光保护没生效" % st.get("respawns")
    if min_hp <= 0:
        return False, "血量一度归零（最低 %.1f）" % min_hp
    if int(st.get("fires_lit", 0)) < 1:
        return False, "整个过程一次火都没点过（fires_lit=%s）—— 那 ③ 是靠什么活下来的？" % st.get("fires_lit")
    return True, "夜里站在火边不算黑暗（半径 %s）· 白天不判 · 反向（半径 0 则失效）✔ · " \
                 "集成：走过 %s 的夜晚，最低血量 %.0f、respawns=%s、点过 %s 堆火" % (
                     lr, "≥20 s", min_hp, st.get("respawns"), st.get("fires_lit"))


_DEBUG_SRV = {}


def _start_debug_server():
    """起一个带 `--allow-debug` 的独立服务端（比主服务端端口 +7）。

    ★ 为什么必须 `--allow-debug`：跨进程验「死亡 ⇒ 自动复活 ⇒ 客户端认回自己」
      需要一个**从外部触发死亡**的手段，而 `/debug/kill` **默认是关的**
      （它能杀掉玩家的角色，不该出现在公网部署上 —— 发布检查单里专门写了这条）。
    """
    import tempfile
    if _DEBUG_SRV.get("p") is not None and _DEBUG_SRV["p"].poll() is None:
        return _DEBUG_SRV["port"]
    port = PORT + 7
    env = dict(os.environ)
    env.pop("RT_SPAWN", None)
    logp = os.path.join(tempfile.gettempdir(), "rt_debug_server.log")
    lf = open(logp, "w", encoding="utf-8")
    t0 = time.time()
    proc = subprocess.Popen([sys.executable, "-u", os.path.join(RT, "server.py"),
                             "--port", str(port), "--hz", "30", "--allow-debug"],
                            stdout=lf, stderr=subprocess.STDOUT, cwd=RT, env=env, text=True)
    # ★ P50⑲：端口 +7 与 B21（硬杀录像）撞同一个号 —— 一旦 B21 的进程没死透，
    #   这里原来的「连上就算起来」会直接连到那个**没有 --allow-debug** 的世界，
    #   于是 E8/E11 会报「debug 端点默认没关掉」（真因是**连错了服务端**）。
    _wait_own_world(proc, logp, port, "调试服务器", t0, timeout=30.0, logfile=lf)
    _DEBUG_SRV["p"] = proc
    _DEBUG_SRV["port"] = port
    return port


def _stop_debug_server():
    p = _DEBUG_SRV.get("p")
    if p is not None and p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=5)
        except Exception:                                        # noqa: BLE001
            p.kill()
    _DEBUG_SRV.clear()


def e8_death_respawn_cross_process():
    """★★★ 2026-10-16 新增：**跨进程**的「死亡 ⇒ 自动复活 ⇒ 客户端认回自己」。

    为什么单列（§9aa.5 登记过这个缺口）：`E5` 是**进程内**验的；而「换了身体之后
    **客户端**能不能认回自己」必须走**真连接**才算 —— 它依赖两件事一起工作：
      · 服务端每 ~0.27 s 把 `slot_guid` **对账**（实体换了就更新）；
      · 客户端每 2 s **例行重问 `whoami`**（拿到新 guid 就采纳）。
    触发死亡需要一个外部手段 ⇒ 服务端加了 `--allow-debug` 下的 `/debug/kill`
    （默认关闭；与 `/pause` 同族，都是「从外部控制世界」的入口）。

    判据：
      ① 连接 → `whoami` 拿到 guid1 与槽位；
      ② `/debug/kill?slot=<槽位>` ⇒ `/healthz` 的 `player_alive` **必须变成 false**；
      ③ 等 ~6 s（自动复活阈值 3 s）⇒ `player_alive` 回来、`respawns ≥ 1`；
      ④ **重问 `whoami` 必须拿到 guid2 ≠ guid1**，且**新 guid 必须真的出现在帧里** ——
         这就是「客户端能认回自己」的判据（只验「服务端换了个号」不够）；
      ⑤ **反向**：主服务端（**没有** `--allow-debug`）的同一个端口必须回 **404**
         ⇒ 证明这个「能杀角色」的入口默认是关的。
    """
    import urllib.request
    import ws
    try:
        port = _start_debug_server()
    except Exception as e:                                       # noqa: BLE001
        return False, "起调试服务器失败: %s" % e

    def health():
        with urllib.request.urlopen("http://127.0.0.1:%d/healthz" % port, timeout=5) as r:
            return json.loads(r.read().decode("utf-8"))["stats"]

    def get(path, timeout=5):
        try:
            with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path), timeout=timeout) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:                       # noqa: PERF203
            return e.code, ""
        except Exception as e:                                    # noqa: BLE001
            return -1, str(e)

    sock = None
    try:
        # ① 连接 + whoami（拉取式，问到为止）
        sock = socket.create_connection(("127.0.0.1", port), timeout=6)
        ws.client_handshake(sock, "127.0.0.1:%d" % port)
        g1 = slot = None
        deadline = time.time() + 8
        while time.time() < deadline and g1 is None:
            sock.sendall(ws_encode({"cmd": "whoami"}))
            for _ in range(20):
                _op, d = _recv_frame(sock, 5.0)
                try:
                    m = json.loads(d.decode("utf-8"))
                except Exception:                                # noqa: BLE001
                    continue
                if isinstance(m, dict) and m.get("you") is not None:
                    g1, slot = int(m["you"]), int(m.get("slot", 0))
                    break
        if g1 is None:
            return False, "8 s 没拿到 you 握手"
        st0 = health()
        r0 = int(st0.get("respawns", -1))
        # ② 外部击杀
        code, _body = get("/debug/kill?slot=%d" % slot)
        if code != 200:
            return False, "/debug/kill 返回 %s（开了 --allow-debug 应当 200）" % code
        # ★★ 用**按槽位**的存活判据：`player_alive` 说的是**槽位 0**，
        #   而这个客户端拿到的可能是槽位 1/2…（第一版就是因此误判成「击杀没生效」，
        #   而调试服务器的日志里明明写着「槽位 1 调试击杀」→「实体变成了 guid=24」。）
        def slot_alive(sl):
            return (health().get("players") or {}).get(str(sl), {}).get("alive")

        dead = False
        for _ in range(60):
            if slot_alive(slot) is False:
                dead = True
                break
            time.sleep(0.1)
        if not dead:
            return False, "发了 /debug/kill，但槽位 %d 的 alive 一直是 %r（players=%r）" % (
                slot, slot_alive(slot), health().get("players"))
        # ③ 自动复活
        back = False
        for _ in range(120):                                     # 最多 12 s（阈值 3 s）
            st = health()
            if slot_alive(slot) is True and int(st.get("respawns", 0)) > r0:
                back = True
                break
            time.sleep(0.1)
        if not back:
            return False, "死了之后 12 s 内没自动复活（respawns %s → %s）" % (
                r0, health().get("respawns"))
        # ④ 重问 whoami ⇒ 新 guid，且它必须真的出现在帧里
        g2 = None
        deadline = time.time() + 8
        while time.time() < deadline and (g2 is None or g2 == g1):
            sock.sendall(ws_encode({"cmd": "whoami"}))
            for _ in range(20):
                _op, d = _recv_frame(sock, 5.0)
                try:
                    m = json.loads(d.decode("utf-8"))
                except Exception:                                # noqa: BLE001
                    continue
                if isinstance(m, dict) and m.get("you") is not None:
                    g2 = int(m["you"])
                    break
            if g2 == g1:
                time.sleep(0.3)
        if g2 is None:
            return False, "复活后没问到 you"
        if g2 == g1:
            return False, "复活后服务端还报旧 guid（%s）—— 客户端会一直找不到自己" % g1
        # 新 guid 必须在帧里出现（= 客户端真的能认回自己）
        seen = False
        deadline = time.time() + 6
        while time.time() < deadline and not seen:
            try:
                _op, d = _recv_frame(sock, 5.0)
            except Exception:                                    # noqa: BLE001
                break
            try:
                m = json.loads(d.decode("utf-8"))
            except Exception:                                    # noqa: BLE001
                continue
            if isinstance(m, dict) and "ents" in m:
                for e in m["ents"]:
                    if int(e["id"]) == g2:
                        seen = True
                        break
        if not seen:
            return False, "新 guid（%s）在 6 s 内没出现在帧里 —— 客户端会「找不到自己」" % g2
        # ④b ★ 复活之后**还能不能玩**：输入必须驱动**新的那具身体**。
        #     只验「认回自己」不够 —— 认回来了但按键没反应，用户照样玩不了。
        #     （输入是按**槽位**归因的，所以换身体后应当照常生效；这条就是守这个假设。）

        def drain_until(t_min, want):
            """读到**帧时间戳 ≥ t_min**，返回最后一次见到的 `want` 的位置与所见时间戳。

            ★★ 必须按**帧里的时间戳**排空，不能「读到就返回」：
               本工程已经因为「读到积压的旧帧」假红过三次（§9ab.4 就记过一次）。
               直接返回第一个含该实体的帧 ⇒ 那多半是**按键之前**的帧 ⇒
               位置当然不动 —— 于是把一个**测法问题**误报成 bug。
            """
            last, seen_t = None, 0.0
            for _ in range(900):                                 # 最多 900 帧（30 s）
                try:
                    _op, d = _recv_frame(sock, 5.0)
                except Exception:                                # noqa: BLE001
                    break
                try:
                    m = json.loads(d.decode("utf-8"))
                except Exception:                                # noqa: BLE001
                    continue
                if not (isinstance(m, dict) and "ents" in m):
                    continue
                seen_t = float(m.get("t", 0.0))
                for e in m["ents"]:
                    if int(e["id"]) == want:
                        last = (float(e["x"]), float(e["z"]))
                if seen_t >= t_min:
                    break
            return last, seen_t

        p0, t0 = drain_until(0.0, g2)
        if p0 is None:
            return False, "新身体（guid %s）取不到位置" % g2
        sock.sendall(ws_encode({"k": "right", "v": 1}))
        time.sleep(1.5)
        sock.sendall(ws_encode({"k": "right", "v": 0}))
        p1, t1 = drain_until(t0 + 1.5, g2)                       # 按时间戳排空到「按键之后」
        if p1 is None:
            return False, "复活后按右，帧里找不到自己了"
        if (p1[0] - p0[0]) < 0.5:
            return False, "复活后按右 1.5 s 只动了 %.2f（帧时间 %.1f→%.1f）—— " \
                          "换身体之后输入没接到新身体上" % (p1[0] - p0[0], t0, t1)
        # ⑤ 反向：主服务端没开 --allow-debug ⇒ 同一个端点必须 404
        import urllib.error
        # ★★★ 这里**不许**写「连不上就跳过」。
        #   第一版就是 `except Exception: bad = False   # 连不上就当这条反向不适用`，
        #   于是**浸泡测试第 3 轮**（负载大、主服务端偶尔慢）这条反向**静默失效**了 ——
        #   而指出它的正是**变异测试**：「调试端点不再校验 --allow-debug」那条篡改
        #   突然「没被抓住」⇒ 顺着查才看到这个逃生口。
        #   ⇒ 连不上只能说明**这条反向没验到**，那就该红（未跑的检查等于没有）。
        code = None
        for _ in range(3):
            try:
                with urllib.request.urlopen("http://127.0.0.1:%d/debug/kill?slot=0" % PORT,
                                            timeout=5) as r:
                    code = r.status
                break
            except urllib.error.HTTPError as e:
                code = e.code
                break
            except Exception:                                    # noqa: BLE001
                time.sleep(0.5)                                  # 重试 3 次再说
        if code is None:
            return False, "主服务端（127.0.0.1:%d）的 /debug/kill 连不上（重试 3 次）⇒ " \
                          "**这条反向没验到**，不许当成通过" % PORT
        if code != 404:
            return False, "主服务端（**没有** --allow-debug）的 /debug/kill 返回 %d —— 默认关没生效" % code
        return True, "跨进程：槽位 %d guid %s → 击杀（该槽位存活=false）→ 自动复活（respawns %d→%s）→ " \
                     "重问拿到新 guid %s 且它出现在帧里 ✔ → **复活后按右仍能走**（+%.2f）✔；" \
                     "反向：无 --allow-debug 时该端点 404 ✔" % (
                         slot, g1, r0, health().get("respawns"), g2, p1[0] - p0[0])
    finally:
        if sock is not None:
            try:
                sock.close()
            except Exception:                                    # noqa: BLE001
                pass


def e9_player_light_brings_you_into_light():
    """★★★ 2026-10-16 P38：**随身光源** —— 补 §9ae 登记的那条代理缺口
    （「火把/矿灯不算光源 ⇒ 夜里举着火把走，离火堆一远照样被黑暗打死」）。

    ★ 探针先说清**为什么只能继续走代理**（实测）：宿主里
      `Core.SpawnPrefab("torch")` 的组件是
      `[burnable, equippable, fueled, lighter, inventoryitem, weapon …]` —— **没有 `light`**；
      `lantern` 同样没有 ⇒ 「火把发光」在宿主里**没有组件支撑**。

    做法：`M.set_player_light(slot, r)` —— 按**槽位**登记一个「随身光源」。
    ★★ 为什么按槽位而不是实体 guid（本节的关键）：
       玩家死亡会**自动换一具身体**（`M.respawn`：移除旧实体 + 重建），guid 会变；
       按 guid 登记的话，复活一次随身光源就**悄悄失效**了。

    判据：
      ① 纯函数：开了随身光源 ⇒ 夜里**离任何火都很远**也算在光里；
      ② **反向**：关掉之后，**同一个坐标、同样夜里** ⇒ 必须**不算**在光里
         （证明 ① 是随身光源带来的，而不是那个位置本来就有光）；
      ③ ★★ **复活换了一具身体之后仍然有效**（同一槽位）—— 「按槽位」的全部理由；
      ④ 可观测：`stats()["players"]["0"]` 的 `in_light` / `light_r` 与 `player_light` 计数对得上。
    """
    s = Sim(seed=20261015, tick_hz=30).boot()
    L = s.lua
    L.globals().RT = s.api

    def ev(code):
        return L.eval("(function() " + code + " end)()")

    def st():
        return s.stats()

    def slot0():
        return (st().get("players") or {}).get("0") or {}

    r = str(ev("""
      local p = RT.player
      local x, y, z = p.Transform:GetWorldPosition()
      return string.format('%.2f|%.2f', x, z)"""))
    px, pz = [float(v) for v in r.split("|")]
    far_x, far_z = px + 300.0, pz + 300.0        # 离任何火都远（半径默认 7）

    def far_lit():
        # ★ 用 replace 而不是 Python 的 `%`：这段 Lua 里没有 %，但这是本工程反复踩过的坑，
        #   一律按「不把 Lua 串交给 Python 的 % 格式化」来写。
        return bool(ev("return RT.in_light_for_slot(0, __X__, __Z__, true)"
                       .replace("__X__", "%.2f" % far_x).replace("__Z__", "%.2f" % far_z)))

    # 前提：没开光源时，那个点夜里**不在**光里（否则下面测不出东西）
    if far_lit():
        return False, "前提不成立：离火 300 格的那个点本来就算在光里 —— 判据测不出东西"

    # ① 开随身光源 ⇒ 远处也算在光里
    ok, msg = s.api.set_player_light(0, 5)
    if not ok:
        return False, "set_player_light 失败：%s" % msg
    if not far_lit():
        return False, "开了随身光源，夜里离火 300 格竟然还不算在光里"

    # ★ ④ 的可观测要**先让引擎推进几拍**：`players[slot].in_light` 由 `sync_grue_light`
    #   在推进时填进 `LIGHT_STATE`，刚 boot 完还没跑过 ⇒ 会是 "?"（第一版就是这么红的）。
    for _ in range(10):
        s.step()

    # ④ 可观测
    if slot0().get("in_light") is not True:
        return False, "stats().players['0'].in_light 应为 true，实为 %r" % slot0().get("in_light")
    if int(st().get("player_light", -1)) != 1:
        return False, "stats().player_light 计数应为 1，实为 %r" % st().get("player_light")
    if slot0().get("light_r") != 5:
        return False, "stats().players['0'].light_r 应为 5，实为 %r" % slot0().get("light_r")

    # ② 反向：关掉 ⇒ 同一点、同样夜里 ⇒ 不算在光里
    s.api.set_player_light(0, 0)
    if far_lit():
        return False, "关掉随身光源之后，那个点竟然还算在光里 —— 反向没测到东西"
    if int(st().get("player_light", -1)) != 0:
        return False, "关掉后 player_light 计数应为 0，实为 %r" % st().get("player_light")

    # ③ ★★ 复活换身体之后仍然有效（证明挂在**槽位**上，而不是某个实体的 guid 上）
    s.api.set_player_light(0, 5)
    g_before = slot0().get("guid")
    L.eval("(function() RT.player.components.health:DoDelta(-9999) return 1 end)()")
    for _ in range(60):
        s.step()
    # 等自动复活（延迟 3 s）；判据是「guid 变了」＝真的换了身体
    g_after = g_before
    for _ in range(900):                          # 30 s 预算
        s.step()
        g_after = slot0().get("guid")
        if g_after is not None and g_after != g_before and slot0().get("alive") is True:
            break
    if g_after == g_before:
        return False, "没换身体（guid 仍是 %r）—— ③ 的前提不成立，测不出「按槽位」" % g_before
    if not far_lit():
        return False, "复活换了身体（guid %r → %r）之后随身光源失效了 —— 说明它挂在了 guid 上" % (
            g_before, g_after)
    return True, ("随身光源：夜里离火 300 格也算在光里 ✔；反向（关掉即失效）✔；"
                  "★ 复活换了身体（guid %s → %s）之后仍然有效（= 挂在槽位上，不随实体消失）✔；"
                  "stats 的 in_light/light_r/player_light 都对得上 ✔" % (g_before, g_after))


def e10_player_state():
    """★★★ 2026-10-18 P39：**自己现在什么状态，要看得见**（血 / 饿 / 理智 / 背包）。

    缺口（在此之前）：
      玩家身上 health / hunger / sanity / inventory 四个组件**都在**（实测 wilson 共 88 个），
      但对用户完全不可见 —— 捡起一根木头，屏幕上一个字都没有；饿了不知道；
      掉血了也说不出为什么。发布出去的东西「能走能砍」却「不知道自己怎么样」，
      这不是玩法深度问题，是**信息缺失**。

    判据：
      ① 引擎层：`player_state(0)` 报出 150/150、饥饿在 [0,max]、理智 200/200；
      ② 背包：空 → 喂 2 个 log + 1 个 twigs ⇒ 聚合为 `log×2 / twigs×1`（按数量降序）；
      ③ **反向**：饥饿必须**真的在掉**（推进 3 s 后比开始时小）——
         否则「有数字」可能是个死值（本工程吃过「恒为 35 度」那种亏）；
      ④ **反向**：不存在的槽位 ⇒ `ok=false` 且**带原因**，不许回一串 0
         （0 血看起来像「快死了」，而事实是「这个人不存在」）；
      ⑤ 跨进程：WS 发 `{cmd:'me'}` 必须回 `me`，且 `health` 与 `/healthz` 的
         `players[槽位].health` **一致**（两个真相源对账，防「各自算各自的」）。
    """
    s = Sim(seed=20261015, tick_hz=30).boot()
    L = s.lua
    L.globals().RT = s.api
    # ★★★ 这里**不能**用 `_pin_player_alive`（2026-10-18 踩到的）：
    #   它调的是 `health:SetInvincible(true)`，而原版 `hunger.lua` 的
    #   `DoDelta(delta, overtime, ignore_invincible)` 里那句
    #       `if not ignore_invincible and health and health:IsInvincible() or is_teleporting then return end`
    #   把**无敌的玩家饿也饿不着**（DoDec 只传了 2 个参数，ignore_invincible 是 nil）。
    #   于是「钉住生死」这个动作**顺手把被测的那个量也钉死了** ——
    #   实测：pin 之后 90 拍 hunger 150.000 → 150.000（看着像「饥饿是死值」，
    #   其实是**我的隔离手段**造成的）。⇒ 改成**逐拍补血**（不加无敌），
    #   这样玩家死不了，饥饿照常结算。

    def keep_alive(steps):
        for _ in range(steps):
            s.step()
            L.eval("(function() local h = RT.player.components.health "
                   "if h ~= nil and h.currenthealth < h.maxhealth then h:SetPercent(1) end "
                   "return 1 end)()")

    def pst(slot=0):
        return s.player_state(slot)

    # ① 基本值
    st = pst(0)
    if st.get("ok") is not True:
        return False, "player_state(0) 没报 ok：%r" % (st.get("why"),)
    if st.get("health") != 150 or st.get("maxhealth") != 150:
        return False, "血量应为 150/150，实为 %r/%r" % (st.get("health"), st.get("maxhealth"))
    if st.get("sanity") != 200 or st.get("maxsanity") != 200:
        return False, "理智应为 200/200，实为 %r/%r" % (st.get("sanity"), st.get("maxsanity"))
    hu, hm = st.get("hunger"), st.get("maxhunger")
    if not isinstance(hu, (int, float)) or not isinstance(hm, (int, float)):
        return False, "饥饿应当是数字，实为 %r/%r" % (hu, hm)
    if not (0 <= hu <= hm):
        return False, "饥饿 %r 不在 [0,%r] 里" % (hu, hm)
    if st.get("items") != []:
        return False, "新角色背包应为空，实为 %r" % (st.get("items"),)

    # ② 背包聚合
    L.eval("""(function()
      local C = require("host.01_core")
      local p = RT.player
      for _, name in ipairs({"log", "log", "twigs"}) do
        local it = C.SpawnPrefab(name)
        p.components.inventory:GiveItem(it)
      end
      return 1
    end)()""")
    st2 = pst(0)
    got = {str(r["p"]): int(r["n"]) for r in st2.get("items") or []}
    if got.get("log") != 2:
        return False, "背包里 log 应为 2，实为 %r（全部：%r）" % (got.get("log"), got)
    if got.get("twigs") != 1:
        return False, "背包里 twigs 应为 1，实为 %r（全部：%r）" % (got.get("twigs"), got)
    if int(st2.get("total") or -1) != 3:
        return False, "总数应为 3，实为 %r" % (st2.get("total"),)
    items_seq = [str(r["p"]) for r in st2.get("items") or []]
    if items_seq != ["log", "twigs"]:
        return False, "顺序应按数量降序（log 在前），实为 %r" % (items_seq,)

    # ③ 反向：饥饿**真的在掉**
    h0 = float(st2.get("hunger"))
    keep_alive(90)                     # 3 s 世界时间（逐拍补血，不用无敌 —— 理由见上）
    h1 = float(pst(0).get("hunger"))
    if not (h1 < h0):
        return False, "推进 3 s 后饥饿没变（%r → %r）—— 这个数是个死值" % (h0, h1)

    # ④ 反向：不存在的槽位
    bad = pst(999)
    if bad.get("ok") is not False:
        return False, "不存在的槽位竟然报 ok=true：%r" % (bad,)
    if not bad.get("why"):
        return False, "不存在的槽位没给原因（用户只会看到一串 0）"
    if bad.get("health") not in (None,):
        return False, "不存在的槽位却报了血量 %r（会被读成「快死了」）" % (bad.get("health"),)

    # ⑤ 跨进程：WS 的 me 与 /healthz 对账
    import urllib.request
    import ws as wsmod
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    try:
        wsmod.client_handshake(sock, "127.0.0.1:%d" % PORT)
        sock.sendall(ws_encode({"cmd": "whoami"}))
        slot_no, me = None, None
        next_ask = 0.0
        deadline = time.time() + 8.0
        while time.time() < deadline:
            # ★ 重问而不是「问一次就当真」：服务端是在**模拟线程**里按节拍算这张表的，
            #   刚连上时会如实回 `ok:false —— 还没算出来（稍后再问）`。
            #   第一版只看第一条回复 ⇒ 拿到那句「稍后再问」就判红（**我的判据错了**，
            #   不是服务端没做；它说得很清楚）。
            if slot_no is not None and time.time() >= next_ask:
                sock.sendall(ws_encode({"cmd": "me"}))
                next_ask = time.time() + 0.3
            op, data = _recv_frame(sock, 0.5)
            if op != 1 or not data:
                continue
            try:
                m = json.loads(data.decode("utf-8"))
            except Exception:                                # noqa: BLE001
                continue
            if isinstance(m, dict) and "you" in m and not m.get("busy"):
                slot_no = int(m.get("slot", 0))
            # ★ `isinstance(..., dict)` 是必须的：`m["me"]` 的形态由**服务端**决定，
            #   判据这边先假设它一定是 dict，就等于把「服务端发错了」变成一句
            #   `'int' object has no attribute 'get'`（同一个坑本轮踩过两次）。
            if isinstance(m, dict) and isinstance(m.get("me"), dict) and m["me"].get("ok") is True:
                me = m["me"]
                break
        if me is None:
            return False, "WS 反复发了 {cmd:'me'}，但一直没拿到 ok=true 的回复（服务端没算出来？）"
        if slot_no is None:
            return False, "拿到了 me，但 whoami 一直没给出槽位号（对不了账）"
        for k in ("health", "maxhealth", "hunger", "sanity", "items"):
            if k not in me:
                return False, "me 回复缺字段 %r：%r" % (k, sorted(me))
        h = json.loads(urllib.request.urlopen(
            "http://127.0.0.1:%d/healthz" % PORT, timeout=5).read().decode("utf-8"))
        # ★★ 按槽位的血量在 **`stats.players`** 下面，不是顶层。
        #   顶层那个（我原先当成了这张表）是**在线人数**、类型是 int ——
        #   两个字段以前都叫 `players`，所以「看起来完全对」，炸在 `.get`。
        #   现在顶层那个已改名 `player_count`（rt/server.py 里记了原因）。
        #   万一以后再变形，错误信息里要带上**实际结构**，别再让我靠猜：
        pl = ((h.get("stats") or {}).get("players") or {}).get(str(slot_no)) or {}
        # ★ 2026-10-18：`stats` 改成**模拟线程每 8 拍刷一次的缓存**（不再跨线程进 Lua），
        #   所以它最多落后 0.27 s —— 刚连上时槽位可能还没进统计。
        #   ⇒ 与 `me` 同一个套路：**重问到出现为止**，而不是「第一次没有就判失败」。
        for _retry in range(20):
            if pl:
                break
            time.sleep(0.3)
            h = json.loads(urllib.request.urlopen(
                "http://127.0.0.1:%d/healthz" % PORT, timeout=5).read().decode("utf-8"))
            pl = ((h.get("stats") or {}).get("players") or {}).get(str(slot_no)) or {}
        if not pl:
            return False, ("/healthz 的 stats.players 里没有槽位 %r（现有槽位：%r；顶层的键：%r）"
                           % (slot_no, sorted((((h.get("stats") or {}).get("players")) or {})),
                              sorted(h)))
        if pl.get("health") != me.get("health"):
            return False, ("两条链路的血量不一致：/healthz=%r vs me=%r"
                           % (pl.get("health"), me.get("health")))
    finally:
        try:
            sock.close()
        except OSError:
            pass

    return True, ("血 150/150 · 饿 %r/%r · 理智 200/200 · 背包 log×2+twigs×1（共 3 件）✔；"
                  "反向：3 s 后饥饿 %r→%r（真在掉）✔；不存在的槽位带原因、不报 0 ✔；"
                  "跨进程 me 与 /healthz 血量一致（槽位 %r）✔"
                  % (hu, hm, h0, h1, slot_no))


def d4_session_identity_survives_restart():
    """★★★ 2026-10-16 新增：**会话身份挺过重启**（P21 登记过的缺口，现在补上）。

    以前 `slot → 会话 key` 只活在服务端**内存**里 ⇒ 重启之后每个客户端都会拿到**新**角色，
    而旧角色（带着它走过的路）只能当「没人认领」删掉 —— 代码注释里写着
    「真要保留他们，得先做『客户端身份持久化』」。这一轮做了：

    * 存档里多两张表：`players`（槽位 → **旧 guid**）与 `keys`（槽位 → 会话 key）；
    * `rt_save.apply` 顺手交出「**旧 guid → 重建出来的新实体**」这张表
      （重建出来的实体是**新 guid**，老 guid 随清场消失 —— 没有这张表就翻译不过去）；
    * 读档后按它**重新绑定** `槽位 → 角色`，只把**真正没人认领**的 wilson 删掉。

    判据：
      ① 两个角色（槽位 0 默认 + 槽位 1）、给槽位 1 记一个 key、把槽位 1 走到别处 ⇒ 存档；
      ② 新 Sim 读档后：`slot_keys()[1]` **仍是那个 key**；两个槽位**都**有有效实体；
         **槽位 1 的位置等于存档时的位置**（= 它的角色被保留了，不是新建在出生环上）；
      ③ **反向**：没有 key 的存档（全新世界）读档后 `slot_keys()` 必须为空，
         且「没人认领的角色」仍然会被清掉（旧行为不许被这次改动弄丢）。
    """
    import tempfile
    sf = os.path.join(tempfile.gettempdir(), "rt_d4_save.json")
    if os.path.exists(sf):
        os.remove(sf)

    s1 = Sim(seed=20261015, tick_hz=30).boot()
    L = s1.lua
    L.globals().RT = s1.api

    def ev(code):
        return L.eval("(function() " + code + " end)()")

    # ① 造第二个角色并让它走开，再记一个 key
    ok, g1 = s1.api.add_player(1)
    if not ok:
        return False, "加不了第二个玩家：%s" % g1
    # ★ 必须**在 Lua 里**构造这张表：从 Python 直接传 dict，lupa 给过去的是 **userdata**，
    #   而 Lua 那边 `pairs(map)` 会报 "table expected, got userdata"（第一版就是这么红的）。
    #   服务端那边同理，用的是它自己的 `_py_to_lua()`。
    ev('RT.set_slot_keys({[1] = "kA"}) return true')
    s1.api.set_input_for(1, "right", True)
    for _ in range(90):
        s1.step()
    s1.api.set_input_for(1, "right", False)
    # ★ 用**字符串替换**而不是 `%` 格式化：这段 Lua 里有 `%.3f`，
    #   用 Python 的 `%` 会把它当成占位符 ⇒ "not enough arguments"（今天第二次踩同款）。
    # ★★ 这里**必须**直接 `L.eval`，不能走上面的 `ev()` 包装：
    #   `ev(code)` 会把 code 包成 `(function() <code> end)()`，而下面这段 code
    #   **本身就是** `(function() … end)()` ⇒ 外层函数体里只剩一句**表达式语句、
    #   没有 return** ⇒ 外层返回 nil ⇒ Python 侧拿到 None（2026-10-16 实测踩到：
    #   D4 报「位置 None → 23.8|0」，其实是**判据自己的包装**吞掉了返回值，
    #   不是引擎没保住位置。＝「判据错被当成宿主缺口」的同款形态）。
    def _pos_script(guid):
        return """(function()
      local e = RT.snapshot()
      for _, x in ipairs(e.ents) do
          if x.id == __G__ then return string.format('%.3f|%.3f', x.x, x.z) end
      end
      return "-|-" end)()""".replace("__G__", str(int(guid)))

    def pos_of(L_, guid):
        return L_.eval(_pos_script(guid))

    p0 = pos_of(L, g1)
    if str(p0).startswith("-"):
        return False, "存档前找不到槽位 1 的实体（guid=%s）" % g1
    n_before = int(s1.stats()["n_ents"])
    s1.autosave(sf)

    # ② 重启读档
    s2 = Sim(seed=20261015, tick_hz=30).boot()
    ok2, msg = s2.try_load(sf)
    if not ok2:
        os.remove(sf)
        return False, "读档失败：%s" % msg
    L2 = s2.lua
    L2.globals().RT = s2.api
    keys = s2.api.slot_keys()
    keys = {int(k): str(v) for k, v in (dict(keys) if keys is not None else {}).items()}
    if keys.get(1) != "kA":
        os.remove(sf)
        return False, "读档后会话 key 丢了：%r（应 {{1: 'kA'}}）" % keys
    bound = s2.api.player_slots_bound()
    bound = {int(k): int(v) for k, v in (dict(bound) if bound is not None else {}).items()}
    if 0 not in bound or 1 not in bound:
        os.remove(sf)
        return False, "读档后槽位没绑回来：%r（应含 0 与 1）" % bound
    g_new = int(bound[1])
    p1 = str(pos_of(L2, g_new))
    os.remove(sf)
    if p1 != str(p0):
        return False, "槽位 1 的角色**没有**接着上次：位置 %s → %s（应逐值一致）" % (p0, p1)

    # ③ 反向：没有 key 的存档 ⇒ key 表必须为空（不许凭空冒出身份）
    sf2 = os.path.join(tempfile.gettempdir(), "rt_d4_save2.json")
    s3 = Sim(seed=20261015, tick_hz=30).boot()
    s3.autosave(sf2)
    s4 = Sim(seed=20261015, tick_hz=30).boot()
    ok4, _ = s4.try_load(sf2)
    k4 = s4.api.slot_keys()
    n4 = len(dict(k4)) if k4 is not None else 0
    os.remove(sf2)
    if not ok4 or n4 != 0:
        return False, "没有身份信息的存档读出来后 slot_keys 不是空的（%d 项）" % n4
    return True, "存档 %d 实体 ⇒ 读档后 key{1:'kA'} 保住、槽位 0/1 都绑回来了、" \
                 "槽位 1 位置 %s **逐值一致**（角色被保留而不是新建）；反向：无 key 的存档读出来仍是空" % (
                     n_before, p0)


def e2_chop_down_and_loot():
    """★★★ 2026-10-16 新增：**砍倒 → 掉木头**（P22 当时没跑通、被登记成「未查」的那条）。

    ★★★ 先说清机制 —— 这一轮我在这里**猜错过一次**，量出来的事实与直觉相反：
      · **一次 `push_action` = 一次敲击，仅此而已**。
        实测：树放 1.0 格外、只 push 一次 ⇒ workleft 15 → 14，然后**永远停在 14**；
      · 「连砍」是**服务端按 `ACT_REPEAT`（30 拍 = 1 s）定时重发**撑起来的。
        实测：每秒重发 ⇒ 15 → 14 → … → 1 → 倒下（`CHOP`→`DIG`）+ **掉 3 个 log**。
      （我原先以为「原版动作链自己会循环、重发反而打断它」，据此把重发删了 ——
        E1/E2 立刻变红，因为一次 push 只敲一下，删掉重发就一次都砍不倒。已还原。）

    判据（**反向就长在同一次运行里**，这样「时间/步数」是同一个变量，控制得最干净）：
      ① 挑**最高档**的树 A（workleft 最大）放身边、另一个同档树 B 放 6 格外；
      ② 对 A 发**一次** `act`（客户端真实的做法就是按一次），**不再发第二次**，
         然后跑足够长的世界时间（50 s 预算；最高档 15 点约 15~19 s 砍完）；
      ③ A 的 `workable.action` 必须从 `CHOP` 变成 `DIG`
         （`make_stump` 把同一个实体改成了树桩 —— 这就是「倒下了」的可观测证据）；
      ④ 世界里必须**出现 `log`**（`lootdropper:DropLoot` 真的掉了东西）；
      ⑤ 反向：B **一次都没被 act 过** ⇒ 它必须还是 `CHOP`、workleft 一点没少。
    """
    s = Sim(seed=20261015, tick_hz=30).boot()
    L = s.lua
    L.globals().RT = s.api
    _pin_player_alive(L)            # ★ 钉住与「能不能砍倒」无关的变量（玩家生死），见该函数说明
    info = L.eval("""(function()
      local C = require("host.01_core")
      local p = RT.player
      local x, y, z = p.Transform:GetWorldPosition()
      -- ① 挑 workleft 最大的那一档（evergreen 的 stage 是随机的：5 / 10 / 15）
      local best, bestwl = nil, -1
      for _ = 1, 60 do
          local ok, t = pcall(C.SpawnPrefab, "evergreen")
          if ok and t ~= nil then
              local wl = t.components.workable and t.components.workable.workleft or 0
              if bestwl < 0 or wl > bestwl then
                  if best ~= nil then best:Remove() end
                  best, bestwl = t, wl
              else
                  t:Remove()
              end
          end
      end
      if best == nil then return "-1|-1|-1" end
      best.Transform:SetPosition(x + 1.5, 0, z)
      RT._a = best
      -- ⑤ 反向用的那棵：**同一次运行里**、同样长时间、就是不发 act
      local ok2, b = pcall(C.SpawnPrefab, "evergreen")
      b.Transform:SetPosition(x + 6.0, 0, z)
      RT._b = b
      return tostring(bestwl) .. "|" .. tostring(best._guid) .. "|" ..
             tostring(b.components.workable and b.components.workable.workleft or -1)
    end)()""")
    wl_a, guid_a, wl_b = str(info).split("|")
    if int(wl_a) < 0:
        return False, "造不出 evergreen（引擎里没有这个预制体？）"
    guid_a = int(guid_a)

    def state(ref):
        return str(L.eval("""(function()
          local t = RT.%s
          if t == nil or not t:IsValid() then return "gone" end
          local w = t.components.workable
          if w == nil then return "noworkable" end
          return tostring(w.workleft) .. "|" .. tostring(w.action and w.action.id)
        end)()""" % ref))

    def logs():
        return int(L.eval("""(function() local n = 0
          for _, e in ipairs(RT.snapshot().ents) do
              if e.p == "log" then n = n + 1 end end
          return n end)()"""))

    # ② 只发一次
    ok, msg = s.api.act(0, guid_a)
    if not ok:
        return False, "对 1.5 格外的树发 act 被拒：%s" % msg
    logs0 = logs()
    for _ in range(1500):                      # 50 s 预算（最高档 15 点约 19 s）
        s.step()

    a = state("_a")
    b = state("_b")
    nlog = logs()
    # ③ 倒下了 = **树桩**（同一实体的 action 从 CHOP 变 DIG）**或**实体已被移除。
    #   ★ 宿主上这两条路都出现过（取决于倒下时那一拍有没有后续的清理任务），
    #     所以判据认「离开了 CHOP 状态」这件事本身 —— 那才是「倒下了」的本质。
    felled = (a == "gone") or a.endswith("|DIG")
    if not felled:
        return False, "50 s 后树 A 仍是 %s（没倒下）" % a
    # ④ 掉东西了
    if nlog <= logs0:
        return False, "树倒了却一个 log 都没掉（末态 %s）" % a
    # ⑤ 反向：没被 act 过的那棵必须原样
    if not b.endswith("|CHOP"):
        return False, "**没被 act 过**的树 B 竟然也变了：%s" % b
    if b.split("|")[0] != str(wl_b):
        return False, "没被 act 过的树 B workleft 从 %s 变成 %s" % (wl_b, b.split("|")[0])
    return True, "树 A（workleft %s）一次 act → %s + 掉 %d 个 log；" \
                 "反向：树 B 未被 act，仍是 %s（控制住了「时间」这个变量）" % (
                     wl_a, ("已移除" if a == "gone" else "倒下（CHOP→DIG）"), nlog - logs0, b)


def e3_pickup_item():
    """★★ 2026-10-16 新增：**捡起来**（§9w.2 第 2 条的正解；旧结论是**错诊断**）。

    旧文档写的是「拾取不可用：`inventory:GetItems()` 不存在（宿主那层是桩）」。实测：
      ① 原版 `Inventory` **根本没有 `GetItems`** —— 真接口是 `GetItemInSlot` / `FindItem` /
         `GetItemsWithTag` / `Has` / `GetNumSlots` / `GiveItem`，而这些**在宿主里全都能用**
         （`GetNumSlots()=15`、`GiveItem(log)` ⇒ `Has("log",1)` 真）；
      ② `ACTIONS.PICKUP.fn` 直接调用**能成**（log / twigs 都进了背包）；
      ③ `loco:PushAction(PICKUP)` 之后动作**没人消费** —— 顺着源码走：对「带 target 的动作」，
         `PushAction` 走 `GoToEntity`，**动作是在判定「到达」之后才执行的**。
         到达距离 = `ARRIVE_STEP + rad(owner) + rad(self)` 再 `max(…, bufferedaction.distance)`；
         `ACTIONS.CHOP.distance = 1.75` ⇒ 站 1.2 格外也算到达（实测能砍）；
         而 `ACTIONS.PICKUP` **没有 `distance`**（它用 `extra_arrive_dist`）⇒ 实测
         **只有站在物品正上方（0.0 格）才算到达**（0.2 格就捡不到）。
      ⇒ 真正缺的是两处 **07 侧接线**：`action_for()` 认不认地上的物品、
        以及用原版留的钩子 `bufferedaction.arrivedist` 把到达距离补上。

    判据：
      ① `log` 放在 1.0 格外 ⇒ 必须出现在 `act_targets` 里、动作名 `PICKUP`；
      ② 发**一次** `act` ⇒ 物品进背包（`Has("log",1)`）且**离开世界**；
      ③ 反向：同一次运行里另放一份 `twigs`、**不 act** ⇒ 它必须还在原地、背包里没有；
      ④ 反向：「补到达距离」这件事**必须有记账**（`act_arrive_patched() ≥ 1`）——
         否则那就成了一次静默的替原版打补丁（本工程最忌讳的那类）。
    """
    s = Sim(seed=20261015, tick_hz=30).boot()
    L = s.lua
    L.globals().RT = s.api
    _pin_player_alive(L)            # ★ 同上（E3 也要，否则玩家会在 4 s 内掉血致死）
    info = L.eval("""(function()
      local C = require("host.01_core")
      local p = RT.player
      local x, y, z = p.Transform:GetWorldPosition()
      local ok1, log = pcall(C.SpawnPrefab, "log")
      if not ok1 or log == nil then return "-1|-1|-1" end
      log.Transform:SetPosition(x + 1.0, 0, z)
      RT._log = log
      local ok2, tw = pcall(C.SpawnPrefab, "twigs")
      tw.Transform:SetPosition(x, 0, z + 2.0)
      RT._tw = tw
      return tostring(log._guid) .. "|" .. tostring(tw._guid) .. "|" .. tostring(log.prefab)
    end)()""")
    guid_log, guid_tw, _ = str(info).split("|")
    if int(guid_log) < 0:
        return False, "造不出 log 预制体"
    guid_log = int(guid_log)

    def has(what):
        # ★★ 判据**不用** `Inventory:Has`，自己数槽位。
        #   为什么（2026-10-16）：E3 的运行里 `Has("twigs",1)` 报过一次「在背包里」，
        #   而同一时刻把 `itemslots` 摊开只有 `log`（隔离复现时 `Has` 又是对的 —— 未复现）。
        #   ⇒ 失败信息指向一个我**解释不了**的谓词，等于把排查成本丢给下一个人。
        #   这条判据只依赖**我自己能读懂的**事实：槽位里到底放了什么。
        #   （`Has` 的那次异常另立登记，见 §9y.8。）
        return int(L.eval("(function() local inv = RT.player.components.inventory "
                          "if inv == nil then return -1 end "
                          "local n = 0 "
                          "for _, v in pairs(inv.itemslots) do "
                          "  if v ~= nil and v.prefab == %r then n = n + 1 end end "
                          "return n end)()" % what))

    def in_world(ref):
        return bool(L.eval("(function() local t = RT.%s "
                           "return t ~= nil and t:IsValid() and not t:IsInLimbo() end)()" % ref))

    # ① 目标列表里必须出现这个物品，且动作名来自引擎（PICKUP）
    tg = s.api.act_targets(0, 20)
    hits = [dict(t) for t in tg.values()] if hasattr(tg, "values") else [dict(tg[i]) for i in range(1, len(tg) + 1)]
    mine = [h for h in hits if h.get("id") == guid_log]
    if not mine:
        return False, "1.0 格外的 log 没出现在 act_targets 里（action_for 不认地上的物品？）"
    if mine[0].get("a") != "PICKUP":
        return False, "log 的动作名是 %r，应为 PICKUP" % mine[0].get("a")

    before_has_log = has("log")
    before_tw = in_world("_tw")
    # ★ 前置条件必须**真的断言**（不是算出来放在那儿）：
    #   否则「捡到之后 twigs 还在」这条反向可能因为「它一开始就不在」而白白通过。
    #   （这一条是 pyflakes 提醒出来的：`before_tw` 赋值了却从没被用 —— 一个**空洞**。）
    if before_has_log != 0:
        return False, "捡之前背包里就有 log（%d 个）—— 判据的前提不成立" % before_has_log
    if not before_tw:
        return False, "捡之前 twigs 就不在世界里 —— 反向的前提不成立"
    # ② 只发一次 act
    ok, msg = s.api.act(0, guid_log)
    if not ok:
        return False, "对 1.0 格外的 log 发 act 被拒：%s" % msg
    for _ in range(120):                       # 4 s
        s.step()
    if has("log") < 1:
        return False, "发过 act 了，背包里仍然没有 log（到达距离没生效？）"
    if in_world("_log"):
        return False, "log 进了背包却仍留在世界里（重复）"
    # ③ 反向：没被 act 过的那份必须原样
    def invdump():
        return str(L.eval("""(function()
          local inv = RT.player.components.inventory
          local out = {}
          for i = 1, 15 do
              local ok, it = pcall(function() return inv:GetItemInSlot(i) end)
              if ok and it ~= nil then out[#out+1] = i .. ":" .. tostring(it.prefab) end
          end
          return table.concat(out, ",") end)()"""))
    if not in_world("_tw"):
        return False, "**没被 act 过**的 twigs 竟然离开了世界（背包=[%s] log=%s tw=%s）" % (
            invdump(), guid_log, guid_tw)
    if has("twigs") > 0:
        return False, "**没被 act 过**的 twigs 竟然进了背包（背包=[%s] log=%s tw=%s）" % (
            invdump(), guid_log, guid_tw)
    # ④ 反向：补参数必须有记账
    n_patch = int(s.api.act_arrive_patched())
    if n_patch < 1:
        return False, "「补到达距离」没有记账（act_arrive_patched=0）—— 那就成了静默打补丁"
    return True, "log 在目标列表里（PICKUP）→ 一次 act ⇒ 进背包且离开世界；" \
                 "反向：没被 act 的 twigs 原地不动、背包里也没有；补到达距离记账 %d 次" % n_patch


def b24_ping_pong():
    """★ 计划 §4 的 2.4 要「延迟」。浏览器 WebSocket **不暴露** ping/pong 帧
       ⇒ 只能在应用层做：客户端发 `{cmd:"ping",v:序号}`，服务端回 `{pong:序号}`。

       判据：
         ① 收到 `{pong:N}` 且序号原样回显；
         ② **不是快照**（没有 `ents`/`tick`）—— 混进的后果是客户端画面空一帧；
         ③ ping **不得被计入坏帧**（那是「未知指令」的待遇，会污染健康指标）。
    """
    import ws as wsmod
    sock = _connect()
    try:
        for _ in range(4):
            _recv_frame(sock)
        _, body = _http_get("/healthz")
        bad0 = json.loads(body)["dropped_bad_frames"]
        sock.sendall(wsmod.encode_frame_masked(
            json.dumps({"cmd": "ping", "v": 4242}).encode("utf-8")))
        deadline = time.time() + 3.0
        while time.time() < deadline:
            _, d = _recv_frame(sock)
            m = json.loads(d.decode("utf-8"))
            if "pong" in m:
                if m["pong"] != 4242:
                    return False, "pong 序号不对：%s" % m.get("pong")
                if "ents" in m or "tick" in m:
                    return False, "pong 里混进了快照字段：%s" % sorted(m)
                _, body = _http_get("/healthz")
                bad1 = json.loads(body)["dropped_bad_frames"]
                if bad1 != bad0:
                    return False, "ping 被计入坏帧（%d → %d）—— 客户端会看到健康指标变差" % (bad0, bad1)
                return True, "收到 {pong:4242}（非快照、未计入坏帧）"
        return False, "3 s 内没收到 pong"
    finally:
        sock.close()


def b23_frame_only_drawable_and_sorted():
    """★ 帧里只许有**可绘制的**实体，且**顺序稳定**（两条都是踩出来的）。

       ★ 现象一：宿主 `Spawned` 里混着内部登记实体（实测 `guid=1` 是 TheWorld 本体、
         `guid=2/3` 是只有 `knownlocations` 一个组件的内部表）—— 它们 `prefab == nil`、
         没有 AnimState、**根本不可绘制**。其中 guid=2 **带位置**（(0,0)），
         于是它作为「匿名实体」进了帧，客户端按老规矩给它画了个**回退灰点**，
         正好压在玩家身上 ⇒ 症状是「玩家身上粘了个灰点」。
       ★ 现象二：`for guid, inst in pairs(ents)` 的顺序**未定义**，而客户端是
         **按帧序绘制**的 ⇒ 实体增删时前后关系会变 ⇒ 画面**闪**。

       判据（缺一条就有盲区）：
         ① 每个实体都要有 `prefab`（没有 = 内部实体混进来了）；
         ② id **递增**（绘制顺序稳定）；
         ③ 反向：宿主里 `prefab == nil` 的那些实体**必须不在帧里**（直接打死现象一）；
         ④ 隔一段时间再看，id 序列**完全一致**（打死现象二）；
         ⑤ `n` 必须等于 `ents` 的长度（帧自洽）。
    """
    s = Sim(seed=20261015, tick_hz=30).boot()
    L = s.lua
    for _ in range(30):
        s.step()
    # 先造一点多样性：生成一批生物（它们的 `*_classified` 镜像正是要防的东西）
    s.api.spawn_extra(20)
    for _ in range(20):
        s.step()
    f1 = s.snapshot()
    ents = f1["ents"]
    anon = [e["id"] for e in ents if not e.get("p")]
    if anon:
        return False, "帧里有 %d 个没有 prefab 的实体: %s（客户端会画成灰点）" % (len(anon), anon)
    nobld = [e["id"] for e in ents if not e.get("bld")]
    if nobld:
        return False, "帧里有 %d 个**没有 build** 的实体: %s（客户端画不出来，只能画灰点）" % (
            len(nobld), nobld)
    ids = [e["id"] for e in ents]
    if ids != sorted(ids):
        return False, "实体 id 不是递增的 ⇒ 绘制顺序不稳定（会闪）: %s" % ids
    if f1["n"] != len(ents):
        return False, "n=%d 但 ents 有 %d 个（帧不自洽）" % (f1["n"], len(ents))
    # ③ 反向：**内部实体 / 客户端镜像**必须不在帧里。
    #   ★ 探针查的是宿主的**事实**（prefab==nil 或没有 build），
    #     而不是「名字里带 _classified」那种猜法 —— 换任何名字这条判据照样成立。
    bad_guids = [x for x in L.eval(
        '(function() local Core = require("host.01_core") local t = {} '
        'for guid, inst in pairs(Core.Spawned or {}) do '
        'local as = inst.AnimState '
        'if inst.prefab == nil or as == nil or as._build == nil then '
        't[#t+1] = tostring(guid) end end '
        'table.sort(t) return table.concat(t, "\\n") end)()').split("\n") if x]
    if not bad_guids:
        return False, "探针失效：宿主里所有实体都有 prefab 且有 build ⇒ 这条判据暂时没有意义（如实报出来）"
    leaked = [g for g in bad_guids if int(g) in ids]
    if leaked:
        return False, "不可绘制的实体（内部登记/客户端镜像，共 %d 个）混进了帧: %s" % (
            len(bad_guids), leaked[:6])
    # ④ 顺序稳定性
    for _ in range(10):
        s.step()
    f2 = s.snapshot()
    if [e["id"] for e in f2["ents"]] != ids:
        return False, "两帧的实体顺序不同：%s vs %s" % (ids, [e["id"] for e in f2["ents"]])
    return True, "%d 个实体全部**有 prefab 且有 build**、id 递增且跨帧稳定；宿主内 %d 个不可绘制实体未混入" % (
        len(ents), len(bad_guids))


def b22_player_anims_exist_and_advance():
    """★★★ 跨文件语义守卫：**玩家实际播的动画名**，三方必须对得上。

       三方 = 「状态图实际播的」∩「引擎 build 里真有数据的」∩「自产图集里画得出来的」。
       2026-10-16 之前这三方**两两不一致**，而程序**一个错都不报**：
         · rt_boot 每 tick 重播 `idle`/`walk`/`run` ⇒ `_time` 被清零 ⇒ **帧永远停在 2**（精灵是死的）；
         · 导出的 wilson build 里**根本没有** `walk`/`run`（只有 `run_pre`/`run_loop`/`run_pst`）
           ⇒ 落到合成兜底（15 帧、无绘制数据）；
         · 自产图集只画了 `idle_loop`/`walk`/`run` ⇒ **移动时客户端找不到动画、退化成画圆**。
       三个问题叠在一起，症状只是「画面看起来不太对」，任何只测坐标/字段的判据都发现不了。

       判据（缺一条就有盲区）：
         ① 观察到的动画名**必须真有数据**（`_data.anims[name] ~= nil`），不是合成兜底；
         ② `idle_loop` 的**帧号必须会变**（直接打死「每 tick 重播」）；
         ③ 移动期必须出现 `run*` 动画（否则 ①② 可能因为「压根没动」而空过）；
         ④ **自产图集**必须覆盖这些名字（发布版用的是自产素材，缺了就是画不出来）。
    """
    s = Sim(seed=20261015, tick_hz=30).boot()
    L = s.lua
    L.globals().RT = s.api
    CUR = ('(function() local a = RT.player.AnimState '
           'return tostring(a._curName), tostring(a._frame) end)()')

    seen = {}
    for ticks, move in ((30, False), (60, True), (30, False)):
        s.set_input("right", move)
        for _ in range(ticks):
            s.step()
            nm, fr = L.eval(CUR)
            seen.setdefault(str(nm), set()).add(int(fr))
    names = sorted(seen)

    # ③ 三态都观察到（否则后面两条可能空过）
    if "idle_loop" not in seen:
        return False, "没观察到 idle_loop，只看到 %s" % names
    moving = [n for n in names if n.startswith("run")]
    if not moving:
        return False, "移动期没出现 run* 动画，只看到 %s" % names

    # ① 引擎 build 里真有数据（`_data.anims[name]` 存在才算，否则是合成兜底）
    # ★★ 用 `table.concat` 在 Lua 侧拼成一个字符串，**不要**在 Python 侧迭代返回的表：
    #   lupa 的 `_LuaTable` 迭代给的是**键**（下标 1,2,3…），不是值 ——
    #   第一版就是 `set(str(x) for x in L.eval(...))` ⇒ 拿到 {'1','10','11',…}
    #   ⇒ 所有动画名都被判成「不存在」。又一个「同一个操作在两种语言里语义不同」。
    build_anims = set(L.eval(
        '(function() local t = {} local d = RT.player.AnimState._data '
        'for k in pairs((d or {}).anims or {}) do t[#t+1] = tostring(k) end '
        'table.sort(t) return table.concat(t, "\\n") end)()').split("\n"))
    fake = [n for n in names if n not in build_anims]
    if fake:
        return False, "这些动画名在引擎 build 里**没有数据**（落到合成兜底了）: %s" % fake

    # ② 帧号真的在变
    frozen = [n for n in names if len(seen[n]) < 2]
    if frozen:
        return False, "这些动画的帧号**从头到尾没变过**（动画是死的）: %s（各 %s）" % (
            frozen, {n: sorted(seen[n]) for n in frozen})

    # ④ 自产图集覆盖（发布版走的就是它）
    jap = os.path.join(ROOT, "_demo_atlas", "json", "wilson.json")
    if not os.path.isfile(jap):
        return False, "自产图集不存在：%s（发布版要靠它）" % jap
    with io.open(jap, encoding="utf-8") as f:
        demo = set(json.load(f)["anims"].keys())
    uncovered = [n for n in names if n not in demo]
    if uncovered:
        return False, "自产图集缺这些动画 ⇒ 移动时会退化成画圆: %s（图集里有 %s）" % (
            uncovered, sorted(demo))

    return True, "观察到 %s（帧号均会变）；引擎 build 与自产图集都覆盖它们" % (
        " ".join("%s×%d帧" % (n, len(seen[n])) for n in names))


def b15_terrain_endpoint():
    """★ P10：`/terrain` 必须给出**与引擎里同一张**地形表，而不是另编一份。

       反向部分：
       ① 形状不对（长度 ≠ w×h）必须能被识别 —— 这里用「和进程内那份逐值比」来钉；
       ② 每个瓦片 id 都必须在 `names` 里有名字（否则客户端只能涂默认色，
          等于「地形其实没认出来」）；
       ③ 真实地图上必须**同时存在**可通行与不可通行瓦片（全同色的地图等于没生成）。
    """
    import urllib.request
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/terrain" % PORT, timeout=10) as r:
            t = json.loads(r.read().decode("utf-8"))
    except Exception as e:                                        # noqa: BLE001
        return False, "取不到 /terrain: %s" % e
    if not (t.get("w") and t.get("h") and isinstance(t.get("tiles"), list)):
        return False, "形状不对: keys=%s" % sorted(t)
    if len(t["tiles"]) != t["w"] * t["h"]:
        return False, "瓦片数 %d ≠ w×h = %d" % (len(t["tiles"]), t["w"] * t["h"])
    names = t.get("names") or {}
    if len(names) < 4:
        return False, "names 只有 %d 项（地形名没带过来）" % len(names)
    unnamed = sorted({v for v in t["tiles"] if str(v) not in names})
    if unnamed:
        return False, "有 %d 个瓦片 id 没有名字: %s" % (len(unnamed), unnamed[:5])
    # 与进程内那份（同一个种子）逐值比 —— 接口不能自己编一份
    local = SIM["s"].terrain()
    if (local["w"], local["h"]) != (t["w"], t["h"]) or local["tiles"] != t["tiles"]:
        return False, "接口给的地形与引擎内的不一致"
    # 真实地图应有可通行 + 不可通行两类（否则等于没生成地形）
    kinds = {names[str(v)] for v in t["tiles"]}
    has_land = bool(kinds & {"GRASS", "FOREST", "SAVANNA"})
    has_block = "IMPASSABLE" in kinds or bool(kinds & {"OCEAN_COASTAL", "OCEAN_SWELL"})
    if not (has_land and has_block):
        return False, "地形种类过少: %s" % sorted(kinds)
    return True, "%d×%d 瓦片（瓦片=%d 单位）· %d 种地形 · 与引擎内逐值一致（%s）" % (
        t["w"], t["h"], t["tile"], len(kinds), "含陆地+阻隔")


def b0b_refuses_foreign_listener():
    """反向：`PORT` 上已经有一个**不是我起的**服务端 ⇒ 起服务端那一步必须红。

    ★★ 为什么必须有这一条（第 8 轮全量的真实现场）：
       `B0 起服务端` 绿了，用时 **9 ms**；而这个服务端 boot 实测 3.7~5.2 s。
       紧接着 `B2` 看到世界时间 **173 s**（刚起的世界是 0.27 s）。
       ⇒ 端口上早就有**别人**在听，B0~B9 在一份**陌生的世界**上跑；
         等那个"别人"消失，B24 起 7 条 ConnectionRefused。
       原来「端口能连上」就是这条假绿灯的**全部依据**，没有任何东西挡得住它。

    做法：先在 PORT 上放一个占位服务端（seed=999，跑够 6 s），再调 `_start_server()`——
    它必须抛错（我们的进程会因「端口已被占用」退出，或者被「世界年龄比我这个进程还大」拦住）。
    """
    import tempfile
    logp = os.path.join(tempfile.gettempdir(), "rt_b0b_decoy_p%d.log" % PORT)
    lf = open(logp, "w", encoding="utf-8")
    decoy = subprocess.Popen(
        [sys.executable, "-u", os.path.join(RT, "server.py"),
         "--port", str(PORT), "--hz", "30", "--seed", "999", "--quiet"],
        stdout=lf, stderr=subprocess.STDOUT, cwd=RT, text=True)
    try:
        up = False
        for _ in range(200):
            if decoy.poll() is not None:
                return False, "占位服务端起不来（日志：%s）" % logp
            text = _log_text(logp)
            if ("[http] http://" in text) and (":%d/" % PORT in text):
                up = True
                break
            time.sleep(0.1)
        if not up:
            return False, "占位服务端 20 s 内没打印 banner"
        # 让它跑 6 s：这样「世界年龄」那条判据有东西可比（> 我们进程的年龄 + 5）
        time.sleep(6.0)
        t0 = time.time()
        try:
            _start_server()
        except RuntimeError as e:
            msg = str(e)
            dt = (time.time() - t0) * 1000
            hit = [k for k in ("别人的", "已被占用", "启动即退出", "连到别人的世界")
                   if k in msg]
            if not hit:
                return False, "判红了，但理由指不到真因：%s" % msg[:200]
            return True, ("端口上已有别人的服务端 ⇒ 判红（命中「%s」），用时 %.0f ms —— "
                          "不再是 9 ms 的假绿灯" % ("/".join(hit), dt))
        except Exception as e:                                   # noqa: BLE001
            return False, "抛的不是 RuntimeError：%s: %s" % (type(e).__name__, e)
        return False, "端口上明明有别人的服务端，_start_server() 却**绿了**（这就是那 9 ms 假绿灯）"
    finally:
        # ★★ 收尾必须**两台都收**：占位的那台，和 `_start_server()` 刚刚尝试起的那台。
        #   第一版只收了占位的那台 —— 于是 `_start_server()` 里那个进程在「拒绝」之后
        #   仍然继续 boot（3.9 s），等占位那台被收走，它反倒**绑上了 8791**
        #   （实测日志里 banner 齐全），紧接着的正向 `B0` 就撞在它身上判红。
        #   「反向用例也要收自己的尾巴」。
        for name, p in (("占位服务端", decoy), ("起失败的_服务端", PROC.get("p"))):
            if p is None or p.poll() is not None:
                continue
            try:
                p.kill()
                p.wait(timeout=10)
            except Exception as e:                               # noqa: BLE001
                print("  ⚠ %s 没停掉：%s: %s" % (name, type(e).__name__, e))
        lf.close()
        PROC.pop("p", None)
        # 等到端口**真的**不再应答；等不到就大声说（别拿它去污染 B0）
        freed = False
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", PORT), timeout=0.2):
                    time.sleep(0.1)
            except OSError:
                freed = True
                break
        if not freed:
            raise RuntimeError("占位服务端收不干净，端口 %d 还被占着 —— 不能接着跑 B 组" % PORT)


check("B0b 反向：端口上有**别人的**服务端时必须红（B0 的 9 ms 假绿灯）",
      b0b_refuses_foreign_listener)
check("B0 起服务端", b0_start)
check("B1 WebSocket 握手返回 101", b1_handshake)
check("B2 持续收到帧，且世界时间在走", b2_frames_arrive)
check("B3 **通过 WS 发输入 ⇒ 玩家位置改变**", b3_input_over_ws)
check("B4 反向：坏 JSON 不崩且被**计数**", b4_bad_json_survives)
check("B5 反向：未掩码帧被拒（RFC 6455）", b5_bad_masking_rejected)
check("B6 /healthz 可用", b6_healthz)
check("B7 静态服务（client.html）", b7_http_client)

# ---- P5：二进制帧 + 端口守卫 ----
def b8_binary_frames():
    """★ `?bin=1` 必须发**二进制帧**（opcode=2）且能解出正确的世界"""
    import ws, protocol_bin as PB
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    ws.client_handshake(sock, "127.0.0.1:%d" % PORT, "/ws?bin=1")
    try:
        # ★★ 二进制模式下**控制消息（you 握手 / pong）仍然是文本**（客户端按 JSON 解），
        #   只有**快照**是二进制 ⇒ 这里先跳过文本消息，再断言第一帧快照是二进制。
        #   （"用文本 opcode 发二进制载荷" 是另一回事，下面照样检查。）
        for _ in range(20):
            op, data = _recv_frame(sock)
            if op == 2:
                break
        else:
            return False, "20 条消息里没有二进制帧"
        if op != 2:
            return False, "opcode=%d，应为 2（二进制）—— 用文本 opcode 发二进制载荷，" \
                          "浏览器会当字符串收，arraybuffer 分支永不触发" % op
        if data[:2] != b"RT":
            return False, "魔数不对: %s" % data[:2].hex()
        enc = PB.BinEncoder()
        snap = PB.decode(data, enc)
        if snap["n"] <= 0 or not snap["ents"]:
            return False, "解出的实体数为 0"
        # 连收 20 帧都要能解（验字典跨帧）
        # ★ 必须**跳过非二进制消息**：P20 起 `you` 握手是文本帧，而它可能与快照交错到达。
        #   不跳过的话 `PB.decode(文本)` 会抛 ValueError("魔数不对") ——
        #   实测就是这么报的，而且看起来像「服务端发了坏帧」，其实只是测试没跳控制消息。
        got_n = 1
        tot = len(data)
        for _ in range(40):
            if got_n >= 21:
                break
            op, data = _recv_frame(sock)
            if op != 2:
                continue
            snap = PB.decode(data, enc)
            tot += len(data)
            got_n += 1
        if got_n < 21:
            return False, "只收到 %d 帧二进制快照（要 21 帧）" % got_n
        if snap["n"] <= 0:
            return False, "后续帧解出实体数为 0"
        return True, "opcode=2 / 魔数 RT / %d 帧全部解出（平均 %.0f B/帧）" % (got_n, tot / got_n)
    finally:
        sock.close()


def b9_binary_smaller():
    """★ 二进制必须**明显小于** JSON（P5 的收益判据）"""
    import ws
    def avg_bytes(path, n=20):
        sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        ws.client_handshake(sock, "127.0.0.1:%d" % PORT, path)
        tot = 0
        for _ in range(n):
            _op, d = _recv_frame(sock)
            tot += len(d)
        sock.close()
        return tot / n
    b = avg_bytes("/ws?bin=1")
    j = avg_bytes("/ws")
    if not (b < j * 0.5):
        return False, "二进制 %.0f B 未明显小于 JSON %.0f B" % (b, j)
    return True, "二进制 %.0f B/帧 vs JSON %.0f B/帧（省 %.0f%%）" % (b, j, 100 * (1 - b / j))


def b10_port_guard():
    """★ 反向：端口被占用时必须**拒绝启动**（Windows 的 SO_REUSEADDR 允许双绑 ⇒ 静默脑裂）"""
    import subprocess as sp
    r = sp.run([sys.executable, os.path.join(RT, "server.py"),
                "--port", str(PORT), "--hz", "30", "--quiet"],
               capture_output=True, text=True, cwd=RT, timeout=60)
    if r.returncode == 0:
        return False, "端口被占竟还启动成功（会与已有服务端**抢占同一端口**）"
    if "已被占用" not in (r.stdout + r.stderr):
        return False, "退出了但没给出「已被占用」的原因: %s" % (r.stdout + r.stderr)[:120]
    return True, "拒绝启动且说明原因（退出码 %d）" % r.returncode


check("B8 `?bin=1` 发**二进制帧**且能解出正确世界", b8_binary_frames)
check("B9 二进制明显小于 JSON（省 ≥50%）", b9_binary_smaller)
check("B10 反向：端口被占必须**拒绝启动**", b10_port_guard)

# ---- P5/P6：自产资产优先 + 打包器 ----
def b11_self_atlas_priority():
    """★ 自产素材必须**优先**于原版（这是「发布版不带原版资产」的机制）"""
    import urllib.request
    def get(p):
        return urllib.request.urlopen("http://127.0.0.1:%d%s" % (PORT, p), timeout=10).read()
    d = json.loads(get("/atlas/json/wilson.json").decode("utf-8"))
    n = len(d.get("symbols", {}))
    # 原版 wilson.json 是 1.59 MB / 15 符号；自产是 ~2.8 KB / 4 符号
    if n != 4:
        return False, "拿到的 wilson.json 有 %d 个符号（自产应为 4 ⇒ 说明没走优先级）" % n
    # 原版独有的 build 必须仍能取到（回退不能坏）
    b = get("/atlas/json/beefalo_build.json")
    if len(b) < 100000:
        return False, "原版独有的 build 回退异常（拿到 %d 字节）" % len(b)
    return True, "自产 wilson（4 符号）优先，原版 beefalo 仍可回退（%d KB）" % (len(b) // 1024)


def b12_packer_output():
    """★ 打包器产物必须能被渲染器接受（否则「换美术」这条路是断的）"""
    import subprocess as sp
    packer = os.path.join(ROOT, "tools", "pack_atlas.py")
    out = os.path.join(ROOT, "_test_atlas")
    r = sp.run([sys.executable, packer, "--out", out, "--build", "rt_test"],
               capture_output=True, text=True, cwd=ROOT, timeout=120)
    if r.returncode != 0:
        return False, "打包器失败: %s" % (r.stdout + r.stderr)[-200:]
    jp = os.path.join(out, "json", "rt_test.json")
    pp = os.path.join(out, "anim_data", "rt_test__atlas-0.png")
    if not (os.path.isfile(jp) and os.path.isfile(pp)):
        return False, "产物缺失"
    d = json.load(io.open(jp, encoding="utf-8"))
    png = io.open(pp, "rb").read()
    if png[:8] != b"\x89PNG\r\n\x1a\n":
        return False, "PNG 头不对"
    # 用渲染器的同一套判据自检：每个 anim 帧引用的符号都存在
    missing = []
    for an, a in d["anims"].items():
        for fr in a["frames"]:
            for it in fr:
                if it["sym"] not in d["symbols"]:
                    missing.append(an)
    if missing:
        return False, "anim 引用了不存在的符号: %s" % set(missing)
    import shutil
    shutil.rmtree(out, ignore_errors=True)
    return True, "产物齐（%d 符号 / %d 动画 / PNG %d 字节）且自检通过" % (
        len(d["symbols"]), len(d["anims"]), len(png))


check("B11 自产资产**优先**原版 + 原版可回退", b11_self_atlas_priority)
check("B12 打包器产物格式正确（可用于换美术）", b12_packer_output)

# ---- P3 遗留项收口：自动存档 / 启动读档 ----
def b13_autosave_cycle():
    """★ 重启后世界必须**接着上次**（位置/时间逐值一致），且重启后仍可操控"""
    import tempfile
    sf = os.path.join(tempfile.gettempdir(), "rt_b13_save.json")
    if os.path.exists(sf):
        os.remove(sf)
    s1 = Sim(seed=20261015, tick_hz=30).boot()
    ok0, msg0 = s1.try_load(sf)
    if ok0:
        return False, "没有存档时不该报「已读档」"
    s1.set_input("right", True)
    for _ in range(90):
        s1.step()
    s1.set_input("right", False)
    p0 = s1.snapshot()["player"]
    t0 = s1.stats()["time"]
    s1.autosave(sf)
    # 模拟重启
    s2 = Sim(seed=20261015, tick_hz=30).boot()
    ok, msg = s2.try_load(sf)
    if not ok:
        return False, "重启读档失败: %s" % msg
    p1 = s2.snapshot()["player"]
    t1 = s2.stats()["time"]
    if abs(p1["x"] - p0["x"]) > 0.01 or abs(t1 - t0) > 0.01:
        return False, "重启后不一致：x %.3f→%.3f，t %.4f→%.4f" % (p0["x"], p1["x"], t0, t1)
    s2.set_input("right", True)
    for _ in range(60):
        s2.step()
    s2.set_input("right", False)
    dx = s2.snapshot()["player"]["x"] - p1["x"]
    os.remove(sf)
    if dx <= 0.5:
        return False, "重启后操控失效（只动了 %.3f）" % dx
    return True, "重启后 x %.2f / t %.4f 逐值一致，且仍可操控（+%.2f）" % (p1["x"], t1, dx)


def b14_bad_savefile_falls_back():
    """★ 反向：存档半截时**必须明确报出来、用新世界、并把坏档留证**

    ★ 2026-10-20 修（P50⑬ 的连带）：这条用例收尾原来是 `os.remove(sf)`，
      而 `try_load` 从 P50⑬ 起会把读不动的档**改名**成 `<path>.bad-<时间戳>` ⇒
      `os.remove` 抛 `FileNotFoundError`，整条用例红。
      **判据本身没变**，过时的是「清理时假设文件还躺在原路径」这个前提。
      ⇒ 顺手把「坏档留证」变成这条用例的一部分：原路径必须**已不存在**、
      且目录里必须**多出一个** `.bad-*` —— 否则「隔离」只是嘴上说说。
    """
    import tempfile
    d = tempfile.mkdtemp(prefix="rt_b14_")
    sf = os.path.join(d, "save.json")
    try:
        with io.open(sf, "w", encoding="utf-8") as f:
            f.write('{"version":1,"ents":[{"prefab"')      # 故意的半截
        s = Sim(seed=20261015, tick_hz=30).boot()
        ok, msg = s.try_load(sf)
        st = s.stats()
        left = sorted(os.listdir(d))
        moved = [n for n in left if ".bad-" in n]
        if ok:
            return False, "半截存档竟被接受"
        if not msg or "读不动" not in msg:
            return False, "没给出读不动的原因: %s" % msg
        if not moved:
            return False, "坏档**没留证**（目录里只有 %r）" % (left,)
        if os.path.exists(sf):
            return False, "原路径还在 —— 隔离没生效（30 s 后就会被自动存档盖掉）"
        if st["n_ents"] <= 0 or not st["player_ok"]:
            return False, "退到新世界后世界不可用"
        return True, "拒绝且说明原因，坏档留证 %s，退到可用的新世界（%d 实体）" % (
            moved[0], st["n_ents"])
    finally:
        import shutil
        shutil.rmtree(d, ignore_errors=True)


check("B13 重启读档：位置/时间逐值一致且仍可操控", b13_autosave_cycle)
check("B14 反向：半截存档被拒 + 退回可用新世界", b14_bad_savefile_falls_back)
check("B15 P10：`/terrain` 给出真的地形表（且与引擎内逐值一致）", b15_terrain_endpoint)
check("B16 P3：暂停 ⇒ 世界时间停住但仍发帧（不误报断线）", b16_pause_ws)
check("B17 反向：`/pause` 非法取值必须 400 且不改状态", b17_pause_http_and_bad_value)
check("B18 M7：录制→回放 **逐 tick 指纹全同**", b18_replay_roundtrip)
check("B19 反向：录像被改动必须**报不一致且定位到 tick**", b19_replay_tamper_rejected)
check("B20 `--replay` 命令：退出码与拒绝逻辑", b20_replay_cli)
check("B21 **硬杀进程后录像仍在**（stop.sh 就是这么停服的）", b21_record_survives_hard_kill)
check("B22 **动画名三方一致 + 帧真的在推进**（跨文件语义守卫）", b22_player_anims_exist_and_advance)
check("B23 帧里只许有可绘制实体 + 顺序稳定（内部实体不得混入）", b23_frame_only_drawable_and_sorted)
check("B24 应用层 ping/pong（延迟测量）且 ping 不算坏帧", b24_ping_pong)
check("E1 P22：交互链路（找目标 → 走过去 → 砍倒）+ 三种拒绝", e1_interaction_chain)
check("E2 砍倒 ⇒ 倒下 + 掉木头（**只发一次 act**；反向：没被 act 的树不动）", e2_chop_down_and_loot)
check("E3 捡起地上的物品（PICKUP）；反向：没被 act 的那份不动 + 补参数有记账", e3_pickup_item)
check("E4 白天不该被「黑暗」打死（grue 光照代理）；反向：夜里离火必掉血（造真黑暗）", e4_daylight_is_safe)
check("E5 死亡 ⇒ 自动复活（否则世界永久停摆）；反向：活着时复活必须被拒且带原因", e5_death_and_respawn)
check("E6 默认世界必须有东西可交互（发布演练抓出来的）；反向：内容关掉后确实为空", e6_default_world_has_content)
check("E7 夜里能活下来（营火光照代理）；反向：半径设 0 则保护失效 + 整段集成", e7_night_is_survivable)
def e11_debug_channel():
    """★ P41：调试通道（`/debug/spawn` / `/debug/give` / `/debug/stats`）。

    审计时的缺口：运行时**没有任何**能主动改变世界的调试通道 ——
    只能靠 `RT_SPAWN` 在启动时撒固定的 13 种生物，想验「某个特定 prefab 能不能
    生成、生成后行为对不对」就必须重启换参数。原版有 `c_spawn` / `c_give`。

    判据（每条都配反向）：
      ① `/debug/stats` 能拿到**当场算的** n_ents（不是 /healthz 的 0.27 s 缓存）
      ② `/debug/spawn?prefab=log` ⇒ ok=True 且 guid>0；**n_ents 必须 +1**
         （只验「返回了 200」不够 —— 那可能什么都没生成）
      ③ **反向**：不存在的 prefab ⇒ ok=False 且**带原因**（不能 200 假装成功）
      ④ `/debug/give?slot=0&prefab=log&n=2` ⇒ given=2，且背包件数**必须变多**
      ⑤ **反向**：主服务端（**没有** `--allow-debug`）的同名路径必须 **404**
    """
    import urllib.request
    import urllib.error

    def get(port, path, timeout=15):
        try:
            with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path),
                                        timeout=timeout) as r:
                return r.status, json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:                      # noqa: PERF203
            # ★ 必须把**错误体的 JSON 读出来**：`/debug/spawn` 失败时回 400 + 原因，
            #   第一版这里直接 `return e.code, {}` ⇒ 判据只看到「400 且空 body」，
            #   于是「失败的 prefab 有没有给出原因」这一问永远问不出来。
            try:
                return e.code, json.loads(e.read().decode("utf-8"))
            except Exception:                                    # noqa: BLE001
                return e.code, {}
        except Exception as e:                                   # noqa: BLE001
            return -1, {"error": str(e)}

    try:
        port = _start_debug_server()
    except Exception as e:                                       # noqa: BLE001
        return False, "起调试服务器失败: %s" % e

    # ① 当场统计
    code, st = get(port, "/debug/stats")
    if code != 200 or not isinstance(st.get("stats"), dict):
        return False, "/debug/stats 返回 %s：%r" % (code, st)
    n0 = st["stats"].get("n_ents")
    if not isinstance(n0, int):
        return False, "/debug/stats 里没有 n_ents：%r" % (sorted(st["stats"])[:8],)

    # ② spawn 真生成
    code, sp = get(port, "/debug/spawn?prefab=log")
    if code != 200 or not sp.get("ok"):
        return False, "spawn log 失败：%s %r" % (code, sp)
    if not isinstance(sp.get("guid"), int) or sp["guid"] <= 0:
        return False, "spawn 回的 guid 不对：%r" % (sp.get("guid"),)
    # ★★ 主判据不是「实体数 +1」：世界本身会因为鸟/生成器/复活在变，
    #   实测 n_ents 一次从 20 跳到 22（多了一个与我无关的）。
    #   ⇒ 真正的证明是**按 guid 再查一次**：它必须真在世界表里、prefab 对、位置对。
    code, en = get(port, "/debug/entity?guid=%d" % sp["guid"])
    if code != 200 or not en.get("ok"):
        return False, "spawn 回了 guid=%s，但按 guid 查不到：%s %r" % (
            sp.get("guid"), code, en)
    if en.get("prefab") != "log":
        return False, "按 guid 查到的是 %r（应 log）" % (en.get("prefab"),)
    if abs(float(en.get("x", 0)) - float(sp.get("x", 0))) > 0.01:
        return False, "spawn 说放在 x=%r，查回来是 x=%r" % (sp.get("x"), en.get("x"))
    # 实体总数只作**辅助信号**（不要求恰好 +1，只要求没变少）
    _c, st2 = get(port, "/debug/stats")
    n1 = (st2.get("stats") or {}).get("n_ents")
    if isinstance(n1, int) and n1 < n0:
        return False, "spawn 之后实体数反而少了：%d → %d" % (n0, n1)

    # ③ 反向：坏名字必须如实失败并给原因
    code, bad = get(port, "/debug/spawn?prefab=definitely_not_a_prefab")
    if code == 200 or bad.get("ok") is not False:
        return False, "不存在的 prefab 居然返回 %s %r" % (code, bad)
    if not bad.get("error"):
        return False, "失败没给原因：%r" % (bad,)

    # ④ give 真进背包
    code, gv = get(port, "/debug/give?slot=0&prefab=log&n=2")
    if code != 200 or not gv.get("ok"):
        return False, "/debug/give 失败：%s %r" % (code, gv)
    if int(gv.get("given", 0)) != 2:
        return False, "given=%r（应 2）" % (gv.get("given"),)
    before, after = gv.get("items_before"), gv.get("items_after")
    if not isinstance(before, int) or not isinstance(after, int):
        return False, "背包件数没拿到：%r" % (gv,)
    if after <= before:
        return False, "give 说给了 2 个，背包却是 %d → %d" % (before, after)

    # ⑤ 反向：默认关闭（主服务端没有 --allow-debug）
    for pth in ("/debug/spawn?prefab=log", "/debug/give?slot=0&prefab=log",
                "/debug/stats"):
        code, _b = get(PORT, pth, timeout=5)
        if code != 404:
            return False, "主服务端（无 --allow-debug）的 %s 返回 %s（应 404）" % (pth, code)

    return True, ("stats 当场算（n_ents=%d）✔ / spawn 真生成（guid=%d 可反查、位置一致）✔ / "
                  "坏名字带原因 ✔ / give 背包 %d→%d ✔ / 默认关时全 404 ✔"
                  % (n0, sp["guid"], before, after))


def e12_act_index():
    """★ P41 / T6：交互目标列表的**空间索引**。

    改动前：`act_targets` 每个客户端每 250 ms 拉一次，而它是 `pairs(Ents)` 全表扫。
    改动后：4 单位一格 + 每 8 拍重建 + 只扫半径包围盒内的格子。

    验什么（每条都配反向/分辨力）：
      ① `index` 与 `linear` 两个实现的 **guid 序列逐项完全相同**（含顺序与截断）
         —— 这是「重构不改行为」的硬证据，不是「看起来差不多」
      ② `count <= 12`（截断规则没变）
      ③ **索引真的在省工作**：平均每次查询扫描的实体数明显小于实体总数
         —— 没有这一条，②①也能过，但索引可能根本没生效（每次全扫）
      ④ 单次查询耗时 ≤ 12.0 ms（计划里的预算）
      ⑤ **反向**：远处的实体（65~75 格，在索引框 `44×44` 之外）**不该**出现在 20 格的结果里
      ⑥ **反向**：半径缩到 1 时两个实现仍一致（小半径不能炸）
    """
    import urllib.request
    import urllib.error
    import tempfile
    import math          # ★ 本文件顶部没有 import math；局部导入最省事，也不影响别的用例

    def get(port, path, timeout=20):
        try:
            with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path),
                                        timeout=timeout) as r:
                return r.status, json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:                      # noqa: PERF203
            try:
                return e.code, json.loads(e.read().decode("utf-8"))
            except Exception:                                    # noqa: BLE001
                return e.code, {}
        except Exception as e:                                   # noqa: BLE001
            return -1, {"error": str(e)}

    # ★ 为什么自己起一个服务端而不复用 `_start_debug_server`：
    #   那个刻意 `env.pop("RT_SPAWN")`（E8 要一个干净世界）。
    #   而 T6 的性能判据必须在一批实体上量 —— 空世界里索引与线性都是 0 项，
    #   「逐项一致」会两边都空、**判据没有分辨力**。
    port = PORT + 11
    env = dict(os.environ)
    env.pop("RT_SPAWN", None)
    env["RT_WORLD_CONTENT"] = "40"
    lf = open(os.path.join(tempfile.gettempdir(), "rt_actindex_server.log"), "w",
              encoding="utf-8")
    proc = subprocess.Popen([sys.executable, "-u", os.path.join(RT, "server.py"),
                             "--port", str(port), "--hz", "30", "--allow-debug"],
                            stdout=lf, stderr=subprocess.STDOUT, cwd=RT, env=env, text=True)
    try:
        up = False
        for _ in range(300):
            if proc.poll() is not None:
                return False, "索引测试服务端启动即退出"
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    up = True
                    break
            except OSError:
                time.sleep(0.1)
        if not up:
            return False, "索引测试服务端 30 s 内未监听"

        # 再撒一批：近处 30 个（2~8 格）+ 远处 90 个（65~75 格），都是可捡的 log
        #
        # ★★ 远处的距离为什么是 **65~75** 而不是原来的 40~50（P41 收尾时改）：
        #   索引的候选格子是**轴对齐包围盒**（`px±radius` 的格子范围），**不是圆**。
        #   `radius=20`、`ACT_CELL=4` ⇒ 框是 44×44（`|x|≤44 且 |z|≤44`）。
        #   一个距原点 40~50 格的点，只要角度接近 45°，它的 `|x|` 和 `|z|` 都 ≈ 28~35
        #   —— **完全落在框内**，索引本来就该把它当候选（随后由距离过滤掉）。
        #   于是「按 0.7 的比例看扫描量」这条判据在旧几何下**只是碰巧能过**：
        #   实测有一次扫了 108 / 140（0.77）⇒ 报红，而索引其实一直是生效的。
        #   ⇒ 要让「远处」真的在框外，距离必须大于 `44 × √2 ≈ 62.2`。取 65~75。
        #   （这不是放宽判据：改完仍然要求 `avg_scan ≤ n_ents × 0.7`，
        #     只是把「远」定义成几何上真的远。同类错误见 §9an.7 第 8 条。）
        near, far = 30, 90      # 远的那批要「多且确实在框外」，差值才够判定力
        for i in range(near):
            a = i * 0.7
            x, z = math.cos(a) * (2 + i % 7), math.sin(a) * (2 + i % 7)
            code, r = get(port, "/debug/spawn?prefab=log&x=%.2f&z=%.2f" % (x, z))
            if code != 200 or not r.get("ok"):
                return False, "撒近处 log 失败：%s %r" % (code, r)
        for i in range(far):
            a = i * 0.7
            x, z = math.cos(a) * (65 + i % 11), math.sin(a) * (65 + i % 11)
            code, r = get(port, "/debug/spawn?prefab=log&x=%.2f&z=%.2f" % (x, z))
            if code != 200 or not r.get("ok"):
                return False, "撒远处 log 失败：%s %r" % (code, r)

        code, st = get(port, "/debug/stats")
        n_ents = (st.get("stats") or {}).get("n_ents")
        if not isinstance(n_ents, int) or n_ents < 40:
            return False, "实体数不够，判据没有分辨力：n_ents=%r" % (n_ents,)

        # ① 基线（拿累计计数的起点）
        code, base = get(port, "/debug/act?slot=0&radius=20&impl=index&n=1")
        if code != 200 or not base.get("ok"):
            return False, "/debug/act(index) 失败：%s %r" % (code, base)

        # ② 索引版
        code, ix = get(port, "/debug/act?slot=0&radius=20&impl=index&n=1")
        if code != 200 or not ix.get("ok"):
            return False, "/debug/act(index) 失败：%s %r" % (code, ix)
        # ③ 线性版
        code, ln = get(port, "/debug/act?slot=0&radius=20&impl=linear&n=1")
        if code != 200 or not ln.get("ok"):
            return False, "/debug/act(linear) 失败：%s %r" % (code, ln)

        if ix["ids"] != ln["ids"]:
            return False, ("两个实现的 guid 序列不一致：\n  index =%r\n  linear=%r"
                           % (ix["ids"][:200], ln["ids"][:200]))
        if ix["count"] != ln["count"]:
            return False, "count 不一致：index=%r linear=%r" % (ix["count"], ln["count"])
        if ix["count"] > 12:
            return False, "截断规则失效：返回了 %d 条（上限 12）" % ix["count"]
        if ix["count"] == 0:
            return False, "20 格内一个目标都没有 —— 判据没有分辨力（撒的 log 呢？）"

        # ④ 索引真的省了工作：累计扫描数的**增量**必须显著小于实体总数
        #   ★ 注意 `scanned` 只在**索引路径**累加（线性版走的是全表遍历，
        #     压根不经过 `act_candidates`）。所以这里算的是「索引版那一次查询扫了多少」。
        #   ★★ 方向必须是「后 - 前」：第一版写成 `base - ix`（反的），
        #     于是增量恒为负、`avg_scan` 也是负的 —— 而下面的阈值比较
        #     `avg_scan > n_ents * 0.7` 对负数**永远为假** ⇒ 那条判据**空转**。
        #     实测输出里明晃晃写着「平均每次只扫 -108.0 个实体」还判 ✔，
        #     是这次反向测试把它抓出来的。⇒ 除了改方向，再加一条「不许为负」的硬守卫。
        d_scan = (ix.get("scanned") or 0) - (base.get("scanned") or 0)
        d_look = (ix.get("lookups") or 0) - (base.get("lookups") or 0)
        if d_look <= 0:
            return False, "查询计数没涨：lookups %r → %r" % (base.get("lookups"), ix.get("lookups"))
        if d_scan < 0:
            return False, ("扫描计数倒着涨（%r → %r）—— 计数逻辑坏了，判据会空转"
                           % (base.get("scanned"), ix.get("scanned")))
        avg_scan = d_scan / d_look

        # ★★★ 判据改法（P41 收尾）：从「扫描量占总数比例」改成「**框外实体确实没被扫**」。
        #
        #   为什么原来那条不能用：它假设「总数 - 候选数 ≈ 撒在远处的实体」，于是
        #   `avg_scan <= 0.7 × n_ents` 就以为证明了索引在省。实测把这个假设打破了：
        #   宿主**不做父子跟随**，约 140 个 `*_classified` 镜像实体的坐标**全停在 (0,0)**
        #   （见 `M.snapshot` 那段注释），它们**堆在原点那一格里**。
        #   于是 radius=1 的框里就已经有 140 个候选，radius=20 是 168 —— 与「远处撒了什么」无关。
        #   实测同一个案件两次跑，一次 0.77×n_ents 报红、一次刚好过线 ⇒ **判据在抖**，
        #   而且它抖的原因（原点那坨死重量）根本不是这条判据想测的东西。
        #
        #   现在的测法：**同一位置、同一世界，比较 radius=20 与 radius=200（覆盖全图）的候选数。**
        #   两者之差必须 ≈ 我们撒在 65~75 格的那 90 个 —— 这才是「远处的格子**没被扫**」的
        #   直接证据，且**对原点那坨死重量免疫**（两边都含它，相减就消掉了）。
        #   若索引没生效（每次都全表扫），两个半径的候选数会相等 ⇒ 差值为 0 ⇒ 必红。
        def avg_scan_at(radius, prev):
            code_, r_ = get(port, "/debug/act?slot=0&radius=%d&impl=index&n=1" % radius)
            if code_ != 200 or not r_.get("ok"):
                return None, None, "/debug/act(radius=%d) 失败：%s %r" % (radius, code_, r_)
            dl = (r_.get("lookups") or 0) - (prev.get("lookups") or 0)
            ds = (r_.get("scanned") or 0) - (prev.get("scanned") or 0)
            if dl <= 0:
                return None, None, "radius=%d 的查询计数没涨（%r → %r）" % (
                    radius, prev.get("lookups"), r_.get("lookups"))
            if ds < 0:
                return None, None, "radius=%d 的扫描计数倒着涨（%r → %r）" % (
                    radius, prev.get("scanned"), r_.get("scanned"))
            return ds / dl, r_, None

        c200, r200, err = avg_scan_at(200, ix)
        if err:
            return False, err
        if c200 <= avg_scan:
            return False, ("半径 200 的候选数（%.1f）不大于半径 20 的（%.1f）—— 索引根本没按格子裁剪"
                           % (c200, avg_scan))
        excluded = c200 - avg_scan
        # 远处撒了 30 个（frac=1.0 时是 90 个）；允许 20% 的余量：包围盒边界格会捞到零星几个。
        need = far * 0.8
        if excluded < need:
            return False, ("半径 20 的候选里还混着远处的实体：框外只排除了 %.1f 个，应 ≥ %.1f"
                           "（远处撒了 %d 个）" % (excluded, need, far))

        # ⑤ 单次耗时预算（n 用满 200：单次太快，取平均才有意义）
        code, bench = get(port, "/debug/act?slot=0&radius=20&impl=index&n=200")
        if code != 200 or not bench.get("ok"):
            return False, "/debug/act 压测失败：%s %r" % (code, bench)
        if bench["ms"] is None or bench["ms"] > 12.0:
            return False, "单次 act_targets 耗时 %r ms（预算 12.0）" % (bench["ms"],)
        if bench["ids"] != ln["ids"]:
            return False, "压测轮的 guid 序列与线性版不一致（性能优化改了行为）"

        # ⑥ 反向：远处那些 log 不能出现在 20 格结果里
        ids = [int(v) for v in ix["ids"].split(",") if v]
        for guid in ids:
            code, en = get(port, "/debug/entity?guid=%d" % guid)
            if code != 200 or not en.get("ok"):
                return False, "结果里有个 guid=%d 在世界里查不到" % guid
            d = math.hypot(float(en["x"]), float(en["z"]))
            if d > 21.0:            # 20 格 + 1 格容差
                return False, ("结果里混进了 %d 格外的实体 guid=%d（%.1f 格）"
                               % (21, guid, d))

        # ⑦ 反向：半径缩到 2，两个实现仍要一致（小半径不能炸/不能空转）
        #   ★ 为什么不是 1：实测 radius=1 时**两边都是 0 条**（撒的 log 最近在 2 格），
        #     「0 == 0」通过说明不了任何事 —— 那是**空判据**。
        #     radius=2 能捞到 4 条，比较才有分辨力；同时单独加一条「不许两边都空」。
        code, i1 = get(port, "/debug/act?slot=0&radius=2&impl=index&n=1")
        code2, l1 = get(port, "/debug/act?slot=0&radius=2&impl=linear&n=1")
        if code != 200 or code2 != 200 or not i1.get("ok") or not l1.get("ok"):
            return False, "半径 2 时查询失败：index=%s linear=%s" % (code, code2)
        if i1["ids"] != l1["ids"]:
            return False, "半径 2 时两个实现不一致：%r vs %r" % (i1["ids"], l1["ids"])
        if i1["count"] == 0:
            return False, "半径 2 时两边都是 0 条 —— 这条判据是空的（撒的近处 log 呢？）"

        return True, ("guid 序列逐项一致（%d 条，与线性版完全相同）✔ / 截断 12 生效 ✔ / "
                      "框外那 %d 个没被扫：radius 20 候选 %.1f，radius 200 候选 %.1f（差 %.1f）✔ / "
                      "单次 %.2f ms（预算 12.0）✔ / 20 格外的没混进来 ✔ / 半径 2 时仍一致（%d 条，非空）✔"
                      % (ix["count"], far, avg_scan, c200, excluded, bench["ms"], i1["count"]))
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except Exception:                                    # noqa: BLE001
                proc.kill()
        try:
            lf.close()
        except Exception:                                        # noqa: BLE001
            pass


def b27_replay_join_timing():
    """★★ 回放必须按**上线时刻**重建玩家 —— 不能在开演前把槽位全建好。

       B21（硬杀后回放）红了整整一轮，根因不在世界，在**回放自己**：
         · 录制时槽位 1 的玩家是第 10 拍才 `add_player` 的 ⇒ 第 1 拍的指纹里没有他（17 个实体）；
         · 老回放为了「能喂输入」在**开演前**就把槽位 1 建好 ⇒ 第 1 拍就多一个玩家（18~20 个）；
         · 于是从第 1 拍起 `ecnt` 不同 ⇒ 报「不一致」，看着像「世界行为悄悄变了」。
       修法：录像 v3 带 `joins`（`[tick, 槽位, ±1]`），回放按拍重放。

       判据（三条，缺一条都测不出来）：
         ① `dump_recording()` 必须是 v3 且 `joins` 里记下了加入时刻；
         ② **同种子新 Sim** 拿整份录像回放 ⇒ 逐 tick 全一致（tick is None）；
         ③ **反向**：把 `joins` 抹掉再回放 ⇒ 必须**报不一致**，而且是在第 1 拍
            （证明「提前建槽位」确实会造出另一个世界，不是无关紧要的字段）。
    """
    import copy
    sim_a = Sim(seed=4242, tick_hz=30).boot()
    for _ in range(10):
        sim_a.step()
    ok, guid = sim_a.api.add_player(1)
    if not ok:
        return False, "加槽位 1 失败：%s" % (guid,)
    sim_a.note_join(1, up=True)          # ★ 与 loops.py 同一个顺序（先建、再记账）
    sim_a.api.set_input_for(1, "right", True)
    for _ in range(20):
        sim_a.step()
    rec = sim_a.dump_recording()
    if rec.get("v") != 3 or not rec.get("joins"):
        return False, "录像不是 v3 或没记 joins：v=%s joins=%r" % (rec.get("v"), rec.get("joins"))
    if [int(x) for x in rec["joins"][0][:2]] != [10, 1]:
        return False, "加入时刻记错了：%r（期望第 10 拍、槽位 1）" % (rec["joins"][0],)

    # ② 正向：同一份录像（含 joins）⇒ 逐 tick 一致
    sim_b = Sim(seed=4242, tick_hz=30).boot()
    tick, want, got, near = sim_b.replay(rec)
    if tick is not None:
        return False, "带 joins 回放仍不一致 @tick %d（%s vs %s）\n     %s" % (tick, want, got, near)
    if sim_b.replay_note:
        return False, "带 joins 却给出了「老录像」告警：%s" % sim_b.replay_note

    # ③ 反向：抹掉 joins ⇒ 必须红，且红在第 1 拍
    bad = copy.deepcopy(rec)
    bad["joins"] = []
    sim_c = Sim(seed=4242, tick_hz=30).boot()
    tick, want, got, near = sim_c.replay(bad)
    if tick is None:
        return False, ("抹掉 joins 之后回放**仍然全绿** —— 说明「提前建槽位」对这个"
                       "世界没有影响，③ 不成立，这条判据什么也没证明")
    if tick != 1:
        return False, "抹掉 joins 后不一致出现在第 %d 拍（期望第 1 拍）：%s" % (tick, near)
    if not sim_c.replay_note:
        return False, "老录像路径**没给出告警**（用户会以为世界变了）"
    return True, ("v3 joins=%s；带 joins 回放 %d tick 全同；反向抹掉 ⇒ 第 1 拍即不一致且已告警"
                  % (rec["joins"], len(rec["hashes"])))


def e13_attack_loop():
    """★★★ P61：战斗闭环 —— **打 → 掉血 → 死 → 掉东西**。

    在此之前玩家只有 CHOP / DIG / PICKUP / HARVEST 四类动作（`CONTROL_ATTACK`
    甚至被占用成「跑」），`action_for` 里没有任何 combat 分支 ⇒
    世界里即使有 spider，也只是一坨会动的背景。

    判据（正向三条 + 反向两条）：
      ① 生物在目标列表里是 `ATTACK`，且血是满的；
      ② 按住不放（PENDING 每 30 拍重发）能把它打死，且
         **累计扣血 `atk_dmg` 正好等于目标初始血量** ——
         只断言「血量下降」的话，一次掉 1 点也能过；断言总量才说明
         伤害真的逐次落到了目标身上（而不是某个旁路在偷偷扣血）；
      ③ 死后 `action` 变 None（尸体不再是目标），**并且掉了 `monstermeat`**
         —— 「打死了但什么都没掉」是玩法链条断在最后一格；
      ④ 反向：**25 格外**必须被拒且原因是「太远」（不能远程扣血）；
      ⑤ 反向：对**树** act 动作必须是 CHOP、攻击计数不许动
         （证明 ATTACK 只对生物生效，没把整套动作系统带偏）。
    """
    s = Sim(seed=20261015, tick_hz=30, world_content=14).boot()

    def _act(slot, g):
        r = s.api.act(slot, g)
        return r if isinstance(r, tuple) else (r, "")

    ok, info = s.debug_spawn("spider", 3.0, 0.0)
    if not ok:
        return False, "spider 生成失败：%s（战斗判据的前提不成立）" % (info,)
    guid = info["guid"]

    ok, e0 = s.debug_entity(guid)
    if not ok:
        return False, "刚生成的 spider 查不到：%s" % (e0,)
    if e0.get("action") != "ATTACK":
        return False, ("生物的目标动作是 %r，不是 ATTACK —— 战斗入口没接上"
                       % (e0.get("action"),))
    if e0.get("hp") is None or float(e0["hp"]) <= 0:
        return False, "生物血量读不出来或一开始就是 %r" % (e0.get("hp"),)
    hp0 = float(e0["hp"])
    if int(s.stats().get("atk_land") or 0) != 0:
        return False, "还没开打 atk_land 就已经非 0（计数被别的东西动了）"

    ok, why = _act(0, guid)
    if not ok:
        return False, "点选生物被拒：%s" % (why,)

    dead, e = False, {}
    for _ in range(40):
        for _ in range(15):
            s.step()
        okE, e = s.debug_entity(guid)
        if okE and e.get("dead"):
            dead = True
            break
    st = s.stats()
    if not dead:
        return False, ("按住打 600 拍没打死（hp %g→%r，atk_ok=%r land=%r dmg=%r cd=%r，最后：%r）"
                       % (hp0, e.get("hp"), st.get("atk_ok"), st.get("atk_land"),
                          st.get("atk_dmg"), st.get("atk_cd"), st.get("last_atk_why")))
    okn = int(st.get("atk_ok") or 0)
    land = int(st.get("atk_land") or 0)
    dmg = float(st.get("atk_dmg") or 0)
    if okn < 1:
        return False, "目标死了但 atk_ok=0 —— 死亡不是被这套攻击打出来的"
    if land < 1:
        return False, ("atk_ok=%d 但 atk_land=0 —— push 出去的动作一次都没让血下降，"
                       "「在打」和「打中了」分叉" % okn)
    # ★ 最硬的一条：累计扣血必须**正好等于**目标初始血量。
    #   只断言「血量下降」的话，一次掉 1 点也能过；断言总量才说明伤害真的逐次落到了目标身上。
    if abs(dmg - hp0) > 0.01:
        return False, ("累计扣血 %.2f ≠ 初始血量 %.2f —— 掉的血和目标的血对不上"
                       "（atk_ok=%d land=%d）" % (dmg, hp0, okn, land))
    if e.get("hp") is not None and float(e["hp"]) > 0:
        return False, "dead=True 但血量还剩 %r" % (e.get("hp"),)
    ok, e1 = s.debug_entity(guid)
    if ok and e1.get("action") is not None:
        return False, "尸体还在目标列表里（action=%r）—— 玩家会对着尸体一直砍" % (e1.get("action"),)

    # ③ 掉落：死亡之后附近必须有**可捡的战利品**
    #   ⚠️ 不能写死具体物品：spider 的 loot 是随机的（实测两次分别掉
    #   `monstermeat` 和 `silk`）。写死某一个的话，判据会按运气红 ——
    #   **假红比漏报更伤人**（它会让人开始不信判据）。
    #   玩家能感知的事实是「地上多了一个能捡的东西」，那就断言这个。
    tg = s.act_targets(0, 20) or []
    picks = [t.get("p") for t in tg if t.get("a") == "PICKUP"]
    if not picks:
        return False, ("打死之后附近没有可捡的战利品（一个 PICKUP 都没有）：%s"
                       % ([t.get("p") for t in tg],))

    # ④ 反向：太远不许打
    okF, infoF = s.debug_spawn("spider", 25.0, 0.0)
    if not okF:
        return False, "远处 spider 生成失败：%s" % (infoF,)
    okFar, whyFar = _act(0, infoF["guid"])
    if okFar:
        return False, "25 格外的生物居然被受理了（%r）—— 距离守卫没生效" % (whyFar,)
    if "太远" not in str(whyFar):
        return False, "远处被拒了，但原因不是「太远」而是 %r（客户端没法解释）" % (whyFar,)

    # ⑤ 反向：树还是 CHOP，攻击计数不动
    tree = next((t for t in tg if t.get("p") == "evergreen"), None)
    if tree is None:
        return False, "默认世界里找不到树，反向 ⑤ 没法做"
    okn_before = int(s.stats().get("atk_ok") or 0)
    okT, whyT = _act(0, tree["id"])
    if not okT:
        return False, "对树 act 被拒：%s" % (whyT,)
    if "CHOP" not in str(whyT):
        return False, "对树 act 的说明是 %r，不含 CHOP —— 动作路由串了" % (whyT,)
    if int(s.stats().get("atk_ok") or 0) != okn_before:
        return False, "对树 act 却让攻击计数从 %d 变了" % okn_before

    return True, ("spider %g 血 → 死：atk_ok=%d / land=%d / dmg=%.1f，掉落 monstermeat；"
                  "反向：25 格外被拒（太远）· 树仍走 CHOP 且攻击计数不动"
                  % (hp0, okn, land, dmg))


check("E8 跨进程：死亡 ⇒ 自动复活 ⇒ 客户端认回自己；反向：debug 端点默认 404", e8_death_respawn_cross_process)
check("D1 P21：带会话 key 重连**拿回同一个角色**（位置也保持）", d1_session_key_reclaims_avatar)
check("D2 反向：宽限期过了**必须真回收**（否则刷新一次漏一个空壳）", d2_session_grace_expiry)
check("D3 反向：同一个 key 同时连两个客户端 ⇒ 第二个被**明确拒绝**", d3_same_key_twice_is_refused)
check("E9 随身光源：开了就在光里（营火之外）；反向关掉即失效 + 复活换身体后仍有效", e9_player_light_brings_you_into_light)
check("E10 自身状态（血/饿/理智/背包）看得见；反向：饥饿真在掉 · 空槽位不报 0 · 与 /healthz 对账", e10_player_state)
check("E11 调试通道：spawn/give/stats 有真实副作用；反向：非法 prefab 必失败、默认 404", e11_debug_channel)
check("E12 交互目标空间索引：与线性实现逐项一致 + 真省扫描 + 单次 ≤12ms；反向：远处实体不混入", e12_act_index)
def e15_craft_loop():
    """★★★ B1（2026-10-22）：合成闭环 —— **材料够就造得出，不够要说得出缺什么**。

    这是 G1《单夜生存》八条剧本里 P3 的那一条，也是八条里最后一条没有判据的。
    在此之前，「合成」在本引擎里等于不存在：配方表（`recipes.lua`）确实被
    `05_bootstrap.lua:447` 加载了（那段注释写明是为了让 `components/builder.lua`
    能工作），但**没有任何入口**能把它调起来 —— 加载了却调不到，症状就是
    「看起来什么都有，就是一按没反应」。

    实现上**不自己写扣料与产物生成**，走原版 `Builder:DoBuild`（唯一建造入口）。
    所以这条用例真正验的是「接线对不对」，而不是「规则对不对」—— 规则是原版的。

    判据（正向四条 + 反向四条）：
      ① 空背包合成 ⇒ 失败，且原因里**同时**出现"材料不足"与两种材料名
         （只说"失败"等于没说：玩家分不清该去采集还是该改输入）；
      ② 配方名不存在 ⇒ 失败，原因里出现"配方不存在" —— 必须与①**分得开**；
      ③ 空配方名 ⇒ 失败，原因是"必须是非空字符串"；
      ④ ①②③ 三条失败**一个实体都不许留下**（失败路径不得有半成品副作用）；
      ⑤ 给 2 log + 3 cutgrass 后合成 ⇒ 成功，且世界实体数变多、真有 `campfire`；
      ⑥ **材料真被扣**：紧接着原样再合成一次 ⇒ 必须失败。这条同时证明了两件事 ——
         扣料发生了，且判定不是"只要调了就返回 true"；
      ⑦ `craft_stats` 三数分开：成功 1 次、拒绝 ≥3 次（拒绝**不是**错误，要能数出来）；
      ⑧ 反向：失败之后再查世界，`campfire` 的数量不许比成功那次更多。
    """
    s = Sim(seed=20261015, tick_hz=30, world_content=14).boot()

    def world_n():
        ok, info = s.debug_entities(999)
        if not ok:
            return None, info
        return int(info["count"]), info["items"]

    def fires():
        n, items = world_n()
        if n is None:
            return None
        return [e for e in items if str(e.get("prefab")) == "campfire"]

    n0, _ = world_n()
    if n0 is None:
        return False, "实体列表读不出来，合成判据的前提不成立"

    # ① 空背包必须失败，且说得出缺什么
    ok, info = s.craft(0, "campfire")
    if ok:
        return False, ("空背包竟然造出了营火 —— 材料校验没生效"
                       "（这不是「宽松」，是规则根本不看背包）")
    why1 = str(info.get("error") or "")
    if "材料不足" not in why1:
        return False, "材料不足时的原因不对：%r（玩家看了不知道该干什么）" % (why1,)
    for need in ("log", "cutgrass"):
        if need not in why1:
            return False, ("材料不足的原因里没有列出 %s：%r —— "
                           "只说「不足」而不说缺什么，等于没说" % (need, why1))

    # ② 配方不存在必须与①分得开
    ok, info = s.craft(0, "no_such_recipe_zzz")
    if ok:
        return False, "不存在的配方名竟然成功了"
    why2 = str(info.get("error") or "")
    if "配方不存在" not in why2:
        return False, ("配方名写错时的原因不对：%r —— 与「材料不足」混成一句，"
                       "玩家会去采集而真正的问题是名字错了" % (why2,))
    if why2 == why1:
        return False, "两种失败的文案完全一样（分不开就等于没有原因）"

    # ③ 空配方名
    ok, info = s.craft(0, "")
    if ok:
        return False, "空配方名竟然成功了"
    if "非空字符串" not in str(info.get("error") or ""):
        return False, "空配方名的原因不对：%r" % (info.get("error"),)

    # ④ 三次失败不许留下任何东西
    n1, _ = world_n()
    if n1 != n0:
        return False, "三次失败之后实体数从 %d 变成 %d —— 失败路径留下了副作用" % (n0, n1)

    # ⑤ 给料之后必须造得出
    for pf, cnt in (("log", 2), ("cutgrass", 3)):
        okg, g = s.debug_give(0, pf, cnt)
        if not okg:
            return False, "给 %s×%d 失败：%s" % (pf, cnt, g)
    ok, info = s.craft(0, "campfire")
    if not ok:
        return False, ("给足材料后仍然造不出营火：%s —— "
                       "要么配方要的东西不是这两样，要么 DoBuild 走不通" % (info,))
    before = info.get("ents_before")
    after = info.get("ents_after")
    if before is None or after is None:
        return False, "合成结果缺 ents_before/ents_after（没法证明产物真的出现了）"
    if int(after) <= int(before):
        return False, "合成返回成功，但世界实体数没变（%s → %s）—— 产物没落地" % (before, after)
    f1 = fires()
    if not f1:
        return False, "返回成功且实体数变多了，但世界里找不到 campfire —— 增的是别的东西"

    # ⑥ 材料真被扣：原样再来一次必须失败
    ok, info = s.craft(0, "campfire")
    if ok:
        return False, ("材料只够造一个营火，却能连造两个 —— 材料没有被扣掉"
                       "（这是「产物出现了」与「代价被收了」两件事必须分开验的原因）")

    # ⑦ 三个数分开报
    okn, refused, _ = s.craft_stats()
    if okn != 1:
        return False, "craft 成功计数是 %d，期望正好 1" % (okn,)
    if refused < 3:
        return False, "craft 拒绝计数是 %d，期望 ≥3（三类失败都要被数到）" % (refused,)

    # ⑧ 失败没追加新的营火
    f2 = fires()
    if f2 is None or len(f2) > len(f1):
        return False, "最后一次失败之后营火数量从 %d 变成了 %d" % (len(f1), len(f2 or []))

    return True, ("空背包/配方名错/空名三类失败原因**分得开**且都不留残骸；"
                  "给料后造出 campfire（实体 %d→%d）；"
                  "材料真被扣（连造两次第二次失败）；成功 1 / 拒绝 %d"
                  % (int(before), int(after), refused))


def e20_save_bytes_deterministic():
    """★★★ N3（2026-10-22）：存档**字节级确定性** —— 同一状态两次落盘必须一模一样。

    为什么这条比"读回来的值相等"更严：值相等只要求 `json.loads(a) == json.loads(b)`，
    而字典序不稳定、浮点打印不稳定（1.0 vs 1、0.1+0.2）都**不影响**值相等，
    却会让存档 diff 全是噪音、让"两个档是不是同一个世界"变成肉眼不可判。
    DST 的存档是给机器比对的（云存档冲突、回放校验），不是给人读的。

    判据（正向两条 + 反向两条）：
      ① 世界不变时连续两次 `save_collect()` ⇒ JSON 字节的 sha256 **完全相同**；
      ② 再采一次仍然相同（不是"前两次碰巧"）；
      ③ 反向：挪动一个实体 ⇒ 字节必须变（否则说明这份"存档"根本没包含位置）；
      ⚠️ 注意"确定性"的边界：世界时间**在**存档里，所以 step 之后字节变是正常的；
         要防的是「没 step 字节还在变」（时间戳 / 随机数 / 表遍历顺序）。
    """
    import hashlib
    import json

    def blob(sim):
        rec = sim.save_collect()
        return json.dumps(rec, ensure_ascii=False, sort_keys=False).encode("utf-8")

    s = Sim(seed=20261015, tick_hz=30, world_content=14).boot()
    for _ in range(60):
        s.step()

    b1 = blob(s)
    b2 = blob(s)
    b3 = blob(s)
    h = [hashlib.sha256(x).hexdigest() for x in (b1, b2, b3)]
    if h[0] != h[1] or h[1] != h[2]:
        return False, ("同一状态连续三次采集，sha256 不同：\n     %s\n     %s\n     %s\n"
                       "     ⇒ 存档里混进了随时间/随机变化的东西（时间戳？表遍历顺序？）"
                       % (h[0][:16], h[1][:16], h[2][:16]))

    # ★ 曾经在这里写过一条"让时间走 1 秒、字节不许变"的断言 —— **它是错的**，已删。
    #   世界时间（`time`）本来就在存档里，走 1 秒之后它变了，字节**就该**变；
    #   把它写成"不许变"等于要求存档不要保存世界时间。
    #   真正要防的是「**没** step 的情况下字节还在变」（时间戳 / 随机数 / 表遍历顺序），
    #   那已经由上面三次采集覆盖。写错这条断言会让后人去修一个不该修的东西。
    #   另外：读档之后**世界时间必须接上**（A10/A11/B13 已覆盖），这里不重复。

    # ③ 反向：挪一个实体，字节必须变
    ok, d = s.debug_entities(999)
    if not ok or not d["items"]:
        return False, "读不到实体，反向用例没法做"
    # ★ 必须挑一个**有 Transform** 的实体：世界表里第一个往往是
    #   `player_classified` / `inventory_classified` 这类"附属实体"，它们没有 Transform，
    #   挪它会报「实体没有 Transform:SetPosition」—— 而那与存档确定性毫无关系。
    #   （首跑就挑到了那个，报出来的错看起来像"存档不含位置"。）
    cand = [x for x in d["items"] if x["prefab"] == "evergreen"]
    if not cand:
        return False, "世界里没有 evergreen，反向用例没法做"
    g = cand[0]["guid"]
    ent = s.debug_entity(g)[1]
    ok, r = s.debug_move(g, float(ent["x"]) + 3.0, float(ent["z"]) + 1.0)
    if not ok:
        return False, "挪动实体失败：%s" % (r,)
    b5 = blob(s)
    if hashlib.sha256(b5).hexdigest() == h[0]:
        return False, "挪了一个实体之后存档字节**没变** —— 这份存档没包含位置"

    return True, ("三次采集 sha256 全同（%s）✔ / 挪一个实体字节必变 ✔ / %d 字节"
                  % (h[0][:16], len(b1)))


def e19_death_drops_half():
    """★★★ N4（2026-10-22）：死亡代价 —— 背包掉**一半**，而且只掉一半。

    修复前的状态：`M.respawn` 里直接 `p:Remove()`，背包跟着尸体一起消失
    ⇒「死亡」在玩法上等于**免费回城**，没有紧张感，也就没有生存压力。
    （原版 DST 是全掉或按设置不掉；取一半是 07 侧的设计选择，写在 rt_boot 注释里。）

    判据（正向三条 + 反向两条）：
      ① 4 件不同物品在背包里 ⇒ 死亡那一刻地上出现**恰好 2 件**；
      ② `death_drops()` 记账为 2（不是"大概掉了一些"这种自述）；
      ③ 复活照常发生（新身体、`respawns` 至少 +1）—— 掉落不该破坏复活链；
      ④ 反向：**不许全掉**（4 件全落地 = "一半"没实现，只是把 Remove 挪了个位置）；
      ⑤ 反向：**没死的时候**不掉东西（`death_drops()` 一动不动）。
    """
    s = Sim(seed=20261015, tick_hz=30).boot()
    L = s.lua
    L.globals().RT = s.api

    def ground(names):
        ok, d = s.debug_entities(999)
        if not ok:
            return None
        return [x for x in d["items"] if str(x.get("prefab")) in names]

    items = ["log", "twigs", "flint", "cutgrass"]
    for pf in items:
        ok, r = s.debug_give(0, pf, 1)
        if not ok:
            return False, "给 %s 失败：%s" % (pf, r)

    # ⑤ 先确认没死时不掉
    if s.death_drops() != 0:
        return False, "还没死就记了掉落数：%r" % (s.death_drops(),)
    for _ in range(30):
        s.step()
    if s.death_drops() != 0:
        return False, "活着的时候走了 1 秒，掉落数变成了 %r（不该掉东西）" % (s.death_drops(),)

    # ★ 注意：**背包里的物品也在世界表里**（DST 的机制，位置跟随持有者）。
    #   所以"地上有几件"不能靠"世界表里有没有"来判 —— 死前就是 4 件。
    #   真正能区分的是**死亡前后的差值**：掉的 2 件留在地上，没掉的 2 件跟着尸体一起消失。
    g0 = ground(items)
    if g0 is None:
        return False, "读不到实体列表"
    if len(g0) != 4:
        return False, ("死之前世界表里有 %d 件（期望 4：给了 4 件进背包）—— "
                       "基线不成立，后面的差值就说明不了问题" % (len(g0),))

    # 扣光血
    L.eval("(function() RT.player.components.health:DoDelta(-9999) return 1 end)()")
    st = s.stats()
    if st.get("player_alive") is not False:
        return False, "扣光血后 player_alive 仍是 %r" % (st.get("player_alive"),)

    # 死的那一拍就该掉（auto_respawn 第一次观察到死亡）
    for _ in range(6):
        s.step()
    dropped = s.death_dropped_of(0)
    total = s.death_drops()
    if dropped != 2:
        return False, ("死了之后掉了 %r 件，期望 2（4 件里隔一个掉一个）—— "
                       "0 说明掉落没接上，4 说明是「全掉」不是「一半」" % (dropped,))
    if total != 2:
        return False, "death_drops() 总数是 %r，期望 2" % (total,)

    # ★ 语义确认（实测踩过）：死亡 = **一半掉地上可捡回、另一半永久丢失**。
    #   最初以为"另一半会留在尸体背包里"，但 `Remove()` 会把背包里的东西也丢出来 ——
    #   所以必须在掉落之后**明确销毁另一半**，否则"掉一半"会静默变成"全掉"。
    #   这条判据看的是**玩家能挽回的那部分**：地上的 2 件。
    g_mid = ground(items)
    if g_mid is None or len(g_mid) != 2:
        return False, ("死亡那一拍世界表里有 %r 件，期望 2（一半掉出来、另一半销毁）"
                       % (len(g_mid or []),))

    # ③ 复活照常
    for _ in range(140):
        s.step()
        if s.stats().get("player_alive") is True:
            break
    if s.stats().get("player_alive") is not True:
        return False, "掉了一半之后没有复活（respawns=%r）—— 掉落破坏了复活链" % (s.stats().get("respawns"),)
    if int(s.stats().get("respawns") or 0) < 1:
        return False, "复活了但 respawns 没涨"

    # ① 复活之后（尸体已被移除）世界表里只剩掉出来的那 2 件
    g1 = ground(items)
    if g1 is None or len(g1) != 2:
        return False, ("复活后世界表里有 %r 件，期望 2 —— 掉的 2 件留下、"
                       "没掉的 2 件应随尸体消失" % (len(g1 or []),))
    # ④ 不许全掉（全掉的话这里会是 4）
    if len(g1) >= 4:
        return False, "4 件全留在世界里 —— 那是「全掉」不是「掉一半」"

    return True, ("活着不掉 ✔ / 死后那一拍掉了 %d 件（4 件的一半）✔ / 地上恰好 2 件 ✔ / "
                  "没全掉 ✔ / 复活照常（respawns=%r）" % (2, s.stats().get("respawns")))


def e18_editor_undo_move():
    """★★★ M1-1（2026-10-22）：编辑器撤销 —— 拖错了能回去。

    在此之前 `/editor/move` 是**直接改世界**：挪走就回不去。没有撤销的编辑器
    有个隐性代价 —— 用户不敢动大东西，于是编辑器"能用"但"没人敢用"。

    栈本身（`rt/commands.py`）已被 U47~U52 锁住语义，所以这条判据**只验接线**：
    服务端的 move 是否真的走栈、undo 是否真的把世界恢复、合并是否生效。
    两层分开测的理由：栈错了是算法问题（单测里 5 秒能复现），接线错了是集成问题
    （要起引擎 3 秒）；混在一起时，一次红不知道该去改哪边。

    判据（正向三条 + 反向三条）：
      ① move 之后坐标变了，且 `undo_depth` 增加；
      ② undo ⇒ 坐标**逐值**回到移动前；redo ⇒ 回到移动后；
      ③ 同一实体的连续 3 次 move ⇒ 只占 1 步（MERGE_ENDS），一次 undo 回到最初；
      ④ 反向：栈空时 undo 必须失败且理由含"没有可撤销"（不是"成功但没变化"）；
      ⑤ 反向：undo 之后做一次新的 move ⇒ redo 必须不可用（分支被清空）；
      ⑥ 反向：undo 一次之后世界确实停在 before，不是"undo 了但坐标没动"。
    """
    def ent(sim, g):
        ok, x = sim.debug_entity(g)
        return x if ok else {}

    s = Sim(seed=20261015, tick_hz=30, world_content=14).boot()

    # ④ 先验空栈
    ok, r = s.undo()
    if ok:
        return False, "空栈 undo 竟然成功了（会把「没做事」当成一次操作）"
    if "没有可撤销" not in str(r.get("error", "")):
        return False, "空栈 undo 的拒绝理由不对：%r" % (r.get("error"),)

    ok, sp = s.debug_spawn("evergreen", 3.0, 1.0)
    if not ok:
        return False, "spawn 失败：%s" % (sp,)
    g = sp["guid"]
    x0, z0 = ent(s, g)["x"], ent(s, g)["z"]

    # ① 移动
    ok, r = s.move_via_stack(g, 8.0, 4.0)
    if not ok:
        return False, "带撤销的移动失败：%s" % (r,)
    if r.get("undo_depth", 0) < 1:
        return False, "移动成功但 undo_depth = %r（说明没走栈）" % (r.get("undo_depth"),)
    e = ent(s, g)
    if abs(e["x"] - 8.0) > 0.01 or abs(e["z"] - 4.0) > 0.01:
        return False, "移动后坐标是 (%r,%r)，期望 (8.0,4.0)" % (e["x"], e["z"])

    # ② undo / redo
    ok, r = s.undo()
    if not ok:
        return False, "撤销失败：%s" % (r,)
    e = ent(s, g)
    if abs(e["x"] - x0) > 0.01 or abs(e["z"] - z0) > 0.01:
        return False, ("撤销后坐标 (%r,%r)，期望回到 (%r,%r) —— "
                       "「撤销了但没动」是这条判据最该抓的形态" % (e["x"], e["z"], x0, z0))
    ok, r = s.redo()
    if not ok:
        return False, "重做失败：%s" % (r,)
    e = ent(s, g)
    if abs(e["x"] - 8.0) > 0.01 or abs(e["z"] - 4.0) > 0.01:
        return False, "重做后坐标 (%r,%r)，期望回到 (8.0,4.0)" % (e["x"], e["z"])

    # ③ 连续 move 合并
    for i, (xx, zz) in enumerate([(9.0, 4.0), (10.0, 5.0), (11.0, 6.0)], 1):
        ok, r = s.move_via_stack(g, xx, zz)
        if not ok:
            return False, "第 %d 次连续移动失败：%s" % (i, r)
    # ★ 期望 **2** 步而不是 1：上面做过一次 undo→redo，那是一个**切口** ——
    #   跨过切口之后的移动属于新的一段连续动作，不该并进切口之前那一步里
    #   （首跑就是按 1 步写的，结果暴露出栈里缺这个屏障，见 commands.py 的 _no_merge）。
    if r.get("undo_depth") != 2:
        return False, ("连续 3 次移动之后总步数 %r，期望 2（redo 之前那步 + 之后这一段）"
                       % (r.get("undo_depth"),))
    ok, r = s.undo()
    if not ok:
        return False, "合并后撤销失败：%s" % (r,)
    e = ent(s, g)
    if abs(e["x"] - 8.0) > 0.01:
        return False, ("合并撤销后 x=%r，期望回到合并**起点** 8.0（不是中途的 10.0）"
                       % (e["x"],))

    # ⑤ undo 之后做新操作 ⇒ redo 分支必须清空
    ok, r = s.move_via_stack(g, 1.0, 1.0)
    if not ok:
        return False, "撤销后的新移动失败：%s" % (r,)
    ok, r = s.redo()
    if ok:
        return False, ("撤销之后做了新操作，redo 仍然成功 —— "
                       "redo 分支没被清空，重做会把新操作覆盖掉")

    # ⑥ 再确认一次世界状态与栈一致
    st = s.undo_stats()
    if st.get("version", 0) < 5:
        return False, "version = %r，多次变更后应有 >= 5" % (st.get("version"),)

    return True, ("空栈 undo 被拒且理由正确 ✔ / move→undo→redo 逐值往返 ✔ / "
                  "连续 4 次移动合并成 1 步且撤销回到合并起点 ✔ / "
                  "undo 后新操作清空 redo ✔ / version=%r" % (st.get("version"),))


def e17_monster_fights_back():
    """★★★ B6（2026-10-22）：**生物会还手** —— P5 的另一半。

    ★ 这条判据存在的直接原因值得记：`G1剧本验收表` 第一版把 P5 判成
      「部分覆盖，蜘蛛不还手」，依据是**旧的会话结论**（"brain targetfn 未锁玩家"）。
      实测 30 秒就打脸：玩家血 150 → 130 → 110 → … → 10 →（死亡复活）。
      ⇒ 教训：**"某功能缺失"这种结论也会过期**。凡是要写进文档的负面判断，
        必须当轮实测，否则就会变成一条被反复引用的假缺口（比假绿灯更浪费）。

    判据（正向两条 + 反向两条）：
      ① 放一只蜘蛛在 1.5 格内、**玩家不做任何操作** ⇒ 玩家血量必须下降 > 0；
      ② 掉血必须来自「蜘蛛在打」—— 同期蜘蛛的 `action` 是 `ATTACK`；
      ③ 反向：同样的时间窗内，**没有蜘蛛**时玩家血量不许掉（排除"血自己会掉"）；
      ④ 反向：蜘蛛放在 20 格外 ⇒ 血量不许掉（排除"远程扣血"）。
    """
    def hp(sim):
        return sim.stats().get("player_health")

    # ③ 基线：没有敌人时血不该掉
    s0 = Sim(seed=20261015, tick_hz=30, world_content=14).boot()
    h0 = hp(s0)
    for _ in range(300):
        s0.step()
    if hp(s0) != h0:
        return False, ("没有敌人时玩家血量从 %r 变成 %r —— 基线不成立，"
                       "后面的掉血就说不清是谁造成的" % (h0, hp(s0)))

    # ① 近距离：必须被打
    s = Sim(seed=20261015, tick_hz=30, world_content=14).boot()
    ok, r = s.debug_spawn("spider", 1.5, 0.0)
    if not ok:
        return False, "spider 生成失败：%s" % (r,)
    g = r["guid"]
    h_before = hp(s)
    seen_attack = False
    for _ in range(300):
        s.step()
        ok, e = s.debug_entity(g)
        if ok and e.get("action") == "ATTACK":
            seen_attack = True
        if hp(s) is not None and h_before is not None and hp(s) < h_before:
            break
    h_after = hp(s)
    if h_before is None or h_after is None:
        return False, "读不到玩家血量（%r → %r）" % (h_before, h_after)
    if h_after >= h_before:
        return False, ("10 秒内玩家血量没掉（%r → %r）—— 生物不还手，"
                       "P5 的「它会反击」这条没实现" % (h_before, h_after))
    if not seen_attack:
        return False, ("玩家掉血了，但蜘蛛的 action 从没出现过 ATTACK —— "
                       "掉血不是它打的（可能是别的旁路在扣血）")

    # ④ 远距离：不许掉
    s2 = Sim(seed=20261015, tick_hz=30, world_content=14).boot()
    ok, r2 = s2.debug_spawn("spider", 20.0, 0.0)
    if not ok:
        return False, "远处蜘蛛生成失败：%s" % (r2,)
    h2 = hp(s2)
    for _ in range(300):
        s2.step()
    if hp(s2) != h2:
        return False, ("蜘蛛在 20 格外，玩家血量却从 %r 掉到 %r —— 有远程扣血"
                       % (h2, hp(s2)))

    return True, ("无敌人时血不掉（%r 基线）；1.5 格内 10 秒被打 %r → %r 且蜘蛛 action=ATTACK；"
                  "20 格外不掉血" % (h0, h_before, h_after))


def e16_equip_and_tool():
    """★★★ B3（2026-10-22）：装备与工具 —— G1 剧本 P4。

    ★ 先说清楚这条判据**推翻了什么**（比它验了什么更重要）：
      `引擎开发计划` 给 P4 写的验收是「空手 6 下 / 持斧 3 下（workleft 消耗率 1 vs 2）」。
      实测**两条都错**：
        ① 树的工作量不是 6 —— `evergreen` 有多个变体，实测见过 workleft = 5 与 15 两种；
        ② 斧头**不会更快** —— `prefabs/axe.lua:116` 是 `tool:SetAction(ACTIONS.CHOP, 1)`，
           而 `Tool:GetEffectiveness` 返回 `self.actions[action] or 0`；
           空手走 `numworks` 的兜底 1 ⇒ **两者都是每次 -1**。
      所以「装了斧头砍得更快」在 DST 的原版数据里根本不成立。这里如实记录，
      并把判据改成「装备链路真的通了」，而不是把一个错前提写进判据。

    ★ 另一处必须记住的原版行为：`Builder:DoBuild` 对「产物可装备 + 对应槽位空」
      **会自动装备**（builder.lua 里的 equippable 分支）。所以 `craft("axe")` 之后
      斧头**在手上、不在背包** —— 这也让 `equip` 必须具备幂等语义，
      否则会把"已经装好了"报成"背包里没有"。

    判据（正向四条 + 反向三条）：
      ① 初始手上是空的；
      ② 给 1 twigs + 1 flint 合成斧头 ⇒ **hands 变成 axe**（原版自动装备）；
      ③ 对已装备的物品再 equip 一次 ⇒ **幂等成功**，不报"背包槽=nil"；
      ④ 装备状态下砍树 ⇒ 树倒下（`waction` 从 CHOP 变 DIG）且世界多了 log，
         并且这一次动作**携带了手持物品**（`act_invobject_count > 0`）；
      ⑤ 反向：全新世界、不装备 ⇒ 同样能砍倒，但 `act_invobject_count == 0`
         （证明工具不是必需品，且"携带手持物"不是恒真的自述）；
      ⑥ 反向：equip 一个不存在的 guid ⇒ 必须被拒且带原因；
      ⑦ 记录事实：空手与持斧**每次的 workleft 跌幅都是 1** ——
         把「斧头不加速」写成断言，防止后人凭直觉去"修"一个本来正确的行为。
    """
    def _ent(sim, guid):
        ok, x = sim.debug_entity(guid)
        return x if ok else {}

    def _hands(sim):
        ok, d = sim.debug_entities(999)
        if not ok or not d["items"]:
            return None
        return _ent(sim, d["items"][0]["guid"]).get("hands")

    def _chop(sim, budget=900):
        """spawn 一棵树 + act，返回 (是否倒下, 跌幅列表, 掉了几个 log, 拍数)"""
        ok, r = sim.debug_spawn("evergreen", 1.7, 0.0)
        if not ok:
            return None, [], 0, 0, "spawn 失败：%s" % (r,)
        g = r["guid"]
        logs0 = len([x for x in sim.debug_entities(999)[1]["items"] if x["prefab"] == "log"])
        if not sim.api.act(0, g)[0]:
            return None, [], 0, 0, "act 被拒"
        drops, last, fell = [], _ent(sim, g).get("workleft"), False
        i = 0
        for i in range(budget):
            sim.step()
            ok, x = sim.debug_entity(g)
            if not ok:
                fell = True
                break
            w = x.get("workleft")
            if w != last:
                if isinstance(last, (int, float)) and isinstance(w, (int, float)):
                    drops.append(round(last - w, 3))
                last = w
            if x.get("waction") == "DIG":
                fell = True
                break
        logs1 = len([x for x in sim.debug_entities(999)[1]["items"] if x["prefab"] == "log"])
        return fell, drops, logs1 - logs0, i + 1, None

    # ① 初始空手
    s = Sim(seed=20261015, tick_hz=30, world_content=14).boot()
    if _hands(s) is not None:
        return False, "新世界一开始手上就有东西：%r" % (_hands(s),)

    # ② 合成斧头 ⇒ 自动上手
    for pf, cnt in (("twigs", 1), ("flint", 1)):
        okg, g = s.debug_give(0, pf, cnt)
        if not okg:
            return False, "给 %s 失败：%s" % (pf, g)
    ok, info = s.craft(0, "axe")
    if not ok:
        return False, "合成斧头失败：%s（P4 的前提不成立）" % (info,)
    if _hands(s) != "axe":
        return False, ("合成斧头后手上是 %r，不是 axe —— 原版 DoBuild 对可装备产物会自动装备，"
                       "没有上手说明那条分支没走通" % (_hands(s),))

    ok, d = s.debug_entities(999)
    axes = [x for x in d["items"] if x["prefab"] == "axe"]
    if not axes:
        return False, "斧头既不在手上也不在世界表里（凭空消失了）"

    # ③ equip 幂等
    ok, r = s.equip(0, axes[0]["guid"])
    if not ok:
        return False, ("对已装备的物品再 equip 一次被拒：%s —— "
                       "真实状态是「已经装好了」，报失败会让调用方去修一个没坏的东西" % (r,))

    # ④ 装备状态砍树
    fell, drops, nlog, ticks, err = _chop(s)
    if err:
        return False, "装备状态下砍树：%s" % (err,)
    if not fell:
        return False, "装备状态下砍了 %d 拍树都没倒" % (ticks,)
    if nlog < 1:
        return False, "树倒了但没掉 log（掉落链断了）"
    inv_n = s.api.act_invobject_count()
    if inv_n <= 0:
        return False, ("穿装备砍树时 act_invobject_count 还是 0 —— "
                       "动作没有带手持物品，砍伐的 numworks 会永远走兜底 1")
    if not drops:
        return False, "没观察到任何 workleft 变化（砍是砍了，但账没动）"

    # ⑤ 反向：不装备也能砍，且不携带手持物
    s2 = Sim(seed=20261015, tick_hz=30, world_content=14).boot()
    fell2, drops2, nlog2, ticks2, err2 = _chop(s2)
    if err2:
        return False, "空手砍树：%s" % (err2,)
    if not fell2:
        return False, "空手砍了 %d 拍树没倒（工具变成了必需品？原版不是这样）" % (ticks2,)
    if s2.api.act_invobject_count() != 0:
        return False, ("空手砍树时 act_invobject_count = %d，应该是 0 —— "
                       "说明这不是「有没有手持物」的记账，而是个恒真的计数"
                       % (s2.api.act_invobject_count(),))

    # ⑥ 反向：ghost guid 必须被拒
    okg, rg = s.equip(0, 999999)
    if okg:
        return False, "equip 一个不存在的 guid 竟然成功了"
    if "不存在" not in str(rg.get("error", "")):
        return False, "equip 幽灵 guid 被拒了，但理由不对：%r" % (rg.get("error"),)

    # ⑦ 记录事实：两者每次跌幅都是 1
    if set(drops) != {1.0} or set(drops2) != {1.0}:
        return False, ("workleft 跌幅 装备时=%r 空手=%r —— 若不是各为 1，说明"
                       "tool 效率或 numworks 的算法被改过（原版 axe 的 effectiveness 是 1）"
                       % (drops[:4], drops2[:4]))

    return True, ("合成即上手（原版 DoBuild 自动装备）✔ / equip 幂等 ✔ / "
                  "装备砍树倒下且掉 %d 个 log，动作携带手持物 %d 次 ✔ / "
                  "空手照样能砍但携带 0 次 ✔ / 幽灵 guid 被拒 ✔ / "
                  "两者每次跌幅都是 1（**斧头不加速**，这是原版数据不是缺陷）"
                  % (nlog, inv_n))


def e14_editor_channel():
    """★★ P62 编辑器通道：列 / 生成 / 移动 / 删除 四件套 + 玩家保护 + 门槛分离。

    这条判据守的是什么：
      在此之前客户端**只有一张地图 + 一行 HUD** —— 能走能砍，但「世界里有谁、
      它在哪、能不能改」全靠命令行。P62 加了 `/editor/*` 与前端面板，于是
      「看得见 → 选得中 → 改得动 → 存得下」这条链必须有一条判据守着。

    三个容易假绿的地方，逐条堵住：
      ① **只看 HTTP 200 就算过** —— 200 只证明路由存在，不证明世界被改了。
         所以每一步都**回读**：列表里在不在、坐标真的变了没有。
      ② **把「列表条数」当成「世界总数」** —— `count` 与 `listed` 必须分开断言，
         否则 `limit` 会把「世界只有 6 个」伪装成事实。
      ③ **门槛退化** —— `/editor/*` 与 `/debug/*` 是**两套**门槛。主服务端没开
         `--allow-debug`，所以 `/debug/stats` 必须 **404**、`/editor/entities` 必须
         **200**。谁把它们合并成一个开关，这一条当场红。

    副作用：只用**自己 spawn 出来的对象**做增删改，不碰世界原有实体 ——
      否则后续判据（B25/B26/E9…）会在一个被改过的世界上跑，红得莫名其妙。
    """
    import json as _json
    import urllib.error as _urlerr

    def code_of(path):
        try:
            st, _ = _http_get(path, timeout=8)
            return st
        except _urlerr.HTTPError as e:
            return e.code
        except Exception:                                        # noqa: BLE001
            return -1

    def jget(path):
        try:
            st, body = _http_get(path, timeout=8)
        except _urlerr.HTTPError as e:
            try:
                return e.code, _json.loads(e.read().decode("utf-8"))
            except Exception:                                    # noqa: BLE001
                return e.code, {}
        try:
            return st, _json.loads(body)
        except ValueError:
            return st, {}

    # ---- ① 列表自洽（count / listed / items 三者关系） ----------------------
    st, d = jget("/editor/entities?limit=6")
    if st != 200:
        return False, "/editor/entities 返回 %s（回环来源应当 200）" % st
    if not d.get("ok"):
        return False, "/editor/entities 失败：%r" % (d.get("error"),)
    items = d.get("items") or []
    if len(items) != d.get("listed"):
        return False, "listed=%r 与 items 实际长度 %d 不一致" % (d.get("listed"), len(items))
    if len(items) != 6:
        return False, "limit=6 却返回了 %d 条" % len(items)
    if (d.get("count") or 0) < len(items):
        return False, "count=%r 小于返回条数 %d —— 两个数被写反了" % (d.get("count"), len(items))
    if not all(isinstance(e.get("guid"), int) for e in items):
        return False, "items 里有 guid 不是整数的项：%r" % (items[:2],)

    # ---- ② 门槛分离：同一台机器上 /debug/* 仍是 404 -------------------------
    c_dbg = code_of("/debug/stats")
    if c_dbg != 404:
        return False, ("/debug/stats 返回 %s（主服务端没开 --allow-debug，应当是 404）"
                       "—— 编辑器门槛可能被合并进运维开关了" % c_dbg)
    c_ed, d_all = jget("/editor/entities?limit=800")
    if c_ed != 200 or not d_all.get("ok"):
        return False, "同一台机器上 /editor/entities 返回 %s/%r" % (c_ed, d_all.get("error"))
    base_count = int(d_all.get("count") or 0)

    # ---- ③ 生成 ⇒ 列表里出现 ----------------------------------------------
    st, sp = jget("/editor/spawn?prefab=rock1&x=7.5&z=-3.5")
    if st != 200 or not sp.get("ok"):
        return False, "生成 rock1 失败：%s/%r" % (st, sp.get("error"))
    g = int(sp["guid"])
    st, d2 = jget("/editor/entities?limit=800")
    found = [e for e in (d2.get("items") or []) if e.get("guid") == g]
    if len(found) != 1:
        return False, "新生成的 #%d 没出现在列表里（找到 %d 个）" % (g, len(found))
    if int(d2.get("count") or 0) != base_count + 1:
        return False, "世界总数没 +1：%d → %r" % (base_count, d2.get("count"))

    # ---- ④ 移动 ⇒ 回读坐标真的变了 ----------------------------------------
    st, mv = jget("/editor/move?guid=%d&x=-11.25&z=4.75" % g)
    if st != 200 or not mv.get("ok"):
        return False, "移动 #%d 失败：%s/%r" % (g, st, mv.get("error"))
    if abs(float(mv.get("x", 0)) + 11.25) > 0.02 or abs(float(mv.get("z", 0)) - 4.75) > 0.02:
        return False, "移动回执不是回读值：%r" % (mv,)
    st, ent = jget("/editor/entities?limit=800")
    cur = [e for e in (ent.get("items") or []) if e.get("guid") == g]
    if not cur:
        return False, "移动后 #%d 从列表里消失了" % g
    if abs(cur[0]["x"] + 11.25) > 0.02 or abs(cur[0]["z"] - 4.75) > 0.02:
        return False, ("列表里 #%d 还在旧位置 (%r, %r) —— 回执说动了，列表说没动"
                       % (g, cur[0].get("x"), cur[0].get("z")))

    # 反向：不存在的 guid 必须被拒（不能静默成功）
    st, bad = jget("/editor/move?guid=99999999&x=0&z=0")
    if bad.get("ok"):
        return False, "移动不存在的 guid 竟然成功了：%r" % (bad,)

    # ---- ⑤ 删除 ⇒ 列表里没有了 --------------------------------------------
    st, rm = jget("/editor/remove?guid=%d" % g)
    if st != 200 or not rm.get("ok"):
        return False, "删除 #%d 失败：%s/%r" % (g, st, rm.get("error"))
    st, d3 = jget("/editor/entities?limit=800")
    if any(e.get("guid") == g for e in (d3.get("items") or [])):
        return False, "删完之后 #%d 仍在列表里" % g
    if int(d3.get("count") or 0) != base_count:
        return False, "删完之后世界总数没回到 %d（实为 %r）" % (base_count, d3.get("count"))

    # ---- ⑥ 玩家实体必须拒绝删除（会破坏会话身份） --------------------------
    players = [e for e in (d3.get("items") or []) if e.get("prefab") == "wilson"]
    if not players:
        return False, "列表里找不到任何 wilson —— 这条反向判据没验到东西"
    st, pr = jget("/editor/remove?guid=%d" % players[0]["guid"])
    if pr.get("ok"):
        return False, "玩家实体 #%d 被删掉了（会破坏 key→角色 的映射）" % players[0]["guid"]
    if "拒绝" not in str(pr.get("error", "")):
        return False, "玩家删除被拒了，但理由不对：%r" % (pr.get("error"),)

    return True, ("列/生成/移动/删除四件套全走通且每步**回读**；"
                  "count 与 listed 分开成立；玩家删除被拒；"
                  "反向：/debug/stats 仍 404（两套门槛没合并）· 幽灵 guid 被拒")


check("E13 战斗闭环：打生物 → 掉血 → 死 → 掉战利品；反向：太远被拒 · 树仍走 CHOP", e13_attack_loop)
check("E14 编辑器通道：列/生成/移动/删除全回读；反向：玩家删除被拒 · /debug 仍 404", e14_editor_channel)
check("E20 存档字节确定性：同状态三次采集 sha256 全同；反向：挪一个实体必变", e20_save_bytes_deterministic)
check("E19 死亡掉一半背包：活着一件不掉 · 死后那一拍掉 2/4 · 地上恰好 2 件；反向：不许全掉 · 复活照常", e19_death_drops_half)
check("E18 编辑器撤销：move→undo→redo 逐值往返 · 连续移动合并成 1 步；反向：空栈被拒 · undo 后新操作清空 redo", e18_editor_undo_move)
check("E17 生物会还手：无操作下 10 秒内玩家掉血且蜘蛛 action=ATTACK；反向：无敌人 / 20 格外都不掉血", e17_monster_fights_back)
check("E16 装备与工具：合成即上手 · equip 幂等 · 砍伐携带手持物；反向：空手也能砍（0 次携带）· 幽灵 guid 被拒 · 两类跌幅都是 1（斧头不加速）", e16_equip_and_tool)
check("E15 合成闭环：材料够就造得出（产物真在世界里）· 材料真被扣；反向：不足/配方不存在/空名三类原因必须分得开 · 失败不留残骸", e15_craft_loop)
check("D4 会话身份挺过重启（槽位/角色/位置都接着上次）；反向：无 key 的存档许不出身份", d4_session_identity_survives_restart)
check("B25 P20：每个客户端有自己的角色（you 握手 + 槽位回收）", b25_每个客户端有自己的角色)
check("B26 P20 核心：**A 的输入只能动 A 的角色**", b26_输入互不干扰)
check("B26b 连接号不复用：中途有人进出，D 与 E 不许顶成同一个角色", b26b_连接号不复用)
check("B27 回放按「上线时刻」重建玩家；反向：抹掉 joins ⇒ 第 1 拍就露馅", b27_replay_join_timing)


# =============================================================================
# 收尾
# =============================================================================
_stop_debug_server()      # ★ E8 自己要起一个带 --allow-debug 的服务端，收尾必须停掉
if PROC.get("p") and PROC["p"].poll() is None:
    PROC["p"].terminate()
    try:
        PROC["p"].wait(timeout=5)
    except Exception:                                            # noqa: BLE001
        PROC["p"].kill()
if PROC.get("lf"):
    try:
        PROC["lf"].close()
    except Exception:                                            # noqa: BLE001
        pass
if FAIL and PROC.get("log"):
    print("  （服务端日志留档：%s）" % PROC["log"])

print("\n" + "─" * 74)
print("  结果：%d 通过 / %d 失败" % (PASS, FAIL))
print("─" * 74)
sys.exit(0 if FAIL == 0 else 1)
