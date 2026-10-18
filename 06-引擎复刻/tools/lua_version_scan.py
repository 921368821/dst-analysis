#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""lua_version_scan.py —— C7：**Lua 5.2+ 迁移可行性**的可执行结论

═══════════════════════════════════════════════════════════════════════════════
C7 原文（校验报告-P43）
═══════════════════════════════════════════════════════════════════════════════
    `weather` 组件在 Lua 5.1/LuaJIT 下编译不过（60 upvalue 硬上限）
    影响：天气仍是桩
    建议：换 5.2+ 运行时才解，改宿主解不了

「换 5.2+ 才解」是一句**结论**，但它自己没被验证过：换过去要付多少代价？
别的 4000 个脚本会不会一片红？—— 不量就不知道，而不知道就等于没结论。

═══════════════════════════════════════════════════════════════════════════════
这个工具量什么
═══════════════════════════════════════════════════════════════════════════════
① **编译面**：把 `dstsrc/scripts` 下全部原版 Lua 文件 + 本工程 `host/` + 根目录入口，
   在每个运行时下**逐个编译**（只编译不执行 —— 编译期问题必须与运行期问题分开，
   混在一起就分不清"语法不兼容"和"少了个全局函数"）。
   输出：每个版本的成功/失败数、按错误种类分组、失败样例。

② **API 面**：在每个运行时里探一下 5.1 专有 / 5.2+ 改名的那些东西还在不在
   （`loadstring` / `setfenv` / `unpack` / `bit32` / `math.pow` / `table.getn` / `module`），
   并统计源码里**实际引用**了多少处 —— 因为"某个 API 没了"和"这段代码用了它"是两件事。

③ **关键词面**：`goto` 在 5.2+ 是**保留字**。5.1 里可以写 `local goto = 1`，
   5.2+ 直接语法错误，而且报错信息通常只写 "unexpected symbol near 'goto'"
   —— 4000 个文件里翻起来非常费劲。所以单独量一遍。

用法：
    python tools/lua_version_scan.py              全部（约 1~2 分钟）
    python tools/lua_version_scan.py --json out.json
    python tools/lua_version_scan.py --only-dst   只扫原版脚本（跳过宿主/入口）
