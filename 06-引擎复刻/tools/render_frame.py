#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
render_frame.py —— 合成一帧真实动画（软件光栅化）

这是整个 ZipAnim 解析工作的**终点验证**：
    如果解出来的三个文件（atlas / build / anim）都对，那么按真实引擎的做法
    把它们拼起来，应当能画出一只**能认出来的生物**。

流程（与原版引擎一致）
    1. 解 KTEX 图集 → RGBA
    2. anim 的某帧给出一串 element：{symbol_hash, symbol_frame, mat}
    3. 对每个 element：
         · 用 symbol_hash 在 build 里找到符号
         · 取该符号的第 symbol_frame 帧 → build 的全局顶点池里的 6 个顶点
           顶点 = (x, y, z, u, v, w)：x,y 是相对锚点的位置，u,v 是归一化 UV
         · 用 element 的 mat (a,b,c,d,tx,ty) 做仿射变换（可含旋转/缩放）
    4. 把变换后的三角形用图集纹理光栅化，按 z 顺序叠加

不依赖任何图像库（纯标准库 + 自写 DXT5 解码 / PNG 写出）。
"""
import struct
import sys
import os
import zipfile

sys.path.insert(0, os.path.dirname(__file__))
from ktex import parse_ktex, decode_dxt5, write_png  # noqa: E402
from zipanim_build import parse_build  # noqa: E402
from zipanim_anim import parse_anim  # noqa: E402


def load_bundle(zip_path):
    z = zipfile.ZipFile(zip_path)
    names = z.namelist()
    b = parse_build(z.read('build.bin'))
    a = parse_anim(z.read('anim.bin'))
    # 图集（多张时按 build 的 materials 顺序）
    texs = []
    for mat in b['materials']:
        if mat in names:
            d = z.read(mat)
            k = parse_ktex(d)
            body = d[k['data_offset']:k['data_offset'] + k['mips'][0]['size']]
            rgba = decode_dxt5(body, k['width'], k['height'])
            texs.append(dict(w=k['width'], h=k['height'], rgba=rgba))
    return b, a, texs


def sample(tex, u, v):
    x = int(u * tex['w'])
    y = int(v * tex['h'])
    x = max(0, min(tex['w'] - 1, x))
    y = max(0, min(tex['h'] - 1, y))
    i = (y * tex['w'] + x) * 4
    return tex['rgba'][i:i + 4]


def render_frame(bundle, anim_name, frame_idx=0, pad=8, max_size=700):
    b, a, texs = bundle
    sym_by_hash = {s['hash']: s for s in b['symbols']}
    pool = b['vertices']

    anim = next((x for x in a['anims'] if x['name'] == anim_name), None)
    if not anim:
        return None, f'没有动画 {anim_name}'
    if frame_idx >= len(anim['frames']):
        return None, f'帧号越界（共 {len(anim["frames"])} 帧）'
    frame = anim['frames'][frame_idx]

    # ---- 收集所有要画的四边形 ----
    # 每个 poly = (tz, pts, atlas_idx)
    #   tz        —— 排序键（渲染引擎的 depth）
    #   pts       —— 变换后的顶点 [(x, y, u, v, z), ...]，**三角形列表**
    #   atlas_idx —— 该符号属于哪张图集
    # ⚠️ atlas_idx 必须跟着 poly 走：多图集 build（pig_build 有 atlas-0 2048²
    #    + atlas-1 1024×512）里，用错图集采样会直接出噪点。
    #    旧代码写死 texs[0]，是「pig/wilson 渲染出噪点」的两个根因之一。
    #    归属判定复用 export_anim.assign_atlas（「UV跨度×图集尺寸==bbox w/h」），
    #    与 export_anim.py / build_world_player.py 用的是同一条等式。
    from export_anim import assign_atlas
    atlas_dims = [(t['w'], t['h']) for t in texs]
    sym_atlas_cache = {}
    polys = []
    for el in frame['elements']:
        sym = sym_by_hash.get(el['symbol_hash'])
        if not sym or not sym['frames']:
            continue
        sf = el['symbol_frame']
        if not (0 <= sf < len(sym['frames'])):
            sf = 0
        fr = sym['frames'][sf]
        vb, nv = fr['vb_start'], fr['n_verts']
        if vb < 0 or vb + nv > len(pool):
            continue
        verts = pool[vb:vb + nv]
        if len(verts) < 3:
            continue
        # 图集归属（按符号缓存，避免每帧重算）
        # ⚠️ assign_atlas 期望「以帧号为键的 dict + 帧里带 _vb/_nv」，
        #    而 parse_build 给的是 list + vb_start/n_verts —— 先转换。
        #    单图集 build 它直接返 0，所以这个转换对 wilson 这类无开销。
        sh = sym['hash']
        ai = sym_atlas_cache.get(sh)
        if ai is None:
            frames_dict = {}
            for i, f in enumerate(sym['frames']):
                frames_dict[i] = dict(_vb=f['vb_start'], _nv=f['n_verts'],
                                      bbox=f['bbox'])
            ai = assign_atlas(frames_dict, pool, atlas_dims)
            sym_atlas_cache[sh] = ai
        aa, bb, cc, dd, tx, ty, tz = el['mat']
        pts = []
        for (x, y, z, u, v, w) in verts:
            # 仿射变换：先矩阵，再平移（与原版一致，tx/ty 不并入矩阵）
            nx = aa * x + bb * y + tx
            ny = cc * x + dd * y + ty
            pts.append((nx, ny, u, v, z))
        polys.append((tz, pts, ai))

    if not polys:
        return None, '该帧没有可绘制的 element'

    # ---- 算整体包围盒 ----
    xs = [p[0] for _, pts, _a in polys for p in pts]
    ys = [p[1] for _, pts, _a in polys for p in pts]
    minx, maxx = min(xs), max(xs)
    miny, maxy = min(ys), max(ys)
    w = int(maxx - minx) + pad * 2
    h = int(maxy - miny) + pad * 2
    if w <= 0 or h <= 0:
        return None, '包围盒为空'
    scale = 1.0
    if max(w, h) > max_size:
        scale = max_size / max(w, h)
        w, h = int(w * scale), int(h * scale)
        if w < 1 or h < 1:
            return None, '缩放后尺寸非法'

    canvas = bytearray(w * h * 4)
    offx = -minx + pad
    # ★ y 方向：数据里 **y 越大越靠下**（即屏幕坐标系）。
    #   判据来自 charlie idle 的部件 ty 排序（语义可验证）：
    #       ch_hat −702  →  ch_features −443  →  ch_mouth −356  →  ch_head −349
    #       →  ch_arm −307  →  ch_bod −292  →  ch_dress −231/−219  →  ch_hand −177
    #       →  ch_dress_light −76
    #   帽子在最上、裙摆在最下 —— 说明 ty 越负越靠上，也就是 y 向下为正。
    #   ⚠️ 文档里那句「引擎绘制时会垂直翻转图像，因此输出 Y 会被反转」
    #      容易让人以为要再翻一次；实际数据已经是屏幕方向，**不要再翻**。
    #      我先前按「y 向上」处理，结果把帽子画到了脚底下。
    offy = -miny + pad

    def to_canvas(x, y):
        # y 向下为正（见上方 offy 处的说明）
        return ((x + offx) * scale, (y + offy) * scale)

    # ---- 光栅化（按 tz 从远到近）----
    polys.sort(key=lambda t: t[0])
    import math

    def draw_tri(p0, p1, p2, tex):
        """三个顶点各自带 (x, y, u, v)，按重心坐标插值 UV —— 这是**严格正确**的做法。

        ⚠️ 早前我用「包围盒 + 按位置比例插值 UV」的近似，那隐含假设了
           「UV 与位置同向且轴对齐」。虽然 DST 的精灵多是轴对齐四边形，
           但一旦有旋转/翻转，近似就会画出错位的图。顶点里本来就带 UV，
           按三角形重心插值不需要任何假设。
        """
        (x0, y0, u0, v0) = p0
        (x1, y1, u1, v1) = p1
        (x2, y2, u2, v2) = p2
        cx0, cy0 = to_canvas(x0, y0)
        cx1, cy1 = to_canvas(x1, y1)
        cx2, cy2 = to_canvas(x2, y2)

        minx_ = int(math.floor(min(cx0, cx1, cx2)))
        maxx_ = int(math.ceil(max(cx0, cx1, cx2)))
        miny_ = int(math.floor(min(cy0, cy1, cy2)))
        maxy_ = int(math.ceil(max(cy0, cy1, cy2)))
        minx_ = max(0, minx_); miny_ = max(0, miny_)
        maxx_ = min(w, maxx_); maxy_ = min(h, maxy_)
        if maxx_ <= minx_ or maxy_ <= miny_:
            return

        denom = (cy1 - cy2) * (cx0 - cx2) + (cx2 - cx1) * (cy0 - cy2)
        if abs(denom) < 1e-9:
            return
        inv = 1.0 / denom
        for py in range(miny_, maxy_):
            fy = py + 0.5
            for px in range(minx_, maxx_):
                fx = px + 0.5
                a = ((cy1 - cy2) * (fx - cx2) + (cx2 - cx1) * (fy - cy2)) * inv
                b = ((cy2 - cy0) * (fx - cx2) + (cx0 - cx2) * (fy - cy2)) * inv
                c = 1.0 - a - b
                if a < -1e-4 or b < -1e-4 or c < -1e-4:
                    continue
                u = a * u0 + b * u1 + c * u2
                v = a * v0 + b * v1 + c * v2
                r, g, bl, al = sample(tex, u, v)
                if al < 8:
                    continue
                i = (py * w + px) * 4
                a0 = al / 255.0
                canvas[i] = int(r * a0 + canvas[i] * (1 - a0))
                canvas[i + 1] = int(g * a0 + canvas[i + 1] * (1 - a0))
                canvas[i + 2] = int(bl * a0 + canvas[i + 2] * (1 - a0))
                canvas[i + 3] = min(255, int(al + canvas[i + 3] * (1 - a0)))

    for poly in polys:
        # poly = (tz, pts, atlas_idx)
        pts = poly[1]
        pts2 = [(x, y, u, v) for (x, y, u, v, _z) in pts]
        # ★ 每个 poly 自带图集下标（见上面收集段）。
        #   旧代码写死 `tex = texs[0]` —— 多图集 build（pig_build 有
        #   atlas-0 2048² + atlas-1 1024×512）里，属于 atlas-1 的符号会拿
        #   atlas-0 的纹理去采样，UV 越界或采到完全无关的像素 → 满屏噪点。
        ai = poly[2] if len(poly) > 2 else 0
        tex = texs[ai if 0 <= ai < len(texs) else 0]
        n = len(pts2)
        # ★ 顶点池是**三角形列表**：每 3 个连续顶点 = 1 个三角形。
        #   旧代码只画了前 2 个三角形，nv 越大丢得越多：
        #       pig_head  nv=24  → 8 个三角形只画 2 个
        #       face      nv=12  → 4 个只画 2 个（所以只有眼睛清楚）
        #       hair      nv=114 → 38 个只画 2 个（所以头发是一条条条纹）
        #   这正是「渲染出来是噪点/残件」的根因 —— 数据是对的，光栅化漏画。
        #   （顶点数据已与 export_anim.py 的产出逐字节比对一致，见 _probe_rfverts.py）
        if n >= 3:
            for i in range(0, n - 2, 3):
                draw_tri(pts2[i], pts2[i + 1], pts2[i + 2], tex)
    return (w, h, bytes(canvas)), None


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print('用法: render_frame.py <zip> <输出目录> [动画名] [帧号]')
        sys.exit(1)
    zp, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    bundle = load_bundle(zp)
    b, a, texs = bundle
    base = os.path.splitext(os.path.basename(zp))[0]
    print(f'  build={b["name"]} 符号={len(b["symbols"])} '
          f'动画={len(a["anims"])} 图集={[t["w"] for t in texs]}')

    targets = []
    if len(sys.argv) > 3:
        targets = [(sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 0)]
    else:
        # 自动挑一个元素最多的动画，画出前 4 帧
        best = max(a['anims'],
                   key=lambda x: max((f['n_elements'] for f in x['frames']),
                                     default=0))
        targets = [(best['name'], i) for i in range(min(4, len(best['frames'])))]

    for an, fi in targets:
        res, err = render_frame(bundle, an, fi)
        if err:
            print(f'  ✘ {an}[{fi}] {err}')
            continue
        w, h, rgba = res
        out = os.path.join(outdir, f'{base}__{an}_{fi}.png')
        write_png(out, w, h, rgba)
        nz = sum(1 for i in range(3, len(rgba), 4) if rgba[i] > 8)
        print(f'  ✔ {an}[{fi}] → {out}  ({w}×{h}, 可见像素 {nz})')
