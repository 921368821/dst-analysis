#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
boot_version_guard.py —— 让「模型版本号」与「引擎实现的指纹」绑死。

═══════════════════════════════════════════════════════════════════════
为什么要有这个工具（C8 的根治）
═══════════════════════════════════════════════════════════════════════
P43 抓到过一次真实事故：P41 把 `act_targets` 从「全表线性扫」换成了
「空间索引」，**引擎行为确实变了**，发布记录也写了 `rt_boot/6`，
但 `rt/rt_boot.lua` 的 `M.version()` 一直停在 `"rt_boot/5"`。

判据 B6 当时是绿的 —— 因为它只核「`/healthz` 报的数 == `rt_boot.lua` 写的数」。
**两处一起停在旧值时，一致性判据永远绿。**

⇒ 一致性 ≠ 正确性。要抓这类偏差，版本号必须与**第三方**绑定。
这里选「实现文件的指纹」：引擎代码的**非注释内容**一变，指纹就变；
指纹变了而版本号没动 ⇒ 说明「改了引擎没升版本」，直接红。

归一化规则（很关键，否则天天误报）：
  · 去掉纯注释行（`--` / `//` / `#` 开头，以及 `/* ... */` 块）
  · 去掉空行、行尾空白
  · 把 `rt_boot/<数字>` 一律替成 `rt_boot/<N>`（升版本本身不改指纹）
  · 把 `function M.version() ...` 整行替换掉（同上）

用法：
    python tools/boot_version_guard.py --check     # 判据（run_all ②j 调这个）
    python tools/boot_version_guard.py --bump      # 升一版：改字面量 + 重算指纹
    python tools/boot_version_guard.py --show      # 打印当前指纹与版本

