#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全库扫 KTEX 头，找「像素格式」到底存在哪个字段。

为什么要扫全库
    ktex.py 里的 DXT5 是**推断**出来的（每字节像素比 = 1.00 + alpha 段结构），
    不是从某个格式字段读出来的。推断法的问题：只要出现一张 DXT1/DXT3 的纹理，
    解码结果就是错的，而且**不会报错**（体积守恒等式照样成立，因为 pitch/size
    都是文件里写着的事实）。

    所以本脚本用「找反例」的方式：把全库每张 KTEX 的
        bpp = mip0.size / (mip0.w * mip0.h)
    算出来，按 (flag 常量, pitch 公式, bpp) 分组。
    若某组的 bpp ≠ 1.00，那就是非 DXT5，DXT5 假设被证伪。

同时把 header 里所有可能的「格式位」候选都列出来做交叉验证。
"""
import glob
import os
import struct
import sys
import zipfile
from collections import Counter

ANIM = "D:/Program Files (x86)/Steam/steamapps/common/Don't Starve Together/data/anim"


def ktex_headers(data):
    """返回 (flag, [mip...])，mip 是 (w, h, pitch, size)"""
    if data[:4] != b'KTEX':
        return None, None
    flag = struct.unpack_from('<I', data, 4)[0]
    mips = []
    o = 8
    while o + 10 <= len(data):
        w, h, pitch, size = struct.unpack_from('<HHHI', data, o)
        if w == 0 or w > 16384 or h == 0 or h > 16384 or size == 0:
            break
        mips.append((w, h, pitch, size))
        o += 10
    return flag, mips


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    files = sorted(glob.glob(os.path.join(ANIM, '*.zip')))
    if limit:
        files = files[:limit]
    print('扫 %d 个包 ...' % len(files))

    n_tex = 0
    flag_counter = Counter()
    bpp_counter = Counter()
    pitch_bpp_counter = Counter()
    header_len_ok = 0
    header_len_bad = 0
    examples = {}

    for p in files:
        try:
            z = zipfile.ZipFile(p)
        except Exception:
            continue
        for name in z.namelist():
            if not name.endswith('.tex'):
                continue
            try:
                data = z.read(name)
            except Exception:
                continue
            flag, mips = ktex_headers(data)
            if flag is None or not mips:
                continue
            n_tex += 1
            flag_counter[flag] += 1

            w0, h0, pitch0, size0 = mips[0]
            bpp = size0 / float(w0 * h0)
            bpp_counter[round(bpp, 4)] += 1
            # pitch / (w/4) 是「每块的字节数」：DXT 系是 16，DXT1 是 8
            per_block = pitch0 / max(w0 // 4, 1)
            pitch_bpp_counter[round(per_block, 2)] += 1
            key = (flag, per_block, round(bpp, 4))
            if key not in examples:
                examples[key] = '%s :: %s  %dx%d' % (os.path.basename(p), name, w0, h0)

            # 体积守恒：头长 + 各级 size 之和 == 文件大小？
            tot = sum(m[3] for m in mips)
            head = 8 + len(mips) * 10
            if head + tot == len(data):
                header_len_ok += 1
            else:
                header_len_bad += 1

    print('KTEX 样本数 = %d' % n_tex)
    print('')
    print('=== flag 常量分布（+4 的 u32）===')
    for v, c in flag_counter.most_common():
        print('  0x%08X  ×%-6d' % (v, c))
    print('')
    print('=== 每像素字节比 bpp（mip0.size / w*h）===')
    for v, c in bpp_counter.most_common():
        tag = 'DXT3/DXT5 系（1 B/px）' if abs(v - 1.0) < 1e-6 else (
              'DXT1 系（0.5 B/px）' if abs(v - 0.5) < 1e-6 else '★ 未知')
        print('  %.4f  ×%-6d  %s' % (v, c, tag))
    print('')
    print('=== 每块字节数 pitch/(w/4) ===')
    for v, c in pitch_bpp_counter.most_common():
        tag = 'DXT3/5（16 B/块）' if abs(v - 16) < 1e-6 else (
              'DXT1（8 B/块）' if abs(v - 8) < 1e-6 else '★ 未知')
        print('  %-8.2f ×%-6d  %s' % (v, c, tag))
    print('')
    print('=== 体积守恒（头长 + Σsize == 文件大小）===')
    print('  成立 %d / 不成立 %d' % (header_len_ok, header_len_bad))
    print('')
    print('=== 每个 (flag, 每块字节, bpp) 组合的一个样例 ===')
    for k, v in sorted(examples.items(), key=lambda x: -flag_counter.get(x[0][0], 0))[:12]:
        print('  0x%08X 每块%-5.1f bpp=%-6.4f  %s' % (k[0], k[1], k[2], v))


if __name__ == '__main__':
    main()