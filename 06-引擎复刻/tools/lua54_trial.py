#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""lua54_trial.py —— C7 的**运行面**结论：14 个入口在 Lua 5.2+ 上到底能不能跑

═══════════════════════════════════════════════════════════════════════════════
为什么还需要这个工具（`lua_version_scan.py` 已经量过编译面了）
═══════════════════════════════════════════════════════════════════════════════
**编译通过 ≠ 能跑**。5.2+ 移走了 `loadstring` / `setfenv` / `unpack` 等全局函数，
这些是在**执行期**才炸的（`attempt to call a nil value (global 'loadstring')`），
编译期一个字都看不出来。

所以结论必须分两层给：
  ① 编译面：5.1 有 2 个文件编不过（`weather.lua` 的 60 upvalue 上限 + 一个坏文件）；
     5.2/5.3/5.4 只剩那 1 个坏文件（它在**所有**版本下都编不过 ⇒ 与迁移无关）。
  ② 运行面：本工具。给 `host/compat52.lua` 垫片，逐个跑入口，报 PASS/FAIL 与首个阻塞。

★ 判据的写法（避免"跑了一遍就宣布成功"）：
  · 每个入口同时在 **5.1（基线）** 与 **5.4 + 垫片** 下跑；
  · 只有当"5.1 通过、5.4 也通过"才算迁移可行的那一条 ——
    5.1 本来就不过的入口，不能拿 5.4 的失败去算迁移成本（那是**既有缺口**，
    两个版本一样，与本议题无关）。这一点必须分开报，否则数字会互相污染。

用法：
    python tools/lua54_trial.py                全部入口（约 3~6 分钟）
    python tools/lua54_trial.py --only tests,mech
    python tools/lua54_trial.py --json _out/lua54_trial.json
退出码：0 = 迁移面**没有新增失败**（5.1 能过的 5.4 也能过）；
        1 = 有新增失败（= 迁移还需要补东西，输出里给出首个阻塞）。
⚠️ 刻意**不**接进 `tools/check_all.sh`：迁移还没采纳（宿主的正式运行时仍是 5.1），
   把它变成常驻红项只会训练人忽略红色。等真的切换运行时，再把它接进去。
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.dirname(HERE)
ROOT = os.path.dirname(ENGINE)
RUNNER = os.path.join(ROOT, "03-参考架构", "_run_lua.py")
PRELUDE = os.path.join(ENGINE, "host", "compat52.lua")

ENTRIES = ["run", "batch", "player", "play", "full", "render", "seasons",
           "equip", "burn", "perish", "tests", "mech", "reachability", "world"]

PASS_RE = re.compile(r"^\s+(5\.[0-9]|Lua [0-9.]+|\S+)\s+PASS", re.M)


def run_entry(py, version, entry, prelude=False, timeout=300):
    cmd = [py, "-u", RUNNER, version]
    if prelude:
        cmd += ["--prelude", "host/compat52.lua"]
    cmd.append(os.path.join(ENGINE, entry + ".lua"))
    try:
        p = subprocess.run(cmd, cwd=ENGINE, capture_output=True, text=True,
                           timeout=timeout, encoding="utf-8", errors="replace")
    except subprocess.TimeoutExpired:
        return {"ok": False, "why": "超时 %d s" % timeout, "out": ""}
    out = (p.stdout or "") + (p.stderr or "")
    ok = bool(re.search(r"^\s+\S+\s+PASS\s*$", out, re.M))
    if ok:
        return {"ok": True, "why": "", "out": out}
    # 提取首个阻塞：Lua 错误行优先，其次 FAIL 行
    why = ""
    for m in re.finditer(r"^.*(LuaError|Traceback|!!! .*|attempt to .*|error loading code:.*)$",
                         out, re.M):
        why = m.group(0).strip()
        break
    if not why:
        for m in re.finditer(r"^\s+\S+\s+FAIL.*$", out, re.M):
            why = m.group(0).strip()
            break
    return {"ok": False, "why": why[:300] or ("退出码 %d" % p.returncode), "out": out}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="逗号分隔的入口名")
    ap.add_argument("--json", default=None)
    ap.add_argument("--py", default=sys.executable)
    a = ap.parse_args()

    entries = [x.strip() for x in a.only.split(",") if x.strip()] or ENTRIES
    if not os.path.isfile(RUNNER):
        print("✘ 找不到 runner：%s" % RUNNER)
        return 2
    if not os.path.isfile(PRELUDE):
        print("✘ 找不到垫片：%s" % PRELUDE)
        return 2

    print("═" * 78)
    print("  C7 运行面：入口在 5.1（基线）与 5.4 + host/compat52.lua 下的对照")
    print("  %d 个入口：%s" % (len(entries), ", ".join(entries)))
    print("═" * 78)

    rows = []
    for e in entries:
        sys.stdout.write("  %-13s 5.1 ... " % e)
        sys.stdout.flush()
        r51 = run_entry(a.py, "5.1", e)
        sys.stdout.write(("PASS" if r51["ok"] else "FAIL") + " ｜ 5.4+垫片 ... ")
        sys.stdout.flush()
        r54 = run_entry(a.py, "5.4", e, prelude=True)
        print("PASS" if r54["ok"] else "FAIL")
        rows.append({"entry": e, "v51": r51["ok"], "v54": r54["ok"],
                     "why51": r51["why"], "why54": r54["why"]})
        if not r51["ok"]:
            print("      5.1 也没过（既有缺口，不计入迁移成本）：%s" % r51["why"][:120])
        if not r54["ok"] and r51["ok"]:
            print("      ✘ 迁移新增失败：%s" % r54["why"][:200])

    base_ok = [r for r in rows if r["v51"]]
    migrated = [r for r in base_ok if r["v54"]]
    new_fail = [r for r in base_ok if not r["v54"]]

    print()
    print("① 对照表")
    print("   %-13s %8s %10s %s" % ("入口", "5.1", "5.4+垫片", "备注"))
    for r in rows:
        note = ""
        if not r["v51"]:
            note = "5.1 既有缺口"
        elif not r["v54"]:
            note = "★ 迁移新增失败"
        else:
            note = "✔"
        print("   %-13s %8s %10s %s" % (r["entry"], "PASS" if r["v51"] else "FAIL",
                                        "PASS" if r["v54"] else "FAIL", note))

    print()
    print("② 结论数字（只统计 5.1 能过的入口，避免既有缺口污染迁移成本）")
    print("   5.1 通过 %d / %d；其中 5.4+垫片 通过 %d，失败 %d"
          % (len(base_ok), len(rows), len(migrated), len(new_fail)))
    if new_fail:
        print("   新增失败清单：")
        for r in new_fail:
            print("     · %s → %s" % (r["entry"], r["why54"][:200]))

    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump({"rows": rows, "base_ok": len(base_ok),
                       "migrated_ok": len(migrated)}, f, ensure_ascii=False, indent=1)
        print()
        print("   完整结果 → %s" % a.json)
    return 0 if not new_fail else 1


if __name__ == "__main__":
    sys.exit(main())
