# -*- coding: utf-8 -*-
"""跨多个 build.bin 验证头部布局"""
import zipfile
import struct
import glob
import os

print(f"{'文件':<34} {'A@8':>6} {'B@0xc':>7} {'len@0x10':>9} {'名字':<26} {'符号数':>7}")
print('-' * 92)
for p in sorted(glob.glob('_animtest/*.zip'))[:12]:
    z = zipfile.ZipFile(p)
    if 'build.bin' not in z.namelist():
        continue
    d = z.read('build.bin')
    a = struct.unpack_from('<I', d, 8)[0]
    b = struct.unpack_from('<I', d, 12)[0]
    ln = struct.unpack_from('<I', d, 16)[0]
    name = d[20:20 + ln].decode('utf-8', 'replace')
    # 名字之后：num_atlases(u32) + (u32 len + str) * n
    off = 20 + ln
    natlas = struct.unpack_from('<I', d, off)[0]
    off += 4
    atlases = []
    for _ in range(natlas):
        al = struct.unpack_from('<I', d, off)[0]
        off += 4
        atlases.append(d[off:off + al].decode('utf-8', 'replace'))
        off += al
    hashv = struct.unpack_from('<I', d, off)[0]
    off += 4
    nsym = struct.unpack_from('<I', d, off)[0]
    off += 4
    print(f"{os.path.basename(p):<34} {a:>6} {b:>7} {ln:>9} {name:<26} {nsym:>7}")
    print(f"{'':<34} 图集={atlases} hash=0x{hashv:08x} 头结束@{off} 体={len(d)-off}B")
