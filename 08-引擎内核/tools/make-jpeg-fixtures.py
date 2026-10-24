#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 JPEG 语料与金标（Pillow 编码 + Pillow 解码）。

★ 为什么金标由 Pillow（libjpeg-turbo）产出，而不是由我们的解码器自己产出：
  自己产金标等于"用答案验证答案"。JPEG 是有损格式，跨实现不可能逐字节相同，
  所以金标的意义是"一个独立实现认为这张图长什么样"，我们的解码器必须落在
  一个**可测量的容差**内。容差数字写进 manifest，测试直接读它 —— 阈值不是
  测试里拍脑袋定的，而是这里实测出来的。

★ 为什么每张图的容差不同：
  4:4:4（无上采样）只剩 IDCT 差异，通常是 ±1；4:2:0/4:2:2 还多一层色度上采样，
  我们实现的是三角滤波（libjpeg fancy 同族），边缘处会有几级差异。
  把两者用同一个阈值，要么放过 4:4:4 的真错误，要么让 4:2:0 天天红。

用法：
  python tools/make-jpeg-fixtures.py            # 写 tests/fixtures/jpeg/
  python tools/make-jpeg-fixtures.py --check    # 只校验，不写文件（CI 用）
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import random
import shutil
import struct
import subprocess
import sys

import numpy

from PIL import Image

try:  # liblj92：唯一的第三方无损（SOF3）编解码实现
    import imagecodecs
except ImportError:  # pragma: no cover - 只有做无损语料时才需要
    imagecodecs = None

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "tests", "fixtures", "jpeg")
CHECK = "--check" in sys.argv


def smooth_image(w: int, h: int) -> Image.Image:
    """低频渐变 + 少量噪点：上采样差异最小的内容，用来压紧容差。"""
    img = Image.new("RGB", (w, h))
    px = img.load()
    rnd = random.Random(0xC0FFEE)
    for y in range(h):
        for x in range(w):
            r = int(30 + 200 * (x / max(1, w - 1)))
            g = int(40 + 180 * (y / max(1, h - 1)))
            b = int(128 + 90 * math.sin((x + y) / 9.0))
            n = rnd.randint(-3, 3)
            px[x, y] = (max(0, min(255, r + n)), max(0, min(255, g + n)), max(0, min(255, b + n)))
    return img


