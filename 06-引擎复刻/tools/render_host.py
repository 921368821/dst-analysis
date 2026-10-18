#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
render_host.py —— 把宿主导出的绘制列表渲染成 PNG

这是「ZipAnim 接进宿主」的闭环终点：
    宿主（Lua）里 prefab → SetBuild → 状态机 → PlayAnimation
        → AnimState 真实帧数据 → GetDrawList()
        → 本脚本用图集光栅化 → PNG

输入是 render.lua 导出的纯文本（见那里的格式说明），
图集是本仓库 anim_data/ 下由 tools/ktex.py 解出的 PNG。
"""
import sys
import os
import re

sys.path.insert(0, os.path.dirname(__file__))
from ktex import write_png  # noqa: E402


# ---------------------------------------------------------------------------
# 极简 PNG 读入（只处理我们自己写出的 RGBA8 无隔行 PNG）
# ---------------------------------------------------------------------------
def read_png(path):
    import zlib
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', '不是 PNG'
    o = 8
    w = h = None
    idat = b''
    while o < len(d):
        ln = int.from_bytes(d[o:o + 4], 'big')
        tag = d[o + 4:o + 8]
        payload = d[o + 8:o + 8 + ln]
        o += 12 + ln
        if tag == b'IHDR':
            w = int.from_bytes(payload[0:4], 'big')
            h = int.from_bytes(payload[4:8], 'big')
            bd, ct = payload[8], payload[9]
            assert bd == 8 and ct == 6, f'只支持 8bit RGBA（得到 {bd}/{ct}）'
        elif tag == b'IDAT':
            idat += payload
        elif tag == b'IEND':
            break
    raw = zlib.decompress(idat)
    stride = w * 4
    out = bytearray(w * h * 4)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        ft = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ft == 1:
            for i in range(4, stride):
                line[i] = (line[i] + line[i - 4]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                b = prev[i]
                c = prev[i - 4] if i >= 4 else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, bytes(out)


def parse_drawlist(path):
    """解析 render.lua 导出的文本"""
    subjects = []
    cur = None
    bundle = None
    for line in open(path, encoding='utf-8'):
        line = line.strip()
        if not line:
            continue
        if line.startswith('BUNDLE '):
            t = line.split()
            name, atlas, w, h = t[1], t[2], int(t[3]), int(t[4])
            atlases = {}
            for extra in t[5:]:
                i, aw, ah = extra.split(':')
                atlases[int(i)] = (int(aw), int(ah))
            bundle = dict(name=name, atlas=atlas, w=w, h=h, atlases=atlases)
        elif line.startswith('SUBJECT '):
            cur = dict(name=line.split(None, 1)[1], bundle=bundle, frame=1, quads=[])
            subjects.append(cur)
        elif line.startswith('FRAME '):
            if cur:
                cur['frame'] = int(line.split()[1])
        elif line.startswith('QUAD '):
            if cur is None:
                continue
            t = line.split()
            sym = t[1]
            symframe = int(t[2])
            symatlas = int(t[3])
            nums = [float(x) for x in t[4:]]
            # ⚠️ 顶点数**不是固定的 6**！
            #   简单部件（耳朵、四肢）是 6 个顶点（两个三角形），
            #   但复杂部件（如 pig_torso）是多边形网格 —— 实测有 126 个顶点。
            #   早前按固定 6 个解析，mat 就读到了顶点数据上，
            #   结果变换矩阵变成乱码、包围盒被拉到 18000 宽。
            #   mat 恒为 7 个，所以顶点数可以由「总长度 − 7」反推。
            if len(nums) < 7:
                continue
            nverts = (len(nums) - 7) // 4
            if nverts < 3:
                continue
            verts = [tuple(nums[i * 4:i * 4 + 4]) for i in range(nverts)]
            mat = tuple(nums[nverts * 4:nverts * 4 + 7])
            cur['quads'].append(dict(symbol=sym, symframe=symframe,
                                     verts=verts, mat=mat, atlas=symatlas))
        elif line == 'END':
            cur = None
    return subjects


def sample(tex, u, v):
    w, h, px = tex
    x = max(0, min(w - 1, int(u * w)))
    y = max(0, min(h - 1, int(v * h)))
    i = (y * w + x) * 4
    return px[i], px[i + 1], px[i + 2], px[i + 3]


def render_subject(subj, atlases, pad=6, max_size=760):
    quads = subj['quads']
    if not quads:
        return None, 'no quads'

    # ---- 变换 + 包围盒 ----
    polys = []
    for q in quads:
        a, b, c, d, tx, ty, tz = q['mat']
        tex = atlases[q.get('atlas', 0)] if isinstance(atlases, dict) else atlases
        pts = []
        for (x, y, u, v) in q['verts']:
            # 与宿主/原版一致：y 向下为正（见 ZipAnim解析报告第四阶段）
            pts.append((a * x + b * y + tx, c * x + d * y + ty, u, v))
        polys.append((tz, q['symbol'], pts, tex))

    xs = [p[0] for _, _, pts, _t in polys for p in pts]
    ys = [p[1] for _, _, pts, _t in polys for p in pts]
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
    w = int(maxx - minx) + pad * 2
    h = int(maxy - miny) + pad * 2
    if w <= 0 or h <= 0:
        return None, 'empty bbox'
    scale = 1.0
    if max(w, h) > max_size:
        scale = max_size / max(w, h)
    ow, oh = max(1, int(w * scale)), max(1, int(h * scale))
    canvas = bytearray(ow * oh * 4)
    offx = -minx + pad
    offy = -miny + pad

    import math

    def to_canvas(x, y):
        return ((x + offx) * scale, (y + offy) * scale)

    def tri(p0, p1, p2, tex):
        x0, y0, u0, v0 = p0
        x1, y1, u1, v1 = p1
        x2, y2, u2, v2 = p2
        cx0, cy0 = to_canvas(x0, y0)
        cx1, cy1 = to_canvas(x1, y1)
        cx2, cy2 = to_canvas(x2, y2)
        x0i = max(0, int(math.floor(min(cx0, cx1, cx2))))
        x1i = min(ow, int(math.ceil(max(cx0, cx1, cx2))))
        y0i = max(0, int(math.floor(min(cy0, cy1, cy2))))
        y1i = min(oh, int(math.ceil(max(cy0, cy1, cy2))))
        if x1i <= x0i or y1i <= y0i:
            return
        den = (cy1 - cy2) * (cx0 - cx2) + (cx2 - cx1) * (cy0 - cy2)
        if abs(den) < 1e-9:
            return
        inv = 1.0 / den
        for py in range(y0i, y1i):
            fy = py + 0.5
            for pxx in range(x0i, x1i):
                fx = pxx + 0.5
                A = ((cy1 - cy2) * (fx - cx2) + (cx2 - cx1) * (fy - cy2)) * inv
                B = ((cy2 - cy0) * (fx - cx2) + (cx0 - cx2) * (fy - cy2)) * inv
                C = 1.0 - A - B
                if A < -1e-4 or B < -1e-4 or C < -1e-4:
                    continue
                u = A * u0 + B * u1 + C * u2
                v = A * v0 + B * v1 + C * v2
                r, g, bl, al = sample(tex, u, v)
                if al < 8:
                    continue
                i = (py * ow + pxx) * 4
                a0 = al / 255.0
                canvas[i] = int(r * a0 + canvas[i] * (1 - a0))
                canvas[i + 1] = int(g * a0 + canvas[i + 1] * (1 - a0))
                canvas[i + 2] = int(bl * a0 + canvas[i + 2] * (1 - a0))
                canvas[i + 3] = min(255, int(al + canvas[i + 3] * (1 - a0)))

    polys.sort(key=lambda t: t[0])       # tz 从远到近
    for tz, sym, pts, tex in polys:
        n = len(pts)
        if n % 6 == 0:
            # ★ 顶点是「每 6 个一组」的独立四边形 —— 每 6 个画两个三角形
            #   （非索引，顶点有重复：实测 v3==v1、v5==v2）。
            #   复杂部件会有多组：pig_torso 126 个顶点 = 21 个四边形。
            #   ⚠️ 先前把 126 个顶点当**一个多边形**做三角扇铺开，
            #      结果画出一大块糊掉的色斑。分组才是对的。
            for g in range(0, n, 6):
                tri(pts[g + 0], pts[g + 1], pts[g + 2], tex)
                tri(pts[g + 3], pts[g + 4], pts[g + 5], tex)
        elif n == 4:
            tri(pts[0], pts[1], pts[2], tex)
            tri(pts[0], pts[2], pts[3], tex)
        elif n >= 3:
            for i in range(1, n - 1):
                tri(pts[0], pts[i], pts[i + 1], tex)
    return (ow, oh, bytes(canvas)), None


if __name__ == '__main__':
    dl_path = sys.argv[1] if len(sys.argv) > 1 else '_out/drawlist.txt'
    outdir = sys.argv[2] if len(sys.argv) > 2 else '_out'
    subdir = 'anim_data'
    subs = parse_drawlist(dl_path)
    print(f'从 {dl_path} 读到 {len(subs)} 个主体')
    for s in subs:
        b = s['bundle']
        if not b:
            continue
        # 多图集：按 BUNDLE 里给的清单把所有图集读进来
        texs = {}
        idxs = sorted(b['atlases']) if b.get('atlases') else [0]
        ok_open = True
        for i in idxs:
            png = os.path.join(subdir,
                               f'{b["name"]}__atlas-{i}.png')
            if not os.path.exists(png):
                print(f'  ✘ 缺图集 {png}')
                ok_open = False
                break
            texs[i] = read_png(png)
        if not ok_open:
            continue
        tex = texs
        res, err = render_subject(s, tex)
        if err:
            print(f'  ✘ {s["name"]}: {err}')
            continue
        w, h, rgba = res
        out = os.path.join(outdir, f'host__{s["name"]}.png')
        write_png(out, w, h, rgba)
        nz = sum(1 for i in range(3, len(rgba), 4) if rgba[i] > 8)
        print(f'  ✔ {s["name"]:<10} {b["name"]:<14} 帧={s["frame"]:<4} '
              f'图块={len(s["quads"]):<3} → {out} ({w}×{h}, 可见 {nz})')
