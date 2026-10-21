#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_src_guard.py —— 「源码里是不是还留着上一轮被中断的变异」

★★ 为什么需要它（2026-10-21 实测，§9bm）

本工程有**两处**会把变异**直接写进真源码**（不是副本）：

| 谁 | 什么时候 | 备份在哪 | 被 kill 后能不能自动还原 |
|---|---|---|---|
| `tests/falsify_server.py`（②f） | 每轮全量 | 标记文件里存 `originals` | **能**（`--heal`） |
| `tests/test_stall_watchdog.py`（W12） | 每轮全量 | **只在进程内存里**（`MUT_BACKUP`） | **不能** |

而还原动作 `heal_leftover()` 只在 `run_all.sh` 开头被调用一次。
2026-10-20 23:10 的 `--fast` 被掐断在 ②f 中途，`rt/rt_boot.lua` 停在
`if true then return true end`（原文 `if not isnight then return true end`）——
于是 `in_light_at()` **永远返回「在光里」**，整段夜间光照判据变成空检查。
今早 09:13 才还原：中间 **10 小时 3 分**，这期间任何「单独跑一个案子看现象」
「发布烟测」「手工 test_rt」都跑在脏源码上，结论全假 —— 而且全是**绿色**的。

所以问题的形状不是「还原写得不对」（它是对的、5 条自测已在 ②f 里跑），
而是 **还原只在一条路径上触发**，而且 **W12 那一路连锁都没有**。

判据（与 `check_leftovers.classify_filelist` 同一条口径：pid 活着 = 在用）
    · 没有标记文件                    ⇒ 干净，放行
    · 标记里有 pid 且该 pid 还活着      ⇒ 有进程正在变异，放行（②f / W12 自己就是）
    · 标记里有 pid 但该 pid 已不在      ⇒ **陈旧变异**，拒绝开跑
    · 标记读不出来 / 没有 pid 字段      ⇒ **无法判定**，拒绝开跑
    · 拿不到进程表                     ⇒ **无法判定**，拒绝开跑

为什么「无法判定」选拒绝而不是放行
    两侧代价不对称：放行一次可能换来**一整天的假绿**（已发生一次，10 小时），
    拒绝一次只损失**一分钟**，而且有明确出口（`RT_ALLOW_DIRTY_SRC=1`）。

用法
    from _src_guard import guard
    guard()                                   # 脏就 SystemExit(2)，并打印还原命令

    python tests/_src_guard.py                # 只查一次，0 干净 / 2 脏
    python tests/_src_guard.py --heal         # ★ 按标记里的 originals 还原（两个标记都认）
    python tests/_src_guard.py --selftest     # ★ 合成用例，证明它会响、也会还原
