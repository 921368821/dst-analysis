#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
auto_export.py —— 自动为每个 build 找最佳动画包并导出

为什么要「自动找」而不是写死名字
    实测踩到的坑：`pig_build.zip`（贴图）配 `ds_pig_basic.zip`（名字看着最像）——
    结果 idle 帧 21 个元素只命中 10 个，**11 个静默消失**，画面缺件但看起来
    「还挺像猪」。真配套是别的包。名字完全不可信：
        ds_ 前缀 = 单机版 Don't Starve，符号哈希与 DST 不同
        同一个生物的贴图与动画可以分在任意命名的两个包里

    所以改用**直接度量**：对每个候选动画包，算它「idle 类动画」的
    元素命中率（能在本 build 里找到对应符号的元素占比），取最高的那几个合并。
    命中率就是「这个动画能不能画全」的直接答案。

合并多个包是必要的
    DST 的动画会跨包引用符号（实测 pig_build 的 14 个符号没有任何单包能全覆盖），
    所以取 top-N 个包一起合并，把符号覆盖率拉到最高。
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from zipanim_build import parse_build  # noqa: E402
from zipanim_anim import parse_anim  # noqa: E402
from export_anim import collect  # noqa: E402
import export_json  # noqa: E402


IDLE_HINTS = ('idle_loop', 'idle', 'alert_idle', 'graze_loop',
              'look', 'taunt', 'bellow')


def eval_anim_package(build_hashes, anim_zip):
    """返回 (最佳 idle 类动画名, 元素命中率, 该包动画数, 该包符号命中数)"""
    try:
        z = __import__('zipfile').ZipFile(anim_zip)
        if 'anim.bin' not in z.namelist():
            return None
        a = parse_anim(z.read('anim.bin'))
    except Exception:
        return None
    best = None
    for an in a['anims']:
        if an['name'] not in IDLE_HINTS:
            continue
        fr = an['frames'][0] if an['frames'] else None
        if not fr or not fr['elements']:
            continue
        hit = sum(1 for e in fr['elements'] if e['symbol_hash'] in build_hashes)
        rate = hit / len(fr['elements'])
        if best is None or rate > best[1]:
            best = (an['name'], rate, len(a['anims']),
                    len({e['symbol_hash'] for aa in a['anims']
                         for f in aa['frames'] for e in f['elements']}
                        & build_hashes))
    return best


def rank(build_zip, anim_dir, limit=40):
    z = __import__('zipfile').ZipFile(build_zip)
    b = parse_build(z.read('build.bin'), collect_vertices=False)
    BH = {s['hash'] for s in b['symbols']}
    rows = []
    files = sorted(glob.glob(os.path.join(anim_dir, '*.zip')))
    for p in files:
        if os.path.abspath(p) == os.path.abspath(build_zip):
            continue
        r = eval_anim_package(BH, p)
        if r and r[1] > 0:
            rows.append((r[1], r[3], r[2], r[0], os.path.basename(p)))
    rows.sort(reverse=True)
    return BH, rows[:limit]


def write_atlas_pngs(name, zips, out_lua):
    """把 build 的每个材质 KTEX 解成 anim_data/<name>__atlas-<i>.png。

    材料顺序 = build['materials'] 的顺序，与 export_json 写的
    `atlases[i]` / 符号的 `atlas` 字段**一一对应**，所以必须用同一组 zips。
    """
    import zipfile as _zf
    from ktex import parse_ktex, decode_dxt5, write_png
    # 找到带 build.bin 的那个包，拿到材料名
    mats = None
    for zp in zips:
        z = _zf.ZipFile(zp)
        members = z.namelist()
        if 'build.bin' in members:
            b = parse_build(z.read('build.bin'), collect_vertices=False)
            mats = b['materials']
            break
    if not mats:
        print('    ⚠ 找不到含 build.bin 的包，跳过图集 PNG')
        return
    for i, mat in enumerate(mats):
        for zp in zips:
            z = _zf.ZipFile(zp)
            if mat in z.namelist():
                d = z.read(mat)
                k = parse_ktex(d)
                # ⚠️ decode_dxt5 收的是**字节** + w/h，不是 parse_ktex 的结果对象；
                #    而且要**只取 mip0 那一段**（按 data_offset/mips[0].size 切），
                #    把整份数据丢进去会从 mip 表开始解，出来是垃圾。
                body = d[k['data_offset']:k['data_offset'] + k['mips'][0]['size']]
                rgba = decode_dxt5(body, k['width'], k['height'])
                op = os.path.join(out_lua, f'{name}__atlas-{i}.png')
                write_png(op, k['width'], k['height'], rgba)
                print(f'    → {op}  ({k["width"]}×{k["height"]})')
                break
        else:
            print(f'    ⚠ 材质 {mat} 在所有包里都找不到')


