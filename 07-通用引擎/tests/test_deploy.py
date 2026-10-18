# -*- coding: utf-8 -*-
"""test_deploy.py —— **发布演练**：走文档里的入口，端到端跑一遍。

★★ 为什么要有这个文件（与其他测试的区别）：
  `test_rt.py` / `test_stress.py` 都是**直接** `python rt/server.py` 起服务端 ——
  它们验的是**服务端本身**。而用户看到的入口是 `deploy/start.sh` / `deploy/stop.sh`，
  这两个脚本里有**自己的逻辑**（端口守卫、日志、启动后自检、按端口找 PID 停服）。
  「服务端没问题」≠「用户那条路没问题」—— 本工程已经在
  「检查写好了 ≠ 检查生效过」上栽过多次，这里同理：
  **脚本的判据（端口守卫、自检）从来不跑，就等于没有。**

判据（每一条要么过，要么把原因说清楚）：
  ① `bash deploy/start.sh <port> 30` 必须自己报「/healthz 通过」+「世界在走」；
  ② `/healthz` 的 stats 必须含 `boot` / `player_alive` / `player_health` / `respawns`
     / `grue_immune` —— 这些是**发布时要能看的东西**（模型版本、玩家还活着没、复活过几次）；
  ③ `/status` 页面必须含模型版本（模板加了行但漏了替换就会只剩 `?`）；
  ④ WS：连上 → `whoami` → 按右 → **位置真的变了**（端到端那条路还通）
     + 目标 + 施放：`targets` → `act` ⇒ `/healthz` 的 `act_ok` 必须增长；
  ⑤ `bash deploy/stop.sh <port>` 必须**真的把端口放掉**（`connect_ex` 失败），
     并且**先存后杀**（P37：硬杀前必须看到「已存档」那行 —— 见下）；
  ⑥ ★★ **会话身份挺过真重启**（P36 跨进程版）：带 key 连上→走一段→停服→重启→
     **同一个 key 拿回同一个角色**（位置接续）；反向：**不同 key** 拿到的是**另一个**
     实体，且原角色**没被顶掉**。
     ★ 为什么这条必须放在这里（而不是只在 `test_rt.py` 的 D4 里测）：
       D4 是**进程内** `try_load`（存档是我手动喂的）；而真实的用户路径是
       `stop.sh`（**硬杀**）+ `start.sh`（读回同一份存档）。
       「进程内成立」≠「用户那条路成立」—— 这两件事之间隔着：
         · `stop.sh` 会在杀之前请求 `/save`（P37），**这条路径不跑就没人知道它通不通**；
         · `start.sh` 传的是 `--save-file deploy/logs/world-<port>.json`（默认就有）；
         · 服务端启动时要把存档里的 key 灌进 `by_key`（`Hub.prime_keys`）。
       ⇒ 这条判据第一次跑起来就证明了「P36 在用户入口上真的成立」。
  ⚠️ 无论成败，最后都**尽力停掉**服务端（否则会漏一个进程占着端口）。

跑法：python tests/test_deploy.py        退出码 0 = 全过
环境变量：RT_DEPLOY_PORT（默认 8799）
"""
import json
import os
import socket
import struct
import subprocess
import sys
import time

# ★★ 连**本机**起的服务端**不该走代理**。
#   本工程在沙箱环境里实测踩到：环境注入了 `http_proxy`（本地转发型）而 `no_proxy` 为空，
#   于是 `urllib` 把 `http://127.0.0.1:<port>/...` 也发给了代理 —— 一旦服务端不在，
#   拿回来的不是「连接被拒」，而是 **502 Bad Gateway**（一个完全不指向真因的错误）。
#   这里显式绕开（只影响本进程，且只对 127.0.0.1/localhost），让失败信息指向真因。
os.environ["no_proxy"] = "127.0.0.1,localhost"
os.environ["NO_PROXY"] = "127.0.0.1,localhost"

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                  # 07-通用引擎
RT = os.path.join(ROOT, "rt")
sys.path.insert(0, RT)

