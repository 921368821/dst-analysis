# -*- coding: utf-8 -*-
"""
search_build_layout.py —— 用「守恒约束」搜索 build.bin 符号表布局

核心思路
    条目不等长（实测 bee_build 的 body=1732=4×433，433 是质数，
    不可能是等长条目的整数倍），所以要找的是一套**可变长记录格式**。
    可变长格式必然有一个「数量字段」驱动循环。

硬约束（都必须同时满足，缺一不可）
    C1 总数守恒：逐条读下来要**正好**停在文件末尾（不允许越界/剩余）
    C2 矩形合法：每个矩形 x+w<=图集宽, y+h<=图集高
    C3 版本一致：所有样本的 version 都是 6

做法
    对每个候选「记录格式」定义（字段序列），在 body 里逐个起始偏移试读，
    看哪套定义能在**多个不同 build** 上同时满足 C1+C2。
    只有跨样本都成立的格式才值得写进解析器。
"""
import zipfile
import struct
import sys
import os
import glob

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import zipanim  # noqa: E402


class R:
    """带边界的读取器，越界就抛异常（让 C1 能被测出来）"""

    def __init__(self, d, o=0):
        self.d, self.o, self.limit = d, o, len(d)

    def u32(self):
        if self.o + 4 > self.limit:
            raise EOFError()
        v = struct.unpack_from('<I', self.d, self.o)[0]
        self.o += 4
        return v

    def f32(self):
        if self.o + 4 > self.limit:
            raise EOFError()
        v = struct.unpack_from('<f', self.d, self.o)[0]
        self.o += 4
        return v

    def skip(self, n):
        self.o += n
        if self.o > self.limit:
            raise EOFError()


def sane_rect(x, y, w, h, W, H, tol=0.6):
    """矩形是否落在图集内。tol 给一点浮点余量。"""
    if not (w > 0 and h > 0):
        return False
    if w > W * 4 or h > H * 4:
        return False
    if x < -tol or y < -tol:
        return False
    if x + w > W + tol or y + h > H + tol:
        return False
    return True


def try_layout(data, start, n_symbols, W, H, frame_size, hdr_extra=0):
    """试读一种布局。

    假设：
        [可选 hdr_extra 字节]
        n_symbols × {
            u32 hash
            u32 nframes
            nframes × frame_size 字节（帧数据）
        }
    返回 (是否正好用尽, 解析出的矩形数, 合法矩形数)
    """
    r = R(data, start)
    try:
        r.skip(hdr_extra)
        rects = 0
        good = 0
        for _ in range(n_symbols):
            r.u32()                  # hash
            nf = r.u32()             # 帧数
            if nf > 4096:
                return False, 0, 0
            for _ in range(nf):
                # 帧数据里假设前 16 字节是 4 个 f32，其中含一个矩形
                base = r.o
                a, b, c, e = r.f32(), r.f32(), r.f32(), r.f32()
                r.o = base + frame_size
                if r.o > r.limit:
                    return False, 0, 0
                # 试两种读法：后两个是 w,h
                rects += 1
                if sane_rect(a, b, c, e, W, H) or sane_rect(c, e, a, b, W, H):
                    good += 1
    except EOFError:
        return False, 0, 0
    exact = (r.o == len(data))
    return exact, rects, good


def main():
    zen = ['_animtest/bee_build.zip', '_animtest/abigail_attack_fx.zip',
           '_animtest/bearger_build.zip', '_animtest/antlion_build.zip']
    zen = [p for p in zen if os.path.exists(p)] + \
          [p for p in sorted(glob.glob('_animtest/*.zip')) if p not in zen]

    print('════ build.bin 符号表布局搜索 ════')
    print('目标：找到一套在**多个不同 build** 上同时满足 C1（用尽）+ C2（矩形合法）的布局')
    print()

    FRAME_SIZES = [16, 20, 24, 28, 32, 36, 40, 48, 56, 64]
    HDR_EXTRA = [0, 4, 8, 12]

    results = {}

    for p in zen[:24]:
        z = zipfile.ZipFile(p)
        if 'build.bin' not in z.namelist():
            continue
        bd = z.read('build.bin')
        b = zipanim.parse_build(bd)
        W = H = 0
        for nm in [n for n in z.namelist() if n.endswith('.tex')]:
            k = zipanim.parse_ktex(z.read(nm))
            if k:
                W, H = k['width'], k['height']
                break
        if not W:
            continue
        name = os.path.basename(p)
        for fs in FRAME_SIZES:
            for he in HDR_EXTRA:
                exact, rects, good = try_layout(
                    bd, b['header_size'], b['num_symbols'], W, H, fs, he)
                if exact and rects > 0 and good == rects:
                    key = (fs, he)
                    results.setdefault(key, []).append(
                        (name, rects, b['num_symbols']))

    if not results:
        print('✘ 没有任何 (frame_size, hdr_extra) 组合能在样本上同时满足 C1+C2')
        print('  → 说明「hash + 帧数 + 等长帧」这个模型不对，需要换模型')
        print('  （这本身是有价值的否定结论：排除了一大类假设）')
        return

    print('满足 C1+C2 的候选布局:')
    for (fs, he), hits in sorted(results.items(), key=lambda x: -len(x[1])):
        print(f'  frame_size={fs:<3} hdr_extra={he:<3} '
              f'→ 在 {len(hits)} 个样本上成立')
        for nm, rects, nsym in hits[:4]:
            print(f'      {nm:<38} 符号={nsym} 矩形={rects}')


if __name__ == '__main__':
    main()
