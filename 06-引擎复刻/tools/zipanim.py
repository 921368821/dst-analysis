#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
zipanim.py —— DST / Don't Starve 的 ZipAnim 资源解析器

背景
    DST 的动画资源放在 `data/anim/<name>.zip`，每个 zip 里是：
      · build.bin   —— 图集索引：符号（symbol/图层）→ 在图集里的矩形 + 变换
      · anim.bin    —— 动画定义：动画名 → 若干帧 → 每帧里各符号的变换
      · atlas-N.tex —— KTEX 格式的纹理图集（Klei 自家格式）
    三个文件都是 Klei 的私有二进制格式，官方没有文档。

本工具的目标
    把这三样解出来，好让「契约复刻宿主」的 AnimState 桩能换成真实的帧数据 ——
    这也是接渲染层（LÖVE2D 之类）唯一缺的一块。

诚实说明（重要）
    这些格式是通过**逐字节观测**推导的，不是从任何文档或泄漏源码来的。
    下面用 `[已解码]` / `[部分]` / `[未解码]` 标注每个字段的确信度。
    未解码的部分保留原始字节，方便后续继续做。

用法
    python zipanim.py info   <zip路径>          # 概览
    python zipanim.py dump   <zip路径>          # 结构 dump（含未解码字节）
    python zipanim.py anims  <zip路径>          # 列出动画名与帧数
    python zipanim.py symbols <zip路径>         # 列出符号名
    python zipanim.py ktex   <zip路径>          # 只用解析 KTEX 头
