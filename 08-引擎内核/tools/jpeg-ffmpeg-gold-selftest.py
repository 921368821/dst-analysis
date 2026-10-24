"""`jpeg-ffmpeg-gold.py --check` 的三分退出码自检。

★★ 为什么需要它
----------------
`--check` 会逐字节比"金标能否重算出来"。金标是**某个具体 ffmpeg 构建**的产物
（本机是 `7.1-essentials_build-www.gyan.dev`；CI 上是
`7.0.2-static johnvansickle`，对 12 位灰度解出的字节不同但**与源差 ≤ 容差**）。

判成"失败"会训练人忽略红字（"又是那条"），判成"通过"更糟（假绿通道）。
所以按三分退出码：0 一致 / 1 真漂移 / 2 环境不适用。
**这个自检守的就是那条分界线本身** —— 没有它，"构建不同"会变成万能免罪符。

★★ 基线必须**现场用当前构建重新生成**，不能拿仓库里那份
------------------------------------------------------
第一版拿仓库 fixture 当基线，结果在 CI 上情形 D 期望 0、实际 1：
仓库那份是 Windows 构建的产物，Linux 上重算天然就"不一致"。
**自检自己在异构机器上红，比没有自检更糟**（会训练人忽略它）。
所以先跑一次生成模式拿到当前构建的基线，再在这份基线上做四种情形。

  D  同构建 + 无漂移              → 0   （正常绿）
  C  同构建 + 漂移 1 级            → 1   （同构建下的差异只可能是真漂移）
  A  跨构建 + 漂移 1 级（容差内）   → 2   （环境不适用，不是通过）
  B  跨构建 + 漂移 500 级          → 1   （超容差，不许当构建差异放过）

仓库文件全程不动：基线生成在临时目录，四个情形各自从基线复制一份。
"""

import importlib.util
import json
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "tools" / "jpeg-ffmpeg-gold.py"
OTHER_BUILD = "ffmpeg version 7.1-static-linux64 (c) the FFmpeg developers"


def load(check: bool):
    """装载目标脚本。`CHECK` 是模块级常量、由 sys.argv 决定，所以每次都要重设 argv。"""
    sys.argv = [a for a in sys.argv if a != "--check"]
    if check:
        sys.argv.append("--check")
    spec = importlib.util.spec_from_file_location("goldmod", SRC)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def make_baseline(dst: Path) -> str:
    """用**当前**构建生成一份金标当基线，返回当前 ffmpeg 版本行。"""
    m = load(False)
    if "--check" in sys.argv:
        raise SystemExit("内部错误：生成基线时 --check 没被摘掉")
    dst.mkdir(parents=True, exist_ok=True)
    m.FIX_DIR = dst
    code = m.main()
    if code != 0:
        raise SystemExit(f"生成基线失败（退出码 {code}）")
    meta = json.loads((dst / "_ffgold.json").read_text(encoding="utf8"))
    return str(meta.get("ffmpeg") or "")


def trial(tag: str, baseline: Path, same_build: bool, shift) -> int:
    m = load(True)
    tmp = Path(tempfile.mkdtemp())
    try:
        fx = tmp / "ff"
        shutil.copytree(baseline, fx)
        if not same_build:
            meta = json.loads((fx / "_ffgold.json").read_text(encoding="utf8"))
            meta["ffmpeg"] = OTHER_BUILD
            (fx / "_ffgold.json").write_text(
                json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf8"
            )
        if shift:
            name, delta = shift
            f = fx / name
            a = np.fromfile(f, dtype="<u2").astype(np.int64)
            np.clip(a + delta, 0, 65535).astype("<u2").tofile(f)
        m.FIX_DIR = fx
        code = m.main()
        # 版本行只在开头打印一次：每个情形重复打，长版本行会把四种情形的对照淹没
        print(f"  >>> {tag}：退出码 {code}")
        return code
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    base = Path(tempfile.mkdtemp())
    try:
        current = make_baseline(base / "ff")
        print(f"基线：{len(list((base / 'ff').glob('*')))} 个文件，来自 `{current}`")
        got = {
            "D": trial("D 同构建/无漂移", base / "ff", True, None),
            "C": trial("C 同构建/漂移 1 级", base / "ff", True, ("gray12-baseline.ff.u16", 1)),
            "A": trial("A 跨构建/漂移 1 级（容差内）", base / "ff", False, ("gray12-baseline.ff.u16", 1)),
            "B": trial("B 跨构建/漂移 500 级（超容差）", base / "ff", False, ("gray12-baseline.ff.u16", 500)),
        }
    finally:
        shutil.rmtree(base, ignore_errors=True)
    want = {"D": 0, "C": 1, "A": 2, "B": 1}
    bad = {k: f"期望 {want[k]} 实际 {got[k]}" for k in want if want[k] != got[k]}
    if bad:
        print(f"✗ 三分退出码不符预期：{bad}", file=sys.stderr)
        return 1
    print("✓ 四种情形符合预期：0 绿 / 1 真漂移 / 2 环境不适用（超容差不被放过）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
