#!/usr/bin/env python3
"""拒绝路径审计：解码器里的每一条 `fail(...)` 在测试里**是否真的被触发过**。

★ 为什么需要这个工具：
  解码器有 90+ 条拒绝理由（"这个文件结构不对，别解"）。判据里逐条断言它们很难看全 ——
  而"某条拒绝理由从没被触发过"意味着：那条检查要么永远不生效（写了等于没写），
  要么只在真实坏文件上才生效（而我们没有任何语料证明它是对的）。

★ 做法（比逐条变异便宜得多，也不改变判据语义）：
  临时给 `fail()` 插一段埋点：调用时把信息写进全局 Set，进程退出时落盘，
  然后**原样**跑一遍全量判据。跑完把源码改回去，读埋点文件。
  插点不改控制流（仍然是 throw），所以判据的结果与平时完全一致。

用法：
  python tools/audit-error-paths.py            # 跑全量，打印未触发的拒绝理由
  python tools/audit-error-paths.py --verbose  # 连已触发的也列出来
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TYPES = ROOT / "src" / "extensions" / "asset-import" / "decode" / "jpeg" / "types.ts"
SRC_DIR = TYPES.parent

MARK_BEGIN = "// >>> audit-error-paths 埋点（临时插入，跑完会删掉）"
MARK_END = "// <<< audit-error-paths 埋点"

FAIL_RE = re.compile(r'fail\(\s*"([A-Z_.]+)"\s*,\s*(`[^`]*`|"[^"]*")')


def collect_sites() -> list[tuple[str, str, str]]:
    """(文件, 错误码, 消息模板) —— 只用于报告，不参与运行。"""
    out: list[tuple[str, str, str]] = []
    for f in sorted(SRC_DIR.glob("*.ts")):
        text = f.read_text(encoding="utf-8")
        for m in FAIL_RE.finditer(text):
            out.append((f.name, m.group(1), m.group(2).strip('`"')))
    return out


def patch() -> str:
    original = TYPES.read_text(encoding="utf-8")
    if MARK_BEGIN in original:
        raise SystemExit("types.ts 里已经有埋点，先手工恢复")
    # 落盘方式：进程退出时把集合打到 stderr，前缀 AUDIT_PAYLOAD:
    # 用 stderr 而不是写文件，是因为这段埋点跑在 ESM 里（没有 require），
    # 而为了埋点往源码里加 import 会扩大改动面。stderr 也会被 subprocess 捕获。
    instrument = f"""{MARK_BEGIN}
const __audit = ((globalThis as any).__jpegFailSet ??= new Set<string>());
if (!(globalThis as any).__jpegFailFlush) {{
  (globalThis as any).__jpegFailFlush = true;
  process.on("exit", () => {{
    process.stderr.write("AUDIT_PAYLOAD:" + JSON.stringify([...__audit]) + "\\n");
  }});
}}
{MARK_END}
"""
    # 埋点插在 fail() 定义之前，并在 fail 里记录
    patched = original.replace(
        "export function fail(code: string, message: string, detail?: Record<string, unknown>): never {\n  throw new JpegFailure(code, message, detail);\n}",
        instrument
        + "export function fail(code: string, message: string, detail?: Record<string, unknown>): never {\n"
        + "  (globalThis as any).__jpegFailSet.add(code + ' | ' + message);\n"
        + "  throw new JpegFailure(code, message, detail);\n"
        + "}",
        1,
    )
    if patched == original:
        raise SystemExit("没找到 types.ts 里 fail() 的定义，埋点位置要更新")
    TYPES.write_text(patched, encoding="utf-8")
    return original


def main() -> int:
    verbose = "--verbose" in sys.argv
    sites = collect_sites()
    original = patch()
    try:
        proc = subprocess.run(
            ["node", "--experimental-transform-types", "--test", "tests/run.ts"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    finally:
        TYPES.write_text(original, encoding="utf-8")

    combined = proc.stdout + proc.stderr
    fails = [ln for ln in combined.splitlines() if ln.startswith("not ok")]
    passes = [ln for ln in combined.splitlines() if ln.startswith("# pass")]

    hit_raw = []
    # 测试跑在子进程里，runner 会给子进程的 stderr 加前缀/缩进，
    # 所以不能只认行首（第一次就是这么漏掉的：埋点明明生效，汇总却是 0 条）。
    for line in combined.splitlines():
        at = line.find("AUDIT_PAYLOAD:")
        if at < 0:
            continue
        try:
            hit_raw.extend(json.loads(line[at + len("AUDIT_PAYLOAD:"):]))
        except json.JSONDecodeError:
            continue

    # 埋点记的是运行期**实际生成**的消息（模板已展开），这里按前缀把它们对回源码里的模板
    hit_keys = set()
    for h in hit_raw:
        code, _, msg = h.partition(" | ")
        hit_keys.add((code, msg))

    def matched(fname: str, code: str, tmpl: str) -> str | None:
        """返回命中的运行期消息，未命中返回 None。"""
        prefix = re.split(r"\$\{", tmpl)[0]
        for hcode, hmsg in hit_keys:
            if hcode != code:
                continue
            if hmsg.startswith(prefix.strip()) or prefix.strip() in hmsg:
                return hmsg
        return None

    missing: list[tuple[str, str, str]] = []
    covered: list[tuple[str, str, str, str]] = []
    for fname, code, tmpl in sites:
        m = matched(fname, code, tmpl)
        if m is None:
            missing.append((fname, code, tmpl))
        else:
            covered.append((fname, code, tmpl, m))

    print("=" * 74)
    print(f"判据结果：{passes[0] if passes else '?'}；失败 {len(fails)} 条")
    print(f"拒绝理由（fail 调用点）：{len(sites)} 条，测试期间实际触发 {len(covered)} 条")
    print(f"未触发：{len(missing)} 条")
    if verbose:
        print("\n已触发：")
        for fname, code, tmpl, m in covered:
            print(f"  {fname:18s} {code}  {tmpl[:64]}")
    print("\n未触发（要么永远不生效，要么只在没有语料的坏文件上生效）：")
    for fname, code, tmpl in missing:
        print(f"  {fname:18s} {code}  {tmpl[:72]}")
    print("=" * 74)
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