"""
import struct
import sys
import zipfile
import os


# =============================================================================
# 二进制读取游标
# =============================================================================
class Reader:
    def __init__(self, data, origin=0):
        self.d = data
        self.o = origin
        self.origin = origin

    @property
    def pos(self):
        """**绝对**文件偏移。

        ⚠️ 踩过的坑：早前写的是 `self.o - self.origin`，于是所有以 origin=4
        （跳过 magic）构造的 Reader 报出的位置都少 4 字节 ——
        build.bin 的 header_size 报成 60 而正确值是 64。
        这类错误不会崩，只会让后续按偏移找字段时全部错位，很难发现。
        """
        return self.o

    def remaining(self):
        return len(self.d) - self.o

    def u8(self):
        v = self.d[self.o]
        self.o += 1
        return v

    def u16(self):
        v = struct.unpack_from('<H', self.d, self.o)[0]
        self.o += 2
        return v

    def u32(self):
        v = struct.unpack_from('<I', self.d, self.o)[0]
        self.o += 4
        return v

    def i32(self):
        v = struct.unpack_from('<i', self.d, self.o)[0]
        self.o += 4
        return v

    def f32(self):
        v = struct.unpack_from('<f', self.d, self.o)[0]
        self.o += 4
        return v

    def str(self):
        """长度前缀字符串（Lua 风格：u32 长度 + 字节）"""
        n = self.u32()
        if n > 4096:
            raise ValueError(f"字符串长度不合理: {n} @ {self.pos}")
        b = self.d[self.o:self.o + n]
        self.o += n
        return b.decode('utf-8', 'replace')

    def raw(self, n):
        b = self.d[self.o:self.o + n]
        self.o += n
        return b


# =============================================================================
# KTEX —— Klei 的纹理格式
# =============================================================================
KTEX_PLATFORMS = {
    0: "PC (DXT1/3/5)", 1: "XBOX360", 2: "PS3", 3: "PSVita",
    4: "WiiU", 8: "Switch", 11: "PS4", 12: "XBOX_ONE",
}
KTEX_FORMATS = {
    0: "DXT1", 1: "DXT3", 2: "DXT5", 4: "RGBA8888", 5: "RGB565",
    6: "BGRA8888", 7: "RGBA4444", 8: "R8",
}


def parse_ktex(data):
    """解析 KTEX 头。

    [已解码] 关键字段位置（**与网上流传的经典 KTEX 布局不同**，是逐字节实测出来的）：

        +0  char[4]  magic "KTEX"
        +4  u32      平台/格式标志（实测 0xFFFD0220 这类值，
                     与经典布局的 "platform" 语义对不上 —— 未解码，见下）
        +8  u16      width   ★ 已用「文件体积反推」交叉验证
        +10 u16      height  ★ 同上
        +12 起       mipmap 链尺寸表（一系列 u16/u32 交替的宽高与字节数）

    ★ 为什么确信 +8/+10 是宽高
      以 abigail_attack_fx.zip 为例：
        · 实测 w=128, h=128
        · 全 mip 链字节数（DXT5 = 1 字节/像素）= 128²+64²+32²+16²+8²+4²
                                         = 16384+4096+1024+256+64+16 = 21840
        · 文件总大小 21960，差 120 字节 ≈ 头部 + 对齐
      体积能对上，说明宽高解读正确。

    [未解码] 平台与像素格式字段。经典 KTEX 布局把平台放在 +4（u32）、格式放在 +8，
             但对本版本的样本，这样读会得到 0xFFFD0220 / 128 这类不合理的值。
             疑似本版本在 +4 处用了不同的打包方式（u16 平台 + u16 格式？）。
             `platform` / `format` 因此标注为「未确定」，不猜。
    """
    if data[:4] != b'KTEX':
        return None
    w, h = struct.unpack_from('<HH', data, 8)
    raw4 = struct.unpack_from('<I', data, 4)[0]

    # 用体积反推验证宽高：假设 DXT5（1B/px）全 mip 链
    mip_total = 0
    ww, hh = w, h
    while ww >= 4 and hh >= 4:
        mip_total += max(ww, 4) * max(hh, 4)
        ww //= 2
        hh //= 2
    body = len(data) - 16
    size_ok = abs(body - mip_total) < max(256, mip_total * 0.05)

    return {
        "magic": "KTEX",
        "width": w,
        "height": h,
        "u32_at_4": raw4,
        "platform": None,     # 未解码
        "format": None,       # 未解码
        "header_size": 16,
        "total_size": len(data),
        "mip_chain_estimate": mip_total,
        "size_matches_dxt5": size_ok,
        "width_height_confidence": "已用体积反推验证" if size_ok else "体积对不上，存疑",
    }


# =============================================================================
# BILD —— 图集/符号索引
# =============================================================================
def parse_build(data):
    """解析 build.bin。

    [已解码] 头部（**已跨 9 个不同 build 交叉验证，布局一致**）：

        +0   char[4] magic "BILD"
        +4   u32     version（DST 实测为 6）
        +8   u32     未知 A  —— 与名字长度无关；同族资源的取值相同
                               （bee_build 与 bee_angry_build 都是 7），
                               疑为「总帧数」或内容计数。未解码。
        +12  u32     未知 B  —— 同上（bee_build 与 bee_angry_build 都是 9）
        +16  u32     build 名字长度  ★ 注意不是 +12！
        +20  ...     build 名字（UTF-8）
        ...  u32     num_atlases
        ...  num_atlases × (u32 长度 + 图集名)
        ...  u32     图集哈希（实测 0x4e5036ce / 0x06a8bb22 …）
        ...  u32     num_symbols
        ...  符号条目区（见下）

    ★ 踩过的坑：一开始我把 +12 当成名字长度，于是每个 build 的名字都读歪一个字段，
      连锁导致符号数读成 1313879758（那其实是哈希）。跨文件对照才看出来。

    [未解码] 符号条目区。观测到每个符号以 u32 hash 开头，随后是一批 f32
             （实测有 -6.525 / 93 / 61 这类值，像「顶点坐标 + 宽高」）。
             字段边界未定。原字节保留在 dump 模式里。

    [未解码] 未知字段 A / B。实测取值：
             abigail_attack_fx(2,15) · antlion_build(11,81) ·
             archive_centipede_build(12,56) · bearger_build(13,87) ·
             bee_build(7,9) · bee_angry_build(7,9)
             同族资源一致，但与名字长度、图集数、符号数都无相关性。
    """
    if data[:4] != b'BILD':
        return None
    r = Reader(data, 4)
    version = r.u32()
    unkA = r.u32()
    unkB = r.u32()
    name = r.str()
    num_atlases = r.u32()
    atlases = [r.str() for _ in range(num_atlases)]
    atlas_hash = r.u32()
    num_symbols = r.u32()
    header_end = r.pos
    return {
        "magic": "BILD",
        "version": version,
        "unkA": unkA,
        "unkB": unkB,
        "name": name,
        "num_atlases": num_atlases,
        "atlases": atlases,
        "atlas_hash": atlas_hash,
        "num_symbols": num_symbols,
        "header_size": header_end,
        "body_offset": header_end,
        "body_size": len(data) - header_end,
        "total_size": len(data),
    }


# =============================================================================
# ANIM —— 动画定义
# =============================================================================
def parse_anim(data):
    """解析 anim.bin。

    [已解码] 头部：
        +0  char[4] magic "ANIM"
        +4  u32     version（DST 实测为 4）
        +8  u32     总元素数（实测 704，疑为「帧×符号」引用总数）
        +12 u32     未知（实测 276）
        +16 u32     未知（实测 0）
        +20 u32     num_anims（实测 18）
        随后 num_anims 个「u32 长度 + 动画名」，紧接着是每段动画的数据。

    [部分解码] 动画数据区：名字后面紧跟一个 u32（疑为 hash 或标志），
               然后是帧数据。帧里含大量 f32，语义像
               （x, y, 缩放, 旋转, alpha）这类关键帧变换。
               字段边界尚未完全确定。

    [未解码] 符号名表：动画数据区里夹着一批可读的符号名
             （如 "Layer 5" / "fx" / "flower" / "fx_swirl_01"），
             它们是 build 的图层名，用于把帧数据映射到图集矩形。
             精确的索引方式待定。
    """
    if data[:4] != b'ANIM':
        return None
    r = Reader(data, 4)
    version = r.u32()
    total_elements = r.u32()
    unk12 = r.u32()
    unk16 = r.u32()
    num_anims = r.u32()

    anims = []
    for _ in range(num_anims):
        try:
            nm = r.str()
        except Exception:
            break
        anims.append({"name": nm, "name_bytes": 4 + len(nm)})
    name_table_end = r.pos

    return {
        "magic": "ANIM",
        "version": version,
        "total_elements": total_elements,
        "unk12": unk12,
        "unk16": unk16,
        "num_anims": num_anims,
        "anims": anims,
        "name_table_end": name_table_end,
        "total_size": len(data),
        "body_size": len(data) - name_table_end,
    }


# =============================================================================
# 找出文件里所有「长度前缀字符串」的位置（用于人工核对未解码区）
# =============================================================================
def scan_strings(data, minlen=2, maxlen=64):
    out = []
    for i in range(0, len(data) - 5):
        n = struct.unpack_from('<I', data, i)[0]
        if minlen <= n <= maxlen and i + 4 + n <= len(data):
            chunk = data[i + 4:i + 4 + n]
            # 全部是可打印 ASCII 才算
            if all(32 <= c < 127 for c in chunk):
                out.append((i, n, chunk.decode('ascii')))
    return out


# =============================================================================
# 载入一个 zip
# =============================================================================
def load_zip(path):
    z = zipfile.ZipFile(path)
    names = z.namelist()
    out = {"zip": path, "members": names}
    for key, pat in (("build", "build.bin"), ("anim", "anim.bin")):
        hit = [n for n in names if os.path.basename(n) == pat]
        out[key] = z.read(hit[0]) if hit else None
    tex = [n for n in names if n.endswith(".tex")]
    out["tex"] = [(n, z.read(n)) for n in tex]
    return out


# =============================================================================
# 命令行
# =============================================================================
def cmd_info(path):
    p = load_zip(path)
    print(f"══ {os.path.basename(path)} ══")
    print(f"  成员: {', '.join(p['members'])}")

    if p["tex"]:
        print()
        print("  ── 图集 (KTEX) ──")
        for nm, d in p["tex"]:
            k = parse_ktex(d)
            if k:
                print(f"    {nm}: {k['width']}×{k['height']}  "
                      f"头={k['header_size']}B  总={k['total_size']}B")
                print(f"      宽高置信度 : {k['width_height_confidence']}")
                print(f"      mip 链估算 : {k['mip_chain_estimate']}B  "
                      f"体积吻合(DXT5)={k['size_matches_dxt5']}")
                print(f"      [未解码] u32@4 = 0x{k['u32_at_4']:08x}"
                      f"（平台/格式的打包方式待定）")
            else:
                print(f"    {nm}: 非 KTEX（前 4 字节 {d[:4]!r}）")

    if p["build"]:
        print()
        print("  ── build.bin ──")
        b = parse_build(p["build"])
        print(f"    magic={b['magic']} version={b['version']}")
        print(f"    名字: {b['name']}")
        print(f"    图集数: {b['num_atlases']}  →  {b['atlases']}")
        print(f"    [未解码] 未知A={b['unkA']} 未知B={b['unkB']}")
        print(f"    图集哈希: 0x{b['atlas_hash']:08x}")
        print(f"    符号数: {b['num_symbols']}")
        print(f"    头 {b['header_size']}B / 体 {b['body_size']}B / 总 {b['total_size']}B")

    if p["anim"]:
        print()
        print("  ── anim.bin ──")
        a = parse_anim(p["anim"])
        print(f"    magic={a['magic']} version={a['version']}")
        print(f"    total_elements={a['total_elements']}  未知12={a['unk12']}  "
              f"未知16={a['unk16']}")
        print(f"    动画数: {a['num_anims']}")
        print(f"    名字表结束于 {a['name_table_end']}B / 总 {a['total_size']}B "
              f"（数据区 {a['body_size']}B）")


def cmd_anims(path):
    """列出动画名。

    ⚠️ anim.bin 里**动画名与帧数据是交织存放的**：
          u32 num_anims
          [ u32 长度 + 动画名 + 该动画的帧数据 ] × num_anims
       所以不能像 build.bin 那样先把名字表读完 —— 必须知道每段数据多长才能
       跳到下一个名字。而帧数据格式尚未完全解码，因此这里改用
       「扫描全部长度前缀字符串」的方式把名字捞出来。
       这对渲染够用（渲染只需要名字 + 帧数，帧数可从数据区反推）。
    """
    p = load_zip(path)
    if not p["anim"]:
        print("此 zip 没有 anim.bin")
        return
    a = parse_anim(p["anim"])
    print(f"num_anims（头部声明）= {a['num_anims']}")
    print()
    strs = scan_strings(p["anim"])
    # 动画名 vs 符号名：DST 的动画名多为 xxx_pre / xxx_loop / xxx_pst / xxx_idle
    # 这类小写+下划线；符号名多为 "Layer N" / "fx" / 文件内图层名。
    print("扫描到的字符串（按偏移，前 60）:")
    for off, n, s in strs[:60]:
        print(f"  0x{off:06x} len={n:3d}  {s}")
    print(f"  … 共 {len(strs)} 个")


def cmd_symbols(path):
    p = load_zip(path)
    if p["build"]:
        b = parse_build(p["build"])
        print(f"build.bin: name={b['name']}  图集={b['atlases']}  "
              f"符号数={b['num_symbols']}")
        print("（符号名不在 build.bin 里，它是纯哈希；名字在 anim.bin 的字符串区）")
    print()
    if not p["anim"]:
        print("（无 anim.bin）")
        return
    print("anim.bin 里的可读字符串:")
    for off, n, s in scan_strings(p["anim"])[:40]:
        print(f"  0x{off:06x} len={n:3d}  {s}")


def cmd_dump(path):
    p = load_zip(path)
    for key in ("build", "anim"):
        d = p[key]
        if not d:
            continue
        print(f"══ {key}.bin  前 128 字节 ══")
        for i in range(0, min(128, len(d)), 16):
            row = d[i:i + 16]
            hexs = ' '.join(f'{b:02x}' for b in row)
            asc = ''.join(chr(b) if 32 <= b < 127 else '.' for b in row)
            print(f"  {i:04x}  {hexs:<47}  {asc}")
        print()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    cmd, path = sys.argv[1], sys.argv[2]
    fn = {"info": cmd_info, "anims": cmd_anims,
          "symbols": cmd_symbols, "dump": cmd_dump}.get(cmd)
    if not fn:
        print(f"未知命令: {cmd}")
        return 1
    fn(path)
    return 0


if __name__ == '__main__':
    sys.exit(main())
