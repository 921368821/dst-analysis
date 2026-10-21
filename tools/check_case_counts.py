#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""check_case_counts.py —— 判据自检「用例条数」的三方对账（提交闸门第 ⑨ 步）

为什么要有（开发计划 §9cd / §9cg）
  `run_all.sh` 与 `pre-commit.sh` 调用各工具的 `--selftest` 时**只看退出码**：
  用例被删掉一半、剩下的一半全过，rc 仍是 0，闸门照样绿。
  今天给 5 个工具各加了 `WANT_CASES` 自守，但那只拦得住「用例被删、常量没动」——
  如果有人把用例和常量**一起**改小，工具照样绿。外部锚点只能是
  一份进仓库、进 diff、要人看过的清单：`tools/case_counts.txt`。

三方对账（任何一方单独都不够）
  清单（人审）      ←→  工具源码里的 WANT_CASES（自守）   ：防「只改了其中一处」
  清单（人审）      ←→  实跑输出的「（用例 N 条）」        ：防「用例被删、常量没动」
  rc == 0                                                 ：防「条数对但有用例失败」

  为什么还要比「清单 ↔ WANT_CASES」：两者都写同一个数，是本仓库唯一允许的重复 ——
  但它必须是**被程序比对着的重复**。今天已经吃过一次教训：
  `final_check.sh` 里 `want="${pair##*:}"` 算出来没人用，那一列「23 条 / 22 条」
  就只是打印出来的装饰。重复不可怕，没人比对才可怕。

  ⚠ 这一条守不住「清单也被一起改小」—— 那只能靠人看 diff。如实写在这儿，不当成守住了。

用法
  python tools/check_case_counts.py              # 判
  python tools/check_case_counts.py --selftest   # 判这条判据自己（8 条合成用例）
