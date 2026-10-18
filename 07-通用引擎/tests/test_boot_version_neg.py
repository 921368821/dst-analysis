# -*- coding: utf-8 -*-
"""test_boot_version_neg.py —— 版本指纹判据（tools/boot_version_guard.py）的反向测试

为什么必须有这一支
    C8 那次事故的本质是：**判据只核「两处是否一致」，而两处一起过期时它是绿的**。
    新判据（实现指纹）能不能抓住它，只有把「改了实现但不升版本」这个动作
    真的演一遍才知道。否则它又是一行"跑出来是绿的字"。

做法
    全程在临时目录里操作副本（环境变量 BVG_* 指过去），**不碰真实工程文件**：
      ① 未篡改基准              → 必须 0（否则后面"变红"可能因为它本来就红）
      ② 只改注释                → 必须 0（不能因为加注释就要求升版本）
      ③ 改一行实现代码          → 必须 1（这正是 C8 的形状）
      ④ 发布会话记录最新版本降级 → 必须 1
      ⑤ --bump 之后            → 必须 0，且版本号 +1，且 --check 仍 0
      ⑥ 基线记录文件被删         → 必须 1（"没有基线"不许当成"通过"）
      ⑦ 手改字面量但不改记录     → 必须 1

用法
    python tests/test_boot_version_neg.py
退出码：0 全部符合预期 / 1 有不符合 / 2 环境缺失
"""

from __future__ import print_function

import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                      # 07-通用引擎
TOOL = os.path.join(ROOT, "tools", "boot_version_guard.py")
BOOT = os.path.join(ROOT, "rt", "rt_boot.lua")
JS = os.path.join(ROOT, "rt", "render_atlas.js")
JS2 = os.path.join(ROOT, "rt", "render_batch.js")
CHECKLIST = os.path.join(ROOT, "deploy", "发布检查单.md")

PY = sys.executable


def rd(p):
    with io.open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def wr(p, s):
    with io.open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


class Env(object):
    """临时目录里的一套输入副本。"""

    def __init__(self, tmp, cur):
        self.tmp = tmp
        self.cur = cur
        self.boot = os.path.join(tmp, "rt_boot.lua")
        self.js = os.path.join(tmp, "render_atlas.js")
        self.js2 = os.path.join(tmp, "render_batch.js")
        self.rec = os.path.join(tmp, "_boot_version.json")
        self.chk = os.path.join(tmp, "发布检查单.md")
        self.proto = os.path.join(tmp, "protocol.md")
        shutil.copy(BOOT, self.boot)
        shutil.copy(JS, self.js)
        shutil.copy(JS2, self.js2)
        shutil.copy(CHECKLIST, self.chk)
        wr(self.proto, "举例：`%s`\n" % cur)

    def env(self):
        e = dict(os.environ)
        e.update({"BVG_BOOT": self.boot, "BVG_ENGINE_JS": self.js,
                  "BVG_ENGINE_JS2": self.js2,
                  "BVG_RECORD": self.rec, "BVG_CHECKLIST": self.chk,
                  "BVG_PROTOCOL": self.proto})
        return e

    def run(self, *args):
        p = subprocess.run([PY, "-u", TOOL] + list(args), capture_output=True,
                           text=True, encoding="utf-8", errors="replace",
                           env=self.env())
        return p.returncode, (p.stdout or "") + (p.stderr or "")


CASES = []


def case(name, fn):
    CASES.append((name, fn))
    return fn


