#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_doc_rounds.py —— 轮次账本与文档的留痕对账（P50㊵）

为什么需要它：
  今晚我在文档里写的每一个耗时/时刻，都是**手抄**的。手抄犯过两次：
  ① ㉞ 之前把「墙钟约 21 s」写成点值（实测 31.8 s）；
  ② 14:30 往账本里填「14:30 / 14:32 落地」，实测 mtime 是 14:26:14 / 14:26:59。
  两者都是同一个动作：**凭印象填一个数，然后它变成别人引用的依据**。

判据（默认模式，在 run_all 的 ④ 组跑）：
  ✘ 表里一轮都没有            ⇒ exit 2（无法判定 ≠ 通过）
  ✘ 表**最后一行**在文档里**追溯不到** —— 两种引用方式任一即可（都是我真会写的）：
      ① 写开始时刻，如「（12:56:00 起跑）」；
      ② 写总耗时，如「全量 ✔ 20/20 / 1227 s」。
    ④ 组跑在写表之前，所以「最后一行」= **上一轮**。这条等于要求：
    每一轮的结论必须在下一轮开跑之前已留痕。
  ⚠ 追溯到了，但同一行里没有那一轮的「组数」（如 `20/20`）
      —— 时刻/耗时对得上、标签对不上，正是 §9bi「标签写 A、代码取 B」的形状。
  ✘ 账页声明的行数 ≠ 表里的轮数（`**N 行全部照抄**` 里的 N）
      —— 2026-10-21 这个数漂了三次（11→12→13），每次都靠人肉同步；
         找不到这条声明同样判 ✘（**无法判定 ≠ 通过**，且防止「声明被删掉就永远绿」）。
  ✘ 账页**表格本身**的数据行数 ≠ 表里的轮数
      —— 声明只是一个数。只把声明改成 13、表格仍抄 12 行，上面那条是绿的：
         「人照着账页核」核的正是那张表，不是那个数。所以表自己也要数。
         声明下面找不到表 ⇒ 同样判 ✘（无法判定 ≠ 通过）。

为什么**不**接受「开始 + ELAPSED = 结束」：
  实测两者不等 —— ELAPSED 是判据累计（1227 s），墙钟到结束是 1228+ s，
  差的几秒是退出清理与 printf。按等式算出来的结束时刻会**系统性偏早**，
  于是「文档写的是结束时刻」这种情况会被判成没留痕（假红）。
  假红几次之后这条判据就会被忽略 —— 宁可少守一种写法，也不要制造误报。

为什么不做「文档里的数字必须全在表里」：
  文档里还有单组耗时（`②f 557 s`）、阈值、行数……全量匹配会误报。
  **只锁「这一轮的存在性」**，是这条判据唯一能守得住的东西（§9bj.4）。

用法：
  check_doc_rounds.py            检查；有 ✘ 退出码 1
  check_doc_rounds.py --selftest 合成用例
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = os.path.join(ROOT, "07-通用引擎", "tests", "_run_all.rounds.tsv")
DOCS = [os.path.join(ROOT, "阶段进度与后续待办-2026-10-19.md")]
COLS = ["开始时间", "判定", "组数", "总耗时_s", "最长一组", "最长_s", "阈值_s", "HEAD"]


def parse(text):
    """返回行列表（dict）。表头不认识就返回 (None, 原因)。"""
    lines = [l for l in text.splitlines() if l.strip()]
    if not lines:
        return None, "空表"
    head = lines[0].split("\t")
    if head[:len(COLS)] != COLS[:len(head)]:
        return None, "表头不认识：%s" % (head,)
    rows = []
    for l in lines[1:]:
        cells = l.split("\t")
        rows.append(dict(zip(head, cells)))
    return rows, ""


def hms(ts):
    """从 `2026-10-21 13:16:35` 取 `13:16:35`；取不到返回 None。"""
    m = re.search(r"(\d{2}):(\d{2}):(\d{2})", ts or "")
    return m.group(0) if m else None


DECL = re.compile(r"\*\*(\d+)\s*行全部照抄")
SEP = re.compile(r"^\s*\|[\s:|-]+\|\s*$")


