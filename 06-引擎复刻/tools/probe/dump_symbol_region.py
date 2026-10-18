# -*- coding: utf-8 -*-
"""
dump_symbol_region.py —— 在**已知符号边界**下逐字段 dump

现在符号的精确起点/长度是硬数据（由尾部字符串表里的哈希反查得到），
于是可以按边界对齐地打印每个符号的原始字节 + f32 视图，
直接肉眼读出字段语义 —— 不用再猜边界。
"""
import struct
import zipfile
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import zipanim  # noqa: E402
from probe_build_tail import find_string_table  # noqa: E402


def run(path, max_sym=8):
    z = zipfile.ZipFile(path)
    if 'build.bin' not in z.namelist():
        return
    d = z.read('build.bin')
    b = zipanim.parse_build(d)
    tbl_start, cnt, names = find_string_table(d)
    sym_start = b['header_size']
    n_tsym = struct.unpack_from('<i', d, 8)[0]
    n_tframe = struct.unpack_from('<i', d, 12)[0]

    hits = []
    for h, s in names:
        pos = d.find(struct.pack('<i', h), sym_start, tbl_start)
        if pos >= 0:
            hits.append((pos, h, s))
    hits.sort(key=lambda x: x[0])
    # 首个符号可能没命中：把 sym_start 也算进去
    starts = [(sym_start, None, '<首符号>')] + hits
    starts = sorted({p: (p, h, s) for p, h, s in starts}.values())

    print(f"══ {os.path.basename(path)} ══")
    print(f"  total_symbols={n_tsym} total_frames={n_tframe} "
          f"符号区={tbl_start - sym_start}B")
    print()
    for i, (pos, h, name) in enumerate(starts[:max_sym]):
        nxt = starts[i + 1][0] if i + 1 < len(starts) else tbl_start
        L = nxt - pos
        chunk = d[pos:nxt]
        # 逐 4 字节打印
        print(f"  ── 符号「{name}」 @{pos}  长度={L}B ──")
        line = []
        for j in range(0, len(chunk), 4):
            if j + 4 > len(chunk):
                break
            u = struct.unpack_from('<I', chunk, j)[0]
            f = struct.unpack_from('<f', chunk, j)[0]
            fu = u & 0xFFFFFFFF
            # 大 u32 当哈希显示
            if fu >= 0x10000000:
                line.append(f"+{j}:u32=0x{fu:08x}")
            elif abs(f) < 1e5 and abs(f) >= 1e-4 and f == f:
                line.append(f"+{j}:f={f:.4g}")
            else:
                line.append(f"+{j}:i={u}")
            if len(line) == 6:
                print('      ' + ' | '.join(line))
                line = []
        if line:
            print('      ' + ' | '.join(line))
        print()


if __name__ == '__main__':
    for p in (sys.argv[1:] or ['_animtest/bee_build.zip']):
        run(p)
