# -*- coding: utf-8 -*-
"""test_drawcmd_neg.py —— DrawCmd 一致性判据（tools/check_drawcmd.js）的**反向测试**

为什么必须有这一支
    "离线渲染器与实时渲染器共用同一份绘制指令"这句话，只有在一个**能红**的判据
    守着的时侯才算事实；否则它只是"跑出来是绿的一行字"。
    本工程已经在"检查写好了 ≠ 检查生效过"上栽过多次（尤其是这条判据自己 ——
    它前后换过三版逻辑，其中两版是**永久绿**的：v1 比错了对象、v2 按 6 个顶点
    分组永远找不到，都因为"红得离谱"才被发现）。

做法
    拿一份**基准** drawcmd.json，逐个"动一个地方"，确认 check_drawcmd.js 变红：
      ① uv 改一点点        → 采到的不是同一块纹理
      ② xy 改一点点        → 摆的位置不同
      ③ 矩阵改动           → 整体位移/缩放不同
      ④ 少一个顶点         → 两边根本不是同一帧
      ⑤ 图集目录空掉       → 全部跳过 ⇒ "全一致"是空的（空判据保护）
      ⑥ 输入文件不存在 / 空 → 退出码 2，而不是"通过"
    并且先跑一遍**未篡改**的基准，确认它**是绿的** ——
    否则"改坏也红"可能只是因为它本来就红（那样这条反向测试什么都没证明）。

用法
    python tests/test_drawcmd_neg.py
退出码：0 全部符合预期 / 1 有不符合 / 2 环境缺失（找不到 node 或基准文件）
"""
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                       # 07-通用引擎
PROJ = os.path.dirname(ROOT)
CHECK = os.path.join(ROOT, "tools", "check_drawcmd.js")
DRAWCMD = os.path.join(PROJ, "06-引擎复刻", "_out", "drawcmd.json")
JSONDIR = os.path.join(PROJ, "06-引擎复刻", "_out", "json")


def find_node():
    """node 按 env → PATH → 托管路径 依次找；找不到就明说，不静默跳过。"""
    cand = [os.environ.get("NODE"), "node",
            r"C:\Users\admin\.workbuddy\binaries\node\versions\22.22.2-6\node.exe"]
    for c in cand:
        if not c:
            continue
        exe = c if os.path.isfile(c) else shutil.which(c)
        if exe:
            return exe
    return None