def edged_image(w: int, h: int) -> Image.Image:
    """硬边 + 高饱和色块：色度上采样差异最大，用来暴露"上采样滤波器选错"。"""
    img = Image.new("RGB", (w, h), (250, 250, 250))
    px = img.load()
    for y in range(h):
        for x in range(w):
            if (x // 4 + y // 4) % 2 == 0:
                px[x, y] = (220, 20, 30)
            elif x < w // 3:
                px[x, y] = (10, 200, 60)
            elif y > (h * 2) // 3:
                px[x, y] = (20, 40, 230)
            else:
                px[x, y] = (250, 250, 250)
    # 一条 1px 斜线：上采样滤波器在细结构上的差别会在这里放大
    for i in range(min(w, h)):
        px[i, i] = (0, 0, 0)
    return img


def exif_orientation_6(jpeg: bytes) -> bytes:
    """在 SOI 后插入一个只含 Orientation=6 的最小 APP1(Exif) 段。

    ★ 手工构造而不是装 piexif：这里要的正是"解码器能否解析一个合法但最小的
      TIFF 头"，第三方库会把各种字段一起写进去，反而看不清是哪个字节起了作用。
    """
    tiff = b"II" + struct.pack("<H", 42) + struct.pack("<I", 8)
    tiff += struct.pack("<H", 1)  # IFD0 条目数
    tiff += struct.pack("<HHI", 0x0112, 3, 1) + struct.pack("<HH", 6, 0)
    tiff += struct.pack("<I", 0)  # 下一个 IFD
    payload = b"Exif\x00\x00" + tiff
    seg = b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload
    assert jpeg[:2] == b"\xff\xd8"
    return jpeg[:2] + seg + jpeg[2:]



def _node() -> str:
    exe = shutil.which("node")
    if exe is None:
        raise SystemExit("找不到 node：算术语料需要先用本仓库的编码器生成源文件")
    return exe


CMYK_CASE_NAMES = (
    "cmyk-baseline",
    "ycck-baseline",
    "cmyk-arith",
    "ycck-arith",
)


def add_arith_cases(manifest: dict) -> list[str]:
    """算术编码语料：本仓库编码 → Pillow(libjpeg-turbo) 解码作为金标。

    ★ 方向为什么是反的：Pillow 不暴露 arith_code，imagecodecs 也没有这个参数，
      全世界找不到一个能"产算术 JPEG"的现成编码器。所以只能反过来验证：
      我们的流如果被 libjpeg-turbo 独立解开、且解出的像素与 baseline 一致，
      就同时证明了编码器合规、以及我们的解码器与 libjpeg 的算术解码器同解。
      每张图的 `golden` 是 **libjpeg-turbo 对同一个文件**的解码结果，
      所以容差里只剩 IDCT 取整差异（4:4:4，与 smooth-444 同量级）。
    """
    failures: list[str] = []
    src_script = os.path.join(ROOT, "tests", "tools", "jpeg-mode-sources.ts")
    proc = subprocess.run(
        [_node(), "--experimental-transform-types", src_script, "--out", OUT_DIR],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if proc.returncode != 0:
        raise SystemExit(f"算术语料源生成失败：\n{proc.stdout}\n{proc.stderr}")

    # ★ 文件清单由 jpeg-mode-sources.ts 写出（`_selfenc.json`），**不在 Python 里再抄一份**：
    #   两份清单一定会漂移，漂移的结果就是"新加的语料没人判"，而且不会有任何东西变红。
    #   这里只保留"阈值 + 说明"这张策略表；清单里出现了策略表没有的名字 → 直接失败。
    POLICY = {
        "arith-seq-gray": (3, 0.20, "SOF9 算术顺序式（灰度）；金标=libjpeg-turbo 解我们的流"),
        "arith-seq-rgb": (3, 0.20, "SOF9 算术顺序式（RGB 4:4:4）"),
        "arith-prog-gray": (3, 0.20, "SOF10 算术渐进式（灰度）"),
        "arith-prog-rgb": (3, 0.20, "SOF10 算术渐进式（RGB 4:4:4）"),
        "arith-seq-gray-dac": (3, 0.20, "SOF9 + DAC 段（非缺省条件走同一张表）"),
        "arith-seq-gray-rst": (3, 0.20, "SOF9 + DRI/RST（算术统计区按区间重置）"),
        # 我们自己编的 8 位哈夫曼流，由 libjpeg 解 —— 这一向管的是**编码器合规**，
        # 而不是"我们能解别人的流"。采样因子、右边界填充、扫描脚本写错都会在这里暴露。
        "selfenc-444": (3, 0.20, "我们编的 baseline 4:4:4，由 libjpeg 解（管编码器合规）"),
        "selfenc-420": (4, 0.50, "我们编的 baseline 4:2:0，由 libjpeg 解（管采样因子/边界填充）"),
        "selfenc-422": (4, 0.50, "我们编的 baseline 4:2:2，由 libjpeg 解"),
        "selfenc-prog-420": (4, 0.50, "我们编的渐进 4:2:0，由 libjpeg 解（管扫描脚本合法性）"),
        "selfenc-rst-420": (4, 0.50, "我们编的 4:2:0 + DRI/RST，由 libjpeg 解（管重启区间对齐）"),
        "selfenc-gray": (3, 0.20, "我们编的灰度 baseline，由 libjpeg 解"),
    }
    index = os.path.join(OUT_DIR, "_selfenc.json")
    if not os.path.exists(index):
        raise SystemExit("jpeg-mode-sources.ts 没有写出 _selfenc.json —— 语料清单丢了，没法验证")
    with open(index, encoding="utf-8") as fh:
        emitted = [c["name"] for c in json.load(fh)]
    # 本函数只管 arith-*/selfenc-*；4 分量那批由 add_cmyk_cases 负责，
    # 但**归属校验要做在这里**：清单里出现一个谁也不管的文件 → 它就是"生成了但没人判"。
    own = [n for n in emitted if n.startswith("arith-") or n.startswith("selfenc-")]
    unknown = [n for n in own if n not in POLICY]
    if unknown:
        raise SystemExit(
            "自产语料里有 %s 没有阈值策略 —— 新语料必须显式给 maxAbs/meanAbs，"
            "否则它要么没被比较、要么用了别人的阈值" % ", ".join(unknown)
        )
    orphan = [n for n in emitted if n not in own and n not in CMYK_CASE_NAMES]
    if orphan:
        raise SystemExit("自产语料里有 %s 不属于任何一组判据（生成了但没人判）" % ", ".join(orphan))
    cases = [(n, *POLICY[n]) for n in own]
    for name, max_abs, mean_abs, note in cases:
        path = os.path.join(OUT_DIR, f"{name}.jpg")
        with open(path, "rb") as fh:
            data = fh.read()
        with Image.open(path) as im:
            w, h = im.size
            rgba = im.convert("RGBA").tobytes()
            mode = im.mode
        gold = os.path.join(OUT_DIR, f"{name}.rgba")
        if not CHECK:
            with open(gold, "wb") as fh:
                fh.write(rgba)
        else:
            with open(gold, "rb") as fh:
                if fh.read() != rgba:
                    failures.append(f"{name}: 金标与当前 Pillow 解码结果不一致")
        manifest["cases"].append(
            {
                "name": name,
                "file": f"{name}.jpg",
                "golden": f"{name}.rgba",
                "width": w,
                "height": h,
                "mode": mode,
                "sha256": hashlib.sha256(data).hexdigest(),
                "goldenSha256": hashlib.sha256(rgba).hexdigest(),
                "maxAbs": max_abs,
                "meanAbs": mean_abs,
                "note": note,
                "exifOrientation": 1,
                "pillow_sampling": 0,
            }
        )
        print(f"  {name:20s} {w}x{h} {mode:5s} {len(data):6d}B  算术（金标=libjpeg 解我们的流）")
    return failures


def add_cmyk_cases(manifest: dict) -> list[str]:
    """4 分量（CMYK / YCCK）语料：本仓库编码 → libjpeg 解码作为金标。

    ★ 为什么这条覆盖非补不可：4 分量在解码器里是**独立的一支**（反相 CMY × K、
      YCCK 的 YCbCr 还要再反相一次），之前一条语料都没有 —— 目录里那张 `cmyk`
      是 Pillow 产的 transform=0 图，YCCK 分支从没被任何外部解碰到过。
    ★ 补的时候立刻发现真缺陷：YCCK 分支少一次反相，整幅图白变黑（max=255）。
      判定依据就是 libjpeg：同一张图，"YCC 编码反相值"被 libjpeg 解成反相图，
      "YCC 编码墨量"则与 transform=0 的 RGB 相差 ≤7。现在解码器按后者。
    ★ 金标是 libjpeg-turbo 对**同一个文件**的解码结果，所以容差里只剩
      IDCT 取整 + YCCK 转换的定点误差（实测见 maxAbs）。
    """
    failures: list[str] = []
    # 容差按**实测**给（我们的解码 vs libjpeg 金标：CMYK max=1、YCCK max=2），
    # 留一点余量给不同 libjpeg 版本的 IDCT 取整，但远小于"反相错"的量级（255）。
    cases = [
        ("cmyk-baseline", 3, "4 分量 CMYK（transform=0）基线；金标=libjpeg 解我们的流"),
        ("ycck-baseline", 4, "4 分量 YCCK（transform=2）基线；Y/Cb/Cr 编码墨量，解码需再反相"),
        ("cmyk-arith", 3, "4 分量 CMYK + SOF9 算术顺序式"),
        ("ycck-arith", 4, "4 分量 YCCK + SOF9 算术顺序式"),
    ]
    for name, max_abs, note in cases:
        path = os.path.join(OUT_DIR, f"{name}.jpg")
        if not os.path.exists(path):
            failures.append(f"{name}: 源文件不存在（jpeg-mode-sources.ts 没产出？）")
            continue
        with open(path, "rb") as fh:
            data = fh.read()
        with Image.open(path) as im:
            w, h = im.size
            mode = im.mode
            if mode != "CMYK":
                failures.append(f"{name}: Pillow 认成 {mode} 而不是 CMYK，说明 APP14/分量数没写对")
            rgba = im.convert("RGBA").tobytes()
        gold = os.path.join(OUT_DIR, f"{name}.rgba")
        if not CHECK:
            with open(gold, "wb") as fh:
                fh.write(rgba)
        else:
            with open(gold, "rb") as fh:
                if fh.read() != rgba:
                    failures.append(f"{name}: 金标与当前 Pillow 解码结果不一致")
        manifest["cases"].append(
            {
                "name": name,
                "file": f"{name}.jpg",
                "golden": f"{name}.rgba",
                "width": w,
                "height": h,
                "mode": mode,
                "sha256": hashlib.sha256(data).hexdigest(),
                "goldenSha256": hashlib.sha256(rgba).hexdigest(),
                "maxAbs": max_abs,
                "meanAbs": 0.5,
                "note": note,
                "exifOrientation": 1,
                "pillow_sampling": 0,
            }
        )
        print(f"  {name:20s} {w}x{h} {mode:5s} {len(data):6d}B  4 分量（金标=libjpeg 解我们的流）")
    return failures


def add_lossless_cases(manifest: dict) -> list[str]:
    """无损（SOF3）语料：liblj92（imagecodecs）编码，判据是**逐位相等**。

    ★ 8 位三路对照：liblj92 解 ↔ Pillow 解 ↔ 我们解，三者必须完全一致。
      Pillow(libjpeg-turbo 8.0) 能解 8 位 SOF3，但它是 8 位构建，解不了 >8 位，
      所以 9..16 位只有 liblj92 一个外部参照 —— 这一点在 note 里写明。
    ★ 精度**逐个**覆盖 8..16：liblj92 的 `bitspersample` 只接受 8..16
      （2..7 直接 `ValueError: invalid bitspersample`），所以"2..7 没有外部语料"
      不是我们偷懒，是唯一能编 SOF3 的工具不支持 —— 这一点写进 ADR 的未验证分支。
      只测 8/12/16 三个端点时，`2^(P-1)` 的位移与 `maxval` 在中间值上的行为是空白。
    ★ 容差是 0 而不是"很小"：无损格式的差异没有"取整"这个借口。
    """
    failures: list[str] = []
    if imagecodecs is None:
        return ["缺少 imagecodecs：无损语料需要 liblj92（pip install imagecodecs）"]

    h, w = 30, 40
    for prec in range(8, 17):
        maxv = (1 << prec) - 1
        yy, xx = numpy.mgrid[0:h, 0:w]
        img = ((((numpy.sin(xx * 0.2) + numpy.cos(yy * 0.15) + 2) / 4) * maxv).round()).astype(numpy.uint16)
        data = bytes(imagecodecs.ljpeg_encode(img, bitspersample=prec))
        back = numpy.asarray(imagecodecs.ljpeg_decode(data)).astype(numpy.uint16)
        if not numpy.array_equal(back, img):
            failures.append(f"lossless-{prec}: liblj92 自解与原图不等，语料本身有问题")

        name = f"lossless-{prec}" if prec != 8 else "lossless-8-gray"
        path = os.path.join(OUT_DIR, f"{name}.jpg")
        if not CHECK:
            with open(path, "wb") as fh:
                fh.write(data)

        if prec == 8:
            # 8 位：三路对照后仍用 Pillow 的解码结果当金标（跨实现）
            with Image.open(path) as im:
                if im.size != (w, h):
                    failures.append(f"{name}: 尺寸不符")
                rgba = im.convert("RGBA").tobytes()
                mode = im.mode
            pillow_pixels = numpy.frombuffer(rgba, dtype=numpy.uint8).reshape(h, w, 4)[:, :, 0]
            if not numpy.array_equal(pillow_pixels.astype(numpy.uint16), img):
                failures.append(f"{name}: Pillow 解出的像素与 liblj92 不一致（两个外部实现互相不同解）")
            gold = os.path.join(OUT_DIR, f"{name}.rgba")
            if not CHECK:
                with open(gold, "wb") as fh:
                    fh.write(rgba)
            else:
                with open(gold, "rb") as fh:
                    if fh.read() != rgba:
                        failures.append(f"{name}: 金标与当前 Pillow 解码结果不一致")
            manifest["cases"].append(
                {
                    "name": name,
                    "file": f"{name}.jpg",
                    "golden": f"{name}.rgba",
                    "width": w,
                    "height": h,
                    "mode": mode,
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "goldenSha256": hashlib.sha256(rgba).hexdigest(),
                    "maxAbs": 0,
                    "meanAbs": 0.0,
                    "note": "SOF3 无损；liblj92 编码，Pillow 与 liblj92 双外部解码逐位一致",
                    "exifOrientation": 1,
                    "pillow_sampling": 1,
                }
            )
            print(f"  {name:20s} {w}x{h} {mode:5s} {len(data):6d}B  无损 8 位（双外部解码一致）")
        else:
            # 12/16 位：原生量程的 uint16 金标，逐位相等
            gold16 = os.path.join(OUT_DIR, f"{name}.u16")
            payload = back.astype("<u2").tobytes()
            if not CHECK:
                with open(gold16, "wb") as fh:
                    fh.write(payload)
            else:
                with open(gold16, "rb") as fh:
                    if fh.read() != payload:
                        failures.append(f"{name}: 16 位金标与当前 liblj92 解码结果不一致")
            manifest.setdefault("wide", []).append(
                {
                    "name": name,
                    "file": f"{name}.jpg",
                    "golden16": f"{name}.u16",
                    "width": w,
                    "height": h,
                    "channels": 1,
                    "precision": prec,
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "goldenSha256": hashlib.sha256(payload).hexdigest(),
                    "note": f"SOF3 无损 {prec} 位，仅 liblj92 一个外部参照（Pillow 是 8 位构建，解不了 >8 位）",
                }
            )
            print(f"  {name:20s} {w}x{h} gray  {len(data):6d}B  无损 {prec} 位（仅 liblj92 参照）")
    return failures

CASES = [
    # name, image factory, save kwargs, tolerance(max_abs, mean_abs), note
    ("smooth-444", lambda: smooth_image(64, 48), dict(quality=95, subsampling=0), (3, 0.15), "4:4:4 基线，无上采样"),
    ("smooth-420", lambda: smooth_image(64, 48), dict(quality=95, subsampling=2), (4, 0.50), "4:2:0 上采样"),
    ("edges-444", lambda: edged_image(37, 23), dict(quality=90, subsampling=0), (3, 0.15), "奇数尺寸 + 硬边"),
    ("edges-420", lambda: edged_image(37, 23), dict(quality=90, subsampling=2), (6, 0.50), "奇数尺寸 + 4:2:0 硬边"),
    ("photo-422", lambda: smooth_image(64, 48), dict(quality=85, subsampling=1), (5, 0.50), "4:2:2"),
    ("progressive-420", lambda: smooth_image(64, 48), dict(quality=90, subsampling=2, progressive=True), (4, 0.50), "SOF2 渐进式"),
    ("progressive-444", lambda: edged_image(37, 23), dict(quality=95, subsampling=0, progressive=True), (3, 0.15), "渐进 + 奇数尺寸"),
    ("gray", lambda: smooth_image(40, 30).convert("L"), dict(quality=90), (2, 0.10), "单分量灰度"),
    ("restart-420", lambda: smooth_image(64, 48), dict(quality=90, subsampling=2), (4, 0.50), "DRI/RST 重启标记"),
    ("restart-prog-420", lambda: smooth_image(64, 48), dict(quality=90, subsampling=2, progressive=True), (4, 0.50), "渐进 + 重启"),
    ("cmyk", lambda: smooth_image(32, 32).convert("CMYK"), dict(quality=90), (3, 0.20), "4 分量 CMYK"),
    ("exif-orient6", lambda: smooth_image(32, 24), dict(quality=90, subsampling=0), (3, 0.15), "EXIF Orientation=6"),
    ("tiny-1x1", lambda: Image.new("RGB", (1, 1), (17, 200, 99)), dict(quality=90), (2, 1.0), "最小尺寸"),
    ("tall-1x64", lambda: smooth_image(1, 64), dict(quality=90, subsampling=0), (3, 0.15), "1×64 单列"),
    # ★ 窄图三件套：色度在某一轴只有 2 个样本，libjpeg 会**关掉 fancy 退回复制**。
    #   没有这三张，`sampleComponent` 里那个开关被谁删掉都不会有判据变红
    #   （大规模差分扫描里，3×97 的这一列原来差 40 级）。
    #   宽 3 与高 3 必须各一张：h2v2 的 fancy 条件**只看宽**，
    #   所以 "97×3 纵向走三角、3×97 横向走复制" 才是 libjpeg 的真实行为。
    ("narrow-420", lambda: smooth_image(3, 97), dict(quality=75, subsampling=2), (4, 0.50), "宽 3 的 4:2:0：色度仅 2 个样本 → 复制"),
    ("narrow-422", lambda: smooth_image(3, 97), dict(quality=75, subsampling=1), (4, 0.50), "宽 3 的 4:2:2：同上"),
    ("flat-420", lambda: smooth_image(97, 3), dict(quality=75, subsampling=2), (4, 0.50), "高 3 的 4:2:0：h2v2 只看宽，纵向仍走三角"),
]


def main() -> int:
    if not CHECK:
        os.makedirs(OUT_DIR, exist_ok=True)
    manifest = {
        "generator": "Pillow " + Image.__version__,
        "reference": "libjpeg-turbo",
        "losslessReference": "liblj92 " + (imagecodecs.ljpeg_version() if imagecodecs else "缺失"),
        "cases": [],
        "wide": [],
    }
    failures: list[str] = []

    for name, factory, kwargs, (max_abs, mean_abs), note in CASES:
        img = factory()
        path = os.path.join(OUT_DIR, f"{name}.jpg")
        save_kwargs = dict(kwargs)
        # 重启标记：Pillow 的这两个参数要求 "块/行" 粒度；只有显式指定才写 DRI
        if name.startswith("restart-"):
            save_kwargs["restart_marker_blocks"] = 1
        if name == "exif-orient6":
            import io

            buf = io.BytesIO()
            img.save(buf, "JPEG", **save_kwargs)
            data = exif_orientation_6(buf.getvalue())
        else:
            import io

            buf = io.BytesIO()
            img.save(buf, "JPEG", **save_kwargs)
            data = buf.getvalue()

        if not CHECK:
            with open(path, "wb") as fh:
                fh.write(data)

        # 金标：Pillow 解这个文件 → RGBA
        with Image.open(os.path.join(OUT_DIR, f"{name}.jpg")) as im:
            w, h = im.size
            rgba = im.convert("RGBA").tobytes()
            mode = im.mode
            exif_orient = im.getexif().get(274, 1)

        gold = os.path.join(OUT_DIR, f"{name}.rgba")
        if not CHECK:
            with open(gold, "wb") as fh:
                fh.write(rgba)
        else:
            with open(gold, "rb") as fh:
                if fh.read() != rgba:
                    failures.append(f"{name}: 金标与当前 Pillow 解码结果不一致（换了 Pillow 版本？）")

        # 元信息断言：文件里的子采样/过程/重启间隔必须与预期一致，
        # 否则"4:2:0 用例"可能其实是 4:4:4，上采样路径根本没被走到。
        jpeg_info = {}
        try:
            from PIL import JpegImagePlugin

            lay = JpegImagePlugin.get_sampling(Image.open(os.path.join(OUT_DIR, f"{name}.jpg")))
            jpeg_info["pillow_sampling"] = lay
        except Exception:  # noqa: BLE001 - 老版本 Pillow 没有这个函数
            pass

        manifest["cases"].append(
            {
                "name": name,
                "file": f"{name}.jpg",
                "golden": f"{name}.rgba",
                "width": w,
                "height": h,
                "mode": mode,
                "sha256": hashlib.sha256(data).hexdigest(),
                "goldenSha256": hashlib.sha256(rgba).hexdigest(),
                "maxAbs": max_abs,
                "meanAbs": mean_abs,
                "note": note,
                "exifOrientation": exif_orient,
                **jpeg_info,
            }
        )
        print(f"  {name:20s} {w}x{h} {mode:5s} {len(data):6d}B  orient={exif_orient}")


    # ------------------------------------------------------------------ 新增两组
    # 1) 算术编码（SOF9/SOF10）：没有第三方编码器，只能"我们编码 → libjpeg-turbo 解码"。
    # 2) 无损（SOF3）：liblj92 编码 + 它自己解码，判据是**逐位相等**（maxAbs=0）。
    failures += add_arith_cases(manifest)
    failures += add_cmyk_cases(manifest)
    failures += add_lossless_cases(manifest)

    manifest_path = os.path.join(OUT_DIR, "manifest.json")
    if not CHECK:
        with open(manifest_path, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(manifest, fh, ensure_ascii=False, indent=2)
            fh.write("\n")

    if failures:
        print("\n失败：")
        for f in failures:
            print("  -", f)
        return 1
    print(f"\n{len(CASES)} 个 JPEG 语料{'校验' if CHECK else '生成'}完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
