# -*- coding: utf-8 -*-
"""
probe_ktex_exact.py —— 用体积守恒反推 KTEX 的头部长度与像素格式

硬约束（两条同时成立）
    C1  total_size − header_size == mip_chain(w, h, format)
        其中 DXT1 = 0.5 字节/像素（8 字节/4×4 块），DXT3/DXT5 = 1 字节/像素
        （16 字节/4×4 块）；每级 mip 至少 4×4
    C2  header_size 必须让「mip 表能装下」—— 表里每级通常 8 字节（宽高各 u16）
        或 4+4，所以 header_size >= 8 + 8×miplevels

做法
    扫 header_size 与 format 的组合，看哪一组在**多个样本**上同时满足 C1。
    满足的组合若唯一，就等于把两个未知量都定死了。
"""
import struct
import zipfile
import glob
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


def mip_chain_bytes(w, h, bytes_per_4x4):
    """返回从 w×h 开始、每级减半直到 4×4 的 mip 链总字节数"""
    total = 0
    ww, hh = w, h
    while ww >= 4 and hh >= 4:
        bw = max(4, ww)
        bh = max(4, hh)
        total += (bw // 4) * (bh // 4) * bytes_per_4x4
        if ww == 4 and hh == 4:
            break
        ww = max(4, ww // 2)
        hh = max(4, hh // 2)
        if ww == 4 and hh == 4:
            # 最后一层 4×4 已在上面加过，避免重复
            break
    return total


def probe(path):
    z = zipfile.ZipFile(path)
    out = []
    for nm in [n for n in z.namelist() if n.endswith('.tex')]:
        d = z.read(nm)
        if d[:4] != b'KTEX':
            continue
        w, h = struct.unpack_from('<HH', d, 8)
        total = len(d)
        hits = []
        for hs in range(8, 400, 1):
            body = total - hs
            if body <= 0:
                break
            for fmtname, b4 in (('DXT1', 8), ('DXT3/5', 16), ('RGBA8', 64)):
                if mip_chain_bytes(w, h, b4) == body:
                    hits.append((hs, fmtname))
        out.append((nm, w, h, total, hits))
    return out


def main():
    files = sorted(glob.glob('_animtest/*.zip'))
    print('════ KTEX 头部长度 + 像素格式 反推 ════')
    print()
    cnt = Counter()
    samples = 0
    for p in files:
        try:
            res = probe(p)
        except Exception:
            continue
        for nm, w, h, total, hits in res:
            samples += 1
            for hs, fmt in hits:
                cnt[(hs, fmt)] += 1
            if len(hits) and samples <= 8:
                print(f'  {os.path.basename(p)[:32]:<34} {nm} {w}×{h} '
                      f'总={total}B → 候选 {hits}')
    print()
    print(f'共 {samples} 个 tex 样本')
    print('候选组合命中次数（前 12）:')
    for (hs, fmt), n in cnt.most_common(12):
        print(f'  header_size={hs:<5} format={fmt:<8} → {n} 次')


if __name__ == '__main__':
    main()