def run_check(node, drawcmd, json_dir):
    """跑一次 check_drawcmd.js，返回 (退出码, stdout)。"""
    p = subprocess.run([node, CHECK, "--drawcmd", drawcmd, "--json", json_dir],
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def mutate_line(obj, kind):
    """对 pig_build 那一条做一个定点篡改，返回新对象（不改原对象）。"""
    o = copy.deepcopy(obj)
    q = o["quads"][0]
    if kind == "uv":
        q["verts"][0][2] = round(q["verts"][0][2] + 0.01, 6)
    elif kind == "xy":
        q["verts"][0][0] = q["verts"][0][0] + 1.0
    elif kind == "mat":
        q["mat"][0] = q["mat"][0] + 0.5
    elif kind == "dropvert":
        q["verts"] = q["verts"][:-1]
    else:
        raise ValueError(kind)
    return o


def main():
    node = find_node()
    if not node:
        print("✘ 找不到 node（设环境变量 NODE 或装 node 22）")
        return 2
    if not os.path.isfile(DRAWCMD):
        print("✘ 找不到基准 %s\n  处置：先跑 06 的 tools/export_drawcmd.py" % DRAWCMD)
        return 2
    if not os.path.isdir(JSONDIR):
        print("✘ 找不到 build JSON 目录 %s" % JSONDIR)
        return 2

    lines = [ln for ln in open(DRAWCMD, encoding="utf-8").read().split("\n") if ln.strip()]
    objs = [json.loads(ln) for ln in lines]
    # 篡改对象固定挑 pig_build（第一个有 QUAD 的），并确保它真被比过
    idx = next((i for i, o in enumerate(objs) if o["build"] == "pig_build" and o.get("quads")), None)
    if idx is None:
        print("✘ drawcmd.json 里没有 pig_build 的 QUAD，无法定点篡改")
        return 2

    tmp = tempfile.mkdtemp(prefix="drawcmd_neg_")
    bad = []
    try:
        def write(objs2, name):
            p = os.path.join(tmp, name)
            with open(p, "w", encoding="utf-8", newline="\n") as f:
                for o in objs2:
                    f.write(json.dumps(o, ensure_ascii=False, separators=(",", ":")) + "\n")
            return p

        # ---- 0) 基准必须先绿：否则"改坏也红"什么都证明不了 ----
        base = write(objs, "base.json")
        rc, out = run_check(node, base, JSONDIR)
        n_ok = out.count("  OK ")
        skipped = 0
        for ln in out.split("\n"):
            if "  一致 " in ln and "跳过 " in ln:
                try:
                    skipped = int(ln.split("跳过 ")[1].split()[0])
                except (IndexError, ValueError):
                    skipped = -1
        print("基准：退出码 %d · OK 行 %d 条 · 跳过 %d 个" % (rc, n_ok, skipped))
        if rc != 0 or n_ok == 0:
            bad.append("基准未通过（退出码 %d）—— 反向测试前提不成立" % rc)
        if skipped != 0:
            bad.append("基准有 %d 个 build 被跳过 —— 覆盖面不全，" % skipped
                       + "「共用同一份指令」这句话在**没比过**的 build 上是空的")

        # ---- 1..4) 定点篡改，必须变红 ----
        cases = [
            ("uv", "uv 改 0.01", "顶点数不同|uv [0-9.]+e[-+]?[0-9]+"),
            ("xy", "xy 改 1.0", "xy [0-9.]+e[-+]?[0-9]+"),
            ("mat", "矩阵改 0.5", "mat\\[0\\] 超差"),
            ("dropvert", "少一个顶点", "顶点数不同"),
        ]
        for kind, desc, expect_re in cases:
            mod = list(objs)
            mod[idx] = mutate_line(objs[idx], kind)
            p = write(mod, "mut_%s.json" % kind)
            rc, out = run_check(node, p, JSONDIR)
            hit = __import__("re").search(expect_re, out) is not None
            if rc == 1 and hit:
                print("  ✔ %-14s → 退出码 1，报错含 %r" % (desc, expect_re))
            else:
                bad.append("%s 没有按预期变红（退出码 %d，匹配 %r=%s）"
                           % (desc, rc, expect_re, hit))
                print("  ✘ %-14s → 退出码 %d，匹配 %r=%s" % (desc, rc, expect_re, hit))

        # ---- 5) 空判据保护：JSON 目录空掉 ⇒ 全跳过 ⇒ 必须红，不能"全绿" ----
        empty = os.path.join(tmp, "empty_json")
        os.makedirs(empty, exist_ok=True)
        rc, out = run_check(node, base, empty)
        if rc == 1 and "这条判据是空的" in out:
            print("  ✔ %-14s → 退出码 1，报「这条判据是空的」" % "全跳过")
        else:
            bad.append("全跳过时没有触发空判据保护（退出码 %d）" % rc)
            print("  ✘ 全跳过 → 退出码 %d" % rc)

        # ---- 6) 输入缺失必须是 2，不能是 0 ----
        rc, out = run_check(node, os.path.join(tmp, "nope.json"), JSONDIR)
        if rc == 2:
            print("  ✔ %-14s → 退出码 2" % "输入不存在")
        else:
            bad.append("输入不存在时应返回 2，实际 %d" % rc)
            print("  ✘ 输入不存在 → 退出码 %d" % rc)

        p = os.path.join(tmp, "empty.json")
        open(p, "w", encoding="utf-8").close()
        rc, out = run_check(node, p, JSONDIR)
        if rc == 2:
            print("  ✔ %-14s → 退出码 2" % "输入为空")
        else:
            bad.append("输入为空时应返回 2，实际 %d" % rc)
            print("  ✘ 输入为空 → 退出码 %d" % rc)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("")
    if bad:
        print("✘ %d 项不符合预期：" % len(bad))
        for b in bad:
            print("   - " + b)
        return 1
    print("✔ 反向测试全部符合预期：判据会红、空跑会红、缺输入报 2")
    return 0


if __name__ == "__main__":
    sys.exit(main())
