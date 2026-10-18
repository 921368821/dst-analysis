#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
export_anim.py —— 把 ZipAnim 资源导出成 Lua 可直接 loadfile 的表

为什么不导出 JSON
    宿主是 Lua，读 JSON 还得带个解析器（~100 行，还慢）。
    直接导出成 `return { ... }` 的 Lua 源文件，宿主一句 loadfile 就能用，
    且 Lua 5.1 加载自己的字面量比解析 JSON 快得多。

为什么可以合并多个 zip
    DST 把「贴图（build）」和「动画（anim）」拆成两个包：
        beefalo_build.zip    → atlas-0.tex + build.bin
        beefalo_actions.zip  → anim.bin
    两边用**同一套哈希**指代符号，所以按 symbol_hash 合并即可。
    这也解释了之前交叉引用 8% 未命中的现象 —— 它们本就在彼此包里。

输出结构
    return {
      build = {
        name = "beefalo_build",
        atlas = { file="atlas-0.tex", w=2048, h=2048 },
        symbols = {
          [hash] = { name="beefalo_body",
                     frames = { [0]={verts={{x,y,u,v},...6个}, bbox={...}} } },
          ...
        },
      },
      anims = {
        [ "idle" ] = { framerate=30, frames = {
            [0] = { elements = {
                { sym=<hash>, frame=0, mat={a,b,c,d,tx,ty,tz} }, ...
            } }, ...
        } },
        ...
      },
      names = { [hash]="beefalo_body", ... },   -- 哈希→名字，便于调试
    }
