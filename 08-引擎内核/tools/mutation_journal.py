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

     · `active.json` 是**阶段标记**，最后写。它不存在 ⇒ 没有待恢复的事，
       哪怕有个孤零零的 `active.bin`（写到一半被杀）也不管 —— 那份 `.bin`
       对应的改动还没发生，世界是干净的。
     · `commit()` 把标记改写成 `restored`，**不删文件**（下一段解释为什么）。
     · `recover()` 先比对 `active.json` 里的 sha256 与 `.bin` 的实际哈希，
       对不上就**报问题而不是写半份**：写半份会把一个文件变成既不是原文
       也不是变异体的第三种东西，比不还原更坏。

★★ 为什么扫尾是「改标记」而不是「删文件」（2026-10-27 实测，第三次事故）：

   第一版扫尾用 `unlink()` 删掉两个文件 —— 反正它们只在这一条变异期间有用。
   而变异是**每条一次**：整轮 459 条 ⇒ 900 多次删除。环境里有一层
   「每轮删除次数上限 50」的防抖守卫，第 51 次删除被拒之后**整轮直接中止**：

     · 实测 1 分 25 秒就退出，`exit=1`，日志只剩三行；stdout 是块缓冲，
       被打断时连 25 条「√ 变异被抓住」一起丢了 —— 现场看起来像"刚启动就没了"；
     · 最坏的不是中断，而是它**看起来像跑完了**：`git status` 干净、
       有个 `active.bin` 但按口径「没有标记 = 没有待恢复的事」，
       于是"整轮全被抓住"这个结论**根本不可得，而没人会去查**。

   修法不是"少删几个"（那只是把上限往后推），而是**扫尾根本不需要删除**：
   把状态写成 `restored` 就够了，下一轮 `begin()` 会覆盖同一对文件。
   删除次数 900+ → 0。

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

# ★ 两个文件**永不删除**（见文件头「为什么扫尾是改标记而不是删文件」）。
#   文件名固定 ⇒ 每次扫尾只是覆盖写入，不产生 unlink。
_BIN = "active.bin"
_MARK = "active.json"
_PHASE_APPLYING = "applying"
_PHASE_RESTORED = "restored"


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
    # ② 阶段标记最后写：它出现就意味着"这份原文是完整的、对应的改动即将/已经发生"。
    #    顺序不能反：先标记后原文的话，崩在中间会拿着"这份原文已就绪"的标记
    #    去配一份还没写完的 .bin（哈希对不上 → 报问题，白丢一次可恢复机会）。
    meta = {
        "phase": _PHASE_APPLYING,
        "path": rel,
        "bytes": len(original),
        "sha256": hashlib.sha256(original).hexdigest(),
        "at": datetime.now().isoformat(timespec="seconds"),
        "pid": os.getpid(),
    }
    _fsync_write(d / _MARK, json.dumps(meta, ensure_ascii=False).encode("utf-8"))


def commit(root: pathlib.Path) -> None:
    """扫尾：原文已经写回去了，把标记改成 `restored`。**不删任何文件**。

    ★ 为什么不 unlink：理由是**跑不完**，不是洁癖 —— 每轮 459 条各扫尾一次，
      就是 900 多次删除，而环境里有「每轮删除上限 50」的守卫，第 51 次起被拒，
      整轮当场中止且看起来像正常结束（详见文件头第三次事故）。
    ★ 为什么先改标记就够：`recover()` 只看标记的阶段。`restored` ⇒ 无事可做，
      原文 `.bin` 留着不占事 —— 下一轮 `begin()` 会把它整份覆盖掉。
    """
    d = journal_dir(root)
    # ★ 这里的变量名与 `begin()` 里那个**故意不同**（`done` vs `meta`）：变异表按
    #   「整行文本首次出现」定位靶子，两处写成同一行的话，M449 会去打 `begin()`
    #   那一句 —— 变异名说"还原完不改标记"，实际改的却是"根本没写标记"。
    done = {"phase": _PHASE_RESTORED, "at": datetime.now().isoformat(timespec="seconds"), "pid": os.getpid()}
    _fsync_write(d / _MARK, json.dumps(done, ensure_ascii=False).encode("utf-8"))


def recover(root: pathlib.Path) -> tuple[list[str], list[str]]:
    """把上一次没提交的原文写回去。

    返回 `(已恢复的相对路径, 问题描述)`。空 + 空 = 上次是干净结束的。
    """
    d = journal_dir(root)
    mark = d / "active.json"
    if not mark.exists():
        # 没有标记 ⇒ 没有待恢复的事。孤儿 .bin（写到一半被杀）**不动它**：
        # 下一轮 begin() 会覆盖，而"顺手删掉"正是上一版撞上删除守卫的地方。
        return [], []
    try:
        meta = json.loads(mark.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        return [], [f"日志读不了（{mark}）：{e} —— 不知道该恢复哪个文件，请手工核对 git status"]

    if str(meta.get("phase", "")) == _PHASE_RESTORED:
        # 上一次是正常扫尾的：文件已经写回去了，标记只是留着看
        return [], []

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

        # ⑥ 扫尾**不删文件**（这是死因，不是洁癖）：整轮 459 条各扫尾一次 =
        #    900 多次删除，撞上"每轮删除上限 50"的守卫整轮会静默中止。
        #    ★ 判据要看**两件事**：文件还在 ∧ 标记写着 restored。
        #      只看"文件还在"会被"什么也没做"骗过（那样标记停在 applying，
        #      下一轮启动会拿它去恢复一遍 —— 正是 ② 要防的那种误恢复）。
        begin(root, target, A)
        target.write_bytes(B)
        target.write_bytes(A)
        commit(root)
        jd = journal_dir(root)
        check(
            "扫尾之后两个日志文件都还在（扫尾不靠删除）",
            (jd / "active.bin").exists() and (jd / "active.json").exists(),
            f"bin={(jd / 'active.bin').exists()} mark={(jd / 'active.json').exists()}",
        )
        check(
            "扫尾之后标记写着 restored（下一轮不会再恢复一遍）",
            str(json.loads((jd / "active.json").read_text(encoding="utf-8")).get("phase", "")) == _PHASE_RESTORED,
            (jd / "active.json").read_text(encoding="utf-8"),
        )

    if fails:
        print("✗ 变异日志的自检没过 —— 此时「被杀也能还原」这句话没有证据价值：")
        for f in fails:
            print(f"  · {f}")
        return 1
    print(
        "[journal] 变异日志自检 14 条通过（无日志 / 提交 / 未提交 / 强杀 / 哈希不符 / 扫尾不删文件）",
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
