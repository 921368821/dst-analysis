# -*- coding: utf-8 -*-
"""ws.py —— 最小 WebSocket 服务端（RFC 6455），**只用标准库**（P1 / M3）

为什么手写而不是装 `websockets`
    §0.3 已核实环境：只有 lupa，没有 websockets/aiohttp/pygame/numpy/PIL。
    本计划定的规矩是「只用标准库 + lupa」—— 与工程既有的
    「播放器 10.2 MB 完全自包含、0 个外部引用」是同一取向。
    RFC 6455 里我们真正需要的部分（握手 + 帧编解码 + ping/pong/close）
    大约 150 行，可控且可测。

支持范围（够用即可，不追求全覆盖）
    · 握手（Sec-WebSocket-Key → Accept）
    · 文本帧收（**必须**处理客户端掩码）
    · 文本帧发（服务端不掩码）
    · ping → pong；close 应答；分片帧**明确不支持**（收到就报错，不静默）
    · 单帧上限可配（防半截帧把内存吃满）
"""
import base64
import hashlib
import struct

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# 帧类型
OP_CONT, OP_TEXT, OP_BIN, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA


class WSError(Exception):
    """协议层错误 —— **必须显式抛出**，不允许静默丢弃（本工程的「不静默」纪律）"""


def accept_key(client_key: str) -> str:
    """握手：Sec-WebSocket-Accept = base64(sha1(key + GUID))"""
    sha = hashlib.sha1((client_key.strip() + GUID).encode("ascii")).digest()
    return base64.b64encode(sha).decode("ascii")


def parse_http_headers(raw: bytes):
    """把 HTTP 请求头解析成 (方法, 路径, 头字典)。只处理我们需要的部分。"""
    text = raw.decode("latin1", "replace")
    lines = text.split("\r\n")
    if not lines or not lines[0]:
        raise WSError("empty request")
    parts = lines[0].split(" ")
    if len(parts) < 2:
        raise WSError("bad request line: %r" % lines[0])
    method, path = parts[0], parts[1]
    headers = {}
    for ln in lines[1:]:
        if not ln:
            break
        if ":" in ln:
            k, v = ln.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return method, path, headers


def handshake_response(headers) -> bytes:
    key = headers.get("sec-websocket-key")
    if not key:
        raise WSError("missing Sec-WebSocket-Key")
    return (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n\r\n" % accept_key(key)
    ).encode("ascii")


def encode_frame(payload: bytes, opcode: int = OP_TEXT) -> bytes:
    """服务端 → 客户端：不掩码。长度用 7bit / 16bit / 64bit 三档。"""
    n = len(payload)
    head = bytearray([0x80 | opcode])
    if n < 126:
        head.append(n)
    elif n < 65536:
        head.append(126)
        head += struct.pack(">H", n)
    else:
        head.append(127)
        head += struct.pack(">Q", n)
    return bytes(head) + payload


def _read_exact(sock, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise WSError("connection closed mid-frame (wanted %d, got %d)" % (n, len(buf)))
        buf += chunk
    return bytes(buf)


def read_frame(sock, max_payload: int = 8 * 1024 * 1024):
    """读一帧 → (opcode, payload)。客户端帧**必须**带掩码，否则协议错。"""
    b0, b1 = _read_exact(sock, 2)
    fin = (b0 & 0x80) != 0
    opcode = b0 & 0x0F
    masked = (b1 & 0x80) != 0
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", _read_exact(sock, 2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", _read_exact(sock, 8))[0]
    if ln > max_payload:
        raise WSError("frame too large: %d > %d" % (ln, max_payload))
    if not fin:
        # ★ 分片帧我们**不支持**：明确报错，不做半吊子拼接（宁可不支持，也不装作支持）
        raise WSError("fragmented frames are not supported (fin=0, opcode=%d)" % opcode)
    if not masked:
        raise WSError("client frame must be masked (RFC 6455 §5.1)")
    mask = _read_exact(sock, 4)
    data = _read_exact(sock, ln)
    out = bytearray(data)
    for i in range(len(out)):
        out[i] ^= mask[i & 3]
    return opcode, bytes(out)


def close_frame(code: int = 1000) -> bytes:
    return encode_frame(struct.pack(">H", code), OP_CLOSE)


# =============================================================================
# 客户端侧（测试用）：RFC 6455 规定客户端帧**必须**带掩码
# =============================================================================
def encode_frame_masked(payload: bytes, opcode: int = OP_TEXT, mask: bytes = b"\x37\xfa\x21\x3d") -> bytes:
    n = len(payload)
    head = bytearray([0x80 | opcode])
    if n < 126:
        head.append(0x80 | n)
    elif n < 65536:
        head.append(0x80 | 126)
        head += struct.pack(">H", n)
    else:
        head.append(0x80 | 127)
        head += struct.pack(">Q", n)
    head += mask
    body = bytearray(payload)
    for i in range(len(body)):
        body[i] ^= mask[i & 3]
    return bytes(head) + bytes(body)


def client_handshake(sock, host: str, path: str = "/ws"):
    """做一次客户端握手；返回响应文本（供断言 101）"""
    key = base64.b64encode(b"0123456789abcdef").decode("ascii")
    req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\n"
           "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
           "Sec-WebSocket-Version: 13\r\n\r\n" % (path, host, key))
    sock.sendall(req.encode("ascii"))
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf.decode("latin1", "replace")
