# -*- coding: utf-8 -*-
"""
verify_zipanim.py —— 对解析结果做统计验证

有价值的地方在于：这些断言是**可证伪的**。
如果 KTEX 宽高的偏移读错了，mip 链体积就对不上；
如果 build.bin 的头偏移读错了，图集名就不是 "atlas-N.tex"、符号数就会是天文数字。
"""
import zipfile
import struct
import glob
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tools'))
import zipanim  # noqa: E402

ANIM_DIR = sys.argv[1] if len(sys.argv) > 1 else '_animtest'


def main():
    zips = sorted(glob.glob(os.path.join(ANIM_DIR, '*.zip')))
    if not zips:
        print('没找到 zip，检查路径:', ANIM_DIR)
        return 1

    n_tex = n_tex_ok = n_tex_bad = 0
    n_build = n_build_ok = 0
    n_anim = 0
    w_h_hist = {}
    bad = []

    for p in zips:
        try:
            z = zipfile.ZipFile(p)
        except Exception:
            continue
        names = z.namelist()

        # ---- KTEX 断言 ----
        for nm in [n for n in names if n.endswith('.tex')]:
            d = z.read(nm)
            k = zipanim.parse_ktex(d)
            n_tex += 1
            if not k:
                bad.append((os.path.basename(p), nm, '魔术数不是 KTEX'))
                continue
            w, h = k['width'], k['height']
            is_pow2 = (w > 0 and (w & (w - 1)) == 0 and
                       h > 0 and (h & (h - 1)) == 0)
            sane = 16 <= w <= 8192 and 16 <= h <= 8192
            if is_pow2 and sane and k['size_matches_dxt5']:
                n_tex_ok += 1
                w_h_hist[f'{w}x{h}'] = w_h_hist.get(f'{w}x{h}', 0) + 1
            else:
                n_tex_bad += 1
                if len(bad) < 12:
                    bad.append((os.path.basename(p), nm,
                                f'{w}x{h} pow2={is_pow2} sane={sane} '
                                f'体积吻合={k["size_matches_dxt5"]}'))

        # ---- build.bin 断言 ----
        if 'build.bin' in names:
            d = z.read('build.bin')
            b = zipanim.parse_build(d)
            n_build += 1
            if b:
                atlas_ok = all(a.startswith('atlas-') and a.endswith('.tex')
                               for a in b['atlases'])
                sym_ok = 0 < b['num_symbols'] < 100000
                ver_ok = b['version'] in (5, 6)
                if atlas_ok and sym_ok and ver_ok:
                    n_build_ok += 1
                else:
                    bad.append((os.path.basename(p), 'build.bin',
                                f'version={b["version"]} 图集={b["atlases"]} '
                                f'符号数={b["num_symbols"]}'))

        if 'anim.bin' in names:
            n_anim += 1

    print('════ ZipAnim 解析验证 ════')
    print(f'扫描目录: {ANIM_DIR}')
    print(f'样本数: {len(zips)} 个 zip')
    print()
    print(f'KTEX 图集   : {n_tex:4d} 个，'
          f'通过 {n_tex_ok}，可疑 {n_tex_bad}')
    if n_tex:
        print(f'             通过率 {n_tex_ok / n_tex * 100:.1f}%')
    print(f'build.bin   : {n_build:4d} 个，通过 {n_build_ok}')
    if n_build:
        print(f'             通过率 {n_build_ok / n_build * 100:.1f}%')
    print(f'anim.bin    : {n_anim:4d} 个')
    print()
    print('图集尺寸分布（前 12）:')
    for k, v in sorted(w_h_hist.items(), key=lambda x: -x[1])[:12]:
        print(f'    {k:<12} {v:5d} 次')
    print()
    if bad:
        print(f'可疑样本（前 12 / 共 {len(bad)}）:')
        for f, member, why in bad[:12]:
            print(f'    {f:<38} {member:<14} {why}')
    else:
        print('✔ 全部样本通过断言')
    return 0


if __name__ == '__main__':
    sys.exit(main())
