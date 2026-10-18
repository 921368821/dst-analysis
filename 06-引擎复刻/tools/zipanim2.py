#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
zipanim2.py —— 按**官方字段表**实现的 ZipAnim 解析器（BILD v6 / ANIM v4）

字段表来源
    Klei 自家 mod 工具脚本 `mod_tools/tools/scripts/buildanimation.py`
    顶部的注释（随游戏发布的脚本，论坛有原文引用）。核心字段：

    BILD v6
        'BILD' | version | total_symbols | total_frames | build_name
        num_materials | material_texture_name × num_materials
        symbols × total_symbols {
            symbol_hash
            num_frames
            frames × num_frames {
                frame_num | frame_duration
                bbox: x, y, w, h (4 floats)
                vb_start_index | num_verts | num_vertices
                vertices × num_vertices { x, y, z, u, v, w } (6 floats)
            }
        }
        num_hashed_strings | (hash | original_string) × n

    ANIM v4
        'ANIM' | version | total_num_element_refs | total_num_frames
              | total_num_events | num_anims
        anims × num_anims {
            animname | validfacings(byte) | rootsymbolhash
            frame_rate(float) | num_frames
            frames × num_frames {
                x, y, w, h (4 floats)
                num_events | event_hash × num_events
                num_elements
                elements × num_elements {
                    symbol_hash | symbol_frame | folder_hash
                    mat a, b, c, d, tx, ty, tz (7 floats)
                }
            }
        }
        num_hashed_strings | (hash | original_string) × n

    ★ 关键：文件末尾有一张「哈希 → 原始字符串」表，符号名/图集名都在那里 ——
      这解释了为什么之前用字符串扫描能捞出符号名。

本模块与 zipanim.py 的关系
    zipanim.py 是**纯观测**推导版（已解码部分经过 127 样本验证）；
    本文件是**按官方字段表**实现版。两者应当互相印证 ——
    凡是有冲突的地方，都以「守恒约束能否满足」为准。
