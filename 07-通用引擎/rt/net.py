# -*- coding: utf-8 -*-
"""net.py —— 传输层公共件：来源校验、query 解析、监听套接字（M4 从 server.py 拆出）

为什么 HTTP 与 WebSocket 的公共件要独立成文件
    M5 的「来源 + token」两道门同时压在 HTTP 与 WS 上：
    _origin_host 在 handle()（决定是否 403）与 _serve_http（控制端点）两处用，
    query 解析在控制端点用。放在任何一个具体协议文件里，另一个都得反向依赖。

★ 拆分只搬代码，不改逻辑。
"""
import socketserver


# =============================================================================
# HTTP + WebSocket（同端口）
# =============================================================================

# ★ M5：有**副作用**的控制端点。它们与只读端点分两类：
#   只读（/status /healthz /terrain /atlas）：谁读都只是读；
#   控制（下面这四个）：能改世界（暂停/存档/复活/给光）。
#   任意网页用 `<img src="http://host:8765/respawn?slot=0">` 就能干扰对局 ——
#   所以这四个要有「来源 + token」两道门。
CONTROL_PATHS = ("/pause", "/save", "/respawn", "/light")

# ★ M5：WS 单连接消息速率上限（每秒）。正常客户端是「按键状态变化时才发」，
#   量级 <20/s；200/s 足够容纳连按与回放脚本，又能挡住「一条连接灌满 CPU」。
MAX_WS_MSGS_PER_SEC = 200


def _origin_host(value):
    """从 `Origin` / `Referer` 里取 `host:port`（小写）。取不到返回空串。

    ★ 为什么不用 urllib.parse 而手写：这两个头在本服务里只用来**比 host**，
      不需要 scheme/path 解析；手写反而不会因畸形值抛异常（畸形 ⇒ 视为跨源）。
    """
    v = (value or "").strip().lower()
    if not v:
        return ""
    if v == "null":            # file:// / sandbox iframe：明确当作跨源
        return "null"
    if "://" in v:
        v = v.split("://", 1)[1]
    return v.split("/", 1)[0].split("?", 1)[0]


def _query_of(path):
    return path.split("?", 1)[1] if "?" in path else ""


def _query_get(path, key):
    for kv in _query_of(path).split("&"):
        if kv.startswith(key + "="):
            return kv[len(key) + 1:]
    return None


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
