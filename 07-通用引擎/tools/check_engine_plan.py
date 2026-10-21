#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验《引擎开发计划-从零到2.5D》里的数字与依赖是否自洽。

为什么需要它：这份文档的核心主张是「102 个模块、57.2 人月、阶段与依赖都排得通」。
这些数字如果只靠人眼加，改一个模块的人月就会和阶段表分叉 —— 而分叉是静默的
（本项目的 `开发计划.md §9aq.1` 就是被同一类问题逼出来的「唯一活口」约定）。

它检查 8 件事（任一不满足则退出码 1）：
  1. 模块 ID 唯一，且每个域内从 1 开始连续无缺号
  2. 依赖列引用的 ID 全部存在
  3. 依赖图无环
  4. 依赖的阶段 ≤ 本模块阶段（防止「后面的模块被前面的依赖」这种倒挂）
  5. 模块表人月合计 == `<!-- PLAN-TOTAL: X -->` 声明值
  6. §5.8 阶段表的模块数 / 人月 / 累计 == 按模块表求和
  7. §7.1 域表人月 == 按模块表按域求和
  8. P0 模块的阶段必须 ≤ S4（P0 不许出现在「第三方可用」之后）

用法：
    python tools/check_engine_plan.py
    python tools/check_engine_plan.py --selftest   # 正例 + 3 个反例，证明它有牙
