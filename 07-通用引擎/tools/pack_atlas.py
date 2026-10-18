#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pack_atlas.py —— 自定义资产打包器（P5 剩余项 / 解锁 P6 发布）

为什么需要它
    发布版**不能带原版 DST 的图集**（版权）。而客户端的精灵渲染需要
    与引擎同格式的产物：`<build>.json`（symbols/anims/UV）+ `<build>__atlas-N.png`。
    ⇒ 这个工具把「自产素材」（本工具用程序化图形生成，也可以是任何 PNG）
      打包成**同一格式**，于是「换掉美术 → 发布」这条链就通了，**不用改引擎一行**。

输出格式（与 `06-引擎复刻/_out/json/<build>.json` 完全同构）
    {
      "buildName": "<name>",
      "atlas":  {"file": "atlas-0.tex", "w": W, "h": H},
      "atlases":[{"w": W, "h": H, "file": "atlas-0.tex"}],
      "symbols": { "<symid>": { "name": "...", "atlas": 0,
                                "frames": { "0": {"verts": [[x,y,u,v]×6],
                                                  "bbox": [x0,y0,x1,y1]} } } },
      "anims":   { "<anim>": { "rate": 30.0,
                               "frames": [ [ {"sym":"<symid>","frame":0,
                                              "mat":[a,b,c,d,tx,ty,z]} ], ... ] } }
    }

用法
    python tools/pack_atlas.py --out <输出目录> [--build rt_demo] [--demo]
