# -*- coding: utf-8 -*-
"""protocol_bin.py —— 二进制帧编码（Python 侧，与 rt/protocol_bin.js 同一格式）

为什么 Python 也要有一份
    服务端是权威端，帧由它产出。客户端那份 JS 是**解码**用的；
    两份实现必须严格遵守同一份 `rt/protocol.md` §3，
    否则会出现「服务端以为发对了、客户端解出垃圾」这种最难查的问题。
    ⇒ 一致性由 `tests/test_protocol_parity.py` 守：同一份快照，
      Python 编码 → JS 解码，逐字段比。

设计（与 JS 版逐条对应）
    · 定点：坐标 1/16 格、朝向 1/16 度 ⇒ 比 float32 省一半
    · 字符串**连接级字典**：跨帧累积，本帧只带新增 ⇒ 重复名每帧 1 个 varint
    · id 用 **delta** 编码（快照按 guid 有序）
"""
import struct

# ★★ L1：常量**不再手写**，全部来自 `rt/protocol.schema.json`
#   （生成器 tools/gen-protocol-schema.mjs，生成物 rt/protocol_schema.py）。
#   为什么必须这样：VERSION / FIX / PHASES / SEASONS 原来在 .py 与 .js 里**各抄一份**，
#   「只改一边」的后果是最难查的那类错 —— 顺序写错 ⇒ 服务端发 day、客户端解成 night；
#   FIX 不一致 ⇒ 位置缓慢漂移（像物理抖动）。parity 测试只能抓「两边不一样」，
#   抓不到「两边一起写错」；单源生成把后者变成不可能。
from protocol_schema import (MAGIC0, MAGIC1, VERSION, FIX, PHASES, SEASONS)

_PHASE_IDX = {s: i for i, s in enumerate(PHASES)}
_SEASON_IDX = {s: i for i, s in enumerate(SEASONS)}


def _varint(v: int) -> bytes:
    v = int(v) & 0xFFFFFFFF
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def _i16(v: float) -> bytes:
    q = int(round(float(v) * FIX))
    q = max(-32768, min(32767, q))
    return struct.pack("<h", q)


def _f32(v: float) -> bytes:
    return struct.pack("<f", float(v))


class BinEncoder:
    """**每个连接一个**：字典是连接级状态，不能跨连接共用"""

    def get(self, i):
        """索引 → 字符串（0 表示没有）。

        ★★ 为什么必须**边界检查**而不是直接 `self.list[i-1]`：
        字典是**连接级**的，而「首帧带全字典」只在客户端**从第一帧开始听**时才成立。
        实测踩到：客户端漏掉首帧（或中途接入）后，后续帧里的索引在本地字典里不存在
        ⇒ 直接抛 `IndexError` —— 一个**看起来像解码器坏了**、其实是「历史缺了一截」的错。
        ⇒ 越界就返回 None，并把次数**记下来**（`misses`），让调用方能看见「我缺字典」，
          而不是崩在一个下标上。
        """
        if not i:
            return None
        if i > len(self.list):
            self.misses = getattr(self, "misses", 0) + 1
            return None
        return self.list[i - 1]

    def __init__(self):
        self.list = []               # [0] 为空位（索引 0 = 没有）
        self.idx = {}

    def intern(self, s):
        if not s:
            return 0
        i = self.idx.get(s)
        if i is None:
            self.list.append(s)
            i = len(self.list)
            self.idx[s] = i
        return i

    def encode(self, snap: dict) -> bytes:
        ents = snap.get("ents") or []
        # 先挑出本帧**新增**的字符串
        fresh, seen = [], set()
        for e in ents:
            for k in ("p", "a", "bld"):
                s = e.get(k)
                if s and s not in self.idx and s not in seen:
                    seen.add(s)
                    fresh.append(s)

        world = snap.get("world")
        out = bytearray()
        out += bytes([MAGIC0, MAGIC1, VERSION])
        # ★ bit3 = 「世界已暂停」。**零字节成本**（借 flags 里一个没用的位），
        #   但客户端必须知道 —— 否则世界停住时它只能靠「t 不涨」猜，
        #   而「t 不涨」和「网络卡了」长得一模一样。
        flags = (1 if snap.get("player") else 0) | (2 if ents else 0) \
              | (4 if world else 0) | (8 if snap.get("paused") else 0)
        out.append(flags)
        out += _varint(snap.get("tick", 0))
        out += _f32(snap.get("t", 0.0))
        out += _varint(len(ents))
        out += _varint(snap.get("iseq", 0))
        out += _varint(len(fresh))
        for s in fresh:
            b = s.encode("utf-8")
            out += _varint(len(b))
            out += b
            self.intern(s)

        pl = snap.get("player")
        if pl is not None:
            out += _varint(pl.get("id", 0))
            out += _i16(pl.get("x", 0.0))
            out += _i16(pl.get("z", 0.0))

        prev = 0
        for e in ents:
            eid = int(e.get("id", 0))
            out += _varint(eid - prev)
            prev = eid
            out += _i16(e.get("x", 0.0))
            out += _i16(e.get("z", 0.0))
            out += _varint(self.intern(e.get("p")))
            out += _varint(self.intern(e.get("a")))
            out += _varint(self.intern(e.get("bld")))
            out += _varint(e.get("fr") or 0)
            import math
            deg = float(e.get("f") or 0.0) * (180.0 / math.pi)
            out += _i16(deg)

        # ---- 世界环境块（可选，放在**帧尾**）----
        # ★ 为什么放尾部而不是头部：这是**追加**式改动，老的字段偏移一个都不动，
        #   出问题时能一眼看出是「新块」而不是「老块被挪位」。
        if world is not None:
            out.append(_PHASE_IDX.get(world.get("phase"), 255) & 0xFF)
            out.append(_SEASON_IDX.get(world.get("season"), 255) & 0xFF)
            df = (1 if world.get("isday") else 0) \
               | (2 if world.get("isdusk") else 0) \
               | (4 if world.get("isnight") else 0)
            out.append(df)
            out += _i16(world.get("temperature", 0.0))
        return bytes(out)


