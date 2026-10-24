#!/usr/bin/env python3
"""生成浏览器 demo 用的那张 **JPEG** 贴图（web/assets/photo.jpg）

★ 为什么 demo 里必须有一张 JPEG：
  `web/assets/` 原本五张全是 PNG，于是"JPEG 支持"在 demo 里根本没有落点 ——
  解码器写得再对，浏览器也在走 PNG 分支。这张 96×96 的图让同一份烘焙代码
  （`AssetImportPipeline` → `decodeImage` 按魔数分发 → `buildAtlasFromSources`
  → GPU 上传）真的跑一次**有损**格式，并且图集里有一帧来自 JPEG。

★ 为什么不复用 `tools/make-jpeg-fixtures.py` 的语料：
  那份语料是**判据专用**的（金标、容差、sha256 全钉死）。
  挪到 demo 里会让"改判据语料"和"改演示素材"互相牵连，
  而且它 64×48 的尺寸放在 2.5D 场景里太小，看不清是不是真的解码对了。

★ 内容故意做成"渐变 + 亮边 + 一个椭圆"：
  渐变检验 DC/低频系数（量化误差最容易被看见），亮边检验高频，
  圆的边缘会横跨 8×8 块边界 —— 块效应/错位一眼可见。

用法：
  python tools/make-demo-jpeg.py          # 重新生成
  python tools/make-demo-jpeg.py --check  # 只校验现有文件与生成规则一致

产物：web/assets/photo.jpg（4:2:0、质量 82、基线过程）
"""

from __future__ import annotations

import hashlib
import pathlib
import sys

from PIL import Image, ImageDraw

OUT = pathlib.Path(__file__).resolve().parent.parent / "web" / "assets" / "photo.jpg"

W = H = 96
QUALITY = 82
SUBSAMPLING = 2  # 4:2:0：让上采样路径也真的被跑到


def build() -> Image.Image:
    im = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(im)
    # 竖直渐变：低频，JPEG 应该几乎无损地保留
    for y in range(H):
        t = y / (H - 1)
        d.line(
            [(0, y), (W, y)],
            fill=(int(40 + 120 * t), int(90 + 60 * (1 - t)), int(150 - 60 * t)),
        )
    # 斜亮边：高频，量化误差最先在这里显形
    for i in range(0, W, 12):
        d.line([(i, 0), (i + 20, H)], fill=(250, 235, 200), width=2)
    # 一个椭圆：边缘斜穿多个 8×8 块，块效应/错位会在这里变成锯齿
    d.ellipse([W * 0.55, H * 0.12, W * 0.95, H * 0.52], fill=(255, 246, 210))
    return im


def encode(im: Image.Image) -> bytes:
    import io

    buf = io.BytesIO()
    im.save(buf, format="JPEG", quality=QUALITY, subsampling=SUBSAMPLING, progressive=False)
    return buf.getvalue()


def main(argv: list[str]) -> int:
    data = encode(build())
    digest = hashlib.sha256(data).hexdigest()

    if "--check" in argv:
        if not OUT.exists():
            print(f"× 缺少 {OUT}")
            return 1
        cur = hashlib.sha256(OUT.read_bytes()).hexdigest()
        if cur != digest:
            print("× 现有文件与生成规则不一致（有人手改过？还是 Pillow 版本变了？）")
            print(f"  现有 {cur}\n  期望 {digest}")
            return 1
        print(f"√ {OUT.name} 与生成规则一致（{len(data)} 字节，sha256 {digest[:16]}…）")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(data)
    print(f"√ 写出 {OUT}（{len(data)} 字节，4:2:0，quality {QUALITY}，sha256 {digest[:16]}…）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