def main():
    anim_dir = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join('D:/Program Files (x86)/Steam/steamapps/common',
                     "Don't Starve Together", 'data', 'anim')
    out_json = sys.argv[2] if len(sys.argv) > 2 else '_out/json'
    out_lua = sys.argv[3] if len(sys.argv) > 3 else 'anim_data'
    picks = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {
        'pig_build': '_animtest/pig_build.zip',
        'rabbit_build': '_animtest/rabbit_build.zip',
        'spider_build': '_animtest/spider_build.zip',
        'beefalo_build': '_animtest/beefalo_build.zip',
    }
    os.makedirs(out_json, exist_ok=True)
    summary = {}
    for name, bz in picks.items():
        if not os.path.exists(bz):
            print(f'✘ 缺 {bz}')
            continue
        BH, rows = rank(bz, anim_dir)
        print(f'══ {name}（build 有 {len(BH)} 个符号）══')
        # 取前 N 个包合并。
        # ★ 取多少是有讲究的：**只看符号覆盖会漏动画**。
        #   实测取 3 个包时，hound 只导出了 4 个动画
        #   （atk_petrify / atk_reanimate / jump_loop / walk），
        #   而轨迹真正用到的 idle / run_loop / atk / run_pre / atk_pre / taunt
        #   **一个都没有** —— 因为排名是「idle 类动画的元素命中率」，
        #   它只回答「这个包的 idle 画得全不全」，不回答「这个包有没有 run/atk」。
        #   取 6 个包能把符号与动画的覆盖率同时拉高（排行榜本身也打印前 5）。
        # ★★ 顺序：**从差到好**。
        #   `collect()` 合并多个包时是「同名动画后者覆盖前者」，
        #   而 rows 是按命中率**降序**排的 —— 直接拿来用会让**最好的包先加载、
        #   再被差的包覆盖**。
        #   实测症状：hound 的 `hound_basic.zip` 单包命中率 100%（57 个动画、含 idle），
        #   但合并后只导出 4 个动画（`idle` / `run_loop` / `atk` 全被
        #   `clayhound.zip` 的同名动画盖掉了，而那些只有 ~80% 命中）。
        #   倒序之后「最优者最后写」，才是我们想要的取舍。
        chosen = [r[4] for r in rows[:6]][::-1]
        for r in rows[:8]:
            mark = '★' if r[4] in chosen else ' '
            print(f'  {mark} idle={r[3]:<12} 命中率={r[0]*100:5.1f}%  '
                  f'符号命中={r[1]:<3} 动画={r[2]:<3} {r[4]}')
        zips = [bz] + [os.path.join(anim_dir, c) for c in chosen]
        zips = [p for p in zips if os.path.exists(p)]
        build, atlas, anims, names, dims = collect(zips)
        # 合并后实测符号覆盖率
        known = set(build['symbols'].keys())
        allused = set()
        for a in anims.values():
            for fr in a['frames']:
                for e in fr['elements']:
                    allused.add(e['sym'])
        cov = len(allused & known) / max(1, len(allused))
        print(f'  → 合并 {len(zips)} 个包：符号 {len(known)}，'
              f'动画 {len(anims)}，合并后符号覆盖 {cov*100:.1f}%')
        summary[name] = dict(bundles=chosen, coverage=cov,
                             symbols=len(known), anims=len(anims))
        print()

    print('提示：合并结果已写入 export 流程；下面逐个导出 JSON/Lua')
    for name, bz in picks.items():
        if name not in summary:
            continue
        zips = [bz] + [os.path.join(anim_dir, c) for c in summary[name]['bundles']]
        zips = [p for p in zips if os.path.exists(p)]
        # JSON
        sys.argv = ['export_json.py', os.path.join(out_json, f'{name}.json')] + zips
        export_json.main()
        # Lua
        from export_anim import collect as _c, write_lua
        b2, a2, an2, nm2, d2 = _c(zips)
        lp = os.path.join(out_lua, f'{name}.lua')
        write_lua(lp, b2, a2, an2, nm2, d2)
        print(f'    → {lp}')
        # ★ 图集 PNG —— 播放器要用它做仿射贴图。
        #   必须用**同一组 zips** 解码，否则材料下标会与 JSON 里的 atlas 字段错位
        #   （实测漏了这一步：world_player 构建时报
        #    FileNotFoundError: anim_data/bee_build__atlas-0.png）
        write_atlas_pngs(name, zips, out_lua)
    json.dump(summary, open(os.path.join(out_json, '_pairs.json'), 'w',
                            encoding='utf-8'), ensure_ascii=False, indent=1)
    return 0


if __name__ == '__main__':
    sys.exit(main())
