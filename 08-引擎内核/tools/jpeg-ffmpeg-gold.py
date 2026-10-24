#!/usr/bin/env python3
"""ffmpeg 外部金标 · 生成器 / 校验器

    python tools/jpeg-ffmpeg-gold.py            # 重新生成（会先自检"金标 vs 源"在容差内）
    python tools/jpeg-ffmpeg-gold.py --check    # 只校验：重算一遍，和仓库里的字节比，不一致就非 0

★ 这一组语料解决的是哪个缺口
------------------------------
12 位 DCT 此前**没有任何第三方参照**：Pillow 只编 8 位；libjpeg-turbo 要 BITS_IN_JSAMPLE=12
重新编译才有 12 位；`djpeg/cjpeg` 在 PATH 里找不到。于是 12 位只能靠"跨精度锚定"
（Pillow 的 8 位金标 → 12 位编码 → 解回 → 降回 8 位必须落回原像素）间接证明。
跨精度锚定能抓住"12 位独有"的错，但**12 位那一段编+解码全是我们自己的实现** ——
编码器与解码器对 12 位理解同错（典型：电平位移该加 2^11 却加了 128）时，回环依然绿。

ffmpeg 的 mjpeg 解码器是独立实现（不基于 libjpeg），并且认 12 位（SOF1 + P=12）。
它把我们的流解出来与源差 ≤2 级 —— 这就是外部参照。链条因此闭合：

    ① 编码器：ffmpeg 解我们的流 → 必须等于源（否则我们写进流的样本是错的）
    ② 解码器：我们解同一份流 → 必须等于 ffmpeg 的解（否则两边对规范的理解不同）
    ①+② 一起，任何"编解码同错"都会让 ① 或 ② 之一爆掉。

★ 为什么不比 4:2:0
-------------------
4:2:0 的色度上采样归 ffmpeg 的 swscale（不是它的 JPEG 解码器），
实测 12 位 4:2:0 两边差 177 级 —— 那个数字测的是"libjpeg 的 fancy 三角 vs swscale"，
与我们的解码器对不对无关。所以这一组语料一律 4:4:4，见 ADR-0009 ⑥-g。

★ 黄金值的口径（必须写清楚，否则"差 2 级"到底是哪儿来的说不明白）
----------------------------------------------------------------
- 灰度：`-pix_fmt gray`（8 位）/ `gray12le`（12 位）—— **原生位打包**，
  落盘的数值就是原生样本值，不经任何缩放。这条路上不存在"缩放口径"这件事。
- RGB：`-pix_fmt rgb48le` —— ffmpeg 把任何位深都展开到**满 16 位量程**
  （8 位是 v*257，12 位是 v*65535/4095），所以反算用 round(v*maxval/65535)。
  不这么做的话，12 位 RGB 会带着一层缩放误差混进"解码器差异"里。

★ 依赖：ffmpeg（`JPEG_FFMPEG` 环境变量指定，否则用 pip 的 imageio-ffmpeg 自带二进制）。
  判据本身**不依赖 ffmpeg** —— 它只读这里落盘的字节，所以 CI 不需要装 ffmpeg。
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
FIX_DIR = ROOT / "tests" / "fixtures" / "jpeg" / "ff"
CHECK = "--check" in sys.argv

# 阈值表（唯一真相）。生成时用它自检"金标 vs 源"，判据读 meta 里的值再断言。
# 灰度单通道，差只来自 IDCT 取整 → 紧；RGB 多一层 YCbCr↔RGB 取整（两家系数舍入不同）→ 松。
TOLERANCE = {
    "gray": 2,
    "rgb": 8,
}


def _node() -> str:
    for cand in (os.environ.get("NODE"), shutil.which("node")):
        if cand and Path(cand).exists():
            return cand
    raise SystemExit("找不到 node —— 设 NODE 环境变量指向 node 可执行文件")


def _ffmpeg() -> str:
    env = os.environ.get("JPEG_FFMPEG")
    if env and Path(env).exists():
        return env
    try:
        import imageio_ffmpeg  # type: ignore

        exe = imageio_ffmpeg.get_ffmpeg_exe()
        if exe and Path(exe).exists():
            return exe
    except Exception:
        pass
    raise SystemExit(
        "找不到 ffmpeg：设 JPEG_FFMPEG 环境变量，或 pip install imageio-ffmpeg。\n"
        "（判据不需要 ffmpeg；只有重新生成/校验这组金标时才需要）"
    )


def _ffmpeg_version(exe: str) -> str:
    out = subprocess.run([exe, "-hide_banner", "-version"], capture_output=True, text=True).stdout
    return out.splitlines()[0].strip() if out else "<unknown>"


def _emit(ff: str, out_dir: Path, src_dir: Path | None, meta_path: Path) -> list[dict]:
    cmd = [
        _node(),
        "--experimental-transform-types",
        str(ROOT / "tests" / "tools" / "jpeg-ff-gold-emit.ts"),
        "--out",
        str(out_dir),
        "--meta-out",
        str(meta_path),
    ]
    if src_dir is not None:
        cmd += ["--src-out", str(src_dir)]
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"编码器产流失败：\n{p.stdout[-2000:]}\n{p.stderr[-2000:]}")
    return json.loads(meta_path.read_text(encoding="utf-8"))


def _decode(exe: str, jpg: Path, pix_fmt: str, out: Path) -> None:
    cmd = [exe, "-hide_banner", "-nostdin", "-y", "-i", str(jpg), "-f", "rawvideo", "-pix_fmt", pix_fmt, str(out)]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0 or not out.exists():
        raise SystemExit(f"ffmpeg 解不开 {jpg.name}（pix_fmt={pix_fmt}）：\n{p.stderr[-1500:]}")


def _pix_fmt(components: int, precision: int) -> str:
    if components == 1:
        return "gray" if precision == 8 else "gray12le"
    return "rgb48le"


def _gold_native(raw: Path, components: int, precision: int) -> np.ndarray:
    """落盘字节 → 原生精度域的 u16 数组（交错，灰度 1 通道 / RGB 3 通道）。"""
    pix_fmt = _pix_fmt(components, precision)
    if pix_fmt == "gray":
        return np.fromfile(raw, dtype=np.uint8).astype(np.uint16)
    if pix_fmt == "gray12le":
        return np.fromfile(raw, dtype="<u2")
    # rgb48le：满量程 16 位 → 反算回原生
    maxval = (1 << precision) - 1
    v = np.fromfile(raw, dtype="<u2").astype(np.float64)
    return np.rint(v * maxval / 65535.0).astype(np.uint16)


def _build(ff: str, out_dir: Path, tmp_src: Path) -> list[dict]:
    cases_meta: list[dict] = []
    out_dir.mkdir(parents=True, exist_ok=True)
    declared = _emit(ff, out_dir, tmp_src, tmp_src / "_cases.json")
    by_name = {c["name"]: c for c in declared}
    emitted = sorted(p.stem for p in out_dir.glob("*.jpg"))
    missing = [n for n in by_name if n not in emitted]
    orphan = [n for n in emitted if n not in by_name]
    if missing or orphan:
        # ★ 与 make-jpeg-fixtures.py 的"生成了没人判 / 判了没人生成"校验同一条原则
        raise SystemExit(f"清单与产物不一致：缺 {missing}，多 {orphan}")

    for name in emitted:
        case = by_name[name]
        jpg = out_dir / f"{name}.jpg"
        src_file = tmp_src / f"{name}.src.u16"
        if not src_file.exists():
            raise SystemExit(f"生成器没写 {name}.src.u16 —— 无法自检")
        components = int(case["components"])
        precision = int(case["precision"])
        width = int(case["width"])
        height = int(case["height"])
        maxval = (1 << precision) - 1
        src = np.fromfile(src_file, dtype="<u2")
        assert src.size == width * height * components, (
            f"{name}: src 有 {src.size} 个样本，与 {width}x{height}x{components} 不符"
        )

        raw = tmp_src / f"{name}.raw"
        _decode(ff, jpg, _pix_fmt(components, precision), raw)
        gold = _gold_native(raw, components, precision)
        assert gold.size == src.size, f"{name}: ffmpeg 给了 {gold.size} 个样本，期望 {src.size}"

        (out_dir / f"{name}.ff.u16").write_bytes(gold.astype("<u2").tobytes())
        diff = np.abs(gold.astype(np.int64) - src.astype(np.int64))
        tol = TOLERANCE["gray" if components == 1 else "rgb"]
        maxdiff = int(diff.max())
        cases_meta.append(
            {
                "name": name,
                "width": width,
                "height": height,
                "components": components,
                "precision": precision,
                "precisionMax": maxval,
                "pixFmt": _pix_fmt(components, precision),
                "samples": int(src.size),
                "maxDiffGoldVsSource": maxdiff,
                "meanDiffGoldVsSource": round(float(diff.mean()), 4),
                "tolerance": tol,
            }
        )
        flag = "OK " if maxdiff <= tol else "!! "
        print(f"{flag}{name:20s} {_pix_fmt(components, precision):9s} gold-vs-src max={maxdiff:3d} tol={tol}")
        raw.unlink(missing_ok=True)

    bad = [c for c in cases_meta if c["maxDiffGoldVsSource"] > c["tolerance"]]
    if bad:
        raise SystemExit(
            "金标与源的差超出容差："
            + ", ".join(f"{c['name']}={c['maxDiffGoldVsSource']}>{c['tolerance']}" for c in bad)
            + "\n（这不是 ffmpeg 的问题就是编码器的问题 —— 生成器必须先自检过，语料才有意义）"
        )
    return cases_meta


def _case_tol(meta0: dict, name: str) -> int:
    """从 meta 里查这一例的容差（`gray12-odd.ff.u16` → cases 里的 `gray12-odd`）。"""
    key = name[: -len(".ff.u16")] if name.endswith(".ff.u16") else name
    for c in meta0.get("cases") or []:
        if c.get("name") == key:
            return int(c.get("tolerance") or 0)
    return 0


def _drift_spread(
    drift: list[str], committed_dir: Path, fresh_dir: Path, meta0: dict
) -> tuple[int | float, str, bool]:
    """逐样本比较漂移的 `.ff.u16`：返回（最大绝对差, 最差例名, 是否每例都在自己的容差内）。

    ★ 跨构建时不能只说一句"构建不同"就跳过 —— 那是新的假绿通道：
      真把编码器改坏了、恰好又在异构构建上跑，就同样被放过去了。
      所以把"差多少"量化出来，并且只在**差落在该例容差内**时才认作构建差异。
    """
    worst: int | float = 0
    worst_name = ""
    within = True
    for name in drift:
        if not name.endswith(".ff.u16"):
            continue
        a, b = committed_dir / name, fresh_dir / name
        if not (a.exists() and b.exists()):
            continue
        va = np.fromfile(a, dtype="<u2").astype(np.int64)
        vb = np.fromfile(b, dtype="<u2").astype(np.int64)
        if va.size != vb.size:
            # 样本数都不一样，绝不可能是取整差 —— 这是真的解错了
            return float("inf"), name, False
        if va.size == 0:
            continue
        d = int(np.max(np.abs(va - vb)))
        if d > worst:
            worst, worst_name = d, name
        if d > _case_tol(meta0, name):
            within = False
    return worst, worst_name, within


def main() -> int:
    ff = _ffmpeg()
    version = _ffmpeg_version(ff)
    print(f"ffmpeg: {version}")

    if CHECK:
        # ★ 校验**不覆盖仓库**：在临时目录里重算一遍，逐字节比。
        #   上一版是"就地重写再比"，漂移时虽然能报出来，但仓库已经被改掉了 ——
        #   一个"检查"动作不该有副作用，否则看到红字的人会分不清是自己改的还是它改的。
        committed = {p.name: p.read_bytes() for p in sorted(FIX_DIR.glob("*")) if p.is_file()}
        meta0 = json.loads(committed.get("_ffgold.json", b"{}").decode("utf-8") or "{}")
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "out"
            cases = _build(ff, out, Path(td))
            fresh = {p.name: p.read_bytes() for p in sorted(out.glob("*")) if p.is_file()}
            drift = sorted(
                name
                for name in set(committed) | set(fresh)
                if name != "_ffgold.json" and committed.get(name) != fresh.get(name)
            )
            if meta0.get("cases") != cases:
                drift.append("_ffgold.json")
            if not drift:
                print(f"✓ {len(cases)} 例金标与仓库一致（{len(committed)} 个文件）")
                return 0
            # ★ 先分"是不是同一个 ffmpeg 构建"，再判"是不是漂移"。
            #
            #   金标是**某个具体 ffmpeg 构建**的产物：生成它的是
            #   `7.1-essentials_build-www.gyan.dev`（Windows）。CI 上
            #   `pip install imageio-ffmpeg` 装的是 **Linux 构建** —— 同一份流、
            #   同一个 12 位灰度样本（`gray12-*`），两家逐字节不同，但**都与源差 ≤ 容差**
            #   （2026-10-25 实测：CI 上 5 例 gray12 漂移，gray8 / rgb48 全部逐字节一致，
            #    且 CI 侧面 gold-vs-src 自检全部 OK）。这不是"编码器变了"。
            #
            #   报成失败会训练人忽略红字（"又是那条"），报成通过更糟（假绿）。
            #   所以走三分退出码：2 = 环境不适用，**显式打印**，并量化"差多少"。
            #   注意判据本身不用 ffmpeg（读的是入库金标），这条只是
            #   「金标还能不能重算出来」的自检 —— 它的适用域本来就绑在生成环境上。
            same_build = (meta0.get("ffmpeg") or "") == version
            worst, worst_name, within = _drift_spread(drift, FIX_DIR, out, meta0)
            if not same_build and within:
                print("⊘ 跳过：ffmpeg 构建与生成金标时不同，逐字节比对没有判别力", file=sys.stderr)
                print(f"  金标生成时：{meta0.get('ffmpeg')}", file=sys.stderr)
                print(f"  当前：      {version}", file=sys.stderr)
                print(f"  不一致的语料：{', '.join(drift)}", file=sys.stderr)
                spread = (
                    f"{worst} 级（{worst_name}）" if worst_name else "无（差异只在元数据里）"
                )
                print(
                    f"  逐样本最大差：{spread} —— 落在该例容差内，判为构建差异而非编码器漂移",
                    file=sys.stderr,
                )
                return 2
            if not same_build:
                print(
                    f"✗ 构建不同，但逐样本最大差 {worst} 级（{worst_name}）**超出容差** —— "
                    "这不是取整差，按真漂移处理",
                    file=sys.stderr,
                )
                print(f"  不一致的语料：{', '.join(drift)}", file=sys.stderr)
                return 1
            print("✗ 语料漂移：" + ", ".join(drift), file=sys.stderr)
            print(
                f"  同一 ffmpeg 构建下仍不一致（最大差 {worst} 级 / {worst_name}）—— "
                "重跑一次并提交，别让判据对着过期的金标断言。",
                file=sys.stderr,
            )
            return 1

    with tempfile.TemporaryDirectory() as td:
        cases = _build(ff, FIX_DIR, Path(td))
    meta = {
        "generator": "tools/jpeg-ffmpeg-gold.py",
        "ffmpeg": version,
        "note": "gold = ffmpeg 解码本仓库编码器产出的流，落在**原生精度域**（灰度原生打包，RGB 从满 16 位反算）",
        "cases": cases,
    }
    (FIX_DIR / "_ffgold.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    total = sum(p.stat().st_size for p in FIX_DIR.glob("*"))
    print(f"✓ 写出 {len(cases)} 例，目录 {total / 1024:.1f} KiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
