"""`jpeg-ffmpeg-gold.py --check` 的三分退出码自检。

★★ 为什么需要它
----------------
`--check` 会逐字节比"金标能否重算出来"。金标是**某个具体 ffmpeg 构建**的产物
（Windows 上是 `7.1-essentials_build-www.gyan.dev`）。CI 的 Linux 构建对 12 位灰度
（`gray12-*`）解出的字节与之不同 —— 但**两者与源都差 ≤ 容差**，语义一致。

判成"失败"会训练人忽略红字（"又是那条"），判成"通过"更糟（假绿通道）。
所以按三分退出码：0 一致 / 1 真漂移 / 2 环境不适用。
**这个自检守的就是那条分界线本身** —— 没有它，"构建不同"会变成一句万能免罪符。

模拟手法：把 fixture 复制到临时目录，显式设置 meta 里的版本行当"金标来自哪个构建"，
再给某个 `.ff.u16` 整体加偏移当"异构构建的取整差/真差错"。仓库文件全程不动。

  D  同构建 + 无漂移              → 0   （正常绿）
  C  同构建 + 漂移 1 级            → 1   （同构建下的差异只可能是真漂移）
  A  跨构建 + 漂移 1 级（容差内）   → 2   （环境不适用，不是通过）
  B  跨构建 + 漂移 500 级          → 1   （超容差，不许当构建差异放过）

★ 版本行必须**显式设定**成"当前 ffmpeg"或"别的构建"，不能沿用仓库里那份：
  仓库那份记的是 Windows 构建，在 Linux 的 CI 上会被判成跨构建，情形 C 就会
  期望 1 而实际 2 —— 自检自己在异构机器上红，等于没有自检。
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
FIX = ROOT / "tests" / "fixtures" / "jpeg" / "ff"
OTHER_BUILD = "ffmpeg version 7.1-static-linux64 (c) the FFmpeg developers"


def load_check():
    """以 `--check` 模式装载目标脚本（模块级 `CHECK` 由 sys.argv 决定）。"""
    if "--check" not in sys.argv:
        sys.argv.append("--check")
    spec = importlib.util.spec_from_file_location("goldmod", SRC)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def trial(tag: str, same_build: bool, shift: tuple[str, int] | None) -> int:
    m = load_check()
    current = m._ffmpeg_version(m._ffmpeg())
    tmp = Path(tempfile.mkdtemp())
    try:
        fx = tmp / "ff"
        fx.mkdir()
        for p in FIX.glob("*"):
            if p.is_file():
                shutil.copy2(p, fx / p.name)
        meta = json.loads((fx / "_ffgold.json").read_text(encoding="utf8"))
        meta["ffmpeg"] = current if same_build else OTHER_BUILD
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
        print(f"  >>> {tag}：退出码 {code}")
        return code
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    got = {
        "D": trial("D 同构建/无漂移", True, None),
        "C": trial("C 同构建/漂移 1 级", True, ("gray12-baseline.ff.u16", 1)),
        "A": trial("A 跨构建/漂移 1 级（容差内）", False, ("gray12-baseline.ff.u16", 1)),
        "B": trial("B 跨构建/漂移 500 级（超容差）", False, ("gray12-baseline.ff.u16", 500)),
    }
    want = {"D": 0, "C": 1, "A": 2, "B": 1}
    bad = {k: f"期望 {want[k]} 实际 {got[k]}" for k in want if want[k] != got[k]}
    if bad:
        print(f"✗ 三分退出码不符预期：{bad}", file=sys.stderr)
        return 1
    print("✓ 四种情形符合预期：0 绿 / 1 真漂移 / 2 环境不适用（超容差不被放过）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
