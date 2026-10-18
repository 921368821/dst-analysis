#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
zipanim_anim.py —— ANIM v4 **完整**解析

格式（字段表来自 Klei 自家 mod 工具脚本 buildanimation.py 的注释）

    'ANIM' (char[4])
    version                : i32
    total_num_element_refs : i32
    total_num_frames       : i32
    total_num_events       : i32
    num_anims              : i32
    anims × num_anims {
        animname           : str
        validfacings       : byte      -- 位掩码 xxxx dlur（下左上右）
        rootsymbolhash     : i32
        frame_rate         : f32
        num_frames         : i32
        frames × num_frames {
            x, y, w, h     : f32 × 4   -- 该帧整体包围盒
            num_events     : i32
            event_hash     : i32 × num_events
            num_elements   : i32
            elements × num_elements {
                symbol_hash : i32
                symbol_frame: i32      -- 该符号用第几帧（对应 build 里的 frame）
                folder_hash : i32      -- 图层分组（对应 build 的文件夹）
                mat a,b,c,d,tx,ty,tz : f32 × 7
            }                          -- 定长 12 + 28 = 40 字节
        }
    }
    num_hashed_strings     : i32
    ( hash : i32, original_string : str ) × n

    ★ 尾部那张「哈希 → 字符串」表就是动画名 / 符号名 / 图层名的来源。
      它和 BILD 用的是同一套哈希 —— 所以 build 与 anim 能对上号。

关于 mat
    元素里的 mat 是给顶点着色器的 2×2 变换矩阵 + 平移：
        [ a  b ]        sx = 水平缩放
        [ c  d ]        sy = 垂直缩放
        （tx, ty）      θ  = 旋转角
        tz              —— 2D 用不到，保留字段
    引擎会预先算好缩放与旋转，渲染时直接乘，省 CPU。
"""
import struct


class ParseError(Exception):
    pass


class R:
    def __init__(self, d, o=0):
        self.d, self.o, self.n = d, o, len(d)

    def u8(self):
        if self.o + 1 > self.n:
            raise ParseError(f'越界 @{self.o}')
        v = self.d[self.o]
        self.o += 1
        return v

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


def parse_anim(data, max_elements=None):
    r = R(data)
    if data[:4] != b'ANIM':
        raise ParseError('魔术数不是 ANIM')
    r.o = 4
    version = r.i32()
    total_element_refs = r.i32()
    total_frames = r.i32()
    total_events = r.i32()
    n_anims = r.i32()
    if not (0 <= n_anims <= 100000):
        raise ParseError(f'动画数异常 {n_anims}')

    anims = []
    elem_total = 0
    for _ in range(n_anims):
        name = r.s()
        validfacings = r.u8()
        rootsymhash = r.i32()
        framerate = r.f32()
        nf = r.i32()
        if not (0 <= nf <= 100000):
            raise ParseError(f'帧数异常 {nf} @{name}')
        frames = []
        for _ in range(nf):
            x, y, w, h = r.f32(), r.f32(), r.f32(), r.f32()
            ne = r.i32()
            if not (0 <= ne <= 100000):
                raise ParseError(f'事件数异常 {ne} @{name}')
            events = [r.i32() for _ in range(ne)]
            nel = r.i32()
            if not (0 <= nel <= 200000):
                raise ParseError(f'元素数异常 {nel} @{name}')
            elem_total += nel
            elements = []
            keep = (max_elements is None or len(elements) < max_elements)
            for k in range(nel):
                sh = r.i32()
                sf = r.i32()
                fh = r.i32()
                mat = (r.f32(), r.f32(), r.f32(), r.f32(),
                       r.f32(), r.f32(), r.f32())
                if max_elements is None or k < max_elements:
                    elements.append(dict(symbol_hash=sh, symbol_frame=sf,
                                         folder_hash=fh, mat=mat))
                else:
                    pass
            frames.append(dict(rect=(x, y, w, h), events=events,
                               n_elements=nel, elements=elements))
        anims.append(dict(name=name, validfacings=validfacings,
                          rootsymhash=rootsymhash, framerate=framerate,
                          frames=frames))

    n_str = r.i32()
    if not (0 <= n_str <= 200000):
        raise ParseError(f'字符串表条数异常 {n_str}')
    hashed = []
    for _ in range(n_str):
        hh = r.i32()
        ss = r.s()
        hashed.append((hh, ss))

    return dict(
        version=version,
        total_element_refs=total_element_refs,
        total_frames=total_frames,
        total_events=total_events,
        anims=anims,
        elem_total=elem_total,
        hashed_strings=hashed,
        hash_to_name={h: s for h, s in hashed},
        consumed=r.o,
        total_size=len(data),
        exact=(r.o == len(data)),
    )


def check_invariants(a):
    """把头部声明的总数与实际解析出的数量对照 —— 这是最强的自证"""
    n_frames = sum(len(an['frames']) for an in a['anims'])
    n_events = sum(len(f['events']) for an in a['anims'] for f in an['frames'])
    return {
        'anims': (len(a['anims']), None),
        'frames': (n_frames, a['total_frames']),
        'events': (n_events, a['total_events']),
        'elements': (a['elem_total'], a['total_element_refs']),
    }


if __name__ == '__main__':
    import zipfile
    import glob
    import os
    import sys

    files = sys.argv[1:] or sorted(glob.glob('_animtest/*.zip'))
    ok = bad = 0
    fails = []
    inv_ok = inv_bad = 0
    for p in files:
        try:
            z = zipfile.ZipFile(p)
        except Exception:
            continue
        if 'anim.bin' not in z.namelist():
            continue
        try:
            a = parse_anim(z.read('anim.bin'))
        except ParseError as e:
            bad += 1
            fails.append((os.path.basename(p), str(e)))
            continue
        if a['exact']:
            ok += 1
            c = check_invariants(a)
            good = all(v[1] is None or v[0] == v[1] for v in c.values())
            if good:
                inv_ok += 1
            else:
                inv_bad += 1
                if len(fails) < 12:
                    fails.append((os.path.basename(p),
                                  f'数量不变式不符 {c}'))
        else:
            bad += 1
            fails.append((os.path.basename(p),
                          f"消耗 {a['consumed']}/{a['total_size']}"))

    print(f'ANIM v4 完整解析: 守恒通过 {ok}，失败 {bad}')
    print(f'  其中「头部声明数 == 实际解析数」不变式成立: {inv_ok}，不符 {inv_bad}')
    for nm, why in fails[:12]:
        print(f'  ✘ {nm:<40} {why}')
    if ok:
        p = [f for f in files if 'abigail_attack_fx' in f]
        p = p[0] if p else files[0]
        a = parse_anim(zipfile.ZipFile(p).read('anim.bin'))
        print()
        print(f'示例 {os.path.basename(p)}:')
        c = check_invariants(a)
        print(f'  动画={c["anims"][0]}  帧={c["frames"][0]}(声明{c["frames"][1]})  '
              f'事件={c["events"][0]}(声明{c["events"][1]})  '
              f'元素={c["elements"][0]}(声明{c["elements"][1]})')
        print(f'  字符串表={len(a["hashed_strings"])}')
        for an in a['anims'][:4]:
            f0 = an['frames'][0] if an['frames'] else None
            el = f0['elements'][0] if f0 and f0['elements'] else None
            print(f'    {an["name"]:<22} 帧={len(an["frames"]):<3} '
                  f'rate={an["framerate"]:.0f} '
                  f'首帧元素={f0["n_elements"] if f0 else "-"} '
                  f'首元素mat={tuple(round(v, 3) for v in el["mat"]) if el else "-"}')
