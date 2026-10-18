# -*- coding: utf-8 -*-
"""
probe_build_symbols2.py —— 用字符串表里的哈希反查符号边界

★ 突破点
    文件末尾的字符串表给的是 (hash, name) 对，而**符号条目里存的正是同一个
    hash**。所以在符号区里搜这些 hash 值，就能拿到每个符号条目的**精确起点**，
    进而算出每条符号的**精确长度** —— 不用再猜字段边界。

    有了「每符号字节数」+「每符号帧数」+「符号区总长」，字段布局就被唯一钉死。
"""
import struct
import zipfile
import glob
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import zipanim  # noqa: E402
from probe_build_tail import find_string_table  # noqa: E402


def analyse(path):
    z = zipfile.ZipFile(path)
    if 'build.bin' not in z.namelist():
        return
    d = z.read('build.bin')
    b = zipanim.parse_build(d)
    res = find_string_table(d)
    if not res:
        print(f'{os.path.basename(path)}: 找不到字符串表')
        return
    tbl_start, cnt, names = res
    sym_start = b['header_size']

    # 头部声明的符号数与帧数
    n_tsym = struct.unpack_from('<i', d, 8)[0]
    n_tframe = struct.unpack_from('<i', d, 12)[0]

    print(f"══ {os.path.basename(path)} ══")
    print(f"  total_symbols={n_tsym}  total_frames={n_tframe}")
    print(f"  符号区 @{sym_start}..{tbl_start} = {tbl_start - sym_start}B")
    print(f"  字符串表 {cnt} 条")

    # 在符号区里搜每个 hash（小端）
    hits = []
    for h, s in names:
        hb = struct.pack('<i', h)
        pos = d.find(hb, sym_start, tbl_start)
        if pos >= 0:
            hits.append((pos, h, s))
    hits.sort(key=lambda x: x[0])
    print(f"  在符号区命中 {len(hits)}/{len(names)} 个符号哈希")
    print()
    print(f"  {'偏移':>7} {'长度':>7} {'名字':<24}")
    for i, (pos, h, s) in enumerate(hits):
        nxt = hits[i + 1][0] if i + 1 < len(hits) else tbl_start
        print(f"  {pos:>7} {nxt - pos:>7} {s:<24}")

    # ---- 用「每符号长度」反解字段布局 ----
    if len(hits) >= 2:
        print()
        print("  ★ 每符号长度（这是硬数据，用来反解字段布局）:")
        lens = []
        for i, (pos, h, s) in enumerate(hits):
            nxt = hits[i + 1][0] if i + 1 < len(hits) else tbl_start
            lens.append((s, nxt - pos))
        for s, L in lens:
            # 读第二字段（帧数），试各种偏移
            print(f"    {s:<24} {L:>6}B   L-8={L - 8}B  L-4={L - 4}B")
        tot = sum(L for _, L in lens)
        print(f"    合计 {tot}B（符号区 {tbl_start - sym_start}B，"
              f"差 {tbl_start - sym_start - tot}B）")
        print()
        print("    求解：L = 8(头) + nframes×H + V×S")
        print("    若每符号 1 帧、顶点 6 个 float(24B)：L-8-H 必须是 24 的倍数")
        for s, L in lens[:6]:
            for H in (12, 16, 20, 24, 28, 32, 36, 40):
                rem = L - 8 - H
                if rem >= 0 and rem % 24 == 0:
                    print(f"      {s:<22} H={H} → 顶点字节 {rem} "
                          f"= {rem // 24} 个顶点")


if __name__ == '__main__':
    for p in (sys.argv[1:] or ['_animtest/bee_build.zip']):
        analyse(p)
        print()
