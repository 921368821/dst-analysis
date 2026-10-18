# -*- coding: utf-8 -*-
"""
search_build_exact.py —— 用「守恒」精确锁定 BILD 的剩余字段

已知确定的部分（多样本一致 + 官方字段表）：
    version | total_symbols | total_frames | build_name
    num_materials | material_texture_name × n
    symbols × total_symbols { hash | num_frames | frames × n }
        frame: num(i32) | duration(i32) | bbox(4×f32) | ???

待定的是 bbox 之后到顶点列表之间有几个 i32、以及每个顶点几个 float。

判据只有一条，但很硬：
    **逐字节读完必须正好落在文件末尾**（不许越界、不许有剩余）
    且要在多个不同 build 上同时成立。
"""
import struct
import zipfile
import glob
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


class R:
    def __init__(self, d, o=0):
        self.d, self.o, self.n = d, o, len(d)

    def i32(self):
        if self.o + 4 > self.n:
            raise EOFError
        v = struct.unpack_from('<i', self.d, self.o)[0]
        self.o += 4
        return v

    def f32(self):
        if self.o + 4 > self.n:
            raise EOFError
        v = struct.unpack_from('<f', self.d, self.o)[0]
        self.o += 4
        return v

    def s(self):
        n = self.i32()
        if n < 0 or n > 4096 or self.o + n > self.n:
            raise EOFError
        b = self.d[self.o:self.o + n]
        self.o += n
        return b.decode('utf-8', 'replace')


def attempt(data, extra_i32, vfloats, count_field):
    """extra_i32 : bbox 之后、顶点列表之前要跳过的 i32 个数
       vfloats   : 每个顶点几个 float
       count_field : 用第几个 i32 当顶点数（0 = extra_i32 中的第一个）
    """
    r = R(data, 4)
    try:
        r.i32()                     # version
        n_tsym = r.i32()
        r.i32()                     # total_frames
        r.s()                       # name
        n_mat = r.i32()
        if not (0 <= n_mat <= 64):
            return None
        for _ in range(n_mat):
            r.s()
        if not (0 <= n_tsym <= 20000):
            return None
        for _ in range(n_tsym):
            r.i32()                 # symbol hash
            nf = r.i32()
            if not (0 <= nf <= 20000):
                return None
            for _ in range(nf):
                r.i32()             # frame num
                r.i32()             # duration
                for _ in range(4):  # bbox
                    r.f32()
                vals = []
                for _ in range(extra_i32):
                    vals.append(r.i32())
                if count_field >= len(vals):
                    return None
                nv = vals[count_field]
                if not (0 <= nv <= 20000):
                    return None
                for _ in range(nv):
                    for _ in range(vfloats):
                        r.f32()
        ns = r.i32()
        if not (0 <= ns <= 20000):
            return None
        for _ in range(ns):
            r.i32()
            r.s()
        return r.o
    except (EOFError, Exception):
        return None


def main():
    files = sorted(glob.glob('_animtest/*.zip'))
    samples = []
    for p in files:
        try:
            z = zipfile.ZipFile(p)
        except Exception:
            continue
        if 'build.bin' not in z.namelist():
            continue
        samples.append((os.path.basename(p), z.read('build.bin')))
    print(f'样本数（含 build.bin 的 zip）: {len(samples)}')
    print()

    wins = Counter()
    detail = {}
    for extra in (1, 2, 3):
        for vf in (4, 5, 6, 7, 8):
            for cf in range(extra):
                ok = 0
                for nm, d in samples:
                    c = attempt(d, extra, vf, cf)
                    if c == len(d):
                        ok += 1
                if ok:
                    wins[(extra, vf, cf)] = ok
                    detail[(extra, vf, cf)] = ok / len(samples)

    if not wins:
        print('✘ 没有组合能在任何样本上守恒')
        return
    print('按「守恒成功的样本数」排序:')
    for (extra, vf, cf), ok in wins.most_common(12):
        print(f'  bbox后跳{extra}个i32  顶点{vf}个float  用第{cf}个当计数 '
              f'→ {ok}/{len(samples)} 个样本守恒 '
              f'({ok / len(samples) * 100:.0f}%)')


if __name__ == '__main__':
    main()
