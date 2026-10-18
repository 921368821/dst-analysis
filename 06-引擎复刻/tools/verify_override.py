#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一键复验「符号覆盖在播放器里真的生效」。

为什么需要它
    覆盖链路有 6 环，任何一环静默失败都不会报错，只会「少画一块」：
        OverrideSymbol → GetDrawList(el.bld/symh) → world.lua 的 draw_sig
        → world.json 的 sigs → build_world_player 的 pick() → 画面
    端到端复验的唯一硬判据是**像素**：同一相机、同一 tick，
    唯一变量是 world.json 的 sigs —— 差异必须聚成**一块**，大小与装备吻合。

反面判据（很重要）
    如果差异散成几十块、铺满整个角色，那不是「画了帽子」，
    而是**锚点漂移**：包围盒把覆盖层算进去 → 角色整体平移。
    实测踩过：2180 像素 / 22 块（错） → 修锚点后 133 像素 / 1 块（对）。
    所以本脚本不只报差异数，还报**连通分量个数**。

用法
    python tools/verify_override.py            # 全流程
    python tools/verify_override.py --keep     # 保留中间产物
"""
import os
import shutil
import struct
import subprocess
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, '_out')
EDGE = r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
PYVER = sys.executable

# 对照用的固定视角：暂停 + 固定 tick + 关界面，保证两次截图只有 sigs 不同
QUERY = 'scale=10&zoom=150&tick=8&play=0&labels=0&ui=0'


def strip_sigs(src, dst):
    """把 HTML 里的 "sigs":[...] 换成空数组（括号配平扫描，不能用正则）。"""
    s = open(src, encoding='utf-8').read()
    key = '"sigs":'
    i = s.index(key) + len(key)
    depth, j, in_str, esc = 0, i, False, False
    while j < len(s):
        ch = s[j]
        if in_str:
            if esc:
                esc = False
            elif ch == '\\':
                esc = True
            elif ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch in '[{':
                depth += 1
            elif ch in ']}':
                depth -= 1
                if depth == 0:
                    break
        j += 1
    seg = s[i:j + 1]
    open(dst, 'w', encoding='utf-8').write(s[:i] + '[]' + s[j + 1:])
    return seg


def shot(html, png):
    url = 'file:///' + html.replace('\\', '/').replace(' ', '%20').replace("'", '%27')
    subprocess.run([EDGE, '--headless=new', '--disable-gpu', '--hide-scrollbars',
                    '--window-size=900,620', '--screenshot=' + png,
                    '--virtual-time-budget=12000', url + '?' + QUERY],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return os.path.exists(png)


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


def components(w, h, c, A, B):
    mask = bytearray(w * h)
    total = 0
    for y in range(h):
        row = y * w
        for x in range(w):
            i = (row + x) * c
            if A[i:i + 3] != B[i:i + 3]:
                mask[row + x] = 1
                total += 1
    seen = bytearray(w * h)
    comps = []
    for idx in range(w * h):
        if not mask[idx] or seen[idx]:
            continue
        stack, seen[idx], n = [idx], 1, 0
        x0, x1, y0, y1 = w, -1, h, -1
        while stack:
            cur = stack.pop()
            n += 1
            cy, cx = divmod(cur, w)
            x0, x1 = min(x0, cx), max(x1, cx)
            y0, y1 = min(y0, cy), max(y1, cy)
            for nb in ((cur - 1, cx > 0), (cur + 1, cx < w - 1),
                       (cur - w, cy > 0), (cur + w, cy < h - 1)):
                p2, ok = nb
                if ok and mask[p2] and not seen[p2]:
                    seen[p2] = 1
                    stack.append(p2)
        comps.append((n, x0, x1, y0, y1))
    comps.sort(reverse=True)
    return total, comps


def main():
    keep = '--keep' in sys.argv
    full = os.path.join(OUT, 'world_player.html')
    nosig = os.path.join(OUT, '_player_nosig.html')
    if not os.path.exists(full):
        print('缺 %s —— 先跑 tools/build_world_player.py' % full)
        return 1

    seg = strip_sigs(full, nosig)
    print('sigs 片段 = %s' % seg)
    if seg.strip() in ('[]', ''):
        print('⚠ sigs 为空 —— 没有任何实体使用装备/覆盖，本验证无意义')
        print('  （world.lua 里要真的装备上东西，见「装备橄榄球帽」那段）')
        return 1

    pa = os.path.join(OUT, '_cl_world_player.png')
    pb = os.path.join(OUT, '_cl__player_nosig.png')
    print('截图（无头 Edge，固定视角 %s）...' % QUERY)
    if not shot(full, pa) or not shot(nosig, pb):
        print('截图失败（检查 Edge 路径）')
        return 1

    w, h, c, A = readpng(pa)
    _, _, _, B = readpng(pb)
    total, comps = components(w, h, c, A, B)
    print('')
    print('画面 %dx%d  差异像素 %d  连通分量 %d 个' % (w, h, total, len(comps)))
    for n, x0, x1, y0, y1 in comps[:5]:
        print('   %6d 像素  bbox x[%4d,%4d] y[%4d,%4d]  %dx%d'
              % (n, x0, x1, y0, y1, x1 - x0 + 1, y1 - y0 + 1))
    print('')
    if total == 0:
        print('✘ 覆盖对画面零影响 —— 链路某处断了')
        ok = False
    elif len(comps) == 1:
        print('✔ 差异聚成单一连通块 —— 覆盖确实画出了一块独立部件，'
              '且没有引起整体位移')
        ok = True
    elif len(comps) <= 3:
        print('✔ 差异聚成 %d 块 —— 覆盖生效（多块可能是装备含分离部件）' % len(comps))
        ok = True
    else:
        print('✘ 差异散成 %d 块 —— 不像「画了个部件」，更像**锚点漂移**：'
              '包围盒把覆盖层算进去了，导致整个角色平移。' % len(comps))
        print('  修法：锚点包围盒只用实体自己的 build（见 build_world_player.py 的注释）')
        ok = False

    if not keep:
        for p in (nosig, pa, pb):
            try:
                os.remove(p)
            except OSError:
                pass
    return 0 if ok else 2


if __name__ == '__main__':
    sys.exit(main())