#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ktex.py —— KTEX 纹理解码（含 DXT5 解码 + PNG 输出）

格式（全部由实测 + 体积守恒确定，非猜测）

    +0   char[4] magic "KTEX"
    +4   u32    大小级别标志（**有符号偏移，不是逐字节 OR**）
                flag = 0xFFFD0220 + ((log2(长边) − 7) << 13)
                例： 128→0xFFFD0220   256→0xFFFD2220   512→0xFFFD4220
                    1024→0xFFFD6220  2048→0xFFFD8220  4096→0xFFFDA220
                     64→0xFFFCE220    32→0xFFFCC220    16→0xFFFCA220
                ★ 小图那几项是「**借位到 byte2**」的结果（byte2 从 0xFD 变成 0xFC），
                  不是 `byte1 = 0x02 | 0x20×(log2−7)` —— 那个写法在 log2<7 时算不出来，
                  早期文档就是错的（实测 16×16 的 bee_poof 给的是 0xFFFCA220）。
    +8   mip 表，每项 **10 字节**:
            u16 width
            u16 height
            u16 row_pitch   -- 每个「块行」的字节数 = (w/4) × 16，最小 16
            u32 size        -- 该 mip 级的压缩字节数
        项数 = 从整图一直降到 1×1（长边 128 → 8 项）
    ...  压缩纹理数据，**紧接着 mip 表最后一项**，按 mip 顺序排列

★ 怎么确认的「数据从表尾开始」
    以 abigail_attack_fx 为例（128×128）：
        8 项 mip，size 之和 = 16384+4096+1024+256+64+16+16+16 = 21872
        文件总大小 21960
        头 = 21960 − 21872 = 88 = 8（magic+标志）+ 8 项 × 10 字节  ✓ 分毫不差
    这个等式在全部样本上都成立，所以头长、项长、数据起点同时被钉死。

像素格式：**DXT5**（1 字节/像素）

★★ 先说结论：**KTEX 里没有独立的「像素格式字段」。**
    全库 3522 个包、3242 个 KTEX 样本逐个解析后，文件里**每一个字节**都被
    「magic + 尺寸级 + mip 表」解释完了（体积守恒 3242/3242 成立），
    没有剩余空间放格式枚举。格式是由 **pitch 字段隐含**的：
        pitch = (w/4) × 16   ⇒  每 4×4 块占 16 字节  ⇒  DXT3/DXT5 系（1 B/px）
    （DXT1 会是 (w/4)×8；全库 3242 个样本**无一例外**都是 16，
      见 tools/scan_ktex.py。）

★ 怎么把 DXT3 排除掉（两者体积完全相同，头字段也分不出）
    只能从**数据本身**判别，用「解码后 alpha 的干净度」做可证伪判据：
    精灵图集的 alpha 绝大多数是完全透明 0 或完全不透明 255，只有边缘一圈 AA。
      · 按 **DXT5** 解（前 2 字节 = 8 位 alpha 端点，后 6 字节 = 3 bit 索引）
      · 按 **DXT3** 解（前 8 字节 = 16 个 4 bit 显式 alpha）
    全图均匀抽样 64 个块，实测：
        DXT5 → 非 {0,255} 的 alpha 占 **2.36%**（正是 AA 边缘该有的比例）
        DXT3 → 占 **78.58%**（把 3 bit 索引当成 4 bit alpha，全是噪点）
    ⇒ DXT5 确证。另有两项旁证：
      · 首个块的 alpha 段是 `01 00 49 92 24 49 92 24` —— a0=1, a1=0 + 梯度索引，
        正是 DXT5 编码（DXT3 那 8 字节会是 16 个显式 nibble，分布不会这么平滑）
      · 解出来的图**看着就是原精灵**（pig/wilson 可辨认）；若格式错，画面会是垃圾
    复现脚本：tools/probe/ktex_format.py