import ws as wsmod                            # noqa: E402  （要先把 rt/ 放进 sys.path）

PORT = int(os.environ.get("RT_DEPLOY_PORT", "8799"))

PASS, FAIL = 0, 0


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
        print("  ✔ %-44s %s  (%.0f ms)" % (name, info, ms))
    else:
        FAIL += 1
        print("  ✘ %-44s %s  (%.0f ms)" % (name, info, ms))
    return ok


def port_busy(p=None):
    s = socket.socket()
    s.settimeout(1.0)
    try:
        return s.connect_ex(("127.0.0.1", p or PORT)) == 0
    finally:
        s.close()


def http_json(path):
    import urllib.request
    with urllib.request.urlopen("http://127.0.0.1:%d%s" % (PORT, path), timeout=5) as r:
        return json.loads(r.read().decode("utf-8"))


def http_text(path):
    import urllib.request
    with urllib.request.urlopen("http://127.0.0.1:%d%s" % (PORT, path), timeout=5) as r:
        return r.read().decode("utf-8")


def sh(cmd, timeout=90):
    p = subprocess.run(["bash"] + cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def stop_server():
    """停服（**尽力**：直接调 stop.sh，它就是被演练的对象之一）。"""
    try:
        rc, out = sh(["deploy/stop.sh", str(PORT)], timeout=90)
        return rc, out
    except Exception as e:                                        # noqa: BLE001
        return -1, "stop.sh 调用失败: %s" % e


# ---------- WS 辅助（提为模块级：④ 与 ⑥ 都要用，避免两处实现漂移）----------
def ws_open(key=None):
    """连上服务端；带 `key` 就是「会话身份」（协议：`/ws?key=xxx`）。"""
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=6)
    path = "/ws" + (("?key=" + key) if key else "")
    wsmod.client_handshake(sock, "127.0.0.1:%d" % PORT, path)
    return sock


def ws_recv(sock):
    def exact(n):
        buf = b""
        while len(buf) < n:
            c = sock.recv(n - len(buf))
            if not c:
                raise RuntimeError("连接关闭")
            buf += c
        return buf
    h = exact(2)
    ln = h[1] & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", exact(2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", exact(8))[0]
    return exact(ln) if ln else b""


def ws_send(sock, obj):
    sock.sendall(wsmod.encode_frame_masked(json.dumps(obj).encode("utf-8")))