"""

import argparse
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DOC = os.path.join(os.path.dirname(HERE), "引擎开发计划-从零到2.5D-2026-10-21.md")

MOD_ROW = re.compile(r"^\|\s*([A-M])(\d+)\s*\|")          # | A1 | 数学与几何 | ...
STAGE_ROW = re.compile(r"^\|\s*(S[0-7])\s*\|")            # | S0 | 地基... | 10 | 3.4 | 3.4 | — |
DOMAIN_ROW = re.compile(                                   # | A 基础 | 2.4 | 2.4 | 0.0 | ...
    r"^\|\s*([A-M])\s+([^|]+?)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|"
)
TOTAL_MARK = re.compile(r"<!--\s*PLAN-TOTAL:\s*([\d.]+)\s*-->")
PHASES = ["S0", "S1", "S2", "S3", "S4", "S5", "S6", "S7"]


def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def parse_modules(text):
    """返回 [{id, domain, idx, name, prio, stage, deps, months}]。"""
    out = []
    for line in text.splitlines():
        if not MOD_ROW.match(line):
            continue
        c = cells(line)
        if len(c) < 8:
            continue
        try:
            months = float(c[5])
        except ValueError:
            continue  # 表头或非数据行
        depraw = c[4]
        deps = [] if depraw in ("—", "-", "", "无") else [
            d.strip() for d in re.split(r"[,，、]", depraw) if d.strip()
        ]
        out.append({
            "id": c[0],
            "name": c[1],
            "prio": c[2],
            "stage": c[3],
            "deps": deps,
            "months": months,
            "domain": c[0][0],
            "idx": int(c[0][1:]),
            "impl": c[7] if len(c) > 7 else "",
        })
    return out


def parse_stage_table(text):
    """§5.8 表：返回 {S0: {count, months, cum}}。"""
    out = {}
    for line in text.splitlines():
        if not STAGE_ROW.match(line):
            continue
        c = cells(line)
        if len(c) < 5:
            continue
        try:
            out[c[0]] = {
                "count": int(c[2].strip("*")),
                "months": float(c[3].strip("*")),
                "cum": float(c[4].strip("*")),
            }
        except ValueError:
            continue
    return out


def parse_domain_table(text):
    """§7.1 表：返回 {A: from_zero_months}。"""
    out = {}
    for line in text.splitlines():
        m = DOMAIN_ROW.match(line)
        if not m:
            continue
        dom, _name, zero = m.group(1), m.group(2), float(m.group(3))
        out[dom] = zero
    return out


def topo_ok(mods):
    """返回 (ok, 环上的 id 列表)。Kahn 算法。"""
    ids = {m["id"] for m in mods}
    indeg = {i: 0 for i in ids}
    adj = {i: [] for i in ids}
    for m in mods:
        for d in m["deps"]:
            if d in ids:
                adj[d].append(m["id"])
                indeg[m["id"]] += 1
    queue = [i for i in ids if indeg[i] == 0]
    seen = 0
    while queue:
        cur = queue.pop()
        seen += 1
        for nxt in adj[cur]:
            indeg[nxt] -= 1
            if indeg[nxt] == 0:
                queue.append(nxt)
    if seen == len(ids):
        return True, []
    return False, sorted(i for i in ids if indeg[i] > 0)


def check_text(text, strict=True):
    """返回 (problems, stats)。problems 为空表示通过。

    strict=False 供 --selftest 用：合成文档只有 2 个域，不必凑满 13 个。
    """
    p = []
    mods = parse_modules(text)
    by_id = {}
    for m in mods:
        if m["id"] in by_id:
            p.append("模块 ID 重复：%s" % m["id"])
        by_id[m["id"]] = m

    if not mods:
        return ["一个模块行都没解析到 —— 表格格式变了？"], {}

    # 1. 每域连续
    domains = {}
    for m in mods:
        domains.setdefault(m["domain"], []).append(m["idx"])
    for d, idxs in sorted(domains.items()):
        idxs.sort()
        want = list(range(1, len(idxs) + 1))
        if idxs != want:
            p.append("域 %s 的编号不连续：%s（期望 1..%d）" % (d, idxs, len(idxs)))

    # 2. 依赖存在 + 3. 无环 + 4. 阶段单调
    for m in mods:
        for dep in m["deps"]:
            if dep not in by_id:
                p.append("%s 依赖了不存在的模块 %s" % (m["id"], dep))
    ok, cyc = topo_ok(mods)
    if not ok:
        p.append("依赖成环，环上节点：%s" % ", ".join(cyc))
    for m in mods:
        for dep in m["deps"]:
            if dep in by_id:
                ds, ms = by_id[dep]["stage"], m["stage"]
                if ds in PHASES and ms in PHASES and PHASES.index(ds) > PHASES.index(ms):
                    p.append("%s(%s) 依赖 %s(%s) —— 阶段倒挂" % (m["id"], ms, dep, ds))

    # 5. PLAN-TOTAL
    total = sum(m["months"] for m in mods)
    m_total = TOTAL_MARK.search(text)
    if not m_total:
        p.append("文档里找不到 <!-- PLAN-TOTAL: x --> 声明")
    else:
        declared = float(m_total.group(1))
        if abs(declared - total) > 0.05:
            p.append("人月合计不符：模块表 %.1f vs 声明 %.1f" % (total, declared))

    # 6. 阶段表
    st = parse_stage_table(text)
    if strict and len(st) != 8:
        p.append("阶段表应解析到 8 行（S0~S7），实际 %d 行" % len(st))
    cum = 0.0
    for ph in PHASES:
        row = st.get(ph)
        want_cnt = sum(1 for m in mods if m["stage"] == ph)
        want_mon = round(sum(m["months"] for m in mods if m["stage"] == ph), 1)
        cum = round(cum + want_mon, 1)
        if not row:
            p.append("阶段表缺 %s 行" % ph)
            continue
        if row["count"] != want_cnt:
            p.append("%s 模块数不符：表 %d vs 模块表 %d" % (ph, row["count"], want_cnt))
        if abs(row["months"] - want_mon) > 0.05:
            p.append("%s 人月不符：表 %.1f vs 模块表 %.1f" % (ph, row["months"], want_mon))
        if abs(row["cum"] - cum) > 0.05:
            p.append("%s 累计不符：表 %.1f vs 重算 %.1f" % (ph, row["cum"], cum))

    # 7. 域表
    dt = parse_domain_table(text)
    if strict and len(dt) != 13:
        p.append("域表应解析到 13 行，实际 %d 行" % len(dt))
    for d in sorted(domains):
        want = round(sum(m["months"] for m in mods if m["domain"] == d), 1)
        if d not in dt:
            p.append("域表缺 %s" % d)
        elif abs(dt[d] - want) > 0.05:
            p.append("域 %s 人月不符：表 %.1f vs 模块表 %.1f" % (d, dt[d], want))

    # 8. P0 阶段
    for m in mods:
        if m["prio"] == "P0" and m["stage"] in PHASES and PHASES.index(m["stage"]) > 4:
            p.append("%s 是 P0 却排在 %s（P0 必须 ≤ S4）" % (m["id"], m["stage"]))

    # 附加：核心实现不能空（防止为了凑数加空行）
    for m in mods:
        if len(m["impl"]) < 6:
            p.append("%s 的「核心实现」过短或为空" % m["id"])

    stats = {
        "modules": len(mods),
        "total": round(total, 1),
        "domains": len(domains),
        "p0": sum(1 for m in mods if m["prio"] == "P0"),
        "p1": sum(1 for m in mods if m["prio"] == "P1"),
        "p2": sum(1 for m in mods if m["prio"] == "P2"),
        "p3": sum(1 for m in mods if m["prio"] == "P3"),
        "g1": round(sum(m["months"] for m in mods if PHASES.index(m["stage"]) <= 4), 1),
    }
    return p, stats


def selftest():
    """正例必须过，三个反例必须被抓住。用例条数写死（WANT_CASES），
    防止「用例被删掉一半、剩下全过」这种假绿（本项目已抓过多次）。"""
    WANT_CASES = 4
    head = "| ID | 模块 | 优先级 | 阶段 | 依赖 | 从零(人月) | 现状 | 核心实现（关键技术点） |\n|---|---|---|---|---|---|---|---|\n"
    rows = ("| A1 | 数学 | P0 | S0 | — | 1.0 | ● | 向量与矩形相交判定 |\n"
            "| A2 | 容器 | P0 | S0 | A1 | 2.0 | ● | 稀疏数组与对象池实现 |\n"
            "| B1 | 窗口 | P0 | S1 | A2 | 3.0 | ○ | 窗口生命周期与画布尺寸 |\n")
    stage = ("| 阶段 | 目标 | 模块数 | 从零人月 | 累计 | 交付线 |\n|---|---|---|---|---|---|\n"
             "| S0 | 地基 | 2 | 3.0 | 3.0 | — |\n"
             "| S1 | 骨架 | 1 | 3.0 | 6.0 | — |\n")
    dom = ("| 域 | 从零 | 已完成 | 剩余 |\n|---|---|---|---|\n"
           "| A 基础 | 3.0 | 3.0 | 0.0 |\n"
           "| B 平台 | 3.0 | 0.0 | 3.0 |\n")
    stages_all = "".join(
        "| %s | x | %d | %s | %s | — |\n" % (ph,
                                             {"S0": 2, "S1": 1}.get(ph, 0),
                                             {"S0": 3.0, "S1": 3.0}.get(ph, 0.0),
                                             {"S0": 3.0, "S1": 6.0}.get(ph, 6.0))
        for ph in PHASES)
    good = head + rows + "\n<!-- PLAN-TOTAL: 6.0 -->\n\n" + stage + "\n" + dom + "\n" + stages_all
    good = good.replace(stage, stages_all)

    cases = []
    cases.append(("正例：3 模块 6.0 人月，依赖 A1->A2->B1", good, True))
    cases.append(("反例：依赖了不存在的 A9",
                  good.replace("| B1 | 窗口 | P0 | S1 | A2 |", "| B1 | 窗口 | P0 | S1 | A9 |"),
                  False))
    cases.append(("反例：成环（A1 依赖 B1）",
                  good.replace("| A1 | 数学 | P0 | S0 | — |", "| A1 | 数学 | P0 | S0 | B1 |"),
                  False))
    cases.append(("反例：合计写成 9.0",
                  good.replace("PLAN-TOTAL: 6.0", "PLAN-TOTAL: 9.0"), False))

    assert len(cases) == WANT_CASES, "用例数 %d != WANT_CASES %d" % (len(cases), WANT_CASES)
    bad = 0
    for title, text, want_ok in cases:
        probs, _ = check_text(text, strict=False)
        ok = not probs
        mark = "✔" if ok == want_ok else "✘"
        if ok != want_ok:
            bad += 1
        print("  %s %s%s" % (mark, title, "" if ok == want_ok else "  —— 实际: " + "; ".join(probs[:2])))
    print("  %d/%d 用例行为符合预期" % (len(cases) - bad, len(cases)))
    return 0 if bad == 0 else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--file", default=DOC)
    a = ap.parse_args()

    if a.selftest:
        print("check_engine_plan --selftest")
        return selftest()

    if not os.path.exists(a.file):
        print("✘ 找不到文档：%s" % a.file)
        return 2
    text = io.open(a.file, encoding="utf-8").read()
    probs, st = check_text(text)
    print("check_engine_plan：%s" % os.path.basename(a.file))
    print("  模块 %d 个 / 域 %d 个 / 人月合计 %.1f" % (st["modules"], st["domains"], st["total"]))
    print("  优先级 P0=%d P1=%d P2=%d P3=%d；G1（≤S4）人月 %.1f"
          % (st["p0"], st["p1"], st["p2"], st["p3"], st["g1"]))
    if probs:
        for x in probs:
            print("  ✘ %s" % x)
        print("❌ %d 处不一致" % len(probs))
        return 1
    print("  ✔ 8 项检查全过（ID/依赖/无环/阶段单调/合计/阶段表/域表/P0 边界）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
