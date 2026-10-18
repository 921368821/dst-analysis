# -*- coding: utf-8 -*-
"""
probe_build_layout.py —— 用「结构规律性」定 build.bin 符号条目边界

三个硬约束（都可证伪）：
  1. 符号条目里应有 hash 值（大 u32），若条目等长，这些 hash 的偏移应**等距**
  2. 最后一条符号的末尾必须**正好落在文件末尾**（体积守恒）
  3. 图集矩形必须满足 x+w<=W, y+h<=H（或 UV 在 [0,1]）
"""
import zipfile
import struct
import sys
import os
from collections import Counter

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import zipanim  # noqa: E402


def analyse(path):
    z = zipfile.ZipFile(path)
    names = z.namelist()
    bd = z.read('build.bin')
    b = zipanim.parse_build(bd)
    W, H = 0, 0
    for nm in [n for n in names if n.endswith('.tex')]:
        k = zipanim.parse_ktex(z.read(nm))
        if k:
            W, H = k['width'], k['height']

    print(f"══ {os.path.basename(path)} ══")
    print(f"  版本={b['version']} 符号数={b['num_symbols']} "
          f"体={b['body_size']}B 图集={W}×{H}")
    body = bd
    start = b['header_size']
    end = len(bd)

    # ---- 1. 找"大 u32"（疑似 hash）的偏移 ----
    cand = []
    for i in range(start, end - 4, 4):
        v = struct.unpack_from('<I', body, i)[0]
        if 0x10000000 <= v < 0xFFFFFFFF:
            cand.append(i)
    print(f"  疑似 hash 的大 u32 共 {len(cand)} 个")
    if len(cand) >= 4:
        deltas = [cand[i + 1] - cand[i] for i in range(len(cand) - 1)]
        c = Counter(deltas)
        print(f"  相邻间隔分布（前 8）: {c.most_common(8)}")
        # 最常见的间隔很可能就是条目 stride
        stride, n = c.most_common(1)[0]
        print(f"  → 最常见间隔 = {stride}（出现 {n} 次）")
        if stride > 0:
            # 用 stride 去整除 body，看余数
            print(f"  body({b['body_size']}) mod stride({stride}) = "
                  f"{b['body_size'] % stride}")
            print(f"  body / stride = {b['body_size'] / stride:.3f}")
        # 第一个 hash 之前有多少字节 = 头部到首个条目的距离
        if cand:
            print(f"  首个 hash @{cand[0]}，距 body 起点 {cand[0] - start}B")

    # ---- 2. 输出 body 头 160 字节的双视图 ----
    print()
    print("  body 起始 160 字节:")
    for i in range(start, min(start + 160, end), 4):
        u = struct.unpack_from('<I', body, i)[0]
        f = struct.unpack_from('<f', body, i)[0]
        fs = f'{f:.6g}'
        tag = ''
        if u in (W, H):
            tag = '  ← == 图集宽/高'
        elif abs(f - W) < 0.01 or abs(f - H) < 0.01:
            tag = '  ← == 图集宽/高(f32)'
        print(f"  {i:>6}  u32={u:<12} f32={fs:<14}{tag}")

    # ---- 3. 若猜出 stride，试着按它切分并统计 ----
    if len(cand) >= 4:
        stride = Counter([cand[i + 1] - cand[i]
                          for i in range(len(cand) - 1)]).most_common(1)[0][0]
        if 8 <= stride <= 4096:
            # 假设首个条目从 (首个 hash 前 k 字节) 开始；k 试 0/4/8/12/16
            print()
            print(f"  按 stride={stride} 切分（假设条目从 hash 处开始）:")
            n_entry = (end - cand[0]) // stride
            print(f"    可切出 {n_entry} 条（尾部余 {end - cand[0] - n_entry * stride}B）")
            # 看每条的第 +16 字节是否总是图集宽
            off16 = Counter()
            for j in range(n_entry):
                o = cand[0] + j * stride + 16
                if o + 4 <= end:
                    off16[struct.unpack_from('<I', body, o)[0]] += 1
            print(f"    各条 +16 处的 u32 分布（前 5）: {off16.most_common(5)}")


if __name__ == '__main__':
    for p in (sys.argv[1:] or ['_animtest/bee_build.zip']):
        analyse(p)
        print()