"""
import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "tools", "case_counts.txt")

WANT_CASES = 14         # 本工具自检用例条数：加/删必须同步改这里（否则自检静默变松）

# 各工具统一在末行加「（用例 N 条）」。只认这一种写法 ——
# 认两种的那一版（`自检：23/23` / `N 条合成用例`）要求每个工具各写一条正则，
# 结果新增工具时很容易漏，漏了就走「读不出」分支，等于白写。统一成一种更稳。
CASE_RE = re.compile(r"（用例 (\d+) 条）")
# Python 侧写 `WANT_CASES = 7`，JS 侧写 `const WANT_CASES = 4;`（在函数里，有缩进）—— 两种都认。
DECL_RE = re.compile(r"^\s*(?:const\s+)?WANT_CASES\s*=\s*(\d+)", re.M)


def runner_for(path):
    """按扩展名选解释器：.mjs/.js 用 node（环境变量 NODE 优先，与 tools/env.sh 一致）。"""
    if path.endswith((".mjs", ".js")):
        return [os.environ.get("NODE") or "node"]
    return [sys.executable]


# ---- 覆盖：闸门脚本里凡 `X --selftest` 的调用，都必须在这份清单里有一条 ----
# 为什么需要：清单只保证「记在册的那些」不静默变松。若有人新写一个判据、在
# run_all/pre-commit 里调了它的 --selftest，却忘了登记，它仍然只被 rc 守着 ——
# 而这份清单会一声不响地全绿。**「清单没记」和「清单记了但松了」是两件事。**
GATES = ["07-通用引擎/tests/run_all.sh", "tools/pre-commit.sh"]
CALL_RE = re.compile(r'([A-Za-z0-9_./-]+\.(?:py|mjs))"?\s+--selftest')

# 白名单**必须带理由**，而且会被打印出来 —— 静默白名单比没有更糟（开发计划 §9bq）。
ALLOW = {
    "falsify_server.py":
        "入口是 --selftest-heal，条数记在实现文件 tests/falsify_heal_selftest.py 名下",
    "check_leftovers.py":
        "自检会真的去杀进程，不宜放进每次提交的闸门；只在 run_all ④ 跑，**条数未纳管**（如实登记）",
}


def coverage_problems(gate_texts, covered, allow):
    """gate_texts = {路径: 内容}；covered = 清单里的 basename 集合。

    返回 (problems, waived)；waived = [(basename, 理由)]。纯函数，便于喂合成用例。
    """
    probs, waived = set(), set()
    for gpath in sorted(gate_texts):
        for m in CALL_RE.finditer(gate_texts[gpath] or ""):
            base = os.path.basename(m.group(1))
            if base in covered:
                continue
            if base in allow:
                waived.add((base, allow[base]))
                continue
            probs.add("%s 里调用了 %s --selftest，但清单没有它 —— 它现在只被 rc 守着"
                      % (gpath, base))
    return sorted(probs), sorted(waived)


def actual_cases(out):
    """从 --selftest 输出里读实跑条数；读不出返回 None（**不返回 0**）。"""
    hits = CASE_RE.findall(out or "")
    return int(hits[-1]) if hits else None


def parse_manifest(text):
    """返回 (rows, problems)。rows = [(path, want, note)]。

    第一列只写**文件路径**，不写参数：`falsify_server.py` 的入口虽然叫 `--selftest-heal`，
    但清单指向它的实现文件 `tests/falsify_heal_selftest.py`（同一个 main()）。
    为什么不做「第一列带参数」：加了就要有 owner 列去指明 WANT_CASES 在哪个文件里，
    而目前只有一个这样的工具 —— **一个用户都没有的通用能力，就是死代码**（§9cd 那条）。
    """
    rows, bad = [], []
    for ln, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("\t") if p.strip()]
        if len(parts) < 2:
            bad.append("清单第 %d 行格式不对（要「路径<TAB>条数[<TAB>说明]」）：%r" % (ln, line))
            continue
        path, num = parts[0], parts[1]
        if not num.isdigit():
            bad.append("清单第 %d 行的条数不是数字：%r" % (ln, num))
            continue
        if os.path.isabs(path) or ".." in path.replace("\\", "/").split("/"):
            bad.append("清单第 %d 行必须写仓库内相对路径：%r" % (ln, path))
            continue
        if " " in path:
            bad.append("清单第 %d 行第一列只写路径，不带参数：%r" % (ln, path))
            continue
        rows.append((path, int(num), parts[2] if len(parts) > 2 else ""))
    return rows, bad


def judge(declared, want, rc, out):
    """纯函数：给定「工具自守常量 / 清单期望 / 实跑 rc / 输出」，返回问题列表。

    抽成纯函数是为了能一条一条喂合成用例 —— 否则这段逻辑只能靠「真跑一遍看看」检验，
    而真跑一遍只能证明「现在是对的」，证明不了「错了会红」。
    """
    p = []
    if declared is None:
        p.append("工具里没有 WANT_CASES —— 它自己不守用例数，只剩这份清单在看")
    elif declared != want:
        p.append("工具自守 WANT_CASES = %d，清单写 %d —— 同一件事的两处说法必须一致"
                 % (declared, want))
    if rc != 0:
        p.append("自检 rc=%d —— 有用例没过（条数对不代表全过）" % rc)
    got = actual_cases(out)
    if got is None:
        p.append("rc=%d 但输出里读不出「（用例 N 条）」—— 不当作通过" % rc)
    elif got != want:
        p.append("实跑 %d 条，清单期望 %d 条 —— 用例被增删了就必须改清单"
                 "（这一刻它在提醒你 diff 里多了什么）" % (got, want))
    return p


def selftest():
    ok = 0
    failures = []

    def case(name, declared, want, rc, out, nbad):
        nonlocal ok
        got = judge(declared, want, rc, out)
        if len(got) == nbad:
            ok += 1
        else:
            failures.append("%s：期望 %d 条问题，实际 %d 条%s"
                            % (name, nbad, len(got), ("：" + "；".join(got)) if got else ""))

    case("全对",              9, 9, 0, "  ✔ check_x 自检：9/9 通过（用例 9 条）", 0)
    case("用例被删常量没动",   9, 9, 0, "  ✔ check_x 自检：8/8 通过（用例 8 条）", 1)
    # ★ 这条期望本来是 1，实测 2 —— **两处都跟清单不一致，就该报两条**：
    #   「WANT_CASES 8 ≠ 清单 9」与「实跑 8 ≠ 清单 9」。写窄了（期望 1）会让我
    #   去改代码迁就一个错的期望；期望要按「它该报几条」写，不是按「我想看到几条」写。
    case("用例和常量一起改小", 8, 9, 0, "  ✔ check_x 自检：8/8 通过（用例 8 条）", 2)
    case("工具没有 WANT_CASES", None, 9, 0, "  ✔ check_x 自检：9/9 通过（用例 9 条）", 1)
    case("rc=1（有用例没过）",  9, 9, 1, "  ✘ check_x 自检：8/9 通过（用例 9 条）", 1)
    case("读不出条数",         9, 9, 0, "  ✔ 全部通过", 1)
    case("条数与 rc 同时坏",    9, 9, 1, "  ✘ 自检不过：用例条数", 2)

    # 清单解析：格式错 / 绝对路径 / 正常行 / 注释空行
    rows, bad = parse_manifest("# c\n\n tools/a.py 9\n")
    if len(bad) == 1 and not rows:
        ok += 1
    else:
        failures.append("清单：格式错（用空格分隔）应报 1 条问题，实际 %d 条、%d 行"
                        % (len(bad), len(rows)))
    rows, bad = parse_manifest("tools/a.py\t9\t说明\n07-通用引擎/tools/b.py\t28\n")
    if not bad and rows == [("tools/a.py", 9, "说明"),
                            ("07-通用引擎/tools/b.py", 28, "")]:
        ok += 1
    else:
        failures.append("清单：正常两行应解析成 2 行，实际 %d 行、问题 %s" % (len(rows), bad))

    # ★ 一个「看起来通用」的能力如果没有用户，就是死代码：第一列本来支持带参数
    #   （`falsify_server.py --selftest-heal`），但那要求再开一列指明 WANT_CASES 在
    #   哪个文件里，而这样的工具目前只有一个 ⇒ 改成「清单指向自检实现文件」。
    #   这条用例守的就是这个约定本身：第一列带空格 ⇒ 报「只写路径，不带参数」。
    rows, bad = parse_manifest("07-通用引擎/tests/falsify_server.py --selftest-heal\t5\tx\n")
    if len(bad) == 1 and not rows:
        ok += 1
    else:
        failures.append("清单：第一列带参数应被拒（%d 条问题、%d 行）" % (len(bad), len(rows)))

    # ★ 判据工具一半是 .mjs：按扩展名选解释器，别把「只支持 Python」当成「JS 不用守」。
    r = runner_for("a/b.mjs")
    if len(r) == 1 and (r[0] == "node" or r[0].lower().endswith(("node", "node.exe"))):
        ok += 1
    else:
        failures.append("runner_for(.mjs) 应选 node，实际 %r" % (r,))

    # ---- 覆盖检查：闸门里调了 --selftest 却没进清单的，必须报 ----
    # 这三条守的是「清单只保证记在册的那些」这个盲区：新写一个判据、在闸门里调它的
    # --selftest、忘了登记 ⇒ 它仍然只被 rc 守着，而清单会一声不响地全绿。
    gate = {'g.sh': 'if run_step "$PY" -u tools/a.py --selftest; then :; fi\n'}
    p, w = coverage_problems(gate, {"a.py"}, {})
    if not p and not w:
        ok += 1
    else:
        failures.append("覆盖：已登记的工具不该报问题，实际 问题%s 豁免%s" % (p, w))
    p, w = coverage_problems(gate, set(), {})
    if len(p) == 1 and not w:
        ok += 1
    else:
        failures.append("覆盖：未登记的工具应报 1 条问题，实际 %d 条" % len(p))
    p, w = coverage_problems(gate, set(), {"a.py": "理由"})
    if not p and len(w) == 1:
        ok += 1
    else:
        failures.append("覆盖：白名单应只产生豁免（问题 %s / 豁免 %s）" % (p, w))

    # 用例数自守：按「跑了几条」核，不按「过了几条」核 ——
    # 用 ok 去核会在失败时恰好抵消掉一条（ok=8、期望 8 看着相等），把漏用例盖住。
    attempted = ok + len(failures)
    if attempted != WANT_CASES:
        failures.append("自检用例 %d 条，期望 %d 条 —— 加/删用例时必须同步 WANT_CASES，"
                        "否则这条自检会静默变松" % (attempted, WANT_CASES))
        attempted = ok + len(failures)
    if failures:
        print("  ✘ 自检不过：")
        for f in failures:
            print("    ✘ %s" % f)
        print("  ✘ check_case_counts 自检：%d/%d（用例 %d 条）"
              % (ok, attempted, attempted))
        return 1
    print("  ✔ check_case_counts 自检：%d/%d 通过（用例 %d 条）" % (ok, attempted, attempted))
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()

    try:
        text = io.open(MANIFEST, encoding="utf-8", newline="").read()
    except OSError as e:
        print("  ✘ 读不到清单 %s：%s" % (MANIFEST, e))
        return 1

    rows, problems = parse_manifest(text)
    nbad = 0
    for p in problems:
        print("  ✘ %s" % p)
        nbad += 1
    if not rows:
        print("  ✘ 清单里一条用例数都没有 —— 这条判据在空转")
        return 1

    total_cases = 0
    for path, want, note in rows:
        full = os.path.join(ROOT, path)
        if not os.path.isfile(full):
            print("  ✘ %s：清单里的文件不存在" % path)
            nbad += 1
            continue
        try:
            src = io.open(full, encoding="utf-8", errors="replace").read()
        except OSError as e:
            print("  ✘ %s：读不到源码（%s）" % (path, e))
            nbad += 1
            continue
        m = DECL_RE.search(src)
        declared = int(m.group(1)) if m else None
        try:
            r = subprocess.run(runner_for(full) + [full, "--selftest"],
                               cwd=ROOT, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, universal_newlines=True,
                               timeout=300)
            rc = r.returncode
            out = r.stdout or ""
        except subprocess.TimeoutExpired:
            rc, out = 124, ""
        except OSError as e:
            rc, out = 2, "<无法执行：%s>" % e
        probs = judge(declared, want, rc, out)
        if probs:
            for q in probs:
                print("  ✘ %s：%s" % (path, q))
            nbad += 1
        else:
            total_cases += want
            print("  ✔ %-40s 用例 %d 条（自守 %d / 清单 %d / 实跑 %d）%s"
                  % (path, want, declared, want, actual_cases(out),
                     ("　" + note) if note else ""))

    if nbad:
        print("✘ %d 处对不上：清单 tools/case_counts.txt 是唯一真源，改完代码要顺手改它"
              % nbad)
        return 1

    # ---- 覆盖：闸门脚本里调了 --selftest 的，清单里都得有一条 ----
    covered = set(os.path.basename(p) for p, _w, _n in rows)
    gate_texts = {}
    for g in GATES:
        fp = os.path.join(ROOT, g)
        if os.path.isfile(fp):
            gate_texts[g] = io.open(fp, encoding="utf-8", errors="replace").read()
        else:
            print("  ⚠ 闸门脚本不存在：%s（覆盖检查跳过它，不当成通过）" % g)
    cov, waived = coverage_problems(gate_texts, covered, ALLOW)
    for base, why in waived:
        print("  ⊘ 豁免 %-26s %s" % (base, why))
    if cov:
        for q in cov:
            print("  ✘ 覆盖：%s" % q)
        print("✘ %d 个自检仍只被 rc 守着 —— 要么加进清单，要么写进 ALLOW 并说明理由" % len(cov))
        return 1

    n_calls = len(set(os.path.basename(m.group(1))
                      for t in gate_texts.values()
                      for m in CALL_RE.finditer(t or "")))
    print("✔ %d 个工具、共 %d 条用例：清单 / 工具自守 / 实跑输出 三方一致；"
          "闸门里 %d 个自检目标已全部纳入或带理由豁免"
          % (len(rows), total_cases, n_calls))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
