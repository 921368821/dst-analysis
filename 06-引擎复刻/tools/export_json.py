#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
export_json.py —— 把动画数据导出成 JSON（供 HTML/JS 渲染器消费）

与 export_anim.py 用同一套 collect()，只是换个序列化格式。
Lua 表给宿主用，JSON 给浏览器用。
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from export_anim import collect  # noqa: E402


def main():
    if len(sys.argv) < 3:
        print('用法: export_json.py <输出.json> <zip> [zip...]')
        return 1
    outp, zips = sys.argv[1], [p for p in sys.argv[2:] if os.path.exists(p)]
    build, atlas, anims, names, atlas_dims = collect(zips)

    syms = {}
    if build:
        for h, s in build['symbols'].items():
            frames = {}
            for fi, f in s['frames'].items():
                frames[str(fi)] = dict(
                    verts=[[round(c, 4) for c in v] for v in f['verts']],
                    bbox=[round(c, 2) for c in f['bbox']],
                )
            syms[str(h)] = dict(name=s.get('name', ''), atlas=s.get('atlas', 0),
                                frames=frames)

    anim_out = {}
    for an, a in anims.items():
        frames = []
        for fr in a['frames']:
            frames.append([
                dict(sym=str(e['sym']), frame=e['frame'],
                     mat=[round(c, 4) for c in e['mat']])
                for e in fr['elements']
            ])
        anim_out[an] = dict(rate=a['framerate'], frames=frames)

    data = dict(
        buildName=build['name'] if build else '',
        atlas=atlas,
        atlases=[dict(w=w, h=h, file=f'atlas-{i}.tex')
                 for i, (w, h) in enumerate(atlas_dims or [])],
        symbols=syms,
        anims=anim_out,
    )
    os.makedirs(os.path.dirname(outp) or '.', exist_ok=True)
    with open(outp, 'w', encoding='utf-8') as f:
        json.dump(data, f, separators=(',', ':'))
    print(f'  → {outp}  ({os.path.getsize(outp) / 1024:.0f} KB)  '
          f'符号={len(syms)} 动画={len(anim_out)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
