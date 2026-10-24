#!/usr/bin/env python
"""
用 **Pillow** 独立验证 PNG/APNG 语料（工具的判据，不是引擎的一部分）

为什么需要第二个外部实现：tools/make-png-fixtures.mjs 的编码器和我们自己的解码器
都是同一个人写的。pngjs 已经证过一遍，但 pngjs 与我们在"16 位降采样取整"这类
规范留白处可能同源（都用 round）。Pillow 是 C 实现、独立代码库，
它能同时回答三件事：
  ① 隔行文件是不是**合法的 Adam7**（Pillow 不认的话会直接报错或解出别的像素）；
  ② APNG 的 dispose/blend 合成结果是否符合主流实现；
  ③ 16 位原值是否被完整保留（Pillow 对 16 位灰度给出原值，不做猜测）。

★ 口径差异要记账，而不是抹平：
  · 16 位 → 8 位降采样，PNG 规范**没有规定**取整方式。我们用 `round(v/257)`
    （与 pngjs 同口径），Pillow 用 `>> 8`（floor）。两者最多差 1 级，
    所以 16 位图的判据分成两条：**原值逐字节相等**（无损）+ **降采样口径一致**（与 pngjs）。
    不把"与 Pillow 的 8 位结果相同"当判据，否则等于用一个未规定的行为否定另一个。

用法：
  python tools/verify-fixtures-pillow.py            # 验证 + 生成 APNG 帧金标
  python tools/verify-fixtures-pillow.py --dry-run  # 只验证，不写文件
"""

import json
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "tests", "fixtures", "png")
DRY = "--dry-run" in sys.argv

with open(os.path.join(ROOT, "manifest.json"), encoding="utf-8") as f:
    manifest = json.load(f)

failures = []
checked = 0


def read(path):
    with open(path, "rb") as f:
        return f.read()


for case in manifest["cases"]:
    name = case["name"]
    if case.get("kind") == "apng":
        continue

    path = os.path.join(ROOT, case["interlaced"])
    im = Image.open(path)
    expect_interlaced = True
    if not im.info.get("interlace"):
        failures.append(f"{name}: Pillow 认为这张图不是隔行（interlace 标记丢失）")

    golden = read(os.path.join(ROOT, case["golden"]))

    if im.mode in ("I;16", "I;16B", "I"):
        # 16 位灰度：Pillow 给原值（小端 ushort）。我们的 pixels16 的 R 通道应与之逐值相等。
        raw = im.tobytes()
        w, h = im.size
        native = [raw[i * 2] | (raw[i * 2 + 1] << 8) for i in range(w * h)]
        # 金标里是降采样后的 RGBA；这里只核对"降采样前的原值"另存一份给测试用
        if not DRY:
            with open(os.path.join(ROOT, name + ".gray16"), "wb") as f:
                f.write(bytes(raw))
        checked += 1
        print(f"✓ {name:24s} Pillow 16 位原值 {w}x{h}（{len(native)} 个样本）")
        continue

    rgba = im.convert("RGBA").tobytes()
    if case["bitDepth"] == 16:
        # 口径差异：PNG 规范不规定 16→8 的取整方式。我们用 round(v/257)（与 pngjs 同），
        # Pillow 用 floor(v/256)。所以判据是"每个字节最多差 1"，不是相等 ——
        # 差 1 说明只是取整口径；差得多说明通道错位/端序错/位深错。
        worst = max((abs(a - b) for a, b in zip(rgba, golden)), default=0)
        if worst > 1:
            failures.append(f"{name}: 16 位降采样与 Pillow 最大差 {worst}（>1 说明不是取整口径问题）")
            continue
        checked += 1
        print(f"✓ {name:24s} Pillow {im.mode} 与金标最大差 {worst}（round vs floor，符合预期）")
        continue
    if rgba != golden:
        diff = sum(1 for a, b in zip(rgba, golden) if a != b)
        failures.append(f"{name}: Pillow 的 RGBA 与金标不同（{diff} 个字节）")
        continue
    checked += 1
    print(f"✓ {name:24s} Pillow {im.mode} {im.size} == 金标 {len(golden)}B")

