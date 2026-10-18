#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
batch_decode.py —— 批量回转 DST 的全部 anim.zip，产出资源清单

对每个 zip：
    · 解 build.bin  → 符号数 / 帧数 / 顶点数 / 符号名 / 图集归属
    · 解 anim.bin   → 动画数 / 帧数 / 元素数 / 动画名
    · 解 KTEX 头    → 图集尺寸 / 格式 / 体积守恒
    · （可选 --png）解出 atlas PNG

产出：
    _inventory/inventory.csv    每包一行的机器可读清单
    _inventory/summary.md       人读的汇总报告

为什么值得做
    1. 全量跑一遍才是**覆盖率**的真实数字（此前都是抽样）
    2. 失败清单本身就是「还有什么没解」的地图
    3. 清单可直接用于挑样本、做资源检索、统计「DST 一共有多少动画帧」
"""
import sys
import os
import csv
import glob
import zipfile
import traceback
import time

sys.path.insert(0, os.path.dirname(__file__))
from zipanim_build import parse_build, ParseError as BErr  # noqa: E402
from zipanim_anim import parse_anim, ParseError as AErr  # noqa: E402
from ktex import parse_ktex, decode_dxt5, write_png  # noqa: E402
from export_anim import assign_atlas  # noqa: E402


def scan_one(path, want_png=False, png_dir=None):
    row = dict(
        zip=os.path.basename(path), size=os.path.getsize(path),
        members="", build_ok=0, build_name="", symbols=0, build_frames=0,
        build_verts=0, anim_ok=0, anims=0, anim_frames=0, anim_elems=0,
        atlas_n=0, atlas_dims="", atlas_exact=0, png_ok=0,
        a1=0, a2=0, err="",
    )
    try:
        z = zipfile.ZipFile(path)
    except Exception as e:
        row['err'] = 'zip 打开失败: ' + str(e)[:80]
        return row
    members = z.namelist()
    row['members'] = ','.join(members)[:200]

    # ---- KTEX ----
    dims = []
    texs = []
    for nm in [n for n in members if n.endswith('.tex')]:
        try:
            d = z.read(nm)
            k = parse_ktex(d)
            dims.append((k['width'], k['height']))
            texs.append((nm, d, k))
        except Exception as e:
            row['err'] = (row['err'] + ' ktex:' + str(e)[:50]).strip()
    row['atlas_n'] = len(dims)
    row['atlas_dims'] = ';'.join(f'{w}x{h}' for w, h in dims)
    row['atlas_exact'] = 1 if all(
        t[2]['exact'] for t in texs) and texs else (0 if texs else -1)

    # ---- BILD ----（不收集顶点，只为统计）
    if 'build.bin' in members:
        try:
            b = parse_build(z.read('build.bin'), collect_vertices=False)
            row['build_ok'] = 1 if b['exact'] else 0
            row['build_name'] = b['name']
            row['symbols'] = len(b['symbols'])
            row['build_frames'] = sum(len(s['frames']) for s in b['symbols'])
            row['build_verts'] = b['num_vertices']
            # 图集归属分布（用 atlas_dims 判）
            try:
                bb = parse_build(z.read('build.bin'))
                a1 = a2 = 0
                for s in bb['symbols']:
                    fr = {}
                    for i, f in enumerate(s['frames']):
                        fr[i] = dict(bbox=f['bbox'], _vb=f['vb_start'],
                                     _nv=f['n_verts'])
                    ai = assign_atlas(fr, bb['vertices'], dims)
                    if ai == 0:
                        a1 += 1
                    else:
                        a2 += 1
                row['a1'], row['a2'] = a1, a2
            except Exception:
                pass
        except (BErr, Exception) as e:
            row['err'] = (row['err'] + ' bild:' + str(e)[:60]).strip()

    # ---- ANIM ----
    if 'anim.bin' in members:
        try:
            a = parse_anim(z.read('anim.bin'))
            row['anim_ok'] = 1 if a['exact'] else 0
            row['anims'] = len(a['anims'])
            row['anim_frames'] = sum(len(x['frames']) for x in a['anims'])
            row['anim_elems'] = a['elem_total']
        except (AErr, Exception) as e:
            row['err'] = (row['err'] + ' anim:' + str(e)[:60]).strip()

    # ---- 出 PNG（可选）----
    if want_png and png_dir and texs:
        base = os.path.splitext(os.path.basename(path))[0]
        n = 0
        for nm, d, k in texs:
            try:
                body = d[k['data_offset']:k['data_offset'] + k['mips'][0]['size']]
                rgba = decode_dxt5(body, k['width'], k['height'])
                out = os.path.join(png_dir,
                                   f'{base}__{nm.replace(".tex", "")}.png')
                write_png(out, k['width'], k['height'], rgba)
                n += 1
            except Exception as e:
                row['err'] = (row['err'] + ' png:' + str(e)[:40]).strip()
        row['png_ok'] = n
    return row


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else None
    want_png = '--png' in sys.argv
    if not src:
        print('用法: batch_decode.py <anim目录> [--png]')
        return 1
    outdir = '_inventory'
    png_dir = os.path.join(outdir, 'png')
    os.makedirs(outdir, exist_ok=True)
    if want_png:
        os.makedirs(png_dir, exist_ok=True)

    zips = sorted(glob.glob(os.path.join(src, '*.zip')))
    print(f'扫描 {len(zips)} 个 zip  （出 PNG: {want_png}）')
    rows = []
    t0 = time.time()
    for i, p in enumerate(zips):
        rows.append(scan_one(p, want_png, png_dir))
        if (i + 1) % 200 == 0:
            el = time.time() - t0
            print(f'  … {i + 1}/{len(zips)}  用时 {el:.0f}s')
    dt = time.time() - t0

    # ---- CSV ----
    csvp = os.path.join(outdir, 'inventory.csv')
    cols = ['zip', 'size', 'members', 'build_ok', 'build_name', 'symbols',
            'build_frames', 'build_verts', 'anim_ok', 'anims', 'anim_frames',
            'anim_elems', 'atlas_n', 'atlas_dims', 'atlas_exact', 'png_ok',
            'a1', 'a2', 'err']
    with open(csvp, 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow(r)

    # ---- 汇总 ----
    n = len(rows)
    nb = sum(1 for r in rows if int(r['build_ok'] or 0) == 1)
    na = sum(1 for r in rows if int(r['anim_ok'] or 0) == 1)
    both = sum(1 for r in rows
               if int(r['build_ok'] or 0) == 1 and int(r['anim_ok'] or 0) == 1)
    tex_ok = sum(1 for r in rows if r['atlas_exact'] == 1)
    tex_all = sum(1 for r in rows if r['atlas_exact'] >= 0)
    ferr = [r for r in rows if r['err']]
    tot_sym = sum(r['symbols'] for r in rows)
    tot_bfr = sum(r['build_frames'] for r in rows)
    tot_anm = sum(r['anims'] for r in rows)
    tot_afr = sum(r['anim_frames'] for r in rows)
    tot_ael = sum(r['anim_elems'] for r in rows)
    tot_bytes = sum(r['size'] for r in rows)

    L = []
    A = L.append
    A('# DST 资源清单（批量回转报告）')
    A('')
    A(f'源目录：`{src}`')
    A(f'扫描：**{n}** 个 zip，总 {tot_bytes / 1048576:.0f} MB，用时 {dt:.1f}s')
    A('')
    A('## 解析成功率')
    A('')
    # ★ 分母必须是「含该文件的包数」，不是全部 zip。
    #   DST 里很多 zip 只有 build、或只有 anim（贴图与动画是分包存的），
    #   拿全部 zip 做分母会把成功率算低一大截（实测 85% vs 真实 100%）。
    def _has(r, name):
        return name in (r['members'] or '')
    hb = [r for r in rows if _has(r, 'build.bin')]
    ha = [r for r in rows if _has(r, 'anim.bin')]
    ht = [r for r in rows if r['atlas_n'] and int(r['atlas_n']) > 0]
    # ⚠️ rows 来自 scan_one（内存里是 int），而从 CSV 读回时是 str。
    #    统一用 int() 比较，免得写成 `== '1'` 在内存路径上全判失败（实测踩到）。
    def _i(v):
        try:
            return int(v)
        except Exception:
            return -1
    b_ok = sum(1 for r in hb if _i(r['build_ok']) == 1)
    a_ok = sum(1 for r in ha if _i(r['anim_ok']) == 1)
    t_ok = sum(1 for r in ht if _i(r['atlas_exact']) == 1)
    A('| 项目 | 含该文件的包 | 成功 | 占比 |')
    A('|---|---:|---:|---:|')
    A(f'| build.bin（逐字节守恒） | {len(hb)} | {b_ok} | '
      f'{b_ok / max(1, len(hb)) * 100:.1f}% |')
    A(f'| anim.bin（逐字节守恒） | {len(ha)} | {a_ok} | '
      f'{a_ok / max(1, len(ha)) * 100:.1f}% |')
    A(f'| KTEX（体积守恒） | {len(ht)} | {t_ok} | '
      f'{t_ok / max(1, len(ht)) * 100:.1f}% |')
    A(f'| build+anim 同包且都成功 | — | {both} | — |')
    A('')
    A(f'（全部 {n} 个 zip 里，{len(hb)} 个含 build、{len(ha)} 个含 anim —— '
      f'DST 把贴图与动画分包存放，所以两个分母不同。）')
    A('')
    A('## 资源总量')
    A('')
    A('| 项目 | 数量 |')
    A('|---|---:|')
    A(f'| 符号总数 | {tot_sym:,} |')
    A(f'| 符号帧总数 | {tot_bfr:,} |')
    A(f'| 动画总数 | {tot_anm:,} |')
    A(f'| 动画帧总数 | {tot_afr:,} |')
    A(f'| 元素引用总数 | {tot_ael:,} |')
    A('')
    if want_png:
        A(f'| 解出的图集 PNG | {sum(r["png_ok"] for r in rows):,} 张 |')
        A('')
    A('## 有解析问题的包')
    A('')
    if not ferr:
        A('**无。** 全部 zip 的 build/anim/KTEX 都解析成功。')
    else:
        A(f'共 {len(ferr)} 个（占 {len(ferr) / n * 100:.1f}%）：')
        A('')
        A('| zip | 问题 |')
        A('|---|---|')
        for r in ferr[:60]:
            A(f'| `{r["zip"]}` | {r["err"][:110]} |')
        if len(ferr) > 60:
            A(f'| … | 另有 {len(ferr) - 60} 个 |')
    A('')
    A('## 多图集分布')
    A('')
    multi = [r for r in rows if r['atlas_n'] >= 2]
    A(f'含 2 张以上图集的包：**{len(multi)}** 个（占 {len(multi) / n * 100:.1f}%）')
    A('')
    A('这些包的符号会分散在不同图集上，归属由')
    A('`UV跨度 × 图集尺寸 == bbox w/h` 判定（见 export_anim.py::assign_atlas）。')
    A('')
    A('| zip | 图集数 | 归属 atlas-0 / 其他 |')
    A('|---|---:|---|')
    for r in multi[:20]:
        A(f'| `{r["zip"]}` | {r["atlas_n"]} | {r["a1"]} / {r["a2"]} |')
    if len(multi) > 20:
        A(f'| … | | 另有 {len(multi) - 20} 个 |')
    A('')
    A('## 图集尺寸分布')
    A('')
    from collections import Counter
    cnt = Counter()
    for r in rows:
        for dd in r['atlas_dims'].split(';'):
            if dd:
                cnt[dd] += 1
    A('| 尺寸 | 数量 |')
    A('|---|---:|')
    for k, v in cnt.most_common(15):
        A(f'| {k} | {v} |')

    sp = os.path.join(outdir, 'summary.md')
    open(sp, 'w', encoding='utf-8').write('\n'.join(L))
    print('\n'.join(L[:40]))
    print()
    print(f'产出: {csvp}')
    print(f'产出: {sp}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
