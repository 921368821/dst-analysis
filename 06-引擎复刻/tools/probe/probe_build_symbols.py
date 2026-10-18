# -*- coding: utf-8 -*-
"""
probe_build_symbols.py —— 破译 build.bin 的符号条目区

思路（关键）：
    图集尺寸是已知的（KTEX 里解出来了）。这给了两个**可证伪的硬约束**：
      · 若某字段是 UV       → 取值必须落在 [0, 1]
      · 若某字段是像素坐标 → x+w <= 图集宽, y+h <= 图集高
    把每条符号条目的所有 u32 按「f32 视图」和「u32 视图」都扫一遍，
    看哪几个位置的取值满足约束 —— 约束满足的位置就是真正的矩形字段。
    这比肉眼猜字节边界可靠得多。
"""
import zipfile
import struct
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import zipanim  # noqa: E402


def dump_symbols(path, limit=6):
    z = zipfile.ZipFile(path)
    names = z.namelist()
    if 'build.bin' not in names:
        print('无 build.bin')
        return
    bd = z.read('build.bin')
    b = zipanim.parse_build(bd)

    atlas_dims = []
    for nm in [n for n in names if n.endswith('.tex')]:
        k = zipanim.parse_ktex(z.read(nm))
        atlas_dims.append((k['width'], k['height']) if k else (0, 0))

    print(f"══ {os.path.basename(path)} ══")
    print(f"  build={b['name']}  version={b['version']}")
    print(f"  图集={b['atlases']}  尺寸={atlas_dims}")
    print(f"  符号数={b['num_symbols']}  头部结束@{b['header_size']}  "
          f"体={b['body_size']}B")
    print()

    off = b['header_size']
    body = bd
    print(f"  每条符号平均 {b['body_size'] // max(1, b['num_symbols'])} 字节")
    print()

    # 以 f32 视图逐字打印前 N 条符号可能的起始区
    print("  前 96 字节的 f32 / u32 双视图（定位矩形字段用）:")
    print(f"  {'偏移':>6} {'u32':>12} {'f32':>14}")
    for i in range(off, min(off + 96, len(body)), 4):
        u = struct.unpack_from('<I', body, i)[0]
        f = struct.unpack_from('<f', body, i)[0]
        mark = ''
        # 标注：哪些位置看起来像 UV 或像像素尺寸
        if 0.0 <= f <= 1.0 and f != 0.0:
            mark = '  ← 像 UV'
        elif 4 <= f <= 4096 and f == int(f):
            mark = '  ← 像像素尺寸'
        print(f"  {i:>6} {u:>12} {f:>14.5g}{mark}")

    # ---- 约束筛选：在整个符号区里找满足「x+w<=W, y+h<=H」的连续 4 元组 ----
    print()
    print("  约束筛选（像素矩形：x+w<=W 且 y+h<=H）:")
    W, H = atlas_dims[0] if atlas_dims else (0, 0)
    hits = []
    end = min(len(body), off + 4096)
    for i in range(off, end - 16, 4):
        try:
            x, y, w, h = struct.unpack_from('<ffff', body, i)
        except Exception:
            break
        if not all(0 <= v < 1e6 for v in (x, y, w, h)):
            continue
        if w <= 0 or h <= 0:
            continue
        if abs(x + w - W) < 0.01 or abs(y + h - H) < 0.01 or (x + w <= W and y + h <= H):
            if w >= 4 and h >= 4:
                hits.append((i, x, y, w, h))
    for i, x, y, w, h in hits[:20]:
        # 算一下是否是 4 的倍数 / 是否贴合图集边缘（贴合 = 很可能是真矩形）
        edge = []
        if abs(x + w - W) < 0.01:
            edge.append('贴右')
        if abs(y + h - H) < 0.01:
            edge.append('贴下')
        if abs(x) < 0.01:
            edge.append('贴左')
        if abs(y) < 0.01:
            edge.append('贴上')
        print(f"    @{i:<6} x={x:<8.1f} y={y:<8.1f} w={w:<8.1f} h={h:<8.1f} "
              f"{'/'.join(edge) if edge else ''}")


if __name__ == '__main__':
    p = sys.argv[1] if len(sys.argv) > 1 else '_animtest/bee_build.zip'
    dump_symbols(p)
