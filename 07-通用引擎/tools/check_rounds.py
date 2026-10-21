#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`tests/_run_all.rounds.tsv` 的不变量检查 —— 每轮一行的历史，自己也要有人守。

═══ 为什么需要它（2026-10-21） ═══

㉖ 那批起，每轮 `run_all.sh` 收尾会往 `tests/_run_all.rounds.tsv` 追加一行：

    开始时间 / 判定 / 组数 / 总耗时_s / 最长一组 / 最长_s / 阈值_s / HEAD

这份数据的用处只有一个：**锁的 beat 阈值由「上一轮最长一组 × 2」推出**（§9bc）。
也就是说这张表**直接决定下一轮的安全边界**：阈值低于「最长单组」时，
父 shell 一死，beat 会在那一组中途变陈旧 ⇒ 下一轮把「还在跑」判成「残留锁」，
清锁、清日志、和孤儿抢端口。

而它此前**没有任何守卫**：
- 谁都能手改 `_run_all.groupmax`（阈值来源），没人比对；
- 表里可以出现「最长 800 s 而阈值 600 s」这种自相矛盾的行，没人发现；
- 判定写 ✔ 但组数 19/20，也没人发现。

本工具就是这三条的守卫。**只读，不改任何文件。**

═══ 判据 ═══

| 级别 | 条件 | 为什么是错的 |
|---|---|---|
| ✘ | `最长_s > 阈值_s` | 阈值低于最长单组 ⇒ 「还在跑」会被误判成「残留锁」 |
| ✘ | `总耗时_s < 最长_s` | 一轮的总时长不可能短于其中一组 |
| ✘ | `组数` 不是 `N/M`，或 `N > M` | 账目坏了 |
| ✘ | 判定 ✔ 但 `N < M` | 「全部通过」却少跑了组 |
| ⚠ | `阈值_s != 2 × 上一条最长_s 向上取整` | 可能是 `--fast` / `RT_BEAT_STALE_MAX` 覆盖，需人确认 |
| ✘ | `_run_all.groupmax` 内容不是正整数秒数 | 阈值来源文件坏了 |
| ✘ | 表里**没有任何一轮**的最长一组等于 `groupmax` | 这个数不是从表里来的（手改，或上一轮写到一半被中断） |
| ⚠ | 对得上、但不是**最后一行** | 之后的轮次没写 `groupmax`（`--fast` 不写，属正常） |
| ✘ | 日志里 `⏱` 行数 ≠ `组数` 的执行数 | 两个落盘点对不上（有一组没打 ⏱ / 打了两次） |
| ✘ | 日志里最长的一组 ≠ `最长_s` | 同上，且**这个错会直接推出错的阈值** |
| ⚠ | 最长一组的**名字**与日志不一致 | 数字对得上、标签对不上（组改名了没同步） |
| ✘ | 日志里一行 `⏱` 都没有 | **无法对账 ≠ 通过**：日志被删/被截断时前三条会空转 |

> ★ 最后三条是**第二批**补的：第一版只查了 TSV 自己内部自洽，**根本没读 `groupmax`**，
> 而本文件开头把「谁都能手改 groupmax，没人比对」列为要解决的问题之一 ——
> 文档承诺了、代码没做，与「标签写 A、代码取 B」同形。

⚠ **只告警、不判红**，但它同样得有人守：2026-10-21 实测把这条整条改成 `if False:`，
原先那 8 条用例**照样全绿、rc=0** —— 只数「✘ 几条」的自测，永远看不见
「一条只产 ⚠ 的判据被打掉了」。所以 `--selftest` 现在**同时数 ✘ 与 ⚠**。

用法：
    python tools/check_rounds.py                 # 查默认路径
    python tools/check_rounds.py --file X.tsv
    python tools/check_rounds.py --selftest      # ★ 合成违规，证明它会响（✘ 与 ⚠ 都数）
