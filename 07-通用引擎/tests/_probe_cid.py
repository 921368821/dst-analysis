"""P49 一次性探针：**连接号（cid）复用**能不能被行为判据抓到。

★ P50 补记：这条判据已经有**毫秒级**版本了（`tests/test_units.py` 的 U12/U13，
  直接对 `Hub` 断言，不用起服务端）。本文件**保留**但**不是测试**：
  文件名 `_probe_` 前缀 + `run_all.sh` 只按名单跑 `test_*.py`，所以它永远不会被自动跑。
  留着的理由：U12/U13 测的是 `Hub` 的纯逻辑，而这里走的是**真的 ws 连接**
  （`ws_api` 里 cid 的取号时机、`finally` 里的 release 顺序）。两者层次不同，
  改 `ws_api` 的取号处时跑一次这个探针，能确认「改的地方真的接上了」。
  用完即弃，不要把它塞进 CI。

只跑一个场景（不需要整套 test_rt，省得等 4 分钟）：

    A(1) B(2) C(3) 都连上 ⇒ **B 断开**（在线人数减一，空出一个号码）
    ⇒ D 连上（旧代码里它叫 3，撞上还活着的 C）
    ⇒ C 断开（旧代码里这一下释放的是 **D 的**槽位）
    ⇒ E 连上 ⇒ 旧代码里 E 拿到 D 的槽位 ⇒ **同一个 guid**

期望：修好的代码 E≠D；旧代码 E==D。
用法：python _probe_cid.py [端口]
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RT = os.path.abspath(os.path.join(HERE, "..", "rt"))
sys.path.insert(0, RT)
import ws                                                          # noqa: E402

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8811


def recv_exact(sock, n, timeout=1.0):
    """收满 n 字节。★ 超时值**只在变化时**才设（P49：每次 settimeout 会改 fd 的阻塞模式，
    与并发的 sendall 抢同一个 fd ⇒ 半帧 ⇒ 服务端报 client frame must be masked）。"""
    buf = b""
    while len(buf) < n:
        if sock.gettimeout() != timeout:
            sock.settimeout(timeout)
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("对端关闭（还差 %d 字节）" % (n - len(buf)))
        buf += chunk
    return buf


def recv_frame(sock, timeout=1.0):
    h = recv_exact(sock, 2, timeout)
    op = h[0] & 0x0F
    ln = h[1] & 0x7F
    if ln == 126:
        ln = int.from_bytes(recv_exact(sock, 2, timeout), "big")
    elif ln == 127:
        ln = int.from_bytes(recv_exact(sock, 8, timeout), "big")
    return op, recv_exact(sock, ln, timeout)


class Conn:
    ALL = []

    def __init__(self, name):
        self.name = name
        Conn.ALL.append(self)
        self.s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        ws.client_handshake(self.s, "127.0.0.1:%d" % PORT)
        self.s.settimeout(1.0)
        self.you = None
        self.slot = None
        self.frames = 0
        self.null = 0
        self.err = None
        self.alive = True
        self.th = threading.Thread(target=self._run, daemon=True)
        self.th.start()
        self.ask()

    def ask(self):
        try:
            self.s.sendall(ws.encode_frame_masked(
                json.dumps({"cmd": "whoami"}).encode("utf-8")))
        except OSError as e:
            self.err = "%s: %s" % (type(e).__name__, e)

    def _run(self):
        while self.alive:
            try:
                _op, d = recv_frame(self.s, 1.0)
            except socket.timeout:
                continue
            except Exception as e:                                  # noqa: BLE001
                if self.alive:
                    self.err = "%s: %s" % (type(e).__name__, e)
                return
            self.frames += 1
            try:
                m = json.loads(d.decode("utf-8"))
            except Exception:                                       # noqa: BLE001
                continue
            if isinstance(m, dict) and "you" in m:
                if m.get("you") is None:
                    self.null += 1
                elif self.you is None:
                    self.you = int(m["you"])
                    self.slot = int(m.get("slot") or 0)

    def wait_you(self, timeout=8.0):
        end = time.time() + timeout
        while time.time() < end:
            if self.you is not None:
                return self.you
            if self.err:
                return None
            self.ask()
            time.sleep(0.15)
        return None

    def close(self):
        self.alive = False
        time.sleep(0.06)
        try:
            self.s.close()
        except OSError:
            pass


def start_server():
    logp = os.path.join(tempfile.gettempdir(), "probe_cid_srv.log")
    lf = open(logp, "w", encoding="utf-8")
    env = dict(os.environ)
    env["PYTHONUNBUFFERED"] = "1"
    p = subprocess.Popen([sys.executable, "-u", "server.py", "--port", str(PORT),
                          "--hz", "30", "--seed", "20261015", "--quiet"],
                         stdout=lf, stderr=subprocess.STDOUT, env=env, cwd=RT, text=True)
    for _ in range(200):
        if p.poll() is not None:
            raise SystemExit("服务端启动即退出（日志 %s）" % logp)
        try:
            socket.create_connection(("127.0.0.1", PORT), timeout=0.2).close()
            return p, lf, logp
        except OSError:
            time.sleep(0.1)
    raise SystemExit("服务端 20 s 内未监听（日志 %s）" % logp)


def main():
    p, lf, logp = start_server()
    try:
        a = Conn("A"); ga = a.wait_you()
        b = Conn("B"); gb = b.wait_you()
        c = Conn("C"); gc = c.wait_you()
        for nm, cn, g in (("A", a, ga), ("B", b, gb), ("C", c, gc)):
            if g is None:
                print("✘ %s 没拿到 you（null×%d frames=%d err=%s）"
                      % (nm, cn.null, cn.frames, cn.err))
                return 2
            print("  %s: guid=%s slot=%s" % (nm, g, cn.slot))
        if len({ga, gb, gc}) != 3:
            print("✘ 前提不成立：三条连接就撞了角色 %s/%s/%s" % (ga, gb, gc))
            return 2

        # ① 中间那条走（在线人数 -1，空出一个号码）
        b.close(); time.sleep(0.8)
        # ② 新连接 D
        d = Conn("D"); gd = d.wait_you()
        if gd is None:
            print("✘ D 没拿到 you（null×%d frames=%d err=%s）" % (d.null, d.frames, d.err))
            return 2
        print("  D: guid=%s slot=%s（B 走之后）" % (gd, d.slot))
        # ③ C 走
        c.close(); time.sleep(0.8)
        # ④ 再连 E
        e = Conn("E"); ge = e.wait_you()
        if ge is None:
            print("✘ E 没拿到 you（null×%d frames=%d err=%s）" % (e.null, e.frames, e.err))
            return 2
        print("  E: guid=%s slot=%s（C 走之后）" % (ge, e.slot))
        print("  D 现状：guid=%s slot=%s err=%s frames=%d"
              % (d.you, d.slot, d.err, d.frames))

        if ge == gd or e.slot == d.slot:
            print("\n✘✘ **E 顶掉了 D**：D(guid=%s slot=%s) / E(guid=%s slot=%s) —— "
                  "连接号被复用，槽位互相顶掉" % (gd, d.slot, ge, e.slot))
            return 1
        if d.err:
            print("\n✘✘ C 断开后 D 掉线了：%s（它的连接被别人的 release 收走了）" % d.err)
            return 1
        if d.you != gd:
            print("\n✘✘ D 的角色被换了：%s → %s" % (gd, d.you))
            return 1
        print("\n✔ 连接号不复用：E(guid=%s) ≠ D(guid=%s)，D 没被顶掉" % (ge, gd))
        return 0
    finally:
        for cn in list(Conn.ALL):
            cn.close()
        p.terminate()
        try:
            p.wait(timeout=5)
        except Exception:                                           # noqa: BLE001
            p.kill()
        lf.close()
        print("（服务端日志：%s）" % logp)


if __name__ == "__main__":
    sys.exit(main())
