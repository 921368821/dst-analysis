#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
export_atlas_index.py —— 把真实图集清单导出成宿主可读的索引
==============================================================================
为什么需要它
    `TheSim:AtlasContains(atlas, imagename)` 是 DST 的 C++ 接口，宿主没有。
    缺它的后果**不是**「少画一张图」，而是**预制体工厂直接崩**：
        preparedfoods.lua:57  inst.inv_image_bg.atlas = GetInventoryItemAtlas(...)
        → simutil.lua:675 attempt to call method 'AtlasContains' (a nil value)
    ⇒ 12 个 `*_spice_*` 预制体全部 spawn 失败（实测，见 reachability.lua）。

    「返回 false 糊过去」是**错**的：那会把「宿主不知道」伪装成
    「这张图不在图集里」，而 DST 真实行为是 true（图确实在）。
    本工程的诚实原则要求**真的查**。

真实数据在哪
    data/images/*.xml       只落了 345 个散件，**没有** inventoryimages*.xml
    data/databundles/images.zip   ✔ 里面有 images/inventoryimages1..4.xml 等
    data/minimap/*.xml       ✔ 散件直接可读

    ⇒ 所以要从 zip 里读。这就是本工具存在的理由。

产出
    atlas_index/<atlas路径，/ 换成 __>.idx     每行一个元素名（如 spear.tex）
    atlas_index/_manifest.txt                 图集名 → 元素数（供报告引用）

口径
    · 只导出 DST 脚本里**确实会问**的那些图集（simutil.lua 的调用点全集）
    · 元素名原样保留（含 .tex 后缀）—— 调用方传进来的也叫 *.tex
==============================================================================
"""

import os
import re
import sys
import zipfile

GAME = r"D:/Program Files (x86)/Steam/steamapps/common/Don't Starve Together/data"
ZIP = os.path.join(GAME, "databundles", "images.zip")
LOOSE_DIRS = [os.path.join(GAME, "minimap")]

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "atlas_index")

# DST 脚本里 AtlasContains 的调用点全集（simutil.lua 678-845）
ATLASES = [
    "images/inventoryimages1.xml",
    "images/inventoryimages2.xml",
    "images/inventoryimages3.xml",
    "images/inventoryimages4.xml",
    "images/inventoryimages.xml",
    "images/scrapbook_icons1.xml",
    "images/scrapbook_icons2.xml",
    "images/scrapbook_icons3.xml",
    "images/skilltree2.xml",
    "images/skilltree3.xml",
    "images/skilltree4.xml",
    "images/skilltree5.xml",
    "images/skilltree6.xml",
    "images/skilltree_icons.xml",
    "minimap/minimap_data1.xml",
    "minimap/minimap_data2.xml",
]

ELEM_RE = re.compile(r'<Element\s+name="([^"]+)"')


def read_from_zip(zf, name):
    try:
        return zf.read(name).decode("utf-8", "replace")
    except KeyError:
        return None


def read_loose(name):
    p = os.path.join(GAME, name)
    if os.path.isfile(p):
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    return None


def main():
    os.makedirs(OUT, exist_ok=True)
    zf = zipfile.ZipFile(ZIP)

    manifest = []
    missing = []
    total_elems = 0

    for atlas in ATLASES:
        txt = read_from_zip(zf, atlas)
        src = "images.zip"
        if txt is None:
            txt = read_loose(atlas)
            src = "散件"
        if txt is None:
            missing.append(atlas)
            continue

        elems = ELEM_RE.findall(txt)
        # 去重（同一图集里理论上不该有重名，但保留防御）
        seen = set()
        uniq = []
        for e in elems:
            if e not in seen:
                seen.add(e)
                uniq.append(e)
        uniq.sort()

        flat = atlas.replace("/", "__")
        with open(os.path.join(OUT, flat + ".idx"), "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(uniq))
            f.write("\n")

        manifest.append((atlas, src, len(uniq), len(elems)))
        total_elems += len(uniq)

    with open(os.path.join(OUT, "_manifest.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("# atlas\t来源\t元素数\n")
        for atlas, src, n, raw in manifest:
            f.write("%s\t%s\t%d\n" % (atlas, src, n))

    print("=" * 70)
    print("  图集索引导出")
    print("=" * 70)
    print("  输出目录 : %s" % OUT)
    for atlas, src, n, raw in manifest:
        dup = "" if n == raw else "  （原始 %d，去重 %d）" % (raw, n)
        print("  %-34s %-10s %5d%s" % (atlas, src, n, dup))
    print("  " + "-" * 60)
    print("  图集数   : %d" % len(manifest))
    print("  元素总数 : %d" % total_elems)
    if missing:
        print("  ✘ 找不到 : %s" % ", ".join(missing))
        return 1
    print("  （无缺失）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
