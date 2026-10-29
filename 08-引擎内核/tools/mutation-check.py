#!/usr/bin/env python3
"""变异验证：逐个注入变异，确认对应判据会红，然后精确还原。

不是"跑一遍测试绿了就算"——绿可以是假的（判据写空、断言恒真）。
这里对每条**关键性质**改坏实现，看它是否真的被抓到：
  M1 脚本异常隔离被破坏（throw 替代 report ⇒ 同帧后续脚本不再执行）
  M2 节点 id 分配退回全局（两个世界共享 id 空间 ⇒ 存档不可比）
  M3 资产增量忽略 sourceHash（改源不重导 ⇒ 幂等判据其实没守东西）

★★ 「还原后」这一段的验证口径（2026-10-25 批75 改，改之前误报过三次）：
   还原是**字节级写回**（`f.write_bytes(original_bytes)`），所以"仓库被留脏"
   是一件可以直接看的事实，不需要靠重跑判据去推断。而浏览器判据跑一轮
   要 20+ 秒、且对机器速度敏感（软件渲染下页面 10 秒总闸会贴边），
   拿它当"还原干净"的推断器，抖动就会被写成一句很重的指控：
     · M31：并发编辑测试文件 ⇒ 被误报「还原不干净」（判据自己还没写完）
     · M292：判据本身时红时绿 ⇒ 同上
     · M314/M315：Linux runner 上**还原后重跑**偶发不过，本地连跑四次全绿、
       CI 同一机器上「浏览器端自检」闸门 45/45 通过 —— 两次误报的形状完全一样
   所以现在分两种口径：
     · cmd 型（浏览器/编辑器判据）：**确定性字节验证** —— 源文件字节回到原位、
       重建退出码为 0（需要时）、构建产物哈希回到变异前（esbuild 同输入同输出，
       已实测两次构建逐字节相同）。判据的牙齿在**变异后那一轮**（必须红），
       不在还原后这一轮。
     · node:test 型：还原后重跑一次（毫秒级、确定性），失败时把明细打出来
       （以前 `n_fail_after, _ = run(m)` 把输出丢了，只剩一个数字）。

★★ 第五种误报形状：**脏产物嫁祸给下一条**（2026-10-25 实测两次）。
   ① M229/M230 的 `cmd` 带 `--build` 却没声明 `rebuild`：变异态被构建进
      `web/editor.js` 后没人再建一次，脏包留在盘上；接着 M292 把它当"正确基线"，
      于是报出「M292 产物没回到干净基线」—— 看起来像 M292 停在了变异态。
   ② M189 更彻底地绕过了声明体系：它的构建藏在 `cross-host-save.mjs` 内部
      （整条工具是"构建 + 开浏览器比对"），`web/cross-host.js` 因此从未被纳入检查，
      脏包里多着一个 `performance.now()` 躺了一整天都没人发现。
   结论：**不靠条目声明，按结果验证** ——
     · 产物基线**开跑前统一建一次**（`_ARTIFACTS_CLEAN`），不用"上一条的遗留状态"；
     · 任何 `cmd` 型条目还原后**一律重建**（`build:web` + `cross-host.js` 两路），
       再拿三个产物的哈希对回基线。代价约 2 秒/条，换"谁都不可能忘记"。
"""
import hashlib
import json
import os
import signal
import subprocess
import sys
import pathlib
import re
from datetime import datetime

# ★★ 这个文件是**脚本**：全篇顶层代码，末尾 `sys.exit()`，没有 `main()`。
#   所以一旦有人 import / `runpy.run_path` 执行它，就会**直接启动整轮变异**
#   （在 src/ 里逐条注入 400 多次），然后大概率被工具超时杀掉，
#   把某个文件留在变异态。2026-10-27 我就这么误触发过一次 —— 想读变异表统计
#   "哪些条目指向我改过的文件"，代价是 `lossless-pred.ts` 被留脏、两条 JPEG 判据红。
#   在**任何副作用之前**拦住非脚本执行；要读变异表请用 `ast` 解析（`docs-check.mjs`
#   就是直接读文本数的），要跑就 `python tools/mutation-check.py`。
if __name__ != "__main__":
    raise SystemExit(
        "tools/mutation-check.py 是脚本，不能 import（导入即启动整轮变异）；"
        "要读变异表请用 ast 解析文本，要跑就 `python tools/mutation-check.py`"
    )

# ★ 不能硬编码本机绝对路径。原先写死 `E:/game_make/.../08-引擎内核`，
#   在 Linux runner 上**每一条 m["test"] 都不存在**，被报成「判据文件不存在」——
#   那句话的意思是"配置写错了"，而真相是"这个脚本一次都没在 CI 上跑起来过"。
#   2026-10-25：修好前它一直排在最后一步，前面总有别的红挡着，所以从没暴露。
#   从脚本自身位置反推：tools/mutation-check.py → 引擎根。
ROOT = pathlib.Path(__file__).resolve().parent.parent

# ★ 跨平台的 npm 入口（2026-10-25 批75）：
#   Windows 上是 npm.cmd，且必须经 shell 才能跑 .cmd；POSIX 上是 npm，直接 exec。
#   原先写成 `subprocess.run(["npm", "run", "build:web"], shell=True)`——
#   POSIX 上 list + shell=True **只有第一个元素是命令**，整行退化成裸 `npm`
#   （打印帮助就退出），重建静默空转；Windows 上 cmd /c 反而会把 list 连成
#   命令串正常跑。同一个坑只在 Linux 上发作，而症状（包停在变异态）离这里很远。
_NPM = "npm.cmd" if sys.platform == "win32" else "npm"

# build:web 的产物：浏览器/编辑器判据读的就是它们，变异还原后必须回到原位。
# ★ cross-host.js 也算：它由 `tools/cross-host-save.mjs` 单独 esbuild 出来，
#   曾被 M189 的变异悄悄留在盘上（那份脏包里多写了一个 `performance.now()`）——
#   只盯 bundle/editor 两个文件就看不见它。
_ARTIFACTS = ("web/bundle.js", "web/editor.js", "web/cross-host.js")


def _artifacts_hash() -> str:
    """构建产物的组合哈希。

    ★ 为什么能用它证明"还原干净"：esbuild 同输入同输出（本地实测两次构建
      逐字节相同），所以"还原后重建"有没有真的发生，看哈希就够 —— 不需要再跑
      一轮 20+ 秒的浏览器判据去推断（那正是 M314/M315 误报「还原不干净」的来历）。
    """
    h = hashlib.sha256()
    for rel in _ARTIFACTS:
        p = ROOT / rel
        h.update(rel.encode("utf-8"))
        h.update(p.read_bytes() if p.exists() else b"<missing>")
    return h.hexdigest()


def _run_build() -> int:
    """把所有 web/ 产物重建一遍，返回第一个非零退出码（全成功返回 0）。

    ★ 两个构建者，缺一不可：
      · `npm run build:web` → `web/bundle.js` + `web/editor.js`
      · `node tools/cross-host-save.mjs --build-only` → `web/cross-host.js`
      （最后这个由跨宿主工具自己 esbuild，`build:web` 不管它。M189 的脏包
       就是漏了这一路 —— 只重建 build:web 的话，它永远留在变异态。）

    ★ 不用 `shell=True`：
      · POSIX 上 list + shell=True 只有第一个元素是命令（原 bug，见文件头）；
      · Windows 上 .cmd 由系统自己经 shell 拉起，**不需要** shell=True ——
        加了反而触发 DEP0190（"args 与 shell=True 一起用不安全"）。
      两头都不用，代码就只有一条路径，不会再有"哪个平台走哪个分支"的差异。
    """
    r = subprocess.run(
        [_NPM, "run", "build:web"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=600,
    )
    if r.returncode != 0:
        return r.returncode
    r2 = subprocess.run(
        ["node", "tools/cross-host-save.mjs", "--build-only"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=600,
    )
    return r2.returncode

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
    # ---- 内容板块（Lua 5.1 / 隔离 / 解码 / 资产→GPU）----
    {
        "name": "M4 模块 env 退化为共享 _G",
        "file": "src/backends/script-lua/runtime.ts",
        "pairs": [(
            "    env = {}\n    setmetatable(env, { __index = _G })",
            # 等价于"没做隔离"：所有模块写在同一个全局表里（批133 起这行在 else 分支里）
            "    env = _G\n    setmetatable(env, { __index = _G })",
        )],
        "test": "tests/backends/script-env.test.ts",
    },
    {
        "name": "M5 PNG Paeth 滤波退化",
        "file": "src/extensions/asset-import/decode/png.ts",
        "pairs": [(
            "  if (pa <= pb && pa <= pc) return a;\n  if (pb <= pc) return b;\n  return c;",
            # 退化成 Up 滤波的 predictor：None/Sub/Up 的图仍然全对，
            # 只有用 Paeth 编码的图（demo 的 tree.png）会花 —— 这正是判据要抓的
            "  if (pa <= pb && pa <= pc) return c;\n  if (pb <= pc) return b;\n  return c;",
        )],
        "test": "tests/extensions/png-decode.test.ts",
    },
    {
        "name": "M6 图集像素没传给 GPU",
        "file": "src/extensions/render/render-module.ts",
        "pairs": [(
            # ★ 这里一度是 `atlas.pixels,` 单行；16 位改造后上传目标变成
            #   `upload`（8/16 位按图集格式选），T288 多页改造后 `if (!t.ok)`
            #   又长出了失败清理循环。变异点必须跟着实现走 —— 靶子漂移会被
            #   汇总打印成"变异没被抓住（判据是假绿）"，那是**误判**：
            #   没找到位置时一条判据都没跑，判据无从红起。
            "          upload,\n        );\n        if (!t.ok) {",
            # 尺寸/格式/label 全对，只是没带像素 —— "假贴图"的典型形态：
            # 所有调用都成功，画面上什么都没有
            "          null,\n        );\n        if (!t.ok) {",
        )],
        "test": "tests/core/asset-gpu-roundtrip.test.ts",
    },
    # ---- Adam7 / APNG / 16 位（2026-10-22 补齐这三项时同步加）----
    {
        "name": "M8 Adam7 pass 表错一位",
        "file": "src/extensions/asset-import/decode/png.ts",
        "pairs": [(
            "  { xStart: 4, yStart: 0, xStep: 8, yStep: 8 },",
            # pass 2 的起点从 4 挪到 5：编码器（tools/png-encode.mjs）用的是**独立**的过滤式实现，
            # 它仍按规范写数据，于是解码器会解出错位的图 —— 这正是"生成式 vs 过滤式"两条腿的价值。
            "  { xStart: 5, yStart: 0, xStep: 8, yStep: 8 },",
        )],
        "test": "tests/extensions/png-adam7.test.ts",
    },
    {
        "name": "M9 Adam7 pass 宽度少算一列",
        "file": "src/extensions/asset-import/decode/png.ts",
        "pairs": [(
            "    const w = width > d.xStart ? Math.ceil((width - d.xStart) / d.xStep) : 0;",
            # ceil → floor：13×11 这种尺寸会少 1 列，扫描线总长度变化 ⇒ 要么长度不符，要么错位
            "    const w = width > d.xStart ? Math.floor((width - d.xStart) / d.xStep) : 0;",
        )],
        "test": "tests/extensions/png-fixtures.test.ts",
    },
    {
        "name": "M10 APNG blend=OVER 退化成覆盖",
        "file": "src/extensions/asset-import/decode/apng.ts",
        "pairs": [(
            "  const sa = src[s + 3]! / 255;",
            # 半透明像素直接覆盖：不透明帧看不出区别，只有 alpha<255 的帧会错
            "  const sa = src[s + 3]! / 255;\n  dst[o] = src[s]!;\n  dst[o + 1] = src[s + 1]!;\n  dst[o + 2] = src[s + 2]!;\n  dst[o + 3] = src[s + 3]!;\n  return;",
        )],
        "test": "tests/extensions/apng.test.ts",
    },
    {
        "name": "M11 APNG 不执行 dispose",
        "file": "src/extensions/asset-import/decode/apng.ts",
        "pairs": [(
            "    if (pendingDispose !== undefined) {\n      disposeArea(pendingDispose.rect, pendingDispose.op);\n      pendingDispose = undefined;\n    }",
            # 只清标记、不做清理：BACKGROUND 的矩形不再变透明，PREVIOUS 不再回滚
            "    if (pendingDispose !== undefined) {\n      pendingDispose = undefined;\n    }",
        )],
        "test": "tests/extensions/apng.test.ts",
    },
    {
        "name": "M12 16 位降采样退回取高字节",
        "file": "src/extensions/asset-import/decode/png.ts",
        "pairs": [(
            "  return Math.round(v / 257);",
            # floor：0x12FF 会得到 18 而不是 19 —— 只有钉了边界值才抓得住
            "  return v >> 8;",
        )],
        "test": "tests/extensions/png-decode.test.ts",
    },
    {
        "name": "M13 APNG 不校验 acTL 帧数",
        "file": "src/extensions/asset-import/decode/apng.ts",
        "pairs": [(
            "  if (sources.length !== frameCount) {",
            # 声明的帧数比实际多时，播放器会静默截断 —— 不报错就永远发现不了
            "  if (false) {",
        )],
        "test": "tests/extensions/apng.test.ts",
    },
    {
        "name": "M7 Lua 5.1 缺 unpack",
        "file": "src/backends/script-lua/compat-lua51.ts",
        "pairs": [(
            "unpack = table.unpack",
            "unpack = nil",
        )],
        "test": "tests/backends/script-lua51.test.ts",
    },
    # ---- JPEG（2026-10-22 补齐 DCT 解码器时同步加）----
    # 这一组都只能靠 tests/extensions/jpeg.test.ts 抓：
    #   · AC 精修 / DC 复位 错位后画面"看起来像照片"，只有和同源编码逐字节比对才露馅；
    #   · 上采样换滤波器只会让差异变大，不逐项看容差就发现不了。
    {
        "name": "M14 渐进 AC 精修 EOBRUN 少计当前块",
        # 这是本轮真踩过的坑：r=0（本块即 EOB）时 (1<<0)-1 = 0，
        # 于是本块剩余非零系数的修正位一个都没读，位流从此错位。
        "file": "src/extensions/asset-import/decode/jpeg/scan-huffman.ts",
        "pairs": [(
            "              st.eobrun = (1 << run) + (run > 0 ? r.receive(run) : 0);",
            "              st.eobrun = (1 << run) - 1 + (run > 0 ? r.receive(run) : 0);",
        )],
        "test": "tests/extensions/jpeg.test.ts",
    },
    {
        "name": "M15 重启区间不复位 DC 预测器",
        # DRI 的全部意义就是"每 N 个 MCU 归零预测器"，避免误差沿扫描线累积。
        # 去掉复位后仍能解出图，只是每个区间第一个块偏一截 —— 只有逐字节不变量抓得住。
        "file": "src/extensions/asset-import/decode/jpeg/scan-huffman.ts",
        "pairs": [(
            "    for (const c of scanComps) c.pred = 0;\n  };",
            "  };",
        )],
        "test": "tests/extensions/jpeg.test.ts",
    },
    {
        "name": "M16 三角上采样退化成最近邻",
        # 色度 2 倍降采样的图上，最近邻会在色块边界留硬台阶。与金标的差异会从
        # max≈4 涨到几十 —— 容差判据（maxAbs）就是为这个准备的。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [(
            "  return top * wy0 + bottom * wy1;",
            "  void top; void bottom; void wy0; void wy1; return a;",
        )],
        "test": "tests/extensions/jpeg.test.ts",
    },
    {
        "name": "M17 截断文件不再标记",
        # 补 0 让截断文件"能解"，但不标记就等于把"缺了 40% 的熵数据"
        # 当成完整像素交给上游 —— 画面上一块灰，没人知道是文件坏了。
        "file": "src/extensions/asset-import/decode/jpeg/index.ts",
        "pairs": [(
            "          truncated: !file.sawEoi,",
            "          truncated: false,",
        )],
        "test": "tests/extensions/jpeg.test.ts",
    },
    {
        "name": "M18 EXIF 方向不再生效",
        # applyOrientation 直接返回原图：竖拍照片会横躺，且宽高不互换。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [(
            "  if (orientation <= 1 || orientation > 8) return { data: src, width: w, height: h };",
            "  return { data: src, width: w, height: h };",
        )],
        "test": "tests/extensions/jpeg.test.ts",
    },
    # ---- 12 bit / 算术 / 无损 / 分层（2026-10-23 收尾时同步加）----
    # 这一组的共同点：**坏掉之后图还是"像一张图"**，靠肉眼看不出，只能靠判据。
    {
        "name": "M19 QM 的 Next_Index_LPS 丢掉 Switch_MPS 位",
        # 真踩过的坑（本轮）：表里少 bit 7 之后，同一个统计桶连续用两次时
        # 第二次决策把已判成 LPS 的符号又当 MPS 解出来。症状是 DC 全对、
        # 块首 AC 幅值偏小、其余全 0，而位流依然"合法"。
        "file": "src/extensions/asset-import/decode/jpeg/qm.ts",
        "pairs": [(
            "  QM_NLPS[i] = QM_NLPS_RAW[i]! | (QM_SWITCH_STATES.includes(i) ? 0x80 : 0);",
            "  QM_NLPS[i] = QM_NLPS_RAW[i]!;",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M20 双线性上采样只钳上界（负下标读成 0）",
        # 真踩过的坑（本轮）：`Math.min(sh-1, y)` 让 y=-1 读到 undefined，
        # NaN 落进 Uint16Array 变 0 —— 第一行整片变黑，而画面上"像过曝"。
        "file": "src/extensions/asset-import/decode/jpeg/hierarchy.ts",
        "pairs": [(
            "  const cy = (y: number): number => (y < 0 ? 0 : y >= sh ? sh - 1 : y);",
            "  const cy = (y: number): number => Math.min(sh - 1, y);",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M21 无损差分用钳位而不是模 2^P",
        # 真踩过的坑（本轮）：s=10、ref=250 时差是 16，16+250=266 要回绕到 10；
        # 钳位把它压成 255 —— 高光被剪掉，且只有测到"跨回绕"的样本才露馅。
        "file": "src/extensions/asset-import/decode/jpeg/hierarchy.ts",
        "pairs": [(
            "        dst[row + x] = cur.lossless ? sum & maxval : clampSample(sum, maxval);",
            "        dst[row + x] = clampSample(sum, maxval);",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M22 DC 差分类别上限写死 11（12 位流解不动）",
        # 真踩过的坑（本轮）：T.81 Table F.1 的 DC 类别上限随精度走（8 位 11、12 位 15）。
        # 写死 11 之后 12 位彩色图直接报"DC 差分位数超过 11"。
        "file": "src/extensions/asset-import/decode/jpeg/scan-huffman.ts",
        "pairs": [(
            "  const maxDcCategory = frame.precision > 8 ? 15 : 11;",
            "  const maxDcCategory = 11;",
        )],
        # ★ 第一次跑这条时报"没被抓住"，原因不是判据空转，而是**指错了测试文件**：
        #   12 位高反差的用例在 jpeg-modes.test.ts 里，jpeg.test.ts 的 12 位素材
        #   都是平滑渐变（DC 差从没超过 2047）。变异校验自己也要对账。
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M23 精度规则放行任意位数",
        # 把"DCT 只支持 8/12、无损 2..16"放宽成 2..16：6 位、17 位的流会被
        # 当成能解，然后在电平位移那里算出错的量程（不报错，只是整幅偏色）。
        "file": "src/extensions/asset-import/decode/jpeg/frame.ts",
        "pairs": [(
            "  } else if (precision !== 8 && precision !== 12) {",
            "  } else if (precision < 2 || precision > 16) {",
        )],
        "test": "tests/extensions/jpeg.test.ts",
    },
    {
        "name": "M24 EXP 允许出现在 DHP 之前",
        # 去掉"没有 DHP 就没有参考帧"的校验：放大因子被无声应用到第一帧，
        # 后续合成按错比例走 —— 画面糊，但不报错。
        "file": "src/extensions/asset-import/decode/jpeg/parse.ts",
        "pairs": [(
            "        if (sequenceHeader === null) {",
            "        if (false) {",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M25 EXP 与几何矛盾时不报错",
        # 把"EXP 声明的放大倍数必须等于实际几何比"这条校验短路：
        # 解析继续、合成按实际几何走 —— 画面糊得很自然，任何像素容差判据都会以为是量化误差。
        "file": "src/extensions/asset-import/decode/jpeg/parse.ts",
        "pairs": [(
            "      if (!expansionMatchesGeometry(prev, cur)) {",
            "      if (false && !expansionMatchesGeometry(prev, cur)) {",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M26 decodeImage 丢掉 keep16",
        # 统一入口不透传选项：8 位视图仍然对，只有像素是 8 位精度的 —— 静默丢精度。
        "file": "src/extensions/asset-import/decode/image.ts",
        "pairs": [(
            "  if (fmt === \"jpeg\") return decodeJpeg(bytes, opts?.jpeg);",
            "  if (fmt === \"jpeg\") return decodeJpeg(bytes, {});",
        )],
        "test": "tests/extensions/jpeg.test.ts",
    },
    {
        "name": "M27 分层渐进重复写扫描头（把刚修掉的缺陷放回去）",
        # 这个缺陷真出现过：分层分支在进入渐进路径前无条件写了一个 (0,63,0,0) 的 SOS，
        # 解码端报"DC 扫描（Ss=0）必须 Se=0"。放进变异表是为了保证"SOF6/SOF14 有用例跑通"
        # 这件事不会因为后续重构又退回去。
        "file": "tests/tools/jpeg-encode.ts",
        "pairs": [(
            "    if (progressive) {",
            "    writeSos(out, diffComps, 0, 63, 0, 0);\n    if (progressive) {",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M28 YCCK 少一次反相（白变黑）",
        # 这个缺陷真出现过，而且是被"自己编自己解"掩盖的：编码端与解码端一起错，
        # 回环仍然 max=0。只有把 libjpeg 的解码当金标（fixtures 里的 ycck-*）才抓得住。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [(
            "          c0 = maxval - (s0 + 1.402 * cr);",
            "          c0 = s0 + 1.402 * cr;",
        )],
        "test": "tests/extensions/jpeg.test.ts",
    },
    {
        "name": "M29 4 分量丢掉 K（只乘 1 不乘 K）",
        # 症状是"图看着对但整体提亮"：反相 CMY 的乘法被跳过，K 小的区域最明显。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [(
            "        r = (c0 * k) / maxval;",
            "        r = c0 + 0 * k;",
        )],
        "test": "tests/extensions/jpeg.test.ts",
    },
    {
        "name": "M30 无损预测初值忽略 Pt",
        # `2^(P-Pt-1)` 改成 `2^(P-1)`：Pt=0 时两者相同，所以只测 Pt=0..3 的老用例
        # 也可能漏掉；现在 Pt 走满 0..7，偏一个常数就立刻红。
        "file": "src/extensions/asset-import/decode/jpeg/lossless-pred.ts",
        "pairs": [(
            "    this.initial = 1 << (precision - pt - 1);",
            "    this.initial = 1 << (precision - 1);",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M31 无损不左移回 Pt（低位永久丢失）",
        # 反过来的错：解码完不 `<< pt`，样本整体变成 1/2^pt 的量级（看着像"曝光不足"）。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [(
            "        for (let i = 0; i < p.length; i++) p[i] = p[i]! << frame.pt;",
            "        for (let i = 0; i < p.length; i++) p[i] = p[i]! + 0 * frame.pt;",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M32 量化表改成重建时现查（不在 SOS 时绑定）",
        # 少绑一次 `c.qtTable`，重建时回退到 `frame.qt`：分层文件里后定义的 DQT
        # 会追溯影响先解的帧 —— 画面变但绝不报错。判据是"表插在所有扫描之后不该生效"。
        "file": "src/extensions/asset-import/decode/jpeg/parse.ts",
        "pairs": [(
            "          if (!current.lossless) c.qtTable = qt[c.tq] ?? null;",
            "          if (false) c.qtTable = qt[c.tq] ?? null;",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M33 分层不写 DRI（重启区间声明丢失）",
        # 只在编码端：分层流照常插 RST 标记但不写 DRI，解码端按"无重启"读，
        # 熵数据里的 RST 就成了噪声。判据是"带重启的分层无损必须仍 max=0"。
        "file": "tests/tools/jpeg-encode.ts",
        "pairs": [(
            "  if (restart > 0) {\n    out.marker(0xdd);",
            "  if (false) {\n    out.marker(0xdd);",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    # ---- 第五批：拒绝路径上限的"差一"变异 ----
    # ★ 这一批守的不是"有没有检查"，而是**上限的数值本身**。
    #   `s > 11` 写成 `s > 15`、`k > 63` 写成 `k > 64` 这类错误不会让任何
    #   "正常图"变红 —— 只有专门喂了边界值的那条用例才会。没有这一批，
    #   "87/94 拒绝理由被触发"这句话只证明了分支可达，不证明分支**是对的**。
    {
        "name": "M34 DC 类别上限写死 15（丢掉随精度变）",
        "file": "src/extensions/asset-import/decode/jpeg/scan-huffman.ts",
        "pairs": [(
            "  const maxDcCategory = frame.precision > 8 ? 15 : 11;",
            "  const maxDcCategory = 15;",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M35 AC 块尾上限差一（63 → 64）",
        "file": "src/extensions/asset-import/decode/jpeg/scan-huffman.ts",
        "pairs": [(
            "      if (k > 63) fail(\"ASSET.BAD_JPEG\", `AC 系数越过块尾：k=${k}（run=${run}）`);",
            "      if (k > 64) fail(\"ASSET.BAD_JPEG\", `AC 系数越过块尾：k=${k}（run=${run}）`);",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M36 无损类别上限 16 放宽到 32",
        "file": "src/extensions/asset-import/decode/jpeg/scan-lossless.ts",
        "pairs": [(
            "    if (s > 16) fail(\"ASSET.BAD_JPEG\", `无损差分的类别位数 ${s} 超过 16`);",
            "    if (s > 32) fail(\"ASSET.BAD_JPEG\", `无损差分的类别位数 ${s} 超过 16`);",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M37 算术 DC 幅度上限被放宽到永不触发（0x8000 → 0x7fffffff）",
        # ★ 这个变异两次才写对，两次都很有信息量：
        #   ① `0x8000 → 0x10000` 是**等价变异**：m 每次左移，15 次到 0x8000、16 次到 0x10000，
        #      下一轮照样命中 —— 抓不住不是判据的问题。
        #   ② `0x8000 → 0x800000` 仍然抓不住，因为报错文本里写的就是"（≥ 0x8000）"，
        #      **改上限不改文本**时判据只看到"同一条消息"，看不到触发时机变了。
        #      这说明那条用例证明的是"这条分支会被触发"，**没有**钉住上限的数值。
        #   ③ 换成 m 永远取不到的 0x7fffffff（m 只会是 2 的幂），分支彻底不触发，才真正变红。
        #      代价是把上限写死成 0x7fffffff —— 这正是"临时放宽一下"的典型写法。
        "file": "src/extensions/asset-import/decode/jpeg/scan-arith.ts",
        "pairs": [(
            "        if (m === 0x8000) fail(\"ASSET.BAD_JPEG\", \"算术编码的 DC 幅度类别溢出（≥ 0x8000）\");",
            "        if (m === 0x7fffffff) fail(\"ASSET.BAD_JPEG\", \"算术编码的 DC 幅度类别溢出（≥ 0x8000）\");",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M38 分层不比较两帧分量数",
        "file": "src/extensions/asset-import/decode/jpeg/hierarchy.ts",
        "pairs": [(
            "  if (cur.components.length !== prev.components.length) {",
            "  if (false) {",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M39 分层不比较两帧精度",
        "file": "src/extensions/asset-import/decode/jpeg/hierarchy.ts",
        "pairs": [(
            "  if (cur.precision !== prev.precision) {",
            "  if (false) {",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M40 导入器对分层文件取参考帧尺寸（元数据报一半）",
        # 这条守的是一类"解对了但元数据错了"的缺陷：解码器给出的像素是 40×24，
        # 而导入器按第一帧（半分辨率参考帧）报 20×12。任何"像素层面"的判据都不会红，
        # 只有"元数据尺寸必须等于解码尺寸"这一条能抓住。
        "file": "src/extensions/asset-import/importers/texture.ts",
        "pairs": [(
            "      const hier = dhpWidth > 0 && dhpHeight > 0;",
            "      const hier = false;",
        )],
        "test": "tests/extensions/jpeg.test.ts",
    },
    # ---- 第八批：覆盖率审计补出来的判据，逐个补"注入即红" ----
    {
        "name": "M41 EXIF 6/8 两条旋转写反（顺时针 ↔ 逆时针）",
        # 这是 EXIF 表最典型的抄写错误：只影响 90° 的两个方向，
        # 而"图是顺时针转还是逆时针转"在无标注的图上肉眼很难判。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [
            ("        case 6: // 顺时针 90°\n          ox = h - 1 - y;\n          oy = x;",
             "        case 6: // 顺时针 90°\n          ox = y;\n          oy = w - 1 - x;"),
            ("        case 8: // 逆时针 90°\n          ox = y;\n          oy = w - 1 - x;",
             "        case 8: // 逆时针 90°\n          ox = h - 1 - y;\n          oy = x;"),
        ],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M42 非 2 倍采样因子改成四舍五入（复制变插值）",
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [(
            "    const p = Math.floor(pos / factor);",
            "    const p = Math.round(pos / factor);",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M43 渐进逼近位数上限 13 放宽到 20",
        "file": "src/extensions/asset-import/decode/jpeg/scan-arith.ts",
        "pairs": [(
            "    if (al > 13 || ah > 13) fail(\"ASSET.BAD_JPEG\", `渐进式逐次逼近位数非法：Al=${al} Ah=${ah}`);",
            "    if (al > 20 || ah > 20) fail(\"ASSET.BAD_JPEG\", `渐进式逐次逼近位数非法：Al=${al} Ah=${ah}`);",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M44 不检查渐进逼近是否逐级（Ah 必须为 Al+1）",
        "file": "src/extensions/asset-import/decode/jpeg/scan-arith.ts",
        "pairs": [(
            "    if (ah !== 0 && ah !== al + 1) {",
            "    if (false) {",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M45 IDCT 丢掉电平位移（整体压暗 2^(P-1)）",
        # 8 位时表现为"整幅偏黑"，与金标的 max 会直接爆；12 位时更狠（压到最暗的 1/16）。
        # 这条同时被"与 libjpeg 金标"和"与教科书定义式"两个方向咬住。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [(
            "      plane[py * planeW + px] = clampSample(Math.round(s + offset), maxval);",
            "      plane[py * planeW + px] = clampSample(Math.round(s), maxval);",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M46 IDCT 第二维用错基向量（块内转置）",
        # 只影响 8×8 块**内部**的排布：整幅图看起来还是"那张图"，
        # 只是每个块里出现了斜向纹理错位 —— 容差 3 的金标判据会红，肉眼不一定。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [(
            "      for (let v = 0; v < 8; v++) s += tmp[v * 8 + x]! * COS[v * 8 + y]!;",
            "      for (let v = 0; v < 8; v++) s += tmp[v * 8 + x]! * COS[v * 8 + x]!;",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M47 颜色变换的偏移量写死 128（12 位色度整体拧掉）",
        # 8 位完全看不出来（128 正是 8 位的 2^7），只有 12 位的判据会红 ——
        # 而 12 位没有任何外部金标，能抓住它的只有"定义式"那条。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [(
            "  const maxval = maxValueOf(precision);\n  const offset = 1 << (precision - 1);\n  const n = components.length;",
            "  const maxval = maxValueOf(precision);\n  const offset = 128;\n  const n = components.length;",
        )],
        "test": "tests/extensions/jpeg-modes.test.ts",
    },
    {
        "name": "M48 上采样：色度只有 2 个样本时仍然三角插值（libjpeg 此时是复制）",
        # 只在"图宽 3~4"的 4:2:2/4:2:0 上可见，差到 31 级；正常尺寸的语料一张都抓不到，
        # 所以专门补了 narrow-420 / narrow-422 两张窄图。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [("const fancyH = factorH === 2 && w > 2;", "const fancyH = factorH === 2;")],
        "test": "tests/extensions/jpeg.test.ts",
    },
    {
        "name": "M49 上采样：把 fancy 开关按轴判断（libjpeg 的 h2v2 只看宽）",
        # 反方向的错：3×97 修好了、97×3 从差 2 变差 26。
        # flat-420（高 3、宽 97）就是为这条错补的 —— 只修一个方向会立刻红。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [(
            "const fancyV = factorV === 2 && (factorH === 2 ? w > 2 : h > 2);",
            "const fancyV = factorV === 2 && h > 2;",
        )],
        "test": "tests/extensions/jpeg.test.ts",
    },
    {
        "name": "M50 IDCT 的电平位移写死 128（8 位正好看不出来，12 位整幅塌陷）",
        # 与 M47 同形状但不同位置：M47 在颜色变换里，这条在反量化+IDCT 的入口。
        # 8 位时 128 == 1<<7，**完全等价**，只有 12 位才暴露 ——
        # 12 位 DCT 的护栏有两条：①跨精度锚定（12 位往返必须落回 8 位金标的同一批像素）；
        # ②ffmpeg 外部金标（M51 用同一个变异点，交给第三方解码器那一侧去判）。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [(
            "export function buildPlane(c: Component, qt: Uint16Array, precision: number): Uint16Array {\n  const offset = 1 << (precision - 1);",
            "export function buildPlane(c: Component, qt: Uint16Array, precision: number): Uint16Array {\n  const offset = 128;",
        )],
        "test": "tests/extensions/jpeg.test.ts",
    },
    {
        "name": "M51 同一个电平位移错，交给 ffmpeg 外部金标去判",
        # ★ 为什么值得和 M50 重一个变异点：这两条判据的**见证者不同**。
        #   M50 的见证者是"我们自己 8 位的 Pillow 金标 + 我们自己的 12 位编解码"，
        #   一旦编码器与解码器对 12 位同错，这条判据就看不见了。
        #   M51 的见证者是 ffmpeg 的解码器 —— 它不会跟着我们的错误理解走。
        #   同一个变异被两套不同来源的判据各抓一次，才说明"外部参照真的参与判定"，
        #   而不是"加了一组文件但只有我们自己那一条在起作用"。
        "file": "src/extensions/asset-import/decode/jpeg/reconstruct.ts",
        "pairs": [(
            "export function buildPlane(c: Component, qt: Uint16Array, precision: number): Uint16Array {\n  const offset = 1 << (precision - 1);",
            "export function buildPlane(c: Component, qt: Uint16Array, precision: number): Uint16Array {\n  const offset = 128;",
        )],
        "test": "tests/extensions/jpeg-ffmpeg-gold.test.ts",
    },
    {
        "name": "M52 分层无损的差分合成用钳位代替 mod 2^P",
        # ★ 这个变异的**全部**判据就是 tests/extensions/jpeg-handwritten.test.ts：
        #   自产语料的回环抓不住它 —— 编码器写流和解码器读流如果都按钳位理解，
        #   回环仍然逐位相等。只有"字节是手写、期望是手算"那条能看见它
        #   （(128+128) mod 256 = 0 vs clamp = 255）。
        "file": "src/extensions/asset-import/decode/jpeg/hierarchy.ts",
        "pairs": [(
            "        dst[row + x] = cur.lossless ? sum & maxval : clampSample(sum, maxval);",
            "        dst[row + x] = clampSample(sum, maxval);",
        )],
        "test": "tests/extensions/jpeg-handwritten.test.ts",
    },
    {
        "name": "M53 分层有损的差图不再减回电平位移",
        # 有损差分帧的差图在 FDCT 前被减过 2^(P-1)，合成时必须加回来。
        # 漏掉这一步：整幅偏 128（8 位），而**自产回环依然逐位相等**（编码端也漏就一样）。
        "file": "src/extensions/asset-import/decode/jpeg/hierarchy.ts",
        "pairs": [(
            "  const shift = cur.lossless ? 0 : 1 << (cur.precision - 1);",
            "  const shift = cur.lossless ? 0 : 0;",
        )],
        "test": "tests/extensions/jpeg-handwritten.test.ts",
    },
    {
        "name": "M54 SOF11 的预测初值忘了随 Pt 缩小",
        # `initial = 2^(P-Pt-1)` 是无损的接缝：Pt>0 时样本已被右移，初值必须跟着小。
        # 写成 2^(P-1) 时 Pt=0 完全等价（M30 那条盯的就是 8/16 位与 Huffman 侧），
        # **只有 Pt>0** 才暴露，而 SOF11 的判据此前只有自产回环（编码端也错就一起绿）。
        "file": "src/extensions/asset-import/decode/jpeg/lossless-pred.ts",
        "pairs": [(
            "    this.initial = 1 << (precision - pt - 1);",
            "    this.initial = 1 << (precision - 1);",
        )],
        "test": "tests/extensions/jpeg-handwritten-arith.test.ts",
    },
    {
        "name": "M55 真实盘写入不走'临时文件+rename'，直接写目标文件",
        # ★ 这条的判据是**边写边读**：读者只能读到某一次的完整内容。
        #   直接 open(w)+write 时，读者会读到 0 字节或半截内容 —— 存档最怕的
        #   "崩溃时留下半个文件"是同一个物理现象，只是这台机器上表现为并发读。
        #   变异后 fsync 也没了，但**光去掉 fsync 不会被判据抓住**（这点必须诚实：
        #   当前的判据无法观测"是否真正落盘"，只能观测"读者是否看到半截"）。
        "file": "src/backends/fs-node/fs.ts",
        "pairs": [(
            "      let handle: fsp.FileHandle | undefined;\n"
            "      try {\n"
            "        handle = await fsp.open(tmp, \"w\");\n"
            "        await handle.writeFile(data);\n"
            "        await handle.sync(); // 先落到稳定介质，再让 rename 生效\n"
            "      } finally {\n"
            "        await handle?.close();\n"
            "      }\n"
            "      await this.renameWithRetry(tmp, target);",
            "      await fsp.writeFile(target, data);",
        )],
        "test": "tests/backends/fs-node.test.ts",
    },
    {
        "name": "M56 去掉'真实路径必须落在 root 内'的越界判定",
        # root 内的符号链接指向盘外时，字符串前缀完全合法，只有 realpath 能看出来。
        # 变异后 /link/escaped.txt 会真的写到盘外 —— 判据断言"盘外目录仍为空"。
        "file": "src/backends/fs-node/fs.ts",
        "pairs": [(
            "        const inside = real === this.realRoot || real.startsWith(this.realRoot + sep);\n"
            "        if (inside) return ok(undefined);",
            "        const inside = true;\n"
            "        if (inside) return ok(undefined);",
        )],
        "test": "tests/backends/fs-node.test.ts",
    },
    {
        "name": "M57 把路径里的 \"..\" 当无害段忽略（而不是拒绝）",
        # "聪明地解析"正是上一代引擎被绕过去的方式：解析成绝对路径看起来更友好，
        # 实际上让"我能写到哪"变得难以推理。变异后 /../x 被静默改写成 /x，越界检测失效。
        "file": "src/backends/fs-node/fs.ts",
        "pairs": [(
            "    if (seg === \"..\") {\n"
            "      return err(\n"
            "        engineError(\"FS.PATH_ESCAPE\", `路径里出现 \"..\"：${path}（拒绝，不做'聪明'的解析）`),\n"
            "      );\n"
            "    }\n"
            "    parts.push(seg);",
            "    if (seg === \"..\") continue;\n"
            "    parts.push(seg);",
        )],
        "test": "tests/backends/fs-node.test.ts",
    },
    {
        "name": "M58 module() 建的容器「变空才摘」改成「一律摘掉」",
        # 共用容器（shared.a / shared.b）是最容易写错的一步：卸 a 时把 shared 整张删掉，
        # 就把别人的 b 一起删了。判据断言"卸 a 之后 b 还在"。
        "file": "src/backends/script-lua/compat-lua51.ts",
        "pairs": [(
            "  for _ in pairs(e.value) do return false end\n  e.parent[e.key] = nil",
            "  e.parent[e.key] = nil",
        )],
        "test": "tests/backends/script-lua51.test.ts",
    },
    {
        "name": "M59 去掉「这张表还是我建的吗」的身份检查（叶子侧）",
        # 内容层会用 `_G.foo = {...}` 打补丁覆盖某个模块表；卸载时若无条件删键，
        # 删掉的是别人接管的表。判据断言 unload 之后 `_G.swapme.replaced` 仍在。
        "file": "src/backends/script-lua/compat-lua51.ts",
        "pairs": [(
            "        if e.parent[e.key] == e.value then\n"
            "          e.parent[e.key] = nil\n"
            "          removed = removed + 1\n"
            "        end",
            "        e.parent[e.key] = nil\n"
            "        removed = removed + 1",
        )],
        "test": "tests/backends/script-lua51.test.ts",
    },
    {
        "name": "M60 unload 根本不调 _G 清理（接线断掉）",
        # 清理逻辑写得再对，unload 里忘了调就是死的。这条盯的是**接线**而不是算法 ——
        # 判据里"卸载后 _G.deep 仍在"会红。
        "file": "src/backends/script-lua/runtime.ts",
        "pairs": [(
            "  if type(__engine_compat_unmodule) == \"function\" then",
            "  if false then",
        )],
        "test": "tests/backends/script-lua51.test.ts",
    },
    {
        "name": "M61 版本键写死成 __v（忽略 versionKey）",
        # 这正是这个 bug 的原样：场景存档写的是 format，Schema 读的是 __v。
        # 读不到版本 ⇒ 一律按 v1 处理 ⇒ `format:0` 的旧档被当当前版本静默读进来。
        "file": "src/core/serialization/schema.ts",
        "pairs": [
            ("const raw = cur[this.versionKey];", 'const raw = cur["__v"];'),
            (
                "const declared = Object.prototype.hasOwnProperty.call(cur, this.versionKey);",
                'const declared = Object.prototype.hasOwnProperty.call(cur, "__v");',
            ),
        ],
        "test": "tests/core/scene-io.test.ts",
    },
    {
        "name": "M62 构造 Schema 时不检查迁移链条数",
        # 只保留"编号连续"的检查：一条迁移都没有时那个循环一次都不跑，
        # 于是 version:2 且无迁移能构造成功，把架构错误降级成运行时错误。
        "file": "src/core/serialization/schema.ts",
        "pairs": [("    if (froms.length !== need) {", "    if (false) {")],
        "test": "tests/core/serialization.test.ts",
    },
    {
        "name": "M63 非整数版本号不检查（1.5 版静默放行）",
        # 1.5 同时躲过 `v > version` 与 `v < version`，原样返回。
        "file": "src/core/serialization/schema.ts",
        "pairs": [("    if (!Number.isInteger(v) || v < 1) {", "    if (v < 1) {")],
        "test": "tests/core/scene-io.test.ts",
    },
    {
        "name": "M64 存档头的 TOO_NEW 降级成 BAD_JSON",
        # 错误码是调用方的分支依据：把"新引擎写的档"说成"JSON 坏了"，
        # 用户会去修文件，而正确的处置是升级引擎。
        "file": "src/core/scene/scene-io.ts",
        "pairs": [
            (
                '      case "SER.VERSION_TOO_NEW":\n        return err(engineError("SCENE.FORMAT_TOO_NEW", dec.error.message));',
                '      case "SER.VERSION_TOO_NEW":\n        return err(engineError("SCENE.BAD_JSON", dec.error.message));',
            )
        ],
        "test": "tests/core/scene-io.test.ts",
    },
    {
        "name": "M65 共用归一化把 `..` 当无害段忽略",
        # 与 M57 同一个错法。★ 这条原来打在 `fs-http/fs.ts` 上，后来 `..` 的判定被抽到
        # `platform/fs/virtual-path.ts`（三份副本合一），变异点就"消失"了 ——
        # 变异工具报的是"变异点没找到（判据可能已过期）"，**这正是它该有的行为**：
        # 重构之后没人重新指认变异点，就等于那条判据从此不再被验。
        "file": "src/platform/fs/virtual-path.ts",
        "pairs": [
            (
                '    if (seg === "..") {\n'
                '      return err(engineError("FS.PATH_ESCAPE", `路径含 ..（拒绝越界）：${path}`));\n'
                "    }",
                "    if (seg === \"..\") continue;",
            )
        ],
        "test": "tests/backends/fs-http.test.ts",
    },
    {
        "name": "M66 fs-http 的 list 返回空数组（冒充「目录是空的」）",
        # 只读契约专门为这条写的：空数组会让资产导入以为一个资产都没有，然后安静地什么都不做。
        "file": "src/backends/fs-http/fs.ts",
        "pairs": [
            (
                "    return err(\n      engineError(\n        \"FS.NOT_SUPPORTED\",\n        `HTTP 后端没有目录列举能力（静态资源服务器不提供列目录）：${dir}`,\n      ),\n    );",
                "    void dir;\n    return ok([]);",
            )
        ],
        "test": "tests/backends/fs-http.test.ts",
    },
    {
        "name": "M67 fs-http 在服务器不支持 HEAD 时不退回 GET",
        # 后果：某些静态服务器上 stat 永远失败，而"读得到内容、量不出大小"很难查。
        "file": "src/backends/fs-http/fs.ts",
        "pairs": [
            (
                '    if (!res.ok && res.error.code === "FS.NOT_SUPPORTED") {',
                "    if (false) {",
            )
        ],
        "test": "tests/backends/fs-http.test.ts",
    },
    {
        "name": "M68 fs-http 把 404 也映射成 FS.IO",
        # 错误码是调用方的分支依据："资源不存在"与"服务器坏了"处置完全不同。
        "file": "src/backends/fs-http/fs.ts",
        "pairs": [("    if (st === 404 || st === 410) return err(", "    if (false) return err(")],
        "test": "tests/backends/fs-http.test.ts",
    },
    {
        "name": "M69 fs-http 的 readText 不做严格 UTF-8 校验",
        # 宽松解码会把"资产编码错了"变成一堆替换字符（U+FFFD），看起来像"文本本来就这样"。
        "file": "src/backends/fs-http/fs.ts",
        "pairs": [('new TextDecoder("utf-8", { fatal: true })', 'new TextDecoder("utf-8", { fatal: false })')],
        "test": "tests/backends/fs-http.test.ts",
    },
    {
        "name": "M70 fs-storage 写入不建父目录",
        # 契约里"没 ensureDir 也能写"那条会红：list 一个不存在的父目录会 NOT_FOUND
        "file": "src/backends/fs-storage/fs.ts",
        "pairs": [
            (
                "    for (let i = 1; i < segs.value.length; i++) {\n"
                "      dirs.add(virtualPathOf(segs.value.slice(0, i)));\n"
                "    }",
                "    // 变异：不建父目录",
            )
        ],
        "test": "tests/backends/fs-storage.test.ts",
    },
    {
        "name": "M71 fs-storage 读目录不报 IS_DIR",
        # localStorage 没有目录，最容易"顺手"把目录当不存在：契约要求 IS_DIR
        "file": "src/backends/fs-storage/fs.ts",
        "pairs": [
            (
                "    if (this.dirs().has(vpath)) {\n"
                '      return err(engineError("FS.IS_DIR", `路径是一个目录：${vpath}`));\n'
                "    }",
                "    // 变异：不查目录",
            )
        ],
        "test": "tests/backends/fs-storage.test.ts",
    },
    {
        "name": "M72 base64 解码丢最高位",
        # 手写 base64 最容易错在"末字节/padding"，但更隐蔽的是掩码写小一位：
        # 0..127 全对，128..255 全错 —— 存档是 UTF-8 文本，中文正好落在高位
        "file": "src/backends/fs-storage/fs.ts",
        "pairs": [("      out[o++] = (acc >> bits) & 0xff;", "      out[o++] = (acc >> bits) & 0x7f;")],
        "test": "tests/backends/fs-storage.test.ts",
    },
    {
        "name": "M73 配额满被报成 FS.IO（而不是 NO_SPACE）",
        # 错误码是处置依据："存满了"要提示用户清理，"IO 坏了"要提示重试
        "file": "src/backends/fs-storage/fs.ts",
        "pairs": [('return err(engineError("FS.NO_SPACE",', 'return err(engineError("FS.IO",')],
        "test": "tests/backends/fs-storage.test.ts",
    },
    {
        "name": "M74 docs-check 的 backends 实测值没接进 actual",
        # 2026-10-23 真实发生过：`actualBackends()` / `actualCiSteps()` 写好了却从没被调用，
        # actual[key] 是 undefined。当时文档里还没有这两个标记 ⇒ 闸门报"全部一致"。
        # 现在靠 `missingKeys` 硬校验兜住，这条变异就是钉住那道校验。
        "file": "tools/docs-check.mjs",
        "pairs": [("backends, steps, ...src }", "steps, ...src }")],
        "test": "tools/docs-check.mjs",
        "cmd": ["node", "tools/docs-check.mjs", "--quick"],
    },
    {
        "name": "M75 README 的后端数写成过期的 12",
        # 对账工具真正的价值是"文档写错了要红"。只测"工具能跑通"证明不了这件事。
        "file": "README.md",
        "pairs": [("**13 个后端**", "**12 个后端**")],
        "test": "README.md",
        "cmd": ["node", "tools/docs-check.mjs", "--quick"],
    },
    {
        "name": "M76 ARCHITECTURE 的 CI 步数写成过期的 14",
        # steps 的值来自 `node tools/ci.mjs --list`（外部进程），
        # 与 backends（读目录）是两条不同的取数路径，各钉一条。
        "file": "docs/ARCHITECTURE.md",
        # ★ 靶子随闸门数漂移过四次（10→11→12→13→14→15）：这条变异必须跟着**真实标题**走，
        #   否则它报的是"变异点没找到"（靶子漂移），而不是"文档对账抓住了它"。
        #   这也是"靶子漂移"这个分类存在的意义：它明确告诉你该改的是**变异表**，
        #   不是判据 —— 别去动 docs-check。
        "pairs": [("### 10.4 15 道闸门", "### 10.4 14 道闸门")],
        "test": "docs/ARCHITECTURE.md",
        "cmd": ["node", "tools/docs-check.mjs", "--quick"],
    },
    {
        "name": "M77 规范化序列化不排序键",
        # 键序不是语义，但 `JSON.stringify` 会把它算进串里 ⇒ 同一份数据两个指纹
        "file": "src/foundation/canonical.ts",
        "pairs": [("const keys = Object.keys(rec).sort();", "const keys = Object.keys(rec);")],
        "test": "tests/extensions/worldgen.test.ts",
    },
    {
        "name": "M78 规范化序列化放过小数",
        # "四舍五入到整数"看似友好，实际把"我引入了浮点"这件事藏起来了
        "file": "src/foundation/canonical.ts",
        "pairs": [
            (
                "      if (!Number.isInteger(value)) {\n"
                '        return bad(CANON_NOT_INTEGER, path, `是小数 ${String(value)}（需要小数请改用定点整数）`);\n'
                "      }\n",
                "      // 变异：放过小数\n",
            )
        ],
        "test": "tests/extensions/worldgen.test.ts",
    },
    {
        "name": "M79 字符串手拼引号而不做 JSON 转义",
        # 一个引号就能让"一个键"变成"两个键"，两份不同数据撞成同一个串
        "file": "src/foundation/canonical.ts",
        "pairs": [("      return ok(JSON.stringify(value));", '      return ok(`"${value}"`);')],
        "test": "tests/extensions/worldgen.test.ts",
    },
    {
        "name": "M80 架桥只计数不真的改地形",
        # "修复看起来做了其实没做"：桥记录写了、可通行格数没变，
        # 于是 repair=true 的世界仍然有到不了的陆地
        "file": "src/extensions/worldgen/worldgen.ts",
        "pairs": [
            (
                '        if (isPassable(kinds[cell]!)) continue;\n'
                '        kinds[cell] = "beach";\n'
                "        carvedHere++;",
                "        if (isPassable(kinds[cell]!)) continue;\n        carvedHere++;",
            )
        ],
        "test": "tests/extensions/worldgen.test.ts",
    },
    {
        "name": "M81 投放点 id 退回全局自增",
        # 全局自增的失败模式：中途加一个格子，后面所有 id 平移，存档里的引用全部指错东西
        "file": "src/extensions/worldgen/worldgen.ts",
        "pairs": [("        id: cell * maxSites + k,", "        id: sites.length,")],
        "test": "tests/extensions/worldgen.test.ts",
    },
    {
        "name": "M82 去掉「边界一圈强制海」",
        # 不做成岛形，地图边缘会漏出可通行格，"能不能走出去"就没定义
        "file": "src/extensions/worldgen/worldgen.ts",
        "pairs": [
            (
                "      if (isBorder) {\n"
                '        kinds[z * width + x] = "ocean";\n'
                "        continue;\n"
                "      }",
                "      // 变异：不强制海",
            )
        ],
        "test": "tests/extensions/worldgen.test.ts",
    },
    {
        "name": "M83 sequence 遇 running 不记住位置",
        # 「只有 running 带记忆」是这棵树的全部承诺。去掉记忆后行为仍"能跑"，
        # 只是每 tick 从头重来 —— 表现是所有动作被重复执行，且不报错
        "file": "src/extensions/ai/behavior.ts",
        "pairs": [
            (
                '          if (st === "running") {\n'
                "            // 只有 running 带记忆：下一次从这里继续，前面的分支不再执行\n"
                "            this.cursor.set(node.id, i);\n"
                '            return "running";',
                '          if (st === "running") {\n            return "running";',
            )
        ],
        "test": "tests/extensions/ai.test.ts",
    },
    {
        "name": "M84 selector 把 running 当成 success",
        # 把"还在做"当成"做完了"：上层会以为任务完成，于是永远不回头
        "file": "src/extensions/ai/behavior.ts",
        "pairs": [
            (
                '          if (st === "running") {\n'
                "            this.cursor.set(node.id, i);\n"
                '            return "running";\n'
                "          }\n"
                '          if (st === "success") {',
                '          if (st === "running") {\n'
                "            this.cursor.set(node.id, i);\n"
                '            return "success";\n'
                "          }\n"
                '          if (st === "success") {',
            )
        ],
        "test": "tests/extensions/ai.test.ts",
    },
    {
        "name": "M85 wait 少算一格（永远差一次）",
        # 差一格最阴：看上去在等，实际永远等不到
        "file": "src/extensions/ai/behavior.ts",
        "pairs": [
            (
                "const done = (this.elapsed.get(node.id) ?? 0) + 1;",
                "const done = this.elapsed.get(node.id) ?? 0;",
            )
        ],
        "test": "tests/extensions/ai.test.ts",
    },
    {
        "name": "M86 reset 不清 wait 进度",
        # 换目标后还记着上一个目标的等待进度 ⇒ 新任务一上手就"已经等完了"
        "file": "src/extensions/ai/behavior.ts",
        "pairs": [("    this.elapsed.clear();\n  }", "  }")],
        "test": "tests/extensions/ai.test.ts",
    },
    {
        "name": "M87 inverter 丢弃 running（当成 failure）",
        # inverter 只该翻转成败，running 必须原样透传，否则"还要多久"的信息被吃掉
        "file": "src/extensions/ai/behavior.ts",
        "pairs": [('        if (st === "running") return "running";\n', "")],
        "test": "tests/extensions/ai.test.ts",
    },
    {
        "name": "M88 未注册的行为在构造时被放过",
        # 构造时不报，就要等运行到那一支才炸 —— 而那一支可能一百年才走到一次
        "file": "src/extensions/ai/behavior.ts",
        "pairs": [("    if (op === undefined || !Object.prototype.hasOwnProperty.call(ops, op)) {", "    if (false) {")],
        "test": "tests/extensions/ai.test.ts",
    },
    {
        "name": "M89 发布包把所有资产都打进去（不求闭包）",
        # 出口判据①：删掉一个未被引用的资产，产物必须逐字节不变。
        # 「目录里有什么就打什么」这条最自然的实现，正好违反它
        "file": "src/extensions/build/publish.ts",
        "pairs": [("  const closure = [...reachable].sort();", "  const closure = [...byId.keys()].sort();")],
        "test": "tests/extensions/publish.test.ts",
    },
    {
        "name": "M90 包名用资产 id 列表而不是包内容",
        # 名字不跟着内容走 ⇒ 改了资产包名不变 ⇒ CDN 永远给旧内容
        "file": "src/extensions/build/publish.ts",
        "pairs": [("    const h = hashBytes(bytes);", '    const h = hashText(curIds.join(","));')],
        "test": "tests/extensions/publish.test.ts",
    },
    {
        "name": "M91 包内不做 framing（直接拼接）",
        # {x:"ab",y:"c"} 与 {x:"a",y:"bc"} 拼出来是同一串字节 ⇒ 两个不同资产集合撞同一个包名
        "file": "src/extensions/build/publish.ts",
        "pairs": [("  out.set(bytes, 4 + idBytes.length + 4);\n  return out;", "  out.set(bytes, 4 + idBytes.length + 4);\n  return bytes;")],
        "test": "tests/extensions/publish.test.ts",
    },
    {
        "name": "M92 manifest hash 退回 JSON.stringify",
        # 这份数据的键序恰好是写死的，所以今天看起来一样；但一旦有人从 Map 重建对象，
        # 指纹就会随键序漂 —— 规范化序列化存在的全部理由
        "file": "src/extensions/build/publish.ts",
        "pairs": [("  const canon = canonicalize(body);", "  const canon = ok(JSON.stringify(body));")],
        "test": "tests/extensions/publish.test.ts",
    },
    {
        "name": "M93 入口列表不排序（顺序敏感）",
        # 入口顺序影响产物 ⇒ 两个仓库 checkout 顺序不同就打出不同的包
        "file": "src/extensions/build/publish.ts",
        "pairs": [("  const entries = [...new Set(input.entries)].sort();", "  const entries = [...new Set(input.entries)];")],
        "test": "tests/extensions/publish.test.ts",
    },
    {
        "name": "M94 AI 模块驱动顺序反转",
        # 顺序变了，"第 7 个 tick 谁先动"就变了，而回放只认字节
        "file": "src/extensions/ai/ai-module.ts",
        "pairs": [("      for (const e of entries) {", "      for (const e of [...entries].reverse()) {")],
        "test": "tests/extensions/ai-module.test.ts",
    },
    {
        "name": "M95 一个 agent 的异常带崩整个 tick（catch 后又抛）",
        # 隔离是模块层唯一的职责之一：一个坏行为不该让整个世界的 AI 停摆
        "file": "src/extensions/ai/ai-module.ts",
        "pairs": [("        } catch (cause) {\n          errors++;", "        } catch (cause) {\n          errors++;\n          throw cause;")],
        "test": "tests/extensions/ai-module.test.ts",
    },
    {
        "name": "M96 异常后不重置记忆",
        # 异常可能抛在树的中途，记忆停在一个"看起来一致、实际不可信"的位置；
        # 不重置就会每 tick 都炸（判据断言的是"再等 3 tick 才炸第二次"）
        "file": "src/extensions/ai/ai-module.ts",
        "pairs": [("          e.agent.reset();\n", "")],
        "test": "tests/extensions/ai-module.test.ts",
    },
    {
        "name": "M97 用 dt 门控驱动（小 dt 就跳过）",
        # 最像"优化"的一种退化：dt 一参与，"同种子同世界"就不成立
        "file": "src/extensions/ai/ai-module.ts",
        "pairs": [("      for (const e of entries) {", "      if (_dt < 0.001) return;\n      for (const e of entries) {")],
        "test": "tests/extensions/ai-module.test.ts",
    },
    {
        "name": "M98 agent 数量上限不检查",
        # 不检查就是无界增长：内存慢慢涨，直到某一帧全卡住
        "file": "src/extensions/ai/ai-module.ts",
        "pairs": [("      if (entries.length >= maxAgents) {", "      if (false) {")],
        "test": "tests/extensions/ai-module.test.ts",
    },
    {
        "name": "M99 构建 CLI 不清输出目录",
        # 残留的旧包会让"产物没变"变成假象，也会让"只重打一个包"变成"目录里多了一个包"
        "file": "tools/build-assets.mjs",
        "pairs": [("rmSync(outRoot, { recursive: true, force: true });\n", "")],
        "test": "tests/tools/build-assets.test.ts",
    },
    {
        "name": "M100 manifest 里写进构建时间戳",
        # 最"贴心"的一条退化：有了时间戳，"同输入同产物"永久不成立，
        # 而可复现构建是"这条产物确实是这份源码打出来的"的唯一证据
        "file": "tools/build-assets.mjs",
        "pairs": [
            (
                'writeFileSync(join(outRoot, "manifest.txt"), renderManifest(r.value.manifest), "utf8");',
                'writeFileSync(join(outRoot, "manifest.txt"), renderManifest(r.value.manifest) + `# built ${new Date().toISOString()}\\n`, "utf8");',
            )
        ],
        "test": "tests/tools/build-assets.test.ts",
    },
    {
        "name": "M101 把 .meta 也当成可发布资产",
        # .meta 是导入期输入。打进包会让"改一个导入设置"也改变玩家要下载的字节
        "file": "tools/build-assets.mjs",
        "pairs": [
            (
                'const publishable = files.filter((f) => !f.endsWith(".meta") && !f.split("/").some((s) => s.startsWith(".")));',
                'const publishable = files.filter((f) => !f.split("/").some((s) => s.startsWith(".")));',
            )
        ],
        "test": "tests/tools/build-assets.test.ts",
    },
    {
        "name": "M102 矩形向右扩展时不看是否已访问",
        # 已访问的格子被重复扩进来 ⇒ 产出的矩形互相重叠。
        # 重叠在画面上"看不出来"（后画的盖住先画的），所以必须由 overlaps 计数抓。
        "file": "src/extensions/worldgen/assemble.ts",
        "pairs": [("if (visited[i] === 1 || kinds[i] !== kind) break;", "if (kinds[i] !== kind) break;")],
        "test": "tests/extensions/assemble.test.ts",
    },
    {
        "name": "M103 矩形向下扩展时跨群系合并",
        # 只检查"已访问"不检查"同群系" ⇒ 一块矩形横跨两种地形。
        # 覆盖仍然完全、也没有重叠 —— 只有逐格比对能抓住它。
        "file": "src/extensions/worldgen/assemble.ts",
        "pairs": [("          if (visited[i] === 1 || kinds[i] !== kind) {", "          if (visited[i] === 1) {")],
        "test": "tests/extensions/assemble.test.ts",
    },
    {
        "name": "M104 标记已访问时漏掉最后一列",
        # 漏标记 ⇒ 那些格子会被下一个起点重新纳入 ⇒ 漏格/重叠同时出现。
        "file": "src/extensions/worldgen/assemble.ts",
        "pairs": [
            (
                "for (let dx = 0; dx < w; dx++) visited[(cz + dz) * width + cx + dx] = 1;",
                "for (let dx = 0; dx < w - 1; dx++) visited[(cz + dz) * width + cx + dx] = 1;",
            )
        ],
        "test": "tests/extensions/assemble.test.ts",
    },
    {
        "name": "M105 定点换世界单位用 /1000 而不是 /256",
        # 256 是 2 的幂 ⇒ 除法无舍入。换成 1000 会让坐标"差不多"，而差不多就是漂移。
        "file": "src/extensions/worldgen/assemble.ts",
        "pairs": [("node.setLocalPosition(s.x / FIXED_UNITS, s.z / FIXED_UNITS);", "node.setLocalPosition(s.x / 1000, s.z / 1000);")],
        "test": "tests/extensions/assemble.test.ts",
    },
    {
        "name": "M106 passable 写死 true（不从群系推）",
        # 海与崖都变成可通行 ⇒ 连通分量数变少。这是"冗余字段被当成常量"的典型症状。
        "file": "src/extensions/worldgen/assemble.ts",
        "pairs": [("made.value.passable = isPassable(r.kind);", "made.value.passable = true;")],
        "test": "tests/extensions/assemble.test.ts",
    },
    {
        "name": "M107 装配前不比对计划指纹",
        # 少了这一步，一个被手改过（或旧 schema）的计划会被"忠实"装配成错世界。
        "file": "src/extensions/worldgen/assemble.ts",
        "pairs": [("if (digest.value !== plan.fingerprint) {", "if (false && digest.value !== plan.fingerprint) {")],
        "test": "tests/extensions/assemble.test.ts",
    },
    {
        "name": "M108 地形节点全摊在 root 上（不挂容器）",
        # 层级是场景结构的一部分：全摊在根上之后，"哪一层是世界"只能靠名字猜。
        "file": "src/extensions/worldgen/assemble.ts",
        "pairs": [
            (
                "const node = scene.spawnImmediate(`terrain/${r.kind}`, terrainRoot.id);",
                "const node = scene.spawnImmediate(`terrain/${r.kind}`);",
            )
        ],
        "test": "tests/extensions/assemble.test.ts",
    },
    {
        "name": "M109 siteId 改用节点 id",
        # 节点 id 会随"往地图中间插一格"整体平移，siteId 不会 —— 混用就丢掉了局部性。
        "file": "src/extensions/worldgen/assemble.ts",
        "pairs": [("made.value.siteId = s.id;", "made.value.siteId = node.id;")],
        "test": "tests/extensions/assemble.test.ts",
    },
    {
        "name": "M110 不检查目标场景是否为空",
        # 往已有世界里再装配一个世界 ⇒ 两个世界的投放点 id 空间重叠，存档指向说不清。
        "file": "src/extensions/worldgen/assemble.ts",
        "pairs": [("if (scene.stats().nodes !== 1) {", "if (false) {")],
        "test": "tests/extensions/assemble.test.ts",
    },
    {
        "name": "M111 反查时重叠不计数（首写优先静默覆盖）",
        # 这是"反查工具的假绿"：重叠了但只报 kinds，重叠就会被完全掩盖。
        "file": "src/extensions/worldgen/assemble.ts",
        "pairs": [("        if (kinds[i] !== null) {", "        if (false) {")],
        "test": "tests/extensions/assemble.test.ts",
    },
    {
        "name": "M112 跳时间时把漏掉的次数补齐（连跑 count 次）",
        # 这是任务表最贵的错误：离线 8 小时回来，period=10 的任务连跑 100 次，
        # 每次都 spawn/写存档/发事件。结果是"回来一看地图被刷满"。
        "file": "src/extensions/worldgen/tasks.ts",
        "pairs": [("      st.runs += 1;", "      st.runs += count;")],
        "test": "tests/extensions/world-tasks.test.ts",
    },
    {
        "name": "M113 missed 恒报 0（跳时间发生了，但没人告诉调用方）",
        # 少跑是设计，**瞒着**不是。missed 是调用方决定"要不要补跑"的唯一依据。
        "file": "src/extensions/worldgen/tasks.ts",
        "pairs": [("          missed: count - 1,", "          missed: 0,")],
        "test": "tests/extensions/world-tasks.test.ts",
    },
    {
        "name": "M114 不校验 phase 上界（phase ≥ period 永不触发）",
        # 静默失败第一名：任务看起来配好了，实际一次都不跑。
        "file": "src/extensions/worldgen/tasks.ts",
        "pairs": [("if (!Number.isInteger(phase) || phase < 0 || phase >= t.periodTicks) {", "if (!Number.isInteger(phase) || phase < 0) {")],
        "test": "tests/extensions/world-tasks.test.ts",
    },
    {
        "name": "M115 允许 tick 倒退",
        # 回档时同一个 tick 会被执行两次 —— 而且没人知道发生过。
        "file": "src/extensions/worldgen/tasks.ts",
        "pairs": [("    if (tick < this._lastTick) {", "    if (false) {")],
        "test": "tests/extensions/world-tasks.test.ts",
    },
    {
        "name": "M116 选格不看可通行（资源刷进海里）",
        # 候选集必须过 isPassable：地形不可通行 ⇒ 玩家永远拿不到那颗资源。
        "file": "src/extensions/worldgen/tasks.ts",
        "pairs": [("      if (!isPassable(k)) continue;", "      if (false) continue;")],
        "test": "tests/extensions/world-tasks.test.ts",
    },
    {
        "name": "M117 不校验任务 id 重复",
        # 两条任务共用一个 seed ⇒ 它们会刷在同一批格子；run 计数也混在一起。
        "file": "src/extensions/worldgen/tasks.ts",
        "pairs": [("    if (seen.has(t.id)) {", "    if (false) {")],
        "test": "tests/extensions/world-tasks.test.ts",
    },
    {
        "name": "M118 跳时间后把 run 复位成 1",
        # run 记录"一共跑过几次"。复位会让诊断显示"每次跳时间都只跑了一次"，
        # 把"跑过很多次"这个事实抹掉。
        "file": "src/extensions/worldgen/tasks.ts",
        "pairs": [("      st.runs += 1;", "      st.runs = 1;")],
        "test": "tests/extensions/world-tasks.test.ts",
    },
    {
        "name": "M119 要选格却没给计划时静默返回空",
        # 静默空数组会让"资源没刷出来"看起来像"任务没跑到"，两者的修法完全不同。
        "file": "src/extensions/worldgen/tasks.ts",
        "pairs": [("    if (needsPlan && plan === undefined) {", "    if (false) {")],
        "test": "tests/extensions/world-tasks.test.ts",
    },
    {
        "name": "M120 存档量化退回十进制 3 位（装不下 1/256）",
        # 2026-10-23 的真 bug：7.26953125 存成 7.27，反推 1861.12（原本 1861）。
        # 挪了 1/2000 格，肉眼/手感都看不出，只有内容指纹与逐字节比对能发现。
        "file": "src/core/scene/scene-io.ts",
        "pairs": [("  if (!(Math.abs(v) < SAVE_SCALE_LIMIT)) return v;\n  return Math.round(v * SAVE_SCALE) / SAVE_SCALE;", "  if (!(Math.abs(v) < SAVE_SCALE_LIMIT)) return v;\n  return Math.round(v * 1000) / 1000;")],
        "test": "tests/extensions/assemble-io.test.ts",
    },
    {
        "name": "M121 地形组件的 schema 漏掉 cx 字段",
        # schema 是序列化的唯一来源：漏一个字段，save() 不写、load() 不读，
        # 读回来所有地形块都落在 (0,0) —— 而装配那侧四条判据全绿（它们只看装配）。
        "file": "src/extensions/worldgen/assemble.ts",
        "pairs": [("    cx: FieldType.Int,\n    cz: FieldType.Int,", "    cz: FieldType.Int,")],
        "test": "tests/extensions/assemble-io.test.ts",
    },
    {
        "name": "M122 去重索引只扫再生资源，不扫计划投放点",
        # 计划自带的资源已经在那格上了。只扫一侧 ⇒ 再生会盖在它上面，
        # 而叠加的两个精灵在画面上看不出来，只有 countOf 会涨。
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("    for (const marker of s.componentsOf<SiteMarker>(SITE_TYPE)) set.add(marker.cell);\n", "")],
        "test": "tests/extensions/world-task-module.test.ts",
    },
    {
        "name": "M123 完全不检查格子占用（同格反复叠刷）",
        # 这是任务模块最典型的错误：每个周期都往同一批格子叠一层。
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("          if (taken.has(cell)) {", "          if (false) {")],
        "test": "tests/extensions/world-task-module.test.ts",
    },
    {
        "name": "M124 不检查全局上限（节点数单调增长）",
        # 再生是"只增不减"的，没有上限就是一条只会涨的曲线。
        # ★ 批44 把上限的判据量从 `spawned` 换成了 `alive`（采走要能腾名额），
        #   这条变异的靶子随之下岗 —— 第一次跑 CI 就报"变异点没找到"。
        #   重新指认到同一行，不是放宽标准（M155 打的是它的反面：换回累计数）。
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("          if (alive >= maxResources) {", "          if (false) {")],
        "test": "tests/extensions/world-task-module.test.ts",
    },
    {
        "name": "M125 资源放在格子左上角而不是中心",
        # 差半格：肉眼看得出来的偏移，但"能刷出来"的判据全绿。
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("          node.value.setLocalPosition(cx + 0.5, cz + 0.5);", "          node.value.setLocalPosition(cx, cz);")],
        "test": "tests/extensions/world-task-module.test.ts",
    },
    {
        "name": "M126 stop 之后仍然刷（生命周期只做了 start）",
        # stop 的语义是"停止参与"。不检查 ⇒ 暂停/切场景后资源还在长。
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("      if (s === null || !started) return;", "      if (s === null) return;")],
        "test": "tests/extensions/world-task-module.test.ts",
    },
    {
        "name": "M127 出生点不限制在主分量里",
        # 出生在走不到的小岛上，这局白开 —— 而地图看起来完全正常。
        "file": "src/extensions/worldgen/worldgen.ts",
        "pairs": [("    if (regionOf[i] !== mainIdx) continue;", "    if (regionOf[i] < 0) continue;")],
        "test": "tests/extensions/worldgen.test.ts",
    },
    {
        "name": "M128 平局取最大下标（平局规则反了）",
        # 全可通行地图上"最宽敞"的格子往往是一整片，平局规则决定结果。
        # 取最大下标会让出生点系统性偏向地图右下角，而"同种子同世界"仍然成立 —— 所以只有专门判据能抓。
        "file": "src/extensions/worldgen/worldgen.ts",
        "pairs": [("    if (d > bestDist) {", "    if (d >= bestDist) {")],
        "test": "tests/extensions/worldgen.test.ts",
    },
    {
        "name": "M129 地图边缘不算作不可通行源",
        # 全可通行的手改地图上，所有格的距离都是 -1 ⇒ 选不出出生点（或选出第一格）。
        "file": "src/extensions/worldgen/worldgen.ts",
        "pairs": [(
            "  for (let z = 0; z < height; z++) {\n    for (let x = 0; x < width; x++) {\n      if (x !== 0 && z !== 0 && x !== width - 1 && z !== height - 1) continue;\n      const i = z * width + x;\n      if (dist[i] !== -1) continue;\n      dist[i] = 1;\n      queue.push(i);\n    }\n  }\n",
            "",
        )],
        "test": "tests/extensions/worldgen.test.ts",
    },
    {
        "name": "M131 缺帧不报错，静默跳过（画面少一类东西，日志一行 warn）",
        # 这正是"渲染模块只 warn"那个行为；本批次把它在这里升级成错误。
        # 去掉之后，一切都"成功"，只是森林里的岩石再也不会出现。
        "file": "src/extensions/render/world-visuals.ts",
        "pairs": [("    if (p.frame !== null && available.has(p.frame)) continue;", "    if (true) continue;")],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M132 幂等按「总组件数」判断：只要有一个 Sprite 就全跳过",
        # `countOf(SPRITE_TYPE) > 0` 读起来完全像是在检查"挂过没有"。
        # ★ 注意"跑两次不重复挂"这条判据**抓不住它**（第二次确实全跳过）——
        #   只有"存档里已有一半可视化"的判据能抓。
        "file": "src/extensions/render/world-visuals.ts",
        "pairs": [("    if (hasSprite(scene, p.nodeId)) {", "    if (scene.countOf(SPRITE_TYPE) > 0) {")],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M133 不幂等（同一个节点挂两个 Sprite）",
        # 半透明资源颜色深一倍，看起来像"贴图颜色不对"，而组件数只是静默翻倍。
        "file": "src/extensions/render/world-visuals.ts",
        "pairs": [("    if (hasSprite(scene, p.nodeId)) {", "    if (false) {")],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M134 pivotY = 0.5（精灵以格子中心为锚，浮在半空）",
        # 差半格。坐标没变、帧名没变、组件数没变 —— 只有字段判据能抓。
        "file": "src/extensions/render/world-visuals.ts",
        "pairs": [("      sp.pivotY = p.pivotY;", "      sp.pivotY = 0.5;")],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M135 frames 报告整个可用图集，而不是实际用到的帧",
        # 报告"失真"不会被任何渲染路径发现：它只影响"换图集时拿它对一遍"这个动作。
        "file": "src/extensions/render/world-visuals.ts",
        "pairs": [("    frames: [...used].sort(),", "    frames: [...availableFrames].sort(),")],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M136 flint 映射到图集里不存在的帧（映射表与图集的漂移）",
        # 表格写错一个字母，画面少一类；只有"每个映射值都在真图集里"那条判据能抓。
        "file": "src/extensions/render/world-visuals.ts",
        "pairs": [('  flint: "rock",', '  flint: "flint",')],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M137 未映射的种类把 undefined 打进报错信息",
        # "undefined（被 site:ancient_tree 用到）"—— 缺的是**映射**，报错却指向帧，
        # 拿到日志的人会去翻图集，而问题在映射表/版本漂移。
        "file": "src/extensions/render/world-visuals.ts",
        "pairs": [("    const key = p.frame ?? UNMAPPED_LABEL;", "    const key = String(p.frame);")],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M130 出生点放在格子左上角而不是中心",
        # 差半格。坐标仍然是整数，所以"精确"判据不会红 —— 只有位置判据能抓。
        "file": "src/extensions/worldgen/worldgen.ts",
        "pairs": [("    x: bx * FIXED_UNITS + FIXED_UNITS / 2,\n    z: bz * FIXED_UNITS + FIXED_UNITS / 2,", "    x: bx * FIXED_UNITS,\n    z: bz * FIXED_UNITS,")],
        "test": "tests/extensions/worldgen.test.ts",
    },
    {
        "name": "M138 pivotX 的符号写反（0.5 - pivot → pivot - 0.5）",
        # 照抄 pivotY 那一行时最容易犯的错。pivot=0.5 的内容完全看不出来（对称中心不动），
        # 只有"矩形地形用 pivot=0"这一类内容能抓。
        "file": "src/extensions/render/batch2d.ts",
        "pairs": [("      const cx = c.x + (0.5 - it.pivotX) * 2 * e.halfW;", "      const cx = c.x + (it.pivotX - 0.5) * 2 * e.halfW;")],
        "test": "tests/core/render.test.ts",
    },
    {
        "name": "M139 渲染模块不传 pivotX（永远 0.5，等于没有这个字段）",
        # ★ 这条第一次跑是**没被抓住**的：变异打在那段对象字面量上，而它当时在
        #   `renderFrame` 里（要 GPU 才能跑到）—— 组件判据、batch 判据全绿，画面却错位。
        #   修法不是放宽标准，而是把"搬运"抽成 `spriteToRenderItem`，让中间那一行**可测**。
        "file": "src/extensions/render/render-module.ts",
        "pairs": [("    pivotX: s.pivotX,", "    pivotX: 0.5,")],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M140 地形也用 pivotX = 0.5（整块右移半块，相邻块之间裂开）",
        # 裂缝在 2.5D 斜视角下看起来像"地表裂了"，而块数、组件数、坐标全都不变。
        "file": "src/extensions/render/world-visuals.ts",
        "pairs": [("      pivotX: 0,", "      pivotX: 0.5,")],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M141 地形块的尺寸写死 1×1（每块只盖住一格，其余全空）",
        # 块数没变、帧没变、锚点没变 —— 只是地表少了九成。
        "file": "src/extensions/render/world-visuals.ts",
        "pairs": [
            ("      width: area.w,", "      width: 1,"),
            ("      height: area.h,", "      height: 1,"),
        ],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M142 所有群系用同一个颜色（地图上没有可分的地貌）",
        # 仍然"有颜色"，仍然在 [0,1] 内 —— 只有"颜色 = BIOME_TINT[kind]"这条能抓。
        "file": "src/extensions/render/world-visuals.ts",
        "pairs": [("    const tint = BIOME_TINT[area.kind];", "    const tint = BIOME_TINT.grass;")],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M143 Sprite.pivotX 的出生默认值改成 0",
        # 新存档全部显式赋值，所以完全正常；只有**旧存档**会把所有精灵右移半格。
        "file": "src/extensions/render/sprite.ts",
        "pairs": [("  pivotX = 0.5;", "  pivotX = 0;")],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M144 组件读档时缺字段压成类型零值（schema 演化把旧档压坏）",
        # 这就是本批次改动之前的真实行为：旧档里没有 pivotX ⇒ 读成 0 ⇒ 精灵右移半格。
        "file": "src/core/scene/component.ts",
        "pairs": [("        if (self[k] !== undefined) continue; // 保留类里声明的出生默认值\n", "")],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    {
        "name": "M145 空间哈希退化成一个巨大的桶（全世界一个格）",
        # 正确性完全不受影响（query 仍然与暴力枚举一致），只是每一步退化成 O(n²)。
        # ★ 这正是"性能没有闸门时就发现不了"的那种退化：所有既有判据仍然全绿。
        # ★★ 批53（T338）改成了自动格宽，这个变异的靶子从"默认值 4"挪到了
        #    "自动格宽这条路径本身"：只改默认值会被 `resizeCellsIfNeeded()` 覆盖回去
        #    （和 M171 踩的坑同一个）。所以必须**同时**关掉自动格宽 —— 两处一起改，
        #    才是在复现"格宽不跟实体尺寸走"的旧行为。
        "file": "src/extensions/physics/physics.ts",
        "pairs": [
            ("    this.autoCell = cfg.cellSize === undefined;", "    this.autoCell = false;"),
            ("    this.cellSize = cfg.cellSize ?? AUTO_CELL_FALLBACK;", "    this.cellSize = cfg.cellSize ?? 1e9;"),
        ],
        "test": "tests/core/physics-perf.test.ts",
    },
    {
        "name": "M146 玩家放在格子**左上角**而不是中心",
        # 差半格。坐标仍然是整数，所以"能精确进存档"那条不会红 —— 只有定点恒等式能抓。
        "file": "src/extensions/worldgen/spawn.ts",
        "pairs": [(
            'scene.spawnAt("player", sp.x / FIXED_UNITS, sp.z / FIXED_UNITS)',
            'scene.spawnAt("player", (sp.x - FIXED_UNITS / 2) / FIXED_UNITS, sp.z / FIXED_UNITS)',
        )],
        "test": "tests/extensions/spawn.test.ts",
    },
    {
        "name": "M147 玩家 pivotY = 0.5（浮在半空）",
        # 与资源那一批同一个错法：坐标没变、帧没变，只有"脚踩地面"这条能抓。
        "file": "src/extensions/worldgen/spawn.ts",
        "pairs": [("    s.pivotY = 0;", "    s.pivotY = 0.5;")],
        "test": "tests/extensions/spawn.test.ts",
    },
    {
        "name": "M148 重复出生不报错（静默再造一个玩家）",
        # 两个控制器抢同一个位置，而两边的判据各自都绿。
        "file": "src/extensions/worldgen/spawn.ts",
        "pairs": [("  if (existing.length > 0) {", "  if (false) {")],
        "test": "tests/extensions/spawn.test.ts",
    },
    {
        "name": "M149 不检查 render.sprite 是否注册（造一个看不见的玩家）",
        # 节点有了、标记有了、其它系统都找得到他 —— 只是画不出来。
        "file": "src/extensions/worldgen/spawn.ts",
        "pairs": [("  if (!scene.components.has(SPRITE_TYPE)) {", "  if (false) {")],
        "test": "tests/extensions/spawn.test.ts",
    },
    {
        "name": "M150 内容指纹的排除前缀写错（排掉 world.* 而不是 render.*）",
        # 两个方向都坏：世界内容不再进指纹（内容 id 会撞），而呈现浮点进了指纹（算不出来）。
        # ★ 这条只有"全链路"判据抓得住 —— 装配那一段自己跑得好好的。
        # ★ 靶子随批88 从常量变成了**列表里的第一项**（同一条 if 的判据没变）：
        #   `game.controller` 的 4.5 也要排掉，所以单个前缀装不下了。
        #   这里只改 `render.` 那一项，语义与原来完全一致（把世界内容误排掉、把呈现浮点放回来）。
        "file": "src/extensions/worldgen/assemble.ts",
        "pairs": [('const DIGEST_EXCLUDE_PREFIXES: readonly string[] = ["render.", "game.controller"];',
                   'const DIGEST_EXCLUDE_PREFIXES: readonly string[] = ["world.", "game.controller"];')],
        "test": "tests/extensions/world-e2e.test.ts",
    },
    {
        "name": "M151 采集只释放名额、不销毁节点（砍完了树还在那儿）",
        # ★ 这是"只做两块状态里的一半"的第一种：组件数、索引、alive 全对，
        #   只有场景里的节点还在 —— 而玩家看到的就是"树砍不掉"。
        # ★ 批122：两条分支（再生 / 投放点）合并进 `settle` 闭包，缩进 6 空格、
        #   同名原文只剩一份 —— pairs 从两条降到一条（不是放宽，是原文少了一处）。
        "file": "src/extensions/worldgen/harvest.ts",
        "pairs": [
            ("      scene.destroy(nodeId);\n", ""),
        ],
        "test": "tests/extensions/harvest.test.ts",
    },
    {
        "name": "M152 采集只销毁节点、不释放名额（砍空之后再也不长）",
        # ★ 另一半。现场表现是"这片林子砍完就荒了"，没人会想到是索引没释放。
        #   只验"节点没了"的判据对这条完全无感。
        "file": "src/extensions/worldgen/harvest.ts",
        "pairs": [
            ("      opts.onRelease?.(cell);\n", ""),
        ],
        "test": "tests/extensions/harvest.test.ts",
    },
    {
        "name": "M153 不校验格子下标（-1 / 1.5 悄悄落进「这一格没东西」）",
        # 报错码从 BAD_CELL 变成 NOTHING：调用方听到的是"这儿本来就没资源"，
        # 于是永远查不出是自己算错了坐标。
        "file": "src/extensions/worldgen/harvest.ts",
        "pairs": [("  if (!isCellIndex(cell)) {", "  if (false) {")],
        "test": "tests/extensions/harvest.test.ts",
    },
    {
        "name": "M154 释放名额时 alive 不减（上限永远腾不出来）",
        # 索引删了、released 也加了 —— 看起来整套流程都跑了，就是名额没还。
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("      if (alive > 0) alive--;\n", "")],
        "test": "tests/extensions/harvest.test.ts",
    },
    {
        "name": "M155 上限仍按累计数 spawned 算（采走也刷不出来）",
        # 回归到本批之前的行为。长期运行的世界"越玩越荒"，而所有单轮判据都绿。
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("          if (alive >= maxResources) {", "          if (spawned >= maxResources) {")],
        "test": "tests/extensions/harvest.test.ts",
    },
    {
        "name": "M156 releaseCell 不删索引只减数（那一格永久被占）",
        # alive / released 全对，只有 isOccupied 是 true —— 名额还了，格子却没还。
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("      if (!taken.delete(cell)) return false;", "      if (!taken.has(cell)) return false;")],
        "test": "tests/extensions/harvest.test.ts",
    },
    {
        "name": "M157 releaseCell 在没占用的格子上也往下走（alive 减成负数）",
        # 把"没占用"的守卫去掉：重复采集同一格时 alive 会一路减，
        # 而上限判断用的正是 alive ⇒ 世界开始无限刷。
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("      if (!taken.delete(cell)) return false;", "      taken.delete(cell);")],
        "test": "tests/extensions/harvest.test.ts",
    },
    {
        "name": "M158 采集销毁后不 flush（命令排队了，节点还在场景里）",
        # ★ `harvest.test.ts` 那 9 条**抓不住**：它们查的是 `countOf`（组件集合），
        #   而 destroy 是结构性修改（走命令队列），组件已经不在了、节点还在。
        #   实际被抓住的两条都在长跑判据里，且各自的角度不同：
        #   ① 「300 轮后节点数回到基线」，② 「同格连采之后节点数不变」。
        "file": "src/extensions/worldgen/harvest.ts",
        "pairs": [
            ("      scene.flush();\n", ""),
        ],
        "test": "tests/extensions/world-soak.test.ts",
    },
    {
        "name": "M159 懒建索引时只扫计划投放点、不扫再生资源（读档后重复刷）",
        # ★ 只在"先有资源、后建索引"的顺序下暴露：装配完立刻跑任务时索引里本来就没东西，
        #   所以**新开一局**永远是对的；只有读档（资源已经在场景里）才会盖上去。
        #   这也是本批新增 `occupied` 的来源 —— 索引与账目是两套状态，要能一次对账。
        # ★ 第一次跑它**没被抓住**，两个原因叠在一起：既有的任务模块判据里没有"资源已在场景里
        #   才建索引"这条路径，而这个场景又没有别的判据在验。补在 `world-soak.test.ts` 之后才抓住。
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("    for (const res of s.componentsOf<ResourceMarker>(RESOURCE_TYPE)) set.add(res.cell);\n", "")],
        "test": "tests/extensions/world-soak.test.ts",
    },
    {
        "name": "M160 最大半径不走缓存、每次重算（O(n²·迭代) 回来了）",
        # ★ 这是本仓库真实发生过的：`maxRadiusNearby()` 的注释写着 O(1)，
        #   代码却是全场 for 循环，而缓存 `maxRange` 一直在维护、**没有任何地方读它**。
        #   毫秒抓不住（0.74 → 2.7 仍在 8ms 预算内），只有计数抓得住。
        "file": "src/extensions/physics/physics.ts",
        "pairs": [("  private maxRadiusNearby(): number {\n    return this.maxRange;\n  }",
                   "  private maxRadiusNearby(): number {\n    return this.scanMaxRange();\n  }")],
        "test": "tests/core/physics-work.test.ts",
    },
    {
        "name": "M161 reindex 走慢路径（每次遍历所有格找自己）",
        # 这条的代价与"格数"成正比，与"体数"无关 —— 现实布局下只有 ~2ms，
        # 但它会让每一次推动都付一遍 O(#格)。
        "file": "src/extensions/physics/physics.ts",
        "pairs": [("    const fast = this.cellOfBody.get(nodeId);\n    if (fast !== undefined) return fast;\n", "")],
        "test": "tests/core/physics-work.test.ts",
    },
    {
        "name": "M162 resolve 遍历所有 body（含静态体，白扫 1900 个）",
        # 正确性完全不变：静态体本来就会被 `if (b.isStatic)` 跳过。
        # 变的只是"每帧白读 1900 次"。
        "file": "src/extensions/physics/physics.ts",
        "pairs": [("      for (const id of this.dynamicIds) {", "      for (const id of this.bodies.keys()) {")],
        "test": "tests/core/physics-work.test.ts",
    },
    {
        "name": "M163 兜底分离用随机方向（同种子同操作的世界跑出不同位置）",
        # 画面上完全正常，甚至"看起来更自然"（重合的实体会朝随机方向散开）。
        # 坏的是存档比对、回放、以及任何"两次运行必须一致"的判据。
        "file": "src/extensions/physics/physics.ts",
        "pairs": [("        let nx = 1;\n        let nz = 0;",
                   "        let nx = Math.random() * 2 - 1;\n        let nz = Math.random() * 2 - 1;")],
        "test": "tests/core/physics-jitter.test.ts",
    },
    {
        "name": "M178 兜底把静态体也推（「墙」在最后一帧被挪动）",
        # T345/T346 恢复的变异。它此前**从变异表里删掉过** —— 因为"静态体不动"那条判据
        # 是弱的：兜底一对静态都没处理，静态体当然不动，推不推都绿。
        # 现在换成"夹心拓扑"（重叠真的活进兜底）+ `settleStaticPushes` 计数后才敢放回来。
        "file": "src/extensions/physics/physics.ts",
        "pairs": [("        const shareOther = oStatic ? 0 : bStatic ? 1 : 0.5;",
                   "        const shareOther = bStatic ? 1 : 0.5;")],
        "test": "tests/core/physics-jitter.test.ts",
    },
    {
        "name": "M179 兜底跳过「动态-静态」对（静态体不动，但动态体永远卡在墙里）",
        # 与 M178 互补：那条证明"静态体没被乱推"，这条证明"静态对真的被处理过"。
        # 只有后者能让 `settleStaticPushes` 变红 —— 位置终态在两种实现下可能相同
        # （D 都停在不与 B 相交处），所以这条只能靠计数抓，正是 T345 加计数的理由。
        "file": "src/extensions/physics/physics.ts",
        "pairs": [("        if (oStatic) this._settleStaticPushes++;",
                   "        if (oStatic) continue;\n        this._settleStaticPushes++;")],
        "test": "tests/core/physics-jitter.test.ts",
    },
    {
        "name": "M164 加物品不合并（砍 100 次树得到 100 堆「1 个木头」）",
        # 画面上完全正常。坏的是 `maxStacks`：第 9 次采集就报"背包满"，而玩家只捡了一种东西。
        "file": "src/extensions/inventory/inventory.ts",
        # ★ 批56 重写 `addItem`（先填满所有同种堆再开新堆）之后，旧靶点 `stackNodeOf` 已不存在。
        #   新靶点：把合并那一步的"能放多少"改成 0 ⇒ 同种物品永不合并，`maxStacks` 被瞬间吃光。
        "pairs": [("    const put = Math.min(cap - s.count, left);\n    s.count += put;\n    left -= put;",
                   "    const put = 0;\n    s.count += put;\n    left -= put;")],
        "test": "tests/extensions/inventory.test.ts",
    },
    {
        "name": "M165 取到 0 的堆叠不销毁（空壳占着名额）",
        # `countItem` 会说 0，`stacksOf` 里却有东西 —— 玩家看到"背包满了，但里面没有东西"。
        "file": "src/extensions/inventory/inventory.ts",
        "pairs": [("      if (id !== undefined) scene.destroy(id);", "      void id;")],
        "test": "tests/extensions/inventory.test.ts",
    },
    {
        "name": "M166 harvestInto 先摘再进包（背包满时资源凭空消失）",
        # ★ 最坏的一种：树真的倒了、计数自洽、玩家什么都没拿到。画面上无异常可看。
        "file": "src/extensions/inventory/harvest-into.ts",
        "pairs": [("""  // ① 先进包：满了就在这里失败，**世界没动**
  const added = addItem(scene, ownerId, peek.kind, want);
  if (!added.ok) return added;
  // ② 再摘：这一步之后资源就少了，所以它必须是最后一步
  const took = harvestAt(scene, cell, { onRelease: opts.onRelease, amount: want });""",
"""  // ① 先摘（错的顺序）
  const took = harvestAt(scene, cell, { onRelease: opts.onRelease, amount: want });
  // ② 再进包
  const added = addItem(scene, ownerId, peek.kind, want);
  if (!added.ok) return added;""")],
        "test": "tests/extensions/inventory.test.ts",
    },
    {
        "name": "M167 对角线不归一化（斜着走快 41%）",
        # 位置、输入、组件全都正常，只是"斜走更快" —— 玩家能感觉到，数值一个都不报错。
        "file": "src/extensions/input/player-controller.ts",
        "pairs": [("  return { dx: (d.dx / len) * speed * dt, dz: (d.dz / len) * speed * dt };",
                   "  return { dx: d.dx * speed * dt, dz: d.dz * speed * dt };")],
        "test": "tests/extensions/player-controller.test.ts",
    },
    {
        "name": "M168 同一个 tick 重复 poll（吞掉「按下」边缘）",
        # 一帧跑多个固定步时，第二次 poll 会把"刚按下"消费掉 —— 表现为"按一下没反应"。
        "file": "src/extensions/input/player-controller.ts",
        "pairs": [("      if (tick === lastTick) return;\n      lastTick = tick;", "      lastTick = tick;")],
        "test": "tests/extensions/player-controller.test.ts",
    },
    {
        "name": "M169 UV 的 v 多翻一次（帧高 < 图集高一半的帧整帧消失）",
        # ★ 这条是 T330 原样回放：几何、颜色、深度、UV 元数据全都对，
        #   只有"采样落在贴图的哪一行"错了。它的坏形状按帧高分布 ——
        #   帧高占满图集的看不见、占 2/3 的丢掉一部分、不超过一半的**彻底不显示**。
        #   旧判据（断言 uv.v == 1-v1）恰好把这个错误写成了契约，所以必须换判据才有靶子。
        #   ★ 2026-10-24 T288 后 `vb` 行从 `it.v1` 变成平铺版
        #   `it.v0 + (it.v1 - it.v0) * tileY` —— 靶子必须跟着走（M6 同款漂移，
        #   不跟进就会被汇总误打印成"判据是假绿"）。
        "file": "src/extensions/render/batch2d.ts",
        "pairs": [("      const va = it.v0;\n      const vb = it.v0 + (it.v1 - it.v0) * tileY;",
                   "      const va = 1 - it.v0;\n      const vb = 1 - (it.v0 + (it.v1 - it.v0) * tileY);")],
        "test": "tests/core/render.test.ts",
    },
    {
        "name": "M170 程序化图集让某一帧画到 (0,0)（帧矩形是空的，帧还在）",
        # 变异点选 rock：它有 30 行不透明内容。画到 (0,0) 之后它的矩形里
        # 一个不透明像素都没有 —— 而"帧在不在、UV 对不对、尺寸对不对"全是绿的。
        "file": "src/extensions/render/atlas.ts",
        "pairs": [('  pen.origin(at("rock").x, at("rock").y);', "  pen.origin(0, 0);")],
        "test": "tests/core/render.test.ts",
    },
    {
        "name": "M171 格宽退回写死的 4（不跟实体尺寸，候选扫描多 5 倍）",
        # 正确性一位不差：解算的是同一个世界，推的也是同一批对。
        # 变的只有"每次查询白扫多少个候选" —— 所以只有**比值判据**抓得住。
        "file": "src/extensions/physics/physics.ts",
        # ★ 变异体必须**完整复现旧行为**（关掉自动 + 默认 4）：第一次写成只关自动，
        #   结果 cellSize 落到占位值 1，比自动值 0.6 还细 —— 判据全绿，变异"没被抓住"。
        #   那不是判据松懈，是变异体没真的回到旧代码。
        "pairs": [("    this.autoCell = cfg.cellSize === undefined;\n    this.cellSize = cfg.cellSize ?? AUTO_CELL_FALLBACK;",
                   "    this.autoCell = false;\n    this.cellSize = cfg.cellSize ?? 4;")],
        "test": "tests/core/physics-perf.test.ts",
    },
    {
        "name": "M172 query 的扫描盒只按 r（边缘伸进来的实体落在盒外相邻格，静默漏掉）",
        # T338 顺带修掉的真漏格：旧默认格宽 4 太粗，撞不上；格宽变细之后立刻被
        # "query 与暴力枚举逐点一致"抓到。
        "file": "src/extensions/physics/physics.ts",
        "pairs": [("    const scanR = r + this.maxRadiusNearby();", "    const scanR = r;")],
        "test": "tests/core/physics.test.ts",
    },
    {
        "name": "M173 冲突检测形同虚设（同组共用键不报错）",
        # 症状：W 同时绑前进与后退 ⇒ 两轴抵消、人不动；或者两个动作都触发
        # （"按一下砍树也存了档"）。数据看起来完全正常。
        "file": "src/extensions/input/input-map.ts",
        "pairs": [("      if (prev.group !== spec.group) continue; // 不同组：允许（\"W 同时是 move 和 sprint\"）",
                   "      continue;")],
        "test": "tests/extensions/input-map.test.ts",
    },
    {
        "name": "M174 动作名拼错静默返回 false（按了没反应，判据全绿）",
        "file": "src/extensions/input/input-map.ts",
        "pairs": [("""      throw new Error(
        `${who}：映射表里没有动作 \"${action}\"（现有：${names.join(", ")}）—— 拼错了？`,
      );""", "      return { keys: [], group: DEFAULT_GROUP };")],
        "test": "tests/extensions/input-map.test.ts",
    },
    {
        "name": "M175 摇杆上下反了（W3C 里 y 负值是上）",
        # 只在真手柄上出现的错法：键盘一条判据都不会红。
        "file": "src/backends/input-dom/device.ts",
        "pairs": [('      if (ly < -this.deadzone) out.add(prefix + "LStickUp");\n      if (ly > this.deadzone) out.add(prefix + "LStickDown");',
                   '      if (ly < -this.deadzone) out.add(prefix + "LStickDown");\n      if (ly > this.deadzone) out.add(prefix + "LStickUp");')],
        "test": "tests/extensions/input-map.test.ts",
    },
    {
        "name": "M176 拾取不判半径（站在空地按一下，整张地图的资源都被吸走）",
        "file": "src/extensions/inventory/pickup.ts",
        "pairs": [("    if (d2 > radius * radius) continue;", "    // 半径不判了")],
        "test": "tests/extensions/pickup.test.ts",
    },
    {
        "name": "M177 remaining 恒为 0（「背包满了」与「半径没覆盖」在画面上长得一样）",
        "file": "src/extensions/inventory/pickup.ts",
        "pairs": [("    remaining: Math.max(0, cand.length - picked.length),", "    remaining: 0,")],
        "test": "tests/extensions/pickup.test.ts",
    },
    {
        "name": "M180 排序键去掉 layer（T288 收尾：地形与实体按 z 混排，draw 从 2 涨回 29）",
        # 症状分两层，两层都没有任何"数字报错"：
        #   ① 遮挡反了 —— 一块地形盖住站在它上面的角色（地形的 z 是矩形左上角，
        #      实体的 z 是格子中心，混排必然交错）；
        #   ② 性能退化 —— 瓦片页被主图集按 z 序打散，116 块地形 ⇒ 29 次 draw。
        # ★ 为什么不是 M171 那种"只改默认值"的弱靶子：layer 是排序键的**第一**优先级，
        #   整条删掉才是完整的旧行为。判据两条腿：「layer 优先于 z」抓顺序，
        #   「交错场景 draw == 2」抓段数 —— 少任何一条，另一条仍可能绿。
        "file": "src/extensions/render/batch2d.ts",
        # 批115 重新指认：sort 加了 sortZ（深度与几何分家），旧靶子第 4 行
        # `if (a.z !== b.z) ...` 不存在了；变异语义不变 —— 仍删 layer 这一**第一**优先级。
        "pairs": [("""      const la = a.layer ?? 1;
      const lb = b.layer ?? 1;
      if (la !== lb) return la - lb; // 背景先画
      // 深度与几何分家（见 RenderItem.sortZ）：世界不传 = 用 z，UI 传 0 = 只看 order。
      const za = a.sortZ ?? a.z;
      const zb = b.sortZ ?? b.z;
      if (za !== zb) return zb - za; // 远的先画""",
                   """      // 深度与几何分家（见 RenderItem.sortZ）：世界不传 = 用 z，UI 传 0 = 只看 order。
      const za = a.sortZ ?? a.z;
      const zb = b.sortZ ?? b.z;
      if (za !== zb) return zb - za; // 远的先画""")],
        "test": "tests/extensions/render-tile.test.ts",
    },
    {
        "name": "M181 缺 layer 默认成 0（旧内容一夜之间全部掉到地形背后）",
        # 比 M180 更阴：只改**缺省值**。所有显式设了 layer 的精灵照常，
        # 而旧存档 / 手搓 RenderItem / 宿主忘了设的精灵全部变成背景层 ——
        # 一帧都不显示，且没有任何报错（它们仍然"在场景里"）。
        "file": "src/extensions/render/batch2d.ts",
        "pairs": [("      const la = a.layer ?? 1;", "      const la = a.layer ?? 0;"),
                  ("      const lb = b.layer ?? 1;", "      const lb = b.layer ?? 0;")],
        "test": "tests/extensions/render-tile.test.ts",
    },
    # ---- 批56：背包面板 / 堆叠上限 / 丢弃到世界 ----
    {
        # 单堆上限形同虚设：45 个芦苇装成一堆（画面上一行写不下，
        # 且 maxStacks 再也管不住"几格"）
        "name": "M182 maxStack 不生效（每堆无限装，45 个并成一大堆）",
        "file": "src/extensions/inventory/inventory.ts",
        "pairs": [("  const cap = stackCapOf(inv);", "  const cap = Number.MAX_SAFE_INTEGER;")],
        "test": "tests/extensions/inventory.test.ts",
    },
    {
        # 名额检查被跳过：maxStacks=2 时能塞进无数堆
        # （症状与"满了"相反：永远不报 FULL，名额缓慢漏光）
        "name": "M183 开新堆前不查名额（堆数无上限，INVENTORY.FULL 永不出现）",
        "file": "src/extensions/inventory/inventory.ts",
        "pairs": [("  if (needNew > free) {", "  if (false) {")],
        "test": "tests/extensions/inventory.test.ts",
    },
    {
        # 只填第一堆同种物品：满堆 + 半堆时，明明半堆还有 30 个空位，
        # 却去开第三堆 —— 名额被白白浪费，玩家提前看到"背包满了"
        "name": "M184 合并只填第一堆（有空位的第二堆被跳过，白开新堆）",
        "file": "src/extensions/inventory/inventory.ts",
        "pairs": [("  for (const s of same) {", "  for (const s of same.slice(0, 1)) {")],
        "test": "tests/extensions/inventory.test.ts",
    },
    {
        # 放下的资源不进去重索引：下一次再生会往同一格再叠一个
        # （画面看不出 —— 两个图标叠在一起只显示上面那个，只有 countOf 会涨）
        "name": "M185 placeResource 不占格（去重索引漏一个，再生原地叠）",
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [(
            "      made.value.count = count === undefined ? yieldOf(kind) : normCount(count);\n      taken.add(cell);",
            "      made.value.count = count === undefined ? yieldOf(kind) : normCount(count);",
        )],
        "test": "tests/extensions/drop-to-world.test.ts",
    },
    {
        "name": "M186 placeResource 不查全局上限（资源数可无限涨）",
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [(
            "      if (alive >= maxResources) {\n        return err(engineError(TASK_CAP,",
            "      if (false) {\n        return err(engineError(TASK_CAP,",
        )],
        "test": "tests/extensions/drop-to-world.test.ts",
    },
    {
        # 回滚被删：放下中途撞上限时，已放下的节点留在世界里、
        # 而背包没扣 —— "世界多几个、背包没少"的复制 bug
        "name": "M187 dropIntoWorld 先出包再放置（放置失败时背包少了、世界没多）",
        # ★ 批122 重指认：堆叠后一次只放**一个**节点，"中途"这个场景不存在了，
        #   回滚循环也整段删掉了。同一条保证（失败时两边都不动）现在靠顺序撑着：
        #   「先做完可能失败的事，最后出包」。所以靶子改成把这两步对调 ——
        #   放置撞上限时就留下"背包少了、世界没多"的半份状态，症状与旧 M187 同类。
        "file": "src/extensions/inventory/drop-to-world.ts",
        "pairs": [(
            """  const placed = opts.tasks.placeResource(cell, kind, opts.bornTick, n);
  // 失败（越界/不可通行/被抢/上限）时世界没动 —— `placeResource` 的每个失败分支
  // 都在 `spawn` 之前 return，或把刚 spawn 的孤儿撤掉，不留半份。
  if (!placed.ok) return placed;
  const took = takeItem(scene, ownerId, kind, n);
  if (!took.ok) return took;""",
            """  const took = takeItem(scene, ownerId, kind, n);
  if (!took.ok) return took;
  const placed = opts.tasks.placeResource(cell, kind, opts.bornTick, n);
  if (!placed.ok) return placed;""",
        )],
        "test": "tests/extensions/drop-to-world.test.ts",
    },
    {
        # 选格不查可通行：候选格可能是水/岩，placeResource 报 BAD_TERRAIN ——
        # "丢东西"莫名失败，看起来像世界坏了，实际是选格漏了一步
        "name": "M188 findFreeCells 不查可通行（候选格可能是水，丢弃莫名失败）",
        "file": "src/extensions/inventory/drop-to-world.ts",
        # ★ 批123 重新指认：环形扫格抽成 `cellsInRing` 之后，这行从双循环内层
        #   （8 空格）挪成了单循环内层（6 空格）—— 原文只剩这一处。
        "pairs": [("      if (!isPassable(plan.kinds[cell]!)) continue;\n", "")],
        "test": "tests/extensions/drop-to-world.test.ts",
    },
    {
        # 存档里混进一个**宿主相关的值**（`performance.now()`）：Node 与浏览器的读数必然不同。
        # 这是"跨宿主逐字节"最容易在真实开发里破掉的方式 —— 给存档加个 `savedAt` 之类的时间戳，
        # 于是浏览器存的档在桌面端打开时"文件变了"（校验/去重/云同步全跟着错）。
        # 判据形态不是 node:test：它要开真浏览器，所以走 `cmd`（看退出码）。
        "name": "M189 存档头部混进 performance.now()（宿主相关值进了存档）",
        "file": "src/core/scene/scene-io.ts",
        "pairs": [
            (
                'lines.push(`{"format":${snap.format},"name":${JSON.stringify(snap.name)},"nodes":[`);',
                'lines.push(`{"format":${snap.format},"t":${performance.now()},"name":${JSON.stringify(snap.name)},"nodes":[`);',
            )
        ],
        "cmd": ["node", "tools/cross-host-save.mjs"],
        "env_exit": 2,
    },
    {
        # 感知输出不排序：决策"取第一个"就会随 scene.root.walk 的遍历序变
        # ⇒ 同种子同世界，怪物有时往左有时往右，而回放只认字节
        "name": "M190 感知结果不排序（决策随遍历序漂）",
        "file": "src/extensions/ai/perception.ts",
        "pairs": [("    out.sort(byDistance);\n", "")],
        "test": "tests/extensions/ai-perception.test.ts",
    },
    {
        # 视野过滤去掉：背后与侧后的目标也"看得见" ⇒ 怪物隔着背扑人
        "name": "M191 感知不查视野半角（背后也看得见）",
        "file": "src/extensions/ai/perception.ts",
        "pairs": [("        if (diff > halfDeg) return;\n", "")],
        "test": "tests/extensions/ai-perception.test.ts",
    },
    {
        # 记忆永不衰减：跟丢以后永远记着 ⇒ 怪物永远冲向一个早就没有东西的坐标
        "name": "M192 感知记忆不衰减（跟丢的目标永远记得）",
        "file": "src/extensions/ai/perception.ts",
        "pairs": [("        if (tick - m.seenTick > this.cfg.memoryTicks) this.memory.delete(id);\n", "")],
        "test": "tests/extensions/ai-perception.test.ts",
    },
    {
        # 迟滞失效（永远换成最优）：两个同样近的目标让人物每帧改主意，一步也走不出去
        "name": "M193 目标选择没有迟滞（每 tick 都换最优）",
        "file": "src/extensions/ai/targeting.ts",
        "pairs": [("    if (this.clearlyBetter(best, cur)) {", "    if (true) {")],
        "test": "tests/extensions/ai-perception.test.ts",
    },
    {
        # 占位可以被覆盖：三只猎狗全都扑同一只兔子，另外两只白跑
        "name": "M194 队伍占位可被后来者覆盖（全员扑同一个目标）",
        "file": "src/extensions/ai/team.ts",
        "pairs": [("    const owner = this.claims.get(targetId);\n    if (owner !== undefined && owner !== agentId) {",
                   "    const owner = this.claims.get(targetId);\n    if (false) {")],
        "test": "tests/extensions/ai-team.test.ts",
    },
    {
        # 队员列表不排序：宿主驱动顺序取决于插入序 ⇒ 回放/存档一改插入序就换行为
        "name": "M195 队伍成员列表不排序（驱动顺序随插入序变）",
        "file": "src/extensions/ai/team.ts",
        "pairs": [("    return out.sort((a, b) => a - b);", "    return out;")],
        "test": "tests/extensions/ai-team.test.ts",
    },
    {
        # 闭包退化成"目录里所有资产"：没人引用的草稿也会被发布
        # ⇒ 往资产目录丢一张草稿，线上包就变了（出口判据 ① 直接失效）
        "name": "M196 构建不按入口闭包取资产（目录全收）",
        "file": "src/extensions/build/publish.ts",
        "pairs": [("  const closure = [...reachable].sort();", "  const closure = [...byId.keys()].sort();")],
        "test": "tests/extensions/build-cli.test.ts",
    },
    {
        # 包名不用内容 hash：改一个资产整批包名都变 ⇒ CDN 缓存全失效，"增量"只剩说法
        "name": "M197 包名不用内容 hash（改一个资产整批换名）",
        "file": "src/extensions/build/publish.ts",
        "pairs": [("    const h = hashBytes(bytes);\n    bundles.set(h, bytes);",
                   "    const h = `b${String(manifestBundles.length)}`;\n    bundles.set(h, bytes);")],
        "test": "tests/extensions/build-cli.test.ts",
    },
    {
        # 写盘不先比字节：内容没变也重写 ⇒ 时间戳变、"同样输入同样产物"没法核对
        "name": "M198 构建写盘不比对（内容没变也重写）",
        "file": "tools/build.ts",
        "pairs": [("    if (old.ok && old.value.length === bytes.length && old.value.every((b, i) => b === bytes[i])) {",
                   "    if (false) {")],
        "test": "tests/extensions/build-cli.test.ts",
    },
    {
        # 切角禁令去掉：怪物从两块礁石的斜缝里穿过去 ⇒ "看得见连通、走不通"的地形变成捷径
        "name": "M199 导航允许切角（礁石斜缝可以穿）",
        "file": "src/extensions/nav/nav-grid.ts",
        "pairs": [("      if (!this.isWalkable(cx + dx, cz) || !this.isWalkable(cx, cz + dz)) return -1;",
                   "      if (false) return -1;")],
        "test": "tests/extensions/nav-grid.test.ts",
    },
    {
        # 启发式恒 0：A* 退化成 Dijkstra —— 路还对，但每帧开销放大一个量级
        # （这条专门钉住"展开数"，因为代价判据在退化后仍然是绿的）
        "name": "M200 启发式恒为 0（A* 退化成 Dijkstra）",
        "file": "src/extensions/nav/nav-grid.ts",
        "pairs": [("      return STRAIGHT_COST * (dx + dz) + (DIAGONAL_COST - 2 * STRAIGHT_COST) * Math.min(dx, dz);",
                   "      return 0;")],
        "test": "tests/extensions/nav-grid.test.ts",
    },
    {
        # 连通分量用"8 邻接但不查切角"：于是分量说通、寻路说没路 —— 两份规则分叉
        "name": "M201 连通分量不查切角（分量说通、寻路说没路）",
        "file": "src/extensions/nav/nav-grid.ts",
        "pairs": [("""        const cx = this.cellX(cur);
        const cz = this.cellZ(cur);
        for (const [dx, dz] of DIRS) {
          const n = this.neighborOf(cx, cz, dx, dz);""",
                   """        const cx = this.cellX(cur);
        const cz = this.cellZ(cur);
        for (const [dx, dz] of DIRS) {
          const n0 = this.indexOf(cx + dx, cz + dz);
          const n = n0 >= 0 && this.mask[n0] === 1 ? n0 : -1;""")],
        "test": "tests/extensions/nav-grid.test.ts",
    },
    {
        # 起终点不吸附：起点在水里也照算 ⇒ 结果里从不说"其实走不到你指的那一格"
        "name": "M202 起终点不可站时不吸附（静默从水里出发）",
        "file": "src/extensions/nav/nav-grid.ts",
        "pairs": [("    if (this.mask[start] !== 1) {", "    if (false) {")],
        "test": "tests/extensions/nav-grid.test.ts",
    },
    {
        # 最近格取"扫描到的第一个"：于是"被推到海里的怪回哪块岸"取决于扫描方向
        "name": "M203 最近可站格取扫描序第一个（不是最近的）",
        "file": "src/extensions/nav/nav-grid.ts",
        "pairs": [("""          const d2 = dx * dx + dz * dz;
          if (d2 < bestD2 || (d2 === bestD2 && i < best)) {
            best = i;
            bestD2 = d2;
          }""",
                   """          if (best < 0) best = i;""")],
        "test": "tests/extensions/nav-grid.test.ts",
    },
    {
        # 剩余距离不结转：每个路点末尾把预算丢掉 ⇒ 斜走段比直走段慢
        "name": "M204 行走不结转剩余距离（路点越密走得越慢）",
        "file": "src/extensions/nav/move-along.ts",
        "pairs": [("      budget -= d;", "      budget = 0;")],
        "test": "tests/extensions/nav-move.test.ts",
    },
    {
        # 每 tick 都重算路径：站在目标上也一直跑 A* ⇒ 无事可做时 CPU 最忙
        "name": "M205 每 tick 都重算路径（到达也不消停）",
        "file": "src/extensions/ai/move.ts",
        "pairs": [("        if (goal !== m.goalCell || m.path.length === 0) {", "        if (true) {")],
        "test": "tests/extensions/ai-move.test.ts",
    },
    {
        # 不可达不退避：目标在海对面时每 tick 一次失败算路（二十只怪 = 二十倍开销）
        "name": "M206 目标不可达不退避（每 tick 都重算一遍失败的路）",
        "file": "src/extensions/ai/move.ts",
        "pairs": [("        if (goal === m.failCell && tick < m.retryTick) {", "        if (false) {")],
        "test": "tests/extensions/ai-move.test.ts",
    },
    {
        # 卡住没有出口：路点走不到就永远等 ⇒ 怪物定格，而"他在朝目标移动"每帧都成立
        "name": "M207 卡住不丢路径（永远等一个不会变的路点）",
        "file": "src/extensions/ai/move.ts",
        "pairs": [("          if (m.stuckTicks >= stuckLimit) {", "          if (false) {")],
        "test": "tests/extensions/ai-move.test.ts",
    },
    {
        # 不看射程：隔山打牛也掉血 —— 而血掉得不多，看起来像"伤害偏小"
        "name": "M208 攻击不检查射程（隔着半张地图打）",
        "file": "src/extensions/combat/attack.ts",
        "pairs": [("  if (dist2 > atk.range * atk.range) {", "  if (false) {")],
        "test": "tests/extensions/combat-attack.test.ts",
    },
    {
        # 不看冷却：一只怪一 tick 打十几下 —— 数值上"能打死"，节奏上完全不对
        "name": "M209 攻击不检查冷却（一 tick 打好几下）",
        "file": "src/extensions/combat/attack.ts",
        "pairs": [("  if (checkCd && tick - atk.lastHitTick < atk.cooldownTicks) {", "  if (false) {")],
        "test": "tests/extensions/combat-attack.test.ts",
    },
    {
        # 血量不夹到 0：血量能变负 ⇒ 不同平台上"死了没有"开始分叉（整数也能负数）
        "name": "M210 血量不夹到 0（可以变成负数）",
        "file": "src/extensions/combat/health.ts",
        "pairs": [("  const after = Math.max(0, before - amount);", "  const after = before - amount;")],
        "test": "tests/extensions/combat-health.test.ts",
    },
    {
        # 打尸体不报错：静默成功 ⇒ "AI 锁着死目标"永远暴露不出来
        "name": "M211 打已归零的目标不报错（静默成功）",
        "file": "src/extensions/combat/health.ts",
        "pairs": [("""  if (isDead(h)) {
    return err(
      engineError(COMBAT_TARGET_DEAD, `节点 ${String(targetId)} 已经归零（hp=${String(h.hp)}）—— 打尸体通常是目标选择出错`),""",
                   """  if (false) {
    return err(
      engineError(COMBAT_TARGET_DEAD, `节点 ${String(targetId)} 已经归零（hp=${String(h.hp)}）—— 打尸体通常是目标选择出错`),""")],
        "test": "tests/extensions/combat-health.test.ts",
    },
    {
        # 击杀不销毁：目标血归零但还站在那儿 ⇒ 攻击者会一直锁定它（每 tick 报 NO_TARGET）
        "name": "M212 击杀后不销毁节点（尸体继续站着）",
        "file": "src/extensions/combat/combat-module.ts",
        "pairs": [("        if (destroyOnKill) {", "        if (false) {")],
        "test": "tests/extensions/combat-world.test.ts",
    },
    {
        # 负数伤害当治疗用：漏一个 `<= 0` 就能"打自己回血"
        "name": "M213 允许负数伤害（负伤害变成回血）",
        "file": "src/extensions/combat/health.ts",
        "pairs": [("""  if (!Number.isInteger(amount) || amount <= 0) {
    return err(
      engineError(COMBAT_BAD_AMOUNT, `伤害必须是正整数，收到 ${String(amount)}（小数会让"死了没有"取决于累加次序）`),""",
                   """  if (!Number.isInteger(amount)) {
    return err(
      engineError(COMBAT_BAD_AMOUNT, `伤害必须是正整数，收到 ${String(amount)}（小数会让"死了没有"取决于累加次序）`),""")],
        "test": "tests/extensions/combat-health.test.ts",
    },
    {
        # 三道 hash 里最容易漏的一道：包 hash 是"内容寻址"的地基，
        # 不验的话 CDN 回一个截断/旧版本文件也能"解析成功"。
        "name": "M214 读取时不校验包 hash（截断的包也能解析成功）",
        "file": "src/extensions/build/loader.ts",
        "pairs": [("  if (expectedHash !== undefined) {", "  if (false) {")],
        "test": "tests/extensions/build-loader.test.ts",
    },
    {
        # 只验包 hash 抓不到"部署时 manifest 落后一版" —— 这条是最常见的线上故障。
        "name": "M215 读取时不校验资产 hash（manifest 与包不配套也放行）",
        "file": "src/extensions/build/loader.ts",
        "pairs": [("      if (got !== want) {", "      if (false) {")],
        "test": "tests/extensions/build-loader.test.ts",
    },
    {
        # 校验用的基准本身可写 ⇒ 校验只是仪式：改 manifest 就能让资产校验永远成立。
        "name": "M216 不校验 manifest 自身 hash（改 manifest 免费绕过资产校验）",
        "file": "src/extensions/build/loader.ts",
        "pairs": [("  if (rehash.value !== manifest.hash) {", "  if (false) {")],
        "test": "tests/extensions/build-loader.test.ts",
    },
    {
        # 首屏流量会乘以资产数，而画面上完全看不出来。
        "name": "M217 reader 不缓存包（每个资产各取一次包）",
        "file": "src/extensions/build/loader.ts",
        "pairs": [("    const hit = cache.get(hash);\n    if (hit !== undefined) {", "    const hit = cache.get(hash);\n    if (false) {")],
        "test": "tests/extensions/build-loader.test.ts",
    },
    {
        # 面板行序随点击序变 ⇒ 点第三个时整行重排，人点不到想点的那一行。
        "name": "M218 选中集 ids 不排序（面板行序随点击顺序跳）",
        "file": "src/extensions/editor/selection.ts",
        "pairs": [("    return [...this.set].sort((a, b) => a - b);", "    return [...this.set];")],
        "test": "tests/extensions/editor-selection.test.ts",
    },
    {
        # primary 悬空 ⇒ 右侧面板显示着上一轮的内容，而标题写着"未选中"。
        "name": "M219 toggle 掉 primary 后不回落（primary 悬空到已删 id）",
        "file": "src/extensions/editor/selection.ts",
        "pairs": [("      if (this.primaryId === id) this.primaryId = this.lowest();", "      if (this.primaryId === id && false) this.primaryId = this.lowest();")],
        "test": "tests/extensions/editor-selection.test.ts",
    },
    {
        "name": "M220 prune 之后 primary 不回落（选中项消失了面板还显示它）",
        "file": "src/extensions/editor/selection.ts",
        "pairs": [("    if (this.primaryId !== null && !this.set.has(this.primaryId)) this.primaryId = this.lowest();", "    if (false) this.primaryId = this.lowest();")],
        "test": "tests/extensions/editor-selection.test.ts",
    },
    {
        # 插入序在"销毁后重建/拖拽换父"之后与 id 序不一致 ⇒ 两次刷新长得不一样。
        "name": "M221 场景树子节点不按 id 升序（用插入序）",
        "file": "src/extensions/editor/outline.ts",
        "pairs": [("      const sorted = [...n.children].sort((a, b) => a.id - b.id);", "      const sorted = [...n.children];")],
        "test": "tests/extensions/editor-outline.test.ts",
    },
    {
        # 静默取整之后，人以为自己在设 3.5，实际值 3 已经写进去了。
        "name": "M222 Int 字段接受小数（静默取整）",
        "file": "src/extensions/editor/property-model.ts",
        "pairs": [("      if (n === null || !Number.isInteger(n)) return bad(type, raw, \"整数（3.5 不会变成 3）\");", "      if (n === null) return bad(type, raw, \"整数（3.5 不会变成 3）\");")],
        "test": "tests/extensions/editor-props.test.ts",
    },
    {
        # 校验失败也写 ⇒ 面板"一边打一边刷"时留下半改状态。
        "name": "M223 属性校验失败也写入（脏值进组件）",
        "file": "src/extensions/editor/property-model.ts",
        "pairs": [("  if (!c.ok) return c;\n  const bag = comp as unknown as Record<string, unknown>;", "  if (!c.ok && false) return c;\n  const bag = comp as unknown as Record<string, unknown>;")],
        "test": "tests/extensions/editor-props.test.ts",
    },
    {
        # 暂停 10 秒再播放，恢复的那一帧会"跳"一下。
        "name": "M224 PIE 暂停时仍累积（恢复时补跑暂停期）",
        "file": "src/extensions/editor/pie.ts",
        "pairs": [("      // 见 ①：暂停中不累积\n      this.accTicks = 0;", "      // 见 ①：暂停中不累积\n      this.accTicks += (dtSec > 0 ? dtSec : 0) * this.hz;")],
        "test": "tests/extensions/editor-pie.test.ts",
    },
    {
        # 点了单步就等于点了播放，而按钮上写的还是"单步"。
        "name": "M225 单步之后不回暂停（单步变成播放）",
        "file": "src/extensions/editor/pie.ts",
        "pairs": [("    this.pendingTicks = Math.min(this.pendingTicks + k, MAX_PENDING);\n    this.playing = false;", "    this.pendingTicks = Math.min(this.pendingTicks + k, MAX_PENDING);")],
        "test": "tests/extensions/editor-pie.test.ts",
    },
    {
        # 卡一帧跑 15 tick ⇒ 世界"瞬移"，而人只会觉得"刚才卡了一下"。
        "name": "M226 PIE 单帧不夹 tick（掉帧后连跑）",
        "file": "src/extensions/editor/pie.ts",
        "pairs": [("      if (due > this.maxStepTicks) {", "      if (false) {")],
        "test": "tests/extensions/editor-pie.test.ts",
    },
    {
        # 144fps 下 1/144×30 = 0.20833333333333334，累满 1 秒只得 29.999999999999996。
        # （最初写成"60fps 掉一半"是错的：1/60×30 恰好 0.5，60fps 测不出来。）
        "name": "M227 PIE 累积器去掉浮点容差（144fps 少一个 tick）",
        "file": "src/extensions/editor/pie.ts",
        "pairs": [("      const due = Math.floor(this.accTicks + EPS);", "      const due = Math.floor(this.accTicks);")],
        "test": "tests/extensions/editor-pie.test.ts",
    },
    {
        "name": "M228 单步排队不设上限（误输入卡死主线程）",
        "file": "src/extensions/editor/pie.ts",
        "pairs": [("    this.pendingTicks = Math.min(this.pendingTicks + k, MAX_PENDING);", "    this.pendingTicks = this.pendingTicks + k;")],
        "test": "tests/extensions/editor-pie.test.ts",
    },
    {
        # 页面级判据（不带 node:test）：改 pie.ts 要**重新构建**才上页面，
        # 所以走 `--build`；判输赢看退出码（0 通过 / 1 真失败 / 2 环境缺失）。
        "name": "M229 PIE 的 pause 不置暂停（点了暂停世界还在跑）",
        "file": "src/extensions/editor/pie.ts",
        "pairs": [("  pause(): void {\n    this.playing = false;", "  pause(): void {")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M230 编辑器单步每个 tick 跑两次（单步按钮翻倍）",
        "file": "src/editor-entry.ts",
        # 批92：靶子从单行 for 改成块首 —— 循环体里多了一句"喂一次位置"（autoPortal），
        # 语义没变（单步仍然每个 tick 跑一次 frame），所以指认到 `for` 那一行即可。
        "pairs": [("      for (let i = 0; i < k; i++) {", "      for (let i = 0; i < k * 2; i++) {")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    # ---- 批65：阵营与友伤 + 击杀战利品
    {
        "name": "M231 attack 不检查友伤（自己人照样砍）",
        "file": "src/extensions/combat/attack.ts",
        "pairs": [('    if (stance === "ally" && opts.friendlyFire !== true) {', "    if (false) {")],
        "test": "tests/extensions/combat-faction.test.ts",
    },
    {
        "name": "M232 setStance 只写一边（对方不还手）",
        "file": "src/extensions/combat/faction.ts",
        "pairs": [("    this.put(a, b, stance);\n    this.put(b, a, stance);", "    this.put(a, b, stance);")],
        "test": "tests/extensions/combat-faction.test.ts",
    },
    {
        "name": "M233 同队不算盟友（队友互砍）",
        "file": "src/extensions/combat/faction.ts",
        "pairs": [('    if (a.length > 0 && a === b) return "ally";', '    if (false) return "ally";')],
        "test": "tests/extensions/combat-faction.test.ts",
    },
    {
        "name": "M234 战利品装不下也算发放成功（肉凭空消失）",
        "file": "src/extensions/combat/loot.ts",
        "pairs": [
            (
                "    const r = addItem(scene, ownerId, e.kind, e.count);\n    if (r.ok) {",
                "    const r = addItem(scene, ownerId, e.kind, e.count);\n    if (true) {",
            )
        ],
        "test": "tests/extensions/combat-loot.test.ts",
    },
    {
        "name": "M235 战利品按配表顺序发（不按 kind 升序 ⇒ 存档里格子顺序会变）",
        "file": "src/extensions/combat/loot.ts",
        "pairs": [("  out.sort((x, y) => (x.kind < y.kind ? -1 : x.kind > y.kind ? 1 : 0));", "  void out.sort;")],
        "test": "tests/extensions/combat-loot.test.ts",
    },
    {
        "name": "M236 配表里重复 kind 覆盖而不相加（少发一份）",
        "file": "src/extensions/combat/loot.ts",
        "pairs": [("    merged.set(e.kind, (merged.get(e.kind) ?? 0) + e.count);", "    merged.set(e.kind, e.count);")],
        "test": "tests/extensions/combat-loot.test.ts",
    },
    {
        "name": "M237 onKill 把 killer 传成 target（战利品发错人）",
        "file": "src/extensions/combat/combat-module.ts",
        "pairs": [("        opts.onKill?.(target, node.id, tick);", "        opts.onKill?.(target, target, tick);")],
        "test": "tests/extensions/combat-loot.test.ts",
    },
    # ---- 批66：生物群 + 真后端的「传了 ≠ 用了」那一类
    # ★ 为什么这一组要落在**后端**而不是渲染模块：批66 的阻塞项就是"渲染模块传对了
    #   `firstIndex`、null 后端记下来了、判据全绿，而 webgl2 把它丢在地上"。
    #   缺陷在"用了没"，判据在"传了什么" —— 中间的洞只能在后端那一层补。
    {
        "name": "M238 webgl2 的 drawElements 永远从索引 0 开始（多段绘制重画第一段 ⇒ 地形盖住一切）",
        "file": "src/backends/gfx-webgl2/device.ts",
        "pairs": [
            (
                "      this.gl.drawElements(mode, batch.indexCount, GL.UNSIGNED_SHORT, firstIndex * 2);",
                "      this.gl.drawElements(mode, batch.indexCount, GL.UNSIGNED_SHORT, 0);",
            )
        ],
        "test": "tests/contract/webgl2.test.ts",
    },
    {
        "name": "M239 管线的 blend 不落到 GL（不透明/叠加/预乘全退化成 Alpha）",
        "file": "src/backends/gfx-webgl2/device.ts",
        "pairs": [("    this.applyBlend(rec.meta.blend as number | undefined);", "    this.applyBlend(undefined);")],
        "test": "tests/contract/webgl2.test.ts",
    },
    {
        "name": "M240 管线的 topology 不落到 draw 的 mode（三角带被当独立三角画）",
        "file": "src/backends/gfx-webgl2/device.ts",
        "pairs": [
            (
                "    const mode = (pipe.meta.topology ?? Topology.Triangles) === Topology.TriangleStrip",
                "    const mode = (pipe.meta.topology ?? Topology.Triangles) === -1",
            )
        ],
        "test": "tests/contract/webgl2.test.ts",
    },
    {
        "name": "M241 和平生物（damage=0）也挂攻击组件 ⇒ 兔子会咬人",
        "file": "src/extensions/mobs/spawn-mob.ts",
        "pairs": [("  if (tpl.damage > 0) attached.push([ATTACKER_TYPE, attacker]);", "  if (true) attached.push([ATTACKER_TYPE, attacker]);")],
        "test": "tests/extensions/mobs.test.ts",
    },
    {
        "name": "M242 本能不过滤友军（猎狗互相咬）",
        "file": "src/extensions/mobs/mob-brain.ts",
        "pairs": [('          if (this.o.factions.stanceOf(me, other) === "ally") continue;', "          if (false) continue;")],
        "test": "tests/extensions/mob-brain.test.ts",
    },
    {
        "name": "M243 漫游用 Math.random（不再是谁来问都一样的纯函数）",
        "file": "src/extensions/mobs/mob-brain.ts",
        "pairs": [("    let h = mix32(this.o.seed, agentId, epoch);", "    let h = (Math.random() * 0xffffffff) >>> 0;")],
        "test": "tests/extensions/mob-brain.test.ts",
    },
    {
        "name": "M244 大脑缓存不按 id 存（同一 tick 所有生物共用一个决定）",
        "file": "src/extensions/mobs/mob-brain.ts",
        "pairs": [
            ("    const hit = this.cache.get(agentId);", "    const hit = this.cache.get(0);"),
            ("    this.cache.set(agentId, d);", "    this.cache.set(0, d);"),
        ],
        "test": "tests/extensions/mob-brain.test.ts",
    },
    {
        "name": "M245 onKill 不发战利品（打了白打）",
        "file": "src/extensions/mobs/mob-world.ts",
        # ★ 批123 重新指认：旁表 `lootOf.get()` 换成实体组件 `lootOfNode()`，
        #   读不出来要报错、读出来可能是 null（没有表）—— 靶子改成那句 null 判空。
        "pairs": [("          if (loot === null) return;", "          if (true) return;")],
        "test": "tests/extensions/mob-world.test.ts",
    },
    {
        "name": "M246 击杀之后不清名单（stats.mobs 滞后，打死一只还报原来那个数）",
        "file": "src/extensions/mobs/mob-world.ts",
        # ★ 批126 重新指认：原来指的是 `prune();\n      syncBodies();` 那两行，
        #   而 `respawnPrey(tick);` 现在插在中间（顺序有意义：补出来的那只必须在
        #   `syncBodies` 之前进名单，否则它要等下一拍才有体）。
        #   要变异的东西没变 —— "尾部不再清名单"，所以只打 `prune();` 这一行，
        #   把 `respawnPrey` / `syncBodies` 留着：否则这条会同时证明两件事，
        #   红的时候分不清是哪一个坏了。
        "pairs": [(
            "      prune();\n      // ★ 顺序：先 prune",
            "      void 0;\n      // ★ 顺序：先 prune",
        )],
        "test": "tests/extensions/mob-world.test.ts",
    },
    # ---- 批67：饥饿与进食
    {
        "name": "M247 feed 不夹上限（饱食能超过 max）",
        "file": "src/extensions/survival/hunger.ts",
        "pairs": [("  const after = Math.min(h.max, before + nutrition);", "  const after = before + nutrition;")],
        "test": "tests/extensions/hunger.test.ts",
    },
    {
        "name": "M248 drain 不夹 0（饱食能变成负数）",
        "file": "src/extensions/survival/hunger.ts",
        "pairs": [("  const after = Math.max(0, before - amount);", "  const after = before - amount;")],
        "test": "tests/extensions/hunger.test.ts",
    },
    {
        "name": "M249 eat 不判满（吃饱了还能吃，把肉吃掉且什么也不涨）",
        "file": "src/extensions/survival/food.ts",
        "pairs": [("  if (h.value >= h.max) {", "  if (false) {")],
        "test": "tests/extensions/food.test.ts",
    },
    {
        "name": "M250 eat 允许死人吃（尸体能给自己回血）",
        "file": "src/extensions/survival/food.ts",
        "pairs": [("  if (health !== undefined && isDead(health)) {", "  if (false) {")],
        "test": "tests/extensions/food.test.ts",
    },
    {
        "name": "M251 食物表不校验 nutrition（0 与小数都能进表）",
        "file": "src/extensions/survival/food.ts",
        "pairs": [("    if (!Number.isInteger(n) || (n as number) <= 0) {", "    if (n === undefined) {")],
        "test": "tests/extensions/food.test.ts",
    },
    {
        "name": "M252 饱食衰减从 tick 0 就开始（跑 30 tick 掉 2 点）",
        "file": "src/extensions/survival/survival-module.ts",
        "pairs": [("        if (tick > 0 && tick % decayEvery === 0 && h.value > 0) {", "        if (tick % decayEvery === 0 && h.value > 0) {")],
        "test": "tests/extensions/survival-module.test.ts",
    },
    {
        "name": "M253 饿死时顺手销毁节点（玩家一饿死连背包一起消失）",
        "file": "src/extensions/survival/survival-module.ts",
        "pairs": [
            (
                "          options.onStarveDeath?.(node.id, tick);",
                "          s.destroy(node.id);\n          s.flush();\n          options.onStarveDeath?.(node.id, tick);",
            )
        ],
        "test": "tests/extensions/survival-module.test.ts",
    },
    {
        "name": "M254 craft 跳过缺料预检（材料少了东西没做出来，还报成别的错）",
        "file": "src/extensions/crafting/recipe.ts",
        "pairs": [("  if (missing.length > 0) {", "  if (false) {")],
        "test": "tests/extensions/crafting.test.ts",
    },
    {
        "name": "M255 产物放不下不回滚（材料变空气）",
        "file": "src/extensions/crafting/recipe.ts",
        "pairs": [
            (
                "    for (const back of consumed) addItem(scene, ownerId, back.kind, back.count);\n    return err(\n      engineError(\n        RECIPE_NO_SPACE,",
                "    return err(\n      engineError(\n        RECIPE_NO_SPACE,",
            )
        ],
        "test": "tests/extensions/crafting.test.ts",
    },
    {
        "name": "M256 配方 id 重复不报（主键悄悄变重复）",
        "file": "src/extensions/crafting/recipe.ts",
        "pairs": [("    if (seen.has(id)) {", "    if (false) {")],
        "test": "tests/extensions/crafting.test.ts",
    },
    {
        "name": "M257 inputs 空数组放过（做出不需要材料的产物）",
        "file": "src/extensions/crafting/recipe.ts",
        "pairs": [("    if (!Array.isArray(rawIn) || rawIn.length === 0) {", "    if (!Array.isArray(rawIn)) {")],
        "test": "tests/extensions/crafting.test.ts",
    },
    {
        "name": "M258 count 允许 0（等价于不需要材料）",
        "file": "src/extensions/crafting/recipe.ts",
        "pairs": [("  if (!Number.isInteger(o.count) || (o.count as number) <= 0) {", "  if (!Number.isInteger(o.count)) {")],
        "test": "tests/extensions/crafting.test.ts",
    },
    {
        "name": "M259 firstCraftable 倒序遍历（表序不再等于优先级）",
        "file": "src/extensions/crafting/recipe.ts",
        "pairs": [("  for (const r of recipes) {\n    if (missingFor", "  for (const r of [...recipes].reverse()) {\n    if (missingFor")],
        "test": "tests/extensions/crafting.test.ts",
    },
    {
        "name": "M260 一次 craft 产两份（产物数量不是配方写的数）",
        "file": "src/extensions/crafting/recipe.ts",
        "pairs": [
            (
                "  const added = addItem(scene, ownerId, recipe.output.kind, recipe.output.count);",
                "  const added = addItem(scene, ownerId, recipe.output.kind, recipe.output.count * 2);",
            )
        ],
        "test": "tests/extensions/crafting.test.ts",
    },
    {
        "name": "M261 闪完还原成白色（尸体/灰精灵被洗白）",
        "file": "src/extensions/render/feedback.ts",
        "pairs": [
            (
                "  sprite.r = feed.baseR;\n  sprite.g = feed.baseG;\n  sprite.b = feed.baseB;\n  sprite.a = feed.baseA;",
                "  sprite.r = 1;\n  sprite.g = 1;\n  sprite.b = 1;\n  sprite.a = 1;",
            )
        ],
        "test": "tests/extensions/feedback.test.ts",
    },
    {
        "name": "M262 每次 flash 都重新抓基色（连挨几下之后颜色漂到红）",
        "file": "src/extensions/render/feedback.ts",
        "pairs": [("  if (!extended) {\n    feed.baseR = sprite.r;", "  if (true) {\n    feed.baseR = sprite.r;")],
        "test": "tests/extensions/feedback.test.ts",
    },
    {
        "name": "M263 重复触发累加时长（连击时闪得越来越久）",
        "file": "src/extensions/render/feedback.ts",
        "pairs": [("  feed.flashTicks = Math.max(feed.flashTicks, ticks);", "  feed.flashTicks += ticks;")],
        "test": "tests/extensions/feedback.test.ts",
    },
    {
        "name": "M264 还原不校验「还是闪色」（把宿主后来的改动盖回去）",
        "file": "src/extensions/render/feedback.ts",
        "pairs": [
            (
                "  if (sprite.r !== FLASH_R || sprite.g !== FLASH_G || sprite.b !== FLASH_B) return false;\n",
                "",
            )
        ],
        "test": "tests/extensions/feedback.test.ts",
    },
    {
        "name": "M265 到期只清倒计时不还原（精灵永远停在闪色上）",
        "file": "src/extensions/render/feedback.ts",
        "pairs": [("            else if (restoreTint(s, node.id)) restored++;", "            else restored++;")],
        "test": "tests/extensions/feedback.test.ts",
    },
    {
        "name": "M266 punch 到期还原成「拉宽后的尺寸」（越打越宽）",
        "file": "src/extensions/render/feedback.ts",
        "pairs": [
            (
                "  sprite.width = feed.baseW;\n  sprite.height = feed.baseH;\n  return true;",
                "  sprite.width = feed.baseW * PUNCH_W;\n  sprite.height = feed.baseH;\n  return true;",
            )
        ],
        "test": "tests/extensions/feedback.test.ts",
    },
    {
        "name": "M267 onHit 的 applied 用了攻击力（打死 2 血的东西显示 -3）",
        "file": "src/extensions/combat/combat-module.ts",
        "pairs": [("          applied: r.value.report.applied,", "          applied: atk.damage,")],
        "test": "tests/extensions/combat-onhit.test.ts",
    },
    {
        "name": "M268 精灵没了也计入 restored（假装还原成功）",
        "file": "src/extensions/render/feedback.ts",
        "pairs": [
            (
                "            if (node.get<Sprite>(SPRITE_TYPE) === undefined) orphaned++;\n            else if (restoreTint(s, node.id)) restored++;",
                "            if (restoreTint(s, node.id)) restored++;\n            else orphaned++;",
            )
        ],
        "test": "tests/extensions/feedback.test.ts",
    },
    {
        "name": "M269 仇恨取最大值而不是累加（打三下等于打一下）",
        "file": "src/extensions/combat/threat.ts",
        "pairs": [
            (
                "    row.set(attackerId, { amount: (prev?.amount ?? 0) + amount, since: tick });",
                "    row.set(attackerId, { amount: Math.max(prev?.amount ?? 0, amount), since: tick });",
            )
        ],
        "test": "tests/extensions/threat.test.ts",
    },
    {
        "name": "M270 平手时取大 id（结果取决于 id 而不是规则）",
        "file": "src/extensions/combat/threat.ts",
        "pairs": [("(r.amount === bestAmount && bestId !== null && attackerId < bestId)", "(r.amount === bestAmount && bestId !== null && attackerId > bestId)")],
        "test": "tests/extensions/threat.test.ts",
    },
    {
        "name": "M271 过期边界写成 >（少记一个 tick）",
        "file": "src/extensions/combat/threat.ts",
        "pairs": [("      if (tick - r.since >= this.decayTicks) {", "      if (tick - r.since > this.decayTicks) {")],
        "test": "tests/extensions/threat.test.ts",
    },
    {
        "name": "M272 忘光了也不删目标（targets 只涨不跌）",
        "file": "src/extensions/combat/threat.ts",
        "pairs": [
            (
                "      }\n    }\n    if (row.size === 0) this.table.delete(targetId);\n  }",
                "      }\n    }\n  }",
            )
        ],
        "test": "tests/extensions/threat.test.ts",
    },
    {
        "name": "M273 表满时不淘汰（超过上限照样记）",
        "file": "src/extensions/combat/threat.ts",
        "pairs": [("      if (row.size >= this.maxPerTarget) this.evictWeakest(row);", "      if (false) this.evictWeakest(row);")],
        "test": "tests/extensions/threat.test.ts",
    },
    {
        "name": "M274 大脑记仇时不过滤尸体（hp=0 也追）",
        "file": "src/extensions/mobs/mob-brain.ts",
        "pairs": [("      if (hp === undefined || isDead(hp)) return false;", "      if (hp === undefined) return false;")],
        "test": "tests/extensions/mob-threat.test.ts",
    },
    {
        "name": "M275 大脑记仇时不过滤友军（误伤导致内讧）",
        "file": "src/extensions/mobs/mob-brain.ts",
        "pairs": [
            (
                "      return this.o.factions.stanceOf(me, teamOf(scene, id).team) !== \"ally\";",
                "      return true;",
            )
        ],
        "test": "tests/extensions/mob-threat.test.ts",
    },
    {
        "name": "M276 noteHit 不接（玩家手动攻击不被记恨）",
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [
            (
                "      if (threat === null) return false;\n      return threat.add(info.targetId, info.attackerId, info.applied, info.tick).ok;",
                "      if (threat === null) return false;\n      return false;",
            )
        ],
        "test": "tests/extensions/mob-world.test.ts",
    },
    {
        "name": "M277 越界判定改用 JS 版 realpathSync 存 root（与 fsp.realpath 不同源）",
        # ★ 编号按**追加顺序**排，所以这条挂在末尾而不是紧跟 M55–M57 那组 fs-node 条目。
        #
        # 缺陷原型（GitHub Actions windows-latest 上 39 条契约测试全红，2026-10-25）：
        # `realpathSync`（JS 版）**保留输入的大小写形式**，`fsp.realpath` 走 native、
        # 返回盘上的真实形式。用前者存 realRoot、用后者比较 ⇒ 前缀永远不等。
        # Windows 的盘不区分大小写（runner 上 `C:\Users\RUNNER~1` 还会被 native 展开成
        # `C:\Users\runneradmin`），于是**每一次**读写都报 FS.PATH_ESCAPE。
        #
        # 判据造的是"输入形式 ≠ 盘上形式"的最小样本：root 全大写。
        # 这条变异把修复回退成 JS 版 realpathSync —— 判据必须立刻红。
        "file": "src/backends/fs-node/fs.ts",
        "pairs": [(
            "      this.realRoot = realpathSync.native(this.root);",
            "      this.realRoot = realpathSync(this.root);",
        )],
        "test": "tests/backends/fs-node.test.ts",
        # 判据本身是 Windows-only（非 Windows 上大写变体指向另一个目录，放行会假绿），
        # 所以平台域外**不许报成「假绿」** —— 那不是判据没牙齿，是环境不具备。
        "platforms": ["win32"],
    },
    {
        "name": "M278 ARCHITECTURE 的闸门表漏掉一行（数字对得上，表对不上）",
        # 2026-10-25 真实发生过：表里写着 10 行、`--list` 是 14 步，漏了整整 4 项，
        # 而 `n:steps` 那个数字刚好对得上 ⇒ 对账一路绿。
        # **数字对 ≠ 表对**：可以一边把标题里的数改对、一边留着过期的表格。
        # 判据就是 docs-check 里那条"表行数必须等于 --list 步数"。
        #
        # ★ 靶子用**整行文本**而不是数字：M76 的靶子随闸门数漂移过四次
        #   （10→11→12→13→14），每次都得改变异表。整行文本只在措辞改动时才需要跟。
        #
        # ★★ 但**别挑带 `n:` 标记的行**（2026-10-25 批84 实测：靶子是第 12 行，
        #   而这一批给第 12 行加上 `36 条 <!-- n:editor -->` ⇒ 整行文本变了 ⇒
        #   M278 报"变异点没找到"）。带标记的行等于**带派生数字**，
        #   它每一批都在变 —— 那正是上一段想避免的那件事，只是换了个地方复发。
        #   所以改挑第 3 行：它没有标记、也不含任何会被对账改写的数字。
        "file": "docs/ARCHITECTURE.md",
        "pairs": [(
            "| 3 | 物理性能闸门（**独占**跑） | 解算耗时退化 | 并行跑时测到的是\"机器多忙\"，不是\"代码多慢\"（阈值仍是 8ms，一个字没动） |\n",
            "",
        )],
        "test": "docs/ARCHITECTURE.md",
        "cmd": ["node", "tools/docs-check.mjs", "--quick"],
    },    {
        "name": "M279 字形 UV 的 v 轴翻转（T330 同族：镜像后仍然像字）",
        "file": "src/extensions/ui/font.ts",
        "pairs": [("      v0: c.y / scaleH,", "      v0: 1 - c.y / scaleH,")],
        "test": "tests/extensions/ui-font.test.ts",
    },
    {
        "name": "M280 文本推进用字形宽度而不是 advance（右侧空隙消失）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [("  const base = g === undefined ? font.missingAdvance : g.xadvance;", "  const base = g === undefined ? font.missingAdvance : g.width;")],
        "test": "tests/extensions/ui-text.test.ts",
    },
    {
        "name": "M281 省略号不裁字（尾部溢出容器，truncated 仍是 true）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [("      while (last.length > 0 && lineWidthOf(font, last, ls) + ellW > maxWidth) last.pop();", "      while (false && last.length > 0) last.pop();")],
        "test": "tests/extensions/ui-text.test.ts",
    },
    {
        "name": "M282 九宫格边距不乘帧在图集里的比例（切片点落到帧外）",
        "file": "src/extensions/ui/widgets.ts",
        "pairs": [("  const su = (b / f.width) * (f.u1 - f.u0);", "  const su = b / f.width;")],
        "test": "tests/extensions/ui-module.test.ts",
    },
    {
        "name": "M283 进度条不裁 UV（把整张图拉进一半宽度）",
        "file": "src/extensions/ui/widgets.ts",
        "pairs": [("        const u1 = f.u0 + (f.u1 - f.u0) * v;", "        const u1 = f.u1;")],
        "test": "tests/extensions/ui-module.test.ts",
    },
    {
        "name": "M284 不透明层不再遮挡（模态对话框点穿到底下的按钮）",
        "file": "src/extensions/ui/layout.ts",
        "pairs": [("    if (n.opaque) return null;", "    if (false) return null;")],
        "test": "tests/extensions/ui-layout.test.ts",
    },
    {
        "name": "M285 点击不校验同目标（拖出去松手也算点击）",
        "file": "src/extensions/ui/events.ts",
        "pairs": [("        if (sameTarget && dist <= this.dragThreshold) push(\"click\", target);", "        if (dist <= this.dragThreshold) push(\"click\", target);")],
        "test": "tests/extensions/ui-events.test.ts",
    },
    {
        "name": "M286 expand 模式的锚点贴回设计框（超宽屏上 HUD 被留在黑边里）",
        "file": "src/extensions/ui/viewport.ts",
        "pairs": [("    if (this.scaleMode === UiScaleMode.Expand) return this.screenRect;", "    if (this.scaleMode === UiScaleMode.Expand) return this.designRect;")],
        "test": "tests/extensions/ui-viewport.test.ts",
    },
    {
        "name": "M287 HUD 文案里混进非 ASCII（字体画不出来 ⇒ 那一段静默变空白）",
        # 换成中文而不是换成 `·`：这两个都是真实会发生的写法（"背包"是旧 DOM 版的标签，
        # "·" 是旧 DOM 版的分隔符），而 5×7 位图字体里两者都没有。
        # 症状：不报错、不崩、`xadvance` 照旧推进，只是那块地方是空的。
        "file": "src/host/hud-model.ts",
        # 批115 重新指认：bagStacks 文案从模板串改成 field("bag ", r(...))（富文本分段），
        # 旧靶子 `` `bag ${...}` `` 不存在了；变异语义不变 —— 标签混进非 ASCII。
        "pairs": [('        field("bag ", r(f.bagStacks)),',
                   '        field("背包 ", r(f.bagStacks)),')],
        "test": "tests/host/hud-model.test.ts",
    },
    {
        "name": "M288 背包行不切 visible（面板永远列出 8 行空格子）",
        # 症状：背包里只有 1 堆，面板上却有 8 个格子，后 7 个点得到但什么都不代表。
        "file": "src/host/hud-ui.ts",
        "pairs": [("      n.visible = r !== undefined;", "      n.visible = true;")],
        "test": "tests/host/hud-ui.test.ts",
    },
    {
        "name": "M289 选中行不换底色（点了没反馈，玩家不知道丢的是哪一堆）",
        "file": "src/host/hud-ui.ts",
        "pairs": [("        tint: r.selected ? selTint : rowTint,", "        tint: rowTint,")],
        "test": "tests/host/hud-ui.test.ts",
    },
    {
        "name": "M290 皮肤帧全落在页 0（手头两张页接反 ⇒ UI 画出来是错图）",
        # 页 0 是字形、页 1 是皮肤。接反的症状不是"UI 不见了"，而是"UI 长得不对"——
        # 面板上出现一堆字模碎片，而所有计数（quad/draw/glyph）都是对的。
        "file": "src/host/hud-ui.ts",
        "pairs": [("      page,", "      page: 0,")],
        "test": "tests/host/hud-ui.test.ts",
    },
    {
        "name": "M291 HUD 面板做窄（三行文本溢出到屏幕外，静默裁剪）",
        # 判据量的是"排版宽度 ≤ HUD_LAYOUT.width - pad*2"，而宽度取自实现导出的常量。
        # 把 640 改成 240 之后，第 1 行必然放不下 ⇒ 判据必须红。
        "file": "src/host/hud-ui.ts",
        "pairs": [("  width: 640,", "  width: 240,")],
        "test": "tests/host/hud-ui.test.ts",
    },
    {
        "name": "M292 面板行的点击回调没接上（面板列得对，但点不动）",
        # ★ 这条只能靠浏览器判据抓：Node 侧 `createHudUi` 的 `onSelectRow` 是好用的，
        #   坏的是"UI 模块有没有把它接成事件接收器"。`UiInputRouter` 走通了、
        #   点击事件也产生了，只是没人接 —— 屏幕上完全看不出区别。
        # 用 `--build`：不重建的话页面读的还是旧 bundle，会得到"变异没被抓住"的假结论。
        "file": "src/host/hud-ui.ts",
        "pairs": [("    onEvent,\n", "    onEvent: undefined,\n")],
        "cmd": ["node", "tools/browser-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M293 quadIn 退化成 linear（缓动名还在，曲线没了）",
        # 症状：配了 quadIn 与配 linear 完全一样，而"有没有缓动"在画面上只是手感差异。
        # 抓它的是方向判据（in 类 f(t) < t 严格小于），linear 恒等于 t ⇒ 红。
        "file": "src/extensions/tween/easing.ts",
        "pairs": [("function quadIn(t: number): number {\n  return t * t;\n}", "function quadIn(t: number): number {\n  return t;\n}")],
        "test": "tests/extensions/tween.test.ts",
    },
    {
        "name": "M294 sineIn 的端点特判删掉（浮点差 1e-16 让「播完」边界抖动）",
        "file": "src/extensions/tween/easing.ts",
        "pairs": [("function sineIn(t: number): number {\n  if (t === 1) return 1;\n  return 1 - Math.cos((t * Math.PI) / 2);\n}", "function sineIn(t: number): number {\n  return 1 - Math.cos((t * Math.PI) / 2);\n}")],
        "test": "tests/extensions/tween.test.ts",
    },
    {
        "name": "M295 elastic 的相位偏移写回 0.1（端点特判会把它全盖住）",
        # ★ 这条是本批最值得留的一条：第一版 elastic 用的就是 0.1，而 t=0/t=1 都有
        #   特判 ⇒ 端点判据全绿，只有 inOut 的中点/中心对称判据把它咬出来（0.567）。
        # 它证明"端点特判"与"公式正确"是两条独立的保证，少一条另一条看不见。
        "file": "src/extensions/tween/easing.ts",
        "pairs": [("const ELASTIC_S = ELASTIC_P / 4;", "const ELASTIC_S = 0.1;")],
        "test": "tests/extensions/tween.test.ts",
    },
    {
        "name": "M296 backIn 的 t===0 特判删掉（0 乘负数得 -0）",
        # `0 * ((S+1)*0 - S)` 在 IEEE 下是 **-0**，而 assert.equal(-0, 0) 不相等。
        # 没有端点判据的话，-0 会一路流进坐标，只留下一个难看的数。
        "file": "src/extensions/tween/easing.ts",
        "pairs": [("function backIn(t: number): number {\n  if (t === 0) return 0;\n  if (t === 1) return 1;\n  return t * t * ((BACK_S + 1) * t - BACK_S);\n}", "function backIn(t: number): number {\n  if (t === 1) return 1;\n  return t * t * ((BACK_S + 1) * t - BACK_S);\n}")],
        "test": "tests/extensions/tween.test.ts",
    },
    {
        "name": "M297 循环边界不取 p=1（动画每到整秒闪一下起点）",
        # t 恰为 duration 的整数倍时，"上一轮刚结束"被算成"新一轮的第 0%"。
        # 帧时间轴没这个问题（回到第 0 帧是它要的），补间有，因为 from≠to。
        "file": "src/extensions/tween/tween.ts",
        "pairs": [("  const p = atLoopStart ? 1 : local / perLoop;", "  const p = local / perLoop;")],
        "test": "tests/extensions/tween.test.ts",
    },
    {
        "name": "M298 循环边界不按上一轮定方向（yoyo 在整秒处给出 from 而不是 to）",
        # t=duration 时轮号已经 +1，若 yoyo 开着就被判成反向轮 ⇒ 给 from。
        # 与 M297 是同一处的两个半条：一个管进度、一个管方向。
        "file": "src/extensions/tween/tween.ts",
        "pairs": [("  const effectiveLoop = atLoopStart ? loop - 1 : loop;", "  const effectiveLoop = loop;")],
        "test": "tests/extensions/tween.test.ts",
    },
    {
        "name": "M299 有限循环播完一律停 to（yoyo 的最后一轮是反向，该停 from）",
        "file": "src/extensions/tween/tween.ts",
        "pairs": [("      value: lastIsReverse ? spec.from : spec.to,", "      value: spec.to,")],
        "test": "tests/extensions/tween.test.ts",
    },
    {
        "name": "M300 speed<0 与 yoyo 从异或改成叠加（倒放的往返轮方向反了）",
        # 异或：同时成立时抵消（倒着走的往返 = 正向）。写成 || 会让轮1 也判成反向。
        "file": "src/extensions/tween/tween.ts",
        "pairs": [("  const reversed = spec.speed < 0 !== (spec.yoyo && effectiveLoop % 2 === 1);", "  const reversed = spec.speed < 0 || (spec.yoyo && effectiveLoop % 2 === 1);")],
        "test": "tests/extensions/tween.test.ts",
    },
    {
        "name": "M301 零时长补间被放行（采样要除以它 ⇒ NaN 帧）",
        "file": "src/extensions/tween/tween.ts",
        "pairs": [("  if (!Number.isFinite(input.durationMs) || input.durationMs <= 0) {", "  if (!Number.isFinite(input.durationMs) || input.durationMs < 0) {")],
        "test": "tests/extensions/tween.test.ts",
    },
    {
        "name": "M302 拼错的缓动名静默回落 linear（配了 elastic 却像 linear）",
        "file": "src/extensions/tween/easing.ts",
        "pairs": [("  const fn = EASINGS[name];", "  const fn = EASINGS[name] ?? EASINGS[\"linear\"];")],
        "test": "tests/extensions/tween.test.ts",
    },
    {
        "name": "M303 冻结只记标志位、不拦推进（hitstop 变成了纯装饰）",
        # 症状：frozen 一直是 true、freezeTicks 在涨，可世界照常跑 ——
        # 画面上"该停的时候没停"，而所有冻结相关的计数都是对的。
        # 这是把 advance 的冻结分支写空的形态，也是唯一能让 Node 与浏览器两侧
        # 同时抓住的一条（Node 抓 tick 动了，浏览器抓渲染帧与 tick 的关系）。
        "file": "src/core/scheduler/scheduler.ts",
        "pairs": [("    if (this._freeze > 0) {", "    if (false && this._freeze > 0) {")],
        "test": "tests/core/scheduler.test.ts",
    },
    {
        "name": "M304 冻结按帧数消耗而不是按 fixedDt 对齐（高刷新屏顿帧更短）",
        # 把"每帧收 fixedDt"改成"每帧就收一步"：60Hz 上冻 2 步 = 33ms（应 67ms），
        # 144Hz 上只有 14ms。单看 60Hz 只是"顿帧短了点"，两种帧率放一起才暴露。
        "file": "src/core/scheduler/scheduler.ts",
        "pairs": [("      this._freezeAcc += Math.min(realDtSec, this.maxFrameDt);", "      this._freezeAcc += this.fixedDt;")],
        "test": "tests/core/scheduler.test.ts",
    },
    {
        "name": "M305 到期时剩余真实时间留给下一次冻结（第二次顿帧莫名短一截）",
        # 症状：连击时第一下顿帧正常，后面几下越来越短直到不冻 ——
        # 因为每次的剩余都被下一次"预支"了。单次触发完全看不出来。
        "file": "src/core/scheduler/scheduler.ts",
        "pairs": [("      if (this._freeze === 0) this._freezeAcc = 0;", "      if (this._freeze < 0) this._freezeAcc = 0;")],
        "test": "tests/core/scheduler.test.ts",
    },
    {
        "name": "M306 重复触发累加而不是取最长（连击越冻越久，回放对不上）",
        "file": "src/core/scheduler/scheduler.ts",
        "pairs": [("    this._freeze = Math.max(this._freeze, ticks);", "    this._freeze += ticks;")],
        "test": "tests/core/scheduler.test.ts",
    },
    {
        "name": "M307 冻结在暂停期间也消耗（paused 与 freeze 两条通道被写反）",
        # 把 paused 检查写成"只在没冻结时生效 ⇒ 冻结分支漏过去：
        # 玩家暂停中顿帧照收，恢复瞬间发现顿帧已经结束了。
        "file": "src/core/scheduler/scheduler.ts",
        "pairs": [("    if (this._paused) {", "    if (this._paused && this._freeze === 0) {")],
        "test": "tests/core/scheduler.test.ts",
    },
    {
        "name": "M308 resetTo 不清冻结（读档后人物保持被冻住的那一瞬间）",
        "file": "src/core/scheduler/scheduler.ts",
        "pairs": [("    this._freeze = 0;", "    if (false) this._freeze = 0;")],
        "test": "tests/core/scheduler.test.ts",
    },
    {
        "name": "M309 非法冻结步数被放行（0 / 小数 / NaN 静默通过）",
        # 夹取或放行的症状：freeze(0) 不抛、freeze(1.5) 照收 ——
        # 而调用方（顿帧层）会以为校验过了。
        "file": "src/core/scheduler/scheduler.ts",
        "pairs": [("    if (!Number.isInteger(ticks) || ticks <= 0) {", "    if (false) {")],
        "test": "tests/core/scheduler.test.ts",
    },
    {
        "name": "M310 顿帧策略的非法值记进「跳过」而不是「拒绝」（配表错被当成正常）",
        # 分桶错了比不记账更糟：skipped 涨说明"策略主动说不冻"，
        # 于是填了 3.5 步的配表看起来像一个深思熟虑的决定。
        "file": "src/extensions/combat/hitstop.ts",
        "pairs": [("        rejected++;", "        skipped++;")],
        "test": "tests/extensions/combat-hitstop.test.ts",
    },
    {
        "name": "M311 顿帧模块 init 不校验调度器（缺依赖时静默成功）",
        # 症状：模块起来了、init 返回 ok，可第一次命中就报 BAD_MODULE ——
        # 而"缺依赖"本该在 init 时就炸，而不是等玩家打第一下。
        "file": "src/extensions/combat/hitstop.ts",
        "pairs": [("        return err(engineError(HITSTOP_BAD_MODULE, \"顿帧模块需要一个调度器（先提供 Services.Scheduler）\"));", "        return ok(undefined);")],
        "test": "tests/extensions/combat-hitstop.test.ts",
    },
    {
        "name": "M312 命中不触发顿帧（showHit 的接线断了，世界该停的时候不停）",
        # ★ 这条只能靠浏览器判据抓：Node 侧 `createHitstopModule` 是好的，
        #   坏的是"宿主的 onHit 有没有调它"。症状是完全没有顿帧，
        #   而闪色/伤害数字/仇恨全都正常 —— 每一项单独看都对。
        # 用 `--build`：不重建的话页面读的还是旧 bundle，会得到"变异没被抓住"的假结论。
                # ★ 批128：装配从 `browser-entry.ts` 搬进 `host/demo-game.ts`，靶子跟着搬家（代码一字未改）。
"file": "src/host/demo-game.ts",
        "pairs": [("    const hs = hitstopMod.trigger(info);", "    const hs = { ok: true as const, value: { ticks: 0, remaining: 0, extended: false } };")],
        "cmd": ["node", "tools/browser-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M313 顿帧策略的分支顺序写反（怪杀怪也冻世界，群战画面一帧一停）",
        # ★ 批74 修的就是这个：第一版写成 `dead ? 12 : attacker===hero ? 3 : 0`，
        #   "任何死亡都冻 12 步" ⇒ 猎狗咬死兔子也冻。演示世界 3 猎狗追 10 兔子，
        #   世界被冻得一顿一顿，而冻结不报错、只是手感变怪 —— 浏览器两条顿帧
        #   判据因此时红时绿，最后以 CI 上 M292「还原不干净」的形式爆出来。
        #   策略抽成纯函数后，这条错误在毫秒级就能被 Node 判据抓住。
        "file": "src/host/hitstop-policy.ts",
        "pairs": [("  if (info.attackerId !== heroId) return 0;\n  return info.dead ? HITSTOP_KILL_TICKS : HITSTOP_HIT_TICKS;", "  return info.dead ? HITSTOP_KILL_TICKS : info.attackerId === heroId ? HITSTOP_HIT_TICKS : 0;")],
        "test": "tests/host/hitstop-policy.test.ts",
    },
    {
        "name": "M314 攻击候选不跳过尸体（贴着尸体打不到活人）",
        # ★ 批74 修的根因：`damage()` 不销毁节点，归零的靶子一直留在场景里。
        #   不跳的话最近的候选是尸体 ⇒ `attack()` 上抛 TARGET_DEAD ⇒ 空格键
        #   对着一个还能打的活人**就是没反应**（health.ts 的文案自己说了
        #   "打尸体通常是目标选择出错"：选择侧的问题要在选择侧修）。
        #   浏览器侧的症状：顿帧判据那一枪打中上一条判据留下的尸体，
        #   却读到上一条残留的冻结而假绿 —— 变异后它永远等不到"击杀"，
        #   10 秒总闸判红。
        # ★★ 批123 重新指认（靶子从「浏览器」换成「纯函数」，不是放宽）：
        #   批123 给玩家击杀补了「当场撤掉死掉的节点」（尸体落地的同时
        #   `scene.destroy`），演示世界里于是**不再有站着的尸体** —— 那一行
        #   `if (isDead(h)) continue;` 在浏览器里再也等不到语料，删掉它浏览器
        #   判据照样全绿（CI 报「判据假绿」）。这不是判据写窄了，是那一行
        #   **没了可观察的出口**。修法是把候选资格抽成纯函数
        #   （`src/host/attack-target-policy.ts`，与批74 的 `hitstop-policy.ts`
        #   同一做法），四条理由各有 Node 判据，不再赌世界里恰好有什么。
        "file": "src/host/attack-target-policy.ts",
        "pairs": [("  if (info.dead) return \"dead\";\n", "")],
        "test": "tests/host/attack-target-policy.test.ts",
    },
    {
        "name": "M774 攻击候选不跳过自己（最近的候选永远是玩家自己，打谁都是打自己）",
        "file": "src/host/attack-target-policy.ts",
        "pairs": [("  if (info.id === info.selfId) return \"self\";\n", "")],
        "test": "tests/host/attack-target-policy.test.ts",
    },
    {
        "name": "M775 攻击候选不跳过未激活的（画面上没有的东西也能被锁上）",
        "file": "src/host/attack-target-policy.ts",
        "pairs": [("  if (!info.active) return \"inactive\";\n", "")],
        "test": "tests/host/attack-target-policy.test.ts",
    },
    {
        "name": "M776 四条拒绝理由合并成一个码（「为什么打不到」重新变回不可诊断）",
        "file": "src/host/attack-target-policy.ts",
        "pairs": [
            ("  if (info.id === info.selfId) return \"self\";\n", "  if (info.id === info.selfId) return \"no\";\n"),
            ("  if (!info.active) return \"inactive\";\n", "  if (!info.active) return \"no\";\n"),
            ("  if (info.dead) return \"dead\";\n", "  if (info.dead) return \"no\";\n"),
            ("  if (info.isAlly) return \"ally\";\n", "  if (info.isAlly) return \"no\";\n"),
        ],
        "test": "tests/host/attack-target-policy.test.ts",
    },
    {
        "name": "M315 伤害数字不记攻击者（判据分不清谁冒的数字，被怪的数字带着通过）",
        # ★ 批74：猎狗伤害也是 2，屏幕上随时可能有怪冒的 "-2" —— 不记攻击者的话，
        #   "打出 -2"这条能在完全没打中的情况下靠怪的数字通过；而"数字会消失"
        #   在生物打斗窗口里永远等不到一个空数组。by 恒为 -1 时，
        #   顿帧/伤害两条判据都等不到自己的数字 ⇒ 10 秒总闸判红。
                # ★ 批128：装配从 `browser-entry.ts` 搬进 `host/demo-game.ts`，靶子跟着搬家（代码一字未改）。
"file": "src/host/demo-game.ts",
        "pairs": [(
            "    damageNumbers.push({ el, x, z, bornMs: env.now(), lifeMs: DMG_LIFE_MS, text, dead, by, opacity: 1 });",
            "    damageNumbers.push({ el, x, z, bornMs: env.now(), lifeMs: DMG_LIFE_MS, text, dead, by: -1, opacity: 1 });",
        )],
        "cmd": ["node", "tools/browser-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M316 自检脚本等页面上限改成 1 毫秒（判据还没开口就判挂）",
        # ★ 批75：runner 实测一次自检要 23.2 秒（软件渲染下启动占大头），
        #   工具等页面开口的上限从 30 秒抬到 60 秒。这条守的是那个上限**还在管事**：
        #   改成 1ms 时页面任何结果都读不到，自检必须以"页面挂了"退出（非 0）。
        #   没有它，"把上限写坏"和"把判据写坏"在 CI 上长得一模一样。
        # 不带 `--build`：变异点在工具自己身上，产物包里没有它。
        "file": "tools/browser-selftest.mjs",
        "pairs": [("    const deadline = Date.now() + 60_000;", "    const deadline = Date.now() + 1;")],
        "cmd": ["node", "tools/browser-selftest.mjs"],
        "env_exit": 2,
    },
    # ---- 批76：UI 过渡（TweenPlayer + 属性轨道）
    {
        "name": "M317 重开背包时只重置轨道、不恢复整组开关（第一次关过之后再也不推进）",
        # ★ 这是批76 真实踩到的 bug：`setBagOpen(false)` 把 `player.playing` 置 false，
        #   而 `reset()` 只重置轨道（进度 + autoplay），不动整组开关 ——
        #   于是"关一次再开"之后面板永远停在 opacity 0（起点值完全正确，只是不再前进）。
        #   Node 判据抓不到：它们直接调 `advancePlayer`，不经过宿主这条状态路径。
                # ★ 批128：装配从 `browser-entry.ts` 搬进 `host/demo-game.ts`，靶子跟着搬家（代码一字未改）。
"file": "src/host/demo-game.ts",
        "pairs": [("      t.playing = true;\n      t.reset();", "      t.reset();")],
        "cmd": ["node", "tools/browser-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M318 speed=0 也推进时间（冻结失效，过渡在「暂停」时照跑）",
        "file": "src/extensions/tween/tween-player.ts",
        "pairs": [("!wasDone && t.spec.speed !== 0", "!wasDone")],
        "test": "tests/extensions/tween-player.test.ts",
    },
    {
        "name": "M319 不透明度不乘父节点（父 0.5 × 子 0.5 变成 0.5，整块面板淡不下去）",
        "file": "src/extensions/ui/widgets.ts",
        "pairs": [
            (
                "  for (let cur: UiNode | null = node; cur !== null; cur = cur.parent) {\n    a *= cur.opacity;\n  }",
                "  a *= node.opacity;",
            )
        ],
        "test": "tests/extensions/ui-transition.test.ts",
    },
    {
        "name": "M320 不透明度不钳位（动画过冲直接写进节点，alpha 超过 1）",
        "file": "src/extensions/ui/ui-transition.ts",
        "pairs": [("      node.opacity = value < 0 ? 0 : value > 1 ? 1 : value;", "      node.opacity = value;")],
        "test": "tests/extensions/ui-transition.test.ts",
    },
    {
        "name": "M321 缩放不沿父链组合（子节点不跟着父放大，整体弹出变成散开）",
        # 变异点：往下传的子节点变换本该是 (s, ox, oy)，退化成"无变换"
        "file": "src/extensions/ui/layout.ts",
        # ★ 批105 重新指认：`arrange` 多了 `clip` 与 `opts` 两个参数（滚动容器要用），
        #   旧靶点整行都不存在了。**改的是靶点，不是判据强度** —— 变异语义一字未变：
        #   往下传的子节点变换本该是 (s, ox, oy)，退化成"无变换"。
        "pairs": [("      arrange(c, new Rect(p.x - sx, p.y - sy, c.measured.w, c.measured.h), s, ox, oy, childClip, opts);", "      arrange(c, new Rect(p.x - sx, p.y - sy, c.measured.w, c.measured.h), 1, 0, 0, childClip, opts);")],
        "test": "tests/extensions/ui-transition.test.ts",
    },
    # ---------------------------------------------------------------- 批77 编辑器撤销栈
    {
        "name": "M322 撤销之后不 pop（再按一次撤销退的还是同一条，历史永远退不完）",
        "file": "src/extensions/editor/undo-stack.ts",
        "pairs": [
            (
                """    this.done.pop();
    this.redoSide.push(op);
    return { kind: "done", label: op.label };""",
                """    this.redoSide.push(op);
    return { kind: "done", label: op.label };""",
            )
        ],
        "test": "tests/extensions/undo-stack.test.ts",
    },
    {
        "name": "M323 撤销失败也弹栈（这条历史被吃掉：状态没退，历史里也没有它了）",
        "file": "src/extensions/editor/undo-stack.ts",
        "pairs": [
            (
                """    if (!r.ok) return { kind: "failed", label: op.label, error: r.error };
    this.done.pop();""",
                """    if (!r.ok) {
      this.done.pop();
      return { kind: "failed", label: op.label, error: r.error };
    }
    this.done.pop();""",
            )
        ],
        "test": "tests/extensions/undo-stack.test.ts",
    },
    {
        "name": "M324 压新操作不清空重做侧（重做会跳到另一条分支的状态）",
        "file": "src/extensions/editor/undo-stack.ts",
        "pairs": [("    this.done.push(op);\n    this.redoSide = [];", "    this.done.push(op);")],
        "test": "tests/extensions/undo-stack.test.ts",
    },
    {
        "name": "M325 上限不生效（历史无限增长，也不报丢弃条数）",
        "file": "src/extensions/editor/undo-stack.ts",
        "pairs": [("    while (this.done.length > this.limit) {", "    while (this.done.length > 1000000000) {")],
        "test": "tests/extensions/undo-stack.test.ts",
    },
    {
        "name": "M326 批量撤销按正序（去动一个已经被前面那条删掉的节点）",
        "file": "src/extensions/editor/undo-stack.ts",
        "pairs": [("    for (let i = this.ops.length - 1; i >= 0; i--) {", "    for (let i = 0; i < this.ops.length; i++) {")],
        "test": "tests/extensions/undo-stack.test.ts",
    },
    {
        "name": "M327 空批量也压进历史（历史里出现一条按了什么都不做的记录）",
        "file": "src/extensions/editor/undo-stack.ts",
        "pairs": [("    if (b.ops.length === 0) return ok({ pushed: false, count: 0 });", "    if (false) return ok({ pushed: false, count: 0 });")],
        "test": "tests/extensions/undo-stack.test.ts",
    },
    {
        "name": "M328 valuesEqual 退化成引用相等（Vec2 写回同值也判成改了，历史被空改动填满）",
        "file": "src/extensions/editor/property-model.ts",
        "pairs": [("  if (a === b) return true;", "  return a === b;")],
        "test": "tests/extensions/editor-props.test.ts",
    },
    {
        "name": "M329 changed 恒 true（每次失焦都算一次改动）",
        "file": "src/extensions/editor/property-model.ts",
        "pairs": [("changed: !valuesEqual(before, c.value) });", "changed: true });")],
        "test": "tests/extensions/editor-props.test.ts",
    },
    {
        "name": "M330 先删再快照（撤销删除什么都回不来，而代码看起来仍在工作）",
        "file": "src/extensions/editor/undo-ops.ts",
        "pairs": [
            (
                """  const snap = snapshotSubtree(scene, nodeId);
  if (snap === undefined) return err(engineError(EDIT_BAD_NODE, `节点 #${String(nodeId)} 拍不到快照`));
  scene.destroy(nodeId);
  scene.flush();""",
                """  scene.destroy(nodeId);
  scene.flush();
  const snap = snapshotSubtree(scene, nodeId);
  if (snap === undefined) return err(engineError(EDIT_BAD_NODE, `节点 #${String(nodeId)} 拍不到快照`));""",
            )
        ],
        "test": "tests/extensions/editor-undo.test.ts",
    },
    {
        "name": "M331 还原不用显式 id（撤销之后 id 变了，场景里所有引用全断）",
        "file": "src/extensions/editor/undo-ops.ts",
        "pairs": [("    const n = scene.spawnImmediate(r.name, scene.rootId, r.id);", "    const n = scene.spawnImmediate(r.name, scene.rootId);")],
        "test": "tests/extensions/editor-undo.test.ts",
    },
    {
        "name": "M332 还原不读组件数据（节点回来了但字段是默认值，看着像撤销只做了一半）",
        "file": "src/extensions/editor/undo-ops.ts",
        "pairs": [("      const res = c.load(cr.data);", "      const res = c.load({});")],
        "test": "tests/extensions/editor-undo.test.ts",
    },
    {
        "name": "M333 多选删除不过滤后代（删父之后再删已消失的子，整批回滚）",
        "file": "src/extensions/editor/undo-ops.ts",
        "pairs": [("      if (picked.has(cur.id)) return false;", "      if (false) return false;")],
        "test": "tests/extensions/editor-undo.test.ts",
    },
    {
        "name": "M334 换父不做环检查（把节点挂进自己的后代，之后 walk 直接爆栈）",
        # ★ 批81：这一段原来是一份手写的上溯循环（`while (cur !== null) { if (cur.id === nodeId) ... }`），
        #   抽成 `Node.isAncestorOf` 之后旧靶子不存在了 —— 变异报告的是「靶子漂移」，
        #   意思是**重新指认**，不是放宽标准。核心层那道守卫（M361）抓不到这条：
        #   编辑器这里必须在崩之前把它变成错误码，所以它值得单独一条。
        "file": "src/extensions/editor/undo-ops.ts",
        # ★ 批85：这个靶子又漂了一次 —— 换父改成"先算世界位置"之后，
        #   `target` 在更早的地方就已经判过 undefined（顺便 return 了错误码），
        #   于是条件里的 `target !== undefined &&` 整段消失。**每次给函数加前置检查，
        #   都要顺手看一遍指向它的变异靶子。**
        "pairs": [("  if (target.id === nodeId || node.isAncestorOf(target)) {",
                   "  if (false) {")],
        "test": "tests/extensions/editor-undo.test.ts",
    },
    {
        "name": "M335 换父的撤销用错方向（撤销之后还在新父下，按钮说退了但没退）",
        "file": "src/extensions/editor/undo-ops.ts",
        # 批85：`move` 多了一个局部坐标参数（撤销要把父子关系与坐标一起回），靶子随之改变。
        "pairs": [("    return this.move(this.from, this.fromLocal);",
                   "    return this.move(this.to, this.toLocal);")],
        "test": "tests/extensions/editor-undo.test.ts",
    },
    {
        "name": "M336 旁路跑完之后不恢复录制（此后所有编辑都不进历史，按钮一直是灰的）",
        "file": "src/extensions/editor/undo-stack.ts",
        "pairs": [
            (
                """    this.muted++;
    try {
      return fn();
    } finally {
      this.muted--;
    }""",
                """    this.muted++;
    return fn();""",
            )
        ],
        "test": "tests/extensions/undo-stack.test.ts",
    },
    # ---------------------------------------------------------------- 批79 平台分包
    {
        "name": "M337 分包不再优先于主包（命中分包的文件掉进主包，分包变空包而规划说成功）",
        "file": "src/publish/pack-plan.ts",
        "pairs": [("    if (hits.length === 1) {", "    if (false) {")],
        "test": "tests/publish/pack-plan.test.ts",
    },
    {
        "name": "M338 主包预算边界从 > 改成 >=（正好 4MB 被拒，差一字节是唯一会错的地方）",
        "file": "src/publish/pack-plan.ts",
        "pairs": [("  if (mainPkg.bytes > WECHAT_LIMITS.mainPackage) {", "  if (mainPkg.bytes >= WECHAT_LIMITS.mainPackage) {")],
        "test": "tests/publish/pack-plan.test.ts",
    },
    {
        "name": "M339 没有归属的文件不报错（它们静默地从包里消失，包看起来是完整的）",
        "file": "src/publish/pack-plan.ts",
        "pairs": [("  if (unmatched.length > 0) {", "  if (false) {")],
        "test": "tests/publish/pack-plan.test.ts",
    },
    {
        "name": "M340 后缀白名单不检查（微信不收的 .md 混进包，上传时才失败且信息在很后面）",
        "file": "src/publish/pack-plan.ts",
        "pairs": [('    if (e !== "" && !WECHAT_EXT_WHITELIST.includes(e)) {', "    if (false) {")],
        "test": "tests/publish/pack-plan.test.ts",
    },
    {
        "name": "M341 不检查分包文件是否落在自己的 root 下（game.json 指的目录里没有它）",
        "file": "src/publish/pack-plan.ts",
        "pairs": [("      if (!f.path.startsWith(`${root}/`)) {", "      if (false) {")],
        "test": "tests/publish/pack-plan.test.ts",
    },
    {
        "name": "M342 不检查分包 root 互相嵌套（内层文件被外层吃掉，两个分包都声明得通）",
        "file": "src/publish/pack-plan.ts",
        "pairs": [("      } else if (a.root.startsWith(`${b.root}/`) || b.root.startsWith(`${a.root}/`)) {", "      } else if (false) {")],
        "test": "tests/publish/pack-plan.test.ts",
    },
    {
        "name": "M343 game.json 的分包 root 按名字猜（与包里实际落的目录脱钩）",
        "file": "src/publish/pack-plan.ts",
        "pairs": [("    subpackages: plan.subpackages.map((p) => ({ name: p.name, root: p.root })),",
                   "    subpackages: plan.subpackages.map((p) => ({ name: p.name, root: `subpackage/${p.name}` })),")],
        "test": "tests/publish/pack-plan.test.ts",
    },
    {
        "name": "M344 无条件写 setlive（`undefined` 变成一个真键，等于对 default 分支自动发布）",
        "file": "src/publish/pack-plan.ts",
        "pairs": [('  if (o.setLive !== undefined) lines.push(q("setlive", o.setLive));',
                   '  lines.push(q("setlive", String(o.setLive)));')],
        "test": "tests/publish/pack-plan.test.ts",
    },
    {
        "name": "M345 扫描行号从 0 起（报的位置差一行，跳过去是上一行）",
        "file": "src/publish/pack-plan.ts",
        "pairs": [("      if (line.includes(api)) hits.push({ api, line: i + 1 });",
                   "      if (line.includes(api)) hits.push({ api, line: i });")],
        "test": "tests/publish/pack-plan.test.ts",
    },
    {
        "name": "M346 打包恒重写（内容没变也写，重复打包把整个产物目录的 mtime 全刷新）",
        "file": "tools/pack.ts",
        "pairs": [("    if (readFileSync(path).equals(buf)) {", "    if (false) {")],
        "test": "tests/publish/pack-cli.test.ts",
    },
    {
        "name": "M347 空 staging 不拒绝（Steam 上推一个空 depot，微信上传一个打不开的包）",
        "file": "tools/pack.ts",
        "pairs": [("if (files.length === 0) {", "if (false) {")],
        "test": "tests/publish/pack-cli.test.ts",
    },
    {
        "name": "M348 规划失败仍退出 0（打包坏了 CI 还是绿的）",
        "file": "tools/pack.ts",
        "pairs": [("    console.error(`\\n✗ 分包规划失败（${String(planR.error.length)} 个问题）—— 没有写出任何东西`);\n    process.exit(EXIT_FAIL);",
                   "    console.error(`\\n✗ 分包规划失败（${String(planR.error.length)} 个问题）—— 没有写出任何东西`);\n    process.exit(EXIT_PASS);")],
        "test": "tests/publish/pack-cli.test.ts",
    },
    {
        "name": "M349 --check 不再提前退出（说好只检查，结果把整个产物目录写了一遍）",
        "file": "tools/pack.ts",
        "pairs": [('  if (checkOnly) {\n    console.log("✓ 分包规划通过（--check 未写文件）");\n    process.exit(EXIT_PASS);\n  }',
                   '  if (false) {\n    console.log("✓ 分包规划通过（--check 未写文件）");\n    process.exit(EXIT_PASS);\n  }')],
        "test": "tests/publish/pack-cli.test.ts",
    },
    {
        "name": "M350 淡入轨道回到缺省的无限循环（面板打开后一直 0→1 反复闪，判据只要撞上末帧就绿）",
        # ★ 这条是被 CI 教出来的：批76 报 0.5555、批78 报 0.75，两次都是**不同相位**，
        #   同一条判据时红时绿。根因是 `TweenSpec.loopCount` 缺省 `0` = 无限循环。
        #   它只能靠浏览器判据抓（Node 侧没有这条宿主 spec），所以走 `cmd`。
        #   判据本身也跟着改了：从「到过 1」改成「到达后一个周期内不许再掉下去」——
        #   只看到过 1 的判据对脉冲无能为力，因为每一轮都会经过 1。
                # ★ 批128：装配从 `browser-entry.ts` 搬进 `host/demo-game.ts`，靶子跟着搬家（代码一字未改）。
"file": "src/host/demo-game.ts",
        "pairs": [('      spec: { id: "bag.fadeIn", from: 0, to: 1, durationMs: fadeMs, easing: "quadOut", loopCount: 1 },',
                   '      spec: { id: "bag.fadeIn", from: 0, to: 1, durationMs: fadeMs, easing: "quadOut", loopCount: 0 },')],
        "cmd": ["node", "tools/browser-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M351 补间缺省循环数从 0（无限）改成 1 —— 这条约定没人钉住就会被人顺手改掉",
        # ★ M350 抓的是「调用方漏传 loopCount」，这条抓的是「**缺省值本身**被改」。
        #   两者是不同的失效：前者改回去还会再犯，后者会让所有依赖无限循环的玩法
        #   （待机浮动、呼吸光效）悄悄只播一次。缺省 0 = 无限与 APNG 的 num_plays = 0 同义。
        "file": "src/extensions/tween/tween.ts",
        "pairs": [("  const loopCount = input.loopCount ?? 0;",
                   "  const loopCount = input.loopCount ?? 1;")],
        "test": "tests/extensions/tween-player.test.ts",
    },
    {
        "name": "M352 Steam 命令末尾漏掉 +quit（steamcmd 停在提示符上，CI 挂到超时且日志无错）",
        # ★ 这类错误最贵：没有异常、没有栈，只是"不结束"。所以 +quit 由构造器追加，
        #   判据同时验"最后一个"和"只出现一次"。
        "file": "src/publish/steam-upload.ts",
        "pairs": [('argv: ["+login", login, "+run_app_build", o.appBuildVdf, "+quit"],',
                   'argv: ["+login", login, "+run_app_build", o.appBuildVdf],')],
        "test": "tests/publish/steam-upload.test.ts",
    },
    {
        "name": "M353 +quit 挪到最前面（参数顺序错：登录/上传都没执行就退出）",
        "file": "src/publish/steam-upload.ts",
        "pairs": [('argv: ["+login", login, "+run_app_build", o.appBuildVdf, "+quit"],',
                   'argv: ["+quit", "+login", login, "+run_app_build", o.appBuildVdf],')],
        "test": "tests/publish/steam-upload.test.ts",
    },
    {
        "name": "M354 登录名含空格不再拒绝（steamcmd 把后半截当密码，报「登录失败」）",
        "file": "src/publish/steam-upload.ts",
        "pairs": [("  } else if (needsQuoting(login)) {", "  } else if (false) {")],
        "test": "tests/publish/steam-upload.test.ts",
    },
    {
        "name": "M355 相对路径的 vdf 放行（steamcmd chdir 之后找不到文件）",
        "file": "src/publish/steam-upload.ts",
        "pairs": [("  if (!isAbsolutePathLike(o.appBuildVdf)) {", "  if (false) {")],
        "test": "tests/publish/steam-upload.test.ts",
    },
    {
        "name": "M356 给含空格的路径预先加引号（spawn 不经 shell，引号成了路径的一部分）",
        "file": "src/publish/steam-upload.ts",
        "pairs": [('argv: ["+login", login, "+run_app_build", o.appBuildVdf, "+quit"],',
                   'argv: ["+login", login, "+run_app_build", needsQuoting(o.appBuildVdf) ? `"${o.appBuildVdf}"` : o.appBuildVdf, "+quit"],')],
        "test": "tests/publish/steam-upload.test.ts",
    },
    {
        "name": "M357 PATH 里的空条目不再跳过（朴素拼出根下的 /steamcmd —— 执行到错的那个文件）",
        "file": "src/publish/steam-upload.ts",
        "pairs": [('    if (dir === "") continue;', "    if (dir === \"\") { /* 不跳过 */ }")],
        "test": "tests/publish/steam-upload.test.ts",
    },
    {
        "name": "M358 Windows 后缀表去掉 .exe（装了 steamcmd.exe 也找不到）",
        "file": "src/publish/steam-upload.ts",
        "pairs": [('exts: win ? ["", ".exe", ".bat", ".cmd"] : [""]', 'exts: win ? ["", ".bat", ".cmd"] : [""]')],
        "test": "tests/publish/steam-upload.test.ts",
    },
    {
        "name": "M359 --check 与 --upload 互斥检查写反（说好只检查，结果照传）",
        "file": "tools/pack.ts",
        "pairs": [('if (checkOnly && wantUpload) usage("--check 只做判断，不能同时 --upload");',
                   'if (checkOnly && !wantUpload) usage("--check 只做判断，不能同时 --upload");')],
        "test": "tests/publish/pack-cli.test.ts",
    },
    {
        "name": "M360 找不到 steamcmd 时退 1（把环境缺失说成打包坏了，人去查预算）",
        "file": "tools/pack.ts",
        "pairs": [('  console.error(`  VDF 已经写好，也可以手工执行：${renderSteamCommandLine(steamCmd.argv)}`);\n  process.exit(EXIT_USAGE);',
                   '  console.error(`  VDF 已经写好，也可以手工执行：${renderSteamCommandLine(steamCmd.argv)}`);\n  process.exit(EXIT_FAIL);')],
        "test": "tests/publish/pack-cli.test.ts",
    },
    {
        "name": "M361 addChild 不做环检查（挂进自己的后代 ⇒ walk 栈溢出，崩在很远的地方）",
        # ★ 这条是批81 补核心层缺口的证据：删掉守卫后，判据里的 `walk` 会真的栈溢出
        #   （RangeError），而不是断言失败 —— 判据本身就是那场事故的复现。
        "file": "src/core/scene/node.ts",
        "pairs": [("    if (child === this || child.isAncestorOf(this)) {", "    if (false) {")],
        "test": "tests/core/scene.test.ts",
    },
    {
        "name": "M362 isAncestorOf 把自己也算成祖先（addChild 的幂等分支被抢走，重复挂会抛）",
        "file": "src/core/scene/node.ts",
        "pairs": [("    let p: Node | null = other.parent;", "    let p: Node | null = other;")],
        "test": "tests/core/scene.test.ts",
    },
    {
        "name": "M363 isAncestorOf 只查直接父（隔代换父漏检 ⇒ 真造出环）",
        "file": "src/core/scene/node.ts",
        "pairs": [("      p = p.parent;\n", "      p = null;\n")],
        "test": "tests/core/scene.test.ts",
    },
    {
        "name": "M364 读档时不接住 addChild 的环异常（坏存档把宿主进程炸掉，Result 变成假的）",
        "file": "src/core/scene/scene-io.ts",
        # ★ 变异必须**语义**上坏，不能把文件改成语法错 —— 语法错也会让判据"红"，
        #   但那是编译失败，等于没验到行为（第一次写成了多插一个 `{`，就是这样）。
        "pairs": [("    } catch (e) {\n      // ★ 存档里如果有环",
                   "    } catch (e) {\n      throw e;\n      // ★ 存档里如果有环")],
        "test": "tests/core/scene-io.test.ts",
    },
    {
        "name": "M365 打开文档后不清撤销栈（撤销会改到新文档里同 id 的另一个节点）",
        "file": "src/extensions/editor/session.ts",
        # ★ 中文判据名里一律用「」，不要嵌 ASCII 双引号（这个仓库踩过 5 次）。
        "pairs": [("  deps.history.clear();\n", "  void deps.history;\n")],
        "test": "tests/extensions/editor-session.test.ts",
    },
    {
        "name": "M366 打开文档后不清选中集（选中项指向已被替换掉的旧节点）",
        "file": "src/extensions/editor/session.ts",
        "pairs": [("  deps.selection.clear();\n", "  void deps.selection;\n")],
        "test": "tests/extensions/editor-session.test.ts",
    },
    {
        "name": "M367 装载失败时不回灌（报错说「已恢复」，工作区其实已经空了）",
        "file": "src/extensions/editor/session.ts",
        # ★ 回灌成**空场景**而不是删掉那行：删掉会让 `back.error` 类型不成立。
        #   这个变异同时覆盖两种事故 —— 没回灌、回灌错了东西。
        "pairs": [("  const back = loadScene(deps.scene, before, deps.registry);",
                   "  const back = loadScene(deps.scene, { format: 1, name: \"\", nodes: [] }, deps.registry);")],
        "test": "tests/extensions/editor-session.test.ts",
    },
    {
        "name": "M368 快照拍成空场景（等价于拍在 loadScene 之后：回灌装回来的是一份空白）",
        "file": "src/extensions/editor/session.ts",
        # ★ 第一版写的是「交换两行」，实测是**假绿**：`loadScene` 唯一的 `err` 面（版本过新）
        #   在 `scene.clear()` **之前**就返回了，那时场景还没被清，先拍后拍拿到的一样。
        #   真正要覆盖的是 clear 之后才发生的失败（组件 onAttach 抛），而它能观察到的
        #   差别只有一个：回灌的 `before` 是不是空的。所以直接让 `before` 空掉。
        # ★ 锚要带下一行：`const before = saveScene(deps.scene);` 在 `newDocument` 里也有一处，
        #   而替换器只打第一处（`replace(..., 1)`）—— 不带上下文就是"靠行号顺序碰运气"。
        "pairs": [("  const before = saveScene(deps.scene);\n  let loaded: ReturnType<typeof loadScene>;",
                   "  const before: SceneSnapshot = { format: 1, name: \"\", nodes: [] };\n"
                   "  let loaded: ReturnType<typeof loadScene>;")],
        "test": "tests/extensions/editor-session.test.ts",
    },
    {
        "name": "M369 打开时先 clear 再解析（打不开的档把正在编辑的工程吃掉）",
        "file": "src/extensions/editor/session.ts",
        "pairs": [("  const parsed = sceneFromJson(text);\n  if (!parsed.ok) {",
                   "  deps.scene.clear();\n  const parsed = sceneFromJson(text);\n  if (!parsed.ok) {")],
        "test": "tests/extensions/editor-session.test.ts",
    },
    {
        "name": "M370 撤销卸载时不检查「节点上那个还是不是它」（按类型摘会摘掉别人新挂的）",
        "file": "src/extensions/editor/undo-ops.ts",
        # ★ 这一条对应的事故：撤销栈里记的是**实例**，而 `scene.detach` 是**按类型**找的。
        #   不比对就把别人刚挂的同类组件摘掉了 —— 界面上「撤销成功」，活干错了。
        "pairs": [("    if (current !== this.comp) {", "    if (false) {")],
        "test": "tests/extensions/editor-component-ops.test.ts",
    },
    {
        "name": "M371 重做挂上时覆盖别人的同类组件（应当报错，而不是把新的换掉）",
        "file": "src/extensions/editor/undo-ops.ts",
        "pairs": [("    if (existing !== undefined) {", "    if (false) {")],
        "test": "tests/extensions/editor-component-ops.test.ts",
    },
    {
        "name": "M372 允许同一节点挂两个同类组件（面板会出现两段一模一样的字段）",
        "file": "src/extensions/editor/undo-ops.ts",
        "pairs": [("  if (already !== undefined) {", "  if (false) {")],
        "test": "tests/extensions/editor-component-ops.test.ts",
    },
    {
        "name": "M373 卸一个本来就没挂的组件也当成功（历史里多一条什么都没做的动作）",
        "file": "src/extensions/editor/undo-ops.ts",
        "pairs": [("  if (comp === undefined) {\n    return err(engineError(EDIT_BAD_COMP, `节点 #${String(nodeId)} 上没有 ${type}`));",
                   "  if (false) {\n    return err(engineError(EDIT_BAD_COMP, `节点 #${String(nodeId)} 上没有 ${type}`));")],
        "test": "tests/extensions/editor-component-ops.test.ts",
    },
    {
        # 页面级判据（走 cmd，看退出码）：组件操作的收尾若不压历史，
        # 纯函数层全绿（undo-ops 的 op 本身没问题），只有页面上「撤销按钮没亮」。
        # 这正是「纯模型层判据证不到接线」的那一类，必须用浏览器那条判据。
        "name": "M374 组件挂/卸不压进历史（撤销按钮不亮，而 op 本身是对的）",
        "file": "src/editor-entry.ts",
        "pairs": [("  const pushed = history.push(op);",
                   "  const pushed: { ok: boolean; error?: { code: string; message: string } } = { ok: true };")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    # ---- 批84：画布拖拽（gizmo）
    {
        "name": "M375 世界→局部换算直接当恒等（父带旋转时拖动方向错，纯平移的场景看不出来）",
        "file": "src/extensions/editor/gizmo.ts",
        "pairs": [("    u: (basis.m11 * dx - basis.m01 * dy) / det,\n    v: (-basis.m10 * dx + basis.m00 * dy) / det,",
                   "    u: dx,\n    v: dy,")],
        "test": "tests/extensions/editor-gizmo.test.ts",
    },
    {
        "name": "M376 按下点的偏移用世界坐标（父一有偏移，节点就跳到父的位置附近）",
        "file": "src/extensions/editor/gizmo.ts",
        "pairs": [("    grabU: local.u - n.localPosition.x,\n    grabV: local.v - n.localPosition.y,",
                   "    grabU: wx - n.localPosition.x,\n    grabV: wz - n.localPosition.y,")],
        "test": "tests/extensions/editor-gizmo.test.ts",
    },
    {
        "name": "M377 命中测试不按 zIndex 排序（重叠时选中先创建的那个，不是画面上压着的那个）",
        "file": "src/extensions/editor/gizmo.ts",
        "pairs": [("  hits.sort((a, b) => (b.z !== a.z ? b.z - a.z : a.d2 !== b.d2 ? a.d2 - b.d2 : a.id - b.id));",
                   "  hits.sort((a, b) => (a.d2 !== b.d2 ? a.d2 - b.d2 : a.id - b.id));")],
        "test": "tests/extensions/editor-gizmo.test.ts",
    },
    {
        "name": "M378 位移为 0 也压一条历史（按一次撤销什么都没发生）",
        "file": "src/extensions/editor/gizmo.ts",
        "pairs": [("  if (x === state.fromX && y === state.fromY) return ok(undefined);",
                   "  if (false) return ok(undefined);")],
        "test": "tests/extensions/editor-gizmo.test.ts",
    },
    {
        "name": "M379 位置 op 改 Vec2 字段而不是 setLocalPosition（不推进版本号：逻辑坐标回去、画面还在原地）",
        "file": "src/extensions/editor/gizmo.ts",
        # ★ 用「就地改 Vec2 的字段」而不是 `new Vec2(...)`：后者要额外 import，
        #   漏了就是 ReferenceError —— 判据会红，但那是"代码跑不起来"，等于没验行为。
        "pairs": [("    n.setLocalPosition(x, y);\n    return ok(undefined);",
                   "    n.localPosition.x = x;\n    n.localPosition.y = y;\n    return ok(undefined);")],
        "test": "tests/extensions/editor-gizmo.test.ts",
    },
    # ---- 批84：文档对账的 n:editor 标记要真的读到清单（不是"接上了却读不到"）
    {
        # 这一条打的不是业务代码，而是**闸门自己**：docs-check 早就为同类问题写过注释
        # （"加了标记却忘了把实测值塞进 actual ⇒ 正则认得、值却是 undefined ⇒ 报绿"）。
        # 让 actualEditor 返回 0，等价于"编辑器自检的条数没接上"：
        # 三份文档里声明的 36 与 0 对不上，必须红。
        # ★ 用 `--quick` 而不是全量：这条变异不碰 tests/，缓存仍然新鲜，
        #   跑整套 npm test 只会让 14 步里的第 14 步多花几分钟，不多抓任何东西。
        "name": "M380 文档对账的编辑器条数没接上（返回 0：标记认得、值却是假的）",
        "file": "tools/docs-check.mjs",
        "pairs": [("function actualEditor() {\n  return EDITOR_DECLARED.length;\n}",
                   "function actualEditor() {\n  return 0;\n}")],
        "cmd": ["node", "tools/docs-check.mjs", "--quick"],
    },
    # ---- 批85：换父保住世界位置（模型层）+ 场景树拖放（页面层）
    {
        # 只改父子关系、不重算局部坐标 —— 这正是 `scene.reparent` 的原始行为。
        # 症状：「拖到别的节点下面」变成「节点飞走了」，而层级、历史、面板全对。
        "name": "M381 换父不重算局部坐标（世界位置跟着跳，层级却对了）",
        "file": "src/extensions/editor/undo-ops.ts",
        "pairs": [("  const toLocal = { x: local.u, y: local.v };",
                   "  const toLocal = { x: node.localPosition.x, y: node.localPosition.y };")],
        "test": "tests/extensions/editor-reparent-world.test.ts",
    },
    {
        # 撤销/重做只把父挂回去、局部坐标留在上一次算出来的值上 ——
        # 父对了、位置错了，而且错得很像「当初就是这样」。
        "name": "M382 换父 op 只管父子关系、不管局部坐标（撤销后位置不回来）",
        "file": "src/extensions/editor/undo-ops.ts",
        "pairs": [("    node.setLocalPosition(local.x, local.y);\n    return ok(undefined);",
                   "    return ok(undefined);")],
        "test": "tests/extensions/editor-reparent-world.test.ts",
    },
    {
        # 拿节点自己的**局部**坐标去当世界坐标换算：父是恒等时完全正确，
        # 于是在大部分测试场景里都是绿的 —— 本批的夹具特意让父带偏移才咬得住。
        "name": "M383 用局部坐标当世界坐标去换算（父不是恒等时位置就错）",
        "file": "src/extensions/editor/undo-ops.ts",
        "pairs": [("  const local = worldToLocal(target.worldTransform, world.x, world.y);",
                   "  const local = worldToLocal(target.worldTransform, node.localPosition.x, node.localPosition.y);")],
        "test": "tests/extensions/editor-reparent-world.test.ts",
    },
    {
        # 页面级：拖到自己身上是「中途改主意」，必须两边都不动。
        # 不判的话会走一遍换父 —— 模型层报「已经挂在 #N 下面了」，
        # 于是人拖回原处就看到一行红字，以为操作坏了。
        "name": "M384 拖到自己身上不再算取消（拖回原处反而报错）",
        "file": "src/editor-entry.ts",
        "pairs": [("  if (!Number.isFinite(dst) || dst === src) return { ok: true, changed: false };",
                   "  if (!Number.isFinite(dst)) return { ok: true, changed: false };")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        # 页面级：换父成功但不进历史 ⇒ 节点真的换了父，撤销按钮却不亮。
        # 纯模型层判据证不到这一条（`reparentWithUndo` 本身没问题）。
        "name": "M385 换父不压进历史（层级变了、撤销按钮不亮）",
        "file": "src/editor-entry.ts",
        "pairs": [("  return commitOp(r.value.op);\n}\n\n/**\n * 松手。",
                   "  afterHistoryChange();\n  return { ok: true };\n}\n\n/**\n * 松手。")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    # ---- 批86：资产浏览器（清单 → 面板 → 加入场景）
    {
        # 清单读的时候不传帧名 ⇒ 所有资产都被当成"无帧"。
        # 这一条同时打红两个地方：面板的可加入数（6 变 0）与"无帧标记"那条
        # （photo 本来就无帧，于是它不再是**唯一**被标出来的那个）。
        "name": "M386 清单不传图集帧名（所有资产都变成『无帧』）",
        "file": "src/editor-entry.ts",
        # 靶子随批87 挪过位置：`.frameNames` 的值从 `atlasFrames` 变成了烘出来的
        # `baked.value.frames`（图集不再来自顶层常量，而是"读清单 → 读图 → 烘"的产物）。
        # **这不是放宽标准**，是同一条语义在新结构下的同一条靶子；
        # 同文件里那个不带 second 参的调用（`bare`，行 966）不能拿来当靶子 ——
        # 它只用来筛位图，`inAtlas` 根本不经过它，改了没有可观察差异。
        "pairs": [("  const cat = catalogFromManifest(text.value, { frameNames: baked.value.frames });",
                   "  const cat = catalogFromManifest(text.value);")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        # 页面级：「加入场景」之后不选中新节点 —— 节点确实加进去了，
        # 但属性面板还停在别人身上（或空空如也），人找不到刚加的那个。
        "name": "M387 加入场景后不选中新节点（属性面板还停在别人身上）",
        "file": "src/editor-entry.ts",
        "pairs": [("  selection.select(r.value.nodeId);\n  const out = commitOp(r.value.op);",
                   "  const out = commitOp(r.value.op);")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        # 页面级：加进了场景却不压历史 ⇒ 节点在那儿、撤销按钮不亮。
        # 与 M385 同一类，但这条打的是"资产面板"这条线（两条线各接一次 `commitOp`）。
        "name": "M388 加入场景不压历史（节点在、撤销退不回去）",
        "file": "src/editor-entry.ts",
        # ★ 靶子随批89 改过一次：`doAddAsset` 现在返回值多一个 `at`（落点），
        #   这是**函数契约的一部分**，不是顺手加的字段 —— 判据要靠它断言"落在指针处"。
        #   靶子要跟着改，否则报「靶子漂移」；漂移不等于放宽，去重新指认。
        "pairs": [("  const out = commitOp(r.value.op);\n  if (!out.ok) return out;\n  return { ok: true, id: r.value.nodeId, at: pos };",
                   "  afterHistoryChange();\n  return { ok: true, id: r.value.nodeId, at: pos };")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        # 快照拍在挂精灵**之前** ⇒ 重做回来的是个没精灵的空节点。
        # 画面上与"资产没加载"完全一样，只有查组件（或读帧名）才分得出来。
        "name": "M389 加资产时在挂精灵之前拍快照（重做回来是个空节点）",
        "file": "src/extensions/editor/undo-ops.ts",
        "pairs": [("  scene.attach(node.id, () => comp);\n  scene.flush();\n  const sprite = node.get<Sprite>(SPRITE_TYPE);",
                   "  const sprite = node.get<Sprite>(SPRITE_TYPE);")],
        "test": "tests/extensions/editor-asset-node.test.ts",
    },
    {
        # 把 `.meta` sidecar 当普通文件处理 ⇒ 每张图在面板里出现两次，
        # 其中一条（.meta）点下去什么都不会发生。
        "name": "M390 .meta sidecar 被当成资产列出来（每张图出现两次）",
        "file": "src/extensions/editor/asset-list.ts",
        "pairs": [('    if (path.toLowerCase().endsWith(".meta")) {',
                   "    if (false) {")],
        "test": "tests/extensions/editor-assets.test.ts",
    },
    {
        # 清单过期：删掉一项。这条变异打在**数据文件**上，语义就是真实事故
        # （加了 png 忘了写清单 / 删了文件没销账），不是把代码改坏。
        "name": "M391 资产清单漏了一项（面板少一行，且不会有任何报错）",
        "file": "web/assets-manifest.json",
        "pairs": [('    "ruler.png",\n', "")],
        "test": "tests/extensions/editor-assets.test.ts",
    },
    # ---- 批87：把真实图片烘进图集（半条链接上）
    {
        # 一张坏图就整体失败 ⇒ 编辑器直接开不起来（人看到的只是白屏）。
        "name": "M392 有一张图解不开就整体失败（一张坏图毁掉整个编辑器）",
        "file": "src/extensions/editor/asset-bake.ts",
        "pairs": [("      skipped.push({ name, reason: dec.error.code });\n      continue;",
                   "      return err(dec.error);")],
        "test": "tests/extensions/editor-asset-bake.test.ts",
    },
    {
        # 不挡重名 ⇒ 两个同名源一起交给合成器，它报 DUPLICATE_FRAME。
        # 症状是"我加了一张图，整个世界都烘不出来"。
        "name": "M393 不挡重名（两个同名源一起交给合成器，整锅失败）",
        "file": "src/extensions/editor/asset-bake.ts",
        "pairs": [("    if (seen.has(name)) {", "    if (seen.has(name) && false) {")],
        "test": "tests/extensions/editor-asset-bake.test.ts",
    },
    {
        # 帧名不排序 ⇒ 面板顺序随 Map 插入序（也就是随清单顺序）变，
        # 判据靠顺序就变成碰运气。
        "name": "M394 帧名不排序（顺序随清单变，面板每次不一样）",
        "file": "src/extensions/editor/asset-bake.ts",
        "pairs": [("    frames: Array.from(built.value.frames.keys()).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)),",
                   "    frames: Array.from(built.value.frames.keys()),")],
        "test": "tests/extensions/editor-asset-bake.test.ts",
    },
    {
        # 「有帧」只看帧名、不看是不是位图 ⇒ 名字撞上 png 的**文本**资产
        # （ui-font.fnt）被判成可加入，点下去造出一个指向字体图的精灵。
        "name": "M395 「有帧」只看帧名（文本资产因名字撞车被当成可渲染）",
        "file": "src/extensions/editor/asset-list.ts",
        "pairs": [("    const inAtlas = raster && frames !== undefined && frames.has(name);",
                   "    const inAtlas = frames !== undefined && frames.has(name);")],
        "test": "tests/extensions/editor-assets.test.ts",
    },
    {
        # 页面级：清单与图片用同一个 base 读 ⇒ 图片路径少一层 assets/，
        # 10 张全 404、静默退回程序化图集，而画面上照样有树有石头。
        # 这就是批87 第一次跑自检时真实发生的那一幕。
        "name": "M396 读图用错 base（10 张全 404，静默退回程序化图集）",
        "file": "src/editor-entry.ts",
        "pairs": [("    const r = await assetsFs.readBinary(e.path);",
                   "    const r = await fs.readBinary(e.path);")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        # 页面级：命令面不查 inAtlas，只靠按钮禁用 ⇒ 双击/命令面能绕过。
        # ★ 批101 改了这条的**分辨方式**：原来靠「名字撞车」——ui-font.fnt 的名字正好等于
        #   烘进来的 ui-font.png 的帧名，于是模型层会放行、只有命令面这道闸能拦。
        #   「UI 页不进世界图集」落地后那个帧名没了，模型层也会拒、而且是**同一个错误码**
        #   ⇒ ok / code 两条实现一模一样，整轮变异里 M397 因此变绿（只有跑整轮才发现）。
        #   剩下的区别是「人看到的那句话」（命令面：不能加进场景、它不是位图；
        #   模型层：图集里没有帧），判据因此改成钉住命令面自己那句话。
        # 与 M395 是两层：那条在模型层算错，这条在命令面不查。
        "name": "M397 加入场景不查 inAtlas（禁用的按钮被命令面绕过去）",
        "file": "src/editor-entry.ts",
        "pairs": [("  if (!entry.inAtlas) {", "  if (false) {")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        # 「世界没变就不重建」这条一旦去掉，代价是**每次**点播放再停止都会把整个工程
        # 换一遍节点实例（`loadScene` 先 clear 再重建），而画面上完全看不出来。
        # 判据靠 `scene.find(id)` 的恒等来分，值相等是分不开的。
        "name": "M398 停止试玩一律重建场景（世界一个字节都没变也重建）",
        "file": "src/extensions/editor/play-session.ts",
        "pairs": [("  if (now === s.text) return ok({ rolledBack: false, made: 0, skipped: [] });",
                   "  if (false) return ok({ rolledBack: false, made: 0, skipped: [] });")],
        "test": "tests/extensions/editor-play-session.test.ts",
    },
    {
        # 同一条 if 的另一种写错方向：永远当"没变" ⇒ 从不回滚 ⇒ 试玩一次工程就永久变样。
        # 两个方向都要钉，因为它们的**症状完全不同**（这个是"世界脏了"，上一个是"实例换了"）。
        "name": "M399 停止试玩从不回滚（试玩一次工程就永久变样）",
        "file": "src/extensions/editor/play-session.ts",
        "pairs": [("  if (now === s.text) return ok({ rolledBack: false, made: 0, skipped: [] });",
                   "  if (true) return ok({ rolledBack: false, made: 0, skipped: [] });")],
        "test": "tests/extensions/editor-play-session.test.ts",
    },
    {
        # ★ 这条是批88 那个真缺陷本身：玩家节点只挂了标记、没挂控制器。
        #   模块单测（`player-controller.test.ts`）自己造带控制器的节点，永远是绿的；
        #   只有"造玩家的那个函数"上的判据能抓住。
        "name": "M400 玩家节点不挂控制器（两个宿主按 WASD 谁也不动）",
        "file": "src/extensions/worldgen/spawn.ts",
        "pairs": [("  scene.attach(nodeId, () => new PlayerController());\n", "")],
        "test": "tests/extensions/spawn.test.ts",
    },
    {
        # 页面级：编辑器不驱动控制器模块 ⇒ 世界真的一动不动，`driven` 恒为 0。
        # 与 M400 是两个方向（一个不挂、一个不驱动），缺哪个都"看起来能玩"。
        "name": "M401 编辑器不驱动控制器（模块在，但每 tick 白转）",
        "file": "src/editor-entry.ts",
        "pairs": [("    controllerMod.update(tick, dt);\n", "")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        # 试玩期间的字段改动进了撤销栈 ⇒ 停播回滚之后，历史里那条 op 的 after 指向
        # 一个已经不存在的变化：下一次撤销会"把值改成人没设过的数"。
        "name": "M402 试玩期间的改动也进撤销栈（撤销时重放一个不存在的变化）",
        "file": "src/editor-entry.ts",
        "pairs": [("  if (playSession !== null) {", "  if (false) {")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        # 快照拍晚了/拍重了：每次 play/step 都重拍 ⇒ 回滚基准变成"已经跑过之后"，
        # 于是停了试玩世界仍然是脏的，而"回滚成功"照样报 true。
        "name": "M403 每次播放/单步都重拍快照（回滚基准被拍在世界变脏之后）",
        "file": "src/editor-entry.ts",
        # 批92：`beginPlay` 里那句被包进了一个 if 块（里面还要建流程层、重置边走边看的门状态），
        # 所以靶子从"单行 if"改成"块首 + 第一句"，仍然钉住"守卫不许去掉"这一件事。
        "pairs": [("  if (playSession === null) {\n    playSession = beginPlaySession(app.scene);",
                   "  if (true) {\n    playSession = beginPlaySession(app.scene);")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M404 拖资产落在视图中心（拖到哪儿都跑到中间去）",
        # 批89 唯一真正的语义就在这一行：点按钮落中心是对的（人没指定位置），
        # 拖动再落中心就是「我明明拖到那儿，它跑到中间去了」。
        "file": "src/editor-entry.ts",
        "pairs": [("  const pos = at ?? viewCenterLocal();", "  const pos = viewCenterLocal();")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M405 落点没减去画布原点（拖到画布右下，落在别处）",
        # 少了这一步，落点会整体偏掉 canvas 在页面里的偏移量 —— 看起来「差一点」，
        # 而"差一点"最容易被人当成自己的手抖。
        "file": "src/editor-entry.ts",
        "pairs": [("  const cx = clientX - r.left;", "  const cx = clientX;")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M406 世界坐标 XZ 互换（2.5D 里 y 就是 z，这一步很容易写反）",
        "file": "src/editor-entry.ts",
        "pairs": [("  const w = canvasToWorld(cx, cy);\n  return { x: w.x, y: w.z };",
                   "  const w = canvasToWorld(cx, cy);\n  return { x: w.z, y: w.x };")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M407 松手在画布外也照样加节点（随手一拖就多一个）",
        "file": "src/editor-entry.ts",
        "pairs": [("  if (at === null) {", "  if (false) {")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        # ★ 这条打的是 `tools/worktree_guard.py`（工作区守护）。它必须住在**另一个文件**里：
        #   靶子是写在本表里的字符串字面量，而替换命中"第一次出现"——
        #   同处一文件时第一次出现就是靶子自己，变异会把自己的靶子改掉、实现纹丝不动，
        #   于是"没被抓住"，而自检照样通过。第一版就这么假绿了一轮。
        #   归一之后：守护恒空与"一切都干净"在输出上完全一致（报告照旧说还原干净），
        #   只能靠 `--selftest` 里那几条自造情形来分辨。
        "name": "M408 工作区守护的差异比较恒空（残留永远报不出来）",
        "file": "tools/worktree_guard.py",
        "pairs": [("        elif before[name] != after[name]:", "        elif False:")],
        # ★ `sys.executable` 而不是字面量 `python`：runner 上常常只有 `python3`，
        #   而"找不到解释器"会以"命令跑不起来 ⇒ 退出码非 0 ⇒ 被判成变异被抓住"
        #   的形式**假绿**（判据根本没执行）。用正在跑本脚本的那个解释器，两边一致。
        "cmd": [sys.executable, "tools/worktree_guard.py", "--selftest"],
    },
    {
        "name": "M409 切走前不保存源场景（切回来刚加的节点就没了）",
        # 这是「多场景」最典型的静默数据丢失：切换成功、目标场景也对，
        # 只有切回来时才发现少了东西 —— 而人会以为是引擎把节点弄丢了。
        "file": "src/extensions/editor/project.ts",
        "pairs": [("  const saved = saveCurrent(deps, p);\n  if (!saved.ok) {\n    return err(\n      engineError(EDIT_SAVE_FAILED, `切走前保存「${from}」失败：${saved.error.message}`, {",
                   "  const saved = ok({ text: \"\", changed: false });\n  if (!saved.ok) {\n    return err(\n      engineError(EDIT_SAVE_FAILED, `切走前保存「${from}」失败：${saved.error.message}`, {")],
        "test": "tests/extensions/editor-project.test.ts",
    },
    {
        "name": "M410 切到当前场景也走装载（整棵树被换成新实例）",
        # 症状：点一下当前那一行，撤销栈/选中集/组件运行时状态全没了，
        # 而节点数、名字、id 全都一样 —— 界面上看不出发生过什么。
        "file": "src/extensions/editor/project.ts",
        "pairs": [("  if (name === p.current) return ok(report(\"noop\", p.current, name, false, null));",
                   "  if (false) return ok(report(\"noop\", p.current, name, false, null));")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M411 目标文档坏了也把 current 改过去（之后每次切走都写错槽位）",
        "file": "src/extensions/editor/project.ts",
        "pairs": [("  const opened = openDocument(deps, target.text);\n  if (!opened.ok) {",
                   "  const opened = openDocument(deps, target.text);\n  if (false) {")],
        "test": "tests/extensions/editor-project.test.ts",
    },
    {
        "name": "M412 新建场景不查名字占用（第二次「新建」变成切到已有场景）",
        "file": "src/extensions/editor/project.ts",
        "pairs": [("    if (slotOf(p, candidate) === undefined) return candidate;",
                   "    return candidate;")],
        "test": "tests/extensions/editor-project.test.ts",
    },
    {
        "name": "M413 删当前场景不装载邻居（列表说切了，场景里还是被删的那份）",
        "file": "src/extensions/editor/project.ts",
        "pairs": [("  const opened = openDocument(deps, next.text);",
                   "  const opened = ok({ made: 0, skipped: [], droppedHistory: 0, droppedSelection: 0 });")],
        "test": "tests/extensions/editor-project.test.ts",
    },
    {
        "name": "M414 不挡「删到只剩一个」（工程里可以一份文档都不剩）",
        "file": "src/extensions/editor/project.ts",
        "pairs": [("  if (p.scenes.length <= 1) {", "  if (p.scenes.length <= 0) {")],
        "test": "tests/extensions/editor-project.test.ts",
    },
    {
        "name": "M415 试玩期间照样新建/切场景（停播会把旧场景的文档装进新场景）",
        "file": "src/editor-entry.ts",
        "pairs": [("  if (playSession !== null) {\n    const msg = \"试玩还没停：先点「停止」再新建场景\";",
                   "  if (false) {\n    const msg = \"试玩还没停：先点「停止」再新建场景\";")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M416 nodeSerial 用 id 冒充实例（「没重建」这条保证立刻失去观测）",
        # 这是**判据自己**的靶子：一旦用 id 冒充实例，跨场景往返（实例必然被换）
        # 与 noop（实例没换）就再也分不开了 —— 而那也是本批唯一能分辨两者的观测量。
        "file": "src/editor-entry.ts",
        "pairs": [("      const n = app.scene.find(id);\n      return n === undefined ? -1 : serialOf(n);",
                   "      const n = app.scene.find(id);\n      return n === undefined ? -1 : n.id;")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M417 场景面板只清不画（模型全对、面板空着）",
        # 这一条打的是**接线**：所有场景判据走的都是命令面（读模型），
        # 面板没画出来时它们全绿 —— 而人打开页面看到的是一块空列表。
        # 所以判据必须读 DOM（#scenelist 的行数 / 高亮），这条变异就是它的靶子。
        "file": "src/editor-entry.ts",
        "pairs": [("    sceneListEl.appendChild(row);", "    void row;")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M418 存盘前不导出当前场景（存档停在上一次切场景的内容）",
        # 面板上照样写着「已存 N 字节」，而人刚才的改动一个字都没进去 ——
        # 只有关掉页面重开才看得出来，那时已经晚了。
        "file": "src/editor-entry.ts",
        "pairs": [("  const saved = saveCurrent(docDeps(app), p);",
                   "  const saved = { ok: true as const, value: { text: \"\", changed: false } };")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M419 试玩期间照样写存档（把试玩跑出来的世界当成文档）",
        "file": "src/editor-entry.ts",
        "pairs": [("  if (app === null || p === null) return;\n  if (playSession !== null) {",
                   "  if (app === null || p === null) return;\n  if (false) {")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M420 启动就用默认世界覆盖存档（用户的几个场景被一份新世界顶掉）",
        # 这是落盘最贵的一种错：不报错、界面正常，只是"我上次做的场景没了"。
        "file": "src/editor-entry.ts",
        "pairs": [("  project = adoptStoredProject(app, t0.value);",
                   "  project = createProject(app.scene.name, t0.value);\n  persistProject();")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M421 恢复了场景列表但不装内容（切过去是个空场景）",
        # 与 M420 互补：M420 让"列表都不对"，这条让"列表对、内容空" ——
        # 只有"切过去看节点在不在"能咬住它。
        "file": "src/editor-entry.ts",
        "pairs": [("  if (cur.text !== freshText) {", "  if (false) {")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M422 存档写到别的键上（写完就再也读不回来）",
        "file": "src/extensions/editor/project-file.ts",
        "pairs": [("export const PROJECT_STORAGE_KEY = \"dst.editor.project.v1\";",
                   "export const PROJECT_STORAGE_KEY = \"dst.editor.project.v1.wrong\";")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M423 解析不校验 current 在列表里（打开之后在错的场景上编辑）",
        "file": "src/extensions/editor/project-file.ts",
        "pairs": [("  if (typeof current !== \"string\" || !seen.has(current)) {", "  if (false) {")],
        "test": "tests/extensions/editor-project-file.test.ts",
    },
    {
        "name": "M424 解析不拦重名场景（切换只会命中第一份）",
        "file": "src/extensions/editor/project-file.ts",
        "pairs": [("    if (seen.has(name)) {", "    if (false) {")],
        "test": "tests/extensions/editor-project-file.test.ts",
    },
    {
        "name": "M425 解析不拦空场景表（空工程顶着一份不存在的文档）",
        "file": "src/extensions/editor/project-file.ts",
        "pairs": [("  if (o.scenes.length === 0) {", "  if (false) {")],
        "test": "tests/extensions/editor-project-file.test.ts",
    },
    {
        "name": "M426 存档写不进去也报成功（配额满了还说已存）",
        "file": "src/extensions/editor/project-file.ts",
        "pairs": [("    return err(engineError(EDIT_PROJECT_STORE, `工程写不进去：${errText(e)}`));",
                   "    return ok({ bytes: 0, scenes: 0 });")],
        "test": "tests/extensions/editor-project-file.test.ts",
    },
    # ---------------- 批92：关卡流程（传送门 / 跳转）
    #
    # ★ 这一组的靶子全在**新文件**里（flow/），所以不会撞上既有判据的断言 ——
    #   但 M433 是例外：它打在**接线**上（loop 里那一句 autoPortal），
    #   只能由浏览器自检抓（Node 侧证不到"每 tick 有没有喂位置"），所以它走 cmd。
    {
        "name": "M427 站在门里每 tick 都触发（把边沿写成电平）",
        # 症状：进门跳走 → 目标场景又把人放在门里 → 再跳…… 画面抖一下回到原地，
        # 而日志里是一串成功的跳转。只有"连续喂 10 次只该触发 1 次"这条能分开。
        "file": "src/extensions/flow/portal.ts",
        "pairs": [("    if (key === this.key) return null;",
                   "    if (key === null && this.key === null) return null;")],
        "test": "tests/extensions/flow-portal.test.ts",
    },
    {
        "name": "M428 reseed 什么都不记（落地就站在另一扇门里 ⇒ 立刻弹回去）",
        "file": "src/extensions/flow/portal.ts",
        "pairs": [("    this.key = keyOf(hitTestPortals(x, z, portals));",
                   "    void x; void z; void portals;")],
        "test": "tests/extensions/flow-portal.test.ts",
    },
    {
        "name": "M429 触发半径写成开区间（恰好踩在边界上的门进不去）",
        "file": "src/extensions/flow/portal.ts",
        "pairs": [("    if (d2 <= p.radius * p.radius) hits.push({ portal: p, distance2: d2 });",
                   "    if (d2 < p.radius * p.radius) hits.push({ portal: p, distance2: d2 });")],
        "test": "tests/extensions/flow-portal.test.ts",
    },
    {
        "name": "M430 重叠时取最远的那扇门（两次运行可能跳向不同场景）",
        "file": "src/extensions/flow/portal.ts",
        "pairs": [("  return hits.length === 0 ? null : hits[0]!.portal.name;",
                   "  return hits.length === 0 ? null : hits[hits.length - 1]!.portal.name;")],
        "test": "tests/extensions/flow-portal.test.ts",
    },
    {
        "name": "M431 跳场景不携带状态（换了个人：血满、饱食 100、背包空）",
        # 这是"少了点什么但日志干净"的典型：跳转成功、世界对，只有人不是原来那个人。
        #
        # ★ 靶子换过位置（批95）：原先打在"读携带"那行，而那一行在加门锁时改名为
        #   `carry0`（`carry` 这个名字让给了"扣完门票之后的那份"），整行文本一变就报
        #   靶子漂移。现在打在**回灌那一步**：携带读出来了、`carried` 标志也是 true，
        #   只是喂给 `applyCarry` 的是个空包 —— 目标玩家保持他自己那份（血满、饱食 100、
        #   背包空）。这比"读成 null"更贴这条变异的真实手感：日志与标志位全对，人换了。
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [("    const applied = carry === null ? null : applyCarry(scene, dstPlayer, carry);",
                   "    const applied = carry === null ? null : applyCarry(scene, dstPlayer, { items: [], health: null, hunger: null });")],
        "test": "tests/extensions/flow-jump.test.ts",
    },
    {
        "name": "M432 目标场景没有玩家也照跳（人站在空地里按 WASD 谁也不动）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [("    if (!snapshotHasPlayer(snap)) {",
                   "    if (false && snapshotHasPlayer(snap)) {")],
        "test": "tests/extensions/flow-jump.test.ts",
    },
    {
        "name": "M433 帧循环里不喂玩家位置（门在场景里画着，走过去毫无反应）",
        # ★ 这条只打**接线**：flow 的三层模型全对、判据全绿，但没有人每 tick 问一次
        #   "玩家现在在哪"。Node 侧永远看不见这种缺失（没有宿主），只能靠浏览器自检。
        # ★ 批98：两处驱动点（`loop()` 与命令面 `step()`）收成了一个 `driveTick()`，
        #   靶子跟着落到那里 —— 现在删掉这一句，两条路同时断，靠浏览器自检抓。
        "file": "src/editor-entry.ts",
        "pairs": [("  autoPortal();\n  stepCurtain();",
                   "  stepCurtain();")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M434 装不下就整份丢掉（目标背包只小一格，一整车木头全没了）",
        "file": "src/extensions/flow/carry.ts",
        "pairs": [("  while (left > 0) {",
                   "  while (false && left > 0) {")],
        "test": "tests/extensions/flow-jump.test.ts",
    },
    {
        "name": "M435 血量不夹上限（20 血带进上限 5 的世界，血条溢出）",
        "file": "src/extensions/flow/carry.ts",
        "pairs": [("      if (want > hp.maxHp) {",
                   "      if (false) {")],
        "test": "tests/extensions/flow-jump.test.ts",
    },
    {
        "name": "M436 跳到当前场景也走装载（点回当前行把整棵树的实例换掉）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [("    if (to === this.current) {",
                   "    if (to === this.current && false) {")],
        "test": "tests/extensions/flow-jump.test.ts",
    },
    {
        "name": "M437 回访时又按文档重建（离开不重置这件事整个没做）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [("    const memo = this.visited.get(to);",
                   "    const memo = this.visited.get(to + \"\\u0000\");")],
        "test": "tests/extensions/flow-progress.test.ts",
    },
    {
        "name": "M438 入册时不给玩家归位（回访落在上次离开的地方，能绕过整张地图）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [("    this.visited.set(from, stampEntry(before, leavingEntry));",
                   "    this.visited.set(from, before);")],
        "test": "tests/extensions/flow-progress.test.ts",
    },
    {
        "name": "M439 回访不清目标背包（同一件东西算两遍：12 根变 24 根）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [("      clearInventory(scene, dstPlayer);",
                   "      void clearInventory;")],
        "test": "tests/extensions/flow-progress.test.ts",
    },
    {
        "name": "M440 读档只换当前场景、不恢复走过的场景（之后再进那一关又按文档重建）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [("      if (name !== save.current) this.visited.set(name, snap);",
                   "      if (name !== save.current && false) this.visited.set(name, snap);")],
        "test": "tests/extensions/flow-progress.test.ts",
    },
    {
        "name": "M441 存档的当前场景没有玩家也放行（读进去没人可操控）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [("    if (!snapshotHasPlayer(cur)) {", "    if (false) {")],
        "test": "tests/extensions/flow-progress.test.ts",
    },
    {
        "name": "M442 存档里的场景不按名字排序（同一局的字节取决于先后去过哪）",
        "file": "src/extensions/flow/game-save.ts",
        "pairs": [("  const names = [...docs.keys()].sort(cmpName);",
                   "  const names = [...docs.keys()];")],
        "test": "tests/extensions/flow-progress.test.ts",
    },
    {
        "name": "M443 存档允许场景重名（后一份覆盖前一份，读档少一整块进度）",
        "file": "src/extensions/flow/game-save.ts",
        "pairs": [("    if (seen.has(name)) {", "    if (false) {")],
        "test": "tests/extensions/flow-progress.test.ts",
    },
    {
        "name": "M444 存档版本太新也照读（旧引擎读新档，缺的字段静默变默认值）",
        "file": "src/extensions/flow/game-save.ts",
        "pairs": [("  if (format > GAME_SAVE_FORMAT) {", "  if (format > GAME_SAVE_FORMAT + 99) {")],
        "test": "tests/extensions/flow-progress.test.ts",
    },
    {
        "name": "M445 存档说的当前场景不在列表里也接受（读的时候必然对不上）",
        "file": "src/extensions/flow/game-save.ts",
        "pairs": [("  if (!seen.has(current)) {", "  if (false) {")],
        "test": "tests/extensions/flow-progress.test.ts",
    },
    {
        "name": "M446 试玩存档说存了、其实没落盘（面板写着已存，关掉页面全没）",
        "file": "src/editor-entry.ts",
        "pairs": [("    window.localStorage.setItem(PLAY_SAVE_KEY, text);",
                   "    void PLAY_SAVE_KEY;")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        "name": "M447 变异日志恢复了名字、不写回字节（被强杀之后源码仍是变异体）",
        "file": "tools/mutation_journal.py",
        "pairs": [("        (root / rel).write_bytes(original)", "        (root / rel).read_bytes()")],
        "cmd": [sys.executable, "tools/mutation_journal.py", "--selftest"],
    },
    {
        "name": "M448 变异日志只写标记不写原文（要恢复的时候没有原文可写）",
        "file": "tools/mutation_journal.py",
        "pairs": [("    _fsync_write(d / \"active.bin\", original)", "    pass")],
        "cmd": [sys.executable, "tools/mutation_journal.py", "--selftest"],
    },
    {
        # ★ 靶子随扫尾方式改过（批96）：原先是"删标记 + 删原文"，现在扫尾只改标记
        #   （删文件会撞上环境的每轮删除上限，整轮被中止 —— 见 mutation_journal 文件头）。
        #   这条打在**把标记改成 restored** 那一句上：不改 ⇒ 下一轮启动会误恢复一遍。
        "name": "M449 还原完不改标记（下一次启动误报「上次被强杀」并把文件再写一遍）",
        "file": "tools/mutation_journal.py",
        "pairs": [('    _fsync_write(d / _MARK, json.dumps(done, ensure_ascii=False).encode("utf-8"))',
                   "    pass")],
        "cmd": [sys.executable, "tools/mutation_journal.py", "--selftest"],
    },
    {
        # ★ 把上一批刚修掉的死法原样放回去：整轮 459 条 ⇒ 900 多次删除 ⇒ 撞上
        #   「每轮删除上限 50」的守卫 ⇒ 变异器在 25 条处静默中止，且**看起来像跑完了**。
        "name": "M460 扫尾又改成删文件（整轮 900 多次删除，撞上每轮删除上限就静默中止）",
        "file": "tools/mutation_journal.py",
        "pairs": [('    _fsync_write(d / _MARK, json.dumps(done, ensure_ascii=False).encode("utf-8"))',
                   "    (d / _MARK).unlink(); (d / _BIN).unlink()")],
        "cmd": [sys.executable, "tools/mutation_journal.py", "--selftest"],
    },
    {
        "name": "M450 原文哈希对不上也照写（把一个文件写成既非原文也非变异体的第三种东西）",
        "file": "tools/mutation_journal.py",
        "pairs": [("    if want and got != want:", "    if False:")],
        "cmd": [sys.executable, "tools/mutation_journal.py", "--selftest"],
    },
    {
        "name": "M451 没有标记也去恢复（无日志时凭空改动文件）",
        "file": "tools/mutation_journal.py",
        "pairs": [("    if not mark.exists():", "    if False:")],
        "cmd": [sys.executable, "tools/mutation_journal.py", "--selftest"],
    },
    {
        "name": "M452 关着的门照样算命中（作者还没开通的路，玩家一走就掉进另一个场景）",
        "file": "src/extensions/flow/portal.ts",
        "pairs": [("    if (!p.open) continue;", "    if (false) continue;")],
        "test": "tests/extensions/flow-door.test.ts",
    },
    {
        "name": "M453 要钥匙但数量不合法也照过（那扇门永远打不开，而作者看不出为什么）",
        "file": "src/extensions/flow/portal.ts",
        "pairs": [('    if (p.requires !== "" && (!Number.isInteger(p.requiresCount) || p.requiresCount <= 0)) {', "    if (false) {")],
        "test": "tests/extensions/flow-door.test.ts",
    },
    {
        "name": "M454 钥匙不够也放行（白拿一次通关，而手里那两个木头一个没少）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [("      if (have < via.requiresCount) {", "      if (false) {")],
        "test": "tests/extensions/flow-door.test.ts",
    },
    {
        "name": "M455 不要消耗也扣钥匙（「资格」和「消耗品」混成一件事）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [("    if (locked && via.consume && carry !== null) {", "    if (locked && carry !== null) {")],
        "test": "tests/extensions/flow-door.test.ts",
    },
    {
        "name": "M456 门票扣了但不生效（报告里写着扣 3 个，身上一个没少）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [("      carry = paid.carry;", "      void paid;")],
        "test": "tests/extensions/flow-door.test.ts",
    },
    {
        "name": "M457 扣门票时什么都不扣（走一遍纯函数，账单一分没动）",
        "file": "src/extensions/flow/carry.ts",
        "pairs": [("    if (it.kind !== kind || left === 0) {", "    if (true) {")],
        "test": "tests/extensions/flow-door.test.ts",
    },
    {
        "name": "M458 扣光的条目留成 count:0（背包里多出一种「有但为 0」的东西）",
        "file": "src/extensions/flow/carry.ts",
        "pairs": [("    if (it.count - take > 0) items.push({ kind: it.kind, count: it.count - take });", "    items.push({ kind: it.kind, count: it.count - take });")],
        "test": "tests/extensions/flow-door.test.ts",
    },
    {
        "name": "M459 停播回滚之后不重新指向玩家（heroId 指向一个不在场景里的 id）",
        "file": "src/editor-entry.ts",
        "pairs": [("  const np = findPlayerId(app.scene);\n  if (np !== null) heroId = np;\n  if (!r.ok) {", "  const np = findPlayerId(app.scene);\n  void np;\n  if (!r.ok) {")],
        "cmd": ["node", "tools/editor-selftest.mjs", "--build"],
        "env_exit": 2,
    },
    {
        # ★ 这一组打的是「缺口清单对账」（`tools/gap-check.mjs`）。它今天的输出永远是 0 条，
        #   所以每条规则都必须靠合成语料咬住 —— 判据在 `tests/tools/gap-check.test.ts`。
        "name": "M461 三级标题也当分节符（§六 的 ### 小节之下的缺口行被整段跳过）",
        "file": "tools/gap-check.mjs",
        "pairs": [('    if (lines[i].startsWith("## ")) break;',
                   '    if (lines[i].startsWith("## ") || lines[i].startsWith("### ")) break;')],
        "test": "tests/tools/gap-check.test.ts",
    },
    {
        "name": "M462 行号用片段内序号（报 PROGRESS.md:3 让人去错地方，比不报更坏）",
        "file": "tools/gap-check.mjs",
        "pairs": [("    out.push({ no: i + 1, text: lines[i] });",
                   "    out.push({ no: out.length + 1, text: lines[i] });")],
        "test": "tests/tools/gap-check.test.ts",
    },
    {
        "name": "M463 已消除判定整个删掉（做完的缺口也照报，清单永远红）",
        # ★ 靶子带上行注释当上下文：批131 抽成 alreadyClosed 后两处调用点逐字相同
        "file": "tools/gap-check.mjs",
        "pairs": [(
            '    // ② 只看首格：正文里划掉一句话不能顶替"这条缺口已经消除了"（`alreadyClosed`）\n    if (alreadyClosed(head)) continue;\n',
            '    // ② 只看首格：正文里划掉一句话不能顶替"这条缺口已经消除了"（`alreadyClosed`）\n    if (false) continue;\n',
        )],
        "test": "tests/tools/gap-check.test.ts",
    },
    {
        # 这是 C12 那个形态本身：正文里划掉了旧等待条件，缺口名还挂着。
        # ★ 靶子带上行注释当上下文：批131 抽成 alreadyClosed 后两处调用点逐字相同
        "name": "M464 正文里划掉就算已消除（C12 那种行被自己的正文免责）",
        "file": "tools/gap-check.mjs",
        "pairs": [(
            '    // ② 只看首格：正文里划掉一句话不能顶替"这条缺口已经消除了"（`alreadyClosed`）\n    if (alreadyClosed(head)) continue;\n',
            '    // ② 只看首格：正文里划掉一句话不能顶替"这条缺口已经消除了"（`alreadyClosed`）\n    if (alreadyClosed(text)) continue;\n',
        )],
        "test": "tests/tools/gap-check.test.ts",
    },
    {
        # 正则写窄 ⇒ 一条都扫不到 ⇒ 判据"绿着但没在扫"，与真的没问题完全一样。
        "name": "M465 只认 src/ 路径（tools/ 点名一个都扫不到，判据永远绿）",
        "file": "tools/gap-check.mjs",
        "pairs": [(r"const TOOL_PATH = /tools\/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+/g;",
                   r"const TOOL_PATH = /src\/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+/g;")],
        "test": "tests/tools/gap-check.test.ts",
    },
    {
        "name": "M466 表头分隔行也当缺口行（缺口行数多算，§六 的规模看着比实际大）",
        "file": "tools/gap-check.mjs",
        "pairs": [("    if (row === null || isSeparator(row)) continue;",
                   "    if (row === null) continue;")],
        "test": "tests/tools/gap-check.test.ts",
    },
    {
        "name": "M467 工具存在就算（不看它在不在 CI 里：规划中的路径一出现就红，假红）",
        "file": "tools/gap-check.mjs",
        "pairs": [("    const hits = [...new Set(paths)].filter((p) => exists(p) && ciText.includes(p));",
                   "    const hits = [...new Set(paths)].filter((p) => exists(p));")],
        "test": "tests/tools/gap-check.test.ts",
    },
    {
        "name": "M468 交火提前到第一拍（幕布还没落满世界就换了）",
        "file": "src/extensions/flow/curtain.ts",
        "pairs": [
            [
                "    if (next < outTicksOf(spec)) {",
                "    if (next < 1) {"
            ]
        ],
        "test": "tests/extensions/flow-curtain.test.ts"
    },
    {
        "name": "M469 落幕只走到一半（换世界那一刻画面从半黑跳到全黑）",
        "file": "src/extensions/flow/curtain.ts",
        "pairs": [
            [
                "    return Math.min(1, state.elapsed / outTicksOf(spec));",
                "    return Math.min(1, state.elapsed / (outTicksOf(spec) * 2));"
            ]
        ],
        "test": "tests/extensions/flow-curtain.test.ts"
    },
    {
        "name": "M470 起幕慢一倍（黑屏多留半秒，而且永远回不到 idle）",
        "file": "src/extensions/flow/curtain.ts",
        "pairs": [
            [
                "    return Math.max(0, 1 - state.elapsed / inTicksOf(spec));",
                "    return Math.max(0, 1 - state.elapsed / (inTicksOf(spec) * 2));"
            ]
        ],
        "test": "tests/extensions/flow-curtain.test.ts"
    },
    {
        "name": "M471 幕布在动时也接新跳（两次换世界都没有视觉证据）",
        "file": "src/extensions/flow/curtain.ts",
        "pairs": [
            [
                "  if (state.phase !== \"idle\") {",
                "  if (false) {"
            ]
        ],
        "test": "tests/extensions/flow-curtain.test.ts"
    },
    {
        "name": "M472 取消时不清待办（下一拍会执行上一局没做完的跳转）",
        "file": "src/extensions/flow/curtain.ts",
        "pairs": [
            [
                "  return { ...CURTAIN_IDLE, fired: state.fired, cancelled: state.cancelled + 1, refused: state.refused };",
                "  return { ...CURTAIN_IDLE, fired: state.fired, cancelled: state.cancelled + 1, refused: state.refused, target: state.target };"
            ]
        ],
        "test": "tests/extensions/flow-curtain.test.ts"
    },
    {
        "name": "M473 拍数下限去掉（outTicks=0 时 alpha 是 NaN，整屏变黑）",
        "file": "src/extensions/flow/curtain.ts",
        "pairs": [
            [
                "  return Math.max(1, Math.floor(spec.outTicks));",
                "  return Math.floor(spec.outTicks);"
            ]
        ],
        "test": "tests/extensions/flow-curtain.test.ts"
    },
    {
        "name": "M474 交火不记账（fired 恒 0，接线判据分不出有没有走幕布）",
        "file": "src/extensions/flow/curtain.ts",
        "pairs": [
            [
                "      state: { ...state, phase: \"in\", elapsed: 0, target: null, fired: state.fired + 1 },",
                "      state: { ...state, phase: \"in\", elapsed: 0, target: null, fired: state.fired },"
            ]
        ],
        "test": "tests/extensions/flow-curtain.test.ts"
    },
    {
        "name": "M475 幕布只画一个三角形（另半个屏幕是亮的）",
        "file": "src/extensions/render/render-module.ts",
        "pairs": [
            [
                "  const xy = [\n    [-1, -1],\n    [1, -1],\n    [1, 1],\n    [-1, -1],\n    [1, 1],\n    [-1, 1],\n  ] as const;",
                "  const xy = [\n    [-1, -1],\n    [1, -1],\n    [1, 1],\n  ] as const;"
            ]
        ],
        "test": "tests/extensions/render-curtain.test.ts"
    },
    {
        "name": "M476 幕布的 alpha 不夹（NaN 传到 GPU 是整屏变黑）",
        "file": "src/extensions/render/render-module.ts",
        "pairs": [
            [
                "  const a = Number.isFinite(alpha) ? Math.max(0, Math.min(1, alpha)) : 0;",
                "  const a = alpha;"
            ]
        ],
        "test": "tests/extensions/render-curtain.test.ts"
    },
    {
        "name": "M477 alpha 为 0 也画幕布（每帧白画一次全屏）",
        "file": "src/extensions/render/render-module.ts",
        "pairs": [
            [
                "    if (curtain > 0 && curtainVbo !== null && pipeline !== null) {",
                "    if (curtain >= 0 && curtainVbo !== null && pipeline !== null) {"
            ]
        ],
        "test": "tests/extensions/render-curtain.test.ts"
    },
    {
        "name": "M478 setCurtain 不生效（状态机说该画，渲染层永远是 0）",
        "file": "src/extensions/render/render-module.ts",
        "pairs": [
            [
                "      curtain = Number.isFinite(alpha) ? Math.max(0, Math.min(1, alpha)) : 0;",
                "      curtain = 0;"
            ]
        ],
        "test": "tests/extensions/render-curtain.test.ts"
    },
    {
        "name": "M479 停播不取消幕布（半路停播之后卡在落幕，下一局第一拍执行旧跳转）",
        "file": "src/editor-entry.ts",
        "pairs": [
            [
                "  curtain = cancelCurtain(curtain);\n  renderMod?.setCurtain(0);",
                "  renderMod?.setCurtain(0);"
            ]
        ],
        "cmd": [
            "node",
            "tools/editor-selftest.mjs",
            "--build"
        ],
        "env_exit": 2
    },
    {
        "name": "M480 检查点拍在回滚之后（存下来的是工程那一份，读档回到起点）",
        "file": "src/editor-entry.ts",
        "pairs": [
            [
                "  const checkpoint = autoCheckpoint();\n  const r = endPlaySession(docDeps(app), s);",
                "  const r = endPlaySession(docDeps(app), s);\n  const checkpoint = autoCheckpoint();"
            ]
        ],
        "cmd": [
            "node",
            "tools/editor-selftest.mjs",
            "--build"
        ],
        "env_exit": 2
    },
    {
        "name": "M481 检查点不看走过没有（没走动也写，把上一次的进度换成开局）",
        "file": "src/editor-entry.ts",
        "pairs": [
            [
                "  if (f === null || f.visitedCount <= 1) return \"\";",
                "  if (f === null) return \"\";"
            ]
        ],
        "cmd": [
            "node",
            "tools/editor-selftest.mjs",
            "--build"
        ],
        "env_exit": 2
    },
    {
        "name": "M482 自动检查点优先于手动存档（我特意存的点被一次停播挤掉）",
        "file": "src/editor-entry.ts",
        "pairs": [
            [
                "    manual !== null && manual.length > 0\n      ? { text: manual, from: \"手动存档\" }\n      : auto !== null && auto.length > 0\n        ? { text: auto, from: \"自动检查点\" }\n        : null;",
                "    auto !== null && auto.length > 0\n      ? { text: auto, from: \"自动检查点\" }\n      : manual !== null && manual.length > 0\n        ? { text: manual, from: \"手动存档\" }\n        : null;"
            ]
        ],
        "cmd": [
            "node",
            "tools/editor-selftest.mjs",
            "--build"
        ],
        "env_exit": 2
    },
    {
        "name": "M483 不在试玩中读档不自动开播（试玩之外的入口等于没有）",
        "file": "src/editor-entry.ts",
        "pairs": [
            [
                "  const started = playSession === null;\n  if (started) {",
                "  const started = playSession === null;\n  if (false) {"
            ]
        ],
        "cmd": [
            "node",
            "tools/editor-selftest.mjs",
            "--build"
        ],
        "env_exit": 2
    },
    {
        "name": "M484 起幕拍数下限去掉（inTicks=0 时 alpha 是 NaN，整屏变黑）",
        "file": "src/extensions/flow/curtain.ts",
        "pairs": [
            [
                "  return Math.max(1, Math.floor(spec.inTicks));",
                "  return Math.floor(spec.inTicks);"
            ]
        ],
        "test": "tests/extensions/flow-curtain.test.ts"
    },
    {
        "name": "M485 文本不进缓存键（改了文案还显示旧字）",
        "file": "src/extensions/ui/state.ts",
        "pairs": [
            [
                "  return [\n    fontId,\n    text,",
                "  return [\n    fontId,\n    \"\","
            ]
        ],
        "test": "tests/extensions/ui-state.test.ts"
    },
    {
        "name": "M486 颜色不进缓存键（换色不重排，沿用旧颜色）",
        "file": "src/extensions/ui/state.ts",
        "pairs": [
            [
                "    c === undefined ? \"-\" : `${c.r},${c.g},${c.b},${c.a}`,",
                "    \"-\","
            ]
        ],
        "test": "tests/extensions/ui-state.test.ts"
    },
    {
        "name": "M487 只丢派生的入口把滚动位置一起清了（换字体列表回顶）",
        "file": "src/extensions/ui/state.ts",
        "pairs": [
            [
                "  invalidateDerived(): void {\n    this.layouts.clear();",
                "  invalidateDerived(): void {\n    this.layouts.clear();\n    this.scrolls.clear();"
            ]
        ],
        "test": "tests/extensions/ui-state.test.ts"
    },
    {
        "name": "M488 全丢的入口漏掉滚动（回滚后读到上一份世界的位置）",
        "file": "src/extensions/ui/state.ts",
        "pairs": [
            [
                "  reset(): void {\n    this.layouts.clear();\n    this.scrolls.clear();",
                "  reset(): void {\n    this.layouts.clear();"
            ]
        ],
        "test": "tests/extensions/ui-state.test.ts"
    },
    {
        "name": "M489 滚动写入把非有限数夹成 0（伪装成「用户滑回顶部」）",
        "file": "src/extensions/ui/state.ts",
        "pairs": [
            [
                "    if (!Number.isFinite(value)) return;",
                "    if (!Number.isFinite(value)) value = 0;"
            ]
        ],
        "test": "tests/extensions/ui-state.test.ts"
    },
    {
        "name": "M490 forget 一家伙清全表（别的节点的缓存跟着废）",
        "file": "src/extensions/ui/state.ts",
        "pairs": [
            [
                "    if (this.layouts.delete(uid)) this.evictions++;",
                "    this.layouts.clear();\n    this.evictions++;"
            ]
        ],
        "test": "tests/extensions/ui-state.test.ts"
    },
    {
        "name": "M491 上限判断差一条（第 1025 条时不清理，表无界增长）",
        "file": "src/extensions/ui/state.ts",
        "pairs": [
            [
                "    if (this.layouts.size >= MAX_LAYOUT_ENTRIES) {",
                "    if (this.layouts.size > MAX_LAYOUT_ENTRIES) {"
            ]
        ],
        "test": "tests/extensions/ui-state.test.ts"
    },
    {
        "name": "M492 字体缺失时返回空排版而不是 null（标签静默塌成 0 宽）",
        "file": "src/extensions/ui/state.ts",
        "pairs": [
            [
                "    if (font === undefined) return null;",
                "    if (font === undefined) return { quads: [], width: 0, height: 0, lineCount: 0, truncated: false, missing: [] };"
            ]
        ],
        "test": "tests/extensions/ui-state.test.ts"
    },
    {
        "name": "M493 只丢派生时不推进代次（持有旧代次的东西查不出过期）",
        "file": "src/extensions/ui/state.ts",
        "pairs": [
            [
                "    this.layouts.clear();\n    this.version++;\n  }",
                "    this.layouts.clear();\n  }"
            ]
        ],
        "test": "tests/extensions/ui-state.test.ts"
    },
    {
        "name": "M494 没给宽度也按父容器宽换行（收缩到内容变成撑满整行）",
        "file": "src/extensions/ui/intrinsic.ts",
        "pairs": [
            [
                "    const wrap = explicit ? Math.max(0, boxW - inset * 2) : 0;",
                "    const wrap = Math.max(0, boxW - inset * 2);"
            ]
        ],
        "test": "tests/extensions/ui-intrinsic.test.ts"
    },
    {
        "name": "M495 自撑开宽度不含内缩（按钮文字贴边）",
        "file": "src/extensions/ui/intrinsic.ts",
        "pairs": [
            [
                "      w: layout.width + inset * 2 + pad.left + pad.right,",
                "      w: layout.width + pad.left + pad.right,"
            ]
        ],
        "test": "tests/extensions/ui-intrinsic.test.ts"
    },
    {
        "name": "M496 文字盒子只内缩一边（绘制与量算各偏 4 像素）",
        "file": "src/extensions/ui/intrinsic.ts",
        "pairs": [
            [
                "  const w = Math.max(0, rect.width - inset * 2);",
                "  const w = Math.max(0, rect.width - inset);"
            ]
        ],
        "test": "tests/extensions/ui-intrinsic.test.ts"
    },
    {
        "name": "M497 空文本也表态（把配置里的 contentSize 改写成 0）",
        "file": "src/extensions/ui/intrinsic.ts",
        "pairs": [
            [
                "    const text = node.props.text ?? \"\";\n    if (rich === undefined && text === \"\") return null;",
                "    const text = node.props.text ?? \"\";"
            ]
        ],
        "test": "tests/extensions/ui-intrinsic.test.ts"
    },
    {
        "name": "M498 默认字体取排序最后一个（注册顺序改变画面）",
        "file": "src/extensions/ui/intrinsic.ts",
        "pairs": [
            [
                "  return ids.length === 0 ? \"\" : (ids[0] as string);",
                "  return ids.length === 0 ? \"\" : (ids[ids.length - 1] as string);"
            ]
        ],
        "test": "tests/extensions/ui-intrinsic.test.ts"
    },
    {
        "name": "M499 量算结果不写回 contentSize（撑开只活在函数栈里）",
        "file": "src/extensions/ui/layout.ts",
        "pairs": [
            [
                "  const nat = opts.intrinsic?.(node, padW, padH) ?? null;\n  if (nat !== null) node.contentSize = { w: nat.w, h: nat.h };",
                "  const nat = opts.intrinsic?.(node, padW, padH) ?? null;"
            ]
        ],
        "test": "tests/extensions/ui-intrinsic.test.ts"
    },
    {
        "name": "M500 easing 挂左端点（最后一帧的 easing 永远不生效）",
        "file": "src/extensions/tween/keyframes.ts",
        "pairs": [
            [
                "  const eased = easingOf(b.easing)(",
                "  const eased = easingOf(a.easing)("
            ]
        ],
        "test": "tests/extensions/tween-keyframes.test.ts"
    },
    {
        "name": "M501 走到末帧不报 done（宿主永远不知道播完了）",
        "file": "src/extensions/tween/keyframes.ts",
        "pairs": [
            [
                "    return { value: (keys[n - 1] as Keyframe).value, segment: n - 2, progress: 1, done: true };",
                "    return { value: (keys[n - 1] as Keyframe).value, segment: n - 2, progress: 1, done: false };"
            ]
        ],
        "test": "tests/extensions/tween-keyframes.test.ts"
    },
    {
        "name": "M502 第一个关键帧不必在 0ms（0..起播 之间没有定义）",
        "file": "src/extensions/tween/keyframes.ts",
        "pairs": [
            [
                "  if (first.atMs !== 0) {",
                "  if (false) {"
            ]
        ],
        "test": "tests/extensions/tween-keyframes.test.ts"
    },
    {
        "name": "M503 时间轴改为非严格递增（同一时刻两个值）",
        "file": "src/extensions/tween/keyframes.ts",
        "pairs": [
            [
                "    if (i > 0 && !(k.atMs > prev)) {",
                "    if (i > 0 && k.atMs < prev) {"
            ]
        ],
        "test": "tests/extensions/tween-keyframes.test.ts"
    },
    {
        "name": "M504 段号报错一位（调用方按段做逻辑时全部错位）",
        "file": "src/extensions/tween/keyframes.ts",
        "pairs": [
            [
                "  return { value: a.value + (b.value - a.value) * eased, segment: i, progress: t, done: false };",
                "  return { value: a.value + (b.value - a.value) * eased, segment: i + 1, progress: t, done: false };"
            ]
        ],
        "test": "tests/extensions/tween-keyframes.test.ts"
    },
    {
        "name": "M505 冻结失效（改入参数组能改已构造的 spec）",
        "file": "src/extensions/tween/keyframes.ts",
        "pairs": [
            [
                "  const frozen: Keyframe[] = keys.map((k) =>",
                "  const frozen: Keyframe[] = [...keys];\n  void keys.map((k) =>"
            ]
        ],
        "test": "tests/extensions/tween-keyframes.test.ts"
    },
    {
        "name": "M506 关键帧轨道播完继续累加时间（浮点精度把重播起点带漂）",
        "file": "src/extensions/tween/tween-player.ts",
        "pairs": [
            [
                "    if (player.playing && t.playing && !wasDone) {",
                "    if (player.playing && t.playing) {"
            ]
        ],
        "test": "tests/extensions/tween-keyframes.test.ts"
    },
    # ★ 批117 复核：这条原来的靶子是「关键帧轨道的 changed 恒为 true」——
    #   `Number.isNaN(t.lastValue) || s.value !== t.lastValue` 已被合并进
    #   `TweenPlayer.commitComposed`（两种轨道共用一条 changed 路径），
    #   同一语义现在由 M665 钉在新代码上（一行，两种轨道都会中）。
    #   编号必须连续（`tools/docs-check.mjs` 会查），所以**重新指认**而不是删：
    #   换成关键帧轨道那一路的算子携带 —— 它同样只影响关键帧轨道，
    #   而且批117 之前这条路径一条判据都没有（新判据见 tween-player.test.ts 的
    #   「关键帧轨道也能带算子」）。
    {
        "name": "M507 关键帧轨道那一路不带算子（配了 multiply 还是按覆盖算）",
        "file": "src/extensions/tween/tween-player.ts",
        "pairs": [
            [
                "    const s = t.sample();\n    entries.push({ id: t.id, targetId: t.targetId, prop: t.prop, op: t.composite, value: s.value, done: s.done });",
                "    const s = t.sample();\n    entries.push({ id: t.id, targetId: t.targetId, prop: t.prop, op: COMPOSITE_OP.Replace, value: s.value, done: s.done });"
            ]
        ],
        "test": "tests/extensions/tween-player.test.ts"
    },
    {
        "name": "M508 面命中不检查另一轴的范围（角区域的命中被当成面 ⇒ 提前停住）",
        "file": "src/extensions/physics/sweep.ts",
        "pairs": [
            [
                "    if (other < f.lo || other > f.hi) continue; // 角区域，交给下面",
                "    if (false) continue; // 角区域，交给下面"
            ]
        ],
        "test": "tests/extensions/physics-sweep.test.ts"
    },
    {
        "name": "M509 走过的路程记成本步**想走**的长度（贴墙时虚报位移 ⇒ 「≤ 原始长度」判据反而看不出来）",
        "file": "src/extensions/physics/sweep.ts",
        "pairs": [
            [
                "    traveled += len * back;",
                "    traveled += len;"
            ]
        ],
        "test": "tests/extensions/physics-sweep.test.ts"
    },
    {
        "name": "M510 角圆半径写死 0（等于关掉角圆 ⇒ 45° 打角早停 0.02）",
        "file": "src/extensions/physics/sweep.ts",
        "pairs": [
            [
                "    const hit = rayVsCircle(px - c.cx, pz - c.cz, dx, dz, r);",
                "    const hit = rayVsCircle(px - c.cx, pz - c.cz, dx, dz, 0);"
            ]
        ],
        "test": "tests/extensions/physics-sweep.test.ts"
    },
    {
        "name": "M511 起点已重叠不特判（法线退化成 0/0 = NaN）",
        "file": "src/extensions/physics/sweep.ts",
        "pairs": [
            [
                "  if (cp.inside) {",
                "  if (false) {"
            ]
        ],
        "test": "tests/extensions/physics-sweep.test.ts"
    },
    {
        "name": "M512 滑动时不清掉法向分量（沿墙走会比直线更快：凭空加能量）",
        "file": "src/extensions/physics/sweep.ts",
        "pairs": [
            [
                "    remX -= h.nx * dot;\n    remZ -= h.nz * dot;",
                "    // 法向分量留在 rem 里（错）"
            ]
        ],
        "test": "tests/extensions/physics-sweep.test.ts"
    },
    {
        "name": "M513 起点已重叠的边界写成 `< 0`（恰好相切/重叠的那一拍被当成「走进去了」，记一次滑动）",
        "file": "src/extensions/physics/sweep.ts",
        "pairs": [
            [
                "    if (h.t <= 0) break;",
                "    if (h.t < 0) break;"
            ]
        ],
        "test": "tests/extensions/physics-sweep.test.ts"
    },
    {
        "name": "M514 平手时取 nodeId 大的（结果依赖数组顺序）",
        "file": "src/extensions/physics/sweep.ts",
        "pairs": [
            [
                "h.t === best.t && h.nodeId < best.nodeId",
                "h.t === best.t && h.nodeId > best.nodeId"
            ]
        ],
        "test": "tests/extensions/physics-sweep.test.ts"
    },
    {
        "name": "M515 earliestHit 不比较 t（取最后一个候选，与距离无关）",
        "file": "src/extensions/physics/sweep.ts",
        "pairs": [
            [
                "    if (best === null || h.t < best.t || (h.t === best.t && h.nodeId < best.nodeId)) best = h;",
                "    best = h;"
            ]
        ],
        "test": "tests/extensions/physics-sweep.test.ts"
    },
    {
        "name": "M516 起点已在圆内时返回 null（重叠的圆互相穿过）",
        "file": "src/extensions/physics/sweep.ts",
        "pairs": [
            [
                "  if (c <= 0) return 0;",
                "  if (c <= 0) return null;"
            ]
        ],
        "test": "tests/extensions/physics-sweep.test.ts"
    },
    {
        "name": "M517 sweepMove 连动态体一起扫（两只怪互相卡住）",
        "file": "src/extensions/physics/physics.ts",
        "pairs": [
            [
                "      if (other === undefined || !other.isStatic) continue;",
                "      if (other === undefined) continue;"
            ]
        ],
        "test": "tests/extensions/physics-sweep.test.ts"
    },
    {
        "name": "M518 sweepMove 丢掉圆形候选（只扫方框障碍）",
        "file": "src/extensions/physics/physics.ts",
        "pairs": [
            [
                "    const fromCircles = circles.map((c) => sweepCircleVsCircle(p.x, p.z, dx, dz, self.radius, c.cx, c.cz, c.r, c.nodeId));",
                "    const fromCircles: (SweepHit | null)[] = [];"
            ]
        ],
        "test": "tests/extensions/physics-sweep.test.ts"
    },
    {
        "name": "M519 sweepMove 的候选半径漏掉位移长度（远处的墙根本不在候选集里）",
        "file": "src/extensions/physics/physics.ts",
        "pairs": [
            [
                "    const reach = Math.hypot(dx, dz) + self.radius + this.maxRange;",
                "    const reach = self.radius + this.maxRange;"
            ]
        ],
        "test": "tests/extensions/physics-sweep.test.ts"
    },
    {
        "name": "M520 AI 移动不夹接触点（一步跨过薄墙：起终点都不重叠，resolve() 永远救不回来）",
        "file": "src/extensions/ai/move.ts",
        "pairs": [
            [
                "        const aim = clampToContact(node.id, wp.x, wp.y, r.x, r.z);",
                "        const aim: { x: number; z: number; hit: MoveSweepHit | null } = { x: r.x, z: r.z, hit: null };"
            ]
        ],
        "test": "tests/extensions/ai-move.test.ts"
    },
    {
        "name": "M521 被物理挡住时照常推进游标（贴着墙把剩下的路空走完，然后宣布到达）",
        "file": "src/extensions/ai/move.ts",
        "pairs": [
            [
                "          m.cursor = cursorBefore;",
                "          m.cursor = r.cursor;"
            ]
        ],
        "test": "tests/extensions/ai-move.test.ts"
    },
    {
        "name": "M522 被物理挡住也宣布到达（`r.done` 只是预算走完了这条路，不是人走到了）",
        "file": "src/extensions/ai/move.ts",
        "pairs": [
            [
                "        if (aim.hit === null && r.done) {",
                "        if (r.done) {"
            ]
        ],
        "test": "tests/extensions/ai-move.test.ts"
    },
    {
        "name": "M523 BDF 位序反了（高位在右 ⇒ 所有字形水平镜像，而「有墨」类判据照样绿）",
        "file": "tools/bdf.mjs",
        "pairs": [
            [
                "    bits.push((byte >> (7 - (x & 7))) & 1);",
                "    bits.push((byte >> (x & 7)) & 1);"
            ]
        ],
        "test": "tests/extensions/ui-cjk-font.test.ts"
    },
    {
        "name": "M524 BITMAP 行数比 BBX 少不报错（那个字缺一整行，宽度照旧）",
        "file": "tools/bdf.mjs",
        "pairs": [
            [
                "    if (bitmap.length !== bbx.h) {",
                "    if (bitmap.length > bbx.h) {"
            ]
        ],
        "test": "tests/extensions/ui-cjk-font.test.ts"
    },
    {
        "name": "M525 十六进制行多一位不报错（parseInt 照样算出一个数 ⇒ 整行错位）",
        "file": "tools/bdf.mjs",
        "pairs": [
            [
                "  if (hex.length !== bytes * 2) {",
                "  if (hex.length < bytes * 2) {"
            ]
        ],
        "test": "tests/extensions/ui-cjk-font.test.ts"
    },
    {
        "name": "M526 全空字形不当成宽 0（空格会有 8×16 的空白矩形，图集里多两块透明补丁）",
        "file": "tools/bdf.mjs",
        "pairs": [
            [
                "        w: any ? bbx.w : 0,",
                "        w: bbx.w,"
            ]
        ],
        "test": "tests/extensions/ui-cjk-font.test.ts"
    },
    {
        "name": "M527 前进量用整字库宽（16）代替每个字形的 DWIDTH ⇒ 半角字符变成全角",
        "file": "tools/make-ui-assets.mjs",
        "pairs": [
            [
                "      advance: g.advance,",
                "      advance: bdf.bboxW,"
            ]
        ],
        "test": "tests/extensions/ui-cjk-font.test.ts"
    },
    {
        "name": "M528 inkTop 少减 1（每个字形整体下移一像素，基线不再是 1）",
        "file": "tools/make-ui-assets.mjs",
        "pairs": [
            [
                "      inkTop: g.yoff + g.h - 1,",
                "      inkTop: g.yoff + g.h,"
            ]
        ],
        "test": "tests/extensions/ui-cjk-font.test.ts"
    },
    {
        "name": "M529 中文字体用 5×7 的货架间距（每行 9px ⇒ 16 高的字互相压）",
        "file": "tools/make-ui-assets.mjs",
        "pairs": [
            [
                "  const packed = pack(glyphs, CJK_ATLAS_W, bdf.bboxH + 1);",
                "  const packed = pack(glyphs, CJK_ATLAS_W, CELL_H + 1);"
            ]
        ],
        "test": "tests/extensions/ui-cjk-font.test.ts"
    },
    {
        "name": "M530 行高不加那 2px（下伸的下沿正好撞到下一行）",
        "file": "tools/make-ui-assets.mjs",
        "pairs": [
            [
                "    lineHeight: bdf.ascent + bdf.descent + 2,",
                "    lineHeight: bdf.ascent + bdf.descent,"
            ]
        ],
        "test": "tests/extensions/ui-cjk-font.test.ts"
    },
    {
        "name": "M531 @ascii 区间少取最后一格（U+007E 悄悄不在字符集里）",
        "file": "tools/make-ui-assets.mjs",
        "pairs": [
            [
                "      for (let c = lo; c <= hi; c++) codes.add(c);",
                "      for (let c = lo; c < hi; c++) codes.add(c);"
            ]
        ],
        "test": "tests/extensions/ui-cjk-font.test.ts"
    },
    {
        "name": "M532 pageBase 不生效（第二张字体会去采样第一张图 ⇒ 画面上是乱纹）",
        "file": "src/extensions/ui/font.ts",
        "pairs": [
            [
                "      page: c.pg + pageBase,",
                "      page: c.pg,"
            ]
        ],
        "test": "tests/extensions/ui-font.test.ts"
    },
    {
        "name": "M533 背包行高不跟中文字体（18 高的字塞进 14 高的行，上下各溢出 2px）",
        "file": "src/host/hud-ui.ts",
        "pairs": [
            [
                "  const cjkRowH = cjk === undefined ? rowH : Math.max(1, cjk.lineHeight) + 4;",
                "  const cjkRowH = rowH;"
            ]
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M534 忽略注入的 labelOf（中文标签传进来了却仍显示 kind）",
        "file": "src/host/hud-model.ts",
        "pairs": [
            [
                '  const label = labelOf ?? ((kind: string) => kind.replace(/_/g, " "));',
                '  const label = (kind: string): string => kind.replace(/_/g, " ");'
            ]
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M535 isUiPage 恒为 false（中文字形图进世界图集 ⇒ 1024×2092 一张撑爆上限，整个编辑器退回假贴图）",
        "file": "src/extensions/editor/asset-bake.ts",
        "pairs": [
            [
                '  return name.startsWith("ui-");',
                "  return false;"
            ]
        ],
        "test": "tests/extensions/editor-asset-bake.test.ts"
    },
    {
        # 批102：阻塞清单对账的四条规则，一条一组。这些规则今天**永远输出空数组**，
        # 所以"没在扫"与"扫了没问题"在输出上一样 —— 每组都必须有一条合成坏行去咬它。
        "name": "M536 死引用不报（改名/删文件之后，清单里那行照样绿）",
        "file": "tools/blockers-check.mjs",
        "pairs": [
            [
                "    const dead = paths.filter((p) => !exists(p));",
                "    const dead = [];"
            ]
        ],
        "test": "tests/tools/blockers-check.test.ts"
    },
    {
        "name": "M537 ✅ 的证据检查恒通过（「我记得做完了」也放行）",
        "file": "tools/blockers-check.mjs",
        "pairs": [
            [
                "    const hit = quotes.some((q) => live.some((p) => readText(p).includes(q)));",
                "    const hit = true;"
            ]
        ],
        "test": "tests/tools/blockers-check.test.ts"
    },
    {
        "name": "M538 状态词表只剩 ✅（⛔ 外部阻塞 / 🔜 排队 / ❌ 决定不做一律被判成坏行）",
        "file": "tools/blockers-check.mjs",
        "pairs": [
            [
                'export const BLOCKER_MARKERS = ["✅", "⛔", "🔜", "❌"];',
                'export const BLOCKER_MARKERS = ["✅"];'
            ]
        ],
        "test": "tests/tools/blockers-check.test.ts"
    },
    {
        "name": "M539 跨行单元格不报（「状态」那一格读不出来，却当它是单行）",
        "file": "tools/blockers-check.mjs",
        "pairs": [
            [
                'singleLine: t.endsWith("|")',
                "singleLine: true"
            ]
        ],
        "test": "tests/tools/blockers-check.test.ts"
    },
    {
        # 批103：剧情门槛（BLOCKERS C2）。六条打在六件不同的事上：
        # 判不判、判定顺序、自锁配置、空白校验、规格带没带出来、「去过」的语义。
        "name": "M540 剧情门槛不判（要先去过的场景形同虚设，门直接放行）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [
            [
                '    if (via !== null && via.requiresScene !== "") {',
                "    if (false) {"
            ]
        ],
        "test": "tests/extensions/flow-story.test.ts"
    },
    {
        "name": "M541 顺序反了：有钥匙要求时就不判剧情（两样都缺时先喊「缺 3 个 key」）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [
            [
                '    if (via !== null && via.requiresScene !== "") {',
                '    if (via !== null && via.requiresScene !== "" && via.requires === "") {'
            ]
        ],
        "test": "tests/extensions/flow-story.test.ts"
    },
    {
        "name": "M542 拿门名当场景名去查「去过」（查的是一张没人往里写的表）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [
            [
                "      if (!this.visited.has(via.requiresScene)) {",
                "      if (!this.visited.has(via.name)) {"
            ]
        ],
        "test": "tests/extensions/flow-story.test.ts"
    },
    {
        "name": "M543 不判「门槛就是自己这一场」（死锁配置表现为「这扇门没反应」）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [
            [
                "      if (via.requiresScene === this.current) {",
                "      if (false) {"
            ]
        ],
        "test": "tests/extensions/flow-story.test.ts"
    },
    {
        "name": "M544 空白门槛不校验（永远匹配不上任何场景 ⇒ 这扇门永远锁着，作者看不出）",
        "file": "src/extensions/flow/portal.ts",
        "pairs": [
            [
                '    if (p.requiresScene !== "" && p.requiresScene.trim() === "") {',
                "    if (false) {"
            ]
        ],
        "test": "tests/extensions/flow-story.test.ts"
    },
    {
        "name": "M545 门槛字段没带进规格（collectPortals 里丢掉 ⇒ 门槛形同虚设）",
        "file": "src/extensions/flow/portal.ts",
        "pairs": [
            [
                "      requiresScene: p.requiresScene,",
                '      requiresScene: "",'
            ]
        ],
        "test": "tests/extensions/flow-story.test.ts"
    },
    {
        "name": "M546 hasVisited 把当前场景也算进去（「站在 a 上」被当成「去过 a」）",
        "file": "src/extensions/flow/scene-flow.ts",
        "pairs": [
            [
                "    return this.visited.has(name);",
                "    return this.visited.has(name) || name === this.current;"
            ]
        ],
        "test": "tests/extensions/flow-story.test.ts"
    },
    {
        # 批104：热重载的三条不变量。删掉下面任一分支，**正常运行一条测试都不会红**
        # （成功路径一模一样），只有"改坏了中间态"的用例才会现形。
        "name": "M547 热更复用旧 env（`_G` 当模块表 ⇒ 上一版的全局串到新版）",
        "file": "src/backends/script-lua/runtime.ts",
        "pairs": [
            [
                # 批133 起这一行在 else 分支里（4 空格缩进）；共享模式分支自己用 env = _G。
                "    env = {}",
                "    env = _G"
            ]
        ],
        "test": "tests/backends/script-hot-reload.test.ts"
    },
    {
        "name": "M548 编译失败也当成成功（旧模块被换成一个空壳，改坏一句就全挂）",
        "file": "src/backends/script-lua/runtime.ts",
        "pairs": [
            [
                "    return { s = 0, m = tostring(compile_err) }",
                "    return { s = 1, m = tostring(compile_err) }"
            ]
        ],
        "test": "tests/backends/script-hot-reload.test.ts"
    },
    {
        "name": "M549 执行期出错也当成成功（编译通过 ≠ 能跑，半成品被登记）",
        "file": "src/backends/script-lua/runtime.ts",
        "pairs": [
            [
                "    return { s = 2, m = tostring(result) }",
                "    return { s = 1, m = tostring(result) }"
            ]
        ],
        "test": "tests/backends/script-hot-reload.test.ts"
    },
    {
        "name": "M550 滚动上限用可视长度算（`measured` 而不是 `contentExtent` ⇒ 永远滚不动）",
        "file": "src/extensions/ui/layout.ts",
        "pairs": [
            [
                "    const extent = horizontal ? node.contentExtent.w : node.contentExtent.h;",
                "    const extent = horizontal ? node.measured.w : node.measured.h;"
            ]
        ],
        "test": "tests/extensions/ui-scroll.test.ts"
    },
    {
        "name": "M551 越界偏移只夹不写回（状态表里仍是越界值，下次改内容又跳）",
        "file": "src/extensions/ui/layout.ts",
        "pairs": [
            [
                "      if (clamped !== raw) src.set(node.uid, clamped);",
                "      void clamped;"
            ]
        ],
        "test": "tests/extensions/ui-scroll.test.ts"
    },
    {
        "name": "M552 不夹负偏移（往上滚能滚到负数，第一条内容被推到框下）",
        "file": "src/extensions/ui/layout.ts",
        "pairs": [
            [
                "      const clamped = !Number.isFinite(raw) ? 0 : raw < 0 ? 0 : raw > node.scrollMax ? node.scrollMax : raw;",
                "      const clamped = !Number.isFinite(raw) ? 0 : raw > node.scrollMax ? node.scrollMax : raw;"
            ]
        ],
        "test": "tests/extensions/ui-scroll.test.ts"
    },
    {
        "name": "M553 命中测试不看裁剪框（露在面板外的半个按钮能点中）",
        "file": "src/extensions/ui/layout.ts",
        "pairs": [
            [
                "  const c = n.clipRect;\n  return c === null || (x >= c.x && x <= c.xMax && y >= c.y && y <= c.yMax);",
                "  return true;"
            ]
        ],
        "test": "tests/extensions/ui-scroll.test.ts"
    },
    {
        "name": "M554 只裁矩形不改 UV（贴图被整张压进被裁的矩形里）",
        "file": "src/extensions/ui/widgets.ts",
        "pairs": [
            [
                "        const ky = (v1 - v0) / rect.height;",
                "        const ky = 0;"
            ]
        ],
        "test": "tests/extensions/ui-scroll.test.ts"
    },
    {
        "name": "M555 只丢整块、不裁半块（滚到一半的行露出整个 30 高，盖到面板外）",
        "file": "src/extensions/ui/widgets.ts",
        "pairs": [
            [
                "      if (x0 !== rect.x || x1 !== rect.xMax || y0 !== rect.y || y1 !== rect.yMax) {",
                "      if (false) {"
            ]
        ],
        "test": "tests/extensions/ui-scroll.test.ts"
    },
    {
        "name": "M556 滚轮投给 `hitTest` 的结果（纯展示的行上滚不动）",
        "file": "src/extensions/ui/events.ts",
        "pairs": [
            [
                "      const box = scrollTargetOf(topmostAt(this.root, p.x, p.y));",
                "      const box = scrollTargetOf(hit);"
            ]
        ],
        "test": "tests/extensions/ui-scroll.test.ts"
    },
    {
        "name": "M557 隐藏只挡住自己、子树照画（`walkVisible` 退化成 `walk`：关不掉的面板）",
        "file": "src/extensions/ui/layout.ts",
        "pairs": [
            [
                "  *walkVisible(): Generator<UiNode> {\n    if (!this.visible) return;",
                "  *walkVisible(): Generator<UiNode> {"
            ]
        ],
        "test": "tests/extensions/ui-scroll.test.ts"
    },
    {
        "name": "M558 子节点裁剪框不与父求交（内层漏到外层之外）",
        "file": "src/extensions/ui/layout.ts",
        "pairs": [
            [
                "    const cut = clipIn === null ? box : clipIn.intersect(box);",
                "    const cut = box;"
            ]
        ],
        "test": "tests/extensions/ui-scroll.test.ts"
    },
    {
        "name": "M559 滚了但不重排（状态表里的数字变了、画面一动不动）",
        "file": "src/extensions/ui/ui-module.ts",
        "pairs": [
            [
                "      if (scrolled) {\n        dirty = true;\n        sync();\n      }",
                "      if (scrolled) {\n        void 0;\n      }"
            ]
        ],
        "test": "tests/extensions/ui-module.test.ts"
    },
    {
        "name": "M560 free 容器的内容长度恒 0（给了 contentSize 也滚不动）",
        "file": "src/extensions/ui/layout.ts",
        "pairs": [
            [
                "  node.contentExtent =\n    node.kind === UiLayoutKind.Free\n      ? { w: clampSize(node.contentSize.w), h: clampSize(node.contentSize.h) }\n      : { w: clampSize(contentW), h: clampSize(contentH) };",
                "  node.contentExtent = { w: clampSize(contentW), h: clampSize(contentH) };"
            ]
        ],
        "test": "tests/extensions/ui-scroll.test.ts"
    },
    {
        "name": "M561 toast 收起时不隐藏面板（底部留一条空白胶囊）",
        "file": "src/host/hud-ui.ts",
        "pairs": [
            [
                "      toastPanel.visible = next !== \"\";",
                "      toastPanel.visible = true;"
            ]
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M562 toast 只显示面板、不写文案（弹出一次空胶囊）",
        "file": "src/host/hud-ui.ts",
        "pairs": [
            [
                "      toastLine.props = { ...toastLine.props, text: next };",
                "      void toastLine;"
            ]
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M563 toast 挡住下层（底部一整条点不动，玩家只会觉得「这里坏了」）",
        "file": "src/host/hud-ui.ts",
        "pairs": [
            [
                "    opaque: false,\n    interactive: false,\n    props: { frame: \"panel\", slice: sliceOf(\"panel\"), tint: new Color(1, 1, 1, 0.92) },",
                "    opaque: true,\n    interactive: false,\n    props: { frame: \"panel\", slice: sliceOf(\"panel\"), tint: new Color(1, 1, 1, 0.92) },"
            ]
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M564 toast 挂到最底层（背包开着时提示被面板盖住）",
        "file": "src/host/hud-ui.ts",
        "pairs": [
            [
                "  root.add(toastPanel);",
                "  root.children.unshift(toastPanel);"
            ]
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M565 toast 不限行（长提示换行，提示条被撑出屏幕）",
        "file": "src/host/hud-ui.ts",
        "pairs": [
            [
                "      style: { align: \"center\", color: white, maxLines: 1, ellipsis: \"…\" },",
                "      style: { align: \"center\", color: white, maxLines: 0, ellipsis: \"…\" },"
            ]
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M566 normRad 不归一化负角（-π/2 停在负区 ⇒ dir8 与存档比对全错）",
        "file": "src/extensions/motion/facing.ts",
        "pairs": [
            (
                "  const m = rad % TAU;\n  return m < 0 ? m + TAU : m + 0;",
                "  const m = rad % TAU;\n  return m;"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M567 零向量返回 0（站着不动的怪被掰向东 —— atan2(0,0) 不是 NaN）",
        "file": "src/extensions/motion/facing.ts",
        "pairs": [
            (
                "  if (dx === 0 && dz === 0) return null;",
                "  if (dx === 0 && dz === 0) return 0;"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M568 不做环绕（350° → 10° 走 340°，怪物原地绕一大圈）",
        "file": "src/extensions/motion/facing.ts",
        "pairs": [
            (
                "  const d = normRad(to) - normRad(from);\n  if (d > Math.PI) return d - TAU;\n  if (d <= -Math.PI) return d + TAU;\n  return d;",
                "  const d = normRad(to) - normRad(from);\n  return d;"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M569 转向不限速（turnRate 形同虚设 ⇒ 视野锥等于全向）",
        "file": "src/extensions/motion/facing.ts",
        "pairs": [
            (
                "      const lim = maxRad > 0 ? maxRad : 0;",
                "      const lim = Number.POSITIVE_INFINITY;"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M570 maxTurn 漏 DEG（度当弧度用，转得慢 57 倍）",
        "file": "src/extensions/motion/facing.ts",
        "pairs": [
            (
                "    return this.turnRate * DEG * Math.max(0, dt);",
                "    return this.turnRate * Math.max(0, dt);"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M571 感知只认显式参数、不读 motion.facing（每只怪都得手工传角度）",
        "file": "src/extensions/ai/perception.ts",
        "pairs": [
            (
                "    const face = facingRad === undefined ? self.get<Facing>(FACING_TYPE)?.angle : facingRad;",
                "    const face = facingRad;"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M572 感知里组件优先于参数（调用方说「我朝西」也不算数）",
        "file": "src/extensions/ai/perception.ts",
        "pairs": [
            (
                "    const face = facingRad === undefined ? self.get<Facing>(FACING_TYPE)?.angle : facingRad;",
                "    const face = self.get<Facing>(FACING_TYPE)?.angle ?? facingRad;"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M573 朝向挪到「有没有位移」的守卫之外，且按想去方向算（贴着墙也在转身）",
        "file": "src/extensions/ai/move.ts",
        "pairs": [
            (
                "          const facing = node.get<Facing>(FACING_TYPE);\n          if (facing !== undefined) facing.faceTo(stepX, stepZ, facing.maxTurn(dt));\n        }",
                "        }\n        {\n          const facing = node.get<Facing>(FACING_TYPE);\n          if (facing !== undefined) facing.faceTo(r.x - wp.x, r.z - wp.y, facing.maxTurn(dt));\n        }"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M574 缺方向帧不回落单帧（美术只画了一张图时实体整个消失）",
        "file": "src/extensions/render/dir-frames.ts",
        "pairs": [
            (
                "  if (has(prefix)) return prefix;",
                "  if (has(prefix)) return null;"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M575 生物不挂 motion.facing（朝向又回到「数据不存在」）",
        "file": "src/extensions/mobs/spawn-mob.ts",
        "pairs": [
            (
                "    [FACTION_TYPE, faction],\n    [FACING_TYPE, facing],\n",
                "    [FACTION_TYPE, faction],\n"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M576 dir-sprite 一律按 dir8 取帧（4 向组件会拿到对角帧）",
        "file": "src/extensions/render/dir-sprite.ts",
        "pairs": [
            (
                "    const dir = ds.dirs === 4 ? face.dir4 : face.dir8;",
                "    const dir = face.dir8;"
            )
        ],
        "test": "tests/extensions/dir-sprite.test.ts"
    },
    {
        "name": "M577 每 tick 无条件写帧（同向也写 ⇒ 每帧给渲染标脏）",
        "file": "src/extensions/render/dir-sprite.ts",
        "pairs": [
            (
                "    if (sp.frame !== target) {",
                "    if (true) {"
            )
        ],
        "test": "tests/extensions/dir-sprite.test.ts"
    },
    {
        "name": "M578 永远取第 0 项（方向变了、帧永远是东向那张）",
        "file": "src/extensions/render/dir-sprite.ts",
        "pairs": [
            (
                "    const target = list[dir] ?? null;",
                "    const target = list[0] ?? null;"
            )
        ],
        "test": "tests/extensions/dir-sprite.test.ts"
    },
    {
        "name": "M579 资产全缺时不记 missing（把「图没烘进来」报成「方向都同步好了」）",
        "file": "src/extensions/render/dir-sprite.ts",
        "pairs": [
            (
                "      stats.missing++;\n      return;",
                "      return;"
            )
        ],
        "test": "tests/extensions/dir-sprite.test.ts"
    },
    {
        "name": "M580 帧名缓存键漏掉 dirs（8 向换成 4 向后继续读 8 向的表）",
        "file": "src/extensions/render/dir-sprite.ts",
        "pairs": [
            (
                "    const key = `${this.prefix}/${this.dirs}`;",
                "    const key = this.prefix;"
            )
        ],
        "test": "tests/extensions/dir-sprite.test.ts"
    },
    {
        "name": "M581 空前缀也参与同步（没有帧名的实体被当作「图集里什么都没有」）",
        "file": "src/extensions/render/dir-sprite.ts",
        "pairs": [
            (
                "    if (ds === undefined || ds.prefix === \"\") return;",
                "    if (ds === undefined) return;"
            )
        ],
        "test": "tests/extensions/dir-sprite.test.ts"
    },
    {
        "name": "M582 装配时把方向帧前缀写成别的模板（抄错字段 ⇒ 永远一个姿势）",
        "file": "src/extensions/mobs/spawn-mob.ts",
        "pairs": [
            (
                "  dirSprite.prefix = tpl.frame;",
                "  dirSprite.prefix = \"hound\";"
            )
        ],
        "test": "tests/extensions/dir-sprite.test.ts"
    },
    {
        "name": "M583 生物不挂 render.dirSprite（朝向与图集之间又断了）",
        "file": "src/extensions/mobs/spawn-mob.ts",
        "pairs": [
            (
                "    [FACING_TYPE, facing],\n    [DIR_SPRITE_TYPE, dirSprite],\n",
                "    [FACING_TYPE, facing],\n"
            )
        ],
        "test": "tests/extensions/dir-sprite.test.ts"
    },
    {
        "name": "M584 兔子朝后也画眼睛（「背对」与「面向」在图上不再可分）",
        "file": "tools/make-demo-assets.mjs",
        "pairs": [
            (
                "  const away = dz < -0.4;\n  const hx = Math.round(cx + dx * 2);\n  const hy = Math.round(13 - dz);\n  const lean = Math.round(dx * 3);\n  const earTop = away ? 5 : 2;",
                "  const away = false;\n  const hx = Math.round(cx + dx * 2);\n  const hy = Math.round(13 - dz);\n  const lean = Math.round(dx * 3);\n  const earTop = away ? 5 : 2;"
            )
        ],
        "test": "tests/extensions/dir-sprite.test.ts"
    },
    {
        "name": "M585 DIRS8 里 e 的 dx 写反（东向那张图其实是朝西的）",
        "file": "tools/make-demo-assets.mjs",
        "pairs": [
            (
                "  [\"e\", 1, 0],",
                "  [\"e\", -1, 0],"
            )
        ],
        "test": "tests/extensions/dir-sprite.test.ts"
    },
    {
        "name": "M586 眼睛不随 dx 横移（八向的眼睛全落在正中，方向判据失效）",
        "file": "tools/make-demo-assets.mjs",
        "pairs": [
            (
                "    const eyeDx = Math.round(dx * 3);",
                "    const eyeDx = 0;"
            )
        ],
        "test": "tests/extensions/dir-sprite.test.ts"
    },
    {
        "name": "M587 换位只换种类不换数量（两格的数字都留在原地）",
        "file": "src/extensions/inventory/inventory.ts",
        "pairs": [
            (
                "  y.kind = kind;\n  y.count = count;",
                "  y.kind = kind;\n  y.count = y.count;"
            )
        ],
        "test": "tests/extensions/inventory.test.ts"
    },
    {
        "name": "M588 两格取成同一格（y 也从 a 取 ⇒ 换位变成什么都没发生）",
        "file": "src/extensions/inventory/inventory.ts",
        "pairs": [
            (
                "  const x = stacks[a]!;\n  const y = stacks[b]!;",
                "  const x = stacks[a]!;\n  const y = stacks[a]!;"
            )
        ],
        "test": "tests/extensions/inventory.test.ts"
    },
    {
        "name": "M589 不校验整数下标（1.5 静默取整，换到隔壁格）",
        "file": "src/extensions/inventory/inventory.ts",
        "pairs": [
            (
                "  const bad = (i: number): boolean => !Number.isInteger(i) || i < 0 || i >= n;",
                "  const bad = (i: number): boolean => i < 0 || i >= n;"
            )
        ],
        "test": "tests/extensions/inventory.test.ts"
    },
    {
        "name": "M590 越界报错里带错格数（detail.count 说成 a）",
        "file": "src/extensions/inventory/inventory.ts",
        "pairs": [
            (
                "        count: n,",
                "        count: a,"
            )
        ],
        "test": "tests/extensions/inventory.test.ts"
    },
    {
        "name": "M591 拖拽标记 to 优先于 from（还没动就显示「放这里」）",
        "file": "src/host/hud-model.ts",
        "pairs": [
            (
                "    const mark: BagDragMark = from !== null && i === from ? \"from\" : to !== null && i === to ? \"to\" : null;",
                "    const mark: BagDragMark = to !== null && i === to ? \"to\" : from !== null && i === from ? \"from\" : null;"
            )
        ],
        "test": "tests/host/hud-model.test.ts"
    },
    {
        "name": "M592 落点不标记（占位反馈消失，只剩起点在动）",
        "file": "src/host/hud-model.ts",
        "pairs": [
            (
                "    const mark: BagDragMark = from !== null && i === from ? \"from\" : to !== null && i === to ? \"to\" : null;",
                "    const mark: BagDragMark = from !== null && i === from ? \"from\" : null;"
            )
        ],
        "test": "tests/host/hud-model.test.ts"
    },
    {
        "name": "M593 松手只清起点不清落点（拖完标记留在屏幕上）",
        "file": "src/host/hud-ui.ts",
        "pairs": [
            (
                "      const from = dragFrom;\n      const to = dragTo;\n      dragFrom = null;\n      dragTo = null;",
                "      const from = dragFrom;\n      const to = dragTo;\n      dragFrom = null;"
            )
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M594 落回同一格也算换位（按一下不动就发一次 swap）",
        "file": "src/host/hud-ui.ts",
        "pairs": [
            (
                "      if (to !== null && to !== from) opts.onSwapRows?.(from, to);",
                "      if (to !== null) opts.onSwapRows?.(from, to);"
            )
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M595 关面板不清拖拽状态（重开时有一行「正被拖着」）",
        "file": "src/host/hud-ui.ts",
        "pairs": [
            (
                "      if (!open) {\n        dragFrom = null;\n        dragTo = null;\n      }",
                "      if (false) {\n        dragFrom = null;\n        dragTo = null;\n      }"
            )
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M596 组合中顺手写 value（取消时无从回滚 —— 玩家会看到一串没打算留下的拼音）",
        "file": "src/extensions/ui/text-input.ts",
        "pairs": [
            (
                "    this.composing = text;",
                "    this.value = text;\n    this.composing = text;"
            )
        ],
        "test": "tests/extensions/text-input.test.ts"
    },
    {
        "name": "M597 compositionend 空串当提交（Esc 取消会把选中的内容删掉）",
        "file": "src/extensions/ui/text-input.ts",
        "pairs": [
            (
                "    if (pending === \"\") {",
                "    if (false) {"
            )
        ],
        "test": "tests/extensions/text-input.test.ts"
    },
    {
        "name": "M598 组合区间只记插入点不记选区（「选中三个字再打拼音」显示与结果不一致）",
        "file": "src/extensions/ui/text-input.ts",
        "pairs": [
            (
                "    this.composeEnd = s.end;",
                "    this.composeEnd = s.start;"
            )
        ],
        "test": "tests/extensions/text-input.test.ts"
    },
    {
        "name": "M599 取消时把光标放到区间起点（选区方向丢了：Shift+方向键会往反方向扩）",
        "file": "src/extensions/ui/text-input.ts",
        "pairs": [
            (
                "      this.caret = this.composeCaret;",
                "      this.caret = start;"
            )
        ],
        "test": "tests/extensions/text-input.test.ts"
    },
    {
        "name": "M600 切片按 UTF-16 码元（emoji 上退格留下半个代理对，屏幕显示 �）",
        "file": "src/extensions/ui/text-input.ts",
        "pairs": [
            (
                "  return Array.from(text).slice(start, end).join(\"\");",
                "  return text.slice(start, end);"
            )
        ],
        "test": "tests/extensions/text-input.test.ts"
    },
    {
        "name": "M601 退格不优先删选区（先删选区左边那一个，玩家选的三个字一个没少）",
        "file": "src/extensions/ui/text-input.ts",
        "pairs": [
            (
                "    if (s.start !== s.end) {",
                "    if (false) {"
            )
        ],
        "test": "tests/extensions/text-input.test.ts"
    },
    {
        "name": "M602 光标末尾取最后一格的**左边**（光标停在最后一个字之前，看起来差一格）",
        "file": "src/extensions/ui/text-input.ts",
        "pairs": [
            (
                "  if (index >= table.length - 1) return table[table.length - 1]!;",
                "  if (index >= table.length - 1) return table[table.length - 2] ?? 0;"
            )
        ],
        "test": "tests/extensions/text-input.test.ts"
    },
    {
        "name": "M603 输入行收起时底栏不回来（两行抢同一位置，收起后空一条）",
        "file": "src/host/hud-ui.ts",
        "pairs": [
            (
                "        bagFoot.visible = true;\n        inputCaretX = 0;",
                "        bagFoot.visible = false;\n        inputCaretX = 0;"
            )
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M604 光标位置拿「字符数」当像素（字宽 5px 时偏到看不懂的地方）",
        "file": "src/host/hud-ui.ts",
        "pairs": [
            (
                "      const lay = layoutText(font, s.text, { maxLines: 1 });\n      const row = lay.lineCaretX[0] ?? [0];",
                "      const row = [0, s.text.length];"
            )
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M605 选区高亮不归一化（反向拖选时宽度为负，画不出来）",
        "file": "src/host/hud-ui.ts",
        "pairs": [
            (
                "        inputSel.offset = { x: Math.min(x0, x1), y: 0 };",
                "        inputSel.offset = { x: x0, y: 0 };"
            )
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M606 不做避头尾（逗号照旧顶在行首）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [
            (
                "      while (cur.length - carry > 1) {",
                "      while (false) {"
            )
        ],
        "test": "tests/extensions/ui-text.test.ts"
    },
    {
        "name": "M607 只判行首、不判行尾（「（」孤零零挂在上一行末尾）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [
            (
                "        if (!LINE_END_FORBIDDEN.has(last) && !LINE_START_FORBIDDEN.has(nextFirst)) break;",
                "        if (!LINE_START_FORBIDDEN.has(nextFirst)) break;"
            )
        ],
        "test": "tests/extensions/ui-text.test.ts"
    },
    {
        "name": "M608 行尾禁则表漏掉全角「（」（行首禁则表里也不会有它）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [
            (
                "  0xff08, // （",
                "  0xff0b, // ＋"
            )
        ],
        "test": "tests/extensions/ui-text.test.ts"
    },
    {
        "name": "M609 断点挪过头（一次带两个字，行被吃掉一格）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [
            (
                "        carry++;",
                "        carry += 2;"
            )
        ],
        "test": "tests/extensions/ui-text.test.ts"
    },
    {
        "name": "M610 行首禁则改成「所有汉字都禁」（等价于把避头尾关掉，还会把整行推空）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [
            (
                "        if (!LINE_END_FORBIDDEN.has(last) && !LINE_START_FORBIDDEN.has(nextFirst)) break;",
                "        if (!LINE_END_FORBIDDEN.has(last) && !(nextFirst >= 0x4e00 && nextFirst <= 0x9fff) && !LINE_START_FORBIDDEN.has(nextFirst))\n          break;"
            )
        ],
        "test": "tests/extensions/ui-text.test.ts"
    },
    {
        "name": "M611 导入器按裁剪框中线镜像（角色转向时整体偏一格，静态看图看不出来）",
        "file": "tools/import-8dir-pack.mjs",
        "pairs": [
            (
                "    const axisX = srcBox === null ? (bw - 1) / 2 : (srcBox.x0 + srcBox.x1) / 2;",
                "    const axisX = (bw - 1) / 2;"
            )
        ],
        "test": "tests/extensions/eight-dir-pack.test.ts"
    },
    {
        "name": "M612 包围盒不看透明度（把整张画布当内容，裁剪框退化成源尺寸）",
        "file": "tools/import-8dir-pack.mjs",
        "pairs": [
            (
                "      if (img.pixels[(y * img.width + x) * 4 + 3] > 0) {",
                "      if (true) {"
            )
        ],
        "test": "tests/extensions/eight-dir-pack.test.ts"
    },
    {
        "name": "M613 西向的源方向写成 down_right（镜像出来的那一向变成斜向）",
        "file": "tools/import-8dir-pack.mjs",
        "pairs": [
            (
                "  w: { src: \"right\", mirror: true },",
                "  w: { src: \"down_right\", mirror: true },"
            )
        ],
        "test": "tests/extensions/eight-dir-pack.test.ts"
    },
    {
        "name": "M614 每 tick 归零 timeMs（动画永远停在第 0 帧，画面像「有在动」）",
        "file": "src/extensions/render/dir-sprite.ts",
        "pairs": [
            (
                "        if (anim.clipId !== clipId) {",
                "        if (true) {"
            )
        ],
        "test": "tests/extensions/eight-dir-pack.test.ts"
    },
    {
        "name": "M615 clip 模式下继续写 sprite.frame（和动画采样抢同一个字段）",
        "file": "src/extensions/render/dir-sprite.ts",
        "pairs": [
            (
                "        // ★ 这里**必须**返回：clip 模式下再写 `sprite.frame` 就是第二个写入者，\n        //   会和 anim-module 的采样抢同一个字段（见文件头 ★★）。\n        return;",
                "        // ★ 这里**必须**返回：clip 模式下再写 `sprite.frame` 就是第二个写入者。\n        //   会和 anim-module 的采样抢同一个字段（见文件头 ★★）。"
            )
        ],
        "test": "tests/extensions/eight-dir-pack.test.ts"
    },
    {
        "name": "M616 clipIds 配了一半也照用（5~8 向会全部错成东向）",
        "file": "src/extensions/render/dir-sprite.ts",
        "pairs": [
            (
                "    if (ds.clipIds.length >= ds.dirs) {",
                "    if (ds.clipIds.length > 0) {"
            )
        ],
        "test": "tests/extensions/eight-dir-pack.test.ts"
    },
    {
        "name": "M617 clip 缺失时不计数（配错的方向静默回落，没人知道）",
        "file": "src/extensions/render/dir-sprite.ts",
        "pairs": [
            (
                "      stats.clipMissing++;",
                "      // 静默回落"
            )
        ],
        "test": "tests/extensions/eight-dir-pack.test.ts"
    },
    {
        "name": "M618 出处清单写错许可（半年后没人说得清能不能商用）",
        "file": "web/assets/pack-provenance.json",
        "pairs": [
            (
                "  \"license\": \"CC0 1.0\",",
                "  \"license\": \"CC-BY 4.0\","
            )
        ],
        "test": "tests/extensions/eight-dir-pack.test.ts"
    },
    {
        "name": "M619 朝向用绝对坐标算（同一个位移在别的位置给出别的方向 —— 朝原点）",
        "file": "src/extensions/motion/facing.ts",
        "pairs": [
            (
                "  const a = angleOf(toX - fromX, toY - fromY);",
                "  const a = angleOf(toX, toY);"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M620 零位移也把朝向掰向东（站着不动的角色被悄悄转向）",
        "file": "src/extensions/motion/facing.ts",
        "pairs": [
            (
                "  if (a === null) return false;\n  face.setAngle(a);\n  return true;",
                "  if (a === null) {\n    face.setAngle(0);\n    return true;\n  }\n  face.setAngle(a);\n  return true;"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M621 角度符号改回数学习惯（往屏幕上走拿到背面变正面：角色倒着走）",
        "file": "src/extensions/motion/facing.ts",
        "pairs": [
            (
                "  return normRad(Math.atan2(-dz, dx));",
                "  return normRad(Math.atan2(dz, dx));"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M622 感知自己再算一遍角度（两处约定一错开：怪物朝下却看见上方的人）",
        "file": "src/extensions/ai/perception.ts",
        "pairs": [
            (
                "        const a = angleOf(dx, dz);",
                "        const a = Math.atan2(dz, dx);"
            )
        ],
        "test": "tests/extensions/ai-perception.test.ts"
    },
    {
        "name": "M623 扇区下标反着走（角度增大算成逆时针：8 向整体镜像）",
        "file": "src/extensions/motion/facing.ts",
        "pairs": [
            (
                "  return Math.round(normRad(rad) / (TAU / n)) % n;",
                "  return Math.round((TAU - normRad(rad)) / (TAU / n)) % n;"
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M624 8 向字母表南北互换（帧名与美术帧对不上：上半圈全画成正面）",
        "file": "src/extensions/render/dir-frames.ts",
        "pairs": [
            (
                'const LETTERS8 = ["e", "se", "s", "sw", "w", "nw", "n", "ne"] as const;',
                'const LETTERS8 = ["e", "ne", "n", "nw", "w", "sw", "s", "se"] as const;'
            )
        ],
        "test": "tests/extensions/facing.test.ts"
    },
    {
        "name": "M625 「仍缺」判据恒不报（闸门绿着但什么都没扫）",
        "file": "tools/gap-check.mjs",
        "pairs": [
            (
                "function liveClaim(text) {\n  let struck = false;",
                "function liveClaim(text) {\n  if (text !== \"\") return false;\n  let struck = false;"
            )
        ],
        "test": "tests/tools/gap-check.test.ts"
    },
    {
        "name": "M626 引用 ✅ 的「仍缺」不报（过期句子又变成绿的了 —— C12 的入口）",
        "file": "tools/gap-check.mjs",
        "pairs": [
            (
                "    const done = ids.filter((id) => status.get(id) === \"✅\");",
                "    const done = [];"
            )
        ],
        "test": "tests/tools/gap-check.test.ts"
    },
    {
        "name": "M627 跨字号也加 kerning（这一对度量在该字号下没有定义：小字那段被挤）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [
            (
                "  if (prev.scale !== cur.scale) return 0;",
                "  // mutated: 跨字号照样查 kerning"
            )
        ],
        "test": "tests/extensions/ui-text.test.ts"
    },
    {
        "name": "M628 行高与基线取整段最大字号（只有小字的行整体下坠：行距看着不匀）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [
            (
                "    const lineScale = maxScaleOf(cells, baseScale);",
                "    const lineScale = Math.max(...runs.map((r) => r.scale ?? baseScale));"
            )
        ],
        "test": "tests/extensions/ui-text.test.ts"
    },
    {
        "name": "M629 省略号取最后一段 run 的样式（被裁掉的正是那段：省略号换了颜色）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [
            (
                "    const ellColor = tail?.color ?? style.color;",
                "    const ellColor = runs[runs.length - 1]?.color ?? style.color;"
            )
        ],
        "test": "tests/extensions/ui-text.test.ts"
    },
    {
        "name": "M630 排版缓存键漏掉 runs（改了配色不刷新：屏幕上还是上一套颜色）",
        "file": "src/extensions/ui/state.ts",
        "pairs": [
            (
                '    const key = layoutCacheKey(fontId, rich === null ? text : "", style, rich);',
                '    const key = layoutCacheKey(fontId, rich === null ? text : "", style, null);'
            )
        ],
        "test": "tests/extensions/ui-state.test.ts"
    },
    {
        "name": "M631 有 runs 时仍按 text 排版（两个字段同时生效 = 两套真相）",
        "file": "src/extensions/ui/state.ts",
        "pairs": [
            (
                "    const layout = rich === null ? layoutText(font, text, style) : layoutRichText(font, rich, style);",
                "    const layout = layoutText(font, text, style);"
            )
        ],
        "test": "tests/extensions/ui-state.test.ts"
    },
    {
        "name": "M632 量算仍只看 text 判空（只给 runs 的标签塌成 0 宽：画得出字却占不到位置）",
        "file": "src/extensions/ui/intrinsic.ts",
        "pairs": [
            (
                '    if (rich === undefined && text === "") return null;',
                '    if (text === "") return null;'
            )
        ],
        "test": "tests/extensions/ui-intrinsic.test.ts"
    },
    {
        "name": "M633 面板只推 text 不推 runs（富文本半条链：模型分了段，屏幕上一个颜色）",
        "file": "src/host/hud-ui.ts",
        "pairs": [("        runs: r.runs,", "        runs: undefined,")],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M634 背包行不再分段（计数与物品名并成一段：计数与名字一样亮）",
        "file": "src/host/hud-model.ts",
        "pairs": [
            (
                "      { text: `${String(i + 1)}. ${label(s.kind)}` },\n      withColor(` x${String(s.count)}`, colors?.count),",
                "      { text: `${String(i + 1)}. ${label(s.kind)} x${String(s.count)}` },"
            )
        ],
        "test": "tests/host/hud-model.test.ts"
    },
    {
        "name": "M635 绘制层不把 runs 传给排版（接线断了：props 里有分段，画出来还是一个颜色）",
        "file": "src/extensions/ui/widgets.ts",
        "pairs": [
            (
                "    const layout = store.text(node.uid, fonts, p.fontId ?? defaultFontId(fonts), text, style, rich ?? undefined);",
                "    const layout = store.text(node.uid, fonts, p.fontId ?? defaultFontId(fonts), text, style);"
            )
        ],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M636 UI 的深度用屏幕 y（行底色画在行文字之后：字被自己的行盖住）",
        "file": "src/extensions/ui/widgets.ts",
        "pairs": [("      sortZ: 0,", "      sortZ: undefined,")],
        "test": "tests/extensions/ui-module.test.ts"
    },
    {
        "name": "M637 UI 相机不开 yDown（整棵界面上下镜像：顶部 HUD 画到屏幕底）",
        "file": "src/extensions/ui/viewport.ts",
        "pairs": [("    this.cam.yDown = true;", "    this.cam.yDown = false;")],
        "test": "tests/extensions/ui-viewport.test.ts"
    },
    {
        "name": "M638 yDown 下 pivot 仍朝上长（矩形从边往反方向长：一行压到上一行）",
        "file": "src/extensions/render/batch2d.ts",
        "pairs": [("      const pivotDir = cam.yDown ? -1 : 1;", "      const pivotDir = 1;")],
        "test": "tests/extensions/ui-module.test.ts"
    },
    {
        "name": "M639 排序不认 sortZ（UI 的顺序又退回按屏幕 y 排）",
        "file": "src/extensions/render/batch2d.ts",
        "pairs": [
            (
                "      const za = a.sortZ ?? a.z;\n      const zb = b.sortZ ?? b.z;",
                "      const za = a.z;\n      const zb = b.z;"
            )
        ],
        "test": "tests/core/render.test.ts"
    },
    {
        "name": "M640 HUD 的值段不上色（分段还在，颜色没了：三行又变成一种颜色）",
        "file": "src/host/hud-model.ts",
        "pairs": [
            (
                "    colors?.value === undefined ? { text } : { text, color: colors.value };",
                "    ({ text });"
            )
        ],
        "test": "tests/host/hud-model.test.ts"
    },
    {
        "name": "M641 面板收下 runs 却不推给节点（富文本半条链：模型分了段，屏幕一个色）",
        "file": "src/host/hud-ui.ts",
        "pairs": [("          runs: row.runs,", "          runs: undefined,")],
        "test": "tests/host/hud-ui.test.ts"
    },
    {
        "name": "M642 onFrameEnd 退订不生效（像素判据会重复触发：一次取帧读两次缓冲）",
        "file": "src/extensions/render/render-module.ts",
        "pairs": [
            (
                "        if (i >= 0) frameEndHooks.splice(i, 1);",
                "        void i;"
            )
        ],
        "test": "tests/extensions/render-curtain.test.ts"
    },
    # ---------------- 批116：UAX #9 双向算法 + RTL 排版 ----------------
    # ★ 这一批的判据主力是**官方 conformance 语料**（BidiTest / BidiCharacterTest
    #   子集，9 万余例），所以"少做一条规则"类的变异几乎必然被抓住；
    #   真正需要盯的是**排版层**的三处（镜像/顺序/光标），它们不在语料范围内。
    {
        "name": "M643 X9 移除类漏掉 PDF（结束嵌入的控制符占了一个视觉位）",
        "file": "src/extensions/ui/bidi.ts",
        "pairs": [
            (
                "    t === BC.LRE || t === BC.RLE || t === BC.LRO || t === BC.RLO || t === BC.PDF || t === BC.BN",
                "    t === BC.LRE || t === BC.RLE || t === BC.LRO || t === BC.RLO || t === BC.BN"
            )
        ],
        "test": "tests/extensions/ui-bidi.test.ts"
    },
    {
        "name": "M644 L2 只反转「级别正好等于当前级」的段（嵌套 run 漏反转）",
        "file": "src/extensions/ui/bidi.ts",
        "pairs": [
            (
                "      if (levels[members[k]!]! >= lvl) {",
                "      if (levels[members[k]!]! === lvl) {"
            ),
            (
                "        while (e < members.length && levels[members[e]!]! >= lvl) e++;",
                "        while (e < members.length && levels[members[e]!]! === lvl) e++;"
            )
        ],
        "test": "tests/extensions/ui-bidi.test.ts"
    },
    {
        "name": "M645 X2 溢出时无条件累计 embedding 计数（之后 PDF 弹错一层：末字符级别差 1）",
        "file": "src/extensions/ui/bidi.ts",
        "pairs": [
            (
                "} else if (overflowIso === 0) overflowEmbed++; // X2 步骤 3：isolate 溢出期间不累计",
                "} else overflowEmbed++;"
            )
        ],
        "test": "tests/extensions/ui-bidi.test.ts"
    },
    {
        "name": "M646 N0 不按 open 的逻辑序处理括号对（前文强类型读到的是「还没被改写的」）",
        "file": "src/extensions/ui/bidi.ts",
        "pairs": [("    pairs.sort((a, b) => a[0] - b[0]);", "    void 0;")],
        "test": "tests/extensions/ui-bidi.test.ts"
    },
    {
        "name": "M647 BD16 栈满只是跳过这个 open（TR9 要求停止本序列后续配对）",
        "file": "src/extensions/ui/bidi.ts",
        "pairs": [("        if (stack.length >= 63) break;", "        if (stack.length >= 63) continue;")],
        "test": "tests/extensions/ui-bidi.test.ts"
    },
    {
        "name": "M648 I1 偶级 EN/AN 只 +1（数字在 LTR 段里少一级，视觉位置错一格）",
        "file": "src/extensions/ui/bidi.ts",
        "pairs": [
            (
                "        else if (t === BC.AN || t === BC.EN) levels[i] = lv + 2;",
                "        else if (t === BC.AN || t === BC.EN) levels[i] = lv + 1;"
            )
        ],
        "test": "tests/extensions/ui-bidi.test.ts"
    },
    {
        "name": "M649 sos 的前文级读 I 阶段改写后的值（前一个字符已被别的 sequence 抬过级）",
        # ★ 第一版靶的是 `levels0[first]` → `levels[first]`，实测**等价变异**（不红）：
        #   每个下标只属于一个 sequence，`first` 不可能被前面的 sequence 改过，
        #   两个表达式恒等。真正会变的是**邻居**的级 —— 它可能已经在别的 sequence
        #   里被 I1/I2 抬过（TR9 X10 注："must use the embedding levels ... before
        #   any changes"）。
        "file": "src/extensions/ui/bidi.ts",
        "pairs": [
            (
                "      prevLv = levels0[i]!;",
                "      prevLv = levels[i]!;"
            )
        ],
        "test": "tests/extensions/ui-bidi.test.ts"
    },
    {
        "name": "M650 L1 的行尾重置链不含 isolate 格式字符（行尾 LRI 拿到嵌入级而不是段落级）",
        "file": "src/extensions/ui/bidi.ts",
        "pairs": [
            (
                "    t === BC.PDF ||\n    t === BC.LRI ||\n    t === BC.RLI ||\n    t === BC.FSI ||\n    t === BC.PDI\n  );",
                "    t === BC.PDF\n  );"
            )
        ],
        "test": "tests/extensions/ui-bidi.test.ts"
    },
    {
        "name": "M651 镜像不看奇偶级（LTR 段落里的括号也被镜像了）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [("      if (odd[i]) {", "      if (!odd[i]) {")],
        "test": "tests/extensions/ui-text.test.ts"
    },
    {
        "name": "M652 镜像不回退：字体没有镜像字形时直接换成镜像码点（变成缺字）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [
            (
                "        if (m !== undefined && font.glyphs.has(m)) cp = m;",
                "        if (m !== undefined) cp = m;"
            )
        ],
        "test": "tests/extensions/ui-text.test.ts"
    },
    {
        "name": "M653 开了 bidi 却不重排（四边形仍按逻辑序发：RTL 文本还是从左往右）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [
            (
                "    const map = reorderLine(local.types, local.levels, 0, n, bidi.paraLevel, local.rawTypes);",
                "    const map = Int32Array.from({ length: n }, (_, k) => k);"
            )
        ],
        "test": "tests/extensions/ui-text.test.ts"
    },
    {
        "name": "M654 光标一律贴左边缘（RTL 里光标不跟着字往左走）",
        "file": "src/extensions/ui/text-layout.ts",
        "pairs": [
            (
                "      caretX.push(pl.odd[i]! ? slotX[v]! + pl.adv[i]! : slotX[v]!);",
                "      caretX.push(slotX[v]!);"
            )
        ],
        "test": "tests/extensions/ui-text.test.ts"
    },
    {
        "name": "M655 排版缓存键漏掉 direction（改成 rtl 之后还是从左往右）",
        "file": "src/extensions/ui/state.ts",
        "pairs": [('    style.direction ?? "-",', '    "-",')],
        "test": "tests/extensions/ui-state.test.ts"
    },
    {
        "name": "M656 multiply 写成加法（各自减半的两条轨道叠成 0，而不是 0.25）",
        "file": "src/extensions/tween/composite.ts",
        "pairs": [("  if (op === COMPOSITE_OP.Multiply) return base * value;", "  if (op === COMPOSITE_OP.Multiply) return base + value;")],
        "test": "tests/extensions/tween-composite.test.ts"
    },
    {
        "name": "M657 合成不看算子，一律覆盖（add/multiply 静默退化成 replace）",
        "file": "src/extensions/tween/composite.ts",
        "pairs": [("      value: composeValue(e.op, prev.value, e.value),", "      value: e.value,")],
        "test": "tests/extensions/tween-composite.test.ts"
    },
    {
        "name": "M658 合成后的 id 保留第一条（值对了，但「这是谁给的」指向前一条）",
        "file": "src/extensions/tween/composite.ts",
        "pairs": [('      id: e.id,\n      targetId: e.targetId,', '      id: prev.id,\n      targetId: e.targetId,')],
        "test": "tests/extensions/tween-composite.test.ts"
    },
    {
        "name": "M659 done 取「任一完成」（上一条还在动就宣布这个属性播完了）",
        "file": "src/extensions/tween/composite.ts",
        "pairs": [("      done: prev.done && e.done,", "      done: prev.done || e.done,")],
        "test": "tests/extensions/tween-composite.test.ts"
    },
    {
        "name": "M660 分组键漏掉 targetId（背包的 opacity 乘到了 HUD 上）",
        "file": "src/extensions/tween/composite.ts",
        "pairs": [('    let byProp = at.get(e.targetId);', '    let byProp = at.get("");')],
        "test": "tests/extensions/tween-composite.test.ts"
    },
    {
        "name": "M661 第一条也合成到 0 上（首条 multiply 变 0：这条属性再也动不了）",
        "file": "src/extensions/tween/composite.ts",
        "pairs": [("      out.push({ id: e.id, targetId: e.targetId, prop: e.prop, value: e.value, done: e.done });",
                   "      out.push({ id: e.id, targetId: e.targetId, prop: e.prop, value: composeValue(e.op, 0, e.value), done: e.done });")],
        "test": "tests/extensions/tween-composite.test.ts"
    },
    {
        "name": "M662 合成顺序反着走（replace 跑到最后，覆盖语义整体错位）",
        "file": "src/extensions/tween/composite.ts",
        "pairs": [("  for (const e of entries) {", "  for (const e of [...entries].reverse()) {")],
        "test": "tests/extensions/tween-composite.test.ts"
    },
    {
        "name": "M663 算子名不校验（拼成 multipy 的轨道静默变成覆盖）",
        "file": "src/extensions/tween/composite.ts",
        "pairs": [("  return KNOWN_OPS.has(op);", "  return true;")],
        "test": "tests/extensions/tween-composite.test.ts"
    },
    {
        "name": "M664 推进器不调合成（同一属性一帧写两次，第二次盖掉第一次）",
        "file": "src/extensions/tween/tween-player.ts",
        "pairs": [("  const composed = composeEntries(entries);", "  const composed = entries;")],
        "test": "tests/extensions/tween-player.test.ts"
    },
    {
        "name": "M665 changed 恒为真（被盖掉的那条在动 ⇒ 整棵 UI 每帧重排）",
        "file": "src/extensions/tween/tween-player.ts",
        "pairs": [("    return prev === undefined || prev !== value;", "    return true;")],
        "test": "tests/extensions/tween-player.test.ts"
    },
    {
        "name": "M666 reset 不清合成值记忆（重播第一帧不报变化，界面停在上一轮末帧）",
        "file": "src/extensions/tween/tween-player.ts",
        "pairs": [('    // ★ 合成值的记忆也要清：否则"重播"的第一帧会拿新起点和**上一轮的终点**比，\n    //   恰好相等时（循环轨道、或者终值等于起点）不报 `changed`，宿主不重画 ——\n    //   症状是"重置后界面停留在上一轮最后一帧"。\n    this.lastComposed.clear();', "    // （变异：忘了清）")],
        "test": "tests/extensions/tween-player.test.ts"
    },
    {
        "name": "M667 贝塞尔三次项的系数写错（3→2：曲线形状整体塌掉）",
        "file": "src/extensions/tween/bezier.ts",
        "pairs": [("  return 3 * mt * mt * t * a + 3 * mt * t * t * b + t * t * t;", "  return 3 * mt * mt * t * a + 2 * mt * t * t * b + t * t * t;")],
        "test": "tests/extensions/tween-bezier.test.ts"
    },
    {
        "name": "M668 反解去掉二分兜底（x1=0 的曲线牛顿必然失效，f 返回错值）",
        "file": "src/extensions/tween/bezier.ts",
        "pairs": [("  for (let i = 0; i < BISECT_STEPS; i++) {", "  for (let i = 0; i < 0; i++) {")],
        "test": "tests/extensions/tween-bezier.test.ts"
    },
    {
        "name": "M669 不校验 x 越界（非单调 ⇒ 同一进度对应多个时刻）",
        "file": "src/extensions/tween/bezier.ts",
        "pairs": [("  if (x1 < 0 || x1 > 1 || x2 < 0 || x2 > 1) {", "  if (false) {")],
        "test": "tests/extensions/tween-bezier.test.ts"
    },
    {
        "name": "M670 不校验非有限控制点（NaN 一路扩散成控件消失）",
        "file": "src/extensions/tween/bezier.ts",
        "pairs": [("    if (!Number.isFinite(v)) {", "    if (false) {")],
        "test": "tests/extensions/tween-bezier.test.ts"
    },
    {
        "name": "M671 采样不调缓动（把 ease(progress) 换成 progress：自定义曲线形同虚设）",
        "file": "src/extensions/tween/tween.ts",
        "pairs": [("  const value = spec.from + (spec.to - spec.from) * spec.ease(progress);", "  const value = spec.from + (spec.to - spec.from) * progress;")],
        "test": "tests/extensions/tween-bezier.test.ts"
    },
    {
        "name": "M672 spec 里不存解析结果（ease 填成恒等：所有曲线退化成 linear）",
        "file": "src/extensions/tween/tween.ts",
        "pairs": [("      ease: e.value,", "      ease: (t: number) => t,")],
        "test": "tests/extensions/tween-bezier.test.ts"
    },
    {
        "name": "M673 getEasing 不试贝塞尔分支（资产里写自定义曲线一律 UNKNOWN）",
        "file": "src/extensions/tween/easing.ts",
        "pairs": [("  if (looksLikeCubicBezier(name)) {", "  if (false) {")],
        "test": "tests/extensions/tween-bezier.test.ts"
    },
    {
        "name": "M674 语法不允许空白（从设计工具复制来的写法一律拒绝）",
        "file": "src/extensions/tween/bezier.ts",
        "pairs": [("\\\\s*,\\\\s*", ",")],
        "test": "tests/extensions/tween-bezier.test.ts"
    },
    {
        "name": "M675 looksLikeCubicBezier 恒 false（分流永远走不到贝塞尔）",
        "file": "src/extensions/tween/bezier.ts",
        "pairs": [("  return /^\\s*cubic-bezier\\s*\\(/.test(text);", "  return false;")],
        "test": "tests/extensions/tween-bezier.test.ts"
    },
    {
        "name": "M676 解析只读三个参数（第四个变 NaN ⇒ 合法曲线被当成越界）",
        "file": "src/extensions/tween/bezier.ts",
        "pairs": [("  for (let i = 1; i <= 4; i++) nums.push(Number(m[i]));", "  for (let i = 1; i <= 3; i++) nums.push(Number(m[i]));")],
        "test": "tests/extensions/tween-bezier.test.ts"
    },
    {
        "name": "M677 输出夹到 [0,1]（回弹被掐掉：easeOutBack 变成普通 easeOut）",
        "file": "src/extensions/tween/bezier.ts",
        "pairs": [("    return sampleCurve(y1, y2, solveT(x1, x2, t));", "    return Math.max(0, Math.min(1, sampleCurve(y1, y2, solveT(x1, x2, t))));")],
        "test": "tests/extensions/tween-bezier.test.ts"
    },
    {
        "name": "M678 区间外直接返回 t（t=1.5 给 1.5：补间末帧会冲出终点）",
        "file": "src/extensions/tween/bezier.ts",
        "pairs": [("    if (t <= 0) return 0;", "    if (t <= 0) return t;")],
        "test": "tests/extensions/tween-bezier.test.ts"
    },
    {
        "name": "M679 未声明的事件回落到 initial（跑步时一个无关事件把状态打回待机）",
        "file": "src/extensions/render/anim-state.ts",
        "pairs": [("  return { state: current, clip: currentClip, consumed: false, changed: false, restart: false };", "  return { state: machine.initial, clip: stateClip(machine, machine.initial), consumed: false, changed: machine.initial !== current, restart: true };")],
        "test": "tests/extensions/anim-state.test.ts"
    },
    {
        "name": "M680 自转移不算消费（连按跑步键不再重播起跑）",
        "file": "src/extensions/render/anim-state.ts",
        "pairs": [("      consumed: true,", "      consumed: t.to !== current,")],
        "test": "tests/extensions/anim-state.test.ts"
    },
    {
        "name": "M681 不检测重复转移（同一状态同一事件两条，后者静默覆盖）",
        "file": "src/extensions/render/anim-state.ts",
        "pairs": [("    if (seen.has(key)) {", "    if (false) {")],
        "test": "tests/extensions/anim-state.test.ts"
    },
    {
        "name": "M682 不校验初始状态（initial 指向不存在的状态）",
        "file": "src/extensions/render/anim-state.ts",
        "pairs": [("  if (!Object.hasOwn(input.states, input.initial)) {", "  if (false) {")],
        "test": "tests/extensions/anim-state.test.ts"
    },
    {
        "name": "M683 不校验转移目标（走到一个没有 clip 的状态）",
        "file": "src/extensions/render/anim-state.ts",
        "pairs": [("    if (!Object.hasOwn(input.states, t.to)) {", "    if (false) {")],
        "test": "tests/extensions/anim-state.test.ts"
    },
    {
        "name": "M684 changed 恒 false（换了状态也不换 clip）",
        "file": "src/extensions/render/anim-state.ts",
        "pairs": [("      changed: t.to !== current,", "      changed: false,")],
        "test": "tests/extensions/anim-state.test.ts"
    },
    {
        "name": "M685 restart 恒 false（换了状态但时钟不清零，从上一段进度接着播）",
        "file": "src/extensions/render/anim-state.ts",
        "pairs": [("      restart: true,", "      restart: false,")],
        "test": "tests/extensions/anim-state.test.ts"
    },
    {
        "name": "M686 未知状态不抛（返回状态名当 clip，下游变成「找不到 clip」）",
        "file": "src/extensions/render/anim-state.ts",
        "pairs": [("    throw new TypeError(`\u72b6\u6001 ${JSON.stringify(state)} \u4e0d\u5728\u72b6\u6001\u673a ${JSON.stringify(machine.id)} \u91cc`);", "    return state;")],
        "test": "tests/extensions/anim-state.test.ts"
    },
    {
        "name": "M687 不校验空事件名（「没有事件」与「某个事件」混同）",
        "file": "src/extensions/render/anim-state.ts",
        "pairs": [("    if (t.event.length === 0) {", "    if (false) {")],
        "test": "tests/extensions/anim-state.test.ts"
    },
    {
        "name": "M688 状态表不冻结（一次改写会同时改掉所有共享它的实体）",
        "file": "src/extensions/render/anim-state.ts",
        "pairs": [("  const states: Record<string, string> = Object.freeze({ ...input.states });", "  const states: Record<string, string> = { ...input.states };")],
        "test": "tests/extensions/anim-state.test.ts"
    },
    {
        "name": "M689 去重键用冒号拼（状态名/事件名含分隔符时撞车，漏报重复）",
        "file": "src/extensions/render/anim-state.ts",
        "pairs": [("    const key = `${t.from}\\u0000${t.event}`;", "    const key = `${t.from}:${t.event}`;")],
        "test": "tests/extensions/anim-state.test.ts"
    },
    {
        "name": "M690 包后端谎称不能列目录（manifest 就是清单，这个信息本来就有）",
        "file": "src/extensions/build/fs-bundle.ts",
        "pairs": [("  readonly canList = true;", "  readonly canList = false;")],
        "test": "tests/extensions/fs-bundle.test.ts"
    },
    {
        "name": "M691 列目录把后代也当直接子项（资产浏览器一层展开成全部）",
        "file": "src/extensions/build/fs-bundle.ts",
        "pairs": [("      if (slash < 0) {", "      if (true) {")],
        "test": "tests/extensions/fs-bundle.test.ts"
    },
    {
        "name": "M692 相对路径不挂到 root 下（绝对路径被拼成 /assets/assets/...）",
        "file": "src/extensions/build/fs-bundle.ts",
        "pairs": [("    if (input.startsWith(\"/\")) return p;", "    if (false) return p;")],
        "test": "tests/extensions/fs-bundle.test.ts"
    },
    {
        "name": "M693 同级文件按名字倒序（顺序不确定就不是同一份清单）",
        "file": "src/extensions/build/fs-bundle.ts",
        "pairs": [("    files.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));", "    files.sort((a, b) => (a.name < b.name ? 1 : a.name > b.name ? -1 : 0));")],
        "test": "tests/extensions/fs-bundle.test.ts"
    },
    {
        "name": "M694 路径不存在时返回空字节（调用方会当成「读到了、但内容是空的」）",
        "file": "src/extensions/build/fs-bundle.ts",
        "pairs": [("    if (asset === undefined) {", "    if (asset === undefined && false) {")],
        "test": "tests/extensions/fs-bundle.test.ts"
    },
    {
        "name": "M695 exists 不查目录（根目录与中间目录都「不存在」）",
        "file": "src/extensions/build/fs-bundle.ts",
        "pairs": [("    return this.byPath.has(p.value) || this.dirs.has(p.value);", "    return this.byPath.has(p.value);")],
        "test": "tests/extensions/fs-bundle.test.ts"
    },
    {
        "name": "M696 构造期不检测重复 path（查 path 时静默取最后一个）",
        "file": "src/extensions/build/fs-bundle.ts",
        "pairs": [("      if (this.byPath.has(p.value)) {", "      if (false) {")],
        "test": "tests/extensions/fs-bundle.test.ts"
    },
    {
        "name": "M697 没有 pack 参数也去取 manifest（默认路径开始发网络请求）",
        "file": "src/extensions/build/bundle-source.ts",
        "pairs": [("  if (param === null || param === \"\") return opts.fallback();", "  if (param === \"\") return opts.fallback();")],
        "test": "tests/extensions/fs-bundle.test.ts"
    },
    {
        "name": "M698 退回直读时不留痕（「以为在测包，其实在测直读」）",
        "file": "src/extensions/build/bundle-source.ts",
        "pairs": [("  const warn = opts.warn ?? (() => {});", "  const warn = () => {};")],
        "test": "tests/extensions/fs-bundle.test.ts"
    },
    {
        "name": "M699 manifest 解析失败也继续（用一个一知半解的结构去建后端）",
        "file": "src/extensions/build/bundle-source.ts",
        "pairs": [("    if (!parsed.ok) throw new Error(", "    if (false) throw new Error(")],
        "test": "tests/extensions/fs-bundle.test.ts"
    },
    {
        "name": "M700 acquireCanvas 不检查 createCanvas 的返回值（拿到 null 也当画布用）",
        "file": "src/host/wx/env.ts",
        "pairs": [("  if (canvas === null || canvas === undefined || typeof canvas.getContext !== \"function\") {", "  if (false) {")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M701 probeWebgl2 把「取不到」当成功（于是宿主以为能上 GPU，画面一片黑）",
        "file": "src/host/wx/env.ts",
        "pairs": [("  if (gl === null || gl === undefined) {", "  if (false) {")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M702 没有 getSystemInfoSync 时把像素比猜成 2（把「不知道」写成「等于 2」）",
        "file": "src/host/wx/env.ts",
        "pairs": [("  const pixelRatio = ratio === undefined || !Number.isFinite(ratio) || ratio <= 0 ? 1 : ratio;", "  const pixelRatio = ratio ?? 2;")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M703 视口尺寸为 0 也放过去（之后所有坐标都是 NaN）",
        "file": "src/host/wx/env.ts",
        "pairs": [("  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {", "  if (false) {")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M704 帧源不看 canvas 上的 rAF，直接只认 wx（两条出口顺序反了）",
        "file": "src/host/wx/tick.ts",
        "pairs": [("  const onCanvas = canvas.requestAnimationFrame;", "  const onCanvas: WxCanvasLike[\"requestAnimationFrame\"] = undefined;")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M705 两处都没有 rAF 也不报错（造一个假调度顶上，真机上永远不刷新）",
        "file": "src/host/wx/tick.ts",
        "pairs": [("  return err(\n"
            "    engineError(WX_ERR.NO_SCHEDULER, \"canvas 与 wx 上都没有 requestAnimationFrame\"),\n"
            "  );", "  return ok({ from: \"fallback\", requestAnimationFrame: () => 0 });")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M706 dt 读 rAF 回调参数（小游戏不保证传；传了也是 undefined ⇒ NaN）",
        "file": "src/host/wx/tick.ts",
        "pairs": [("  private readonly loop = (): void => {\n"
            "    if (!this._running) return;\n"
            "    const t = this.now();", "  private readonly loop = (ts?: number): void => {\n"
            "    if (!this._running) return;\n"
            "    const t = ts ?? this.now();")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M707 stop 不取消已排队的那一帧（stop 之后还会再跑一次）",
        "file": "src/host/wx/tick.ts",
        "pairs": [("    if (this.handle !== 0) this.raf.cancelAnimationFrame?.(this.handle);", "    if (false) this.raf.cancelAnimationFrame?.(this.handle);")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M708 同级按名字升序失效（行序随文件系统而变 ⇒ 截图对不上）",
        "file": "src/host/wx/fs.ts",
        "pairs": [("        return x.name < y.name ? -1 : x.name > y.name ? 1 : 0;", "        return 0;")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M709 目录排到文件后面（清单第一行变成一个文件）",
        "file": "src/host/wx/fs.ts",
        "pairs": [("        if (x.isDirectory !== y.isDirectory) return x.isDirectory ? -1 : 1;", "        if (x.isDirectory !== y.isDirectory) return x.isDirectory ? 1 : -1;")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M710 list 拿名字猜类型（readdirSync 不给类型，猜出来全是文件）",
        "file": "src/host/wx/fs.ts",
        "pairs": [("        const st = this.mgr.statSync(joinPath(a.value, name));", "        const st = { size: 0, isDirectory: () => false };")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M711 错误分类里删掉权限分支（权限错误被读成 FS.IO，排查方向从一开始就错）",
        "file": "src/host/wx/fs.ts",
        "pairs": [("  if (low.includes(\"permission\") || low.includes(\"denied\") || low.includes(\"eacces\")) {", "  if (false) {")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M712 写文件前不建父目录（第一次存档失败、第二次能成）",
        "file": "src/host/wx/fs.ts",
        "pairs": [("    const parent = parentOf(abs);", "    const parent = \"\";")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M713 写二进制不复制（wx 持有那块内存，调用方复用时已写的内容被改掉）",
        "file": "src/host/wx/fs.ts",
        "pairs": [("      const copy = new Uint8Array(data.length);", "      const copy = data;")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M714 摇杆死区不生效（手指一碰角色就往前挪）",
        "file": "src/host/wx/input.ts",
        "pairs": [("    if (dist <= 1 && dist > pad.deadZone) {", "    if (dist <= 1 && dist >= 0) {")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M715 摇杆用方框而不是圆（矩形角落也算命中，按下去没反应）",
        "file": "src/host/wx/input.ts",
        "pairs": [("    const dist = Math.sqrt(nx * nx + ny * ny);", "    const dist = Math.max(Math.abs(nx), Math.abs(ny));")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M716 按钮命中后不 break（两个重叠按钮同时触发两个动作）",
        "file": "src/host/wx/input.ts",
        "pairs": [("      keys.push(b.key);\n"
            "      break;", "      keys.push(b.key);")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M717 触摸点不换算像素比（必须点到偏左上才有效）",
        "file": "src/host/wx/input.ts",
        "pairs": [("  const sx = space.windowWidth > 0 ? space.canvasWidth / space.windowWidth : 1;", "  const sx = 1;")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M718 多指只算最后一根（左手摇杆 + 右手按钮变成二选一）",
        "file": "src/host/wx/input.ts",
        "pairs": [("    for (const p of this.points.values()) {", "    for (const p of [...this.points.values()].slice(-1)) {")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M719 poll 不清边缘（一次点击被处理到下一次 poll）",
        "file": "src/host/wx/input.ts",
        "pairs": [(
            "    this.pressed.clear();\n    this.released.clear();\n"
            "    this.pointerPressed = false;\n    this.pointerReleased = false;\n    return snap;",
            "    this.pointerPressed = false;\n    this.pointerReleased = false;\n    return snap;",
        )],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M720 createWxInput 不检查有没有触摸订阅（没有输入源也装作能玩）",
        "file": "src/host/wx/input.ts",
        "pairs": [("  if (!WxInputDevice.hasTouch(wx)) {", "  if (false) {")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M721 destroy 不设 dead 标记（没给 off* 的实现回调照旧改状态）",
        "file": "src/host/wx/input.ts",
        "pairs": [("    this.dead = true;", "    this.dead = false;")],
        "test": "tests/host/wx.test.ts"
    },
    {
        "name": "M722 yieldOf 的兜底没了（产量配成 0 时种出空堆：采不动、也永远拆不掉）",
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("    return normCount(raw);",
                   "    return raw;")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M723 再生时不把产量冻进 count（世界上长出来的全是 1 份，芦苇少一半）",
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("          made.value.count = yieldOf(made.value.kind);",
                   "          made.value.count = 1;")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M724 placeResource 忽略 count 参数（丢 45 个只放 1 个，其余 44 个凭空消失）",
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("      made.value.count = count === undefined ? yieldOf(kind) : normCount(count);",
                   "      made.value.count = 1;")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M725 stackResource 不看种类（把 tree 叠进 berry 堆，berry 凭空消失）",
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("        if (r.cell !== cell || r.node === null || r.kind !== kind) continue;",
                   "        if (r.cell !== cell || r.node === null) continue;")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M726 叠堆不记账（stacked 恒 0：合并这件事在世界账目上完全不可观察）",
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("        stacked += n;",
                   "        void n;")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M727 stats 不暴露 stacked（内部记了也不给看，等于没记）",
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("        stacked,",
                   "        stacked: 0,")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M728 stackResource 不校验数量（n = 0 也算成功，调用方以为叠上了）",
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("      if (!Number.isInteger(n) || n <= 0) {",
                   "      if (false) {")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M729 叠堆顺手把 spawned 加一（账目串到放置上：上限提前撞满）",
        "file": "src/extensions/worldgen/task-module.ts",
        "pairs": [("        r.count += n;",
                   "        r.count += n; spawned++;")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M730 只剩 1 个就销毁（left <= 1：最后那个凭空消失，背包只收到 taken 个）",
        "file": "src/extensions/worldgen/harvest.ts",
        "pairs": [("    if (left === 0) {",
                   "    if (left <= 1) {")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M731 每次都销毁（回到批122 前：拿 2 个也把整堆 5 个一起删掉）",
        "file": "src/extensions/worldgen/harvest.ts",
        "pairs": [("    if (left === 0) {",
                   "    if (true) {")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M732 采完不减 count（永远采不光，同一格可以无限采）",
        "file": "src/extensions/worldgen/harvest.ts",
        "pairs": [("    r.count = out.left;",
                   "    void out.left;")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M733 count = 0 的堆不兜底（存档被伪造出空堆时它永远采不动）",
        "file": "src/extensions/worldgen/harvest.ts",
        "pairs": [("    const have = Math.max(1, r.count);",
                   "    const have = r.count;")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M734 忽略这次的上限（要 2 个给 5 个：凭空生资源）",
        "file": "src/extensions/worldgen/harvest.ts",
        "pairs": [("    const taken = Math.min(ask, have);",
                   "    const taken = have;")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M735 peek 的 count 恒 1（背包满时调用方算不出还能拿几个）",
        "file": "src/extensions/worldgen/harvest.ts",
        "pairs": [("      return { kind: r.kind, source: \"resource\", count: Math.max(1, r.count) };",
                   "      return { kind: r.kind, source: \"resource\", count: 1 };")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M736 不校验 amount（传 0 也当成功，返回 taken = 0 让调用方以为采到了）",
        "file": "src/extensions/worldgen/harvest.ts",
        "pairs": [("  if (!(askRaw > 0)) {",
                   "  if (false) {")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M737 harvestInto 只往包里加 1 个（与这一堆的数量脱钩：堆里 45 个只捡回 1 个）",
        "file": "src/extensions/inventory/harvest-into.ts",
        "pairs": [("  const added = addItem(scene, ownerId, peek.kind, want);",
                   "  const added = addItem(scene, ownerId, peek.kind, 1);")],
        "test": "tests/extensions/drop-to-world.test.ts"
    },
    {
        "name": "M738 pickupNearby 默认上限 1（地上一堆 40 个，按一次只捡一个）",
        "file": "src/extensions/inventory/pickup.ts",
        "pairs": [("      ? () => Number.POSITIVE_INFINITY",
                   "      ? () => 1")],
        "test": "tests/extensions/drop-to-world.test.ts"
    },
    {
        "name": "M739 丢弃永不合并（每次都新建碎堆，地上很快全是同一格一颗的图）",
        "file": "src/extensions/inventory/drop-to-world.ts",
        "pairs": [("  const stackAt = findStackCell(scene, opts.plan, opts.x, opts.z, kind, opts.searchCells);",
                   "  const stackAt: number | null = null;")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M740 findStackCell 不看种类（把 tree 的落点指到 berry 堆上，放置随即失败）",
        "file": "src/extensions/inventory/drop-to-world.ts",
        "pairs": [("    if (r.node === null || r.kind !== kind) continue;",
                   "    if (r.node === null) continue;")],
        "test": "tests/extensions/drop-to-world.test.ts"
    },
    {
        "name": "M741 findStackCell 半径无上限（隔着半张图也能合并，位置完全失控）",
        "file": "src/extensions/inventory/drop-to-world.ts",
        "pairs": [("    if (d > reach) continue;",
                   "    if (false) continue;")],
        "test": "tests/extensions/stack.test.ts"
    },
    {
        "name": "M742 新建堆时把 n 丢了（传 1：丢 45 个只放 1 个）",
        "file": "src/extensions/inventory/drop-to-world.ts",
        "pairs": [("  const placed = opts.tasks.placeResource(cell, kind, opts.bornTick, n);",
                   "  const placed = opts.tasks.placeResource(cell, kind, opts.bornTick, 1);")],
        "test": "tests/extensions/drop-to-world.test.ts"
    },
    {
        "name": "M743 合并分支谎报 merged = false（走了叠堆却说是新建，两条账从此分不清）",
        "file": "src/extensions/inventory/drop-to-world.ts",
        "pairs": [("    return ok({ cell: stackAt, nodeId: stackedUp.value.nodeId, count: stackedUp.value.count, dropped: n, merged: true });",
                   "    return ok({ cell: stackAt, nodeId: stackedUp.value.nodeId, count: stackedUp.value.count, dropped: n, merged: false });")],
        "test": "tests/extensions/stack.test.ts"
    },
    # ────────────────────────── 批123：尸体（C18 第三项） ──────────────────────────
    {
        "name": "M744 环扫丢掉第 0 圈（中心格永远不入围）",
        # 症状：丢东西永远掉到旁边一格、尸体永远不落在死亡格。
        # 两者都"成功了"，只是位置偏一格 —— 而回放比对的是格子，不是"有没有放"。
        "file": "src/extensions/worldgen/cell-ring.ts",
        "pairs": [(
            """  if (r === 0) {
    if (cx >= 0 && cx < width && cz >= 0 && cz < height) out.push(cz * width + cx);
    return;
  }""",
            """  if (r === 0) {
    return;
  }""",
        )],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M745 环内顺序倒过来（同距离取到的是大 cell）",
        # 由近到远还在，环内顺序反了 ⇒ "同距离取小 cell"这条确定性没了。
        # 两次调用之间仍然一致，所以只比"两次是否相同"的判据抓不住。
        "file": "src/extensions/worldgen/cell-ring.ts",
        "pairs": [(
            """  for (let dz = -r; dz <= r; dz++) {
    for (let dx = -r; dx <= r; dx++) {""",
            """  for (let dz = r; dz >= -r; dz--) {
    for (let dx = r; dx >= -r; dx--) {""",
        )],
        "test": "tests/extensions/drop-to-world.test.ts",
    },
    {
        "name": "M746 生成尸体时不写 cell（按格永远找不到它）",
        # 组件在、节点在、items 也对 —— 只有 `corpseAt(cell)` 永远 null。
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [("  made.value.cell = cell;\n", "")],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M747 生成尸体时不写 items（尸体是空的，翻了也没东西）",
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [("  made.value.items = encodeItems(items);\n", "")],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M748 腐烂时刻存成相对量（不 + nowTick）",
        # 相对量意味着"读档续命"：存档前剩 600、读档后又从当前 tick 数 600。
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [(
            "  made.value.decayAtTick = decayTicks === 0 ? 0 : opts.nowTick + decayTicks;",
            "  made.value.decayAtTick = decayTicks === 0 ? 0 : decayTicks;",
        )],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M749 空表也生成尸体（玩家白跑一趟，而且那一格再也放不下别的尸体）",
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [("  if (items.length === 0) {", "  if (false) {")],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M750 不校验腐烂时长（-1 直接当「已经烂了」）",
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [("  if (!Number.isInteger(decayTicks) || decayTicks < 0) {", "  if (false) {")],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M751 尸体落点不查可走性（尸体躺在海里）",
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [("      if (!ground.isWalkableIndex(cell)) continue;\n", "")],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M752 尸体落点不看「这格已经有一具」（两具叠在一格）",
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [("      if (occupied.has(cell)) continue;\n", "")],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M753 配表不排序就进存档（同一张表的两种写法产出两份不同的档）",
        # 它同时是"跨宿主逐字节比对"的地基：顺序不稳，两边各写一遍就会随机红。
        "file": "src/extensions/combat/loot.ts",
        "pairs": [("  out.sort((x, y) => (x.kind < y.kind ? -1 : x.kind > y.kind ? 1 : 0));\n", "")],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M754 解码用 indexOf 而不是 lastIndexOf（kind 含冒号就解错）",
        "file": "src/extensions/combat/loot.ts",
        "pairs": [(
            '    const at = s.lastIndexOf(":");',
            '    const at = s.indexOf(":");',
        )],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M755 解码不校验数量（NaN / 负数 / 前导零都能进配表）",
        "file": "src/extensions/combat/loot.ts",
        "pairs": [("    if (!Number.isInteger(n) || n <= 0 || String(n) !== raw) {", "    if (false) {")],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M756 腐烂差一 tick（到点那一 tick 还看得见）",
        # 只在"正好走到那一 tick"的判据里可见；跑一万 tick 的粗判据看不出来。
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [(
            "        if (tick < c.decayAtTick) continue;\n",
            "        if (tick <= c.decayAtTick) continue;\n",
        )],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M757 删掉「永不腐烂」的哨兵（decayAtTick = 0 的尸体下一 tick 就烂）",
        # ★ 0 在 `tick >= decayAtTick` 里恒真 ⇒ 一具本该永久的尸体立刻消失。
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [("        if (c.decayAtTick === 0) continue;\n", "")],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M758 腐烂后不 flush（组件没了，节点还在场景里）",
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [("      s.flush();\n      decayed += due.length;", "      decayed += due.length;")],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M759 多条目取到一半失败不回滚（背包比尸体多一件）",
        # ★ 最隐蔽的一种：第一次 addItem 成功、第二次满 ⇒ 玩家白得一件，
        #   而"取成功了没有"看起来完全正常（返回值是错误码，可没人会去看背包对账）。
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [(
            """      for (const back of added) {
        const rb = takeItem(scene, ownerId, back.kind, back.count);
        // 退回失败只能透传：继续退回剩下的会掩盖第一处失败
        if (!rb.ok) return rb;
      }
""",
            "",
        )],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M760 尸体取空后不销毁节点（幽灵尸体：看得见、再也取不出东西）",
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [(
            "  if (emptied) {\n    scene.destroy(nodeId);\n    scene.flush();\n  } else {",
            "  if (false) {\n    scene.destroy(nodeId);\n    scene.flush();\n  } else {",
        )],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M761 取东西时忽略 amount 上限（点「拿 2 个」把整堆拿走）",
        "file": "src/extensions/combat/corpse.ts",
        "pairs": [(
            "    take.push({ kind: e.kind, count: Math.min(e.count, limit) });",
            "    take.push({ kind: e.kind, count: e.count });",
        )],
        "test": "tests/extensions/corpse.test.ts",
    },
    {
        "name": "M762 尸体放不下时不退回进背包（战利品凭空消失）",
        # 画面上只是"地上没有尸体"，玩家不会想到去怀疑地形。
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [(
            """              corpsesFailed++;
              lastCorpseError = placed.error.code;
            } else {""",
            """              corpsesFailed++;
              lastCorpseError = placed.error.code;
              return;
            } else {""",
        )],
        "test": "tests/extensions/mob-world.test.ts",
    },
    {
        "name": "M763 尸体模式下仍然把战利品发给击杀者（双份掉落）",
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [(
            """              if (placed.ok) {
                corpsesSpawned++;
                return;
              }""",
            """              if (placed.ok) {
                corpsesSpawned++;
              }""",
        )],
        "test": "tests/extensions/mob-world.test.ts",
    },
    {
        "name": "M764 生成尸体时把 tick 传成 0（腐烂时刻从世界的开端算）",
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [("                nowTick: tick,", "                nowTick: 0,")],
        "test": "tests/extensions/mob-world.test.ts",
    },
    {
        "name": "M765 尸体不上屏（世界里有、画面上没有）",
        "file": "src/extensions/render/world-visuals.ts",
        "pairs": [(
            "  for (const body of scene.componentsOf<Corpse>(CORPSE_TYPE)) {",
            "  for (const body of [] as Corpse[]) {",
        )],
        "test": "tests/extensions/world-visuals.test.ts",
    },
    # ---- 批123 后期：战利品表改成**实体上的组件**（`game.loot`）
    #   这一组盯的是"旁表 vs 组件"的区别本身：旁表是进程内状态，
    #   读档换了场景就查不到 —— 症状是"读档之后打死的怪什么都不掉"，且无日志。
    {
        "name": "M766 挂表后不 flush（组件还在队列里，紧接着的读操作读不到 ⇒ 挂上两个）",
        "file": "src/extensions/combat/loot.ts",
        "pairs": [(
            "  scene.flush();\n  return ok(norm.value);\n}\n",
            "  return ok(norm.value);\n}\n",
        )],
        "test": "tests/extensions/combat-loot.test.ts",
    },
    {
        "name": "M767 表读不出来时静默当成「没有掉落」（东西凭空消失且无日志）",
        "file": "src/extensions/combat/loot.ts",
        "pairs": [(
            "  if (!decoded.ok) return decoded;\n",
            "  if (!decoded.ok) return ok(null);\n",
        )],
        "test": "tests/extensions/combat-loot.test.ts",
    },
    {
        "name": "M768 空表返回空数组而不是 null（调用方再生成一具空尸体、再报一次错）",
        "file": "src/extensions/combat/loot.ts",
        "pairs": [(
            "  return ok(decoded.value.length === 0 ? null : decoded.value);",
            "  return ok(decoded.value);",
        )],
        "test": "tests/extensions/combat-loot.test.ts",
    },
    {
        "name": "M769 挂表时不过 normalizeLoot（配表顺序直接进存档 ⇒ 跨宿主比对随机红）",
        "file": "src/extensions/combat/loot.ts",
        "pairs": [(
            "  const items = encodeItems(norm.value);",
            "  const items = encodeItems(table as LootTable);",
        )],
        "test": "tests/extensions/combat-loot.test.ts",
    },
    {
        "name": "M770 挂表不检查节点在不在（对不存在的 id 也返回成功）",
        "file": "src/extensions/combat/loot.ts",
        "pairs": [(
            "  if (node === undefined) {\n    return err(engineError(LOOT_NO_NODE,",
            "  if (false) {\n    return err(engineError(LOOT_NO_NODE,",
        )],
        "test": "tests/extensions/combat-loot.test.ts",
    },
    {
        "name": "M771 挂表不检查组件注册（报的是引擎的通用错，说不出是谁要挂）",
        "file": "src/extensions/combat/loot.ts",
        "pairs": [("  if (!scene.components.has(LOOT_TYPE)) {", "  if (false) {")],
        "test": "tests/extensions/combat-loot.test.ts",
    },
    {
        "name": "M772 spawnMob 不挂战利品表（生物一打死就什么都不掉）",
        "file": "src/extensions/mobs/spawn-mob.ts",
        "pairs": [(
            "  if (tpl.loot.length > 0) attached.push([LOOT_TYPE, loot]);",
            "  if (false) attached.push([LOOT_TYPE, loot]);",
        )],
        "test": "tests/extensions/mob-world.test.ts",
    },
    {
        "name": "M773 击杀时表读不出来就当成没有掉落（AI 那条路的静默丢）",
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [(
            "          if (!lootR.ok) {\n            // 表在、但读不出来：不能当成\"没有掉落\"，否则东西凭空消失且无日志\n            lastLootError = lootR.error.code;\n            return;\n          }\n          const loot = lootR.value;",
            "          const loot = lootR.ok ? lootR.value : null;",
        )],
        "test": "tests/extensions/mob-world.test.ts",
    },
    {
        "name": "M777 blockCells 封了格却不作废连通分量（分量说有路、寻路说没有）",
        "file": "src/extensions/nav/nav-grid.ts",
        "pairs": [("      this.labels.fill(-1);\n      this.labeled = false;\n      this.labelCount = 0;\n", "")],
        "test": "tests/extensions/nav-grid.test.ts",
    },
    {
        "name": "M778 blockCells 只计数不封格（摆件仍然是一条通途）",
        "file": "src/extensions/nav/nav-grid.ts",
        "pairs": [("      this.mask[c] = 0;\n", "")],
        "test": "tests/extensions/nav-grid.test.ts",
    },
    {
        "name": "M779 blockCells 把已经封过的格也算成新封（返回值会虚高）",
        "file": "src/extensions/nav/nav-grid.ts",
        "pairs": [("      if (this.mask[c] === 0) continue;\n", "")],
        "test": "tests/extensions/nav-grid.test.ts",
    },
    {
        "name": "M780 syncBodies 不补体（读档清了物理表之后，生物静默开始穿模）",
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [(
            "      phys.add({ nodeId: id, radius, isStatic: false });\n      bodiesAdded++;\n",
            "",
        )],
        "test": "tests/extensions/mob-collision.test.ts",
    },
    {
        "name": "M781 prune 不撤死者的体（原地一堵看不见的墙）",
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [(
            "      if (phys !== undefined && phys.has(id)) {\n        phys.remove(id);\n        bodiesRemoved++;\n      }\n",
            "",
        )],
        "test": "tests/extensions/mob-collision.test.ts",
    },
    {
        "name": "M782 生物体登记成静态体（解算不推它，它站在树里出不来）",
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [("      phys.add({ nodeId: id, radius, isStatic: false });\n", "      phys.add({ nodeId: id, radius, isStatic: true });\n")],
        "test": "tests/extensions/mob-collision.test.ts",
    },
    {
        "name": "M783 resyncBodies 什么都不补（读档后的 33ms 空窗又回来了）",
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [("      return syncBodies();\n", "      return 0;\n")],
        "test": "tests/extensions/mob-collision.test.ts",
    },
    {
        "name": "M784 resyncBodies 不先 prune（读档时对已销毁的节点补体 ⇒ 直接抛）",
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [("      prune();\n      return syncBodies();\n", "      return syncBodies();\n")],
        "test": "tests/extensions/mob-collision.test.ts",
    },
    {
        "name": "M785 宿主读档时不补生物体（模块有入口，但没人调 —— 接线断了）",
                # ★ 批128：装配从 `browser-entry.ts` 搬进 `host/demo-game.ts`，靶子跟着搬家（代码一字未改）。
"file": "src/host/demo-game.ts",
        "pairs": [("    const back = worldState.mobs?.resyncBodies() ?? 0;\n", "    const back = 0;\n")],
        "cmd": ["node", "tools/browser-selftest.mjs", "--build"],
    },
    {
        "name": "M786 `update` 里不调 respawnPrey（再生规则写好了，但没人跑 —— 兔子照样灭绝）",
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [("      respawnPrey(tick);\n", "")],
        "test": "tests/extensions/mob-world-respawn.test.ts",
    },
    {
        "name": "M787 再生不看上限（`max` 变成摆设，兔子越打越多）",
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [("    if (alive >= rp.max) return;\n", "")],
        "test": "tests/extensions/mob-world-respawn.test.ts",
    },
    {
        "name": "M788 再生不看窗口（每一拍都补一只，直到上限）",
        "file": "src/extensions/mobs/mob-world.ts",
        "pairs": [("    if (tick - lastRespawnCheck < rp.everyTicks) return;\n", "")],
        "test": "tests/extensions/mob-world-respawn.test.ts",
    },
    {
        "name": "M789 落点不避开活物周围若干格（兔子生成在猎狗嘴边 = 生成即被杀）",
        "file": "src/host/prey-respawn.ts",
        "pairs": [("  for (const c of liveCells) blockAround(grid, c, cfg.blockCells, blocked);\n", "")],
        "test": "tests/host/prey-respawn.test.ts",
    },
    {
        "name": "M790 宿主不传 respawn（引擎能力在，演示世界用不上 —— 接线断了）",
                # ★ 批128：装配从 `browser-entry.ts` 搬进 `host/demo-game.ts`，靶子跟着搬家（代码一字未改）。
"file": "src/host/demo-game.ts",
        "pairs": [(
            "        respawn: {\n          everyTicks: DEMO_PREY_RESPAWN.everyTicks,\n          kind: DEMO_PREY_RESPAWN.kind,\n          max: DEMO_PREY_RESPAWN.max,\n          template: DEMO_PREY_RESPAWN.template,\n          pickCell: (tick) => pickPreySpawnCell(tick),\n        },\n",
            "",
        )],
        "cmd": ["node", "tools/browser-selftest.mjs", "--build"],
    },
    {
        "name": "M791 落点只查下界不查上界（兔子被扔到地图另一头，玩家永远遇不到）",
        "file": "src/host/prey-respawn.ts",
        "pairs": [("    if (d < q.minCells || d > q.maxCells) continue;\n", "    if (d < q.minCells) continue;\n")],
        "test": "tests/host/prey-respawn.test.ts",
    },
    {
        "name": "M792 封格用曼哈顿距离（斜角漏掉，兔子从斜角被咬死）",
        "file": "src/host/prey-respawn.ts",
        "pairs": [(
            "    for (let dz = -r; dz <= r; dz++) {\n",
            "    for (let dz = -r; dz <= r; dz++) {\n      if (Math.abs(dx) + Math.abs(dz) > r) continue;\n",
        )],
        "test": "tests/host/prey-respawn.test.ts",
    },
    {
        "name": "M793 闸门不再看「项」格的自述（做完的项目可以一直挂在 🔜 上，清单又回答不了「还剩几件」）",
        "file": "tools/blockers-check.mjs",
        "pairs": [("      const claim = DONE_CLAIM_RE.exec(item);\n", "      const claim = null;\n")],
        "test": "tests/tools/blockers-check.test.ts",
    },
    {
        "name": "M794 构建忽略 mount（manifest 登记的键回到源文件位置，?pack= 每个 readBinary 都 NOT_FOUND）",
        "file": "src/extensions/build/from-pipeline.ts",
        "pairs": [(
            "    const logical = mount === undefined ? path : `${mount}${path.slice(rootTrim.length)}`;\n",
            "    const logical = path;\n",
        )],
        "test": "tests/extensions/build-cli.test.ts",
    },
    {
        "name": "M795 资产来源永远自报 direct（走包也说自己走直读 —— 探针分不清哪条路径真的用了）",
        "file": "src/browser-entry.ts",
        "pairs": [(
            '      assetKindLabel = source instanceof BundleFileSystem ? "bundle" : "direct";\n',
            '      assetKindLabel = "direct";\n',
        )],
        "cmd": ["node", "tools/browser-selftest.mjs", "--build"],
    },
    {
        "name": "M796 资产来源永远自报 bundle（退回直读也说在走包 —— 「静默退回」从此又变成长期假象）",
        "file": "src/browser-entry.ts",
        "pairs": [(
            '      assetKindLabel = source instanceof BundleFileSystem ? "bundle" : "direct";\n',
            '      assetKindLabel = "bundle";\n',
        )],
        "cmd": ["node", "tools/browser-selftest.mjs", "--build"],
    },
    # ---- 批128：宿主抽取（demo-game / wx 入口 / 注入输入 / 严格后端）
    {
        "name": "M797 strict 不往下透传（宿主说了「输入不许降级」，平台听见了却没转达）",
        "file": "src/platform/platform.ts",
        "pairs": [(
            "    req.strict?.includes(kind) === true ? { allowFallbackToNull: false } : {};\n",
            # ★ 变异成恒 `{}`：注册表退回默认语义「挑不到就继续往下挑」——
            #   prefer 的后端 probe 不过时会**静默**落到 null 后端，
            #   症状是"游戏起来了但按什么都没反应"，与"输入没接好"画面完全一样。
            "    false ? { allowFallbackToNull: false } : {};\n",
        )],
        "test": "tests/backends/input-injected.test.ts",
    },
    {
        "name": "M798 probe 把 null 当成「给了设备」（之后 create 才炸，栈里已看不到是谁注入的）",
        "file": "src/backends/input-injected/device.ts",
        "pairs": [(
            "    return (options as InjectedInputOptions | undefined)?.device != null;\n",
            # ★ `!= null` 与 `!== undefined` 差的就是 null 这一格，而它恰恰是最常见的那格：
            #   调用方从可选字段读出来的常常正是 null。
            "    return (options as InjectedInputOptions | undefined)?.device !== undefined;\n",
        )],
        "test": "tests/backends/input-injected.test.ts",
    },
    {
        "name": "M799 两样都看不见也照样启动（起了但什么都没有，比起不来更贵）",
        "file": "src/host/demo-game.ts",
        "pairs": [(
            '  if (hudUi === null && surface?.hudLine === undefined) {\n'
            '    throw new Error("DEMO.NO_VISIBLE_HUD：既没有可用的 UI 资产，宿主也没有能显示一行文本的地方");\n'
            "  }\n",
            # ★ 不抛之后工程照样跑得起来：模块全绿、tick 在走、日志里只有几条 warn。
            #   这正是要拦的那一类 —— 玩家看到的是黑屏，开发者看到的是"没报错"。
            "  if (hudUi === null && surface?.hudLine === undefined) {\n"
            "    // 变异：不抛（让它起得来）\n"
            "  }\n",
        )],
        "test": "tests/host/wx-entry.test.ts",
    },
    {
        "name": "M800 无条件建脚本模块（`SCRIPT.NOT_SUPPORTED` 把整个启动拖下来）",
        "file": "src/host/demo-game.ts",
        "pairs": [(
            "  const scriptMod = env.scriptWasm === null ? null : createScriptModule({ callTimeoutMs: 16 });\n",
            # ★ 「这个宿主有没有脚本能力」必须在**建模块之前**回答：
            #   `script-null` 的 `caps.executes` 是 false，`init` 会直接报错。
            "  const scriptMod = createScriptModule({ callTimeoutMs: 16 });\n",
        )],
        "test": "tests/host/wx-entry.test.ts",
    },
    {
        "name": "M801 GameApp 丢掉 strict（宿主说了「不许降级」，装配转手就扔了）",
        "file": "src/runtime/GameApp.ts",
        "pairs": [(
            "      ...(opts.strict === undefined ? {} : { strict: opts.strict }),\n",
            # ★★ 这条是**真事**，不是假想：`GameAppOptions` 原先没有 `strict` 字段，
            #   而装配是用 `...(env.platform ?? {})` 展开进来的 —— 对象展开**不做**
            #   多余属性检查，于是 wx 入口从批128 起写的 `strict` 一次都没到过平台。
            #   症状与"写了没生效"完全一样：黑屏也能起得来，所有子系统判据全绿。
            #   判别法：**参数跨了三层**（入口 → DemoHostEnv.platform → GameAppOptions
            #   → PlatformRequest），就得有一层判据去验"它到底到没到尽头"。
            "      ...(opts.strict === undefined ? {} : {}),\n",
        )],
        "test": "tests/host/wx-entry.test.ts",
    },
    {
        "name": "M802 资产盘复用存档盘（包内只读与用户目录可写是两个根）",
        "file": "src/wx-entry.ts",
        "pairs": [(
            "    open: async () => assetFs,\n",
            # ★ 症状是"真机上资产全读不到、模拟器上正常"：模拟器两者等价，
            #   真机上 `wxfile://usr` 里根本没有 `ui-font.fnt`。
            "    open: async () => host.fs,\n",
        )],
        "test": "tests/host/wx-entry.test.ts",
    },
    {
        "name": "M803 触摸设备没交给平台（适配层全绿，平台里跑的却是 input-null）",
        "file": "src/wx-entry.ts",
        "pairs": [(
            "        input: { device: host.input },\n",
            # ★ 这条是本批的核心接线：不交设备 ⇒ probe 为 false ⇒ 平台没有输入。
            #   而 `host/wx/` 那 37 条判据此刻**依然全绿**（它们验的是翻译，不是接线）。
            "        input: {},\n",
        )],
        "test": "tests/host/wx-entry.test.ts",
    },
    {
        "name": "M804 扫产物前不剥注释（解释规则的注释把闸门自己顶红）",
        "file": "src/publish/pack-plan.ts",
        "pairs": [(
            '  const lines = stripJsComments(source).split("\\n");\n',
            # ★ 引擎里最该保留的注释恰恰是「为什么不能用 window.setTimeout」这种，
            #   它们逐字包含被禁的字符串 ⇒ 假红。假红比漏报更贵（被挡过的人会关闸门）。
            '  const lines = source.split("\\n");\n',
        )],
        "test": "tests/publish/pack-plan.test.ts",
    },
    {
        "name": "M805 连字符串字面量一起剥（`el[\"document.\" + x]` 这种动态拼法彻底消失）",
        "file": "src/publish/pack-plan.ts",
        "pairs": [(
            '    if (mode === "sq" || mode === "dq") {\n'
            "      // 字符串**原样保留**（见调用点的说明），但要知道它什么时候结束\n"
            "      out.push(c);\n",
            # ★ 看起来"更干净"（连引号内容都不算了），实际把最需要在闸门上看见的
            #   那一种擦掉了：动态拼法 `el["document." + x]` 只在字符串里露出线索。
            '    if (mode === "sq" || mode === "dq") {\n'
            "      // 变异：字符串也当注释抹掉\n"
            '      out.push(" ");\n',
        )],
        "test": "tests/publish/pack-plan.test.ts",
    },
    {
        "name": "M806 剥注释时把换行也吃掉（后面的行号全歪一格，报错指到别人头上）",
        "file": "src/publish/pack-plan.ts",
        "pairs": [(
            '    if (mode === "line") {\n      if (c === "\\n") {\n        mode = "code";\n        out.push(c);\n',
            # ★ 长度保持是为了**行号**；只保长度不保换行等于没保。
            '    if (mode === "line") {\n      if (c === "\\n") {\n        mode = "code";\n        out.push(" ");\n',
        )],
        "test": "tests/publish/pack-plan.test.ts",
    },
    {
        "name": "M807 装配里混进一个小游戏没有的 API（闸门只扫 host/wx/ ⇒ 真机上才白屏）",
        "file": "src/host/demo-game.ts",
        "pairs": [(
            'export const ASSET_ROOT = "/assets";\n',
            # ★ 破坏方式刻意选"不改变任何行为"的那一种：一个没人调用的函数体。
            #   它只能被**静态闸门**看见 —— 所有运行时判据都会绿（假 wx 里根本没人访问 document），
            #   而这正是"闸门要跟着代码搬家"的理由：搬走了 3000 行，闸门的目录却没跟着动。
            'export const ASSET_ROOT = "/assets";\n\nconst __forbiddenProbe = (): unknown => globalThis.document.title;\n',
        )],
        "test": "tests/host/wx.test.ts",
    },    {
        "name": "M808 干净时静默通过（`0 处` 不打印 ⇒ 分不清「扫了 0 处」与「压根没扫」）",
        "file": "tools/pack.ts",
        "pairs": [(
            "    console.log(\n      `\\n✓ 小游戏禁用 API：0 处（扫了 ",
            # ★ 退出码仍然是 0，`--strict-api` 的判据也仍然绿 —— 唯一的差别是**没有输出**。
            #   「判据输出恒为空」正是本项目反复吃亏的那种"没验"。
            "    void 0 && console.log(\n      `\\n✓ 小游戏禁用 API：0 处（扫了 ",
        )],
        "test": "tests/publish/pack-cli.test.ts",
    },
    {
        "name": "M809 wx 启动失败只冒泡不播报（真机上就是白屏无提示）",
        # ★ 这是修复前的行为：`surface` 建好之前抛的错（WX.NO_TOUCH / WX.NO_FS）一路冒到
        #   `void main()` ⇒ 真机上未处理的 promise 拒绝通常**什么都不发生** ——
        #   与「还在加载」在屏幕上一模一样。
        "file": "src/wx-entry.ts",
        "pairs": [("    reportFatal(wx, e instanceof Error ? e.message : String(e));\n", "    throw e;\n")],
        "test": "tests/host/wx-entry.test.ts",
    },
    {
        "name": "M810 启动失败只打日志不弹窗（开发者看得见，玩家仍是白屏）",
        # 与 M809 是**两个不同的观测量**：那条验「有没有播报」，这条验「播给谁看」。
        # 只留 console.error 时，判据必须红在弹窗那一条上 —— 否则玩家看到的白屏没人管。
        "file": "src/wx-entry.ts",
        "pairs": [("  wx.showModal?.({ title: \"启动失败\", content: text.slice(0, 200), showCancel: false });\n", "  void wx;\n")],
        "test": "tests/host/wx-entry.test.ts",
    },
    {
        "name": "M811 包体下限调成 0（构建成空壳也通过）",
        # 空壳是最容易发生的产物退化：入口改坏、tree-shaking 把整局吃掉 —— 产物仍然「构建成功」。
        "file": "tools/wx-check.mjs",
        "pairs": [("export const MIN_BUNDLE_BYTES = 200_000;", "export const MIN_BUNDLE_BYTES = 0;")],
        "test": "tests/host/wx-bundle.test.ts",
    },
    {
        "name": "M812 ESM export 判据扫了个空串（恒不命中，闸门变成装饰）",
        "file": "tools/wx-check.mjs",
        "pairs": [("  if (ESM_EXPORT.test(source)) {", "  if (ESM_EXPORT.test(source.slice(0, 0))) {")],
        "test": "tests/host/wx-bundle.test.ts",
    },
    {
        "name": "M813 node 内置判据漏掉 `from \"node:…\"` 这一种写法（require 仍然报）",
        # ★ 半错的变异比「完全失效」难发现得多：合成语料里两种写法都在，只漏一种时
        #   另一种仍然绿 —— 这正是「判据要能分辨两种改法」的意义。
        "file": "tools/wx-check.mjs",
        "pairs": [("|\\bfrom\\s*)[\"']node:[a-z/]+[\"']/;", "|\\bimported\\s*)[\"']node:[a-z/]+[\"']/;")],
        "test": "tests/host/wx-bundle.test.ts",
    },
    {
        "name": "M814 小游戏包被打成 ESM（真机 Unexpected token；而 export 那条抓不到）",
        # ★ 实测过：esm 产物**没有** `export`（入口没有导出），所以 ESM_EXPORT 那条是绿的；
        #   抓住它的是「必须含 EngineWx」那条结构判据。这就是它存在的理由。
        "file": "tools/build-wx.mjs",
        "pairs": [("  format: \"iife\",", "  format: \"esm\",")],
        "test": "tools/wx-check.mjs",
        "cmd": ["node", "tools/wx-check.mjs"],
    },
    {
        "name": "M815 CI 里删掉小游戏包那一步（闸门表 15 行 vs --list 14 步）",
        # ★ 这条验的是「新闸门真的进了 CI」，而不是「写了这个脚本」：
        #   删掉这一步，ARCHITECTURE 的闸门表与 `ci.mjs --list` 立刻对不上。
        "file": "tools/ci.mjs",
        "pairs": [("  node(\"小游戏包构建+断言\", \"tools/wx-check.mjs\");\n", "")],
        "test": "tools/docs-check.mjs",
        "cmd": ["node", "tools/docs-check.mjs", "--quick"],
    },
    {
        "name": "M816 返回值桥接不判环（自引用表退回「嵌套超过 32 层」）",
        # ★ 这就是批130 修复前的行为：`c.__index = c` 会一路展开 32 层，
        #   报的是「八成是成环的表」—— 说了症状，没说原因。
        "file": "src/backends/script-lua/runtime.ts",
        "pairs": [("    if (path.has(src)) {\n", "    if (false) {\n")],
        "test": "tests/backends/script-value-cycle.test.ts",
    },
    {
        "name": "M817 只在对象分支判环，数组分支漏判（`t[1] = t` 退回深度兜底）",
        # ★ 第一版实现就是这样：数组分支在对象分支**之前**，判环写在对象里，
        #   于是自引用数组永远走不到 —— 判据当场红在 `返回值[0][0][0]…` 上。
        "file": "src/backends/script-lua/runtime.ts",
        "pairs": [("    if (path.has(v)) {\n", "    if (false) {\n")],
        "test": "tests/backends/script-value-cycle.test.ts",
    },
    {
        "name": "M818 参数侧用「全局 visited」代替路径栈（合法的共享引用被当成环拒掉）",
        # ★ 落在参数侧而不是 Lua 侧：wasmoon 转 Lua 表时**深拷贝**，
        #   `{a=t, b=t}` 到那边已经是两个对象 ⇒ 打在 Lua 侧是等价变异，永远不红。
        "file": "src/platform/script/runtime.ts",
        "pairs": [("        path.delete(src);\n", "")],
        "test": "tests/backends/script-value-cycle.test.ts",
    },
    {
        "name": "M819 参数侧不判环（自引用对象进 Lua 之前没人挡）",
        "file": "src/platform/script/runtime.ts",
        "pairs": [("      if (path.has(src)) return err(cycleError(where));\n", "      if (false) return err(cycleError(where));\n")],
        "test": "tests/backends/script-value-cycle.test.ts",
    },
    {
        "name": "M820 深度上限的文案不说「不是环」（两种失败又混成一句）",
        # 文案也是判据的一部分：作者读到「八成是成环」会去拆数据，
        # 读到「不是环，是太深」才会去摊平。
        "file": "src/backends/script-lua/runtime.ts",
        "pairs": [("嵌套超过 32 层（**不是环** —— 真的是数据太深；跨边界前请先摊平）", "嵌套超过 32 层（八成是成环的表）")],
        "test": "tests/backends/script-value-cycle.test.ts",
    },
    # ---- 批131：「做完了却没关单」
    {
        "name": "M821 已关单的行照样报（`alreadyClosed` 恒 false：划掉 / ✅ 都不再免责）",
        # ★ 靶子打在 `alreadyClosed` 上，不是打在调用点：两处规则共用它，
        #   打在调用点的话 `replace(…, 1)` 只改得到第一个 —— 第一条变异跑完才发现
        #   新规则那条分支一条变异都没覆盖（靶串逐字相同的陷阱，批131 实测）。
        "file": "tools/gap-check.mjs",
        "pairs": [(
            '  return head.includes("✅") || head.includes("~~");\n',
            "  return false;\n",
        )],
        "test": "tests/tools/gap-check.test.ts",
    },
    {
        "name": "M822 行里写着「仍缺 X」也报（判据逼人把「还差什么」删掉才好交差）",
        # ★ 这一条是**反向条件**：不写「仍缺」就没人报，写了反而被判红 —— 那种判据
        #   会训练人删证据。C3「开关已交付、只是决定不读朝向」就是这一档。
        "file": "tools/gap-check.mjs",
        "pairs": [("    if (LIVE_GAP.test(body)) continue;\n", "    if (false) continue;\n")],
        "test": "tests/tools/gap-check.test.ts",
    },
    {
        "name": "M823 一行里没自称做完也报（缺口表全变红，等于没有判据）",
        "file": "tools/gap-check.mjs",
        "pairs": [("    if (!DONE_CLAIM.test(body)) continue;\n", "    if (false) continue;\n")],
        "test": "tests/tools/gap-check.test.ts",
    },
    {
        "name": "M824 不剥 ~~…~~（划掉的历史留痕被当成现状，重新打开的行被误报）",
        "file": "tools/gap-check.mjs",
        "pairs": [('  return out.join("");\n', "  return text;\n")],
        "test": "tests/tools/gap-check.test.ts",
    },
    # ---- 批132：wx 存档的原子写
    # ---- 批133：脚本模块的两种环境
    {
        "name": "M831 sharedModuleEnv 选项被忽略（共享模式退化成隔离 —— 真实 DST 脚本又全炸在 Class 上）",
        "file": "src/backends/script-lua/runtime.ts",
        "pairs": [("      if (this.opts.sharedModuleEnv === true) {\n", "      if (false) {\n")],
        "test": "tests/backends/script-shared-env.test.ts",
    },
    {
        "name": "M832 默认改成共享（热更不变式 ③ 被静默关掉：新版本还看得到上一版的全局）",
        # ★ 这条与 M831 是**两个方向**：那条验"打开时真的打开了"，这条验"没打开时真的是关着的"。
        #   只验一个方向的话，一个"永远共享"的实现全绿，而隔离模式的承诺已经没了。
        "file": "src/backends/script-lua/runtime.ts",
        "pairs": [("__engine_shared_env = false\n", "__engine_shared_env = true\n")],
        "test": "tests/backends/script-shared-env.test.ts",
    },
    {
        "name": "M833 loadModule 不登记 package.loaded（require 永远说「已加载的模块不存在」）",
        # ★ 第一版这里打的是「共享模式也去建命名空间表」，跑出来是**等价变异**：
        #   `collect` 内部还有一句 `if _G[k] ~= v then ns[k] = v end`，
        #   当 t 就是 _G 时它一个键都收不进去 —— 删掉外层那个判断，行为一模一样。
        #   换成这条：package.loaded 是 5.1 里 require 的第一站（也是唯一一站，
        #   因为垫片的 require 不读文件系统），漏登记 ⇒ 先加载 class 再 require("class") 也找不到。
        "file": "src/backends/script-lua/runtime.ts",
        "pairs": [(
            "  package.loaded[name] = result == nil and true or result\n",
            "  package.loaded[name] = nil\n",
        )],
        "test": "tests/backends/script-shared-env.test.ts",
    },
    {
        "name": "M826 wx 存档直接写目标（回到批132 之前：崩在写入中途就是半份存档）",
        # ★ 这条变异必须**整段绕过** atomicWrite，而不是只把 write(tmp) 改成 write(target)：
        #   那样 rename 会去挪一个不存在的临时文件、报的是另一个错，
        #   判据红在"写失败"上而不是"没走临时文件"上 —— 红的位置错了，等于没验到。
        "file": "src/host/wx/fs.ts",
        "pairs": [(
            "    return this.atomicWrite(a.value, path, (tmp) => {\n      this.mgr.writeFileSync(tmp, text, \"utf8\");\n    });\n",
            "    this.mgr.writeFileSync(a.value, text, \"utf8\");\n    return ok(undefined);\n",
        )],
        "test": "tests/host/wx.test.ts",
    },
    {
        "name": "M827 写失败不删临时文件（存档目录里从此多个 `.tmp-N`，list 会当成普通文件）",
        "file": "src/host/wx/fs.ts",
        "pairs": [(
            "    } catch (e) {\n      this.dropTmp(tmp);\n      return err(classify(e, logical));\n    }\n",
            "    } catch (e) {\n      return err(classify(e, logical));\n    }\n",
        )],
        "test": "tests/host/wx.test.ts",
    },
    {
        "name": "M828 老基础库没有 renameSync 也照写（静默退化成非原子写，修复形同不存在）",
        "file": "src/host/wx/fs.ts",
        "pairs": [("    if (typeof rename !== \"function\") {\n", "    if (false) {\n")],
        "test": "tests/host/wx.test.ts",
    },
    {
        "name": "M829 rename 不会覆盖目标时不补救（第二次存档永远失败 —— 读档一直是旧的）",
        "file": "src/host/wx/fs.ts",
        "pairs": [("      if (isAlreadyExists(e)) {\n", "      if (false) {\n")],
        "test": "tests/host/wx.test.ts",
    },
    {
        "name": "M830 临时文件名不带序号（同一个目标的两次写互相踩）",
        "file": "src/host/wx/fs.ts",
        "pairs": [(
            "    const tmp = `${target}.tmp-${String(++this.tmpSeq)}`;\n",
            "    const tmp = `${target}.tmp-0`;\n",
        )],
        "test": "tests/host/wx.test.ts",
    },
    {
        "name": "M825 docs-check 打印里去掉「没关单」（接线判据只剩半条：仍缺在跑、新规则没在跑）",
        # ★ 纯函数判据证不了「有人在调用它」。去掉这一段输出，
        #   tests/tools/gap-check.test.ts 的接线那条立刻红。
        "file": "tools/docs-check.mjs",
        "pairs": [(
            "，做完却没关单 ${forgotten.length} 条`,\n",
            "`,\n",
        )],
        "test": "tests/tools/gap-check.test.ts",
    },
]


def run(m: dict) -> tuple[int, str]:
    """
    跑一条变异的"判据"，返回 (失败条数, 明细)。

    ★ 两种判据形态：
      · 默认 —— `node --test <file>`，输赢看 `not ok` 行数；
      · 带 `cmd` —— 任意命令，输赢看**退出码**。
    为什么必须支持第二种：`tools/docs-check.mjs` 不是 node:test 文件，它的失败是
    stderr 上一句"✗ 文档数字漂移 N 处" + 退出码 1/2。若按 `not ok` 数数，
    它永远返回 0 失败 ⇒ 变异恒"没被抓住"，或者干脆绕过不测。
    「判据形态不是 node:test」不构成不对它做变异校验的理由。
    """
    cmd = m.get("cmd")
    if cmd:
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=600)
        out = (p.stdout or "") + (p.stderr or "")
        tail = "\n".join([ln for ln in out.splitlines() if ln.strip()][-4:])
        # ★★ `env_exit`：这个命令把退出码 2 用来表示**环境缺失**（无浏览器），
        #   此时"变异被抓住"没有证据 —— 那台机器上判据根本没跑起来。
        #   不加这条的话，无浏览器的 CI 上 M229/M230/M78/M292 会一致假绿。
        #
        #   ★ 为什么必须**逐条声明**、不能对所有 cmd 型判据一律这么判：
        #     退出码 2 在这两个位置上含义正好相反 ——
        #     `browser-selftest` 用 2 表示"没有浏览器"（前提缺失），
        #     而 `docs-check` 用 2 表示"实测值取不到"，**那正是 M74 要抓住的东西**
        #     （把 backends 的实测值摘掉 ⇒ 对账读不到数 ⇒ 退出码 2）。
        #     第一次修这条时按"一律 2 = 环境"处理，当场把 M74 判成环境问题。
        #     同一个数字，两种语义 —— 只有变异表知道自己在调哪个脚本。
        if p.returncode == 2 and m.get("env_exit") == 2:
            print(f"✗ 判据命令以退出码 2 结束（该脚本用 2 表示环境缺失，不是判据结论）：{' '.join(cmd)}")
            print(f"  ← {m['name']}")
            print("  把它记成「变异被抓住」是假绿：这台机器上那条判据根本没跑起来。")
            for ln in tail.splitlines():
                print(f"    {ln}")
            raise SystemExit(2)
        if p.returncode == 0:
            return 0, ""
        return 1, tail
    # ★ `--test-reporter=tap` 必须显式写死。
    #   2026-10-25 事故：默认 reporter 在 Node 22 下是 TAP（`not ok 3 - ...`），
    #   在 Node 24 下变成 spec（`✖ 名字 (1.2ms)`）。本工具数的是 `not ok` 行，
    #   于是**在 Node 24 下每条变异都返回"失败 0 条"** —— 八条刚写好的 UI 变异
    #   齐刷刷报"判据是假绿"，而实际上把代码改坏之后测试是全红的。
    #   这类故障最坏的地方在于它**看起来像结论**：报的是"你的判据不行"，
    #   而不是"我的解析器不行"，照着它去补判据只会越补越远。
    p = subprocess.run(
        ["node", "--experimental-transform-types", "--test-reporter=tap", "--test", m["test"]],
        cwd=ROOT, capture_output=True, text=True, timeout=600,
    )
    out = p.stdout + p.stderr
    fails = [ln for ln in out.splitlines() if ln.startswith("not ok")]
    # 认不出 TAP 汇总行 ⇒ 不是"判据不行"，是**测试根本没按 TAP 输出**（解释器/参数问题）。
    # 这两种情况必须分开报：混在一起就会把环境问题写成判据结论（上面那条事故的同款）。
    if not fails and not re.search(r"^# (tests|fail) \d+", out, re.M):
        print(f"✗ 判据输出里没有 TAP 汇总行（`# tests N`）—— 测试没按预期跑起来，不是判据的问题。")
        print(f"  命令：node --experimental-transform-types --test-reporter=tap --test {m['test']}")
        print(f"  退出码 {p.returncode}；输出末尾：")
        for ln in [x for x in out.splitlines() if x.strip()][-6:]:
            print(f"    {ln}")
        raise SystemExit(2)
    return len(fails), "\n".join(fails[:6])


results = []
# 因**平台域**而不适用的条目（判据自身带平台条件，不是"没牙齿"）。单独记账，别混进失败。
skipped_by_platform: list[str] = []

# ★ 运行期间测试文件被改动 → 本次结论作废。
#   这条也是踩出来的：一边跑变异、一边往测试文件里加用例，
#   结果 M31 报"还原后失败 2 条"——看上去像还原不干净，其实是那 2 条是新加的用例
#   自己还没写完。**"还原不干净"是个很严重的指控，不能由并发编辑制造出来。**
def _test_fingerprint() -> dict:
    h = hashlib.sha256()
    files: dict = {}
    # 带 cmd 的条目没有 `test` 键（或它指的就是被变异的文件本身），照样要盯住
    for tf in sorted({m.get("test") for m in MUTANTS if m.get("test")}):
        p = ROOT / tf
        digest = p.read_bytes() if p.exists() else b"<missing>"
        files[tf] = hashlib.sha256(digest).hexdigest()
        h.update(tf.encode())
        h.update(digest)
    # ★ files 是 per-file 快照：守卫报"被改动过"时必须能说出**是哪个文件**。
    #   2026-10-24：只有一句集体结论，害得全量跑连挂、单跑同一条却过，全靠猜。
    return {"sig": h.hexdigest(), "files": files}


_FP0 = _test_fingerprint()

# ★ 正在被变异的文件 → 原始内容。SIGTERM/SIGINT 时靠它把仓库还原。
#   这条不是"保险"，是踩出来的：本工具曾经在前台跑到超时被 SIGTERM 掉，
#   恰好停在某条变异已写入、还没走到 finally 的瞬间，于是 scan-lossless.ts 里
#   留下了 `if (s > 32)`，而**下一次运行从这个脏状态开始**，
#   表现为"某条变异点没找到"+"上一条还原后仍失败 1 条"，很容易被误读成判据过期。
#   Python 的 kill 不会执行 finally，只有信号处理器能兜住。
_ACTIVE: dict = {}


def _restore_all(signum=None, _frame=None) -> None:
    restored = 0
    for path, original in list(_ACTIVE.values()):
        try:
            # 与变异循环同口径：字节级写回，行尾不被转换
            if isinstance(original, bytes):
                path.write_bytes(original)
            else:
                path.write_text(original, encoding="utf-8")
            restored += 1
        except OSError:
            pass
    _ACTIVE.clear()
    # ★ 还原完了就把日志也扫掉，否则下一次启动会再恢复一遍并误报"上次被强杀"。
    #   `globals()` 判断是因为处理器注册在 import 之前：那时 `_ACTIVE` 必然为空
    #   （没有任何文件被改），但直接引用名字会抛 NameError、把一次干净的退出变成异常。
    if "mutation_journal" in globals():
        mutation_journal.commit(ROOT)
    if signum is not None:
        print(f"\n✗ 收到信号 {signum}：已还原 {restored} 个被变异的文件后退出", flush=True)
        sys.exit(130)


for _name in ("SIGINT", "SIGTERM", "SIGHUP"):  # Windows 没有 SIGHUP
    _sig = getattr(signal, _name, None)
    if _sig is None:
        continue
    try:
        signal.signal(_sig, _restore_all)
    except (ValueError, OSError):  # 平台不支持该信号
        pass

# ★ `--only M48,M50`：只跑指定的几条。
#   全量一轮要 6~7 分钟，而"改了某个模块，想看某条变异还抓不抓得住"是高频动作；
#   没有这个开关就只能整轮跑，于是每次都要等 —— 等待会诱导人"这次先不验了"。
#   **结论口径不变**：报告里写"50/50"必须来自不带 --only 的整轮。
#   编号取名字的第一段（"M50 IDCT 的..." → "M50"），与报告里的写法一致。
def _mid(name: str) -> str:
    return name.split(" ", 1)[0]


_only: list[str] = []
for _i, _a in enumerate(sys.argv):
    if _a == "--only" and _i + 1 < len(sys.argv):
        _only = [x.strip() for x in sys.argv[_i + 1].split(",") if x.strip()]
if _only:
    _all_ids = [_mid(m["name"]) for m in MUTANTS]
    _unknown = [x for x in _only if x not in _all_ids]
    if _unknown:
        sys.exit(f"--only 里有不存在的编号：{_unknown}（现有 {len(_all_ids)} 条：{_all_ids}）")
    MUTANTS = [m for m in MUTANTS if _mid(m["name"]) in _only]
    # ★ 指纹的基准集合必须跟着过滤后的 MUTANTS 走。
    #   否则 _FP0（全量测试文件）与运行期 _test_fingerprint()（只剩被选中那几条的测试文件）
    #   必然不等 —— 加完 --only 第一次跑就是这样，守卫立刻报了"测试文件被改动"，
    #   把一次正常的单条验证误判成作废。**守卫报错的这条路径也是被守卫自己抓出来的。**
    _FP0 = _test_fingerprint()
    print(f"[--only] 只跑 {len(MUTANTS)} 条：{_only}", flush=True)

# ★ 运行期间**整个 src/ 处于"被故意改坏"的状态**，所以另一条线（CI / npm test / 编辑器里
#   按了保存触发 watch）此时跑出来的红不是真的。光靠文档提醒不够 —— 人不会记得，
#   而"红得没依据"会训练人忽略红字（这正是本项目反复吃过的亏）。
#   做法：起跑写一个锁文件，CI 与文档对账看到锁就拒绝启动；结束时无论怎么退出都删掉。
LOCK = ROOT / ".cache" / "mutation.lock"


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    except Exception:
        return True
    return True


def _other_alive() -> int:
    """另一个**还活着**的变异轮的 pid（没有则 0）。只探测，不动锁。"""
    if not LOCK.exists():
        return 0
    try:
        held = json.loads(LOCK.read_text(encoding="utf-8"))
    except Exception:
        return 0
    pid = int(held.get("pid", 0) or 0)
    return pid if pid != os.getpid() and _pid_alive(pid) else 0


def _take_lock() -> None:
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    if LOCK.exists():
        try:
            held = json.loads(LOCK.read_text(encoding="utf-8"))
        except Exception:
            held = {}
        pid = int(held.get("pid", 0) or 0)
        if pid != os.getpid() and _pid_alive(pid):
            sys.exit(
                f"已经有一轮变异在跑（pid {pid}，开始于 {held.get('at')}）——"
                "它正在改 src/ 里的源码，两轮并行会让两边的结论都不可信"
            )
        # 陈锁（上一个进程被杀）：直接接管，但要说出来，别静默
        print(f"[lock] 接管陈锁（pid {pid} 已不在）", flush=True)
    LOCK.write_text(
        json.dumps({"pid": os.getpid(), "at": datetime.now().isoformat(timespec="seconds")}),
        encoding="utf-8",
    )


def _drop_lock() -> None:
    try:
        if LOCK.exists():
            LOCK.unlink()
    except OSError:
        pass


_drop_lock()

# ★★ 判据文件必须真的存在。
#
#   不存在时 `node --test` 只打印一行 `Could not find '...'`（退出码 1，但没有任何
#   `not ok` 行），于是本工具读到"失败 0 条" —— 报成**判据假绿**。
#   方向完全反了：代码一点没错，是这一条变异把 test 路径写错了。
#   2026-10-24 实测：M203 写成 `tests/extensions/nav/nav-grid.test.ts`（多了个 nav/），
#   工具一本正经地报"这条变异抓不住"，而人工单独跑判据立刻红。
#   **"配置写错"和"判据没有分辨力"必须分开报**，否则人会去改判据。
_missing_tests = [
    (m["name"], m["test"])
    for m in MUTANTS
    if m.get("test") and not (ROOT / m["test"]).exists()
]
if _missing_tests:
    for _name, _tf in _missing_tests:
        print(f"✗ 判据文件不存在：{_tf}  ← {_name}")
    sys.exit("变异表里的 test 路径写错了（是配置错，不是判据失效）")


# ---------------------------------------------------------------- 工作区守护（批89）
#
# ★★ 为什么需要它：上面那两套「还原后校验」各自只看**自己这一条**变异的文件 ——
#   cmd 型验"这个源文件的字节 + 三个产物哈希"，node:test 型"重跑这一条判据"。
#   它们看不见 **别的文件被留在了变异态**。
#
#   2026-10-26 批89 实测：全量跑完 407 条，工具通篇报「全部变异均被抓住且还原干净」，
#   但 `src/extensions/asset-import/decode/jpeg/lossless-pred.ts` 被留成了变异体
#   （`1 << (precision - pt - 1)` → `1 << (precision - 1)`）。
#   后果不是"红一下"：`ci.mjs` 的判据步排在变异步**之前**，所以当次全绿，
#   红要等到**下一次**有人跑判据才爆 —— 而那时红的是两条 JPEG 判据，
#   跟眼前正在改的东西毫无关系。**我照着那条红去查了一个不存在的 bug。**
#   更糟的路径是它被 `git add -A` 一并提交：diff 长成"把真缺陷改回去"，
#   而提交信息写着别的事。
#
# ★★ 实现在 `tools/worktree_guard.py`，**不能住在变异表所在的文件里**：
#   变异靶子是写在变异表里的字符串字面量，而 `replace(old, new, 1)` 命中的是
#   文件中第一次出现 —— 实现与靶子同处一文件时，第一次出现就是靶子自己。
#   M408 第一版就是这么假绿了一轮：它把自己的靶子改掉了、实现纹丝不动，
#   于是"没被抓住"，而自检照样通过（因为逻辑真的没变）。
#   抽出去之后，靶子在这边、实现在那边，两边不可能撞上。
sys.path.insert(0, str(ROOT / "tools"))
import worktree_guard  # noqa: E402  （路径要先插进 sys.path）

# ★★ 落盘日志：**进程被强杀之后**还能把源码还原。
#
#   光靠内存里的 `_ACTIVE` + 信号处理器不够 —— 处理器只在能收到信号时执行。
#   Windows 上结束子进程走 `TerminateProcess`，Unix 上 `kill -9`，两者都
#   **不可捕获**，处理器一次都不会跑。这就是为什么 2026-10-26（批89）和
#   2026-10-27（我 runpy 误触发被工具超时杀掉）两次都把 `lossless-pred.ts`
#   留在了变异态，而第一次还通篇报"还原干净"。
#   与 `worktree_guard` 同一个理由抽成独立模块：靶子在这里、实现在那里。
import mutation_journal  # noqa: E402

# ★ 变异轮**开始前**先把文档对账的缓存刷成新鲜状态（必须在拿锁之前）。
#
#   为什么：M74–M76 的判据是 `node tools/docs-check.mjs --quick`，而 quick 模式一旦发现
#   「tests/ 有改动、缓存过期」，就会去跑整套测试取真实数字；但测试入口在变异期间
#   **拒绝启动**（此时 src/ 是被故意改坏的，跑出来的数字不可信）。
#   三个条件叠起来的结果是：这三条变异「变异后红、还原后也红」，
#   被误报成**「还原不干净」** —— 那是个很严重的指控，不能由工具自己的死锁制造出来。
#
#   顺带把「基线必须绿」变成硬前置：基线红的时候，「变异被抓住」根本没有证据价值
#   （M74 第一次跑就是这样：变异数 73→76 没同步，文档对账本来就红）。
#
# ★★ 恢复必须排在这次对账**之前**（2026-10-27 实测）：
#   第一次接线时我把恢复放在 warm 之后，结果伪造一份"上一轮被强杀"的残留再跑，
#   工具报的是「基线不绿：有 4 条判据失败」—— 那 4 条正是被残留改坏的判据。
#   于是**真正该说的那句话**（"上一次没正常结束，我已把文件写回去"）一个字都没出现，
#   而看到的人会去查那 4 条判据。恢复与被诊断，恢复必须在前。
#   锁仍然只能在这之后拿：`docs-check` 看到锁会拒绝启动。
_other = _other_alive()
if _other:
    sys.exit(
        f"已经有一轮变异在跑（pid {_other}）—— 它正在改 src/ 里的源码，"
        "两轮并行会让两边的结论都不可信；也不能先替它还原（那会改掉它正在测的文件）"
    )
_restored, _journal_problems = mutation_journal.recover(ROOT)
if _restored:
    print(
        f"[journal] 上一次运行没有正常结束：已把 {len(_restored)} 个文件写回原文"
        f"（{', '.join(_restored)}）—— 那是被强杀的那一轮留下的，不是这次改的",
        flush=True,
    )
if _journal_problems:
    print("✗ 变异日志里有恢复不了的东西 —— 此时工作区不可信，先人工核对：")
    for _p in _journal_problems:
        print(f"  · {_p}")
    sys.exit(2)

_warm = subprocess.run(
    ["node", "tools/docs-check.mjs"], cwd=ROOT, capture_output=True, text=True, timeout=600
)
if _warm.returncode != 0:
    print("✗ 基线不绿：文档对账本身没通过 —— 此时「变异被抓住」没有证据价值。")
    print("  刚改过判据数/变异数的话，先跑：node tools/docs-check.mjs --fix")
    print((_warm.stdout or "") + (_warm.stderr or ""))
    sys.exit(2)
print("[warm] 文档对账缓存已刷新（变异期间不再重算判据数）", flush=True)

# ★★ 取锁必须排在**产物基线之前**：基线构建会写三个产物，两轮并行时后一轮
#   会把前一轮的产物当参照。原先取锁在工作区基线之后、产物基线之后 ——
#   那时"两轮并行"的口子已经开过了（虽然很快会被拒，但基线已经错）。
#   也不能更早：`docs-check` 看到锁会拒绝启动，而上面那次 warm 正是跑它。
_take_lock()

# ★★ 产物基线：**开跑前统一建一次**，之后每条 cmd 型变异都拿这一个值当对照。
#
#   第一版用的是"这一条变异开始之前那一刻盘上的包"当基线。那种基线会把
#   **上一条变异留下的脏包**当成本条的正确参照 —— 实测就是 M229/M230：
#   它们的 cmd 带 `--build` 却漏了 `rebuild`，跑完把 `web/editor.js` 留在变异态，
#   接着 M292 报「产物没回到干净基线」，看起来像 M292 的毛病，真凶在前一条。
#   开跑前建一次，基线就恒等于"当前源码的正确产物"：谁把包弄脏，都会在
#   **它自己那一轮**暴露，不会嫁祸给下一条。
_ARTIFACTS_CLEAN: str | None = None
if any(m.get("cmd") for m in MUTANTS):
    if _run_build() != 0:
        print("✗ 基线构建失败 —— 产物不能当参照，还原验证就退化成猜。")
        sys.exit(2)
    _ARTIFACTS_CLEAN = _artifacts_hash()
    print(
        f"[warm] 产物基线 {_ARTIFACTS_CLEAN[:12]}（{len(_ARTIFACTS)} 个文件，开跑前建一次）",
        flush=True,
    )

# ★ 工作区基线：取在产物基线**之后**（基线构建会重写三个产物，落在基线之内才不误报）。
HASH_BEFORE = worktree_guard.tracked_hashes(ROOT)
print(
    f"[guard] 工作区基线 {hashlib.sha256(''.join(sorted(HASH_BEFORE)).encode()).hexdigest()[:12]}"
    f"（{len(HASH_BEFORE)} 个 tracked 文件）",
    flush=True,
)

try:
    for m in MUTANTS:
        f = ROOT / m["file"]
        # ★★ 判据可以有**明确的平台域**，变异校验必须认识它，否则会报假「假绿」。
        #
        #   2026-10-25 第十轮实测：`✗ 未通过 1 条：M277(假绿)`。
        #   M277 的判据（root 大小写与盘上不一致）是 **Windows-only** ——
        #   非 Windows 上大写变体指向的是另一个目录，放行会假绿，所以判据主动 skip。
        #   于是变异后 0 失败 ⇒ 被归进「判据假绿」。
        #   但**判据没有分辨力**和**环境不具备**是两件事，混在一起会让人去改一条
        #   本来正确的判据（和 `_missing_tests` 那次"配置错被报成判据失效"同一类）。
        #
        #   所以：条目声明 `platforms` 后，域外**根本不跑**，并单独列出。
        #   ★ 这不是逃生门 —— 只有判据自身真的带平台条件时才配声明它，
        #     否则就是拿平台当借口不测。
        want = m.get("platforms")
        if want is not None and sys.platform not in want:
            skipped_by_platform.append(m["name"])
            continue
        # ★ 行尾三口径（2026-10-24，一次改对）：
        #   ① **匹配**在归一化 LF 的文本上做 —— 靶子全部按 LF 写，而仓库里
        #      CRLF / LF 文件都有（`git config core.autocrlf` 与编辑器各写各的）；
        #   ② **写回**保持原行尾 —— Python 的 universal newlines 会把 LF 文件
        #      写成 CRLF（内容被改 ⇒ 指纹误报"测试文件被改动过" + git 留脏）；
        #   ③ **还原**永远是原始字节。
        #   第一版只做了 ②（read_bytes/decode），结果 CRLF 文件全部匹配不上，
        #   181 条变异一半报"变异点没找到"—— 修一个坑造了一个更大的坑。
        original_bytes = f.read_bytes()
        crlf = b"\r\n" in original_bytes
        original = original_bytes.decode("utf-8")
        if crlf:
            original = original.replace("\r\n", "\n")
        mutated = original
        ok_apply = True
        for old, new in m["pairs"]:
            if old not in mutated:
                ok_apply = False
                break
            mutated = mutated.replace(old, new, 1)
        if not ok_apply:
            results.append((m["name"], "变异点没找到（判据可能已过期）", 0, [], ""))
            continue

        _ACTIVE[str(f)] = (f, original_bytes)
        # ★★ 先落盘日志，**再**改文件。顺序反过来的话，崩在这两步之间就是
        #   "文件已经坏了、日志却没有" —— 正是这套东西唯一要防的那种状态。
        mutation_journal.begin(ROOT, f, original_bytes)
        out_text = mutated.replace("\n", "\r\n") if crlf else mutated
        f.write_bytes(out_text.encode("utf-8"))
        try:
            n_fail, detail = run(m)
        finally:
            f.write_bytes(original_bytes)
            _ACTIVE.pop(str(f), None)
            # ★ 原文已经写回去了 ⇒ 告诉日志"这件事完了"。
            #   少了这一句，下一次启动会把**已经还原**的文件再写一遍，
            #   并误报一次"上一次被强杀" —— 假警报会训练人忽略真警报。
            mutation_journal.commit(ROOT)
            # ★★ **cmd 型一律重建**（不再靠条目声明 `rebuild`）。
            #   教训：靠人手声明就有漏的时候，而且漏了会**嫁祸给下一条**
            #   （M229/M230 漏了 ⇒ M292 顶锅；M189 干脆不在声明体系里，
            #   因为它的构建藏在 `cross-host-save.mjs` 内部）。
            #   按结果验证：还原后无条件重建一次，再拿产物哈希和干净基线比。
            #   代价约 2 秒/条，换来"任何人都无法忘记"。
            rebuild_rc = None
            if m.get("cmd"):
                rebuild_rc = _run_build()

        # 还原后必须重新变绿，否则说明的还原不干净
        if _test_fingerprint() != _FP0:
            _restore_all()
            _fp1 = _test_fingerprint()
            print(
                "\n✗ 测试文件在运行期间被改动过 —— 本次「还原后失败」的条数不可信，结论作废。"
                "\n  跑变异的期间不要编辑测试文件（这次就是这么误判成「还原不干净」的）。",
                flush=True,
            )
            for tf, d in _fp1["files"].items():
                if d != _FP0["files"].get(tf):
                    print(f"  · 变了：{tf}", flush=True)
            sys.exit(2)
        if m.get("cmd"):
            # ★★ 确定性还原验证（口径说明见文件头）：**不重跑浏览器判据**。
            #   还原是字节级写回，"仓库脏不脏"是能直接看的事实；而浏览器判据跑一轮
            #   20+ 秒且对机器速度敏感（软件渲染下页面 10 秒总闸贴边），拿它的抖动
            #   去指控"还原不干净"已经误报过三次（M31 / M292 / M314+M315）。
            #   判据的牙齿在**变异后那一轮**（必须红），那一轮照跑、照算失败条数。
            problems = []
            if f.read_bytes() != original_bytes:
                problems.append("源文件字节与变异前不一致")
            if rebuild_rc is not None and rebuild_rc != 0:
                problems.append(f"还原后重建退出码 {rebuild_rc}")
            if rebuild_rc == 0 and _ARTIFACTS_CLEAN is not None:
                artifacts_now = _artifacts_hash()
                if artifacts_now != _ARTIFACTS_CLEAN:
                    # ★ 两个短哈希都要打：只报"不一致"的话，下一个人没法判断
                    #   是"包停在被变异态"还是"包本来就没跟上源码"。
                    problems.append(
                        "构建产物没回到干净基线（包可能停在变异态）"
                        f" [{_ARTIFACTS_CLEAN[:12]} → {artifacts_now[:12]}]"
                    )
            n_fail_after = len(problems)
            detail_after = "；".join(problems)
        else:
            n_fail_after, detail_after = run(m)
            if n_fail_after and detail_after:
                # 还原后的失败明细以前被整段丢掉（`n_fail_after, _ = run(m)`），
                # 只剩一个数字 —— 而"还原不干净"是需要证据的指控。
                print(f"   还原后仍失败：{detail_after.splitlines()[0]}", flush=True)
        results.append((m["name"], detail, n_fail, [n_fail_after], detail_after))
finally:
    _restore_all()
    _drop_lock()

# ★★ 工作区守护的**收尾**：残留可能来自任何一条变异（不一定是最后一条，也不一定是
#   刚刚报出问题的那条），所以只能在全部结束后整体比一次。
HASH_AFTER = worktree_guard.tracked_hashes(ROOT)
LEFTOVER = worktree_guard.hash_diff(HASH_BEFORE, HASH_AFTER)
if LEFTOVER:
    print(
        "\n✗ 变异跑完工作区不干净 —— 有文件被留在了变异态（或反过来被改了）：",
        flush=True,
    )
    for _line in LEFTOVER:
        print(f"  · {_line}", flush=True)
    print(
        "  这些改动**不是**本次任务的产物；`git add -A` 会把它们一起提交。"
        "逐个人工看过后 `git checkout -- <path>` 丢掉，不要直接提交。",
        flush=True,
    )

print("=" * 70)
all_ok = True
for name, detail, n_fail, after, detail_after in results:
    # ★ 三种失败必须分开说，混为一谈会指错方向：
    #   ① 变异点没找到 ⇒ 靶子漂移（重构挪走了代码），判据**一条都没跑**，
    #      说它"假绿"是误判 —— 2026-10-24 M6/M169 就这么被误打印过；
    #   ② 变异后 0 失败 ⇒ 真的假绿（判据对这类改动没有分辨力）；
    #   ③ 还原后仍失败 ⇒ 还原不干净（更严重，可能留下脏仓库）。
    if detail.startswith("变异点没找到"):
        verdict = "× 变异点没找到（靶子漂移：重构挪走了代码，判据没跑过）"
    elif n_fail > 0:
        verdict = "√ 变异被抓住"
    else:
        verdict = "× 变异没被抓住（判据是假绿）"
    if n_fail == 0 or (after and after[0] != 0):
        all_ok = False
    print(f"{name}: {verdict}  变异后失败 {n_fail} 条；还原后校验失败 {after[0] if after else '?'} 项")
    if detail:
        print("   " + detail.replace("\n", "\n   "))
    if after and after[0] != 0 and detail_after:
        print("   还原后：" + detail_after)
print("=" * 70)
# ★ 工作区残留也进 all_ok：只报"变异被抓住"而留下脏文件，结论同样是不可信的。
if LEFTOVER:
    all_ok = False
if all_ok:
    print("全部变异均被抓住且还原干净")
    if skipped_by_platform:
        print(
            f"· {len(skipped_by_platform)} 条因平台不适用而跳过（判据自身带平台域，不是假绿）："
            + "、".join(n.split(" ")[0] for n in skipped_by_platform)
        )
else:
    # ★ 失败清单必须打在**最后几行**：CI 只回显尾部 12 行，
    #   而"有变异未被抓住"这句话本身不含任何可行动信息 ——
    #   第一次跑就吃了这个亏：只看到结论，看不到是哪一条（M65 的变异点在重构后消失了）。
    #   ★ 三类失败分开列（2026-10-24：M6/M169 是靶子漂移，却被归进"未被抓住"，
    #     害我去查假绿，而真相是重构挪走了代码 —— 错误分类比没有分类更贵）。
    drift = [name for name, d, _n, _a, _da in results if d.startswith("变异点没找到")]
    green = [name for name, d, n, _a, _da in results if not d.startswith("变异点没找到") and n == 0]
    dirty = [name for name, _d, _n, a, _da in results if a and a[0] != 0]
    # ★★ 紧凑摘要必须**以 ✗ 开头**，而且要打在最前面。
    #
    #   2026-10-25 第九轮实测：860 秒跑完 278 条，`tools/ci.mjs` 的 annotation
    #   提取只认 `not ok|✗|×|FAIL` 开头的行 —— 而下面那些 `· [判据假绿] M12`
    #   一个都不匹配。结果 annotation 里塞满了**预期内**的 `not ok`（那正是
    #   "变异被抓住"的证据），真正该看的"哪几条没抓住"一个字都没进去。
    #   **信息通道要在排障之前建好**，否则每一轮都要重新猜一次。
    _items = (
        [(n, "漂移") for n in drift]
        + [(n, "假绿") for n in green]
        + [(n, "脏") for n in dirty]
        # ★ 第四类：**工作区残留**。它不是某一条变异的事（可能根本没有哪条报错），
        #   但后果比"某条没抓住"更重 —— 脏文件会被下一次提交带走。
        + [(p, "残留") for p in LEFTOVER]
    )
    print(
        f"✗ 未通过 {len(_items)} 条："
        + "、".join(f"{n.split(' ')[0]}({lab})" for n, lab in _items)
    )
    print(
        f"有变异未通过 —— 靶子漂移 {len(drift)} 条 / 判据假绿 {len(green)} 条 /"
        f" 还原不干净 {len(dirty)} 条 / 工作区残留 {len(LEFTOVER)} 处："
    )
    for label, lst in (("靶子漂移", drift), ("判据假绿", green), ("还原不干净", dirty)):
        for name in lst:
            print(f"  · [{label}] {name}")
    for _p in LEFTOVER:
        print(f"  · [工作区残留] {_p}")
    print("（'靶子漂移' = 代码重构后变异点不存在了，要重新指认，不是放宽标准；'假绿' = 判据对这类改动没有分辨力）")
    if skipped_by_platform:
        print(
            f"· 另有 {len(skipped_by_platform)} 条因平台不适用而跳过（判据自身带平台域，不是假绿）："
            + "、".join(n.split(" ")[0] for n in skipped_by_platform)
        )
sys.exit(0 if all_ok else 1)