"""
import argparse
import io
import json
import os
import struct
import zlib


# ---------------------------------------------------------------- 极简 PNG 写入
def write_png(path, w, h, rgba):
    """纯标准库写 PNG（不引 Pillow）。
    rgba: bytes，长度 w*h*4，逐行自上而下。"""
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)                       # filter type 0
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)   # 8bit RGBA
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", ihdr)
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


class Canvas:
    """极简画布：矩形 / 圆 / 三角。够画演示素材。"""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = bytearray(w * h * 4)      # 全透明

    def rect(self, x0, y0, x1, y1, rgba):
        for y in range(max(0, y0), min(self.h, y1)):
            row = y * self.w * 4
            for x in range(max(0, x0), min(self.w, x1)):
                i = row + x * 4
                a = rgba[3] / 255.0
                for k in range(3):
                    self.px[i + k] = int(rgba[k] * a + self.px[i + k] * (1 - a))
                self.px[i + 3] = max(self.px[i + 3], rgba[3])

    def ellipse(self, cx, cy, rx, ry, rgba):
        for y in range(max(0, cy - ry), min(self.h, cy + ry + 1)):
            for x in range(max(0, cx - rx), min(self.w, cx + rx + 1)):
                dx = (x - cx) / float(rx)
                dy = (y - cy) / float(ry)
                if dx * dx + dy * dy <= 1.0:
                    i = (y * self.w + x) * 4
                    self.px[i:i + 4] = bytes(rgba)

    def tri(self, p0, p1, p2, rgba):
        xs = [p0[0], p1[0], p2[0]]
        ys = [p0[1], p1[1], p2[1]]
        def sign(a, b, c):
            return (a[0] - c[0]) * (b[1] - c[1]) - (b[0] - c[0]) * (a[1] - c[1])
        for y in range(max(0, min(ys)), min(self.h, max(ys) + 1)):
            for x in range(max(0, min(xs)), min(self.w, max(xs) + 1)):
                d1, d2, d3 = sign((x, y), p0, p1), sign((x, y), p1, p2), sign((x, y), p2, p0)
                neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
                pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
                if not (neg and pos):
                    i = (y * self.w + x) * 4
                    self.px[i:i + 4] = bytes(rgba)


# ---------------------------------------------------------------- 打包
def make_demo_sheet():
    """生成演示素材：四个符号（body / head / arm / shadow），各 1 帧。

    为什么程序化生成：
      · 发布版的**素材必须是自产的**（版权）——程序化图形天然自产；
      · 也顺便证明「任意 PNG 都能进这条管线」，不必依赖任何外部素材。
    布局：每个符号占 64×64 的格子，横向排在 256×64 的图集里。
    """
    W, H = 256, 64
    cv = Canvas(W, H)
    # 0: body —— 蓝绿圆角块
    cv.rect(8, 14, 56, 58, (63, 185, 80, 255))
    cv.rect(14, 8, 50, 20, (88, 166, 255, 255))
    # 1: head —— 肤色圆
    cv.ellipse(96 + 32, 32, 22, 22, (210, 168, 140, 255))
    cv.ellipse(96 + 24, 26, 4, 4, (40, 40, 40, 255))
    cv.ellipse(96 + 40, 26, 4, 4, (40, 40, 40, 255))
    # 2: arm —— 斜条
    cv.rect(128 + 26, 16, 128 + 38, 56, (210, 168, 140, 255))
    # 3: shadow —— 半透明椭圆
    cv.ellipse(192 + 32, 52, 26, 10, (0, 0, 0, 90))
    return W, H, bytes(cv.px)


SYMS = [
    # (symid, 名字, 格子序号)
    (1000001, "body",   0),
    (1000002, "head",   1),
    (1000003, "arm",    2),
    (1000004, "shadow", 3),
]
CELL = 64


def build_json(name, W, H, fps=30.0):
    def verts_for(idx):
        """6 个顶点（2 个三角形），x/y 为符号局部坐标（原点在格子中心），u/v 为图集 UV"""
        x0 = idx * CELL
        x1 = x0 + CELL
        # 局部坐标：以格子中心为原点，y 向上为正
        lx0, lx1 = -CELL // 2, CELL // 2
        ly1, ly0 = CELL // 2, -CELL // 2
        u0, u1 = x0 / float(W), x1 / float(W)
        v0, v1 = 0.0, 1.0        # 单行图集：整行高
        return [[lx0, ly0, u0, v1], [lx1, ly0, u1, v1], [lx0, ly1, u0, v0],
                [lx1, ly0, u1, v1], [lx1, ly1, u1, v0], [lx0, ly1, u0, v0]]

    symbols = {}
    for sid, nm, idx in SYMS:
        symbols[str(sid)] = {
            "name": nm, "atlas": 0,
            "frames": {"0": {"verts": verts_for(idx),
                             "bbox": [idx * CELL, 0, idx * CELL + CELL, CELL]}},
        }

    def frame(body, arm, lean=0.0):      # shadow 固定，未做参数（第一版多写了个必填参数，直接 TypeError）
        """一帧 = 若干符号 + 各自的仿射矩阵 [a,b,c,d,tx,ty,z]"""
        out = [
            # shadow 在最下（z 小）
            {"sym": str(1000004), "frame": 0, "mat": [1, 0, 0, 1, 0, 0, -1.0]},
            {"sym": str(1000001), "frame": 0, "mat": [body[0], 0, 0, body[1], 0, 0, 0.0]},
            {"sym": str(1000003), "frame": 0, "mat": [arm[0], 0, 0, arm[1], 10, 6, 0.5]},
            {"sym": str(1000002), "frame": 0, "mat": [1, 0, 0, 1, lean, 20, 1.0]},
        ]
        return out

    # ★★★ 动画名必须**跟状态图实际播的对上**（2026-10-16 修）：
    #   原版 `SGwilson` 走/跑时播的是 `run_pre` / `run_loop` / `run_pst`，
    #   而这里原来只产 `walk` / `run` —— **那两个名字在导出的 wilson build 里根本不存在**
    #   （实测动画表：corpse, corpse_hit, idle, idle_hot_*, idle_inaction*, idle_loop*,
    #     idle_sanity_*, run_loop, run_pre, run_pst）。
    #   ⇒ 后果：客户端按 `run_loop` 找不到图 ⇒ 移动时**退化成画圆**（静止时反而是精灵）。
    #   ⇒ 教训与 `WalkInDirection` 那次同源：**名字对不上的时候，程序不会报错，只会悄悄降级。**
    anims = {
        "idle_loop": {"rate": fps, "frames": [
            frame((1.0, 1.0), (1.0, 0.9)),
            frame((1.02, 0.98), (1.0, 1.0)),
        ]},
        # —— 起跑（原版 run_pre，4 帧）——
        "run_pre": {"rate": fps, "frames": [
            frame((1.0, 1.02), (1.05, 1.05), lean=1),
            frame((1.0, 1.0), (1.15, 1.15), lean=2),
        ]},
        # —— 跑循环（原版 run_loop，16 帧；自产给 4 帧够看出「在跑」）——
        "run_loop": {"rate": fps, "frames": [
            frame((1.05, 0.95), (1.4, 1.3), lean=2),
            frame((0.98, 1.02), (1.2, 1.1), lean=0),
            frame((0.95, 1.05), (1.1, 1.0), lean=-1),
            frame((0.98, 1.02), (1.2, 1.1), lean=0),
        ]},
        # —— 刹车（原版 run_pst，8 帧）——
        "run_pst": {"rate": fps, "frames": [
            frame((1.02, 0.98), (1.2, 1.15), lean=1),
            frame((0.99, 1.01), (1.05, 1.0), lean=0),
        ]},
        # —— 旧名字保留：别的 build / 别的路径可能仍在用（别名，不删）——
        "walk": {"rate": fps, "frames": [
            frame((1.0, 1.0), (1.15, 1.2), lean=1),
            frame((0.98, 1.02), (0.9, 1.0), lean=-1),
            frame((1.0, 1.0), (1.15, 1.2), lean=1),
            frame((0.98, 1.02), (0.9, 1.0), lean=-1),
        ]},
        "run": {"rate": fps, "frames": [
            frame((1.05, 0.95), (1.4, 1.3), lean=2),
            frame((0.95, 1.05), (1.1, 1.0), lean=-1),
        ]},
    }
    return {
        "buildName": name,
        "atlas": {"file": "atlas-0.tex", "w": W, "h": H},
        "atlases": [{"w": W, "h": H, "file": "atlas-0.tex"}],
        "symbols": symbols,
        "anims": anims,
    }


def validate(build, js, png_path):
    """打包后自检：**别产出解不动的东西**"""
    errs = []
    if not os.path.isfile(png_path):
        errs.append("PNG 没生成")
    else:
        with open(png_path, "rb") as f:
            head = f.read(8)
        if head != b"\x89PNG\r\n\x1a\n":
            errs.append("PNG 头不对")
    W, H = js["atlas"]["w"], js["atlas"]["h"]
    for sid, sym in js["symbols"].items():
        for fno, fr in sym["frames"].items():
            vs = fr["verts"]
            if len(vs) != 6:
                errs.append("%s/%s 顶点数 %d（应 6）" % (sid, fno, len(vs)))
            for (x, y, u, v) in vs:
                if not (0.0 <= u <= 1.0 and 0.0 <= v <= 1.0):
                    errs.append("%s/%s UV 越界 (%.3f,%.3f)" % (sid, fno, u, v))
    for an, a in js["anims"].items():
        if not a["frames"]:
            errs.append("anim %s 没有帧" % an)
        for i, fr in enumerate(a["frames"]):
            for item in fr:
                if item["sym"] not in js["symbols"]:
                    errs.append("anim %s 第 %d 帧引用了不存在的符号 %s" % (an, i, item["sym"]))
                if len(item["mat"]) != 7:
                    errs.append("anim %s 第 %d 帧的 mat 长度不是 7" % (an, i))
    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="输出目录（会建 json/ 与 anim_data/）")
    ap.add_argument("--build", default="rt_demo", help="build 名")
    ap.add_argument("--fps", type=float, default=30.0)
    a = ap.parse_args()

    out = os.path.abspath(a.out)
    jdir = os.path.join(out, "json")
    pdir = os.path.join(out, "anim_data")
    os.makedirs(jdir, exist_ok=True)
    os.makedirs(pdir, exist_ok=True)

    print("打包自产素材：build=%s → %s" % (a.build, out))
    W, H, rgba = make_demo_sheet()
    png = os.path.join(pdir, "%s__atlas-0.png" % a.build)
    write_png(png, W, H, rgba)
    print("  图集 PNG : %s（%d×%d，%d 字节）" % (os.path.basename(png), W, H, os.path.getsize(png)))

    js = build_json(a.build, W, H, a.fps)
    jp = os.path.join(jdir, "%s.json" % a.build)
    with io.open(jp, "w", encoding="utf-8") as f:
        json.dump(js, f, ensure_ascii=False, separators=(",", ":"))
    print("  元数据   : %s（%d 符号 / %d 动画 / %d 字节）"
          % (os.path.basename(jp), len(js["symbols"]), len(js["anims"]), os.path.getsize(jp)))

    errs = validate(a.build, js, png)
    if errs:
        print("  ✘ 自检不过：")
        for e in errs[:8]:
            print("     ·", e)
        return 1
    print("  ✔ 自检通过（顶点 6 / UV 在界内 / anim 引用的符号都存在 / mat 长度 7）")
    print()
    print("  怎么用：把这两个文件放到服务端能取到的位置即可 —— 引擎**不用改一行**。")
    print("    json/%s.json                  → /atlas/json/%s.json" % (a.build, a.build))
    print("    anim_data/%s__atlas-0.png     → /atlas/anim_data/%s__atlas-0.png"
          % (a.build, a.build))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
