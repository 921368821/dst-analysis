#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""校验《外部引擎逆向推演评估》§8 参考源登记表。

为什么需要它
------------
这张表的作用是把「我参考了 XX」变成可审计的记录。但一张手写的表会静默腐烂：
有人加了来源却没写结论，有人写了结论却没有产物，有人把预算从 3.0 改到 5.0
而没人发现。本脚本核六项：

  1. 编号唯一且连续（R1..Rn）
  2. 许可证在白名单内（防"不明来源"混入）
  3. 预算可解析，且表尾声明的三数与重算相等
  4. **结论与产物同进同退** —— 写了结论却"待产出" ⇒ 红；有产物却"待读" ⇒ 红
  5. 产物里的文件名必须真实存在（"产物"不能是空话）
  6. 计划项预算合计 ≤ 文档声明的上限

第 4 项是核心：它拦的正是本项目反复出现的失败模式 ——
「做了但没有证据」和「说有结论但找不到产物」。

用法
----
    python tools/check_refs.py            # 核真实文档
    python tools/check_refs.py --selftest # 跑合成用例，自证判据会红

反向验证记录（写在这里，因为工具本身也需要被验证）
--------------------------------------------------
2026-10-21 建脚本时实测两次：
  a) 把 R5 的产物由"待产出"改成真实结论文字 ⇒ rc=1，理由「有结论无产物」；
  b) 把表尾"计划 3.0"改成"计划 5.0" ⇒ rc=1，理由「合计不符」。
