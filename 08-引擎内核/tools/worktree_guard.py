#!/usr/bin/env python3
"""工作区守护：证明「变异跑完没在仓库里留下脏文件」。

★★ 为什么要有这个文件（2026-10-26 批89 实测）：

   变异器原有的两套「还原后校验」各自只看**自己这一条**变异的文件 ——
   `cmd` 型验"这个源文件的字节 + 三个产物哈希"，`node:test` 型"重跑这一条判据"。
   它们看不见 **别的文件被留在了变异态**。

   那天全量跑完 407 条，工具通篇报「全部变异均被抓住且还原干净」，但
   `src/extensions/asset-import/decode/jpeg/lossless-pred.ts` 被留成了变异体
   （`1 << (precision - pt - 1)` → `1 << (precision - 1)`）。
   后果不是"红一下"：`tools/ci.mjs` 的判据步排在变异步**之前**，所以当次全绿，
   红要等到**下一次**有人跑判据才爆 —— 而那时红的是两条 JPEG 判据，
   跟眼前正在改的东西毫无关系。我照着那条红查了一个不存在的 bug。
   更糟的路径是它被 `git add -A` 一并提交：diff 长成"把真缺陷改回去"，
   而提交信息写着别的事。

★★ 口径：只比**内容**，不比 mtime。
   变异还原是字节级写回，所以"仓库脏不脏"是可以直接看的事实 ——
   但写回本身会让 mtime 变，拿 mtime 当判据会让**每一条**变异都假报脏。

★★ 范围：`git ls-files -- .`（本文件所在目录＝引擎目录内的 tracked 文件）。
     · **不含未跟踪文件** —— 变异器不创建新文件，要抓的正是"改了别人"这一类；
       反过来把未跟踪文件也纳入，会让"某人在仓库里放了个草稿"变成每轮必红的噪声，
       而那种红与变异无关（"红得没依据"会训练人忽略红字，这正是本项目反复吃过的亏）。
       **已知边界**：本文件自己首次提交前是未跟踪的，那段时间它不在自己的守护范围内。
     · **不含产物** —— 三个产物另有哈希校验，而且基线构建会重写它们，
       取在这里会把构建噪声当成脏。

★★ 为什么是独立文件而不是塞在 `tools/mutation-check.py` 里：
   变异靶子是**写在变异表里的字符串字面量**，而 `replace(old, new, 1)` 替换的是
   文件中**第一次**出现。实现与靶子同处一个文件时，第一次出现就是靶子自己 ——
   变异会把自己的靶子改掉，实现纹丝不动，于是"变异没被抓住"，
   而自检**照样通过**（因为逻辑真的没变）。第一次写 M408 就这么假绿了一轮。
   抽出来之后，靶子在 `mutation-check.py`、实现在这里，两边不可能撞上。

用法：
  python tools/worktree_guard.py --selftest   # 自检（造四种情形自证，1 秒内）
  python tools/worktree_guard.py --check <基线.json>  # 手工比对（调试用）
"""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile


def tracked_hashes(root: pathlib.Path) -> dict[str, str]:
    """`root` 下所有 tracked 文件的内容哈希（路径相对 root）。git 不可用时返回空。"""
    cp = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", "."],
        capture_output=True,
        check=False,
    )
    if cp.returncode != 0:
        return {}
    out: dict[str, str] = {}
    for name in cp.stdout.decode("utf-8", "replace").split("\0"):
        if not name:
            continue
        try:
            out[name] = hashlib.sha256((root / name).read_bytes()).hexdigest()
        except OSError:
            # ★ 读不到就**不进快照**（于是差异里表现为「没了」）。用占位符的话，
            #   删除与权限问题都会变成「变了」，而处置动作其实一样：去看那个文件。
            continue
    return out


def hash_diff(before: dict[str, str], after: dict[str, str]) -> list[str]:
    """两份快照的差异：变了 / 多了 / 没了。空列表 = 干净。"""
    out: list[str] = []
    for name in sorted(after):
        if name not in before:
            out.append(f"多了：{name}")
        elif before[name] != after[name]:
            out.append(f"变了：{name}")
    for name in sorted(before):
        if name not in after:
            out.append(f"没了：{name}")
    return out