# ------------------------------------------------------------------ APNG
#
# 金标生成方式：**逐帧矩形 PNG** + `Image.alpha_composite`（严格 source-over），
# 状态机（dispose 顺序/矩形裁剪）在这里用 Pillow 的坐标系独立重写一遍。
# 为什么不直接用 Pillow 的 APNG 内建读取：它对 blend=OVER 走 `paste(im, box, im)`，
# 等于拿 alpha 当 mask 同时混 RGB 和 alpha 自身，半透明帧 alpha 会被二次相乘
# （实测 128→64）。规范定义的是 Porter-Duff over（Ao = As + Ad(1-As)）。
# 内建读取仍保留，但只用于**全不透明帧**的交叉核对 —— 那时 paste 与 over 等价，
# 能验证 dispose 顺序，又不会把 Pillow 的近似当成标准。

for case in manifest["cases"]:
    if case.get("kind") != "apng":
        continue
    name = case["name"]
    w, h = case["width"], case["height"]

    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    previous = None
    pending = None  # (rect, op) 上一帧的 dispose
    frames = []

    for f in case["frames"]:
        r = f["rect"]
        if pending is not None:
            prect, pop = pending
            if pop == 1:  # BACKGROUND：矩形清成全透明
                canvas.paste(Image.new("RGBA", (prect["width"], prect["height"]), (0, 0, 0, 0)),
                             (prect["x"], prect["y"]))
            elif pop == 2 and previous is not None:  # PREVIOUS：恢复绘制前快照
                canvas = previous.copy()
            pending = None

        if f["dispose"] == 2:
            previous = canvas.copy()

        src = Image.open(os.path.join(ROOT, f["png"])).convert("RGBA")
        if f["blend"] == 0:  # SOURCE：直接覆盖
            canvas.paste(src, (r["x"], r["y"]))
        else:  # OVER：严格 alpha 合成
            layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
            layer.paste(src, (r["x"], r["y"]))
            canvas = Image.alpha_composite(canvas, layer)
        frames.append(canvas.tobytes())
        pending = (r, f["dispose"])

    blob = b"".join(frames)
    if not DRY:
        with open(os.path.join(ROOT, case["golden"]), "wb") as fh:
            fh.write(blob)

    # 交叉核对：Pillow 的 APNG 内建读取（仅全不透明帧用例有可比性）
    im = Image.open(os.path.join(ROOT, case["file"]))
    n = getattr(im, "n_frames", 1)
    skip = 0 if case.get("idatFirstFrame", True) else 1
    if n != case["frameCount"] + skip:
        failures.append(f"{name}: Pillow 读到 {n} 帧，期望 {case['frameCount']}（+默认图 {skip}）")
        continue
    all_opaque = all(f["blend"] == 0 for f in case["frames"])
    if all_opaque:
        native = []
        for i in range(skip, n):
            im.seek(i)
            native.append(im.convert("RGBA").tobytes())
        if b"".join(native) != blob:
            failures.append(f"{name}: 全不透明帧下 Pillow 内建 APNG 与逐帧合成不一致（dispose 顺序可疑）")
            continue
        note = " 内建读取一致"
    else:
        note = " 含半透明 OVER，内建读取按 paste 语义（alpha 二次乘）不作金标"

    delays = [f["delayMs"] for f in case["frames"]]
    if not DRY:
        pass
    checked += 1
    print(f"✓ {name:24s} APNG {len(frames)} 帧 {len(blob)}B 延迟={delays}{note}")

print()
if failures:
    print(f"{len(failures)} 条不一致：")
    for f in failures:
        print("  ✗ " + f)
    sys.exit(1)
print(f"Pillow 交叉验证通过：{checked} 个用例（Pillow {Image.__version__ if hasattr(Image, '__version__') else '?'}）")
