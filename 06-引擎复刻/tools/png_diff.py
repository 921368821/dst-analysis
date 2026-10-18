#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对照两张播放器截图，量化「符号覆盖」到底改了画面上的哪些区域。

为什么需要它（而不是肉眼看图）
    覆盖链路每一环都可能静默失败，而失败的样子都是「少一块」。
    但「有差异」还不够 —— 抗锯齿、atlas 重映射都可能造成零星差异。
    真正要证明的是：**差异聚成一块、位置与大小和帽子吻合**。
    所以做 4-邻接连通分量分析，报出最大块的尺寸与包围盒。

输入：两张同相机、同 tick、唯一变量是 world.json 的 `sigs` 的截图。
"""
import struct
import sys
import zlib


def readpng(p):
    d = open(p, 'rb').read()
    pos, idat, ct, w, h = 8, b'', 6, 0, 0
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            w, h, _bd, ct = struct.unpack('>IIBB', data[:10])
        elif typ == b'IDAT':
            idat += data
        pos += 12 + ln
    raw = zlib.decompress(idat)
    ch = 4 if ct == 6 else 3
    stride = w * ch
    out = bytearray(w * h * ch)
    prev = bytearray(stride)
    i = 0
    for y in range(h):
        f = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, ch, bytes(out)


def main():
    pa = sys.argv[1] if len(sys.argv) > 1 else '_out/_cmp_world_player.png'
    pb = sys.argv[2] if len(sys.argv) > 2 else '_out/_cmp__player_nosig.png'
    w, h, c, A = readpng(pa)
    w2, h2, c2, B = readpng(pb)
    if (w, h) != (w2, h2):
        print('尺寸不一致 %sx%s vs %sx%s' % (w, h, w2, h2))
        return 1

    mask = bytearray(w * h)
    total = 0
    for y in range(h):
        row = y * w
        for x in range(w):
            i = (row + x) * c
            if A[i:i + 3] != B[i:i + 3]:
                mask[row + x] = 1
                total += 1

    # 4-邻接 BFS 求连通分量
    seen = bytearray(w * h)
    comps = []
    for idx in range(w * h):
        if not mask[idx] or seen[idx]:
            continue
        stack = [idx]
        seen[idx] = 1
        n = 0
        x0, x1, y0, y1 = w, -1, h, -1
        while stack:
            cur = stack.pop()
            n += 1
            cy, cx = divmod(cur, w)
            if cx < x0: x0 = cx
            if cx > x1: x1 = cx
            if cy < y0: y0 = cy
            if cy > y1: y1 = cy
            if cx > 0 and mask[cur - 1] and not seen[cur - 1]:
                seen[cur - 1] = 1; stack.append(cur - 1)
            if cx < w - 1 and mask[cur + 1] and not seen[cur + 1]:
                seen[cur + 1] = 1; stack.append(cur + 1)
            if cy > 0 and mask[cur - w] and not seen[cur - w]:
                seen[cur - w] = 1; stack.append(cur - w)
            if cy < h - 1 and mask[cur + w] and not seen[cur + w]:
                seen[cur + w] = 1; stack.append(cur + w)
        comps.append((n, x0, x1, y0, y1))

    comps.sort(reverse=True)
    print('画面 %dx%d，差异像素合计 %d' % (w, h, total))
    print('连通分量 %d 个，最大的 6 个：' % len(comps))
    for n, x0, x1, y0, y1 in comps[:6]:
        print('   %6d 像素  bbox x[%4d,%4d] y[%4d,%4d]  %dx%d'
              % (n, x0, x1, y0, y1, x1 - x0 + 1, y1 - y0 + 1))
    if comps:
        big = sum(n for n, *_ in comps[:3])
        print('前 3 大块占差异的 %.1f%%' % (big * 100.0 / max(total, 1)))
    return 0


if __name__ == '__main__':
    sys.exit(main())