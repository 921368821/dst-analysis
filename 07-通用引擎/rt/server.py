# -*- coding: utf-8 -*-
"""server.py —— 实时引擎服务端（入口与路由）

职责（对应开发计划 §2 的 M1/M2/M3）
    M1 权威模拟：唯一一个 lupa LuaRuntime，固定步长推进（默认 30 Hz）
    M2 输入：客户端 WS 消息 → 输入队列 → 每次 step 前一次性应用
    M3 传输：每帧把快照编成 JSON，广播给所有客户端

★ M4（2026-10-19）：本文件从 2440 行拆成 7 个模块，**只搬代码不改逻辑**
    ┌ config.py    路径与同目录依赖（唯一落点）
    ├ sim.py       Sim：权威模拟（独占 LuaRuntime）
    ├ hub.py       Hub + 统计缓存（跨线程唯一交汇点）
    ├ loops.py     sim_loop + watchdog_loop
    ├ net.py       来源校验 / query 解析 / ThreadedServer
    ├ http_api.py  HttpMixin：静态文件 / healthz / status / 控制端点 / 图集
    ├ ws_api.py    WsMixin：握手 / 帧循环 / 发送 / 单帧分派
    └ server.py    ← 本文件：按 Upgrade 头分流 + require_sources + main
    拆分判据：每个文件 < 800 行；`python -m pyflakes rt/*.py` 无未定义名；
    `tests/test_rt.py` 全绿（拆之前/之后各跑一次，结果必须一致）。

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

兼容性：`tests/` 里有 `from server import Sim` / `from server import Hub, watchdog_loop`
    —— 拆分后这些名字由本文件**转出**（见下面的 import），测试不用改。
"""
import argparse
import io
import json
import os
import signal
import socket
import socketserver
import sys
import threading
import time

from config import HERE, ENGINE, require_sources, ws
from hub import Hub, _stats_from_cache
from http_api import HttpMixin
from loops import sim_loop, watchdog_loop
from net import ThreadedServer, _origin_host, port_in_use
from sim import Sim
from ws_api import WsMixin

__all__ = ["Sim", "Hub", "sim_loop", "watchdog_loop", "Handler", "ThreadedServer",
           "port_in_use", "require_sources", "main"]


# =============================================================================
# 传输层：HTTP 与 WebSocket 同端口（按 Upgrade 头分流）
# =============================================================================
class Handler(HttpMixin, WsMixin, socketserver.BaseRequestHandler):
    # M4：方法体分散在 http_api.py / ws_api.py，这里只留类属性与**分流**。

    hub = None
    slot = 0          # ★ P20：WS 连接会覆盖它；HTTP 连接保持 0
    sim_stats = None
    sim_terrain = None
    static_dir = None
    allow_debug = False        # ★ 默认关闭：`--allow-debug` 才开（见 /debug/kill）
    control_token = None       # ★ M5：控制端点 token（`--control-token` / RT_CONTROL_TOKEN）

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

            # ★★ C3c（2026-10-22）：**读请求体**（POST）。
            #   在这之前服务端只认 GET，于是"导入场景"只能把整份文本塞进 URL query ——
            #   20 个实体约 400 字符没问题，但上百个实体会撞 URL 长度上限
            #   （实测 IE/Chrome 约 2 KB 起就不稳），而那时**报错是一句 414/400**，
            #   与"场景有坏行"完全分不清。
            #   上限 256 KB：场景文本是纯文本，几百个实体也就几十 KB；
            #   给足余量但不给无限（一个请求吃光内存是另一种事故）。
            req_body = b""
            if method in ("POST", "PUT"):
                try:
                    clen = int(headers.get("content-length") or 0)
                except (TypeError, ValueError):
                    clen = 0
                if clen < 0 or clen > 262144:
                    body = json.dumps({"ok": False,
                                       "error": "请求体过大（%d 字节，上限 262144）" % clen},
                                      ensure_ascii=False).encode("utf-8")
                    self._reply(b"HTTP/1.1 413 Payload Too Large\r\n"
                                b"Content-Type: application/json; charset=utf-8\r\n"
                                b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                    return
                head_end = raw.find(b"\r\n\r\n") + 4
                req_body = raw[head_end:]
                # 可能已经读进来一部分（与头部同一个 recv），只补剩下的
                body_deadline = time.time() + 5
                while len(req_body) < clen and time.time() < body_deadline:
                    try:
                        chunk = self.request.recv(min(65536, clen - len(req_body)))
                    except socket.timeout:
                        continue
                    if not chunk:
                        break
                    req_body += chunk
                req_body = req_body[:clen]

            # ★★★ M5：**来源校验**（HTTP 与 WS 共用，放在分派之前）。
            #   威胁模型：任意网页都能对 `http://127.0.0.1:8765/...` 发起请求
            #   （`<img>` / `<script>` / form / WebSocket），浏览器**会**带 Origin 或 Referer。
            #   本服务只有一个「同源客户端」，所以判定极简：
            #     来源的 host:port 必须等于请求的 Host —— 不等就是 403。
            #   · 不带来源头（curl / 部署脚本 / 同源 fetch 的某些情形）⇒ 放行，
            #     否则所有命令行工具都要跟着改（`/save` 就是 `stop.sh` 在调）。
            #   · `Origin: null`（file:// / sandbox iframe）⇒ 视为跨源，**拒绝**。
            #   ★ WS 也必须查：WebSocket **不受同源策略限制**，不查 Origin 等于没门。
            _src = headers.get("origin") or headers.get("referer") or ""
            if _src and _origin_host(_src) != (headers.get("host") or "").lower():
                body = json.dumps({"ok": False, "error": "跨源请求被拒绝（来源 %s）" % _src},
                                  ensure_ascii=False).encode("utf-8")
                self._reply(b"HTTP/1.1 403 Forbidden\r\n"
                            b"Content-Type: application/json; charset=utf-8\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return

            if headers.get("upgrade", "").lower() == "websocket":
                self._serve_ws(headers, path)
            else:
                self._serve_http(method, path, headers, req_body)
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


# =============================================================================
# 入口
# =============================================================================
def main():
    require_sources()
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--hz", type=int, default=30)
    ap.add_argument("--seed", type=int, default=20261015)
    ap.add_argument("--max-ents", type=int, default=400)
    ap.add_argument("--control-token", default=os.environ.get("RT_CONTROL_TOKEN"),
                    help="控制端点（/pause /save /respawn /light）要求的 token；"
                         "不填则不校验（默认只监听 127.0.0.1）")
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
        if getattr(sim, "replay_note", None):
            print("[replay] ⚠ %s" % sim.replay_note)
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
    Handler.control_token = a.control_token or None   # ★ M5：控制端点 token（默认不启用）

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
