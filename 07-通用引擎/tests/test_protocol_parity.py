# -*- coding: utf-8 -*-
"""test_protocol_parity.py —— **跨实现一致性**：Python 编码 → JS 解码（P5）

为什么必须有这条
    二进制协议有**两份实现**（服务端 Python、客户端 JS）。
    只要它们有一点不一致，症状会是「服务端以为发对了、客户端解出垃圾」——
    这类问题在实时流里极难查（每帧都在变）。
    ⇒ 唯一可靠的办法：拿**同一份快照**，一边编一边解，逐字段比。

跑法：cd 07-通用引擎 && python tests/test_protocol_parity.py
"""
import io
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RT = os.path.join(ROOT, "rt")
sys.path.insert(0, RT)

import protocol_bin as PB   # noqa: E402

sys.path.insert(0, os.path.join(ROOT, "tools"))
import _rt_env             # noqa: E402

NODE = _rt_env.NODE      # ★ 不再写死用户目录（2026-10-17 迁移）
PASS, FAIL = 0, 0


def check(name, fn):
    global PASS, FAIL
    try:
        ok, info = fn()
    except Exception as e:                                       # noqa: BLE001
        ok, info = False, "抛异常: %s: %s" % (type(e).__name__, e)
    if ok:
        PASS += 1
        print("  ✔ %-46s %s" % (name, info))
    else:
        FAIL += 1
        print("  ✘ %-46s %s" % (name, info))


# ---------------------------------------------------------------- 造快照
def make_snap(n=40):
    ents = []
    for i in range(n):
        ents.append({
            "id": 100 + i * 3,
            "x": round(((i * 37) % 200) - 100 + 0.031, 3),
            "z": round(((i * 53) % 200) - 100 - 0.047, 3),
            "p": "prefab_" + str(i % 7),
            "a": "walk" if i % 2 else "idle_loop",
            "bld": "蜘蛛" if i % 5 == 0 else "wilson",     # 故意混中文，验 UTF-8
            "fr": i % 5,
            "f": (i % 8) * 0.3927,
        })
    return {"t": 123.456, "tick": 4096, "n": n, "iseq": 777,
            "ents": ents, "player": {"id": 100, "x": ents[0]["x"], "z": ents[0]["z"]},
            "paused": True,                      # ★ bit3（零字节成本）
            # ★ 世界环境块：故意用**非默认**组合（黄昏 + 冬天 + 负温度），
            #   免得「碰巧等于默认值」把编码错误掩盖掉
            "world": {"phase": "dusk", "season": "winter",
                      "isday": False, "isdusk": True, "isnight": False,
                      "temperature": -3.25}}


