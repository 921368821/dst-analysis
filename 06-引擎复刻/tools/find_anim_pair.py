#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
find_anim_pair.py —— 按「符号哈希重合度」自动找 build 的配套动画包

为什么需要这个
    DST 把贴图（build）与动画（anim）拆成两个 zip，但**名字并不对应**：
        pig_build.zip        ← 猪的贴图
        ds_pig_basic.zip     ← 名字像，但其实是**单机版 Don't Starve** 的动画，
                               符号哈希与 DST 的 pig_build 对不上
        werepig_actions.zip  ← 实测与 pig_build 重合 84.6%，才是真配套
    靠名字猜「谁配谁」会拿到看似合理、实则缺件的结果
    （实测 pigman 的 idle 帧 21 个元素只命中 10 个，缺的 11 个静默消失）。

做法
    对每个候选 anim 包，统计它引用的符号哈希有多少能在目标 build 里找到，
    按重合率排序。重合率就是「这个动画能不能在本 build 上画全」的直接度量。
"""
import glob
import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(__file__))
from zipanim_build import parse_build  # noqa: E402
from zipanim_anim import parse_anim  # noqa: E402


def build_symbols(zip_path):
    z = zipfile.ZipFile(zip_path)
    if 'build.bin' not in z.namelist():
        return None
    b = parse_build(z.read('build.bin'), collect_vertices=False)
    return {s['hash'] for s in b['symbols']}


def anim_usage(zip_path):
    z = zipfile.ZipFile(zip_path)
    if 'anim.bin' not in z.namelist():
        return None
    a = parse_anim(z.read('anim.bin'))
    used = set()
    for an in a['anims']:
        for fr in an['frames']:
            for el in fr['elements']:
                used.add(el['symbol_hash'])
    return used, len(a['anims'])


def rank_anim_for_build(build_zip, anim_dir, top=10, min_rate=0.75):
    BH = build_symbols(build_zip)
    if BH is None:
        return []
    rows = []
    for p in glob.glob(os.path.join(anim_dir, '*.zip')):
        if os.path.abspath(p) == os.path.abspath(build_zip):
            continue
        try:
            r = anim_usage(p)
        except Exception:
            continue
        if not r:
            continue
        used, na = r
        if not used:
            continue
        hit = len(used & BH)
        rows.append((hit / len(used), hit, len(used), os.path.basename(p), na))
    rows.sort(reverse=True)
    return [r for r in rows if r[0] >= min_rate][:top] if min_rate else rows[:top]


if __name__ == '__main__':
    anim_dir = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join('D:/Program Files (x86)/Steam/steamapps/common',
                     "Don't Starve Together", 'data', 'anim')
    build_zips = sys.argv[2:] or sorted(glob.glob('_animtest/*_build.zip'))
    for bz in build_zips:
        if not os.path.exists(bz):
            continue
        print(f'══ {os.path.basename(bz)} ══')
        rows = rank_anim_for_build(bz, anim_dir, top=6)
        if not rows:
            print('   （没找到重合率 ≥75% 的动画包）')
        for rate, hit, tot, nm, na in rows:
            print(f'   {rate * 100:5.1f}%   {hit:>4}/{tot:<4} 动画{na:<4} {nm}')
        print()
