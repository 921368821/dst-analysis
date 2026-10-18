# -*- coding: utf-8 -*-
"""诊断 BILD 解析在哪一步偏离"""
import struct
import zipfile
import sys

sys.path.insert(0, '.')


class R:
    def __init__(self, d, o=0):
        self.d, self.o = d, o

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
        b = self.d[self.o:self.o + n]
        self.o += n
        return b.decode('utf-8', 'replace')


def diag(path, verbose=True):
    d = zipfile.ZipFile(path).read('build.bin')
    r = R(d, 4)
    ver = r.i32()
    n_tsym = r.i32()
    n_tframe = r.i32()
    name = r.s()
    n_mat = r.i32()
    mats = [r.s() for _ in range(n_mat)]
    print(f"  version={ver} total_symbols={n_tsym} total_frames={n_tframe} "
          f"name={name} materials={mats}")
    print(f"  符号区起点 @{r.o}")
    for si in range(n_tsym):
        base = r.o
        shash = r.i32()
        nf = r.i32()
        print(f"   符号[{si}] @{base} hash=0x{shash & 0xFFFFFFFF:08x} 帧数={nf}")
        if not (0 <= nf <= 10000):
            print(f"     ✘ 帧数不合理 → 结构假设在此处不成立")
            return
        for fi in range(nf):
            fbase = r.o
            fnum = r.i32()
            fdur = r.i32()
            x, y, w, h = r.f32(), r.f32(), r.f32(), r.f32()
            vb = r.i32()
            nv1 = r.i32()
            nv2 = r.i32()
            if verbose and fi < 2:
                print(f"     帧[{fi}] @{fbase} num={fnum} dur={fdur} "
                      f"bbox=({x:.1f},{y:.1f},{w:.1f},{h:.1f}) "
                      f"vb={vb} A={nv1} B={nv2}")
            if not (0 <= nv2 <= 10000):
                print(f"     ✘ 顶点数不合理 A={nv1} B={nv2}")
                return
            for _ in range(nv2):
                for _ in range(6):
                    r.f32()
    ns = r.i32()
    print(f"  字符串表: {ns} 条 @{r.o}")
    if not (0 <= ns <= 10000):
        print("   ✘ 字符串表条数不合理")
        return
    for _ in range(ns):
        r.i32()
        r.s()
    print(f"  消耗 {r.o}/{len(d)}  差 {len(d) - r.o}B  "
          f"{'✔ 守恒' if r.o == len(d) else '✘'}")


for p in sys.argv[1:]:
    print(f"══ {p} ══")
    try:
        diag(p)
    except Exception as e:
        print(f"   异常: {e}")
    print()
