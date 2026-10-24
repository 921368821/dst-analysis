#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
大规模离线差分对照：用 Pillow(libjpeg-turbo) 编码并解码一大批图，产出"待比对包"。

★ 与 tools/make-jpeg-fixtures.py 的分工（两者都拿 Pillow 当金标，用途不同）：
    make-jpeg-fixtures.py —— 生成 14 个**进仓库**的固定语料，容差写进 manifest，CI 每次跑。
    本脚本               —— 跑一个**网格扫描**，语料不落仓库（几十 MB），只把分布写进 ADR。

★ 为什么需要网格扫描：
    14 个用例的容差是**从这 14 个用例自己实测出来的**。样本少的时候，
    "阈值够用"可能只是"恰好没踩到长尾"。长尾才是真问题——
    容差写 4、而某个角落差 11，说明那条路径根本没被那 14 个用例覆盖到。

    网格维度 = 会改变解码路径的那几件事：
      子采样 4:4:4/4:2:2/4:2:0（上采样滤波器 + 块对齐）
      质量 30..95            （量化表跨度）
      顺序 / 渐进            （扫描结构、DC 预测器重置点）
      有无重启间隔            （RSTn 边界、DC 预测器重置）
      尺寸含 1x1 / 奇数 / 非 16 倍数（边块、MCU 补齐）

★ 金标必须是"Pillow 对落盘后的那份字节"的解码结果，不是对原图的解码：
  否则"编码器→解码器"往返的差会被算到我们头上，容差里就混进了不属于我们的误差。

用法：
  python tools/jpeg-diff-sweep.py --out .cache/jpeg-sweep
  node   tools/jpeg-diff-sweep.mjs .cache/jpeg-sweep
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import sys

import numpy
from PIL import Image

# 尺寸刻意几乎都不是 16 的倍数：边块 / MCU 补齐的路径才会被走到
SIZES = [(1, 1), (17, 9), (37, 23), (64, 48), (129, 97)]
BIG = (256, 192)  # 只跑一小撮，验证结论不是"只在小图上成立"
SAMPLINGS = [0, 1, 2]  # 4:4:4 / 4:2:2 / 4:2:0
QUALITIES = [30, 60, 80, 95]
PATTERNS = ["smooth", "edges", "noise", "ramp"]
TAG = {0: "444", 1: "422", 2: "420"}


def make_image(kind: str, w: int, h: int, mode: str = "RGB") -> Image.Image:
    """四种内容 × 三种通道结构，放大的误差来源不同。"""
    rnd = random.Random((hash((kind, w, h, mode)) & 0xFFFF) ^ 0x5EED)
    px = []
    for y in range(h):
        for x in range(w):
            if kind == "smooth":
                r = 30 + 200 * (x / max(1, w - 1))
                g = 40 + 180 * (y / max(1, h - 1))
                b = 128 + 90 * math.sin((x + y) / 9.0)
            elif kind == "edges":
                # 硬边 + 高饱和块：色度上采样在这里差得最多
                if (x // 4 + y // 4) % 2 == 0:
                    r, g, b = 220, 20, 30
                elif x < w // 3:
                    r, g, b = 10, 200, 60
                elif y > (h * 2) // 3:
                    r, g, b = 20, 40, 230
                else:
                    r, g, b = 250, 250, 250
                if x == y:
                    r, g, b = 0, 0, 0
            elif kind == "noise":
                # 全频段噪点：量化误差最大，IDCT 的舍入方式在这里最容易被看见
                r, g, b = rnd.randint(0, 255), rnd.randint(0, 255), rnd.randint(0, 255)
            else:  # ramp
                # 逐像素线性斜坡：最容易暴露"整幅偏移一格"这类系统性错误
                r = (x * 255) // max(1, w - 1)
                g = (y * 255) // max(1, h - 1)
                b = ((x + y) * 255) // max(1, w + h - 2)
            rgb = (max(0, min(255, int(r))), max(0, min(255, int(g))), max(0, min(255, int(b))))
            if mode == "L":
                # 亮度取 BT.601 权重，保证灰度图和彩色版本内容相当
                px.append(int(0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]))
            elif mode == "CMYK":
                # 直接给分量值（Pillow 的 CMYK 是"油墨量"，不是"亮度"）：
                # 四个分量都动，避免 C=M=Y=K 这种退化组合
                px.extend((rgb[0], rgb[1], rgb[2], 255 - rgb[1]))
            else:
                px.extend(rgb)
    # frombytes 比 putdata 稳：putdata 对 CMYK 的 4 元组序列不接受
    return Image.frombytes(mode, (w, h), bytes(px))