def selftest() -> int:
    """在真 git 仓库里造四种情形自证。

    ★ 守护坏掉的样子**和"一切都干净"完全一样**（快照恒等、差异恒空、
      报告照旧说"还原干净"），所以它自己的判据只能靠**造已知脏**来分辨。
    """
    with tempfile.TemporaryDirectory() as td:
        tdp = pathlib.Path(td)
        sub = tdp / "sub"
        sub.mkdir()
        (tdp / "a.txt").write_text("A", encoding="utf-8")
        (sub / "b.txt").write_text("B", encoding="utf-8")
        for cmd in (
            ["init", "-q"],
            ["add", "-A"],
            ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "x"],
        ):
            cp = subprocess.run(["git", "-C", td, *cmd], capture_output=True, check=False)
            if cp.returncode != 0:
                print(f"✗ 自检环境建不起来（git {' '.join(cmd)}）：{cp.stderr.decode()[:200]}")
                return 2

        fails: list[str] = []

        def check(name: str, cond: bool, detail: str) -> None:
            if not cond:
                fails.append(f"{name}（{detail}）")

        s0 = tracked_hashes(tdp)
        check("快照能读到 tracked 文件", len(s0) == 2, f"读到 {len(s0)} 个：{sorted(s0)}")
        check("同一状态两次快照没有差异", hash_diff(s0, tracked_hashes(tdp)) == [], "差异不为空")

        (tdp / "a.txt").write_text("A改", encoding="utf-8")
        d1 = hash_diff(s0, tracked_hashes(tdp))
        check("改了内容必须报出来", d1 == ["变了：a.txt"], f"实际 {d1}")

        # ★ 这条钉的是「只比内容、不比 mtime」：写回原内容后 mtime 变了，
        #   但文件字节回到原位 ⇒ 不该报。否则每条变异都会假报（写回必然改 mtime）。
        (tdp / "a.txt").write_text("A", encoding="utf-8")
        d2 = hash_diff(s0, tracked_hashes(tdp))
        check("内容回到原样就不算脏（只看内容，不看 mtime）", d2 == [], f"实际 {d2}")

        (sub / "b.txt").unlink()
        d3 = hash_diff(s0, tracked_hashes(tdp))
        check("删掉被跟踪的文件必须报出来", d3 == ["没了：sub/b.txt"], f"实际 {d3}")

        # ★ 未跟踪文件不在守护范围：写一个新文件进去，除了已知的"没了"之外不该多出别的。
        (tdp / "c.txt").write_text("C", encoding="utf-8")
        d4 = hash_diff(s0, tracked_hashes(tdp))
        check("未跟踪文件不在守护范围（变异器不建文件）", d4 == ["没了：sub/b.txt"], f"实际 {d4}")

    if fails:
        print("✗ 工作区守护的自检没过 —— 此时「还原干净」这句话没有证据价值：")
        for f in fails:
            print(f"  · {f}")
        return 1
    print("[guard] 工作区守护自检 6 条通过（改动/还原/删除/未跟踪四种情形）", flush=True)
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    if "--check" in argv:
        i = argv.index("--check")
        if i + 1 >= len(argv):
            print("用法：python tools/worktree_guard.py --check <基线.json>")
            return 2
        root = pathlib.Path(__file__).resolve().parent.parent
        before = json.loads(pathlib.Path(argv[i + 1]).read_text(encoding="utf-8"))
        diff = hash_diff(before, tracked_hashes(root))
        for line in diff:
            print(f"  · {line}")
        print("干净" if not diff else f"有 {len(diff)} 处残留")
        return 0 if not diff else 1
    if "--snapshot" in argv:
        i = argv.index("--snapshot")
        root = pathlib.Path(__file__).resolve().parent.parent
        data = json.dumps(tracked_hashes(root), ensure_ascii=False, indent=0)
        if i + 1 < len(argv):
            pathlib.Path(argv[i + 1]).write_text(data, encoding="utf-8")
        else:
            print(data)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