"""
import sys
import os
import zipfile

sys.path.insert(0, os.path.dirname(__file__))
from zipanim_build import parse_build  # noqa: E402
from zipanim_anim import parse_anim  # noqa: E402
from ktex import parse_ktex  # noqa: E402


def rnd(v, n=4):
    return round(v, n)


def assign_atlas(sym_frames, vertices, atlas_dims):
    """判定一个符号属于哪个图集。

    ★ 这里解决的是「多图集 build」的核心问题。
      BILD 的符号条目里**没有图集索引字段**（解析是逐字节守恒的，多一个字段就对不上），
      但可以用一条**可推导的等式**来定：

           UV 跨度 × 图集尺寸 == bbox 的 w/h（像素）

      实测 pig_build（atlas-0 是 2048²，atlas-1 是 1024×512）：
          pig_head  bbox=177×186  UV跨=0.08643  → 177/0.08643 = 2048  → atlas-0 ✓
          pig_arm   bbox= 86×222  UV跨=0.08398  →  86/0.08398 = 1024  → atlas-1 ✓
          pig_ear   bbox=105× 97  UV跨=0.10254  → 105/0.10254 = 1024  → atlas-1 ✓
      每个符号都**只有一个**图集能让等式成立（另一个差 2 倍以上），所以这是个干净的判据。

      换句话说：图集宽 = bbox_w ÷ du，反推出来再跟候选图集比。
    """
    if not atlas_dims:
        return 0
    if len(atlas_dims) == 1:
        return 0
    for fi in sorted(sym_frames):
        fr = sym_frames[fi]
        vb, nv = fr['_vb'], fr['_nv']
        if nv <= 0 or vb < 0 or vb + nv > len(vertices):
            continue
        us = [v[3] for v in vertices[vb:vb + nv]]
        vv = [v[4] for v in vertices[vb:vb + nv]]
        du = max(us) - min(us)
        dv = max(vv) - min(vv)
        bw, bh = fr['bbox'][2], fr['bbox'][3]
        if du <= 1e-9 or dv <= 1e-9 or bw <= 0 or bh <= 0:
            continue
        est_w = bw / du
        best, best_err = 0, None
        for i, (aw, ah) in enumerate(atlas_dims):
            err = abs(est_w - aw)
            if best_err is None or err < best_err:
                best, best_err = i, err
        # 误差超过 5% 就不敢认，退回 0
        if best_err is not None and best_err <= atlas_dims[best][0] * 0.05:
            return best
    return 0


def collect(zips):
    build = None
    build_atlas = None
    atlas_dims = []
    anims = {}
    names = {}

    for zp in zips:
        z = zipfile.ZipFile(zp)
        members = z.namelist()
        if 'build.bin' in members and build is None:
            b = parse_build(z.read('build.bin'))
            # 先把所有图集尺寸量出来（判符号归属要用）
            for mat in b['materials']:
                if mat in members:
                    k = parse_ktex(z.read(mat))
                    atlas_dims.append((k['width'], k['height']))
                else:
                    atlas_dims.append((0, 0))
            if b['materials'] and b['materials'][0] in members:
                k = parse_ktex(z.read(b['materials'][0]))
                build_atlas = dict(file=b['materials'][0],
                                   w=k['width'], h=k['height'])

            syms = {}
            for s in b['symbols']:
                frames = {}
                # 先算各帧的顶点区间，供判图集用
                for i, f in enumerate(s['frames']):
                    frames[i] = dict(verts=[], bbox=f['bbox'],
                                     duration=f['duration'],
                                     _vb=f['vb_start'], _nv=f['n_verts'])
                ai = assign_atlas(frames, b['vertices'], atlas_dims)
                for i, f in enumerate(s['frames']):
                    vb, nv = f['vb_start'], f['n_verts']
                    pool = b['vertices']
                    vs = []
                    if 0 <= vb and vb + nv <= len(pool):
                        for v in pool[vb:vb + nv]:
                            vs.append([rnd(v[0]), rnd(v[1]),
                                       rnd(v[3], 6), rnd(v[4], 6)])
                    frames[i]['verts'] = vs
                    frames[i].pop('_vb', None)
                    frames[i].pop('_nv', None)
                syms[s['hash']] = dict(frames=frames, atlas=ai)
            for h, n in b['hash_to_name'].items():
                names[h] = n
                if h in syms:
                    syms[h]['name'] = n
            build = dict(name=b['name'], materials=b['materials'],
                         symbols=syms)

        if 'anim.bin' in members:
            a = parse_anim(z.read('anim.bin'))
            for h, n in a['hash_to_name'].items():
                names.setdefault(h, n)
            for an in a['anims']:
                frames = []
                for f in an['frames']:
                    els = []
                    for el in f['elements']:
                        els.append(dict(
                            sym=el['symbol_hash'],
                            frame=el['symbol_frame'],
                            folder=el['folder_hash'],
                            mat=[rnd(v, 4) for v in el['mat']],
                        ))
                    frames.append(dict(elements=els, rect=list(f['rect'])))
                anims[an['name']] = dict(framerate=rnd(an['framerate'], 2),
                                         frames=frames)
    # ★ 按「元素命中率」过滤动画 —— 宁可少而全，不要多而残。
    #   同一批包合并进来时，每个包都带着自己那套符号；
    #   有些动画的元素在本 build 里根本找不到对应符号（会**静默少画部件**）。
    #   实测：pig_build 合并 8 个包后，动画数从 9 涨到 95，
    #   但元素覆盖反而从 80% 掉到 41% —— 因为多数新动画都对不上。
    #   所以逐动画算命中率，低于阈值直接丢掉。
    if build:
        known = set(build['symbols'].keys())
        dropped = []
        for an in list(anims.keys()):
            a = anims[an]
            tot = hit = 0
            for fr in a['frames']:
                for e in fr['elements']:
                    tot += 1
                    if e['sym'] in known:
                        hit += 1
            # 阈值可用环境变量覆盖。默认 0.85（只留能画全的动画）；
            # pig 这类「DST 没提供完全配套动画包」的 build 要放宽到 ~0.45，
            # 否则会被过滤到 0 个动画（实测踩到）。
            _th = float(os.environ.get('ANIM_HIT_THRESHOLD', '0.85'))
            if tot == 0 or hit / tot < _th:
                dropped.append(an)
                del anims[an]
        if dropped:
            import os as _os
            print(f"    （按命中率<{_os.environ.get('ANIM_HIT_THRESHOLD','0.85')} "
                  f'丢弃 {len(dropped)} 个动画，保留 {len(anims)} 个）')

    return build, build_atlas, anims, names, atlas_dims


def lua_key(k):
    if isinstance(k, str):
        return '"%s"' % k.replace('\\', '\\\\').replace('"', '\\"')
    return str(k)


def write_lua(path, build, atlas, anims, names, atlas_dims=None):
    out = []
    w = out.append
    w('-- 由 tools/export_anim.py 自动生成，请勿手改')
    w('return {')
    if atlas:
        w('  atlas = { file="%s", w=%d, h=%d },'
          % (atlas['file'], atlas['w'], atlas['h']))
    if atlas_dims:
        w('  atlases = {')
        for i, (aw, ah) in enumerate(atlas_dims):
            w('    [%d] = { w=%d, h=%d, file="atlas-%d.tex" },' % (i, aw, ah, i))
        w('  },')
    if build:
        w('  buildName = "%s",' % build['name'])
        w('  symbols = {')
        # 按名字排序输出，便于 diff
        for h in sorted(build['symbols'], key=lambda x: build['symbols'][x].get('name', '')):
            s = build['symbols'][h]
            nm = s.get('name', '')
            w('    [%d] = { name="%s", atlas=%d, frames={' % (h & 0xFFFFFFFF, nm, s.get('atlas', 0)))
            for fi in sorted(s['frames']):
                fr = s['frames'][fi]
                vs = ','.join('{%g,%g,%g,%g}' % tuple(v) for v in fr['verts'])
                w('      [%d]={dur=%d,bbox={%g,%g,%g,%g},verts={%s}},'
                  % (fi, fr['duration'], fr['bbox'][0], fr['bbox'][1],
                     fr['bbox'][2], fr['bbox'][3], vs))
            w('    } },')
        w('  },')
    w('  anims = {')
    for an in sorted(anims):
        a = anims[an]
        w('    ["%s"] = { rate=%g, frames={' % (an, a['framerate']))
        for fi, fr in enumerate(a['frames']):
            els = []
            for el in fr['elements']:
                m = el['mat']
                els.append('{sym=%d,frame=%d,mat={%g,%g,%g,%g,%g,%g,%g}}'
                           % (el['sym'] & 0xFFFFFFFF, el['frame'],
                              m[0], m[1], m[2], m[3], m[4], m[5], m[6]))
            w('      {%s},' % ','.join(els))
        w('    } },')
    w('  },')
    w('}')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out))


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print('用法: export_anim.py <输出.lua> <zip> [zip...]')
        print('  例: export_anim.py out/beefalo.lua '
              '".../beefalo_build.zip" ".../beefalo_actions.zip"')
        sys.exit(1)
    outp = sys.argv[1]
    zips = [p for p in sys.argv[2:] if os.path.exists(p)]
    os.makedirs(os.path.dirname(outp) or '.', exist_ok=True)
    build, atlas, anims, names, atlas_dims = collect(zips)
    write_lua(outp, build, atlas, anims, names, atlas_dims)
    size = os.path.getsize(outp)
    print(f'  → {outp}  ({size / 1024:.0f} KB)')
    print(f'     build={build["name"] if build else "-"}  '
          f'符号={len(build["symbols"]) if build else 0}  '
          f'动画={len(anims)}  图集={atlas}')
    if anims:
        an = sorted(anims)[0]
        print(f'     示例动画 "{an}": {len(anims[an]["frames"])} 帧, '
              f'rate={anims[an]["framerate"]}')