def ws_whoami(sock, timeout=8.0):
    """反复问 `whoami` 直到拿到 `you`（模拟线程建角色有延迟），拿不到返回 None。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        ws_send(sock, {"cmd": "whoami"})
        for _ in range(20):
            try:
                m = json.loads(ws_recv(sock).decode("utf-8"))
            except Exception:                                    # noqa: BLE001
                continue
            if isinstance(m, dict) and m.get("you") is not None:
                return int(m["you"])
    return None


def ws_pos(sock, guid, consume=8):
    """读**排空后**的位置。
    ★★ `consume` 是必须的：直接读一条帧拿到的是**积压的旧帧**（本工程的老坑，
      在 `test_deploy` 里也栽过一次）——必须把队列排空再取最后一条。"""
    last = None
    for _ in range(consume):
        try:
            m = json.loads(ws_recv(sock).decode("utf-8"))
        except Exception:                                        # noqa: BLE001
            continue
        if isinstance(m, dict) and "ents" in m:
            for e in m["ents"]:
                if int(e["id"]) == guid:
                    last = (float(e["x"]), float(e["z"]))
    return last


def force_cleanup():
    """兜底：无论成败，确保端口空出来（否则会漏一个进程占着端口）。"""
    if not port_busy():
        return
    print("  ⚠️ 端口仍被占用，做最后清理（按端口找 PID）……")
    try:
        out = subprocess.run(["netstat", "-ano"], capture_output=True, text=True, timeout=30).stdout
        pids = set()
        for line in out.splitlines():
            if (":%d " % PORT) in line and "LISTENING" in line.upper():
                pids.add(line.split()[-1])
        for pid in pids:
            subprocess.run(["taskkill", "/F", "/PID", pid], capture_output=True, timeout=30)
        time.sleep(1.0)
    except Exception as e:                                        # noqa: BLE001
        print("    清理也失败了：%s" % e)
    print("    清理后端口占用 = %s" % port_busy())


print("═" * 74)
print("  发布演练（走 deploy/start.sh / deploy/stop.sh 这条**用户入口**）")
print("  端口 %d" % PORT)
print("═" * 74)

if port_busy():
    print("  ✘ 端口 %d 已被占用 —— 先停掉再演练：bash deploy/stop.sh %d" % (PORT, PORT))
    sys.exit(1)

# ★ 演练从**干净世界**开始：清掉上一次演练留下的存档。
#   为什么必须做：`start.sh` 默认 `--save-file deploy/logs/world-<port>.json`，读档会**恢复**
#   上一轮的世界（角色、位置、身份）；不清的话每次跑都在「上一轮的残留」上做判据，
#   存档越滚越大，而且 ⑦ 的「重启前位置」可能继承自更早的一轮 —— 判据就不再测它想测的东西。
SAVE = os.path.join(ROOT, "deploy", "logs", "world-%d.json" % PORT)
if os.path.exists(SAVE):
    os.remove(SAVE)
    print("  （已清掉上一次演练的存档：%s）" % os.path.relpath(SAVE, ROOT))

IDENT = {}          # 跨重启要记住的身份（key / guid / 位置）

try:
    # ① start.sh 自己必须报自检通过
    def t1_start():
        rc, out = sh(["deploy/start.sh", str(PORT), "30"], timeout=120)
        if rc != 0:
            return False, "start.sh 退出码 %d：\n%s" % (rc, out[-600:])
        if "/healthz 通过" not in out:
            return False, "start.sh 没报「/healthz 通过」：\n%s" % out[-400:]
        if "世界在走" not in out:
            return False, "start.sh 的自检只到「/healthz 通过」，没确认 **tick 在走**（起来了但卡住？）"
        return True, "start.sh 自检通过（端口守卫 → 起服务 → /healthz → tick 在走）"

    if not check("① start.sh 走通且自检通过", t1_start):
        raise SystemExit(1)

    # ② /healthz 必须带发布时要看的那几个字段
    def t2_health_fields():
        j = http_json("/healthz")
        st = j.get("stats", {})
        need = ("boot", "player_alive", "player_health", "respawns", "grue_immune")
        miss = [k for k in need if k not in st]
        if miss:
            return False, "stats 缺字段：%s" % miss
        if "world" not in j:
            return False, "/healthz 里没有 world 块"
        return True, "boot=%s alive=%s health=%s respawns=%s grue_immune=%s" % (
            st["boot"], st["player_alive"], st["player_health"], st["respawns"], st["grue_immune"])

    check("② /healthz 带模型版本 / 玩家存活 / 复活计数", t2_health_fields)

    # ②b HTTP 方法校验（P41 / T7）
    def t2b_method_guard():
        """★ 改之前 `method` 解析出来**从头到尾没人用**：`POST /healthz` 会照常 200，
        `DELETE /save` 甚至**真的去存档**。→ 现在非 GET 一律 405 + `Allow: GET`。"""
        import urllib.request
        import urllib.error

        def req(method, path, body=None):
            r = urllib.request.Request("http://127.0.0.1:%d%s" % (PORT, path),
                                       data=body, method=method)
            try:
                with urllib.request.urlopen(r, timeout=5) as resp:
                    return resp.status, dict(resp.headers), resp.read().decode("utf-8", "replace")
            except urllib.error.HTTPError as e:                   # noqa: PERF203
                return e.code, dict(e.headers or {}), e.read().decode("utf-8", "replace")

        # 反向：GET 必须仍然是 200（不能为了拦 POST 把正常路也拦了）
        code, _h, txt = req("GET", "/healthz")
        if code != 200 or '"stats"' not in txt:
            return False, "GET /healthz 返回 %s（应 200 且带 stats）" % code

        bad = []
        for m in ("POST", "PUT", "DELETE"):
            code, hdrs, txt = req(m, "/healthz", b"{}" if m in ("POST", "PUT") else None)
            if code != 405:
                bad.append("%s→%s" % (m, code))
                continue
            allow = ""
            for k, v in hdrs.items():
                if k.lower() == "allow":
                    allow = v.strip()
            if allow.upper() != "GET":
                bad.append("%s 的 Allow=%r（应 GET）" % (m, allow))
        if bad:
            return False, "方法校验不对：%s" % "；".join(bad)

        # ★ 更狠的一条：`POST /debug/kill` 在**没开 --allow-debug** 时也必须 405，
        #   而不是 404 —— 先问「方法对不对」，再问「端点开没开」。
        #   否则一条 `PUT /debug/kill` 就能绕过「默认关闭」的错觉（虽然现在也拦得住，
        #   但语义上应该由方法校验先说话）。
        code, _h, _t = req("POST", "/debug/kill?slot=0", b"")
        if code != 405:
            return False, "POST /debug/kill 返回 %s（应 405：方法先于端点判断）" % code

        return True, ("GET /healthz 仍 200 ✔ / POST·PUT·DELETE /healthz 全 405 且 Allow: GET ✔ / "
                      "POST /debug/kill 也是 405（方法校验先于端点开关）✔")

    check("②b HTTP 方法校验：非 GET 一律 405 + Allow: GET；反向：GET 仍 200", t2b_method_guard)

    # ③ /status 页面必须真的显示模型版本
    def t3_status():
        html = http_text("/status")
        st = http_json("/healthz")["stats"]
        if st["boot"] not in html:
            return False, "/status 页面上看不到模型版本 %s（模板加了行但漏了替换？）" % st["boot"]
        # ★ 新加的行也要**真的**显示（模板加了行、漏了 replace ⇒ 页面上会留着 {{ALIVE}} 这种占位符）
        for label, needle in (("玩家存活", "活着"), ("各玩家槽位", "槽0"),
                              ("复活次数", str(st.get("respawns"))),
                              ("光源", str(st.get("fires")))):
            if label not in html:
                return False, "/status 上没有「%s」这一行（运营看不到这个状态）" % label
            if needle not in html:
                return False, "/status 上「%s」那行的值是坏的（找不到 %r —— 占位符没被替换？）" % (label, needle)
        if "{{" in html:
            return False, "/status 里残留了没替换的占位符：%r" % html[html.index("{{"):html.index("{{") + 30]
        return True, "/status 显示模型版本 %s + 玩家存活/按槽位/复活/光源四行（%d 字节，无残留占位符）" % (
            st["boot"], len(html))

    check("③ /status 页面真的显示模型版本与新增的三行", t3_status)

    # ④ WS 端到端：连上 → whoami → 按右 → 位置真的变了（+ 目标与施放）
    def t4_walk():
        sock = ws_open()
        try:
            guid = ws_whoami(sock)
            if guid is None:
                return False, "8 s 没拿到 `you` 握手"
            p0 = ws_pos(sock, guid, consume=6)
            if p0 is None:
                return False, "帧里找不到自己（guid=%d）" % guid
            ws_send(sock, {"k": "right", "v": 1})
            time.sleep(1.5)
            ws_send(sock, {"k": "right", "v": 0})
            # ★ 排空积压（1.5 s ≈ 45 帧）后再取，才量的是**按右之后**的位置
            p1 = ws_pos(sock, guid, consume=90)
            if p1 is None:
                return False, "按右之后帧里找不到自己了"
            dx = p1[0] - p0[0]
            if dx < 0.5:
                return False, "按右 1.5 s 后 x 只动了 %.2f（端到端那条路断了）" % dx
            # 顺手在同一连接里做「目标 + 施放」
            a0 = http_json("/healthz")["stats"]["act_ok"]
            picked = None
            ws_send(sock, {"cmd": "targets"})
            for _ in range(90):
                try:
                    m = json.loads(ws_recv(sock).decode("utf-8"))
                except Exception:                                # noqa: BLE001
                    continue
                if isinstance(m, dict) and m.get("targets") is not None:
                    tg = m["targets"]
                    if tg:
                        picked = tg[0]
                    break
            if picked is None:
                # ★ 2026-10-16：**这里从「通过（附注）」改成了「失败」**。
                #   以前默认世界只有一个玩家 ⇒ 这条只能当作提示；现在默认世界有内容
                #   ⇒ 20 格内**必须**有东西可砍，否则就是「用户打开链接看到空世界」那个问题回来了。
                return False, ("按右位移 %.2f ✔，但 20 格内**一个可交互目标都没有** —— "
                               "默认世界又空了？见 E6 与 rt_boot.populate_world" % dx)
            ws_send(sock, {"cmd": "act", "v": int(picked["id"])})
            time.sleep(2.5)
            a1 = http_json("/healthz")["stats"]["act_ok"]
            if a1 <= a0:
                return False, "施放之后 act_ok 没涨（%s → %s）：目标 %s 没被受理" % (a0, a1, picked.get("p"))
            return True, "按右位移 %.2f ✔；目标 %s·%s 施放成功（act_ok %s → %s）" % (
                dx, picked.get("p"), picked.get("a"), a0, a1)
        finally:
            try:
                sock.close()
            except Exception:                                    # noqa: BLE001
                pass

    check("④ 端到端：whoami → 按右真的动了（+ 目标与施放）", t4_walk)

    # ---- ⑥ 的前半：带 key 连上、走一段、记下身份（供重启后认回）----
    def t5_capture_identity():
        # ★★ 为什么要**先开两个「占位连接」**，再让 K1 连上：
        #   如果 K1 恰好拿到「重启后新连接也会拿到的那个槽位号」（从 1 开始），
        #   那么即使**身份机制完全失效**，重启后 K1 也会被分到同一个槽位、
        #   于是**偶然**拿回同一个角色 —— 判据就分不清「靠身份认回」还是「槽位号巧合」。
        #   实测（变异测试）：把 `hub.prime_keys(...)` 改成 no-op（启动不灌身份 key）后
        #   ⑦ **依然全绿** —— 就是这个巧合。
        #   占住两个槽位之后，K1 拿的是**槽位 ≥2**，而重启后新连接默认从槽位 1 开始
        #   ⇒ 身份失效时位置对不上 ⇒ 变异会被抓住。
        holders, sock = [], None
        try:
            holders = [ws_open(), ws_open()]
            for h in holders:
                ws_whoami(h)                       # 等它们各自拿到自己的槽位
            sock = ws_open("DEPLOY-ID-K1")
            g = ws_whoami(sock)
            if g is None:
                return False, "带 key 连上后 8 s 没拿到 `you`"
            ws_send(sock, {"k": "right", "v": 1})
            time.sleep(1.5)
            ws_send(sock, {"k": "right", "v": 0})
            p = ws_pos(sock, g, consume=90)
            if p is None:
                return False, "带 key 连上后帧里找不到自己（guid=%d）" % g
            IDENT.update(key="DEPLOY-ID-K1", guid=g, pos=p)
            return True, "带 key=K1 连上（先占住两个槽位以避开「槽位号巧合」）→ guid=%d，走到 %s" % (g, p)
        finally:
            for s in holders + ([sock] if sock else []):
                try:
                    s.close()
                except Exception:                                # noqa: BLE001
                    pass

    check("⑤ 带会话 key 连上并记下身份（为重启后认回做准备）", t5_capture_identity)

    # 停服：必须真的把端口放掉**且先存后杀**
    def t6_stop():
        rc, out = stop_server()
        time.sleep(1.2)
        if "已存档" not in out:
            return False, ("stop.sh 里看不到「已存档」—— P37 的「先存后杀」没生效？"
                           "硬杀会丢掉最后 30 s（含刚记下的身份），⑥ 会因此变红。输出：\n%s"
                           % out[-300:])
        if port_busy():
            return False, ("stop.sh 返回 %d，**但端口 %d 仍被占用** ⇒ 服务端还在跑"
                           "（下一次启动会撞端口，而 Windows 允许双绑 ⇒ 静默脑裂）。输出：\n%s"
                           % (rc, PORT, out[-300:]))
        if rc != 0:
            return False, "stop.sh 退出码 %d（端口倒是空出来了）：\n%s" % (rc, out[-300:])
        return True, "先存档再停服；端口 %d 已空闲（stop.sh 退出码 0）" % PORT

    check("⑥ stop.sh 先存档、再把端口真的放掉", t6_stop)

    # ⑦ ★★ 会话身份挺过**真重启**（重启 → 同 key 认回同一角色；反向：不同 key 不抢角色）
    def t7_restart_reclaim():
        if not IDENT:
            return False, "没有记到身份（⑤ 没成功），无法验证重启后认领"
        # 再起一次（start.sh 默认带 --save-file deploy/logs/world-<port>.json，会读回同一份存档）
        rc, out = sh(["deploy/start.sh", str(PORT), "30"], timeout=120)
        if rc != 0:
            return False, "第二次 start.sh 退出码 %d：\n%s" % (rc, out[-600:])
        # 同 key 连上
        sock = ws_open(IDENT["key"])
        try:
            g2 = ws_whoami(sock)
            if g2 is None:
                return False, "重启后带同一个 key 连上，8 s 没拿到 `you`（身份没被灌进 by_key？）"
            p2 = ws_pos(sock, g2, consume=40)
            if p2 is None:
                return False, "重启后帧里找不到自己（guid=%d）" % g2
            d = ((p2[0] - IDENT["pos"][0]) ** 2 + (p2[1] - IDENT["pos"][1]) ** 2) ** 0.5
            if d > 0.6:
                return False, ("同 key 没拿回原来的位置：重启前 %s → 重启后 %s（差 %.2f 格）"
                               "—— 身份没落盘，或 stop.sh 硬杀把最后一段丢了"
                               % (IDENT["pos"], p2, d))
            # 反向：**不同 key** 必须拿到**另一个**实体，且原角色**没被顶掉**
            sock2 = ws_open("DEPLOY-ID-K2")
            try:
                g3 = ws_whoami(sock2)
                if g3 is None:
                    return False, "第二个 key 连上后 8 s 没拿到 `you`"
                if g3 == g2:
                    return False, "不同 key 拿到了**同一个**实体（%d）⇒ key 没起到身份作用" % g3
                p_old = ws_pos(sock, g2, consume=30)
                if p_old is None:
                    return False, "第二个 key 连上后，原角色（guid=%d）从帧里消失了（被顶掉了？）" % g2
            finally:
                try:
                    sock2.close()
                except Exception:                                # noqa: BLE001
                    pass
            return True, ("重启后同 key 认回同一角色：位置 %s → %s（差 %.3f 格）；"
                          "反向：不同 key 拿到另一个实体（%d≠%d）且原角色没被顶掉"
                          % (IDENT["pos"], p2, d, g3, g2))
        finally:
            try:
                sock.close()
            except Exception:                                    # noqa: BLE001
                pass

    check("⑦ 会话身份挺过真重启（同 key 认回角色；不同 key 不抢）", t7_restart_reclaim)

finally:
    # 兜底：无论上面成败，最后都尽力把服务端停掉、端口放空
    try:
        stop_server()
        time.sleep(1.0)
    except Exception:                                            # noqa: BLE001
        pass
    force_cleanup()

print("\n" + "─" * 74)
print("  结果：%d 通过 / %d 失败" % (PASS, FAIL))
print("─" * 74)
sys.exit(0 if FAIL == 0 else 1)