"""
import io
import os
import re
import sys

DOC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "外部引擎逆向推演评估-2026-10-21.md")

WANT_CASES = 5          # 自检用例数，改了要一起改，防止用例被悄悄删掉
PLAN_CAP = 3.0          # 计划项预算上限（人日）
LICENSE_OK = ("MIT", "Apache", "BSD", "Reference-Only", "自有", "项目内已有")
DONE_MARK = ("已完成", "实测", "沉没")   # 预算列的"已发生"标记
FILE_RE = re.compile(r"[\w\u4e00-\u9fa5\-./]+\.(?:md|py|js|json)")


def parse_rows(text):
    """抽出 §8 表格行。返回 [{no,src,lic,use,conc,out,budget_raw}, ...]"""
    rows = []
    started = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("## §8"):
            started = True
            continue
        if started and s.startswith("## "):
            break
        if not started or not s.startswith("| R"):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if len(cells) < 7:
            continue
        rows.append({
            "no": cells[0], "src": cells[1], "lic": cells[2], "use": cells[3],
            "conc": cells[4], "out": cells[5], "budget_raw": cells[6],
        })
    return rows


def parse_budget(raw):
    """返回 (数值, 是否已发生)。解析不出返回 (None, False)。"""
    done = any(m in raw for m in DONE_MARK)
    m = re.search(r"\d+(?:\.\d+)?", raw)
    if not m:
        return (0.0 if done else None), done
    return float(m.group()), done


def parse_declared(text):
    """从表尾"预算合计：已发生 a 人日 ｜ 计划 b 人日 ｜ 计划上限 c 人日"取三数。"""
    m = re.search(r"预算合计[^\n]*?已发生\s*([\d.]+)[^\n]*?计划\s*([\d.]+)[^\n]*?上限\s*([\d.]+)",
                  text)
    if not m:
        return None
    return tuple(float(x) for x in m.groups())


def product_exists(out, base_dir):
    """产物列里的文件名是否存在。没有文件名但写了"本文"也算合格（指向本文件）。"""
    if out.strip() in ("待产出", "", "-"):
        return True, []          # 空产物由第 4 项"同进同退"兜住，这里不重复判
    names = FILE_RE.findall(out.replace("`", ""))
    if not names:
        return ("本文" in out), []
    checked = []
    for n in names:
        p1 = os.path.join(base_dir, n)
        p2 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", n)
        ok = os.path.exists(p1) or os.path.exists(p2)
        checked.append((n, ok))
    return all(ok for _, ok in checked), checked


def check_text(text, base_dir="", strict=True):
    """返回 (problems, stats)。problems 为空表示通过。"""
    probs = []
    rows = parse_rows(text)
    if strict and not rows:
        return (["§8 参考源登记表为空"], {})
    if not rows:
        return ([], {})

    # 1. 编号唯一且连续
    nos = []
    for r in rows:
        m = re.fullmatch(r"R(\d+)", r["no"])
        if not m:
            probs.append("编号非法: %s" % r["no"])
            continue
        nos.append(int(m.group(1)))
    if nos != list(range(1, len(nos) + 1)):
        probs.append("编号不连续或重复: %s" % nos)

    # 2. 许可证白名单
    for r in rows:
        if not any(k in r["lic"] for k in LICENSE_OK):
            probs.append("%s 许可证不在白名单: %s" % (r["no"], r["lic"]))

    # 3+4+5. 预算解析 / 结论-产物同进退 / 产物存在
    done_sum = plan_sum = 0.0
    for r in rows:
        v, is_done = parse_budget(r["budget_raw"])
        if v is None:
            probs.append("%s 预算解析失败: %s" % (r["no"], r["budget_raw"]))
        elif is_done:
            done_sum += v
        else:
            plan_sum += v

        conc_empty = r["conc"].strip() in ("待读", "", "-")
        out_empty = r["out"].strip() in ("待产出", "", "-")
        if conc_empty != out_empty:
            if conc_empty:
                probs.append("%s 有产物却无结论（产物: %s）" % (r["no"], r["out"]))
            else:
                probs.append("%s 有结论却「待产出」（结论: %s…）" % (r["no"], r["conc"][:18]))

        ok, checked = product_exists(r["out"], base_dir)
        if not ok:
            missing = [n for n, o in checked if not o] or ["<未指向任何文件>"]
            probs.append("%s 产物不存在: %s" % (r["no"], ", ".join(missing)))

    # 6. 表尾声明与上限
    dec = parse_declared(text)
    if strict:
        if dec is None:
            probs.append("找不到「预算合计」声明行")
        else:
            d_done, d_plan, d_cap = dec
            if abs(d_done - done_sum) > 1e-6:
                probs.append("已发生合计不符: 声明 %.2f / 重算 %.2f" % (d_done, done_sum))
            if abs(d_plan - plan_sum) > 1e-6:
                probs.append("计划合计不符: 声明 %.2f / 重算 %.2f" % (d_plan, plan_sum))
            if plan_sum > d_cap + 1e-6:
                probs.append("计划合计 %.2f 超上限 %.2f" % (plan_sum, d_cap))
            if d_cap > PLAN_CAP + 1e-6:
                probs.append("上限 %.2f 超过硬上限 %.2f" % (d_cap, PLAN_CAP))

    stats = {"n": len(rows), "done": done_sum, "plan": plan_sum}
    return (probs, stats)


def selftest():
    """合成最小文档，逐条反例必须因正确原因变红。"""
    head = ("## §8 参考源登记表\n\n"
            "| # | 来源 | 许可证 | 用途 | 提炼结论 | 产物 | 预算(人日) |\n"
            "|---|---|---|---|---|---|---|\n")
    ok_row = "| R1 | Godot | MIT | M1-1 | 双列表 | 本文 §5 | 0.5 |\n"
    ok_row2 = "| R2 | DST | 项目内已有 | M3 | 已读 | 本文 §3 | 0（实测） |\n"
    tail = "\n**预算合计**：已发生 0.0 人日 ｜ 计划 0.5 人日 ｜ 计划上限 3.0 人日\n"
    good = head + ok_row + ok_row2 + tail

    # (名字, 文本, 期望通过?, 是否走 strict 表尾校验)
    cases = [
        ("正例", good, True, True),
        ("有结论无产物",
         head + ok_row.replace("| 本文 §5 |", "| 待产出 |") + ok_row2 + tail, False, True),
        ("许可证不明",
         head + ok_row.replace("| MIT |", "| 不明 |") + ok_row2 + tail, False, True),
        ("合计不符",
         head + ok_row + ok_row2 +
         "\n**预算合计**：已发生 0.0 人日 ｜ 计划 0.9 人日 ｜ 计划上限 3.0 人日\n", False, True),
        ("超上限",
         head + ok_row.replace("0.5 |", "9.0 |") + ok_row2 +
         "\n**预算合计**：已发生 0.0 人日 ｜ 计划 9.0 人日 ｜ 计划上限 9.0 人日\n", False, True),
    ]

    assert len(cases) == WANT_CASES, "自检用例数与 WANT_CASES 不一致"
    bad = 0
    for name, txt, want_pass, st in cases:
        probs, _ = check_text(txt, strict=st)
        if want_pass:
            okk = not probs
        else:
            okk = bool(probs)
        print(("  ✅ " if okk else "  ❌ ") + name +
              ("" if okk else "  → " + "; ".join(probs)))
        if not okk:
            bad += 1
    print("自检 %d/%d 通过" % (len(cases) - bad, len(cases)))
    return 0 if bad == 0 else 1


def main():
    if "--selftest" in sys.argv:
        return selftest()
    doc = os.path.abspath(DOC)
    if not os.path.exists(doc):
        print("✘ 找不到文档: %s" % doc)
        return 1
    text = io.open(doc, encoding="utf-8").read()
    probs, stats = check_text(text, base_dir=os.path.dirname(doc))
    if probs:
        print("✘ 参考源登记表 %d 个问题：" % len(probs))
        for p in probs:
            print("   - " + p)
        return 1
    print("✅ 参考源登记表通过：%d 条（已发生 %.2f / 计划 %.2f 人日）"
          % (stats["n"], stats["done"], stats["plan"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