"""
import argparse
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# 两个就地篡改者各写一个标记：②f 的、W12 的。**同一套 schema**（都带 pid + originals）。
MARKS = [os.path.join(HERE, "_falsify_inprogress.json"),
         os.path.join(HERE, "_mutant_inprogress.json")]
MARK = MARKS[0]
ENV_BYPASS = "RT_ALLOW_DIRTY_SRC"


def _pid_set():
    """活着的 pid 集合；拿不到 ⇒ None。**复用** check_leftovers 的实现（不抄第二份）。"""
    sys.path.insert(0, os.path.join(os.path.dirname(HERE), "tools"))
    try:
        from check_leftovers import pid_set
        return pid_set()
    except Exception:                                            # noqa: BLE001
        return None


def inspect(mark=None, pids="auto"):
    """查**一个**标记 → (是否脏, 说明)。纯判定，不打印、不退出，便于自检注入。"""
    mark = MARK if mark is None else mark
    if not os.path.exists(mark):
        return False, "没有 %s ⇒ 源码不在变异态" % os.path.basename(mark)
    try:
        info = json.load(io.open(mark, encoding="utf-8"))
    except Exception as e:                                       # noqa: BLE001
        return True, "标记 %s 读不出来（%s: %s）⇒ 无法判定，按脏处理" % (
            os.path.basename(mark), type(e).__name__, e)
    pid = info.get("pid")
    if not pid:
        return True, ("标记 %s 里没有 pid（旧格式）⇒ 无法判定是否还活着，按脏处理"
                      % os.path.basename(mark))
    if pids == "auto":
        pids = _pid_set()
    if pids is None:
        return True, "拿不到进程表 ⇒ 无法判定 pid %r 是否还活着，按脏处理" % (pid,)
    if pid in pids:
        return False, "标记 %s 的 pid %r 还活着 ⇒ 有进程正在做变异测试，放行" % (
            os.path.basename(mark), pid)
    return True, ("标记 %s 的 pid %r 已不在 ⇒ **上一轮变异没还原**（文件仍停在篡改态）"
                  % (os.path.basename(mark), pid))


def inspect_any(marks=None, pids="auto"):
    """> 一个标记就算脏。**任一脏即脏**：②f 还活着、W12 是上一轮残留，也是脏。"""
    marks = MARKS if marks is None else marks
    bad = []
    for m in marks:
        dirty, why = inspect(m, pids)
        if dirty:
            bad.append(why)
    if bad:
        return True, "；".join(bad)
    return False, "；".join(inspect(m, pids)[1] for m in marks)


def guard(marks=None, pids="auto", quiet=False):
    """脏就 `SystemExit(2)`；干净就静默返回。"""
    dirty, why = inspect_any(marks, pids)
    if not dirty:
        if not quiet:
            print("  [src_guard] %s" % why)
        return
    if os.environ.get(ENV_BYPASS) == "1":
        print("  ⚠ [src_guard] %s" % why)
        print("  ⚠ 已按 %s=1 放行 —— **本轮结论不可信**（源码可能是篡改态）" % ENV_BYPASS)
        return
    print("  ✘ [src_guard] %s" % why)
    print("     源码里可能还留着变异，此时任何测试结论都可能**假绿**。先还原：")
    print("       cd 07-通用引擎 && python tests/_src_guard.py --heal")
    print("     确认 git diff 为空后重跑；确实要在脏源码上跑，设 %s=1。" % ENV_BYPASS)
    raise SystemExit(2)


def heal(marks=None, quiet=False):
    """按标记里的 `originals` 把文件逐字节写回，再删标记 → 还原了几个 / 失败几个。

    ★ 读写都要 `newline=""`：否则 CRLF 会在「存进去」或「写回来」时被翻译成 LF，
      而校验那一遍也用翻译读法 ⇒ 两边都翻译 ⇒ **报「一致」**（这个坑 §9bg 记过）。
    """
    marks = MARKS if marks is None else marks
    ok = bad = 0
    for m in marks:
        if not os.path.exists(m):
            continue
        try:
            info = json.load(io.open(m, encoding="utf-8"))
        except Exception as e:                                   # noqa: BLE001
            if not quiet:
                print("  ✘ %s 读不出来（%s）—— 无法还原，请手工 git checkout" % (
                    os.path.basename(m), e))
            bad += 1
            continue
        originals = info.get("originals") or {}
        if not originals:
            if not quiet:
                print("  ✘ %s 里没有 originals —— 无法还原，请手工 git checkout" % (
                    os.path.basename(m)))
            bad += 1
            continue
        for path, text in originals.items():
            try:
                io.open(path, "w", encoding="utf-8", newline="").write(text)
                back = io.open(path, encoding="utf-8", newline="").read()
            except OSError as e:                                 # noqa: BLE001
                if not quiet:
                    print("  ✘ 写不回 %s：%s" % (path, e))
                bad += 1
                continue
            if back != text:
                if not quiet:
                    print("  ✘ %s 写回后与原文不一致（后续结论不可信）" % path)
                bad += 1
            else:
                ok += 1
                if not quiet:
                    print("  ✔ 已还原 %s（%d 字节）" % (
                        os.path.relpath(path, os.path.dirname(HERE)),
                        len(text.encode("utf-8"))))
        try:
            os.remove(m)
        except OSError:
            pass
    if not quiet:
        print("  结果：还原 %d 个文件，失败 %d 处" % (ok, bad))
    return ok, bad


# ── 合成用例：证明上面那几条真的会响、heal 真的写回 ──────────────
SELFTEST = [
    # (说明, 标记内容(None=不建文件), 活 pid 集合(None=拿不到), 期望脏?, 期望关键词)
    ("没有标记文件 ⇒ 干净", None, set(), False, "没有"),
    ("pid 还活着 ⇒ 放行（②f / W12 自己正在变异）",
     {"pid": 4242, "desc": "x"}, {4242}, False, "还活着"),
    ("pid 已不在 ⇒ 脏（这就是那次 10 小时）",
     {"pid": 4242, "desc": "x"}, {1, 2}, True, "没还原"),
    ("旧标记没有 pid 字段 ⇒ 无法判定，按脏",
     {"desc": "x"}, set(), True, "没有 pid"),
    ("拿不到进程表 ⇒ 无法判定，按脏",
     {"pid": 4242, "desc": "x"}, None, True, "拿不到进程表"),
    ("标记是坏 JSON ⇒ 按脏，不许抛",
     "{not json", set(), True, "读不出来"),
]


def selftest():
    import tempfile
    d = tempfile.mkdtemp(prefix="sg_")
    bad = 0
    for name, content, pids, want_dirty, kw in SELFTEST:
        p = os.path.join(d, "mark.json")
        if os.path.exists(p):
            os.remove(p)
        if content is not None:
            io.open(p, "w", encoding="utf-8", newline="").write(
                content if isinstance(content, str) else json.dumps(content))
        try:
            dirty, why = inspect(p, pids)
            ok = (dirty == want_dirty and kw in why)
        except Exception as e:                                   # noqa: BLE001
            dirty, why, ok = None, "%s: %s" % (type(e).__name__, e), False
        if not ok:
            bad += 1
        print("    %s %-32s 期望%s，实得%s（%s）"
              % ("✔" if ok else "✘", name,
                 "脏" if want_dirty else "干净", "脏" if dirty else "干净", why[:44]))
    # ---- 两个标记：任一脏即脏 ----
    a = os.path.join(d, "a.json")
    b = os.path.join(d, "b.json")
    io.open(a, "w", encoding="utf-8", newline="").write(json.dumps({"pid": 4242}))
    io.open(b, "w", encoding="utf-8", newline="").write(json.dumps({"pid": 9999}))
    dirty, why = inspect_any([a, b], {4242})       # a 活着、b 死了
    ok = dirty and "没还原" in why
    bad += 0 if ok else 1
    print("    %s %-32s 期望脏，实得%s（%s）" % ("✔" if ok else "✘",
          "两个标记任一脏即脏（a 活 b 死）", "脏" if dirty else "干净", why[:34]))
    # ---- heal：按 originals 逐字节写回（含 CRLF + 中文），再删标记 ----
    target = os.path.join(d, "src.lua")
    original = "-- 中文注释\r\nif not isnight then return true end\r\n"
    io.open(target, "w", encoding="utf-8", newline="").write(
        original.replace("not isnight", "true"))
    io.open(b, "w", encoding="utf-8", newline="").write(json.dumps(
        {"pid": 9999, "desc": "t", "originals": {target: original}}))
    ok_n, bad_n = heal([b], quiet=True)
    back = io.open(target, encoding="utf-8", newline="").read()
    ok = (ok_n == 1 and bad_n == 0 and back == original)
    bad += 0 if ok else 1
    print("    %s %-32s 期望逐字节写回，实得 还原%d/失败%d%s" % (
        "✔" if ok else "✘", "heal 按 originals 写回（CRLF+中文）", ok_n, bad_n,
        "" if ok else " ← 不一致"))
    # ---- heal 不许把「没 originals 的标记」当成功 ----
    io.open(a, "w", encoding="utf-8", newline="").write(json.dumps({"pid": 1}))
    ok_n, bad_n = heal([a], quiet=True)
    ok = (ok_n == 0 and bad_n == 1)
    bad += 0 if ok else 1
    print("    %s %-32s 期望 失败1，实得 还原%d/失败%d" % (
        "✔" if ok else "✘", "heal：没有 originals 必须算失败", ok_n, bad_n))
    for f in (a, b, target, os.path.join(d, "mark.json")):
        try:
            os.remove(f)
        except OSError:
            pass
    try:
        os.rmdir(d)
    except OSError:
        pass
    total = len(SELFTEST) + 3
    print("  %s %d 条合成用例" % ("✔" if bad == 0 else "✘", total))
    return 0 if bad == 0 else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--heal", action="store_true", help="按标记里的 originals 还原")
    ap.add_argument("--mark", default=None, help="只查/只还原指定的一个标记")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    marks = [a.mark] if a.mark else None
    if a.heal:
        ok_n, bad_n = heal(marks)
        return 0 if bad_n == 0 else 1
    dirty, why = inspect_any(marks)
    # ★ 命令行也要认出口，否则「按提示设了 RT_ALLOW_DIRTY_SRC=1，rc 还是 2」——
    #   提示与行为不符，比没提示更坏（本工程栽过好几回）。
    if dirty and os.environ.get(ENV_BYPASS) == "1":
        print("  ⚠ " + why)
        print("  ⚠ 已按 %s=1 放行 —— 本轮结论不可信" % ENV_BYPASS)
        return 0
    print(("  ✘ " if dirty else "  ✔ ") + why)
    return 2 if dirty else 0


if __name__ == "__main__":
    sys.exit(main())
