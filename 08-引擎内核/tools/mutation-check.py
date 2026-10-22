#!/usr/bin/env python3
"""变异验证：注入 3 个变异，确认对应判据会红，然后精确还原。

不是"跑一遍测试绿了就算"——绿可以是假的（判据写空、断言恒真）。
这里对每条**关键性质**改坏实现，看它是否真的被抓到：
  M1 脚本异常隔离被破坏（throw 替代 report ⇒ 同帧后续脚本不再执行）
  M2 节点 id 分配退回全局（两个世界共享 id 空间 ⇒ 存档不可比）
  M3 资产增量忽略 sourceHash（改源不重导 ⇒ 幂等判据其实没守东西）
"""
import subprocess
import sys
import pathlib

ROOT = pathlib.Path(r"E:/game_make/25d/DST-Analysis/08-引擎内核")

MUTANTS = [
    {
        "name": "M1 脚本异常隔离",
        "file": "src/extensions/script/script-module.ts",
        "pairs": [(
            "        if (!r.ok) {\n"
            "          // ★ 异常隔离：一个脚本挂不能让同帧其他脚本不执行，更不能让整帧崩\n"
            "          report(c, entry, r.error);\n"
            "        }",
            # ★ 第一版变异写成 `throw` —— 被同一个 for 里的 catch 接住，行为几乎不变
            #   （等价变异，抓不住不是判据的问题）。真正的破坏方式是**中断整帧**。
            "        if (!r.ok) {\n"
            "          report(c, entry, r.error);\n"
            "          return;\n"
            "        }",
        )],
        "test": "tests/core/script-module.test.ts",
    },
    {
        "name": "M2 节点 id 全局分配",
        "file": "src/core/scene/scene.ts",
        "pairs": [
            ("  private nextId = 2;", "  private static nextId = 2;"),
            ("      if (explicit >= this.nextId) this.nextId = explicit + 1;",
             "      if (explicit >= Scene.nextId) Scene.nextId = explicit + 1;"),
            ("    return this.nextId++;", "    return Scene.nextId++;"),
        ],
        "test": "tests/core/script-e2e.test.ts",
    },
    {
        "name": "M3 增量忽略 sourceHash",
        "file": "src/extensions/asset-import/pipeline.ts",
        "pairs": [(
            "        cached.sourceHash === sourceHash &&\n",
            "        true &&\n",
        )],
        "test": "tests/extensions/asset-import.test.ts",
    },
]


def run(test_file: str) -> tuple[int, str]:
    p = subprocess.run(
        ["node", "--experimental-transform-types", "--test", test_file],
        cwd=ROOT, capture_output=True, text=True, timeout=600,
    )
    out = p.stdout + p.stderr
    fails = [ln for ln in out.splitlines() if ln.startswith("not ok")]
    return len(fails), "\n".join(fails[:6])


results = []
for m in MUTANTS:
    f = ROOT / m["file"]
    original = f.read_text(encoding="utf-8")
    mutated = original
    ok_apply = True
    for old, new in m["pairs"]:
        if old not in mutated:
            ok_apply = False
            break
        mutated = mutated.replace(old, new, 1)
    if not ok_apply:
        results.append((m["name"], "变异点没找到（判据可能已过期）", 0, []))
        continue

    f.write_text(mutated, encoding="utf-8")
    try:
        n_fail, detail = run(m["test"])
    finally:
        f.write_text(original, encoding="utf-8")

    # 还原后必须重新变绿，否则说明的还原不干净
    n_fail_after, _ = run(m["test"])
    results.append((m["name"], detail, n_fail, [n_fail_after]))

print("=" * 70)
all_ok = True
for name, detail, n_fail, after in results:
    verdict = "√ 变异被抓住" if n_fail > 0 else "× 变异没被抓住（判据是假绿）"
    if n_fail == 0 or (after and after[0] != 0):
        all_ok = False
    print(f"{name}: {verdict}  变异后失败 {n_fail} 条；还原后失败 {after[0] if after else '?'} 条")
    if detail:
        print("   " + detail.replace("\n", "\n   "))
print("=" * 70)
print("全部变异均被抓住且还原干净" if all_ok else "有变异未被抓住或还原不干净")
sys.exit(0 if all_ok else 1)
