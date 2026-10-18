#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""test_stall_watchdog.py —— C1：**停帧看门狗**（§9v.5「模拟循环停住」）

════════════════════════════════════════════════════════════════════════════
这件事的来历（决定了判据该长什么样）
════════════════════════════════════════════════════════════════════════════
`校验报告-P43` 的 C1 原文：

    §9v.5「某节奏让模拟循环停住」**未复现**（本轮第 3 次尝试…）
    影响：客户端极端节奏下可能停帧（**未证实**）
    当前状态位：保持 tools/repro_v5.py 可复跑；若线上再出现，先抓这个脚本的输出再加条件

★ 关键判断：**三次没复现 ≠ 不存在**。它真正意味着的是 ——
  「下一次它发生时，我们**仍然没有证据**」。
  所以 C1 要修的不是「那个未知的 bug」，而是**取证能力**：
  当循环真的不动了，必须有人（别的线程）当场发现、计数、并**抓住那一刻的栈**。

★ 因此看门狗**不能**写在 `sim_loop` 的循环体里：
  单线程里的看门狗看不见自己卡死 —— 循环停了，看门狗跟着停，一起沉默。
  这是本判据唯一不可妥协的设计点，也是下面 A1/**B3** 存在的理由。

════════════════════════════════════════════════════════════════════════════
判据分两层（每一条都要能红）
════════════════════════════════════════════════════════════════════════════
A. **部件级**（进程内，不启服务端）—— 判「看门狗的函数本身对不对」：
   A1 停帧 ⇒ 计数 +1（且 gap 记在案）
   A2 心跳一直在推进 ⇒ **一次都不许记**（对照：证明判据不是恒绿的橡皮图章）
   A3 一次停帧只记 **1** 次（0.6 s 内轮询 12 次，不许灌水成 12 次）
   A4 gap **小于**阈值 ⇒ 不记（证明阈值真的被当阈值用，不是 `gap > 0`）

B. **集成级**（真起服务端 + 真 HTTP）—— 判「用户/运维看到的那个面上对不对」：
   B1 基线：`/healthz` 里 `stalls = 0`、`stall_threshold` **等于环境变量给的值**、
      `stall_age` 很小（⇒ 世界确实在走，心跳在推进）
   B2 `/debug/stall?ms=4000` 返回 200 且回 "queued"
   B3 ★★★ **停帧**进行中就能看到 `stalls = 1`，且此刻 `stall_age > 阈值`
      —— 这是「看门狗在**另一个线程**里」的唯一外部证据：
         如果它写在 `sim_loop` 里，那一拍正在 `sleep`，检查根本没机会执行；
         等循环恢复后 `beat` 立刻就被重写，gap 又变小 ⇒ **永远不会记到这一笔**。
      并且 `last_stall.trace` **必须非空**（取证能力本身就是要交付的东西）
   B4 恢复：`stall_age` 掉回 < 0.5，且 `stats.tick` 继续增长（世界自愈，不是卡死）
   B5 不许灌水：恢复后再等 1 s，`stalls` 仍然是 **1**
   B6 ★ 反向：另起一个**不带** `--allow-debug` 的服务端 ⇒ `/debug/stall` 必须 **404**
      （这个端点能让世界停住，不能裸奔在公网上 —— 与 `/debug/kill` 同一开关）
      ★ 顺带把它的 `RT_STALL_SEC` 设成另一个值 ⇒ `stall_threshold` 必须跟着变
        （证明这个阈值**不是**写死的常量）

跑法：python tests/test_stall_watchdog.py       退出码 0 = 全过
环境变量：
    RT_STALL_PORT     调试服务端端口（默认 8801）
    RT_STALL_CTRL_PORT  对照服务端端口（默认 8802）
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time

# ★★ 连本机起的服务端**不该走代理**（本工程在沙箱里实测踩到：注入了 http_proxy
#   而 no_proxy 为空 ⇒ 失败信息变成 502，指向一个完全不相干的真因）。
os.environ["no_proxy"] = "127.0.0.1,localhost"
os.environ["NO_PROXY"] = "127.0.0.1,localhost"

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                  # 07-通用引擎
RT = os.path.join(ROOT, "rt")
sys.path.insert(0, RT)

from server import Hub, watchdog_loop        # noqa: E402

PORT_DEBUG = int(os.environ.get("RT_STALL_PORT", "8801"))
PORT_CTRL = int(os.environ.get("RT_STALL_CTRL_PORT", "8802"))

# ★ 阈值与「造的停帧时长」是一对：停 4 s / 阈值 1.5 s ⇒ 中间有 2.5 s 的窗口
#   能观察到「还在停着，但已经被记下来了」。两者都通过**环境变量**传进去，
#   这样 B1/B6 同时也就验了「阈值不是写死的」。
STALL_SEC = 1.5
STALL_MS = 4000
CTRL_STALL_SEC = 2.5

PASS, FAIL = 0, 0

# ★★ 本文件的**断言条数**必须显式声明，并在文件末尾自校验。
#   为什么不能靠「静态数 `check(` 的调用行」：一次调用可能跑出多条断言
#   （①e 渲染那组就是 15 行调用 → 21 条断言，因为断言写在循环里）。
#   两种口径并存 = 两张表各自计算、一起过期 —— 本工程反复踩过的那个母题。
#   ⇒ 以**声明值**为唯一来源，而声明值由测试自己守（条数对不上就直接红）。
EXPECT_ITEMS = 15


def check(name, fn):
    global PASS, FAIL
    t0 = time.perf_counter()
    try:
        ok, info = fn()
    except Exception as e:                                        # noqa: BLE001
        ok, info = False, "抛异常: %s: %s" % (type(e).__name__, e)
    ms = (time.perf_counter() - t0) * 1000
    if ok:
        PASS += 1
        print("  ✔ %-46s %s  (%.0f ms)" % (name, info, ms))
    else:
        FAIL += 1
        print("  ✘ %-46s %s  (%.0f ms)" % (name, info, ms))
    return ok


# =============================================================================
# A. 部件级：看门狗函数本身
# =============================================================================
print("═" * 78)
print("  A. 部件级：watchdog_loop 会不会响 / 会不会乱响 / 会不会灌水")
print("═" * 78)


def _run_wd(hub, seconds, check_sec=0.05):
    """跑看门狗 `seconds` 秒，返回进程内的线程对象（已 join）。"""
    stop = threading.Event()
    t = threading.Thread(target=watchdog_loop, args=(hub, stop),
                         kwargs={"check_sec": check_sec}, daemon=True)
    t.start()
    time.sleep(seconds)
    stop.set()
    t.join(2.0)
    return t


def a1_stall_counts():
    """停帧 ⇒ 计数 +1，并且把 gap 记在案。"""
    hub = Hub()
    hub.stall_threshold = 0.2
    hub.beat = time.perf_counter() - 1.0     # 假装「最后一拍是 1 s 前」
    _run_wd(hub, 0.35)
    if hub.stalls != 1:
        return False, "期望 stalls=1，实际 %d（看门狗没响）" % hub.stalls
    ls = hub.last_stall or {}
    if not isinstance(ls.get("gap"), (int, float)) or ls["gap"] < 0.2:
        return False, "last_stall.gap 不合理: %r" % (ls.get("gap"),)
    return True, "stalls=1 gap=%.2fs threshold=%.1fs" % (ls["gap"], ls["threshold"])


def a2_alive_no_alarm():
    """对照：心跳一直在推进 ⇒ **一次都不许记**。

    ★ 这条不是凑数：A1 只证明「响了」，证明不了「不乱响」。一个
      `if gap > 0: stalls += 1` 的实现能让 A1 全绿、同时把每个正常世界
      都标成停帧 —— 那种判据比没有更糟（它会把真问题淹没在噪声里）。
    """
    hub = Hub()
    hub.stall_threshold = 0.2
    hub.beat = time.perf_counter()
    stop = threading.Event()

    def beat_forever():
        while not stop.is_set():
            hub.beat = time.perf_counter()
            time.sleep(0.02)

    bt = threading.Thread(target=beat_forever, daemon=True)
    bt.start()
    try:
        _run_wd(hub, 0.6)
    finally:
        stop.set()
        bt.join(2.0)
    if hub.stalls != 0:
        return False, "心跳正常却记了 %d 次停帧（判据在乱响）" % hub.stalls
    return True, "0 次（心跳 20 ms 一拍、看门狗 50 ms 一查）"


def a3_dedup():
    """一次停帧只记 1 次：0.6 s 里轮询 12 次，不许变成 12 次。"""
    hub = Hub()
    hub.stall_threshold = 0.2
    hub.beat = time.perf_counter() - 1.0
    _run_wd(hub, 0.6)                        # check_sec=0.05 ⇒ 约 12 次检查
    if hub.stalls != 1:
        return False, "0.6 s 内记了 %d 次（去重失效，次数会灌水）" % hub.stalls
    return True, "12 次检查 → 只记 1 次"


def a4_below_threshold():
    """gap **小于**阈值 ⇒ 不记（阈值真的被当阈值用）。"""
    hub = Hub()
    hub.stall_threshold = 0.5
    hub.beat = time.perf_counter() - 0.1
    # 跑 0.25 s：gap 最多长到 0.35 s，始终 < 0.5
    _run_wd(hub, 0.25)
    if hub.stalls != 0:
        return False, "gap<阈值却记了 %d 次（阈值没用）" % hub.stalls
    return True, "gap≈0.35s < 0.5s → 0 次"


check("A1 停帧 ⇒ 计数 +1（gap 入档）", a1_stall_counts)
check("A2 心跳正常 ⇒ 一次都不许记（对照）", a2_alive_no_alarm)
check("A3 一次停帧只记 1 次（不灌水）", a3_dedup)
check("A4 gap 小于阈值 ⇒ 不记", a4_below_threshold)


# =============================================================================
# B. 集成级：真服务端
# =============================================================================
print()
print("═" * 78)
print("  B. 集成级：真起服务端，用 /debug/stall 造一次停帧")
print("═" * 78)


def port_busy(p):
    s = socket.socket()
    s.settimeout(1.0)
    try:
        return s.connect_ex(("127.0.0.1", p)) == 0
    finally:
        s.close()


def http_get(port, path, timeout=6):
    """返回 (status, body_text)。404/500 不抛异常 —— 反向测试要用状态码。"""
    import urllib.error
    import urllib.request
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path), timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.read().decode("utf-8", "replace")
        except Exception:                                        # noqa: BLE001
            return e.code, ""
    except Exception as e:                                       # noqa: BLE001
        return -1, "%s: %s" % (type(e).__name__, e)


def health(port):
    st, body = http_get(port, "/healthz")
    if st != 200:
        raise RuntimeError("/healthz 返回 %s: %s" % (st, body[:200]))
    return json.loads(body)


def start_server(port, allow_debug, stall_sec, logname, script=None):
    env = dict(os.environ)
    env["RT_STALL_SEC"] = str(stall_sec)
    env.pop("RT_SPAWN", None)
    argv = [sys.executable, "-u", script or os.path.join(RT, "server.py"),
            "--port", str(port), "--hz", "30", "--world-content", "6", "--quiet"]
    if allow_debug:
        argv.append("--allow-debug")
    lf = open(os.path.join(HERE, logname), "w", encoding="utf-8")
    proc = subprocess.Popen(argv, stdout=lf, stderr=subprocess.STDOUT, cwd=RT, env=env)
    for _ in range(400):
        if proc.poll() is not None:
            raise RuntimeError("服务端启动即退出（见 tests/%s）" % logname)
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return proc
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("服务端 40 s 内未监听")


def stop_server(proc):
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=8)
    except Exception:                                            # noqa: BLE001
        proc.kill()


# 端口守卫：占用了就直接失败（不要静默换成别的端口 —— 那会让「上一次的残留」
# 混进这一次的判据里，正是本工程吃过的那种亏）。
for _p in (PORT_DEBUG, PORT_CTRL):
    if port_busy(_p):
        print("  ✘ 端口 %d 已被占用 —— 先清掉再跑（netstat -ano | findstr :%d）" % (_p, _p))
        sys.exit(1)

srv_dbg = srv_ctrl = None
STATE = {}


def b0_boot():
    global srv_dbg, srv_ctrl
    t0 = time.perf_counter()
    srv_dbg = start_server(PORT_DEBUG, True, STALL_SEC, "_stall_server.log")
    t1 = time.perf_counter()
    h = health(PORT_DEBUG)
    st = h.get("stats") or {}
    STATE["tick0"] = st.get("tick")
    return True, "调试服 %d 起好（%.1fs）tick=%s" % (PORT_DEBUG, t1 - t0, STATE["tick0"])


def judge_baseline(port, expect_threshold):
    """★ B1 的判据本体（同样抽出来给 C 组用 —— 见 judge_after_trigger 的说明）。"""
    h = health(port)
    st = h.get("stats") or {}
    if st.get("stalls") != 0:
        return False, "刚起服就 stalls=%r" % (st.get("stalls"),)
    if abs(float(st.get("stall_threshold") or -1) - expect_threshold) > 1e-6:
        return False, "stall_threshold=%r ≠ RT_STALL_SEC=%s（阈值没接线？）" % (
            st.get("stall_threshold"), expect_threshold)
    age = st.get("stall_age")
    if not isinstance(age, (int, float)) or age > 1.0:
        return False, "stall_age=%r（>1 s 说明心跳根本没在推进）" % (age,)
    if st.get("last_stall") is not None:
        return False, "last_stall 应为 None，实际 %r" % (st.get("last_stall"),)
    return True, "stalls=0 threshold=%.1f stall_age=%.3fs last_stall=None" % (
        st["stall_threshold"], age)


def b1_baseline():
    """基线：还没停过帧；阈值 == 环境变量给的；心跳在推进。"""
    return judge_baseline(PORT_DEBUG, STALL_SEC)


def b2_trigger():
    """`/debug/stall?ms=N` ⇒ 200 且回 queued。"""
    t0 = time.perf_counter()
    st, body = http_get(PORT_DEBUG, "/debug/stall?ms=%d" % STALL_MS)
    if st != 200:
        return False, "期望 200，实际 %s: %s" % (st, body[:120].replace("\n", " "))
    if "queued" not in body:
        return False, "回话里没有 queued: %r" % body[:120]
    STATE["t_trigger"] = t0
    return True, "200 queued（%d ms）" % STALL_MS


def judge_after_trigger(port, t_trig, stall_ms):
    """★ B3 的判据本体（抽成函数，**C 组变异测试直接调同一份**）。

    ★ 为什么必须抽出来：如果 C 组另写一遍「差不多」的判断，那么 C 组证明的是
      「另一份判据会红」，而不是「B3 这条判据会红」—— 本工程已经栽过这种
      「判据双份、一起过期」的坑（C9 就是两处同源副本）。
    """
    deadline = t_trig + stall_ms / 1000.0 + 3.0
    seen = None
    while time.perf_counter() < deadline:
        st = (health(port).get("stats") or {})
        if (st.get("stalls") or 0) >= 1:
            seen = (st, time.perf_counter() - t_trig)
            break
        time.sleep(0.08)
    if seen is None:
        return False, "%.1f s 内 stalls 一直是 0（看门狗没响）" % (
            time.perf_counter() - t_trig)
    st, dt = seen
    age = st.get("stall_age")
    ls = st.get("last_stall") or {}
    trace = (ls.get("trace") or "")
    if not isinstance(age, (int, float)) or age <= st["stall_threshold"]:
        return False, ("发现时 stall_age=%.2fs 已 ≤ 阈值 %.1fs —— 这说明检查是"
                       "**停帧结束后**才跑的（看门狗没在独立线程里）"
                       % (age if isinstance(age, (int, float)) else -1, st["stall_threshold"]))
    if len(trace.strip()) == 0:
        return False, "last_stall.trace 是空的 —— 计数了但没抓住现场"
    if "server.py" not in trace:
        return False, "栈里看不到 server.py（抓错线程了？）:\n%s" % trace[:400]
    if "sleep" not in trace and "sim_loop" not in trace:
        return False, "栈里既没有 sleep 也没有 sim_loop —— 抓到的可能不是模拟线程:\n%s" % trace[:400]
    return True, "停帧 %.1fs 后就被记下（age=%.2fs > %.1fs），栈 %d 字节" % (
        dt, age, st["stall_threshold"], len(trace))


def b3_detected_while_stalled():
    """★★★ 停帧**进行中**就必须被记下来，且栈要抓住。

    ★ 这里所有时间都用 `perf_counter()`，**不能**和 `time.time()` 混用。
      第一版就是混了：B2 存的是 `perf_counter()`（进程内的短秒数），B3 却拿
      `time.time()`（纪元秒，1.79e9）去比 ⇒ `deadline` 落在过去，轮询循环
      **一次都没进**，然后输出了「1792250211.2 s 内一直是 0」这种荒谬数字。
      ⇒ 教训：判据里的时间基准必须**单一**；混用不会报错，只会给出看起来很
        像结论的错结论（本工程的老母题：判据输入不能自己污染自己）。
    """
    t_trig = STATE.get("t_trigger")
    if t_trig is None:
        return False, "B2 没成功，无法判"
    return judge_after_trigger(PORT_DEBUG, t_trig, STALL_MS)


def b4_recovered():
    """恢复：`stall_age` 掉回 < 0.5，且世界继续往前走（没卡死、也没追帧）。"""
    deadline = time.time() + 12.0
    age = None
    while time.time() < deadline:
        st = (health(PORT_DEBUG).get("stats") or {})
        age = st.get("stall_age")
        if isinstance(age, (int, float)) and age < 0.5:
            break
        time.sleep(0.1)
    if not isinstance(age, (int, float)) or age >= 0.5:
        return False, "12 s 内 stall_age 没掉回来（最后一次 %r）" % (age,)
    t1 = (health(PORT_DEBUG).get("stats") or {}).get("tick")
    time.sleep(0.6)
    t2 = (health(PORT_DEBUG).get("stats") or {}).get("tick")
    if not (isinstance(t1, int) and isinstance(t2, int) and t2 - t1 >= 5):
        return False, "0.6 s 内 tick 只走了 %r → %r（世界没在前进）" % (t1, t2)
    return True, "stall_age=%.3fs，0.6 s 内 tick +%d" % (age, t2 - t1)


def b5_no_flood():
    """恢复后再等 1 s：`stalls` 必须还是 1（一次停帧 = 一笔账）。"""
    time.sleep(1.0)
    st = (health(PORT_DEBUG).get("stats") or {})
    if (st.get("stalls") or 0) != 1:
        return False, "期望 1，实际 %r（同一次停帧被反复记账）" % (st.get("stalls"),)
    return True, "stalls=1（停帧 4 s + 恢复 1 s 后仍是 1）"


def b6_control_404():
    """★ 反向：不带 `--allow-debug` 的服务端，`/debug/stall` 必须 404；
    且它的 `stall_threshold` 必须等于**它自己**的 RT_STALL_SEC（不同值）。"""
    global srv_ctrl
    srv_ctrl = start_server(PORT_CTRL, False, CTRL_STALL_SEC, "_stall_ctrl.log")
    st, body = http_get(PORT_CTRL, "/debug/stall?ms=1000")
    if st != 404:
        return False, "没有 --allow-debug 却回了 %s（调试口裸奔了）: %s" % (
            st, body[:120].replace("\n", " "))
    if "disabled" not in body:
        return False, "404 了但没说明原因: %r" % body[:120]
    h = health(PORT_CTRL)
    th = (h.get("stats") or {}).get("stall_threshold")
    if abs(float(th or -1) - CTRL_STALL_SEC) > 1e-6:
        return False, "对照服 stall_threshold=%r ≠ %s（阈值是写死的常量？）" % (th, CTRL_STALL_SEC)
    # 再确认：它**没有**被那次调用停住（stalls 仍 0、世界在走）
    time.sleep(0.5)
    st2 = (health(PORT_CTRL).get("stats") or {})
    if (st2.get("stalls") or 0) != 0:
        return False, "对照服 stalls=%r（明明 404 了却记了停帧）" % (st2.get("stalls"),)
    return True, "404 disabled；threshold=%.1f≠%.1f（各服各值）；stalls=0" % (
        th, STALL_SEC)


# =============================================================================
# C. 变异测试：把实现改坏，确认 B 组的判据**真的会红**
# =============================================================================
# ★ 为什么 C 组不是可选项：
#   B 组全绿只证明「现在的实现让判据通过了」，**证明不了判据有牙**。
#   本工程在「裁判自己也会瞎」上栽过多次（判据输入包含被判定对象、
#   两处一起过期 ⇒ 一致性判据恒绿）。所以必须把实现改坏，看判据会不会红 ——
#   而且用的是 `judge_after_trigger` / `judge_baseline` **同一份代码**，
#   不是另写一份「差不多」的判断。
print()
print("═" * 78)
print("  C. 变异测试：摘掉看门狗线程 / 把阈值写死 —— B 组判据必须红")
print("═" * 78)

PORT_MUT = int(os.environ.get("RT_STALL_MUT_PORT", "8803"))
MUTANTS = []


def make_mutant(tag, edits):
    """把 `rt/server.py` 复制一份并做定点篡改。

    锚点必须**恰好命中 1 次**，否则报错（不许静默跳过 —— 锚点过期了就没人守这条判据了）。

    ★★ 换行符必须**跟着文件走**，不能假设 LF：
      `rt/server.py` 是 **CRLF**（本工程 06/07 两个工程混用两种换行，`mech.lua`、
      `host/01_core.lua`、`server.py` 都是 CRLF）。第一版锚点写成 `\\n` 拼接，
      在 CRLF 文件里 `count == 0`，变异器直接抛错。
      ⇒ 这里把锚点里的 `\\n` 统一翻译成文件自己的 EOL，再逐条核 `count == 1`。
      （教训与 `.lua` 那次编译失败同源：改文本前先量它到底是什么字节。）
    """
    path = os.path.join(RT, "server.py")
    with open(path, "r", encoding="utf-8", newline="") as f:
        src = f.read()
    eol = "\r\n" if "\r\n" in src else "\n"
    for old, new in edits:
        old = old.replace("\r\n", "\n").replace("\n", eol)
        new = new.replace("\r\n", "\n").replace("\n", eol)
        n = src.count(old)
        if n != 1:
            raise RuntimeError("变异锚点命中 %d 次（要求恰好 1 次，文件 EOL=%r）：%r"
                               % (n, eol, old[:70]))
        src = src.replace(old, new, 1)
    out = os.path.join(RT, "_mutant_%s.py" % tag)
    with open(out, "w", encoding="utf-8", newline="") as f:
        f.write(src)
    MUTANTS.append(out)
    return out


def cleanup_mutants():
    for p in MUTANTS:
        try:
            os.remove(p)
        except OSError:
            pass


MUT_NOWD = None
MUT_THRESHOLD = None


def c0_build_mutants():
    global MUT_NOWD, MUT_THRESHOLD
    # ① 看门狗**不启动**（模拟「写进了 sim_loop 所以跟着一起停」的等价后果）
    MUT_NOWD = make_mutant("nowd", [
        ("    wd = threading.Thread(target=watchdog_loop, args=(hub, stop), daemon=True)\n"
         "    wd.start()\n",
         "    wd = None          # ★ 变异：看门狗不启动\n"),
    ])
    # ② 阈值写死（忽略环境变量）
    MUT_THRESHOLD = make_mutant("threshold", [
        ('        self.stall_threshold = float(os.environ.get("RT_STALL_SEC", "3.0"))',
         '        self.stall_threshold = 3.0     # ★ 变异：阈值写死'),
    ])
    return True, "两个变异体已生成（锚点各命中 1 次）"


def c1_no_watchdog_goes_red():
    """★★★ 摘掉看门狗 ⇒ **B3 的判据必须红**（这就是「有牙」的证据）。"""
    proc = start_server(PORT_MUT, True, STALL_SEC, "_stall_mut_nowd.log", script=MUT_NOWD)
    try:
        h = health(PORT_MUT)
        st = h.get("stats") or {}
        if "stalls" not in st:
            return False, "/healthz 里没有 stalls 字段（接口都变了，红的原因不可信）"
        t0 = time.perf_counter()
        code, body = http_get(PORT_MUT, "/debug/stall?ms=%d" % STALL_MS)
        if code != 200:
            return False, "变异体连 /debug/stall 都不通（%s）" % code
        ok, info = judge_after_trigger(PORT_MUT, t0, STALL_MS)
        if ok:
            return False, ("★★ 摘掉看门狗之后 B3 仍然通过（%s）—— "
                           "说明这条判据是空的，抓不住「没人看」这件事" % info)
        # 「红」必须是**因为没人看**，不能是因为服务端坏了：/healthz 仍要 200
        st2 = health(PORT_MUT).get("stats") or {}
        if "stalls" not in st2 or st2.get("stalls") not in (0, None):
            return False, "变异体状态异常，红的原因不可信：%r" % (st2.get("stalls"),)
        return True, "判据如预期变红：%s" % info
    finally:
        stop_server(proc)
        time.sleep(0.4)


def c2_mutant_world_still_alive():
    """★ 「红」必须归因于**没人看**，不是世界坏了。

    同一个变异体再起一次：停帧结束后世界要照常恢复（stall_age 回正、tick 前进）
    —— 它只是「没人记账」，不是「循环永久卡死」。

    ★★ 顺序不能省：必须先**等到确实在停**（age > 阈值），再等恢复，最后才量 tick。
      第一版是「触发后立刻等 age < 0.5」—— 而那一刻停帧还没轮到（命令在队列里），
      age 本来就 < 0.5 ⇒ 判据在**还没停**的时候就宣布「已恢复」，接着 t1/t2 的
      0.6 s 窗口正好被随后到来的 1.5 s 停帧盖住，tick 当然是 0 → 0。
      症状长得像「变异体坏了」，其实是**判据自己在抢跑**。
      （本工程的老母题：判据的观测窗口与被观测事件必须对上时序。）
    """
    proc = start_server(PORT_MUT, True, STALL_SEC, "_stall_mut_nowd2.log", script=MUT_NOWD)
    try:
        code, body = http_get(PORT_MUT, "/debug/stall?ms=2500")
        if code != 200:
            return False, "变异体 /debug/stall 不通（%s: %s）" % (code, body[:80])
        # ① 先看到「真的停住了」（age 是现算的，不依赖看门狗，所以变异体上也成立）
        deadline = time.perf_counter() + 8.0
        stalled = False
        while time.perf_counter() < deadline:
            age = (health(PORT_MUT).get("stats") or {}).get("stall_age")
            if isinstance(age, (int, float)) and age > STALL_SEC:
                stalled = True
                break
            time.sleep(0.08)
        if not stalled:
            return False, "8 s 内没观测到停帧本身（age 从未超过 %.1fs）" % STALL_SEC
        # ② 再等恢复
        deadline = time.perf_counter() + 12.0
        age = None
        while time.perf_counter() < deadline:
            age = (health(PORT_MUT).get("stats") or {}).get("stall_age")
            if isinstance(age, (int, float)) and age < 0.5:
                break
            time.sleep(0.1)
        if not isinstance(age, (int, float)) or age >= 0.5:
            return False, "停帧后没恢复（age=%r）—— 那不是变异体，是坏了" % (age,)
        # ③ 最后量 tick（此时停帧已经过去，窗口里不会再被盖住）
        t1 = (health(PORT_MUT).get("stats") or {}).get("tick")
        time.sleep(0.6)
        t2 = (health(PORT_MUT).get("stats") or {}).get("tick")
        if not (isinstance(t1, int) and isinstance(t2, int) and t2 - t1 >= 5):
            return False, "恢复后 tick 不走（%r → %r）" % (t1, t2)
        return True, "停过 → 恢复（age=%.3fs）→ tick +%d ⇒ 红确实来自「没人看」" % (
            age, t2 - t1)
    finally:
        stop_server(proc)
        time.sleep(0.4)


def c3_hardcoded_threshold_goes_red():
    """★★ 阈值写死 ⇒ **B1 的判据必须红**（证明「阈值接线」不是摆设）。"""
    proc = start_server(PORT_MUT, True, STALL_SEC, "_stall_mut_thr.log", script=MUT_THRESHOLD)
    try:
        ok, info = judge_baseline(PORT_MUT, STALL_SEC)
        if ok:
            return False, ("阈值被写死成 3.0，而 B1 拿 RT_STALL_SEC=%s 去对，居然通过了 —— "
                           "说明那条判据没在核对阈值" % STALL_SEC)
        return True, "判据如预期变红：%s" % info
    finally:
        stop_server(proc)
        time.sleep(0.4)


try:
    ok_boot = check("B0 起调试服务端（--allow-debug）", b0_boot)
    if not ok_boot:
        print("  ✘ 服务端起不来，B 组其余判据无法执行")
        FAIL += 5
    else:
        check("B1 基线：stalls=0 / 阈值接线 / 心跳在走", b1_baseline)
        check("B2 /debug/stall?ms=%d 入队" % STALL_MS, b2_trigger)
        check("B3 ★ 停帧进行中就被记下 + 抓到栈", b3_detected_while_stalled)
        check("B4 恢复：心跳回正、世界继续前进", b4_recovered)
        check("B5 一次停帧只记 1 笔（不灌水）", b5_no_flood)
        check("B6 ★ 反向：无 --allow-debug ⇒ 404 + 阈值各服各值", b6_control_404)

    check("C0 生成两个变异体（锚点唯一）", c0_build_mutants)
    if MUT_NOWD:
        check("C1 ★ 摘掉看门狗 ⇒ B3 判据变红", c1_no_watchdog_goes_red)
        check("C2 ★ 变异体的世界照常恢复（红≠崩）", c2_mutant_world_still_alive)
    if MUT_THRESHOLD:
        check("C3 ★ 阈值写死 ⇒ B1 判据变红", c3_hardcoded_threshold_goes_red)
finally:
    stop_server(srv_dbg)
    stop_server(srv_ctrl)
    cleanup_mutants()
    time.sleep(0.4)
    for _p in (PORT_DEBUG, PORT_CTRL, PORT_MUT):
        if port_busy(_p):
            print("  ⚠️ 端口 %d 停服后仍被占用（可能有残留进程）" % _p)

print()
print("═" * 78)
print("  结果：通过 %d · 失败 %d" % (PASS, FAIL))
print("═" * 78)
if FAIL:
    print("  日志：tests/_stall_server.log（调试服）· tests/_stall_ctrl.log（对照服）")

# ★ 声明值自校验（见文件头 EXPECT_ITEMS 的说明）：少一条/多一条都必须红，
#   否则 README 的「合计 N 项」会悄悄变成假数。
_DONE = PASS + FAIL
if _DONE != EXPECT_ITEMS:
    print("  ✘ 断言条数与声明不符：声明 %d 条，实跑 %d 条"
          "（增删断言后请同步本文件的 EXPECT_ITEMS）" % (EXPECT_ITEMS, _DONE))
    sys.exit(1)

sys.exit(0 if FAIL == 0 else 1)
