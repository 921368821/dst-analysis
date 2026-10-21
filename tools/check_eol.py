#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_eol.py —— 行尾一致性判据（P50㊴）

为什么需要它（2026-10-21 事故 ㊳，同一天里「同一个转换做两遍」的第三次）：
  1. 我用 `io.open(p, "w", encoding="utf-8")` 改文档里的数字，**漏了 `newline=""`**
     ⇒ Windows 的默认换行把整份草稿写成 CRLF；
  2. `insert_docs.py` 又假设草稿是 LF、再转一遍 ⇒ `阶段进度…md` 里 39 处 `\\r\\r\\n`、
     纯 LF 的 `开发计划.md` 混进 124 行 CRLF；
  3. 更隐蔽的是级联：`tail_nl()` 看「最后两个字节」，上一块以 `\\r\\n` 结尾
     ⇒ 下一块也被判成 CRLF。
  修的时候我只给插入器加了断言 —— **判据本身没有**，所以下一次换个入口照样复发。

判据（作用域内逐文件）：
  ✘ `\\r\\r\\n` > 0          —— 双重转换的指纹，没有任何正常来源
  ✘ CRLF 与裸 LF 同时 > 0   —— 文件内部不一致（git diff 会整段变红/绿，review 失去意义）
  ✘ 作用域内一个文件都没读到 ⇒ 退出码 2，**不当作通过**（§9bj.4：数什么才守得住什么）

作用域：`git ls-files` 里的 .py / .sh / .mjs，以及**根目录与引擎目录下**的 .md；
  含**未跟踪但未被忽略**的新文件（新文件最可能是工具刚写出来的，也正是最容易带错行尾的）。
  排除 `02-注释源码/` 与 `06-引擎复刻/`：上游快照，行尾由上游决定，改了会让与上游的
  整份 diff 失真。排除**不是静默的** —— 会打印排除了多少个文件、为什么
  （§9bq 的教训：白名单里写着它该抓的那句，比没有白名单更糟）。

用法：
  check_eol.py              检查；有 ✘ 则退出码 1
  check_eol.py --fix        按**多数派**归一（只动不一致的文件，逐文件打印前后）
  check_eol.py --selftest   合成用例（含反向：改了判据必须变红）