"""
import argparse
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT = os.path.join(ROOT, "tests", "_run_all.rounds.tsv")
GROUPMAX = os.path.join(ROOT, "tests", "_run_all.groupmax")
COLS = ["开始时间", "判定", "组数", "总耗时_s", "最长一组", "最长_s", "阈值_s", "HEAD"]


def ceil60(n):
    """与 run_all.sh 里 `(x*2 + 59) / 60 * 60` 同一个取整方式。"""
    return (n * 2 + 59) // 60 * 60


def parse(text):
    """→ (rows, errors)。rows 里每项是 dict；errors 是「连解析都过不去」的行。"""
    rows, errors = [], []
    lines = [l for l in text.replace("\r\n", "\n").split("\n") if l.strip()]
    if not lines:
        return rows, ["文件是空的（连表头都没有）"]
    head = lines[0].split("\t")
    if head != COLS:
        errors.append("表头不对：期望 %d 列 %s，实际 %d 列 %s"
                      % (len(COLS), COLS, len(head), head))
    for i, line in enumerate(lines[1:], start=2):
        cells = line.split("\t")
        if len(cells) != len(COLS):
            errors.append("第 %d 行有 %d 列（期望 %d）：%s" % (i, len(cells), len(COLS), line[:60]))
            continue
        rows.append(dict(zip(COLS, cells), _line=i))
    return rows, errors


def check_rows(rows):
    """→ (bad, warn)。全是「判据」，没有 IO。"""
    bad, warn = [], []
    prev_longest = None
    for r in rows:
        ln = r["_line"]
        try:
            total = int(r["总耗时_s"])
            longest = int(r["最长_s"])
            limit = int(r["阈值_s"])
        except ValueError:
            bad.append("第 %d 行：总耗时/最长/阈值 里有非整数（%r / %r / %r）"
                       % (ln, r["总耗时_s"], r["最长_s"], r["阈值_s"]))
            continue

        if longest > limit:
            bad.append("第 %d 行：最长一组 %d s **超过**锁阈值 %d s —— 阈值低于最长单组，"
                       "父 shell 一死就会把「还在跑」判成「残留锁」" % (ln, longest, limit))
        if total < longest:
            bad.append("第 %d 行：总耗时 %d s 小于最长一组 %d s（不可能）" % (ln, total, longest))

        g = r["组数"]
        if "/" not in g:
            bad.append("第 %d 行：组数写的是 %r（期望 N/M）" % (ln, g))
        else:
            a, _, b = g.partition("/")
            if not (a.strip().isdigit() and b.strip().isdigit()):
                bad.append("第 %d 行：组数 %r 不是两个数字" % (ln, g))
            elif int(a) > int(b):
                bad.append("第 %d 行：组数 %s 里 执行数 > 声明数" % (ln, g))
            elif "✔" in r["判定"] and int(a) < int(b):
                bad.append("第 %d 行：判定「%s」却只跑了 %s —— 「全部通过」但少跑了组"
                           % (ln, r["判定"], g))

        if prev_longest is not None:
            want = ceil60(prev_longest)
            if limit != want:
                warn.append("第 %d 行：阈值 %d s ≠ 2×上一条最长 %d s 向上取整（%d s）"
                            "—— 可能是 `--fast` 或 `RT_BEAT_STALE_MAX` 覆盖，请人确认"
                            % (ln, limit, prev_longest, want))
        prev_longest = longest
    return bad, warn


# ── 日志 ↔ 表：两个独立落盘点必须对上 ──────────────────────────
LOG = os.path.join(ROOT, "tests", "_run_all.log")
# ★ 只认「行首 ⏱、中间 用时 N s 结尾」这一种形状（`_tally` 的落盘格式）。
#   `.+?` 非贪婪 + 固定分隔符：组名里带 `+` / `**` / `：` 都不影响。
_TIME_RE = re.compile(r"^⏱ (.+?) 用时 (\d+) s\s*$", re.M)


def check_log(log_text, n_exec=None, max_s=None, max_name=None):
    """日志里的组用时 ↔ 表里的「组数 / 最长_s / 最长一组」。

    参数显式传入而不是从表里读，是因为**两个调用点的期望值来源不同**：
    - 事后复查（本工具默认模式）：期望值取自表的最后一行；
    - 轮末对账（`run_all.sh` 收尾）：期望值取自**即将写入表的那几个变量**
      （那时本轮的行还没写，表的最后一行还是上一轮的）。
    """
    bad, warn = [], []
    times = [(m.group(1), int(m.group(2))) for m in _TIME_RE.finditer(log_text or "")]
    if not times:
        bad.append("日志里没有任何 `⏱ … 用时 N s` 行 —— 与「组数 / 最长_s」"
                   "**无法对账**（不是通过）")
        return bad, warn
    if n_exec is not None and len(times) != n_exec:
        bad.append("日志里有 %d 行组用时，而「组数」写的是 %s —— 两个落盘点对不上"
                   % (len(times), n_exec))
    name, secs = max(times, key=lambda x: x[1])
    if max_s is not None and secs != max_s:
        bad.append("日志里最长的一组是 %d s（%s），而「最长_s」写的是 %d s"
                   % (secs, name, max_s))
    elif max_s and max_name is not None and max_name != name:
        # ★ 只在最长 > 0 时比名字：`--dry-run` 里所有组都是 0 s，
        #   「谁最长」没有意义（`max()` 只会取第一个），比名字必报假告警。
        warn.append("最长一组的名字不一致：一处写 %r，日志写 %r" % (max_name, name))
    return bad, warn


def row_expect(last):
    """从表的一行取 (执行组数, 最长_s, 最长一组)；取不到的那项返回 None。"""
    g = (last or {}).get("组数", "")
    n = None
    if "/" in g:
        a = g.partition("/")[0].strip()
        if a.isdigit():
            n = int(a)
    return n, _int_or_none((last or {}).get("最长_s")), (last or {}).get("最长一组")


# ── 合成违规：证明上面那几条真的会响 ──────────────────────────────
def check_groupmax(rows, gm_text):
    """`tests/_run_all.groupmax` 与轮次表对不对得上 → (bad, warn)。

    ★★ 为什么必须单独查（2026-10-21，写这个文件时自己漏掉的）：
      本文件开头的说明把「谁都能手改 `_run_all.groupmax`（阈值来源），没人比对」
      列为**要解决的问题之一**，但第一版只查了 TSV 自己内部自洽 ——
      **根本没读 groupmax**。文档承诺了、代码没做，是同一种「标签写 A、代码取 B」。

    判据：
      ✘ 内容不是一个正整数秒数
      ✘ 表里**没有任何一轮**的最长一组等于它 ⇒ 这个数字不是从表里来的
        （手改；或者上一轮写完 groupmax、还没写轮次表就被中断）
      ⚠ 对得上、但对应的不是**最后一行** ⇒ 之后的轮次没写 groupmax
        （`--fast` 不写，属正常）
    """
    bad, warn = [], []
    s = (gm_text or "").strip()
    if not s.isdigit():
        bad.append("tests/%s 的内容是 %r（期望一个正整数秒数）"
                   % (os.path.basename(GROUPMAX), s[:20]))
        return bad, warn
    gm = int(s)
    hit = [r for r in rows if _int_or_none(r["最长_s"]) == gm]
    if not hit:
        bad.append("tests/%s 写着 %d s，但轮次表里**没有任何一轮**的最长一组是 %d s "
                   "—— 这个数不是从表里来的（手改？或上一轮写完 groupmax、"
                   "还没写轮次表就被中断）" % (os.path.basename(GROUPMAX), gm, gm))
        return bad, warn
    last_line = rows[-1]["_line"]
    if hit[-1]["_line"] != last_line:
        warn.append("tests/%s 的 %d s 对应第 %d 行，不是最后一行（第 %d 行）"
                    "—— 之后的轮次没写 groupmax（`--fast` 不写，属正常）"
                    % (os.path.basename(GROUPMAX), gm, hit[-1]["_line"], last_line))
    return bad, warn


def _int_or_none(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _row(start, verdict, groups, total, longest, limit, name="x"):
    return "\t".join([start, verdict, groups, str(total), name, str(longest), str(limit), "abc1234"])


SELFTEST = [
    # (说明, 行, 期望 ✘ 条数, 期望 ⚠ 条数)
    #
    # 为什么要把 ⚠ 也数进来：第 5 条判据（阈值来源）**只产 ⚠ 不产 ✘**。
    # 2026-10-21 实测把它整条改成 `if False:`，下面 8 条用例**照样全绿、rc=0** ——
    # 只数「✘ 几条」的自测，永远看不见「一条只产 ⚠ 的判据被打掉」。
    ("干净两行不得报",
     [COLS, _row("2026-10-21 09:00", "✔ 全部通过", "20/20", 1300, 580, 1200),
      _row("2026-10-21 10:00", "✔ 全部通过", "20/20", 1320, 583, 1200)], 0, 0),
    ("最长一组超过阈值必须报",
     [COLS, _row("2026-10-21 09:00", "✔ 全部通过", "20/20", 1300, 800, 600)], 1, 0),
    ("总耗时短于最长一组必须报",
     [COLS, _row("2026-10-21 09:00", "✔ 全部通过", "20/20", 100, 580, 1200)], 1, 0),
    ("判定 ✔ 却少跑了组必须报",
     [COLS, _row("2026-10-21 09:00", "✔ 全部通过", "19/20", 1300, 580, 1200)], 1, 0),
    ("组数写坏必须报",
     [COLS, _row("2026-10-21 09:00", "✔ 全部通过", "二十组", 1300, 580, 1200)], 1, 0),
    ("非整数必须报（不许 traceback）",
     [COLS, _row("2026-10-21 09:00", "✔ 全部通过", "20/20", "13xx", 580, 1200)], 1, 0),
    ("表头不对必须报",
     [["start", "verdict"], _row("2026-10-21 09:00", "✔", "20/20", 1, 1, 2)], 1, 0),
    ("整行少列必须报",
     [COLS, "\t".join(["2026-10-21 09:00", "✔ 全部通过", "20/20"])], 1, 0),
    ("空文件必须报",
     [], 1, 0),
    # ↓ 这两条是本次新增的：第 5 条判据（只产 ⚠）此前**零覆盖**
    ("阈值与上一条最长不符必须告警",
     [COLS, _row("2026-10-21 09:00", "✔ 全部通过", "20/20", 1300, 580, 1200),
      _row("2026-10-21 10:00", "✔ 全部通过", "20/20", 1320, 583, 1100)], 0, 1),
    ("两行各违规必须各报一次（不是只报一次）",
     [COLS, _row("2026-10-21 09:00", "✔ 全部通过", "20/20", 1300, 800, 600),
      _row("2026-10-21 10:00", "✔ 全部通过", "20/20", 1320, 810, 600)], 2, 1),
]


SELFTEST_GM = [
    # (说明, 轮次表行, groupmax 内容, 期望 ✘, 期望 ⚠)
    # ★ 用 `_G2`（最长 586 / 583）做底表：
    ("groupmax：等于最后一行 ⇒ 不报", None, "583", 0, 0),
    ("groupmax：不是数字 ⇒ 必须报", None, "五八三\n", 1, 0),
    ("groupmax：表里没有这一轮 ⇒ 必须报（手改/写到一半）", None, "600", 1, 0),
    ("groupmax：对得上但不是最后一行 ⇒ 只告警", None, "586", 0, 1),
    # 反向：证明上面「不报」的那条不是因为它根本没查
    ("groupmax：空内容 ⇒ 必须报", None, "", 1, 0),
]


def _mklog(pairs):
    return "\n".join("⏱ %s 用时 %d s" % (n, s) for n, s in pairs) + "\n"


# 与下面 `_G3` 最后一行（20/20、最长 583 s、名字 "x"）一致 / 各处差一项的日志
_LOG_SAME = _mklog([("甲", 10)] * 19 + [("x", 583)])
_LOG_NAME = _mklog([("甲", 10)] * 19 + [("zz", 583)])
_LOG_SECS = _mklog([("甲", 605)] + [("乙", 10)] * 19)
_LOG_SHORT = _mklog([("甲", 10)] * 18 + [("x", 583)])

SELFTEST_LOG = [
    # (说明, 日志文本, 期望 ✘, 期望 ⚠)
    ("日志：与表一致 ⇒ 不报", _LOG_SAME, 0, 0),
    ("日志：组数少一行 ⇒ 必须报", _LOG_SHORT, 1, 0),
    ("日志：最长一组对不上 ⇒ 必须报", _LOG_SECS, 1, 0),
    ("日志：一行 ⏱ 都没有 ⇒ 必须报（无法对账 ≠ 通过）", "只有别的内容\n", 1, 0),
    ("日志：最长一组名字不同 ⇒ 只告警", _LOG_NAME, 0, 1),
]


def selftest():
    bad = 0
    for name, lines, want, want_w in SELFTEST:
        text = "\n".join("\t".join(l) if isinstance(l, list) else l for l in lines)
        rows, errs = parse(text)
        b, w = check_rows(rows)
        got, got_w = len(errs) + len(b), len(w)
        ok = (got == want and got_w == want_w)
        if not ok:
            bad += 1
        print("    %s %-28s 期望 ✘%d ⚠%d，实际 ✘%d ⚠%d"
              % ("✔" if ok else "✘", name, want, want_w, got, got_w))
        if not ok:
            for m in errs + b:
                print("         · ✘ %s" % m)
            for m in w:
                print("         · ⚠ %s" % m)
    # ---- groupmax 与轮次表的对账（第二批补，第一版根本没读这个文件）----
    _G2 = [COLS,
           _row("2026-10-21 09:00", "✔ 全部通过", "20/20", 1320, 586, 1080),
           _row("2026-10-21 10:00", "✔ 全部通过", "20/20", 1300, 583, 1200)]
    for name, lines, gm, want, want_w in SELFTEST_GM:
        lines = _G2 if lines is None else lines
        rows, _errs = parse("\n".join("\t".join(l) if isinstance(l, list) else l
                                      for l in lines))
        b, w = check_groupmax(rows, gm)
        got, got_w = len(b), len(w)
        ok = (got == want and got_w == want_w)
        if not ok:
            bad += 1
        print("    %s %-28s 期望 ✘%d ⚠%d，实际 ✘%d ⚠%d"
              % ("✔" if ok else "✘", name, want, want_w, got, got_w))
        if not ok:
            for m in b:
                print("         · ✘ %s" % m)
            for m in w:
                print("         · ⚠ %s" % m)
    _G3 = [COLS,
           _row("2026-10-21 09:00", "✔ 全部通过", "20/20", 1320, 586, 1080),
           _row("2026-10-21 10:00", "✔ 全部通过", "20/20", 1300, 583, 1200)]
    for name, log_text, want, want_w in SELFTEST_LOG:
        _rows, _errs = parse("\n".join("\t".join(l) if isinstance(l, list) else l
                                        for l in _G3))
        b, w = check_log(log_text, *row_expect(_rows[-1]))
        got, got_w = len(b), len(w)
        ok = (got == want and got_w == want_w)
        if not ok:
            bad += 1
        print("    %s %-28s 期望 ✘%d ⚠%d，实际 ✘%d ⚠%d"
              % ("✔" if ok else "✘", name, want, want_w, got, got_w))
        if not ok:
            for m in b:
                print("         · ✘ %s" % m)
            for m in w:
                print("         · ⚠ %s" % m)
    total = len(SELFTEST) + len(SELFTEST_GM) + len(SELFTEST_LOG)
    print("  %s %d 条合成用例（✘ 与 ⚠ 都数）" % ("✔" if bad == 0 else "✘", total))
    return 0 if bad == 0 else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=DEFAULT)
    ap.add_argument("--groupmax", default=GROUPMAX,
                    help="阈值来源文件（`run_all.sh` 每轮全量写一次）")
    ap.add_argument("--log", default=LOG, help="组用时日志（默认 tests/_run_all.log）")
    ap.add_argument("--no-log", action="store_true",
                    help="只查表、不与日志对账（④ 组用：那时日志还没写完）")
    ap.add_argument("--wire-groups", default=None, help="轮末对账：本次执行组数")
    ap.add_argument("--wire-max", default=None, help="轮末对账：本轮最长一组秒数")
    ap.add_argument("--wire-name", default=None, help="轮末对账：本轮最长一组名字")
    ap.add_argument("--selftest", action="store_true", help="合成违规，证明判据会响")
    a = ap.parse_args()

    if a.selftest:
        return selftest()

    if a.wire_groups is not None or a.wire_max is not None:
        # ★★ 轮末对账：表的最后一行还是**上一轮**的，所以期望值只能由调用方给。
        #   这也是**唯一**能对账的时刻：本轮所有 `⏱` 已写完（⑥ 之后）、本轮的行还没写。
        if not os.path.isfile(a.log):
            print("  （没有 %s —— 日志对账**没有执行**，不是通过）"
                  % os.path.relpath(a.log, ROOT).replace("\\", "/"))
            return 2
        n = None
        if a.wire_groups and "/" in a.wire_groups:
            a0 = a.wire_groups.partition("/")[0].strip()
            n = int(a0) if a0.isdigit() else None
        b, w = check_log(io.open(a.log, encoding="utf-8", errors="replace").read(),
                         n,
                         int(a.wire_max) if (a.wire_max or "").strip().isdigit() else None,
                         a.wire_name)
        print("  轮末对账：日志 ↔ 即将写入 %s 的这一行（%s 组 / 最长 %s s / %s）"
              % (os.path.relpath(a.file, ROOT).replace("\\", "/"),
                 n if n is not None else "?", a.wire_max, a.wire_name))
        for m in b:
            print("  ✘ %s" % m)
        for m in w:
            print("  ⚠ %s" % m)
        if not b:
            print("  ✔ 两个落盘点一致（日志 %d 行 ⏱）"
                  % len(_TIME_RE.findall(
                      io.open(a.log, encoding="utf-8", errors="replace").read())))
        return 1 if b else 0

    if not os.path.isfile(a.file):
        # ★ 不许静静返回 0：那会让「本机还没跑过」看起来像「检查通过」。
        print("  （没有 %s —— 这台机器还没有跑过 run_all，本检查**没有执行**，不是通过）"
              % os.path.relpath(a.file, ROOT).replace("\\", "/"))
        return 2

    text = io.open(a.file, encoding="utf-8", errors="replace").read()
    rows, errs = parse(text)
    bad, warn = check_rows(rows)
    print("  轮次记录：%s（%d 行）" % (os.path.relpath(a.file, ROOT).replace("\\", "/"), len(rows)))
    # ★ groupmax 是**下一轮阈值的唯一来源**，与轮次表必须对得上。
    if os.path.isfile(a.groupmax):
        gm_text = io.open(a.groupmax, encoding="utf-8", errors="replace").read()
        gb, gw = check_groupmax(rows, gm_text)
        bad += gb
        warn += gw
        print("  阈值来源：%s = %r" % (os.path.relpath(a.groupmax, ROOT).replace("\\", "/"),
                                     gm_text.strip()))
    else:
        print("  （没有 %s —— groupmax 对账**没有执行**，不是通过）"
              % os.path.relpath(a.groupmax, ROOT).replace("\\", "/"))
    # ★ 日志是**第二个落盘点**：与表的最后一行对账（组数 / 最长_s / 名字）。
    #   `--no-log` 用于「日志还没写完」的场合（④ 组跑在第 14 位，见 run_all.sh 的注释）。
    #   `log_ran` 只为了让**通过时那句总结**如实反映「这次到底查了哪几条」——
    #   通过文案里写了一条没跑过的判据，与「文档承诺了、代码没做」是同一类错。
    log_ran = False
    if a.no_log:
        print("  （--no-log：不与日志对账 —— 只查了表自己）")
    elif os.path.isfile(a.log):
        lb, lw = check_log(io.open(a.log, encoding="utf-8", errors="replace").read(),
                           *row_expect(rows[-1] if rows else None))
        bad += lb
        warn += lw
        log_ran = True
        print("  组用时日志：%s" % os.path.relpath(a.log, ROOT).replace("\\", "/"))
    else:
        print("  （没有 %s —— 日志对账**没有执行**，不是通过）"
              % os.path.relpath(a.log, ROOT).replace("\\", "/"))

    for m in errs + bad:
        print("  ✘ %s" % m)
    for m in warn:
        print("  ⚠ %s" % m)
    if not errs and not bad:
        print("  ✔ 不变量全部成立（最长 ≤ 阈值 / 总耗时 ≥ 最长 / 组数与判定自洽 / "
              "groupmax 与表对得上%s）"
              % ("／日志 ⏱ 行数与最长一组与表对得上" if log_ran else "／**日志未对账**"))
    return 0 if (not errs and not bad) else 1


if __name__ == "__main__":
    sys.exit(main())