def decode(buf: bytes, enc: BinEncoder = None) -> dict:      # noqa: F811
    if enc is None:
        enc = BinEncoder()
    if len(buf) < 4:
        raise ValueError("帧太短")
    if buf[0] != MAGIC0 or buf[1] != MAGIC1:
        raise ValueError("魔数不对")
    if buf[2] != VERSION:
        raise ValueError("协议版本不支持: %d" % buf[2])
    p = 3
    flags = buf[p]; p += 1

    def rv():
        nonlocal p
        v, shift = 0, 0
        while True:
            b = buf[p]; p += 1
            v |= (b & 0x7F) << shift
            if not (b & 0x80):
                break
            shift += 7
            if shift > 35:
                raise ValueError("varint 过长")
        return v

    def ri16():
        nonlocal p
        v = struct.unpack_from("<h", buf, p)[0]; p += 2
        return v / FIX

    def rf32():
        nonlocal p
        v = struct.unpack_from("<f", buf, p)[0]; p += 4
        return v

    out = {"tick": rv(), "t": rf32(), "n": rv(), "iseq": rv(),
           "paused": bool(flags & 8)}
    dn = rv()
    for _ in range(dn):
        ln = rv()
        s = buf[p:p + ln].decode("utf-8"); p += ln
        enc.intern(s)
    if flags & 1:
        out["player"] = {"id": rv(), "x": ri16(), "z": ri16()}
    out["ents"] = []
    prev = 0
    for _ in range(out["n"]):
        prev += rv()
        e = {"id": prev}
        e["x"] = ri16()
        e["z"] = ri16()
        e["p"] = enc.get(rv())
        e["a"] = enc.get(rv())
        e["bld"] = enc.get(rv())
        e["fr"] = rv()
        deg = ri16()
        if deg:
            e["f"] = deg * 3.141592653589793 / 180.0
        out["ents"].append(e)
    if flags & 4:
        phi = buf[p]; p += 1
        sei = buf[p]; p += 1
        df = buf[p]; p += 1
        out["world"] = {
            "phase":  PHASES[phi] if phi < len(PHASES) else None,
            "season": SEASONS[sei] if sei < len(SEASONS) else None,
            "isday":  bool(df & 1),
            "isdusk": bool(df & 2),
            "isnight": bool(df & 4),
            "temperature": ri16(),
        }
    return out