"""
import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── 作用域 ────────────────────────────────────────────────────────────────
EXCLUDE_DIRS = ("02-注释源码/", "06-引擎复刻/")
EXCLUDE_REASON = ("上游快照源码（行尾由上游决定；改它会让与上游的整份 diff 失真）")
CODE_EXT = (".py", ".sh", ".mjs", ".js")
MD_DIRS = ("07-通用引擎/", "tools/", "tests/")


def in_scope(rel):
    rel = rel.replace("\\", "/")
    if rel.startswith(EXCLUDE_DIRS):
        return False
    if rel.endswith(CODE_EXT):
        return True
    if rel.endswith(".md"):
        return "/" not in rel or rel.startswith(MD_DIRS)
    return False


def excluded(rel):
    rel = rel.replace("\\", "/")
    return rel.startswith(EXCLUDE_DIRS)


def git_files(root):
    """仓库里的全部文件（相对路径）。拿不到 git 就返回 None —— **不是空列表**。

    ★ 已跟踪 + **未跟踪但未被忽略**。只用 `ls-files` 会漏掉刚被工具写出来的新文件，
      而「刚写出来的新文件」恰恰是最可能带错行尾的那个（2026-10-21 实测：
      本工具自己与 check_doc_rounds.py 都没被扫到）。语法错误/漏 `newline=""`
      的产物往往就是新文件，所以这一半必须补上。
    """
    tracked = _git_out(root, ["ls-files", "-z"])
    untracked = _git_out(root, ["ls-files", "-z", "--others", "--exclude-standard"])
    if tracked is None or untracked is None:
        return None
    return merge_files(tracked, untracked)


def _git_out(root, args):
    try:
        r = subprocess.run(["git", "-C", root] + args, capture_output=True, check=False)
    except OSError:
        return None
    if r.returncode != 0:
        return None
    return [x for x in r.stdout.decode("utf-8", "replace").split("\0") if x]


def merge_files(tracked, untracked):
    """并集去重，保留顺序（已跟踪在前）。纯函数，便于自检。"""
    seen, out = set(), []
    for rel in list(tracked) + list(untracked):
        if rel in seen:
            continue
        seen.add(rel)
        out.append(rel)
    return out


# ── 判据本体（纯函数，便于自检） ─────────────────────────────────────────
def analyze(data):
    """返回 (crlf, bare, crcrlf)。bare = 裸 LF 行数（不含 CRLF 里的那个 LF）。"""
    crcrlf = data.count(b"\r\r\n")
    crlf = data.count(b"\r\n")
    total = data.count(b"\n")
    return crlf, total - crlf, crcrlf


def check_one(rel, data):
    """一个文件的 ✘ 列表（空 = 通过）。只回答「是不是一色」，不评价该用哪种。"""
    if b"\x00" in data[:4096]:
        return []                                   # 二进制，不归这条判据管
    crlf, bare, crcrlf = analyze(data)
    if crlf == 0 and bare == 0:
        return []                                   # 空文件 / 一整行没有换行
    out = []
    if crcrlf:
        out.append("%s：%d 处 `\\r\\r\\n` —— 同一个转换做了两遍（CRLF 的行又被转了一次）"
                   % (rel, crcrlf))
    if crlf and bare:
        major = "CRLF" if crlf >= bare else "裸 LF"
        out.append("%s：CRLF %d 行 / 裸 LF %d 行 —— 文件内部不一致（多数派是 %s，"
                   "少数派 %d 行；`--fix` 可归一）"
                   % (rel, crlf, bare, major, min(crlf, bare)))
    return out


def scan(root, rels):
    """返回 (bad, checked, skipped)。bad 是 {rel: [消息...]}。"""
    bad, checked, skipped = {}, 0, 0
    for rel in rels:
        if excluded(rel):
            skipped += 1
            continue
        if not in_scope(rel):
            continue
        path = os.path.join(root, rel.replace("/", os.sep))
        try:
            with io.open(path, "rb") as f:
                data = f.read()
        except OSError:
            continue                                # 已删除但还在索引里
        checked += 1
        msgs = check_one(rel, data)
        if msgs:
            bad[rel] = msgs
    return bad, checked, skipped


def normalize(data):
    """按多数派归一。先消掉 `\\r\\r\\n`（它是 CRLF 的行又被转了一遍）。"""
    data = data.replace(b"\r\r\n", b"\r\n")
    crlf, bare, _ = analyze(data)
    if not crlf and not bare:
        return data, "空"
    if not (crlf and bare):
        return data, "已一色"
    use_crlf = crlf >= bare
    parts = data.split(b"\n")
    tail_nl = parts[-1] == b""
    if tail_nl:
        parts = parts[:-1]
    body = [p[:-1] if p.endswith(b"\r") else p for p in parts]
    sep = b"\r\n" if use_crlf else b"\n"
    out = sep.join(body) + (sep if tail_nl else b"")
    return out, ("CRLF" if use_crlf else "裸 LF")


def fix(root, rels):
    """就地归一。返回 (fixed, failed)。写用 `newline=""` —— 否则又是「转两遍」。"""
    fixed, failed = [], []
    for rel in rels:
        if excluded(rel) or not in_scope(rel):
            continue
        path = os.path.join(root, rel.replace("/", os.sep))
        try:
            with io.open(path, "rb") as f:
                data = f.read()
        except OSError:
            continue
        new, how = normalize(data)
        if new == data:
            continue
        try:
            with io.open(path, "wb") as f:
                f.write(new)
        except OSError as e:
            failed.append((rel, str(e)))
            continue
        after = analyze(new)
        if after[0] and after[1]:
            failed.append((rel, "归一后仍然混合（CRLF %d / 裸 LF %d）" % (after[0], after[1])))
            continue
        fixed.append((rel, how))
    return fixed, failed


# ── 自检 ─────────────────────────────────────────────────────────────────
def selftest():
    cases = []

    def add(name, ok, extra=""):
        cases.append((name, bool(ok), extra))

    def one(name, data, want):
        got = check_one("x.md", data)
        add(name, len(got) == want, "期望 ✘%d 实得 ✘%d" % (want, len(got)))

    # ① 全 CRLF ② 全 LF ③ 混合 ④ CRCRLF ⑤ CRCRLF+混合 ⑥ 空
    one("① 全 CRLF ⇒ 通过", b"a\r\nb\r\n", 0)
    one("② 全裸 LF ⇒ 通过", b"a\nb\n", 0)
    one("③ 混合 ⇒ ✘1", b"a\r\nb\n", 1)
    one("④ 只有 \\r\\r\\n ⇒ ✘1（混合那条不重复报，因为它本来是一色）", b"a\r\r\nb\r\r\n", 1)
    one("⑤ \\r\\r\\n + 混合 ⇒ ✘2（两条独立缺陷）", b"a\r\r\nb\n", 2)
    one("⑥ 空文件 ⇒ 通过", b"", 0)
    # ⑦ 二进制不归它管
    add("⑦ 含 \\0 的二进制 ⇒ 跳过（不当成缺陷）",
        check_one("x.bin", b"\x00\x01\r\nfoo\n") == [])

    # ⑧ 少一行换行（末行无换行）不算混合
    one("⑧ 末行无换行 ⇒ 通过", b"a\r\nb", 0)

    # ⑨ 归一：混合的 CRLF 多数派 ⇒ 全 CRLF，内容逐行不变
    d, how = normalize(b"a\r\nb\nc\r\n")
    add("⑨ --fix 多数派 CRLF ⇒ 全 CRLF 且内容保留",
        d == b"a\r\nb\r\nc\r\n" and how == "CRLF", repr(d))

    # ⑩ 归一：两个 \r 必须先消掉，否则修完还是坏的
    d2, _ = normalize(b"a\r\r\nb\r\r\n")
    add("⑩ --fix 先消 \\r\\r\\n ⇒ 结果无 \\r\\r\\n", b"\r\r\n" not in d2, repr(d2))

    # ⑪ 归一后必须真的通过判据（否则 fix 只是搬砖）
    add("⑪ --fix 的结果能过判据", check_one("x.md", d) == [] and check_one("x.md", d2) == [])

    # ⑫ 归一幂等
    d3, _ = normalize(d)
    add("⑫ --fix 幂等（第二次不再改）", d3 == d)

    # ⑬ 作用域：上游快照被排除，且**排除了多少**是可数的
    add("⑬ 02-注释源码 在排除域内", excluded("02-注释源码/scripts/a.lua"))
    add("⑭ 06-引擎复刻 在排除域内", excluded("06-引擎复刻/x.lua"))
    add("⑮ 引擎目录下的 .md 在作用域内", in_scope("07-通用引擎/开发计划.md"))
    add("⑯ 根目录 .md 在作用域内", in_scope("引擎审计报告.md"))
    add("⑰ 子目录深处的 .md 不在作用域内（避免再去守上游文档）",
        not in_scope("02-注释源码/README.md"))
    add("⑱ .tsv 不在作用域内（生成物）", not in_scope("07-通用引擎/tests/_run_all.rounds.tsv"))

    # ⑲ scan 在「一个文件都没有」时必须能被上层识别成「无法判定」——
    #    这里只验它不抛异常且 checked=0；退出码 2 由 main 负责
    bad, checked, skipped = scan(ROOT, [])
    add("⑲ 空列表 ⇒ checked=0（上层据此退出码 2，不是 0）", checked == 0 and not bad)
    add("⑳ 排除计数是从列表里真的数出来的", skipped == 0)

    # ㉑㉒ 作用域的另一半：未跟踪但未被忽略的新文件
    add("㉑ 并集去重：已跟踪 + 未跟踪同名只算一次", 
        merge_files(["a.py", "b.md"], ["b.md", "c.sh"]) == ["a.py", "b.md", "c.sh"])
    add("㉒ 未跟踪的新文件也在作用域内（漏掉它 = 漏掉最可能错的那个）",
        in_scope("new_tool.py") and not excluded("new_tool.py"))

    # ㉓ 接线测试：㉑ 只测了 helper，把 `return merge_files(...)` 改成 `return tracked`
    #    照样全绿 —— 那正是「判据没接进回路」。这一条真建一个临时仓库。
    import shutil
    import tempfile
    tmp = tempfile.mkdtemp(prefix="eol_")
    try:
        ok = subprocess.run(["git", "init", "-q", tmp],
                            capture_output=True).returncode == 0
        if ok:
            with io.open(os.path.join(tmp, "a.py"), "wb") as f:
                f.write(b"a\n")
            with io.open(os.path.join(tmp, "b.py"), "wb") as f:
                f.write(b"b\n")
            subprocess.run(["git", "-C", tmp, "add", "a.py"], capture_output=True)
            got = git_files(tmp)
            add("㉓ git_files 真的把未跟踪文件算进作用域（接线，不只 helper）",
                got == ["a.py", "b.py"], "实得 %r" % (got,))
        else:
            add("㉓ git_files 接线测试", False, "临时仓库建不起来，无法验证")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    good = [n for n, ok, _ in cases if ok]
    badl = [(n, e) for n, ok, e in cases if not ok]
    print("  check_eol 自检：%d/%d 通过" % (len(good), len(cases)))
    for n, e in badl:
        print("    ✘ %s%s" % (n, ("  ← " + e) if e else ""))
    return 0 if not badl else 1


# ── main ─────────────────────────────────────────────────────────────────
def main(argv):
    root = ROOT
    rels = git_files(root)
    if rels is None:
        print("  （拿不到 `git ls-files` —— 本检查**没有执行**，不是通过）")
        return 2

    bad, checked, skipped = scan(root, rels)
    if "--fix" in argv:
        fixed, failed = fix(root, rels)
        for rel, how in fixed:
            print("  ✔ 归一为 %s：%s" % (how, rel))
        for rel, err in failed:
            print("  ✘ 归一失败：%s —— %s" % (rel, err))
        if fixed:
            bad, checked, skipped = scan(root, rels)
        if failed:
            return 1

    print("  行尾判据：作用域内 %d 个文件（排除 %d 个：%s）"
          % (checked, skipped, EXCLUDE_REASON))
    if checked == 0:
        print("  （作用域内一个文件都没读到 —— 本检查**没有执行**，不是通过）")
        return 2
    if bad:
        for msgs in bad.values():
            for m in msgs:
                print("  ✘ %s" % m)
        return 1
    print("  ✔ 全部一色：无 `\\r\\r\\n`、无 CRLF/裸 LF 混排")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main(sys.argv[1:]))