退出码：0 一致 / 1 不一致 / 2 输入缺失
"""

from __future__ import print_function, unicode_literals

import hashlib
import io
import json
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOLS)                     # 07-通用引擎

# ★ 允许环境变量覆盖（只为反向测试能把三个输入指到临时副本）。
#   默认行为一个字节都不变 —— 生产调用不带任何环境变量。
BOOT = os.environ.get("BVG_BOOT") or os.path.join(PROJECT, "rt", "rt_boot.lua")
RECORD = os.environ.get("BVG_RECORD") or os.path.join(PROJECT, "rt", "_boot_version.json")
CHECKLIST = os.environ.get("BVG_CHECKLIST") or os.path.join(PROJECT, "deploy", "发布检查单.md")

# 参与指纹的文件：它们是「引擎行为」本身。
# ⚠️ 不要把 protocol.md / server.py 放进来 —— 协议版本另有 B7 守，
#    混进来会让「改个 HTTP 路由」也要求升模型版本，噪声太大。
ENGINE_JS = os.environ.get("BVG_ENGINE_JS") or os.path.join(PROJECT, "rt", "render_atlas.js")
# ★★ 2026-10-18（本轮接入口时补的）：`render_batch.js` 里是**批渲染的投影/打包数学**
#   （C2），它绝对是「引擎实现」。第一版只把 `render_atlas.js` 算进指纹 ——
#   于是**新增一个实现文件，指纹不变** ⇒ 改了批路径的 `toScreen` 公式、
#   版本号照样绿。这正是 C8 的形状（「判据覆盖不到的那部分，看起来和通过一模一样」），
#   只是换了个藏身处。
ENGINE_JS2 = os.environ.get("BVG_ENGINE_JS2") or os.path.join(PROJECT, "rt", "render_batch.js")
FINGERPRINT_FILES = [BOOT, ENGINE_JS, ENGINE_JS2]

VER_RE = re.compile(r'^\s*function\s+M\.version\(\)\s*return\s*"([^"]+)"', re.M)


def read(path):
    with io.open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_comments(text):
    """去掉注释与空行，只留「会改变行为的那些行」。

    ★ 为什么不用真正的语法分析：这两个文件我们自己在维护，
      用「行首注释 + 块注释」两规则足够，而且**规则本身可解释**。
      相反，引一个 Lua 解析器会让本工具的失败模式变成「解析器挂了」，
      与本判据要防的东西（版本漂移）无关。
    """
    out = []
    in_block = False
    for raw in text.splitlines():
        line = raw.strip()
        if in_block:
            if "*/" in line:
                in_block = False
                line = line.split("*/", 1)[1].strip()
            else:
                continue
        if line.startswith("/*"):
            if "*/" not in line:
                in_block = True
            continue
        if not line:
            continue
        if line.startswith("--") or line.startswith("//") or line.startswith("#"):
            continue
        out.append(line.rstrip())
    return out


def normalize(lines):
    """把「版本号本体」从指纹里抹掉 —— 升版本这一步不该改指纹。"""
    norm = []
    for line in lines:
        if re.match(r'^function\s+M\.version\(\)', line):
            norm.append("function M.version() return <VER>")
            continue
        line = re.sub(r"rt_boot/\d+", "rt_boot/<N>", line)
        norm.append(line)
    return norm


def fingerprint():
    """返回 (hex, 每文件行数明细)。任一文件缺失返回 (None, 原因)。"""
    h = hashlib.sha256()
    detail = []
    for path in FINGERPRINT_FILES:
        if not os.path.isfile(path):
            return None, "缺文件: %s" % os.path.basename(path)
        lines = normalize(strip_comments(read(path)))
        detail.append("%s=%d 行" % (os.path.basename(path), len(lines)))
        h.update(("\n".join(lines) + "\n").encode("utf-8"))
    return h.hexdigest()[:16], " · ".join(detail)


def declared_version():
    src = read(BOOT)
    m = VER_RE.search(src)
    return (m.group(1) if m else None)


def record():
    if not os.path.isfile(RECORD):
        return None
    try:
        with io.open(RECORD, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def checklist_versions():
    """发布检查单里出现过的所有 `rt_boot/N`。"""
    try:
        txt = read(CHECKLIST)
    except OSError:
        return []
    return [int(x) for x in re.findall(r"rt_boot/(\d+)", txt)]


def check(verbose=False):
    ver = declared_version()
    if ver is None:
        print("  ✘ rt_boot.lua 里找不到 M.version() 的字面量（判据锚点失效）")
        return 1
    fp, detail = fingerprint()
    if fp is None:
        print("  ✘ %s" % detail)
        return 2
    rec = record()
    if rec is None:
        print("  ✘ 缺 %s —— 没有基线指纹，本判据无从判定" % os.path.basename(RECORD))
        print("    修法：python tools/boot_version_guard.py --bump")
        return 1

    bad = 0
    if rec.get("version") != ver:
        print("  ✘ 版本号不一致：rt_boot.lua 写 %s，指纹记录写 %s"
              % (ver, rec.get("version")))
        bad += 1
    if rec.get("fingerprint") != fp:
        print("  ✘ **引擎实现变了，版本号没升**：")
        print("      记录指纹 %s（%s）" % (rec.get("fingerprint"), rec.get("detail")))
        print("      当前指纹 %s（%s）" % (fp, detail))
        print("    ⇒ 这正是 C8 那类事故（P41 改了 act_targets，版本停在 /5）。")
        print("      确实改了行为就 --bump；只是改注释不会走到这里（注释已剔除）。")
        bad += 1
    # 发布记录里必须出现过当前版本号，且**最大的那个**就是当前版本。
    vers = checklist_versions()
    if not vers:
        print("  ✘ 发布检查单里找不到任何 `rt_boot/N` —— 发布记录不在了")
        bad += 1
    else:
        cur_n = int(re.search(r"(\d+)$", ver).group(1)) if re.search(r"(\d+)$", ver) else None
        if cur_n is None:
            print("  ✘ 版本号格式不是 rt_boot/<数字>：%s" % ver)
            bad += 1
        elif max(vers) != cur_n:
            print("  ✘ 发布检查单最新版本是 rt_boot/%d，代码里是 %s"
                  % (max(vers), ver))
            bad += 1
        elif cur_n not in vers:
            print("  ✘ 发布检查单里没有记录 %s（升了版本但没写发布记录）" % ver)
            bad += 1

    if bad == 0:
        print("  ✔ 版本 %s · 指纹 %s（%s）· 发布记录最新 %s"
              % (ver, fp, detail, ver))
        return 0
    return 1


def bump():
    """升一版：版本号 +1，重写 rt_boot.lua 的字面量，重算指纹写记录。"""
    ver = declared_version()
    if ver is None:
        print("  ✘ 找不到 M.version()，无法 bump")
        return 2
    m = re.search(r"(\d+)$", ver)
    if not m:
        print("  ✘ 版本号格式不是 rt_boot/<数字>：%s" % ver)
        return 2
    old_n = int(m.group(1))
    new_ver = ver[: m.start(1)] + str(old_n + 1)

    src = read(BOOT)
    # ★ 只替换**真正那一行**（行首锚定），不碰注释里引用的同一句
    new_src, n = VER_RE.subn('function M.version() return "%s"' % new_ver, src, count=1)
    if n != 1:
        print("  ✘ 替换 M.version() 失败（命中 %d 处）" % n)
        return 2
    # 保留原文件的换行符风格
    with io.open(BOOT, "w", encoding="utf-8", newline="") as f:
        f.write(new_src)
    # 其它文件里引用旧版本号的**说明性文字**不动（protocol.md 由 B6 之外的人维护），
    # 但协议文档里那句举例必须跟着走，否则「文档举例 = 旧版本」又是一处漂移。
    proto = os.environ.get("BVG_PROTOCOL") or os.path.join(PROJECT, "rt", "protocol.md")
    if os.path.isfile(proto):
        ptxt = read(proto)
        pnew = re.sub(re.escape(ver) + r"(?=[^0-9])", new_ver, ptxt)
        if pnew != ptxt:
            with io.open(proto, "w", encoding="utf-8", newline="") as f:
                f.write(pnew)

    fp, detail = fingerprint()
    with io.open(RECORD, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps({
            "version": new_ver,
            "fingerprint": fp,
            "detail": detail,
            "note": "由 tools/boot_version_guard.py --bump 生成；不要手改 fingerprint",
        }, ensure_ascii=False, indent=2) + "\n")
    print("  ✔ 已升版本：%s → %s（指纹 %s，%s）" % (ver, new_ver, fp, detail))
    print("    下一步：在 deploy/发布检查单.md 的发布记录表**最上面**加一行 %s" % new_ver)
    return 0


def init_record():
    """只建基线（不改版本号）。用于「判据此前不存在」的首次接入。"""
    ver = declared_version()
    if ver is None:
        print("  ✘ 找不到 M.version()")
        return 2
    fp, detail = fingerprint()
    if fp is None:
        print("  ✘ %s" % detail)
        return 2
    with io.open(RECORD, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps({
            "version": ver,
            "fingerprint": fp,
            "detail": detail,
            "note": "由 tools/boot_version_guard.py --init 生成；不要手改 fingerprint",
        }, ensure_ascii=False, indent=2) + "\n")
    print("  ✔ 已建基线：%s · 指纹 %s（%s）" % (ver, fp, detail))
    return 0


def main():
    args = sys.argv[1:]
    if not args or "--help" in args or "-h" in args:
        print(__doc__)
        return 0
    if "--init" in args:
        return init_record()
    if "--bump" in args:
        return bump()
    return check(verbose="--verbose" in args or "-v" in args)


if __name__ == "__main__":
    sys.exit(main())