"""
import struct
import sys


class R:
    def __init__(self, d, o=0):
        self.d, self.o = d, o

    def u8(self):
        v = self.d[self.o]
        self.o += 1
        return v

    def i32(self):
        v = struct.unpack_from('<i', self.d, self.o)[0]
        self.o += 4
        return v

    def f32(self):
        v = struct.unpack_from('<f', self.d, self.o)[0]
        self.o += 4
        return v

    def s(self):
        n = self.i32()
        if n < 0 or n > 65536:
            raise ValueError(f'字符串长度异常 {n} @ {self.o - 4}')
        b = self.d[self.o:self.o + n]
        self.o += n
        return b.decode('utf-8', 'replace')

    def at_end(self):
        return self.o == len(self.d)


class ParseError(Exception):
    pass


# =============================================================================
# BILD
# =============================================================================
def parse_build(data):
    r = R(data)
    if data[:4] != b'BILD':
        raise ParseError('魔术数不是 BILD')
    r.o = 4
    version = r.i32()
    total_symbols = r.i32()
    total_frames = r.i32()
    build_name = r.s()
    num_materials = r.i32()
    materials = [r.s() for _ in range(num_materials)]

    symbols = []
    for _ in range(total_symbols):
        shash = r.i32()
        nframes = r.i32()
        if not (0 <= nframes <= 100000):
            raise ParseError(f'帧数异常 {nframes}')
        frames = []
        for _ in range(nframes):
            fnum = r.i32()
            fdur = r.i32()
            x, y, w, h = r.f32(), r.f32(), r.f32(), r.f32()
            vb_start = r.i32()
            n_verts = r.i32()
            n_vertices = r.i32()
            verts = []
            for _ in range(n_vertices):
                verts.append((r.f32(), r.f32(), r.f32(),
                              r.f32(), r.f32(), r.f32()))
            frames.append(dict(num=fnum, duration=fdur, bbox=(x, y, w, h),
                               vb_start=vb_start, n_verts=n_verts,
                               n_vertices=n_vertices, verts=verts))
        symbols.append(dict(hash=shash, frames=frames))

    n_strings = r.i32()
    hashed = []
    for _ in range(n_strings):
        hh = r.i32()
        ss = r.s()
        hashed.append((hh, ss))

    return dict(version=version, total_symbols=total_symbols,
                total_frames=total_frames, name=build_name,
                materials=materials, symbols=symbols,
                hashed_strings=hashed,
                consumed=r.o, total_size=len(data),
                exact=(r.o == len(data)))


# =============================================================================
# ANIM
# =============================================================================
def parse_anim(data):
    r = R(data)
    if data[:4] != b'ANIM':
        raise ParseError('魔术数不是 ANIM')
    r.o = 4
    version = r.i32()
    total_elements = r.i32()
    total_frames = r.i32()
    total_events = r.i32()
    num_anims = r.i32()

    if not (0 <= num_anims <= 100000):
        raise ParseError(f'动画数异常 {num_anims}')

    anims = []
    for _ in range(num_anims):
        name = r.s()
        validfacings = r.u8()
        rootsymhash = r.i32()
        framerate = r.f32()
        nframes = r.i32()
        if not (0 <= nframes <= 100000):
            raise ParseError(f'帧数异常 {nframes} @ {name}')
        frames = []
        for _ in range(nframes):
            x, y, w, h = r.f32(), r.f32(), r.f32(), r.f32()
            nevents = r.i32()
            if not (0 <= nevents <= 100000):
                raise ParseError(f'事件数异常 {nevents} @ {name}')
            events = [r.i32() for _ in range(nevents)]
            nelements = r.i32()
            if not (0 <= nelements <= 100000):
                raise ParseError(f'元素数异常 {nelements} @ {name}')
            elements = []
            for _ in range(nelements):
                elements.append(dict(
                    symbol_hash=r.i32(),
                    symbol_frame=r.i32(),
                    folder_hash=r.i32(),
                    mat=(r.f32(), r.f32(), r.f32(), r.f32(),
                         r.f32(), r.f32(), r.f32()),
                ))
            frames.append(dict(rect=(x, y, w, h), events=events,
                               elements=elements))
        anims.append(dict(name=name, validfacings=validfacings,
                          rootsymhash=rootsymhash, framerate=framerate,
                          frames=frames))

    n_strings = r.i32()
    hashed = []
    for _ in range(n_strings):
        hh = r.i32()
        ss = r.s()
        hashed.append((hh, ss))

    return dict(version=version, total_elements=total_elements,
                total_frames=total_frames, total_events=total_events,
                anims=anims, hashed_strings=hashed,
                consumed=r.o, total_size=len(data),
                exact=(r.o == len(data)))


if __name__ == '__main__':
    import zipfile
    import os
    p = sys.argv[1]
    z = zipfile.ZipFile(p)
    print(f'══ {os.path.basename(p)} ══')
    if 'build.bin' in z.namelist():
        b = parse_build(z.read('build.bin'))
        print(f'  BILD v{b["version"]} name={b["name"]}')
        print(f'    total_symbols={b["total_symbols"]} '
              f'total_frames={b["total_frames"]}')
        print(f'    materials={b["materials"]}')
        print(f'    实际符号={len(b["symbols"])}  '
              f'字符串表={len(b["hashed_strings"])}')
        print(f'    消耗 {b["consumed"]}/{b["total_size"]}  '
              f'守恒={"✔" if b["exact"] else "✘"}')
        for i, s in enumerate(b["symbols"][:3]):
            print(f'      [{i}] hash=0x{s["hash"] & 0xFFFFFFFF:08x} '
                  f'帧={len(s["frames"])} '
                  f'首帧bbox={tuple(round(v,1) for v in s["frames"][0]["bbox"]) if s["frames"] else "-"}')
    if 'anim.bin' in z.namelist():
        a = parse_anim(z.read('anim.bin'))
        print(f'  ANIM v{a["version"]}')
        print(f'    total_elements={a["total_elements"]} '
              f'total_frames={a["total_frames"]} '
              f'total_events={a["total_events"]}')
        print(f'    动画={len(a["anims"])}  字符串表={len(a["hashed_strings"])}')
        print(f'    消耗 {a["consumed"]}/{a["total_size"]}  '
              f'守恒={"✔" if a["exact"] else "✘"}')
        for an in a["anims"][:4]:
            print(f'      {an["name"]:<22} 帧={len(an["frames"])} '
                  f'rate={an["framerate"]:.0f}')
