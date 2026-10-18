# -*- coding: utf-8 -*-
"""
probe_build_tail.py —— 从文件尾部反推符号区长度

思路（换了个更硬的约束）
    文件末尾有一张「哈希 → 原始字符串」表。表里的字符串是我们**认识的**
    （符号名 "Layer 5" / "fx" / 图集名 / build 名）。找到这张表的起点，
    就能算出符号区**精确**占多少字节：
        符号区长度 = 字符串表起点 − 符号区起点
    这个数字是硬的，可以用来卡死布局猜测 —— 比「末尾对齐」更容易命中，
    因为末尾对齐要求全链条都对，而这里只要找到表头就行。

表的结构（官方字段表）：
    num_hashed_strings (int)
      hash (int)
      original_string (int 长度 + 字节)   × n
"""
import struct
import zipfile
import glob
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import zipanim  # noqa: E402


def find_string_table(data):
    """从后往前扫，找出最长的、合法解读为 (i32 count + (i32 hash + str)×n)
    且**正好**结束在文件末尾的位置。返回 (起点, 条数, 名字列表) 或 None。"""
    n = len(data)
    # 表里每条至少 8 字节 + 字符串
    for start in range(max(0, n - 4 * 500), n):
        cnt = struct.unpack_from('<i', data, start)[0]
        if not (1 <= cnt <= 400):
            continue
        o = start + 4
        names = []
        ok = True
        for _ in range(cnt):
            if o + 4 > n:
                ok = False
                break
            h = struct.unpack_from('<i', data, o)[0]
            o += 4
            if o + 4 > n:
                ok = False
                break
            ln = struct.unpack_from('<i', data, o)[0]
            o += 4
            if not (0 <= ln <= 200) or o + ln > n:
                ok = False
                break
            b = data[o:o + ln]
            o += ln
            try:
                s = b.decode('utf-8')
            except Exception:
                ok = False
                break
            if not all(32 <= ord(c) < 127 for c in s):
                ok = False
                break
            names.append((h, s))
        if ok and o == n and names:
            return start, cnt, names
    return None


def main():
    files = sorted(glob.glob('_animtest/*.zip'))
    n_ok = 0
    rows = []
    for p in files:
        try:
            z = zipfile.ZipFile(p)
        except Exception:
            continue
        if 'build.bin' not in z.namelist():
            continue
        d = z.read('build.bin')
        b = zipanim.parse_build(d)
        res = find_string_table(d)
        nm = os.path.basename(p)
        if not res:
            rows.append((nm, b['header_size'], None, None, None, []))
            continue
        start, cnt, names = res
        n_ok += 1
        rows.append((nm, b['header_size'], start, cnt,
                     start - b['header_size'], [s for _, s in names][:4]))

    print('════ 从尾部反推字符串表 ════')
    print(f'样本 {len(rows)}，找到合法字符串表 {n_ok} 个')
    print()
    print(f"{'文件':<38}{'符号区起':>8}{'表起':>8}{'条数':>6}{'符号区长度':>11}  前几个名字")
    print('-' * 104)
    for nm, hdr, st, cnt, sz, names in rows[:20]:
        if st is None:
            print(f'{nm:<38}{hdr:>8}{"未找到":>8}')
        else:
            print(f'{nm:<38}{hdr:>8}{st:>8}{cnt:>6}{sz:>11}  {", ".join(names)}')


if __name__ == '__main__':
    main()
