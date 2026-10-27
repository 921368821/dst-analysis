#!/usr/bin/env python3
"""变异的落盘日志：**进程被强杀之后**还能把源码还原。

★★ 为什么要有这个文件（2026-10-27 实测，同一个事故的第二次）：

   变异器改文件前把原文放在内存里（`_ACTIVE`），并在 SIGINT/SIGTERM/SIGHUP
   上挂了还原处理器。看起来兜住了 —— 但 Windows 上并没有能捕获的 SIGTERM：
   测试宿主结束子进程用的是 `TerminateProcess`，**任何 Python 处理器都不会执行**。
   Unix 上 `kill -9` 同理。于是：

     · 2026-10-26（批89）全量跑完 407 条，`lossless-pred.ts` 被留在变异态，
       工具通篇报「全部还原干净」；红要等到**下一次**跑判据才爆，而红的是
       两条 JPEG 判据，跟当时在改的东西毫无关系。
     · 2026-10-27 我 `runpy` 误触发了整轮变异，被工具超时杀掉 —— 同一个文件
       又被留在变异态（`1 << (precision - pt - 1)` → `1 << (precision - 1)`），
       而这次连一行提示都没有：被杀就是被杀。

   两次都不是"忘了还原"，而是**还原的真相只活在内存里**。内存随进程一起没。

★★ 口径：journal 是"我正在改这个文件，原文如下"，不是备份。

   `begin()` 在**写文件之前**调用，`commit()` 在**写回之后**调用。
   中间任何时刻进程死掉，磁盘上都留着一份能自证的原文：

     · `active.json` 是**提交标记**，最后写。它不存在 ⇒ 没有待恢复的事，
       哪怕有个孤零零的 `active.bin`（写到一半被杀）也不管 —— 那份 `.bin`
       对应的改动还没发生，世界是干净的。
     · `recover()` 先比对 `active.json` 里的 sha256 与 `.bin` 的实际哈希，
       对不上就**报问题而不是写半份**：写半份会把一个文件变成既不是原文
       也不是变异体的第三种东西，比不还原更坏。

★★ 为什么是独立文件而不是塞进 `tools/mutation-check.py`：
   与 `worktree_guard.py` 同一个理由 —— 变异靶子是写在变异表里的字符串字面量，
   而 `replace(old, new, 1)` 只替换**第一次**出现。实现与靶子同处一个文件时，
   第一次出现就是靶子自己，变异会改掉靶子、实现纹丝不动，而自检照样通过。
   另外这个模块要能在**不启动整轮变异**的前提下被测试（变异器本身是纯顶层脚本，
   导入即开跑），所以它必须住在别处。

用法：
  python tools/mutation_journal.py --selftest   # 自检（含"起子进程强杀再恢复"）
  python tools/mutation_journal.py --recover    # 手工恢复（引擎根下的 .cache）
"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
from datetime import datetime

# 日志目录名。放在 `.cache/` 下，与变异锁（`.cache/mutation.lock`）同级 ——
# 两者都是"这次运行的状态"，且都已在 .gitignore 里。
_DIRNAME = "mutation-journal"


def journal_dir(root: pathlib.Path) -> pathlib.Path:
    return root / ".cache" / _DIRNAME


def _fsync_write(path: pathlib.Path, data: bytes) -> None:
    """写 + fsync。★ 不 fsync 的话，"写进日志"这件事本身可能还在页缓存里，
    进程一死（尤其断电）日志就是空的 —— 那正是这套东西唯一要防的情形。"""
    with open(path, "wb") as fp:
        fp.write(data)
        fp.flush()
        os.fsync(fp.fileno())


def begin(root: pathlib.Path, target: pathlib.Path, original: bytes) -> None:
    """在**写坏 target 之前**记下原文。"""
    d = journal_dir(root)
    d.mkdir(parents=True, exist_ok=True)
    rel = target.resolve().relative_to(root.resolve()).as_posix()
    # ① 原文先落盘（内容最多，最慢）
    _fsync_write(d / "active.bin", original)
    # ② 提交标记最后写：它出现就意味着"这份原文是完整的、对应的改动即将/已经发生"
    meta = {
        "path": rel,
        "bytes": len(original),
        "sha256": hashlib.sha256(original).hexdigest(),
        "at": datetime.now().isoformat(timespec="seconds"),
        "pid": os.getpid(),
    }
    # 先删旧标记再写新标记：否则崩溃点恰好落在两者之间时，会拿**上一条**的标记
    # 去配**这一条**的 bin（哈希对不上 → 报问题，虽然安全但会丢掉一次可恢复机会）。
    _unlink(d / "active.json")
    _fsync_write(d / "active.json", json.dumps(meta, ensure_ascii=False).encode("utf-8"))


def commit(root: pathlib.Path) -> None:
    """扫尾：原文已经写回去了，忘掉它。**先删标记**（否则崩在中间会误恢复）。"""
    d = journal_dir(root)
    _unlink(d / "active.json")
    _unlink(d / "active.bin")


def _unlink(p: pathlib.Path) -> None:
    try:
        p.unlink()
    except OSError:
        pass


def recover(root: pathlib.Path) -> tuple[list[str], list[str]]:
    """把上一次没提交的原文写回去。

    返回 `(已恢复的相对路径, 问题描述)`。空 + 空 = 上次是干净结束的。
    """
    d = journal_dir(root)
    mark = d / "active.json"
    if not mark.exists():
        # 没有标记 ⇒ 没有待恢复的事。孤儿 .bin（写到一半被杀）顺手清掉。
        _unlink(d / "active.bin")
        return [], []
    try:
        meta = json.loads(mark.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        return [], [f"日志读不了（{mark}）：{e} —— 不知道该恢复哪个文件，请手工核对 git status"]

    rel = str(meta.get("path", ""))
    if not rel:
        return [], ["日志里没有文件路径 —— 无法恢复，请手工核对 git status"]

    try:
        original = (d / "active.bin").read_bytes()
    except OSError as e:
        return [], [f"日志里的原文读不到（{rel}）：{e} —— 请手工核对 git status"]

    want = str(meta.get("sha256", ""))
    got = hashlib.sha256(original).hexdigest()
    if want and got != want:
        # ★ 不写半份：写下去会得到一个既非原文也非变异体的第三态。
        return [], [
            f"日志里的原文哈希对不上（{rel}：记着 {want[:12]}，实际 {got[:12]}）"
            " —— 不写半份，请手工核对 git status"
        ]

    try:
        (root / rel).write_bytes(original)
    except OSError as e:
        return [], [f"写回失败（{rel}）：{e}"]

    commit(root)
    return [rel], []


def selftest() -> int:
    """造五种情形自证。★ 其中第 ④ 条**真的起子进程然后强杀**。"""
    fails: list[str] = []

    def check(name: str, cond: bool, detail: str) -> None:
        if not cond:
            fails.append(f"{name}（{detail}）")

    with tempfile.TemporaryDirectory() as td:
        root = pathlib.Path(td)
        (root / "src").mkdir()
        target = root / "src" / "a.ts"
        A = b"const x = 1;\r\n"
        B = b"const x = 2;\r\n"
        target.write_bytes(A)

        # ① 没有日志时 recover 什么都不做（不能平白无故写文件）
        got, probs = recover(root)
        check("无日志时 recover 不动任何东西", got == [] and probs == [], f"{got} {probs}")
        check("无日志时文件保持原样", target.read_bytes() == A, "被改了")

        # ② 正常一遍：begin → 改坏 → 写回 → commit。之后 recover 必须无事可做
        begin(root, target, A)
        target.write_bytes(B)
        target.write_bytes(A)
        commit(root)
        got, probs = recover(root)
        check("提交之后没有待恢复的事", got == [] and probs == [], f"{got} {probs}")
        check("提交之后文件保持当前内容", target.read_bytes() == A, "被改回去了")

        # ③ 模拟"写完日志就死"：begin → 改坏 → 不 commit → recover 写回原文
        begin(root, target, A)
        target.write_bytes(B)
        got, probs = recover(root)
        check("没提交的改动会被写回原文", got == ["src/a.ts"], f"{got} {probs}")
        check("recover 之后文件真的回到原文", target.read_bytes() == A, target.read_bytes()[:20].decode("utf-8", "replace"))
        got2, _ = recover(root)
        check("恢复一次之后再恢复不该重复写", got2 == [], f"{got2}")

        # ④ **真的强杀**：起一个子进程，它 begin 之后睡觉，主进程把它 kill 掉。
        #    ★ Windows 上 Popen.kill() 走的是 TerminateProcess —— 不可捕获，
        #      这正是线上真实发生的死法，也是内存里的 `_ACTIVE` 兜不住的那一种。
        target.write_bytes(A)
        code = (
            "import pathlib,sys,time;"
            f"sys.path.insert(0, {str(pathlib.Path(__file__).resolve().parent)!r});"
            "import mutation_journal as J;"
            f"root=pathlib.Path({str(root)!r});t=root/'src'/'a.ts';"
            "J.begin(root,t,t.read_bytes());"
            "t.write_bytes(b'const x = 2;\\r\\n');"
            "print('begun',flush=True);"
            "time.sleep(60)"
        )
        p = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            line = p.stdout.readline() if p.stdout else b""
            if line.strip() != b"begun":
                err = b""
                if p.stderr:
                    err = p.stderr.read()[:300]
                p.kill()
                p.wait()
                check("子进程能起来并写下日志", False, f"stdout={line!r} stderr={err!r}")
            else:
                p.kill()
                p.wait()
                check("强杀之后文件确实停在变异态（前提成立）", target.read_bytes() == B, target.read_bytes()[:20].decode("utf-8", "replace"))
                got, probs = recover(root)
                check("★ 被不可捕获的强杀之后仍能恢复原文", got == ["src/a.ts"] and probs == [], f"{got} {probs}")
                check("★ 强杀之后文件真的回到原文", target.read_bytes() == A, target.read_bytes()[:20].decode("utf-8", "replace"))
        finally:
            if p.poll() is None:
                p.kill()
                p.wait()

        # ⑤ 日志被截断（哈希对不上）⇒ 报问题，**不写半份**
        begin(root, target, A)
        (journal_dir(root) / "active.bin").write_bytes(b"const x = ")
        got, probs = recover(root)
        check("原文哈希对不上时报问题而不是写半份", got == [] and len(probs) == 1, f"{got} {probs}")
        check("哈希对不上时文件没被改成第三种东西", target.read_bytes() == A, "被写了半份")
        commit(root)

    if fails:
        print("✗ 变异日志的自检没过 —— 此时「被杀也能还原」这句话没有证据价值：")
        for f in fails:
            print(f"  · {f}")
        return 1
    print(
        "[journal] 变异日志自检 10 条通过（无日志 / 提交 / 未提交 / 强杀 / 哈希不符五种情形）",
        flush=True,
    )
    return 0


def _root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parent.parent


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    if "--recover" in argv:
        root = _root()
        restored, problems = recover(root)
        for r in restored:
            print(f"  ✔ 已写回原文：{r}")
        for p in problems:
            print(f"  · {p}")
        if problems:
            return 1
        print("没有待恢复的变异" if not restored else f"已恢复 {len(restored)} 个文件")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