def specs() -> list[dict]:
    """先铺平网格再切片，避免五层嵌套 break。"""
    out = []
    for pattern in PATTERNS:
        for (w, h) in SIZES:
            for sampling in SAMPLINGS:
                for quality in QUALITIES:
                    for progressive in (False, True):
                        for restart in (0, 1):
                            out.append(
                                dict(
                                    mode="RGB", pattern=pattern, w=w, h=h, sampling=sampling,
                                    quality=quality, progressive=progressive, restartRows=restart,
                                )
                            )
    for sampling in SAMPLINGS:
        for progressive in (False, True):
            out.append(
                dict(
                    mode="RGB", pattern="edges", w=BIG[0], h=BIG[1], sampling=sampling,
                    quality=90, progressive=progressive, restartRows=0,
                )
            )
    # 灰度（1 分量）与 CMYK（4 分量，libjpeg 默认按 YCCK 编）：走的是完全不同的
    # 分量数分支与颜色变换分支，RGB 网格再全也覆盖不到
    for mode in ("L", "CMYK"):
        for pattern in ("edges", "ramp"):
            for (w, h) in SIZES:
                for sampling in (0, 2):
                    for quality in (60, 90):
                        for progressive in (False, True):
                            out.append(
                                dict(
                                    mode=mode, pattern=pattern, w=w, h=h, sampling=sampling,
                                    quality=quality, progressive=progressive, restartRows=0,
                                )
                            )
    # 4 分量 × 渐进 × 重启 × 质量两端：CMYK 的渐进扫描要解四个分量，
    # 重启则要在区间边界重置四个分量的 DC 预测器 —— 这两件事叠加时最容易错位，
    # 而上面的网格里 CMYK 既没有重启也没有 q=1/100。
    for pattern in ("edges", "noise"):
        for (w, h) in ((37, 23), (129, 97)):
            for sampling in SAMPLINGS:
                for quality in (1, 30, 95, 100):
                    for progressive in (False, True):
                        for restart in (0, 1):
                            out.append(
                                dict(
                                    mode="CMYK", pattern=pattern, w=w, h=h, sampling=sampling,
                                    quality=quality, progressive=progressive, restartRows=restart,
                                )
                            )
    for pattern in ("ramp", "noise"):
        for (w, h) in ((37, 23), (129, 97)):
            for quality in (1, 60, 100):
                for progressive in (False, True):
                    for restart in (0, 1):
                        out.append(
                            dict(
                                mode="L", pattern=pattern, w=w, h=h, sampling=0,
                                quality=quality, progressive=progressive, restartRows=restart,
                            )
                        )
    # ---- 边角：固定语料与上面的均匀网格都刻意避开的极端组合
    # ① 质量 1 / 100：量化表从"几乎全 255"到"全 1"，AC 系数量级跨两个数量级
    # ② 重启**块**间隔 1/3/7：不是整行对齐，MCU 计数与 RSTn 边界都会落在块中间
    # ③ 极端长宽比：1 宽的图没有水平相邻块，1 高的图整幅只剩一行块
    corners = []
    for quality in (1, 100):
        for sampling in SAMPLINGS:
            for progressive in (False, True):
                corners.append(dict(mode="RGB", pattern="noise", w=37, h=23, sampling=sampling,
                                    quality=quality, progressive=progressive, restartRows=0, restartBlocks=0))
    for (w, h) in ((1, 64), (64, 1), (3, 97), (97, 3)):
        for sampling in SAMPLINGS:
            for progressive in (False, True):
                corners.append(dict(mode="RGB", pattern="ramp", w=w, h=h, sampling=sampling,
                                    quality=75, progressive=progressive, restartRows=0, restartBlocks=0))
    for blocks in (1, 3, 7):
        for sampling in SAMPLINGS:
            for progressive in (False, True):
                corners.append(dict(mode="RGB", pattern="edges", w=97, h=61, sampling=sampling,
                                    quality=80, progressive=progressive, restartRows=0, restartBlocks=blocks))
    for c in corners:
        c.setdefault("restartBlocks", 0)
        out.append(c)

    for s in out:
        s.setdefault("restartBlocks", 0)
    return out


def label(s: dict) -> str:
    return "%s %s %dx%d %s q%d%s%s%s" % (
        s["mode"], s["pattern"], s["w"], s["h"], TAG[s["sampling"]], s["quality"],
        " prog" if s["progressive"] else "",
        " rst%d" % s["restartRows"] if s["restartRows"] else "",
        " rstb%d" % s["restartBlocks"] if s.get("restartBlocks") else "",
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=0, help="只生成前 N 个（冒烟用）")
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)

    todo = specs()
    if args.limit:
        todo = todo[: args.limit]

    cache: dict[tuple, Image.Image] = {}
    cases = []
    for i, s in enumerate(todo):
        key = (s["pattern"], s["w"], s["h"], s["mode"])
        if key not in cache:
            cache[key] = make_image(*key)
        img = cache[key]

        name = "case-%04d" % i
        jpg = os.path.join(out, name + ".jpg")
        raw = os.path.join(out, name + ".rgba")
        save_kw = dict(
            format="JPEG",
            quality=s["quality"],
            subsampling=s["sampling"],
            progressive=s["progressive"],
        )
        if s["restartRows"]:
            save_kw["restart_marker_rows"] = s["restartRows"]
        if s.get("restartBlocks"):
            save_kw["restart_marker_blocks"] = s["restartBlocks"]
        img.save(jpg, **save_kw)

        with Image.open(jpg) as back:
            back.load()
            # 与 make-jpeg-fixtures.py 统一成 RGBA（alpha 恒 255），我们的解码输出也是 RGBA8
            gold = back.convert("RGBA")
            with open(raw, "wb") as f:
                f.write(gold.tobytes())
            cases.append(
                dict(
                    name=name,
                    file=name + ".jpg",
                    golden=name + ".rgba",
                    width=gold.width,
                    height=gold.height,
                    note=label(s),
                    **{k: s[k] for k in ("mode", "pattern", "sampling", "quality", "progressive", "restartRows", "restartBlocks")},
                )
            )

    with open(os.path.join(out, "sweep.json"), "w", encoding="utf-8") as f:
        json.dump(dict(generator="Pillow " + Image.__version__, reference="libjpeg-turbo", cases=cases), f, indent=1)

    total = sum(os.path.getsize(os.path.join(out, c["golden"])) for c in cases)
    print("用例 %d 个，金标合计 %.1f MB → %s" % (len(cases), total / 1e6, out))
    print("Pillow %s / numpy %s" % (Image.__version__, numpy.__version__))
    return 0


if __name__ == "__main__":
    sys.exit(main())