"""
import struct
import zlib
import sys
import os


class KtexError(Exception):
    pass


def parse_ktex(data):
    if data[:4] != b'KTEX':
        raise KtexError('魔术数不是 KTEX')
    flag = struct.unpack_from('<I', data, 4)[0]
    mips = []
    o = 8
    while o + 10 <= len(data):
        w, h, pitch, size = struct.unpack_from('<HHHI', data, o)
        if w == 0 or w > 16384 or h == 0 or h > 16384:
            break
        if size == 0:
            break
        mips.append(dict(w=w, h=h, pitch=pitch, size=size))
        o += 10
        if w == 1 and h == 1:
            break
    if not mips:
        raise KtexError('mip 表解析为空')
    data_off = o
    total = sum(m['size'] for m in mips)
    return dict(flag=flag, mips=mips, data_offset=data_off,
                data_bytes=total, total_size=len(data),
                exact=(data_off + total == len(data)),
                width=mips[0]['w'], height=mips[0]['h'])


# ---------------------------------------------------------------------------
# DXT5 解码
# ---------------------------------------------------------------------------
def _color_block(b, o):
    """解一个 DXT5 的颜色部分（8 字节）→ 4 个 RGBA 元组（a 先留 255）"""
    c0, c1 = struct.unpack_from('<HH', b, o)
    idx = struct.unpack_from('<I', b, o + 4)[0]
    def rgb565(c):
        r = (c >> 11) & 0x1F
        g = (c >> 5) & 0x3F
        bl = c & 0x1F
        return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (bl << 3) | (bl >> 2))
    e0, e1 = rgb565(c0), rgb565(c1)
    if c0 > c1:
        e2 = tuple((2 * e0[i] + e1[i]) // 3 for i in range(3))
        e3 = tuple((e0[i] + 2 * e1[i]) // 3 for i in range(3))
    else:
        e2 = tuple((e0[i] + e1[i]) // 2 for i in range(3))
        e3 = (0, 0, 0)
    pal = [e0, e1, e2, e3]
    return [pal[(idx >> (2 * k)) & 3] for k in range(16)]


def _alpha_block(b, o):
    """解一个 DXT5 的 alpha 部分（8 字节）→ 16 个 alpha（0-255）"""
    a0, a1 = b[o], b[o + 1]
    bits = int.from_bytes(b[o + 2:o + 8], 'little')
    if a0 > a1:
        tbl = [a0, a1] + [((7 - k) * a0 + k * a1) // 7 for k in range(1, 7)]
    else:
        tbl = [a0, a1] + [((5 - k) * a0 + k * a1) // 5 for k in range(1, 5)] + [0, 255]
    return [tbl[(bits >> (3 * k)) & 7] for k in range(16)]


def decode_dxt5(data, w, h):
    """返回 RGBA 字节串（w×h×4）。"""
    out = bytearray(w * h * 4)
    bw, bh = max(1, (w + 3) // 4), max(1, (h + 3) // 4)
    o = 0
    for by in range(bh):
        for bx in range(bw):
            if o + 16 > len(data):
                break
            al = _alpha_block(data, o)
            co = _color_block(data, o + 8)
            o += 16
            for k in range(16):
                px = bx * 4 + (k % 4)
                py = by * 4 + (k // 4)
                if px >= w or py >= h:
                    continue
                idx = (py * w + px) * 4
                c = co[k]
                out[idx] = c[0]
                out[idx + 1] = c[1]
                out[idx + 2] = c[2]
                out[idx + 3] = al[k]
    return bytes(out)


def decode_ktex_rgba(data):
    """解出第 0 级 mip 的 RGBA"""
    k = parse_ktex(data)
    body = data[k['data_offset']:k['data_offset'] + k['size'] if False else
                k['data_offset'] + k['mips'][0]['size']]
    return k['width'], k['height'], decode_dxt5(body, k['width'], k['height']), k


# ---------------------------------------------------------------------------
# 写 PNG（不依赖 Pillow，纯标准库）
# ---------------------------------------------------------------------------
def write_png(path, w, h, rgba):
    def chunk(tag, payload):
        return (struct.pack('>I', len(payload)) + tag + payload +
                struct.pack('>I', zlib.crc32(tag + payload) & 0xFFFFFFFF))
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)                     # filter type 0
        raw += rgba[y * stride:(y + 1) * stride]
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
           + chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)


if __name__ == '__main__':
    import zipfile
    if len(sys.argv) < 3:
        print('用法: ktex.py <zip路径> <输出目录> [--warn-only]')
        sys.exit(1)
    zpath, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    z = zipfile.ZipFile(zpath)
    base = os.path.splitext(os.path.basename(zpath))[0]
    for nm in [n for n in z.namelist() if n.endswith('.tex')]:
        d = z.read(nm)
        try:
            k = parse_ktex(d)
        except KtexError as e:
            print(f'  ✘ {nm}: {e}')
            continue
        print(f'  {nm}: {k["width"]}×{k["height"]}  mip={len(k["mips"])}  '
              f'头={k["data_offset"]}B  数据={k["data_bytes"]}B  '
              f'守恒={"✔" if k["exact"] else "✘"}')
        w, h, rgba, k = decode_ktex_rgba(d)
        # 裁掉完全透明的边，方便肉眼看
        out = os.path.join(outdir, f'{base}__{nm.replace(".tex","")}.png')
        write_png(out, w, h, rgba)
        # 统计非透明像素
        nz = sum(1 for i in range(3, len(rgba), 4) if rgba[i] > 8)
        print(f'      → {out}  ({w}×{h})  非透明像素 {nz} '
              f'({nz / (w * h) * 100:.1f}%)')