退出码：0 = 扫描完成（是否"全绿"不是它判的，结论由报告给）。
"""
import argparse
import json
import os
import sys
from collections import Counter, OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.dirname(HERE)                 # 06-引擎复刻
ROOT = os.path.dirname(ENGINE)                 # DST-Analysis
DST_SRC = os.path.join(ROOT, "dstsrc", "scripts")

VERSIONS = [("5.1", "lua51"), ("5.2", "lua52"), ("5.3", "lua53"),
            ("5.4", "lua54"), ("jit2.1", "luajit21")]

# 5.1 → 5.2+ 的已知断裂点（探针）
# ★ 每个探针都是**表达式**：lupa 的 `eval` 直接把源码当表达式编译，
#   写 `return x ~= nil` 会得到 `unexpected symbol near 'return'` ——
#   第一版就是这么写的，于是 12 个探针在 5 个版本上**全部报同一个错**，
#   表格看上去像"每条都不兼容"，其实是我自己的探针编译不过。
#   （又一次同源教训：判据的输入先要能跑。）
PROBES = OrderedDict([
    ("loadstring", "loadstring ~= nil"),
    ("setfenv", "setfenv ~= nil"),
    ("getfenv", "getfenv ~= nil"),
    ("unpack", "unpack ~= nil"),
    ("table.unpack", "table.unpack ~= nil"),
    ("bit32", "bit32 ~= nil"),
    ("math.pow", "math.pow ~= nil"),
    ("table.getn", "table.getn ~= nil"),
    ("module", "module ~= nil"),
    # goto 是不是保留字：能当变量名 ⇒ 还是 5.1 语义（5.2+ 会语法错误）
    ("goto_is_keyword",
     "(function() local f = loadstring or load; return f('local goto = 1') == nil end)()"),
    # 整数除法运算符（5.3+）；5.1/5.2 下是语法错误
    ("intdiv_op",
     "(function() local f = loadstring or load; return f('return 1//1') ~= nil end)()"),
    # 位运算符（5.3+ 才有 & | ~ << >>）
    ("bitwise_ops",
     "(function() local f = loadstring or load; return f('return 1 & 1') ~= nil end)()"),
])

# 源码里值得计数的记号（用词边界匹配，避免 count 到注释里的噪音也说不清）
TOKENS = ["loadstring", "setfenv", "getfenv", "unpack(", "bit32", "math.pow",
          "table.getn", "goto", "::"]


def collect_files(only_dst=False):
    """返回 [(kind, path)] —— kind 用于分组统计。"""
    out = []
    for base, kind in ((DST_SRC, "dstsrc"), (os.path.join(ENGINE, "host"), "host")):
        if only_dst and kind != "dstsrc":
            continue
        for dirpath, _dirs, names in os.walk(base):
            for n in names:
                if n.endswith(".lua"):
                    out.append((kind, os.path.join(dirpath, n)))
    if not only_dst:
        for n in sorted(os.listdir(ENGINE)):
            if n.endswith(".lua"):
                out.append(("entry", os.path.join(ENGINE, n)))
    return out


def safe_err(v):
    """把 Lua 的错误值安全地转成 str（可能带非 UTF-8 字节）。"""
    try:
        if isinstance(v, bytes):
            return v.decode("utf-8", "replace")
        return str(v)
    except Exception:                                            # noqa: BLE001
        return "<无法解码的错误值>"


def classify(msg):
    m = msg.lower()
    if "upvalue" in m or "too many" in m:
        return "upvalue 超限"
    if "goto" in m or "label" in m:
        return "goto/标签（5.2+ 保留字）"
    if "unexpected symbol" in m:
        return "意外符号（语法）"
    if "expected" in m:
        return "语法期望不符"
    if "malformed" in m or "unfinished" in m:
        return "字面量未闭合"
    if "<eof>" in m:
        return "文件意外结束"
    return "其它"


def scan_version(version, module, files, sample=3):
    import lupa
    try:
        rtmod = __import__("lupa." + module, fromlist=["LuaRuntime"])
    except ImportError:
        return {"version": version, "skip": "lupa 未提供 %s" % module}
    L = rtmod.LuaRuntime(unpack_returned_tuples=True)

    probes = {}
    for name, code in PROBES.items():
        try:
            probes[name] = L.eval(code)
        except Exception as e:                                   # noqa: BLE001
            probes[name] = "ERR:" + safe_err(e)

    res = {"version": version, "module": module, "version_str": safe_err(L.eval("_VERSION")),
           "probes": probes, "by_kind": OrderedDict(), "fails": [], "total": 0, "ok": 0}

    for kind, path in files:
        res["total"] += 1
        stat = res["by_kind"].setdefault(kind, {"total": 0, "ok": 0, "fail": 0, "kinds": Counter()})
        stat["total"] += 1
        # ★ 按**字节**读，再交给 Lua 编译：原版脚本里有非 UTF-8 内容，
        #   先 decode 再 compile 会引入"我以为是语法错误、其实是编码"的假线索。
        with open(path, "rb") as f:
            src = f.read()
        try:
            L.compile(src)
            stat["ok"] += 1
            res["ok"] += 1
        except Exception as e:                                   # noqa: BLE001
            stat["fail"] += 1
            msg = safe_err(e)
            k = classify(msg)
            stat["kinds"][k] += 1
            if len(res["fails"]) < 200:
                res["fails"].append({"kind": kind, "cls": k,
                                     "path": os.path.relpath(path, ROOT).replace("\\", "/"),
                                     "msg": msg.replace("\n", " ")[:200]})
    return res


def token_counts(files):
    """统计源码里实际出现了多少次 5.1 专有/敏感记号（用简单词边界，只做量级参考）。"""
    import re
    pats = {t: re.compile(re.escape(t)) for t in TOKENS}
    out = Counter()
    files_with = Counter()
    for _kind, path in files:
        try:
            with open(path, "rb") as f:
                txt = f.read().decode("utf-8", "replace")
        except Exception:                                        # noqa: BLE001
            continue
        hit = False
        for t, pat in pats.items():
            n = len(pat.findall(txt))
            if n:
                out[t] += n
                hit = True
        if hit:
            files_with[t] += 0   # 占位，避免 Counter 空
    return dict(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default=None, help="把完整结果写成 JSON")
    ap.add_argument("--only-dst", action="store_true", help="只扫 dstsrc（跳过 host/入口）")
    ap.add_argument("--samples", type=int, default=3)
    a = ap.parse_args()

    if not os.path.isdir(DST_SRC):
        print("✘ 找不到原版脚本目录：%s" % DST_SRC)
        return 2
    files = collect_files(a.only_dst)
    print("═" * 78)
    print("  C7：Lua 版本迁移扫描 —— %d 个文件 × %d 个运行时" % (len(files), len(VERSIONS)))
    print("  （dstsrc = 原版脚本；host/entry = 本工程宿主与入口）")
    print("═" * 78)

    results = []
    for v, mod in VERSIONS:
        sys.stdout.write("  扫描 %s ... " % v)
        sys.stdout.flush()
        r = scan_version(v, mod, files, a.samples)
        results.append(r)
        if r.get("skip"):
            print("跳过（%s）" % r["skip"])
        else:
            print("完成：编译失败 %d / %d" % (r["total"] - r["ok"], r["total"]))

    # ---------------- 汇总表
    print()
    print("① 编译面（每个运行时下，逐个文件只编译不执行）")
    print("   %-8s %-9s %8s %8s %8s %8s %8s" % ("运行时", "_VERSION", "总数", "通过", "失败", "dstsrc", "host+入口"))
    for r in results:
        if r.get("skip"):
            print("   %-8s %s" % (r["version"], r["skip"]))
            continue
        d = r["by_kind"].get("dstsrc", {"total": 0, "ok": 0, "fail": 0})
        he = sum(x["fail"] for k, x in r["by_kind"].items() if k != "dstsrc")
        print("   %-8s %-9s %8d %8d %8d %8d %8d"
              % (r["version"], r["version_str"], r["total"], r["ok"],
                 r["total"] - r["ok"], d["fail"], he))

    # ---------------- 失败按种类
    for r in results:
        if r.get("skip") or not r["fails"]:
            continue
        agg = Counter()
        for k, x in r["by_kind"].items():
            for cls, n in x["kinds"].items():
                agg[cls] += n
        print()
        print("   失败种类 @ %s：%s" % (r["version"], dict(agg)))
        for f in r["fails"][:a.samples]:
            print("     · [%s] %s\n       %s" % (f["cls"], f["path"], f["msg"]))

    # ---------------- API 面
    print()
    print("② API 面（探针：True 表示**存在**）")
    names = list(PROBES.keys())
    print("   %-16s" % "探针" + "".join("%10s" % r["version"] for r in results))
    for n in names:
        row = ""
        for r in results:
            v = r.get("probes", {}).get(n, "—")
            row += "%10s" % (v if not isinstance(v, bool) else ("在" if v else "无"))
        print("   %-16s%s" % (n, row))
    tc = token_counts(files)
    print()
    print("③ 源码引用量（出现次数，含注释 —— 只做量级参考）")
    for t in TOKENS:
        print("   %-14s %d" % (t, tc.get(t, 0)))

    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump({"files": len(files), "results": results, "tokens": tc},
                      f, ensure_ascii=False, indent=1)
        print()
        print("   完整结果 → %s" % a.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
