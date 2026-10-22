# -*- coding: utf-8 -*-
"""http_api.py —— HTTP 端点（M4 从 server.py 拆出）

★ 为什么是 Mixin 而不是普通函数
    这些方法全部依赖 self.request / self.server / self.hub（BaseRequestHandler
    给的上下文），改成自由函数就得把 6 个字段打包传参 —— 那是改行为，不是拆文件。
    Mixin 让「搬代码」做到零语义变化：方法体一个字符都不动，
    只是从 server.py 的类体挪到这里。Handler 继承顺序 (HttpMixin, WsMixin, Base)。

★ 拆分只搬代码，不改逻辑。
"""
import json
import os
import threading

from config import ATLAS_JSON_DIR, ATLAS_PNG_DIR, SELF_ATLAS_DIR
from hub import _slots_html
from net import CONTROL_PATHS, _query_get, path_inside

__all__ = ["HttpMixin", "STATUS_HTML"]

# /status 页面模板（{{SLOTS}} 由 _slots_html 填）
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

class HttpMixin:
    # HTTP 侧方法集合：静态文件 / healthz / status / 控制端点 / 图集。


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
            # ★ 用 path_inside 而不是 startswith：同前缀的兄弟目录（…/json_x）不是「在里」
            if path_inside(base, cand) and os.path.isfile(cand):
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

    def _editor_allowed(self) -> bool:
        """★ P62：编辑器端点（`/editor/*`）的门槛 —— **本次请求来自回环**。

        为什么不复用 `_debug_allowed`：
          `/debug/*` 是**运维**通道：默认关、要 `--allow-debug`、发布检查单里明写
          「公网部署别开」。编辑器是**本机开发工具**，诉求正相反：打开就要能用。
          共用一个开关，等于让「想做编辑器」和「不想开运维口子」互相绑死。

        为什么看来源地址而不是启动参数：
          来源地址是**每个请求的事实**，启动参数是**启动时的意图**。
          绑了 `0.0.0.0` 时前者依然正确 —— 外网请求的 peer 不是回环，编辑器自动失效，
          而本机开发者不用改任何参数。判据贴着它要拦的动作，不贴着配置。

        ⚠️ 这是**纵深防御的一层**，不是唯一一层：服务默认还只绑 127.0.0.1
          （`U45` 守着这条）。两层都失效才能碰到编辑器。
        """
        try:
            peer = str(self.client_address[0])
        except Exception:                                        # noqa: BLE001
            return False
        return peer in ("127.0.0.1", "::1", "::ffff:127.0.0.1", "localhost")

    # ---------- 静态文件 / healthz ----------
    def _serve_http(self, method, path, headers=None):
        headers = headers or {}
        # ★★ M5：控制端点的 **token 门**（可选，`--control-token` 才启用）。
        #   为什么做成可选：本服务默认只监听 127.0.0.1，部署脚本 `stop.sh` 会调 `/save`；
        #   强行要求 token 会让「本地起一个自己看」也变麻烦，从而被人一键关掉整道门。
        #   需要对外暴露时（反代/容器/公网）加 `--control-token XXX` 即可，
        #   也可以用同名环境变量 `RT_CONTROL_TOKEN` 注入。
        #   ★ 顺序：**先 token、后方法** —— 无 token 的 POST 必须是 401（不是 405），
        #     否则「方法对不对」会掩盖「你根本没被授权」。
        if path.split("?")[0] in CONTROL_PATHS:
            want = getattr(self, "control_token", None)
            if want:
                got = headers.get("x-api-token") or _query_get(path, "token") or ""
                if got != want:
                    body = json.dumps({"ok": False, "error": "缺少或错误的 control token"},
                                      ensure_ascii=False).encode("utf-8")
                    self._reply(b"HTTP/1.1 401 Unauthorized\r\n"
                                b"WWW-Authenticate: X-Api-Token\r\n"
                                b"Content-Type: application/json; charset=utf-8\r\n"
                                b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                    return
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
            # ★ P50⑳：统计项**一次取全**（同一个页面里不许出现两套数）。
            #   原来这里逐个字段读，读一半被改就会出现「发帧 1200 / 字节 0」那种
            #   自相矛盾的一页 —— 不一致的统计比没有更误导。
            hs = self.hub.stats_snapshot()
            body = STATUS_HTML.replace("{{TICK}}", str(st.get("tick", "?"))) \
                              .replace("{{TIME}}", "%.1f" % st.get("time", 0)) \
                              .replace("{{ENTS}}", str(st.get("n_ents", "?"))) \
                              .replace("{{CLIENTS}}", str(self.hub.clients)) \
                              .replace("{{PLAYERS}}", str(self.hub.player_count)) \
                              .replace("{{PLAYER}}", "在" if st.get("player_ok") else "缺") \
                              .replace("{{BADFRAMES}}", str(hs["dropped_bad_frames"])) \
                              .replace("{{SENT}}", str(hs["frames_sent"])) \
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
        # ★★ P62：编辑器通道 —— `/editor/entities|remove|move|spawn`
        #   门槛是**来源回环**（见 `_editor_allowed`），**不是** `--allow-debug`。
        #   全部走 hub.cmds 排队（要碰 Lua），并且**同步等回话**：
        #   编辑器要的是「改了没有 / 为什么没改」，不是「已入队」。
        #   `spawn` 复用 `/debug/spawn` 的同一条 Lua 路径，只是换了个门槛 ——
        #   同一能力不该有两份实现，否则两处会各自长歪。
        if path.split("?")[0].startswith("/editor/"):
            if not self._editor_allowed():
                try:
                    peer = str(self.client_address[0])
                except Exception:                                # noqa: BLE001
                    peer = "?"
                body = json.dumps({"ok": False, "error": "编辑器只接受本机（回环）请求",
                                   "peer": peer}, ensure_ascii=False).encode("utf-8")
                self._reply(b"HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                            b"\r\n" + body)
                return
            sub = path.split("?")[0]
            q = path.split("?", 1)[1] if "?" in path else ""
            arg = {}
            for kv in q.split("&"):
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    arg[k] = v

            def _enum(key, cast=float, default=None):
                v = arg.get(key)
                if v is None or v == "":
                    return default
                try:
                    return cast(v)
                except (TypeError, ValueError):
                    return default

            ev, box = threading.Event(), {}
            if sub == "/editor/entities":
                self.hub.cmds.put(("debug_entities", _enum("limit", int, 500), ev, box))
            elif sub == "/editor/remove":
                self.hub.cmds.put(("debug_remove", _enum("guid", int, -1), ev, box))
            elif sub == "/editor/move":
                self.hub.cmds.put(("debug_move", _enum("guid", int, -1),
                                   _enum("x"), _enum("z"), ev, box))
            elif sub == "/editor/spawn":
                self.hub.cmds.put(("debug_spawn", arg.get("prefab", ""),
                                   _enum("x"), _enum("z"), ev, box))
            elif sub == "/editor/recipes":
                # ★ B2：配方列表。**只给回环**（编辑器/本机工具），因为它会遍历全部
                #   1122 个配方并逐个查背包 —— 敞开给外网等于一个便宜的 DoS 入口。
                self.hub.cmds.put(("recipes", _enum("slot", int, 0),
                                   _enum("limit", int, 40), ev, box))
            elif sub == "/editor/craft":
                # ★ B1：合成/建造。与 spawn 的区别是它**不指定产物**，只给配方名，
                #   产物是什么、要不要落点、材料够不够，全由原版 `DoBuild` 决定。
                self.hub.cmds.put(("craft", _enum("slot", int, 0), arg.get("recipe", ""),
                                   _enum("x"), _enum("z"), ev, box))
            else:
                body = b"unknown editor endpoint\n"
                self._reply(b"HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return

            if not ev.wait(timeout=10):
                body = json.dumps({"ok": False, "error": "10 s 内没等到模拟线程（模拟循环卡住？）"},
                                  ensure_ascii=False).encode("utf-8")
                self._reply(b"HTTP/1.1 503 Service Unavailable\r\n"
                            b"Content-Type: application/json\r\n"
                            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return
            code = b"200 OK" if box.get("ok") else b"400 Bad Request"
            body = json.dumps(box, ensure_ascii=False).encode("utf-8")
            self._reply(b"HTTP/1.1 " + code + b"\r\nContent-Type: application/json\r\n"
                        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                        b"Cache-Control: no-store\r\n\r\n" + body)
            return

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
                        b"\r\n" + body)
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
                        b"\r\n" + body)
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
                        b"\r\n" + body)
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
                        b"\r\n" + body)
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
                        b"\r\n" + body)
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
            # ★ P50⑳：统计项走 `stats_snapshot()`（一次取全），不再逐字段读 ——
            #   否则「发帧 1200 / 字节 0」这种自相矛盾的一帧会被客户端当真。
            hs = self.hub.stats_snapshot()
            body = json.dumps({"ok": True, "stats": self.sim_stats(),
                               "world": w,
                               "paused": self.hub.is_paused(),
                               "clients": self.hub.clients,
                               "player_count": self.hub.player_count,
                               "dropped_bad_frames": hs["dropped_bad_frames"],
                               "frames_sent": hs["frames_sent"]},
                              ensure_ascii=False).encode("utf-8")
            self._reply(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                             b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                             b"\r\n" + body)
            return
        name = path.split("?")[0].lstrip("/") or "client.html"
        full = os.path.normpath(os.path.join(os.path.abspath(self.static_dir), name))
        # ★ 同前缀兄弟目录（rt2/…）与跨盘符都算「不在里面」；原来只比字符串前缀。
        if not path_inside(self.static_dir, full) or not os.path.isfile(full):
            self._reply(b"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found")
            return
        ctype = "text/html; charset=utf-8" if full.endswith(".html") else "application/octet-stream"
        with open(full, "rb") as f:
            data = f.read()
        self._reply(("HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n"
                          "Cache-Control: no-store\r\n\r\n" % (ctype, len(data))).encode() + data)
