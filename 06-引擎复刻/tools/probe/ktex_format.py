#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""判别 KTEX 用的到底是 DXT5 还是 DXT3 —— 二者体积完全相同，只能靠解码质量。

为什么不能靠体积/头字段
    DXT3 与 DXT5 都是 1 B/px、每块 16 B，文件头里也**没有格式字段**
    （380 个样本的每一个字节都被 magic / 尺寸级 / mip 表解释完了，
      见 tools/scan_ktex.py 的体积守恒 380/380）。
    所以只能从**数据本身**判别。

可证伪的判据
    精灵图集的 alpha 绝大多数是「完全透明 0」或「完全不透明 255」，
    只有边缘一圈抗锯齿是中间值。
      · 按 **DXT5** 解：前 2 字节是 8 位 alpha 端点 a0/a1，后 6 字节是 3 bit 索引
        —— 中间值只能取 8 档插值，边缘过渡会比较「台阶化」但整体干净。
      · 按 **DXT3** 解：前 8 字节是 16 个 4 bit 显式 alpha
        —— 若实际数据是 DXT5，这 16 个 nibble 会被当成 16 个 alpha，
          大量出现「半透明噪点」。
    ⇒ 统计解码后 alpha 落在 {0, 255} 之外的比例。**比例低的那一方才是对的。**
"""
import glob
import os
import struct
import sys
import zipfile
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
ANIM = "D:/Program Files (x86)/Steam/steamapps/common/Don't Starve Together/data/anim"


def ktex_first_mip(data):
    mips = []
    o = 8
    while o + 10 <= len(data):
        w, h, pitch, size = struct.unpack_from('<HHHI', data, o)
        if w == 0 or w > 16384 or h == 0 or h > 16384 or size == 0:
            break
        mips.append((w, h, pitch, size))
        o += 10
    if not mips:
        return None, None
    w, h, pitch, size = mips[0]
    start = 8 + len(mips) * 10
    return (w, h), data[start:start + size]


def alpha_hist_dxt5(block):
    a0, a1 = block[0], block[1]
    if a0 > a1:
        table = [a0, a1] + [round(((7 - i) * a0 + i * a1) / 7) for i in range(1, 7)]
    else:
        table = [a0, a1] + [round(((5 - i) * a0 + i * a1) / 5) for i in range(1, 5)] + [0, 255]
    bits = int.from_bytes(block[2:8], 'little')
    out = []
    for i in range(16):
        out.append(table[(bits >> (3 * i)) & 7])
    return out


def alpha_hist_dxt3(block):
    out = []
    for b in block[:8]:
        out.append((b & 0xF) * 17)
        out.append((b >> 4) * 17)
    return out


def scan(files, max_tex=60):
    res = {'dxt5_extreme': 0, 'dxt5_total': 0, 'dxt3_extreme': 0, 'dxt3_total': 0,
           'samples': []}
    n = 0
    for p in files:
        if n >= max_tex:
            break
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
            wh, blob = ktex_first_mip(data)
            if wh is None or len(blob) < 16:
                continue
            w, h = wh
            nb = (w // 4) * (h // 4)
            if nb == 0:
                continue
            # ★ 全图抽样（不是只取前 16 个块）：精灵图集的前若干块常整块透明，
            #   只看开头会得到「100% 干净」的假象，掩盖格式错误。
            #   按步长均匀撒 64 个块，覆盖整张图。
            take = min(64, nb)
            step = max(1, nb // take)
            e5 = t5 = e3 = t3 = 0
            for kk in range(take):
                k = kk * step
                blk = blob[k * 16:(k + 1) * 16]
                if len(blk) < 16:
                    break
                for a in alpha_hist_dxt5(blk):
                    t5 += 1
                    if a in (0, 255):
                        e5 += 1
                for a in alpha_hist_dxt3(blk):
                    t3 += 1
                    if a in (0, 255):
                        e3 += 1
            if t5 == 0:
                continue
            res['dxt5_extreme'] += e5
            res['dxt5_total'] += t5
            res['dxt3_extreme'] += e3
            res['dxt3_total'] += t3
            if len(res['samples']) < 8:
                res['samples'].append((os.path.basename(p), name, w, h,
                                       e5 / t5, e3 / t3))
            n += 1
            break
    return res


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 60
    files = sorted(glob.glob(os.path.join(ANIM, '*.zip')))[:400]
    res = scan(files, max_tex=limit)
    print('采样纹理数 = %d' % len(res['samples']) if res['samples'] else '0')
    print('')
    print('=== alpha 落在 {0,255} 之外的比例（越低越像「对的格式」）===')
    if res['dxt5_total']:
        print('  按 DXT5 解：非极端值占 %.2f%%' %
              (100.0 * (res['dxt5_total'] - res['dxt5_extreme']) / res['dxt5_total']))
    if res['dxt3_total']:
        print('  按 DXT3 解：非极端值占 %.2f%%' %
              (100.0 * (res['dxt3_total'] - res['dxt3_extreme']) / res['dxt3_total']))
    print('')
    print('=== 前几个样本（极端值占比，越高越干净）===')
    for nm, ent, w, h, r5, r3 in res['samples']:
        print('  %-34s %-12s %4dx%-4d  DXT5 %.1f%%   DXT3 %.1f%%'
              % (nm[:34], ent[:12], w, h, r5 * 100, r3 * 100))


if __name__ == '__main__':
    main()