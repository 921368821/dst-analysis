#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_report_ledger.py —— 终期报告里「从账本抄来的数」必须与账本一致。

为什么有这个工具（2026-10-21 17:01 实测）：

  `终期三层校验-B7-2026-10-21.md` 16:59 定稿，17:01 就抓出两处过期：

      §五  账本 **14 轮**（1 表头 + 13 历史 + 本轮）  ← 实际 15 轮
      §六  阈值 1140 s，来源：上一轮最长一组 561 s × 2 ← 实际 1020 s / 499 s

  差的那一行是 16:35:25 那一轮：写报告时它**还在跑**，16:52 才落账。
  而 `561` 这个数在账本里**根本不存在** —— 是更早一轮的 groupmax，手抄后一直没动。

  所以问题不是「谁抄错了」，是**把易变的数写成点值**这个动作本身会过期。
  本工具让它没法手写：数只从 `_run_all.rounds.tsv` 来。

判据（三条，任一条不成立就 rc=1）：
  ① 报告里的「账本 N 轮（1 表头 + M 历史 + 本轮）」与账本行数一致；
  ② 报告里的「阈值 X s，来源：上一轮最长一组 Y s × 2」与账本末行/倒二行一致；
  ③ 账本**自己**不自相矛盾：末行阈值必须等于由倒二行推出来的值。
     ③ 不成立时**拒绝改报告** —— 报告是下游，把一处错复制成两处只会更可信地错。

用法：
    python tools/check_report_ledger.py            # 只比对（rc=1 表示过期）
    python tools/check_report_ledger.py --apply    # 顺手改正（原子替换）
    python tools/check_report_ledger.py --selftest # 合成用例