def main():
    for p in (TOOL, BOOT, JS, JS2, CHECKLIST):
        if not os.path.isfile(p):
            print("  [SKIP] 缺文件：%s" % p)
            return 2

    ok = 0
    bad = 0
    # ★★ 版本号**不写死**：从真实的 rt_boot.lua 读当前版本，再派生 N-1 / N+1 / N+2。
    #   原来这里写死 rt_boot/6 与 /7 —— 2026-10-18 一升到 /7，四条用例同时变成
    #   「没抓到」的假红（因为 re.sub("rt_boot/6", …) 在 /7 上命中 0 处）。
    #   教训与 README 那条同源：**用例里写死的「当前值」会在被测对象前进时静默过期**。
    CUR = (re.search(r'function\s+M\.version\(\)\s*return\s*"([^"]+)"', rd(BOOT)) or [None, None])[1]
    if not CUR:
        print("  ✘ 读不出 rt_boot.lua 的版本字面量",
              "（判据锚点失效，下面的用例全部无效）")
        return 2
    _num = re.search(r"(\d+)$", CUR)
    NUM = int(_num.group(1))
    STEM = CUR[: _num.start(1)]
    OLD, NXT, FAR = STEM + str(NUM - 1), STEM + str(NUM + 1), STEM + str(NUM + 2)

    tmp = tempfile.mkdtemp(prefix="bvg_")
    try:
        e = Env(tmp, CUR)

        # ① 先建基线，再确认未篡改时是绿的
        rc, out = e.run("--init")
        base_ok = (rc == 0)
        rc, out = e.run("--check")
        if base_ok and rc == 0:
            print("  ✔ ① 未篡改基准为绿（--init 后 --check 退出 0）")
            ok += 1
        else:
            print("  ✘ ① 未篡改基准不是绿的（rc=%d）—— 后面所有'变红'都不算数\n%s"
                  % (rc, out))
            bad += 1

        # ② 只改注释 → 必须仍绿
        s = rd(e.boot)
        wr(e.boot, s + "\n-- 这只是一行注释，不改任何行为\n")
        rc, out = e.run("--check")
        if rc == 0:
            print("  ✔ ② 只改注释仍然绿（没有把'改注释'误判成'改行为'）")
            ok += 1
        else:
            print("  ✘ ② 只改注释就红了 —— 判据过严，会被开发者绕过\n%s" % out)
            bad += 1

        # ③ 改一行实现代码但不升版本 → 必须红（C8 的形状）
        s = rd(e.boot)
        wr(e.boot, s.replace("local ACT_LIMIT = 12", "local ACT_LIMIT = 13", 1))
        rc, out = e.run("--check")
        if rc == 1 and "实现变了" in out:
            print("  ✔ ③ 改了实现却没升版本 → 红，且报出「实现变了，版本号没升」")
            ok += 1
        else:
            print("  ✘ ③ 改实现未升版本没被抓到（rc=%d）\n%s" % (rc, out))
            bad += 1
        # 还原实现，回到基准
        shutil.copy(BOOT, e.boot)

        # ④ 发布记录里最新版本降级 → 必须红
        c = rd(e.chk)
        wr(e.chk, re.sub(re.escape(CUR), OLD, c))
        rc, out = e.run("--check")
        if rc == 1 and "发布检查单" in out:
            print("  ✔ ④ 发布记录停在旧版本 → 红")
            ok += 1
        else:
            print("  ✘ ④ 发布记录降级没被抓到（rc=%d）\n%s" % (rc, out))
            bad += 1
        shutil.copy(CHECKLIST, e.chk)

        # ⑤ --bump：版本 +1、字面量真的改了，且**发布记录没跟上时仍然红**
        #     —— 这条语义是刻意的：bump 只负责「代码 + 指纹基线」，
        #        发布记录是人写的事实，机器不能替他编一行。
        rc, out = e.run("--bump")
        v2 = re.search(r'function\s+M\.version\(\)\s*return\s*"([^"]+)"', rd(e.boot))
        rc2, out2 = e.run("--check")
        bumped = (rc == 0 and v2 and v2.group(1) == NXT)
        # 此时应当**只**卡在发布记录（/6 vs /7）
        only_checklist = (rc2 == 1 and ("发布检查单最新版本是 rt_boot/%d" % NUM) in out2
                          and "实现变了" not in out2 and "版本号不一致" not in out2)
        # 补上发布记录后必须变绿
        c2 = rd(e.chk)
        wr(e.chk, re.sub(re.escape(CUR), NXT, c2))
        rc3, out3 = e.run("--check")
        if bumped and only_checklist and rc3 == 0:
            print("  ✔ ⑤ --bump → %s；发布记录未跟上时红；补上后绿" % NXT)
            ok += 1
        else:
            print("  ✘ ⑤ --bump 行为不对（rc=%d/%d/%d, 字面量=%s, 只卡发布记录=%s）\n%s\n%s\n%s"
                  % (rc, rc2, rc3, v2.group(1) if v2 else None, only_checklist,
                     out, out2, out3))
            bad += 1

        # ⑥ 改**批渲染**的投影公式（render_batch.js）→ 必须红
        #    ★ 本轮加这条的理由：`render_batch.js` 原来**不在指纹里**，
        #      于是「新增一个实现文件」不会让指纹变 —— 判据覆盖不到的那部分，
        #      在输出里和「已覆盖且正确」长得一模一样（C8 的同一个形状）。
        e.run("--init")
        s = rd(e.js2)
        mut = s.replace("return { x: sx + scale * p.x, y: sy - scale * p.y };",
                        "return { x: sx + scale * p.x, y: sy + scale * p.y };", 1)
        if mut == s:
            print("  ✘ ⑥ 锚点过期：render_batch.js 里找不到那句投影（判据没人守了）")
            bad += 1
        else:
            wr(e.js2, mut)
            rc, out = e.run("--check")
            if rc == 1 and "实现变了" in out:
                print("  ✔ ⑥ 改了批渲染的投影公式却没升版本 → 红（新纳入指纹的文件真的在守）")
                ok += 1
            else:
                print("  ✘ ⑥ render_batch.js 不在指纹覆盖内（rc=%d）\n%s" % (rc, out))
                bad += 1
            shutil.copy(JS2, e.js2)

        # ⑦ 基线记录被删 → 必须红（不能让"没有基线"等于"通过"）
        os.remove(e.rec)
        rc, out = e.run("--check")
        if rc == 1 and "没有基线指纹" in out:
            print("  ✔ ⑦ 删掉基线记录 → 红（不是静默放行）")
            ok += 1
        else:
            print("  ✘ ⑦ 缺基线记录时没报红（rc=%d）\n%s" % (rc, out))
            bad += 1

        # ⑧ 手改字面量但不改记录 → 必须红
        e.run("--init")
        s = rd(e.boot)
        wr(e.boot, re.sub(r'function M\.version\(\) return "%s"' % re.escape(NXT),
                          'function M.version() return "%s"' % FAR, s, count=1))
        rc, out = e.run("--check")
        if rc == 1 and "版本号不一致" in out:
            print("  ✔ ⑧ 只改字面量不改记录 → 红")
            ok += 1
        else:
            print("  ✘ ⑧ 字面量与记录不同步没被抓到（rc=%d）\n%s" % (rc, out))
            bad += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("-" * 66)
    print("  符合预期 %d · 不符合 %d" % (ok, bad))
    if bad:
        print("  ✘ 反向测试没有全过 —— 这条判据还不能信")
        return 1
    print("  ✔ 全部符合预期：这条判据在应当红的地方都会红")
    return 0


if __name__ == "__main__":
    sys.exit(main())
