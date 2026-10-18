# -*- coding: utf-8 -*-
"""export_drawcmd.py —— 把 06 离线渲染器的 drawlist 转成 DrawCmd JSON

为什么要它（2.4 的验收：「至少给出离线渲染器与实时渲染器**共用同一份绘制指令**的路径」）

    现状（本轮摸清的，都是实测）：
      · 06 离线侧：`render.lua` 走 AnimState → `GetDrawList()` → 文本
        （`BUNDLE/SUBJECT/FRAME/QUAD`），再由 Python 画成 PNG。
      · 07 实时侧：`rt/render_atlas.js` 直接读**同一份** `_out/json/<build>.json`
        （build 的 symbols/anims/verts），自己算 `uvRect` / `localQuad` / `applyMat`。
      · 两边**数据同源**，但**指令格式不同** —— 于是「两边画得一样」只能靠人肉相信。

    这份工具把离线侧的输出转成 DrawCmd（一份中间表示），
    再由 `07-通用引擎/tools/check_drawcmd.js` 拿它跟实时侧算出来的结果**逐符号比对**。
    两边一致 ⇒ 「共用同一份绘制指令」不是口号，是可复核的事实。

用法
    python tools/export_drawcmd.py                       # 读 _out/drawlist.txt，写 _out/drawcmd.json
    python tools/export_drawcmd.py --in X --out Y
"""
import argparse
import io
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _paths import ENGINE                      # noqa: E402

DEFAULT_IN = os.path.join(ENGINE, "_out", "drawlist.txt")
DEFAULT_OUT = os.path.join(ENGINE, "_out", "drawcmd.json")


def parse(path):
    bundles = []
    cur = None
    for ln, line in enumerate(io.open(path, encoding="utf-8", errors="replace"), 1):
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        tag = parts[0]
        if tag == "BUNDLE":
            # BUNDLE <build> <atlas> <w> <h> [<frame>...]
            cur = {"build": parts[1], "atlas": parts[2],
                   "atlas_w": int(parts[3]), "atlas_h": int(parts[4]),
                   "quads": []}
            bundles.append(cur)
        elif tag == "SUBJECT":
            if cur is None:
                raise SystemExit("第 %d 行 SUBJECT 出现在 BUNDLE 之前" % ln)
            cur["subject"] = parts[1]
        elif tag == "FRAME":
            if cur is None:
                raise SystemExit("第 %d 行 FRAME 出现在 BUNDLE 之前" % ln)
            cur["frame"] = int(parts[1])
        elif tag == "QUAD":
            if cur is None:
                raise SystemExit("第 %d 行 QUAD 出现在 BUNDLE 之前" % ln)
            # ★★ 行格式（render.lua:113-120 实测）：
            #     QUAD <symbol> <symframe> <atlas> <v0.x v0.y v0.u v0.v> ... <mat 7 个>
            #   两部分曾经都解析错，记在这里：
            #     ① `parts[3]` 是 **atlas 索引**，不是顶点；从 `parts[3:]` 取数会整体错位一格
            #        —— 于是"顶点"里混着 atlas 号，"矩阵"少一个分量、多吞一个顶点值。
            #     ② 顶点**不是固定 6 个**：一个 QUAD 行对应**一个符号的一整帧**，
            #        实测 pig_torso 帧 2 有 126 个顶点（NF=515 = 4 头字段 + 126*4 + 7）。
            #        早期按"6 个一组"硬切，把 20 个四边形拼成的复合图当成一块，
            #        才引出 check_drawcmd.js 里"最接近的组误差 17744"那种误报。
            #   正确读法：头 4 字段之后，顶点总数 = (剩余 - 7) / 4，尾部 7 个是矩阵。
            sym, sf = parts[1], int(parts[2])
            nums = [float(x) for x in parts[4:]]
            if (len(nums) - 7) < 4 or (len(nums) - 7) % 4 != 0:
                raise SystemExit("第 %d 行 QUAD 顶点数不整：(字段 %d - 头 4 - 矩阵 7) 不能整除 4"
                                 % (ln, len(parts)))
            nv = (len(nums) - 7) // 4
            verts = [nums[i * 4:i * 4 + 4] for i in range(nv)]
            mat = nums[nv * 4:]
            cur["quads"].append({"sym": sym, "sf": sf, "verts": verts, "mat": mat})
    return bundles


def main(argv=None):
    ap = argparse.ArgumentParser(description="06 drawlist → DrawCmd JSON")
    ap.add_argument("--in", dest="inp", default=DEFAULT_IN)
    ap.add_argument("--out", dest="out", default=DEFAULT_OUT)
    a = ap.parse_args(argv)

    if not os.path.isfile(a.inp):
        print("✘ 输入不存在：%s\n  处置：先在 06 侧跑一次 render 入口生成 drawlist" % a.inp)
        return 2
    bundles = parse(a.inp)
    if not bundles:
        print("✘ 没解析到任何 BUNDLE（文件格式变了？）")
        return 2
    for b in bundles:
        if "subject" not in b or "frame" not in b:
            print("✘ %s 缺 SUBJECT 或 FRAME" % b["build"])
            return 2
    with io.open(a.out, "w", encoding="utf-8", newline="\n") as f:
        for b in bundles:
            f.write(json.dumps(b, ensure_ascii=False, separators=(",", ":")) + "\n")
    total = sum(len(b["quads"]) for b in bundles)
    print("✔ %d 个 BUNDLE / %d 个 QUAD → %s"
          % (len(bundles), total, os.path.relpath(a.out, ENGINE)))
    for b in bundles:
        print("   %-16s subject=%-10s frame=%-2s quads=%d  atlas=%dx%d"
              % (b["build"], b["subject"], b["frame"], len(b["quads"]),
                 b["atlas_w"], b["atlas_h"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