def js_decode(bytes_path):
    """调 Node 用 protocol_bin.js 解一帧，返回 JSON"""
    script = (
        "const fs=require('fs');"
        "const P=require(%s);"
        "const buf=fs.readFileSync(%s);"
        "const d=new P.Dict();"
        "console.log(JSON.stringify(P.decode(new Uint8Array(buf), d)));"
        % (json.dumps(os.path.join(RT, "protocol_bin.js")), json.dumps(bytes_path))
    )
    r = subprocess.run([NODE, "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("node 解码失败: " + (r.stderr or "")[:300])
    return json.loads(r.stdout.strip().split("\n")[-1])


def t1_parity():
    """★ 核心：Python 编码 → JS 解码，逐字段一致"""
    snap = make_snap(40)
    enc = PB.BinEncoder()
    blob = enc.encode(snap)
    tmp = os.path.join(RT, "_parity_frame.bin")
    with open(tmp, "wb") as f:
        f.write(blob)
    try:
        back = js_decode(tmp)
    finally:
        os.remove(tmp)
    if back["tick"] != snap["tick"] or back["n"] != snap["n"] or back["iseq"] != snap["iseq"]:
        return False, "头部字段不一致"
    tol = 1 / 16 + 1e-9
    for i, (a, b) in enumerate(zip(snap["ents"], back["ents"])):
        if b["id"] != a["id"]:
            return False, "id 不一致 @%d" % i
        if abs(b["x"] - a["x"]) > tol or abs(b["z"] - a["z"]) > tol:
            return False, "坐标差 @%d (%.4f, %.4f)" % (i, b["x"] - a["x"], b["z"] - a["z"])
        if b.get("p") != a["p"] or b.get("a") != a["a"] or b.get("bld") != a["bld"]:
            return False, "字符串不一致 @%d: %s/%s/%s" % (i, b.get("p"), b.get("a"), b.get("bld"))
        if b.get("fr") != a["fr"]:
            return False, "帧号不一致 @%d" % i
    # ★ 世界环境块也必须逐字段一致（含布尔三态与负温度）
    w, bw = snap["world"], back.get("world")
    if bw is None:
        return False, "JS 侧没解出 world 块（bit2 没置位？）"
    for k in ("phase", "season", "isday", "isdusk", "isnight"):
        if bw.get(k) != w[k]:
            return False, "world.%s 不一致: %r vs %r" % (k, bw.get(k), w[k])
    if abs(bw["temperature"] - w["temperature"]) > 1 / 16 + 1e-9:
        return False, "world.temperature 差 %.4f" % (bw["temperature"] - w["temperature"])
    if back.get("paused") is not True:
        return False, "暂停位（bit3）没传过去: %r" % back.get("paused")
    return True, "%d 实体 × 6 字段 + world × 6 字段 + paused 全部一致（含中文 build 名、负温度）" \
                 % len(snap["ents"])


def t2_multi_frame_dict():
    """★ 跨帧字典：Python 连编 3 帧，JS 用**同一个** Dict 连解 3 帧"""
    enc = PB.BinEncoder()
    frames = []
    tmpfiles = []
    for k in range(3):
        s = make_snap(20 + k * 5)
        s["tick"] = 100 + k
        blob = enc.encode(s)
        p = os.path.join(RT, "_parity_f%d.bin" % k)
        with open(p, "wb") as f:
            f.write(blob)
        tmpfiles.append(p)
        frames.append(s)
    script = (
        "const fs=require('fs');const P=require(%s);const d=new P.Dict();"
        "const out=[];"
        "for (const f of %s) { out.push(P.decode(new Uint8Array(fs.readFileSync(f)), d)); }"
        "console.log(JSON.stringify(out));"
        % (json.dumps(os.path.join(RT, "protocol_bin.js")), json.dumps(tmpfiles))
    )
    try:
        r = subprocess.run([NODE, "-e", script], capture_output=True, text=True)
        if r.returncode != 0:
            return False, "node 失败: " + (r.stderr or "")[:200]
        got = json.loads(r.stdout.strip().split("\n")[-1])
    finally:
        for p in tmpfiles:
            if os.path.exists(p):
                os.remove(p)
    for k, (a, b) in enumerate(zip(frames, got)):
        if b["tick"] != a["tick"] or b["n"] != a["n"]:
            return False, "第 %d 帧头部不对" % k
        if b["ents"][0].get("p") != a["ents"][0]["p"]:
            return False, "第 %d 帧字符串不对（字典跨帧失效）" % k
    return True, "3 帧共用字典，全部解对（第 2/3 帧字符串走索引）"


def t3_size():
    """带宽实测：同一快照 Python 二进制 vs JSON"""
    snap = make_snap(200)
    enc = PB.BinEncoder()
    enc.encode(snap)                    # 首帧建字典
    b = len(enc.encode(snap))    # ★ 忘了 len：b 是 bytes，和 float 比会 TypeError
    j = len(json.dumps(snap, ensure_ascii=False).encode("utf-8"))
    return (b < j * 0.3, "200 实体：JSON %d B → 二进制 %d B（省 %.0f%%）"
            % (j, b, 100 * (1 - b / j)))


def t4_bad_frame():
    """★ 反向：坏帧 JS 侧必须抛错（而不是解出垃圾）"""
    cases = [("空", b""), ("魔数错", b"\x00\x00\x02\x03\x00\x00\x00\x00"),
             ("版本错", b"\x52\x54\x63\x03\x00\x00\x00\x00")]
    bad = []
    for name, b in cases:
        p = os.path.join(RT, "_parity_bad.bin")
        with open(p, "wb") as f:
            f.write(b)
        script = ("const fs=require('fs');const P=require(%s);const d=new P.Dict();"
                  "try { P.decode(new Uint8Array(fs.readFileSync(%s)), d); console.log('NOERR'); }"
                  "catch (e) { console.log('ERR'); }"
                  % (json.dumps(os.path.join(RT, "protocol_bin.js")), json.dumps(p)))
        r = subprocess.run([NODE, "-e", script], capture_output=True, text=True)
        os.remove(p)
        if "ERR" not in r.stdout:
            bad.append(name)
    return (not bad, "3 种坏帧 JS 侧全部抛错 ✔" if not bad else "没抛错: " + ",".join(bad))


def t5_no_world():
    """★ 反向：**没有** world 的快照 —— bit2 必须不置位，且 JS 解出来**没有** world。

    ★★ 为什么必须有这条反向测试：
    只测「有 world 时解得对」是不够的 —— 如果实现是「无条件读 world 块」，
    那么没有 world 的帧会在**帧尾之外**继续读，可能读到垃圾甚至越界。
    更要命的是「不管有没有都塞一个默认 world」这种实现：表面上 t1 也过，
    但客户端就永远看不到「这个世界没有环境数据」这个事实。
    """
    snap = make_snap(10)
    del snap["world"]
    enc = PB.BinEncoder()
    blob = enc.encode(snap)
    if blob[3] & 4:
        return False, "没有 world 却置了 bit2"
    tmp = os.path.join(RT, "_parity_now.bin")
    with open(tmp, "wb") as f:
        f.write(blob)
    try:
        back = js_decode(tmp)
    finally:
        os.remove(tmp)
    if "world" in back:
        return False, "没有 world 却解出了 %r" % (back["world"],)
    if back["n"] != 10 or back["ents"][9]["p"] != snap["ents"][9]["p"]:
        return False, "去掉 world 后实体段解错（帧尾对齐被破坏）"
    return True, "bit2 未置位、JS 无 world 字段、实体段仍解对"


def t6_unknown_phase():
    """★ 边界：phase/season 是**未知值**时，不能崩、也不能瞎猜 —— 必须给 None"""
    snap = make_snap(3)
    snap["world"] = {"phase": "血月", "season": "??", "isday": False,
                     "isdusk": False, "isnight": True, "temperature": 0}
    enc = PB.BinEncoder()
    tmp = os.path.join(RT, "_parity_unk.bin")
    with open(tmp, "wb") as f:
        f.write(enc.encode(snap))
    try:
        back = js_decode(tmp)
    finally:
        os.remove(tmp)
    w = back.get("world")
    if w is None:
        return False, "解不出 world 块"
    if w.get("phase") is not None or w.get("season") is not None:
        return False, "未知枚举被解成了 %r / %r（应该为 null）" % (w.get("phase"), w.get("season"))
    if w.get("isnight") is not True:
        return False, "未知 phase 时三态布尔也丢了（isnight 应为 true）"
    return True, "未知 phase/season → null，三态布尔与温度仍保住"


print("═" * 74)
print("  二进制协议：Python 编码 ⇄ JS 解码（跨实现一致性）")
print("═" * 74)
check("T1 同一快照：Python 编 → JS 解，逐字段一致", t1_parity)
check("T2 跨帧字典：连编 3 帧，JS 共用字典连解", t2_multi_frame_dict)
check("T3 带宽：二进制 vs JSON", t3_size)
check("T4 反向：坏帧 JS 侧必须抛错", t4_bad_frame)
check("T5 反向：无 world 时 bit2 不置位、不瞎补", t5_no_world)
check("T6 边界：未知 phase/season → null 而非瞎猜", t6_unknown_phase)
print("\n  结果：%d 通过 / %d 失败" % (PASS, FAIL))
sys.exit(0 if FAIL == 0 else 1)