def ledger_data_rows(doc_text):
    """账页表格的数据行数；找不到「声明句 + 紧跟的表」返回 None。

    为什么从**声明句**往下找、而不是按小节号（`### 6.36`）找：
      小节号会变（6.36 → 6.37 → …），今天已经改过一次编号；
      而声明句与表是同一段话里的东西，粘在一起，只要声明在，表就在它下面。
    越过小节标题（`### `）还没见到表 ⇒ 认为没有表，**不跨节去抓下一张**：
      文档里另有旧账页（§6.31 那两张），跨节抓会把「别人的表」数进来。
    """
    lines = doc_text.splitlines()
    start = None
    for i, l in enumerate(lines):
        if DECL.search(l):
            start = i
            break
    if start is None:
        return None
    i = start
    while i < len(lines) and not lines[i].lstrip().startswith("|"):
        if lines[i].startswith("### "):
            return None
        i += 1
    if i >= len(lines):
        return None
    i += 1                                  # 表头
    if i < len(lines) and SEP.match(lines[i]):
        i += 1                              # 分隔行 |---|---|
    n = 0
    while i < len(lines) and lines[i].lstrip().startswith("|"):
        n += 1
        i += 1
    return n


def check(table_text, doc_text):
    """纯函数：返回 (bad, warn)。便于自检。"""
    bad, warn = [], []
    rows, why = parse(table_text)
    if rows is None:
        bad.append("轮次表无法解析（%s）—— 本检查**没有执行**，不是通过" % why)
        return bad, warn
    if not rows:
        bad.append("轮次表里一轮都没有记录 —— 本检查**没有执行**，不是通过")
        return bad, warn
    last = rows[-1]
    t = hms(last.get("开始时间"))
    el = (last.get("总耗时_s") or "").strip()
    hits = []                                    # [(怎么追溯到的, 命中的行)]
    if t and t in doc_text:
        hits.append(("开始时刻 %s" % t,
                     [l for l in doc_text.splitlines() if t in l]))
    if el.isdigit():
        pat = re.compile(r"(?<!\d)%s\s*s" % re.escape(el))
        lines = [l for l in doc_text.splitlines() if pat.search(l)]
        if lines:
            hits.append(("总耗时 %s s" % el, lines))
    if not hits:
        bad.append("表最后一轮**在阶段进度文档里追溯不到**（既没有开始时刻 %s，"
                   "也没有「%s s」）—— 要么这轮没留痕，要么文档里的数是另写的"
                   % (t or "（表里读不到）", el or "（表里读不到）"))
        return bad, warn
    want = (last.get("组数") or "").strip()
    if want:
        matched = [l for _, lines in hits for l in lines]
        if matched and not any(want in l for l in matched):
            warn.append("%s 在文档里有，但那一行没写这一轮的组数 %s"
                        "（数字对得上、标签对不上）" % (hits[0][0], want))
    # ★ 账页的行数声明必须等于表里的轮数。
    #   2026-10-21 这个数漂了三次（11→12→13），每次都靠人肉同步 ——
    #   而「人肉同步」正是这条判据要替掉的东西。
    m = DECL.search(doc_text)
    if not m:
        bad.append("找不到账页的行数声明（`**N 行全部照抄**`）—— 无法判定，"
                   "不当作通过（也不许把声明删掉来绕过）")
    else:
        claimed = int(m.group(1))
        if claimed != len(rows):
            bad.append("账页声明 **%d 行**，而表里是 **%d 轮** —— 账页没跟上表"
                       % (claimed, len(rows)))
        # ★ 声明只是一个数。**表自己也要数**：只把声明改成 13、表格仍抄 12 行，
        #   上面那条是绿的 —— 而人照着账页核的正是那张表。
        #   找不到声明时上面已判 ✘，这里不再重复报（避免一条毛病两条红）。
        got = ledger_data_rows(doc_text)
        if got is None:
            bad.append("声明句下面找不到账页表格 —— 无法判定，不当作通过")
        elif got != len(rows):
            bad.append("账页**表格**实际 **%d 行**，而表里是 **%d 轮** —— 表被少抄/多抄了"
                       "（只改声明不改表，声明核对那条是过的）" % (got, len(rows)))
    return bad, warn


