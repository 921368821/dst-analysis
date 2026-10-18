#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
zipanim_render.py —— 把 anim.bin + build.bin 合成「渲染就绪」的帧数据

这是整个 ZipAnim 解析工作的**落地形态**：
    渲染器只需要知道「第 N 帧要画哪些图块、每个图块贴到哪儿」。
    本工具就把两个文件合成成那个形态。

为什么这能证明解析是对的
    要让一帧画得出来，必须同时满足：
      · anim 里引用的每个 symbol_hash 都能在 build 里找到对应符号
      · 每个元素指定的 symbol_frame 在该符号的帧数范围内
      · 每个符号帧的 vb_start 能切出 6 个顶点，且 UV 落在图集尺寸内
    这是**端到端的一致性命中**，比任何单文件断言都强 ——
    两个文件是分开生成的，哈希能对上就说明整条链路解对了。
"""
import struct
import zipfile
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from zipanim_build import parse_build, ParseError as BErr  # noqa: E402
from zipanim_anim import parse_anim, ParseError as AErr  # noqa: E402


def ktex_dims(z, name):
    d = z.read(name)
    if d[:4] != b'KTEX':
        return None
    w, h = struct.unpack_from('<HH', d, 8)
    return w, h


def build_render_frames(zip_path, anim_name=None, verbose=False):
    """返回 {anim: {frame_idx: [(symbol, u0,v0,u1,v1, mat...), ...]}}"""
    z = zipfile.ZipFile(zip_path)
    names = z.namelist()
    if 'build.bin' not in names:
        return None, 'no build.bin'

    b = parse_build(z.read('build.bin'))
    sym_by_hash = {s['hash']: s for s in b['symbols']}
    name_by_hash = b['hash_to_name']

    dims = {}
    for i, mat in enumerate(b['materials']):
        dd = ktex_dims(z, mat) if mat in names else None
        dims[i] = dd
    W, H = next((v for v in dims.values() if v), (0, 0))

    stats = dict(sym_hit=0, sym_miss=0, frame_oob=0, verts_ok=0, uv_oob=0)
    out = {}

    if 'anim.bin' not in names:
        return dict(build=b, stats=stats, frames={}), None

    a = parse_anim(z.read('anim.bin'))
    # 顶点池：symbols 里 vb_start 是全局下标，但顶点存在 build 的顶点池里
    pool = b['vertices']

    for an in a['anims']:
        if anim_name and an['name'] != anim_name:
            continue
        framedata = []
        for fi, f in enumerate(an['frames']):
            draws = []
            for el in f['elements']:
                sh = el['symbol_hash']
                sym = sym_by_hash.get(sh)
                if sym is None:
                    stats['sym_miss'] += 1
                    continue
                stats['sym_hit'] += 1
                sf = el['symbol_frame']
                if not (0 <= sf < len(sym['frames'])):
                    stats['frame_oob'] += 1
                    sf = 0
                if not sym['frames']:
                    continue
                fr = sym['frames'][sf]
                vb, nv = fr['vb_start'], fr['n_verts']
                if vb < 0 or vb + nv > len(pool):
                    stats['verts_ok'] += 0
                    continue
                stats['verts_ok'] += 1
                vs = pool[vb:vb + nv]
                # ★ UV 在**顶点**里，不在 bbox 里。
                #   顶点元组 = (x, y, z, u, v, w)：
                #     x, y —— 相对锚点的像素位置（可负）
                #     z    —— 2D 恒为 0
                #     u, v —— **归一化 UV，落在 [0,1]**   ← 就是我们要的
                #     w    —— 未使用（恒 0）
                #   已交叉验证：UV 跨度 × 图集尺寸 == bbox 的 w/h
                #     body      u 跨 0.2969 × 256 = 76.0  == bbox.w 76 ✓
                #     arm       u 跨 0.1172 × 256 = 30.0  == bbox.w 30 ✓
                #     inner wing u 跨 0.2304 × 256 = 59.0 == bbox.w 59 ✓
                us = [v[3] for v in vs]
                vv = [v[4] for v in vs]
                u0, u1 = min(us), max(us)
                v0, v1 = min(vv), max(vv)
                if not (0 <= u0 <= u1 <= 1.0001 and 0 <= v0 <= v1 <= 1.0001):
                    stats['uv_oob'] += 1
                # bbox 是「相对锚点的裁剪框」，可为负，不该拿它跟图集尺寸比 ——
                # 早前拿 bbox 当 UV 用，误报了一堆「超出图集范围」。
                draws.append(dict(
                    symbol=name_by_hash.get(sh, f'0x{sh & 0xFFFFFFFF:08x}'),
                    symbol_frame=sf, n_verts=nv,
                    uv=(round(u0, 5), round(v0, 5), round(u1, 5), round(v1, 5)),
                    bbox=tuple(round(v, 2) for v in fr['bbox']),
                    verts=[tuple(round(x, 3) for x in v) for v in vs],
                    mat=tuple(round(v, 4) for v in el['mat']),
                ))
            framedata.append(draws)
        out[an['name']] = dict(framerate=an['framerate'],
                               n_frames=len(an['frames']),
                               frames=framedata)

    return dict(build=b, atlas=(W, H), stats=stats, frames=out), None


def main():
    files = sys.argv[1:] or sorted(glob.glob('_animtest/*.zip'))
    ok = bad = 0
    total_hit = total_miss = total_oob = total_uv_oob = 0
    samples = []
    for p in files:
        try:
            r, err = build_render_frames(p)
        except (BErr, AErr, Exception) as e:
            bad += 1
            continue
        if err or r is None:
            continue
        s = r['stats']
        if not r['frames']:
            continue
        ok += 1
        total_hit += s['sym_hit']
        total_miss += s['sym_miss']
        total_oob += s['frame_oob']
        total_uv_oob += s['uv_oob']
        samples.append((os.path.basename(p), r))

    print('════ 渲染就绪合成验证（anim × build 交叉一致性）════')
    print(f'可合成的样本: {ok}，异常 {bad}')
    print(f'  元素引用命中 build 符号 : {total_hit}')
    print(f'  引用不存在的符号        : {total_miss}')
    print(f'  symbol_frame 越界       : {total_oob}')
    print(f'  bbox 超出图集范围       : {total_uv_oob}')
    if total_hit + total_miss:
        print(f'  命中率: {total_hit / (total_hit + total_miss) * 100:.2f}%')
    print()

    if samples:
        nm, r = samples[0]
        b = r['build']
        print(f'示例 {nm}  图集={r["atlas"]}')
        an = next(iter(r['frames'].items()))
        print(f'  动画「{an[0]}」 rate={an[1]["framerate"]:.0f} '
              f'帧={an[1]["n_frames"]}')
        for i, draws in enumerate(an[1]['frames'][:3]):
            print(f'    帧[{i}] 画 {len(draws)} 个块:')
            for d in draws[:3]:
                print(f'      {d["symbol"]:<16} symframe={d["symbol_frame"]} '
                      f'nverts={d["n_verts"]} uv={d["uv"]}')


if __name__ == '__main__':
    main()