"""
import argparse
import glob
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = os.path.join(ROOT, "07-通用引擎", "tests", "_run_all.rounds.tsv")
REPORT_GLOB = os.path.join(ROOT, "终期三层校验-*.md")
FLOOR = 600                     # 与 tests/run_all.sh 的 BEAT_STALE_MAX 初值一致


def read_rows(text):
    lines = [l for l in text.splitlines() if l.strip()]
    if not lines:
        return None, "空表"
    head = lines[0].split("\t")
    for col in ("开始时间", "总耗时_s", "最长_s", "阈值_s"):
        if col not in head:
            return None, "表头缺列 %s：%s" % (col, head)
    return [dict(zip(head, l.split("\t"))) for l in lines[1:]], ""


def expect_threshold(prev_max):
    """和 tests/run_all.sh 一字不差：2 倍余量 → 向上取整到分钟 → 不低于 600。"""
    need = (int(prev_max) * 2 + 59) // 60 * 60
    return max(need, FLOOR)


def claims(text):
    """从报告里摘出三个声明。返回 (rounds, thresh, doc_rows)；各自可能是 None。

    为什么要求「恰好一处」：写成「找到就替换」，报告里若有两处在说同一件事，
    会安静地只改一处、留下另一处，看起来还挺一致。
    实测它救过一次 —— 补 §14.1 时那行也以 `| 账本 |` 开头，命中 2 次当场被抓。
    """
    import re
    out = []
    for rx in (re.compile(r"\|\s*账本\s*\|\s*\*\*(\d+) 轮\*\*（1 表头 \+ (\d+) 历史 \+ 本轮）"),
               re.compile(r"阈值 (\d+) s，来源：上一轮最长一组 (\d+) s × 2"),
               # ★ 第三种说法：同一件事在「一页结论」里被写成「账页 N 行与表逐行对应」。
               #   实测：前两条守住之后，这一处仍写着 14（实际 15）—— 一句话在一个文档里
               #   有三种说法，只认其中两种，第三种就会一直烂着。
               re.compile(r"账页 (\d+) 行")):
        hits = rx.findall(text)
        if len(hits) > 1:
            raise ValueError("模式命中 %d 次（要求至多 1 次）：%s" % (len(hits), rx.pattern))
        if not hits:
            out.append(None)
            continue
        # ★ 只有一个捕获组时 findall 返回的是**字符串**（`"14"`），两个组时返回元组。
        #   原写法 `tuple(int(x) for x in hits[0])` 会把 `"14"` 拆成 `(1, 4)` ——
        #   实测就踩了：报告写「账页 14 行」，判据读到 (1, 4)，打印成「账页 1 行」。
        #   当时它仍判红（(1,4) != 15），属于**碰巧**对；若账本正好是 14 行，
        #   它会拿 (1,4) 跟 14 比 ⇒ 假红。所以这里必须按「有没有第二个组」分开处理。
        h = hits[0]
        out.append(tuple(int(x) for x in h) if isinstance(h, tuple) else (int(h),))
    return out[0], out[1], out[2]


def check(table_text, report_text):
    """纯函数：返回 (bad, warn)。便于自检。"""
    bad, warn = [], []
    rows, why = read_rows(table_text)
    if rows is None:
        return ["账本无法解析（%s）—— 本检查**没有执行**，不是通过" % why], warn
    if len(rows) < 2:
        return ["账本不足两行 —— 本检查**没有执行**，不是通过"], warn
    n = len(rows)
    last, prev = rows[-1], rows[-2]
    thr = int((last.get("阈值_s") or "0").strip() or 0)
    prev_max = int((prev.get("最长_s") or "0").strip() or 0)
    want = expect_threshold(prev_max)

    # ③ 先校验上游：账本自己是不是自洽
    if thr != want:
        bad.append("账本自身不自洽：末行阈值 %d s，而按「上一轮最长 %d s ×2 向上取整到分钟、"
                   "不低于 %d」应为 %d s —— 先查账本，别改报告" % (thr, prev_max, FLOOR, want))
        return bad, warn

    try:
        c_rounds, c_thresh, c_doc = claims(report_text)
    except ValueError as e:
        return [str(e)], warn

    if c_rounds is None:
        warn.append("报告里没有「账本 N 轮 (1 表头 + M 历史 + 本轮)」这个声明 —— 跳过那一项")
    elif c_rounds != (n, n - 1):
        bad.append("报告写「账本 %d 轮（1 表头 + %d 历史 + 本轮）」，账本是 %d 轮（1 表头 + %d 历史 + 本轮）"
                   % (c_rounds[0], c_rounds[1], n, n - 1))
    if c_thresh is None:
        warn.append("报告里没有「阈值 X s，来源：上一轮最长一组 Y s × 2」这个声明 —— 跳过那一项")
    elif c_thresh != (thr, prev_max):
        bad.append("报告写「阈值 %d s / 上一轮最长 %d s」，账本是「阈值 %d s / 上一轮最长 %d s」"
                   % (c_thresh[0], c_thresh[1], thr, prev_max))
    if c_doc is None:
        warn.append("报告里没有「账页 N 行」这个声明 —— 跳过那一项")
    elif c_doc[0] != n:
        bad.append("报告写「账页 %d 行与表逐行对应」，账本是 %d 轮 —— 这一处是同一件事的第三种说法"
                   % (c_doc[0], n))
    return bad, warn


def rewrite(report_text, n, thr, prev_max):
    """把两处点值改对。只在 check() 全绿（上游自洽）且确有声明时调用。"""
    import re
    t = re.sub(r"(\|\s*账本\s*\|\s*\*\*)\d+( 轮\*\*（1 表头 \+ )\d+( 历史 \+ 本轮）)",
               lambda m: "%s%d%s%d%s" % (m.group(1), n, m.group(2), n - 1, m.group(3)),
               report_text, count=1)
    t = re.sub(r"(阈值 )\d+( s，来源：上一轮最长一组 )\d+( s × 2)",
               lambda m: "%s%d%s%d%s" % (m.group(1), thr, m.group(2), prev_max, m.group(3)),
               t, count=1)
    t = re.sub(r"(账页 )\d+( 行)", lambda m: "%s%d%s" % (m.group(1), n, m.group(2)), t, count=1)
    return t


# ── 自检 ─────────────────────────────────────────────────────────────────
def _tbl(thr, prev_max, n=3):
    head = ("开始时间\t判定\t组数\t总耗时_s\t最长一组\t最长_s\t阈值_s\tHEAD\t参数")
    body = []
    for i in range(n - 1):
        body.append("2026-10-21 1%d:00:00\t✔ 全部通过\t20/20\t900\tg\t%d\t1080\th%d\tfull"
                    % (i, prev_max, i))
    body.append("2026-10-21 16:35:25\t✔ 全部通过\t20/20\t1243\tg\t564\t%d\thx\tfull" % thr)
    return "\n".join([head] + body) + "\n"


def _rpt(n, hist, thr, pmax, doc=None):
    """doc = 「一页结论」里那句「账页 N 行」的数字，默认与轮数一致。"""
    doc = n if doc is None else doc
    return ("| 账本 | **%d 轮**（1 表头 + %d 历史 + 本轮） | `x.tsv` |\n"
            "| 锁 | 正常释放 | 阈值 %d s，来源：上一轮最长一组 %d s × 2 |\n"
            "| **文档** | 计划数字与实测一致；账页 %d 行与表逐行对应 | ✔ |\n"
            % (n, hist, thr, pmax, doc))


WANT_CASES = 9                   # 自检用例条数。加/删用例**必须同步改这里**


def selftest():
    ok = bad = 0
    cases = [
        # 名字, 账本, 报告, 期望 bad 条数
        ("一致",            _tbl(1020, 499),           _rpt(3, 2, 1020, 499),   0),
        # 账本多一行 ⇒ 「N 轮」与「账页 N 行」**两处都过期**（同一件事的两种说法）
        ("账本多一行",       _tbl(1020, 499, n=4),      _rpt(3, 2, 1020, 499),   2),
        ("阈值来源过期",     _tbl(1020, 499),           _rpt(3, 2, 1140, 561),   1),
        ("三处都过期",       _tbl(1020, 499, n=4),      _rpt(3, 2, 1140, 561),   3),
        ("账本自身不自洽",   _tbl(1140, 499),           _rpt(3, 2, 1020, 499),   1),
        ("报告里没有声明",   _tbl(1020, 499),           "什么都没有\n",           0),   # 只 warn
        ("同一件事写两处",   _tbl(1020, 499),           _rpt(3, 2, 1020, 499) * 2, 1),  # 命中 2 次
        ("账页行数过期",     _tbl(1020, 499),           _rpt(3, 2, 1020, 499, doc=2), 1),
        # ★ 两位数不能被拆成 (1, 4)：账本 14 轮、报告也写 14 ⇒ 必须 0 条✘。
        #   这条是给「单捕获组 findall 返回字符串」那个 bug 立的回归用例 ——
        #   修之前它会读到 (1, 4) 与 14 比，判成假红。
        ("账页两位数不错位", _tbl(1020, 499, n=14),      _rpt(14, 13, 1020, 499), 0),
    ]
    for name, t, r, want in cases:
        got, warn = check(t, r)
        mark = "✔" if len(got) == want else "✘"
        if len(got) == want:
            ok += 1
        else:
            bad += 1
        print("%s %-18s 期望 %d 条✘ 实际 %d 条%s"
              % (mark, name, want, len(got),
                 ("：" + got[0][:60]) if got else ("（⚠ %d 条）" % len(warn))))
    # ★ 自检自己也要守住「用例还在不在」：删掉一条用例、只要剩下几条全过，
    #   rc 仍是 0 —— 那这条自检就在**静默变松**，而它看起来一直在跑。
    #   收尾核验里那个「算了却没用」的 want 变量就是这个毛病（开发计划 §9cd）。
    if len(cases) != WANT_CASES:
        print("✘ 自检用例 %d 条，期望 %d 条 —— 加/删用例时必须同步 WANT_CASES，"
              "否则这条自检会静默变松" % (len(cases), WANT_CASES))
        bad += 1
    print("%s check_report_ledger 自检：%d/%d（用例 %d 条）"
          % ("✔" if bad == 0 else "✘", ok, len(cases) + bad, len(cases)))
    return 0 if bad == 0 else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--table", default=TABLE)
    ap.add_argument("--report", action="append", default=None)
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    table_text = io.open(a.table, encoding="utf-8", errors="replace").read()
    reports = a.report or sorted(glob.glob(REPORT_GLOB))
    if not reports:
        print("⚠ 没有找到终期报告（%s）—— 跳过，不算通过也不算失败" % REPORT_GLOB)
        return 0

    rows, why = read_rows(table_text)
    if rows is None:
        print("✘ 账本无法解析：%s" % why)
        return 1
    n = len(rows)
    thr = int((rows[-1].get("阈值_s") or "0").strip() or 0)
    prev_max = int((rows[-2].get("最长_s") or "0").strip() or 0)
    print("账本 %d 轮｜末行 %s｜阈值 %d s（上一轮最长 %d s）"
          % (n, (rows[-1].get("开始时间") or "").strip(), thr, prev_max))

    rcbad = 0
    fixed = 0
    for path in reports:
        text = io.open(path, encoding="utf-8", newline="").read()
        bad, warn = check(table_text, text)
        name = os.path.basename(path)
        for w in warn:
            print("  ⚠ %s：%s" % (name, w))
        if not bad:
            print("  ✔ %s：报告里的账本数字与账本一致" % name)
            continue
        for b in bad:
            print("  ✘ %s：%s" % (name, b))
        # 账本自身不自洽时**不改报告** —— 报告是下游，抄一遍错只会更可信地错
        if a.apply and all("账本自身不自洽" not in b for b in bad):
            new = rewrite(text, n, thr, prev_max)
            tmp = path + ".tmp"
            io.open(tmp, "w", encoding="utf-8", newline="\n").write(new)
            os.replace(tmp, path)            # 原子替换：④ 组可能正在读它
            print("  ✔ 已改：%s（%d 行）" % (name, new.count("\n")))
            fixed += 1
        else:
            rcbad += 1
    if rcbad:
        print("✘ %d 份报告的账本数字过期%s" % (rcbad, "" if a.apply else "（加 --apply 可自动改）"))
        return 1
    if fixed:
        print("✔ 已改正 %d 份报告" % fixed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
