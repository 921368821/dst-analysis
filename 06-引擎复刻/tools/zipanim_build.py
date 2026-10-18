#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
zipanim_build.py —— BILD v6 符号表**完整**解析（已全量验证）

格式（字段表来自 Klei 自家 mod 工具脚本 buildanimation.py 的注释，
     **布局细节由 41 个真实样本 + 哈希反查边界实证**）

    'BILD' (char[4])
    version                : i32
    total_symbols          : i32
    total_frames           : i32
    build_name             : str(i32 长度 + 字节)
    num_materials          : i32
    material_texture_name  : str × num_materials
    ── 符号区 ──
    symbols × total_symbols {
        hash               : i32
        num_frames         : i32
        frames × num_frames {
            frame_num      : i32
            duration       : i32     -- 该帧重复使用的次数（1 = 不重复）
            bbox: x, y, w, h : f32 × 4   -- 在图集里的像素矩形
            vb_start_index : i32     -- ★ 全局顶点池里的起始下标
            num_verts      : i32     -- 本帧用几个顶点
        }                            -- 定长 32 字节
    }
    ── 全局顶点池（只存一份）──
    total_vertices         : i32
    vertices × total_vertices { x, y, z, u, v, w } : f32 × 6   -- 定长 24 字节
    ── 哈希 → 原始字符串 ──
    num_hashed_strings     : i32
    ( hash : i32, original_string : str ) × n

★ 三个「破译靠的是守恒，不是猜」的关键点
    1. 符号条目**定长 32 字节**（num + duration + bbox(16) + vb_start + num_verts）
       → 由「符号长度 = 8 + nframes × 32」在 41 个样本上验证
    2. `vb_start_index` 是**全局顶点池的累计下标**，且每帧顶点数 = 下一帧的
       vb_start 减它 → 由 antlion 的累加序列 0,78,156,246,330,444,516,774,…
       一路累加到 1758 正好等于下一个符号的 vb_start 而确认
    3. 顶点池**独立于符号、只存一份** → 由「pinchers 长 168 = 8+5×32，不含顶点」
       与「最后一个符号后紧跟着 total_vertices + 池」共同确认
"""
import struct


class ParseError(Exception):
    pass


class R:
    def __init__(self, d, o=0):
        self.d, self.o, self.n = d, o, len(d)

    def i32(self):
        if self.o + 4 > self.n:
            raise ParseError(f'越界 @{self.o}')
        v = struct.unpack_from('<i', self.d, self.o)[0]
        self.o += 4
        return v

    def f32(self):
        if self.o + 4 > self.n:
            raise ParseError(f'越界 @{self.o}')
        v = struct.unpack_from('<f', self.d, self.o)[0]
        self.o += 4
        return v

    def s(self):
        n = self.i32()
        if n < 0 or n > 65536 or self.o + n > self.n:
            raise ParseError(f'字符串长度异常 {n} @{self.o - 4}')
        b = self.d[self.o:self.o + n]
        self.o += n
        return b.decode('utf-8', 'replace')


def parse_build(data, collect_vertices=True):
    r = R(data)
    if data[:4] != b'BILD':
        raise ParseError('魔术数不是 BILD')
    r.o = 4
    version = r.i32()
    total_symbols = r.i32()
    total_frames = r.i32()
    name = r.s()
    n_mat = r.i32()
    if not (0 <= n_mat <= 64):
        raise ParseError(f'材质数异常 {n_mat}')
    materials = [r.s() for _ in range(n_mat)]

    if not (0 <= total_symbols <= 100000):
        raise ParseError(f'符号数异常 {total_symbols}')

    sym_hdr_start = r.o
    symbols = []
    for _ in range(total_symbols):
        h = r.i32()
        nf = r.i32()
        if not (0 <= nf <= 100000):
            raise ParseError(f'帧数异常 {nf} @符号{len(symbols)}')
        frames = []
        for _ in range(nf):
            fnum = r.i32()
            dur = r.i32()
            x, y, w, hh = r.f32(), r.f32(), r.f32(), r.f32()
            vb = r.i32()
            nv = r.i32()
            frames.append(dict(num=fnum, duration=dur,
                               bbox=(x, y, w, hh), vb_start=vb, n_verts=nv))
        symbols.append(dict(hash=h, frames=frames))

    sym_hdr_end = r.o
    n_vertices = r.i32()
    if not (0 <= n_vertices <= 5000000):
        raise ParseError(f'顶点总数异常 {n_vertices}')
    verts = []
    if collect_vertices:
        for _ in range(n_vertices):
            verts.append((r.f32(), r.f32(), r.f32(),
                          r.f32(), r.f32(), r.f32()))
    else:
        r.o += n_vertices * 24

    n_str = r.i32()
    if not (0 <= n_str <= 100000):
        raise ParseError(f'字符串表条数异常 {n_str}')
    hashed = []
    for _ in range(n_str):
        hh = r.i32()
        ss = r.s()
        hashed.append((hh, ss))

    return dict(
        version=version,
        total_symbols=total_symbols,
        total_frames=total_frames,
        name=name,
        materials=materials,
        symbols=symbols,
        num_vertices=n_vertices,
        vertices=verts,
        hashed_strings=hashed,
        hash_to_name={h: s for h, s in hashed},
        sym_hdr_start=sym_hdr_start,
        sym_hdr_end=sym_hdr_end,
        consumed=r.o,
        total_size=len(data),
        exact=(r.o == len(data)),
    )


if __name__ == '__main__':
    import zipfile
    import glob
    import os
    import sys

    files = sys.argv[1:] or sorted(glob.glob('_animtest/*.zip'))
    ok = bad = 0
    fails = []
    for p in files:
        try:
            z = zipfile.ZipFile(p)
        except Exception:
            continue
        if 'build.bin' not in z.namelist():
            continue
        try:
            b = parse_build(z.read('build.bin'), collect_vertices=False)
        except ParseError as e:
            bad += 1
            fails.append((os.path.basename(p), str(e)))
            continue
        if b['exact']:
            ok += 1
        else:
            bad += 1
            fails.append((os.path.basename(p),
                          f"消耗 {b['consumed']}/{b['total_size']}"))
    print(f'BILD v6 完整解析: 守恒通过 {ok}，失败 {bad}')
    for nm, why in fails[:10]:
        print(f'  ✘ {nm:<40} {why}')
    if ok and not fails:
        p = [f for f in files if 'bee_build' in f]
        p = p[0] if p else files[0]
        b = parse_build(zipfile.ZipFile(p).read('build.bin'))
        print()
        print(f'示例 {os.path.basename(p)}: name={b["name"]}')
        print(f'  符号={len(b["symbols"])} 帧={b["total_frames"]} '
              f'顶点={b["num_vertices"]} 字符串={len(b["hashed_strings"])}')
        for s in b['symbols'][:8]:
            nm = b['hash_to_name'].get(s['hash'], f'<0x{s["hash"] & 0xFFFFFFFF:08x}>')
            f0 = s['frames'][0] if s['frames'] else None
            print(f'    {nm:<16} 帧={len(s["frames"])}  '
                  f'首帧 bbox={tuple(round(v, 1) for v in f0["bbox"]) if f0 else "-"} '
                  f'verts={f0["n_verts"] if f0 else "-"}')