# ── 自检 ─────────────────────────────────────────────────────────────────
def _tab(rows):
    out = ["\t".join(COLS)]
    for r in rows:
        out.append("\t".join(r))
    return "\n".join(out) + "\n"


def _row(t, verdict="✔ 全部通过", groups="20/20", el="1227"):
    return [t, verdict, groups, el, "②f", "557", "1200", "a6e7aa2"]


def selftest():
    cases = []

    def add(name, ok, extra=""):
        cases.append((name, bool(ok), extra))

    def _tbl(n):
        out = ["| 起跑 | 判定 |", "|---|---|"]
        for k in range(n):
            out.append("| 2026-10-21 0%d:00:00 | ✔ |" % (k + 1))
        return "\n".join(out) + "\n"

    def run(name, table, doc, nb, nw, decl="auto", tbl="auto"):
        """decl / tbl: "auto" = 跟随表里的轮数；"none" = 不写；int = 写指定数。

        **两个参数分开**，因为「声明错、表对」与「声明对、表少抄」是两条不同的毛病：
        合成一个参数就只能测前一种，后一种（只改声明不改表）会一直是绿的。
        """
        n = max(0, len([l for l in table.splitlines() if l.strip()]) - 1)
        tn = n if tbl == "auto" else (None if tbl == "none" else tbl)
        if decl == "auto":
            doc = doc + ("**%d 行全部照抄**\n" % n)
        elif decl != "none":
            doc = doc + ("**%d 行全部照抄**\n" % decl)
        if tn is not None:
            doc = doc + _tbl(tn)          # 声明句在上、表在下（与真文档一致）
        bad, warn = check(table, doc)
        add(name, len(bad) == nb and len(warn) == nw,
            "期望 ✘%d⚠%d 实得 ✘%d⚠%d%s" % (nb, nw, len(bad), len(warn),
                                          ("｜" + bad[0][:40]) if bad else ""))

    T = _tab([_row("2026-10-21 12:56:00")])
    run("① 末行时刻与组数都在文档里 ⇒ 全绿", T,
        "### 6.30 全量 ✔ 20/20 / 1227 s（12:56:00）\n", 0, 0)
    run("② 时刻与耗时都追溯不到 ⇒ ✘1", T,
        "### 6.30 全量 ✔ 20/20 / 999 s（11:11:11）\n", 1, 0)
    run("②b 已知弱点：耗时对、时刻是编的 ⇒ 绿（两种引用任一即可的代价）", T,
        "### 6.30 全量 ✔ 20/20 / 1227 s（11:11:11）\n", 0, 0)
    run("③ 时刻有、组数写成 18/18 ⇒ ⚠1", T,
        "### 6.30 全量 ✔ 18/18 / 1227 s（12:56:00）\n", 0, 1)
    run("③b 只写耗时、不写时刻 ⇒ 绿（两种引用方式都认）", T,
        "### 6.30 全量 ✔ 20/20 / 1227 s\n", 0, 0)
    run("③c 耗时写成 12270 s 不算命中 1227 ⇒ ✘1", T,
        "### 6.30 ✔ 20/20 / 12270 s\n", 1, 0)

    # ④ 空表：不是通过
    run("④ 空表 ⇒ ✘1（无法判定 ≠ 通过）", "", "任意\n", 1, 0)
    # ⑤ 只有表头没有数据行
    run("⑤ 只有表头 ⇒ ✘1", "\t".join(COLS) + "\n", "任意\n", 1, 0)
    # ⑥ 表头不认识
    run("⑥ 表头不认识 ⇒ ✘1", "a\tb\n1\t2\n", "任意\n", 1, 0)

    # ⑦ 取**最后一行**，不是第一行
    T2 = _tab([_row("2026-10-21 09:00:00"), _row("2026-10-21 12:56:00")])
    run("⑦ 认最后一行（文档只有第一轮 ⇒ ✘1）", T2,
        "第一轮（09:00:00）\n", 1, 0)
    run("⑧ 认最后一行（文档两轮都有 ⇒ 绿）", T2,
        "第一轮（09:00:00）\n第二轮（12:56:00）20/20\n", 0, 0)

    # ⑨ fast 轮（18/18）同样要对上
    T3 = _tab([_row("2026-10-21 11:09:45", groups="18/18", el="1088")])
    run("⑨ fast 轮 18/18 对上 ⇒ 绿", T3, "fast ✔ 18/18 / 1088 s（11:09:45）\n", 0, 0)

    # ⑩ hms 解析
    add("⑩ hms 能从完整时刻里取时分秒", hms("2026-10-21 13:16:35") == "13:16:35")
    add("⑪ hms 取不到时返回 None（不是空串）", hms("没有时刻") is None)

    # ⑫ 两种引用方式都追溯不到 ⇒ 报错而不是静默通过
    T4 = _tab([_row("坏时刻")])
    run("⑫ 时刻坏掉且文档里也没有耗时 ⇒ ✘1", T4, "任意\n", 1, 0)

    # ㉑㉒㉓ 账页行数声明（2026-10-21 这个数漂了三次，全靠人肉同步）
    run("㉑ 声明 1 行、表 1 轮 ⇒ 绿", T, "### 6.30 全量 ✔ 20/20 / 1227 s（12:56:00）\n", 0, 0, decl=1)
    run("㉒ 声明 1 行、表 2 轮 ⇒ ✘1（账页没跟上表）", T2,
        "第一轮 09:00:00\n第二轮 12:56:00 20/20\n", 1, 0, decl=1)
    run("㉓ 找不到行数声明 ⇒ ✘1（无法判定 ≠ 通过）", T,
        "### 6.30 全量 ✔ 20/20 / 1227 s（12:56:00）\n", 1, 0, decl="none")

    # ㉔㉕㉖㉗ 账页**表格本身**的行数：声明只是一个数，人照着核的是那张表
    run("㉔ 声明 2 行、表 2 行、轮次表 2 轮 ⇒ 绿", T2,
        "第一轮 09:00:00\n第二轮 12:56:00 20/20\n", 0, 0)
    run("㉕ 声明 2 行对、但表只抄了 1 行 ⇒ ✘1（只改声明不改表）", T2,
        "第一轮 09:00:00\n第二轮 12:56:00 20/20\n", 1, 0, decl=2, tbl=1)
    run("㉖ 声明 1 行对、声明下面根本没有表 ⇒ ✘1（无法判定 ≠ 通过）", T,
        "### 6.30 全量 ✔ 20/20 / 1227 s（12:56:00）\n", 1, 0, decl=1, tbl="none")
    # ㉗ 是**集成**级：走 check() 全程，不只测 ledger_data_rows 这个 helper
    #    （今天的教训：测了 helper 没测接线，把接线拆掉仍全绿）
    doc_cross = ("### 6.30 全量 ✔ 20/20 / 1227 s（12:56:00）\n"
                 "**1 行全部照抄**\n\n### 6.37 别的事\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
    _b, _w = check(T, doc_cross)
    add("㉗ 声明后面先出现小节标题 ⇒ 不跨节去数别人的表（✘1）", len(_b) == 1,
        "实得 ✘%d：%s" % (len(_b), _b[0][:40] if _b else ""))

    good = [n for n, ok, _ in cases if ok]
    bad = [(n, e) for n, ok, e in cases if not ok]
    print("  check_doc_rounds 自检：%d/%d 通过" % (len(good), len(cases)))
    for n, e in bad:
        print("    ✘ %s%s" % (n, ("  ← " + e) if e else ""))
    return 0 if not bad else 1


def main():
    if not os.path.isfile(TABLE):
        print("  （没有 %s —— 本检查**没有执行**，不是通过）" % TABLE)
        return 2
    table_text = io.open(TABLE, encoding="utf-8", errors="replace").read()
    doc_text = ""
    used = []
    for d in DOCS:
        if os.path.isfile(d):
            doc_text += io.open(d, encoding="utf-8", errors="replace").read() + "\n"
            used.append(os.path.basename(d))
    if not used:
        print("  （阶段进度文档不存在 —— 本检查**没有执行**，不是通过）")
        return 2
    bad, warn = check(table_text, doc_text)
    print("  留痕对账：表末行 vs %s" % "、".join(used))
    for m in bad:
        print("  ✘ %s" % m)
    for m in warn:
        print("  ⚠ %s" % m)
    if bad:
        return 1
    if not warn:
        print("  ✔ 表里最后一轮的开始时刻与组数都能在文档里找到")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
