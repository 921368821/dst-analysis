# 08 · 引擎内核

分层、接口优先的 **2.5D 游戏引擎内核**，目标是《饥荒》风格
（斜俯视 + 组件化世界 + 确定性模拟 + Lua 脚本内容层），架构水准对标 Unity / Cocos。

> **完整设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**（分层、职责、接口、通信、扩展、路线）。
> **想让一个世界跑起来并看到画面**：见 [docs/WORLD-QUICKSTART.md](docs/WORLD-QUICKSTART.md)（六步 + 常见现象对照表）。
> 关键决策见 [docs/adr/](docs/adr/)（7 个 ADR）。

## 四条不变量（由测试守护，不靠纪律）

| 不变量 | 守护 |
|---|---|
| 依赖只能单向向下；后端只认接口 | `tests/arch/layers.test.ts`（7 条规则） |
| 内核不取环境随机 / 墙钟 | 同上，规则 3 —— 否则回放不可复现 |
| 每个后端都过同一套契约 | `tests/contract/gfx.contract.ts`（22 条 · 两图形后端）<br>`tests/contract/script.contract.ts`（14 条 · 两脚本后端） |
| **结构性修改只走命令队列** | `core/scene/scene.ts` 的 `enqueue` + `flush`（ADR-0004） |

## 快速开始

```bash
npm install
npm run check            # tsc（strict）+ 1414 条判据 + 覆盖率闸门 <!-- n:tests -->
npm run audit:errors     # 拒绝路径审计：JPEG 解码器 94 条 fail 分支里哪些真的被触发过
npm run audit:mutation   # 变异校验：278 组注入，判据必须逐个变红 <!-- n:mutants -->
npm run audit:docs       # 文档数字对账：判据/变异/测试文件/浏览器自检/JPEG 金标
npm run test:browser     # 无头浏览器跑 selftest.html 的 14 条（无浏览器时退出码 2 = 跳过）
npm run ci               # 全部闸门（10 步，含浏览器自检/外部金标/变异；--fast 跳过慢的那几步）
npm run sample:headless  # 最小宿主：150 tick / 5 秒 / 脚本驱动 + 存档

# 浏览器（真的能看见画面 + Lua 在跑）
npm run build:web        # esbuild → web/bundle.js（wasm 从 web/glue.wasm 取，不依赖 CDN）
npm run serve:web        # http://127.0.0.1:8123/
#   index.html    演示：WASD 移动 · H 砍树 · F5 存档 · F9 读档 · 浆果在漂（Lua 驱动）
#   selftest.html 端到端自检：40 条断言 <!-- n:browser -->（画面/批处理/存档往返/Lua 跨边界）
```

`npm run sample:headless` 的输出（实测，节选；加 `-- --save-dir <目录>` 则存档落真实盘）：

```
[I][app] 平台就绪：headless gfx=null audio=null input=null fs=mem script=lua {"caps":{"id":"headless","interactive":false,"hasGpu":false,"hasAudio":false,"hasDom":false,"maxTextureSize":4096}}
[I][script] 脚本模块就绪：后端 lua 5.4 · 暴露 9 个宿主函数
[I][module] 模块启动完成：2 个（game.world → script.lua）
初始： {"nodes":6,"components":5,"pendingCommands":0,"stepsRun":0,"componentUpdates":0}
5 秒后： {
  tick: 150,
  time: 5,
  nodes: 6,
  components: 5,
  componentUpdates: 750,
  droppedSteps: 0,
  backends: {
    gfx: 'null',
    audio: 'null',
    input: 'null',
    fs: 'mem',
    net: null,
    script: 'lua'
  }
}
hero 位置： (10.00, 2.00)
树 0 的 ttl： 0.000 （5 秒后应为 0：已经烂完）
脚本节点位置： (1.387, 3.752) 半径=4.000（Lua 里用的是 4）
脚本： { backend: 'lua', modules: 1, calls: 150, errors: 0, dropped: 0 }
暂停期间 tick 不变： true (150 → 150)
模块： game.world=started, script.lua=started
事件统计： { emitted: 300, listenerErrors: 0, lastError: null }
存档： {
  where: 'mem:/saves/slot1.json',
  bytes: 935,
  sha256: 'edf6ee99f456cb11',
  '再次存相同': true,
  '节点数': 5
}
已释放。
```


## 分层

```
L6 hosts       browser-entry · headless sample · (editor ⬜)
L5 backends    gfx-null ✅ · gfx-webgl2 ✅ · audio-null ✅ · audio-webaudio ✅
               input-null ✅ · input-dom ✅ · fs-memory ✅ · fs-node ✅ · script-null ✅ · script-lua ✅
L4 extensions  render ✅ · physics ✅ · script ✅ · asset-import ✅ · (ai ⬜ · ui ⬜ · worldgen ⬜)
L3 runtime     GameApp · ITickSource
L2 core        Module · Scene/Node/Component · Scheduler · Asset · Schema
L1 platform    IGraphicsDevice · IAudioDevice · IInputDevice · IFileSystem · ITransport · IScriptRuntime
L0 foundation  Result · math · log · event · memory · time · random
```

依赖方向只能向下；`backends` **不许** import `core`（否则后端会开始依赖实现细节）。

## 加一个功能要改哪里

| 需求 | 改动 | 不用改 |
|---|---|---|
| 一个新组件（如"饥饿值"） | 1 个新文件（schema + 字段） | Scene / Component 基类 / 序列化 |
| 一个新子系统（如"物理"） | 1 个 `IModule` | GameApp / Scene / Scheduler |
| 一个新渲染后端 | 1 个目录 + 1 行注册 | `src/core/**` 全部 |
| 一种新脚本语言 | 1 个 `IScriptRuntime` 实现 | 内核 / 脚本模块 / 契约 |
| 一种新资产类型 | 1 个 `SourceImporter` + 1 个 `IAssetLoader` | AssetDatabase / 管线 |
| 一个存档新字段 | schema 加一行 + 一条 migration | 序列化器 |

## 当前状态

- ✅ L0–L3 完整；**12 个后端** <!-- n:backends -->（gfx×2 / audio×2 / input×2 / fs×4（mem + 真实盘 + 只读 http + localStorage）/ script×2）；**1414 条判据全绿** <!-- n:tests -->（变异 278 组全被抓住 <!-- n:mutants -->）
- ✅ 2D 渲染管线（相机/精灵/批处理/确定性图集合成）· 2.5D 物理 · 确定性存档 · 跳时间结算
- ✅ 世界生成：整数噪声 → 群系 → 架桥修复 → **世界指纹**（同种子必同指纹）+ 连通性校验
  （校验器用 `repair:false` 主动造出"到不了的陆地"来证明自己会报红，含 6 条变异）
- ✅ AI：**纯数据树**（可 JSON 往返/进指纹）+ 注册表行为 + **tick 计数不吃 dt**
  + **真 `FixedStepScheduler` 驱动**（每步恰好一次、暂停不动）+ 异常隔离（一个 agent 炸不拖垮整帧）
- ✅ 构建发布：入口闭包 + **内容寻址分包**（包名 = 内容 hash）+ 可复现 manifest + **落盘 CLI**
  （出口判据在内存层与磁盘层各验一遍：删未引用资产产物逐字节不变 / 改一个资产只重打一个包）
- ✅ 脚本层：`IScriptRuntime` + Lua 5.4（wasm）+ **Lua 5.1 兼容垫片** + **per-module `_ENV` 隔离**
  + 每 tick 串行调度 + 异常隔离 + 最小反射表
- ✅ 资产身份：`.meta` + `AssetId` + 依赖图 + 增量导入 + 产物加载器
- ✅ **PNG 全格式解码**（纯 TS inflate，colorType 0/2/3/4/6 × 位深 1/2/4/8/16 × 5 种滤波
  × **Adam7 隔行**；**APNG** 帧合成，含 dispose/blend 与循环；**16 位全精度**可保留到 `pixels16`）
  · 真实语料 3422/3423（唯一失败是源文件本身只有一半扫描线的 `_cmp_pair.png`）
  · 隔行/16 位/APNG 用 **pngjs + Pillow 双实现金标**闭环（见 [ADR-0008](docs/adr/0008-png-full-format-support.md)）
- ✅ **JPEG 全格式解码**（自写 DCT + QM 算术 + DPCM 无损 + 分层合成）
  · **13 个 SOF 全实现**：基线/扩展顺序/渐进/无损/差分 × Huffman/算术，不再有"明确不支持"的过程
  · 精度：DCT 类 8/12 位（12 位默认出 8 位，`keep16` 拿全精度 `pixels16`）· 无损类 2..16 位
  · 分层：DHP + EXP + 多帧，差分帧在样本域合成（无损按 mod 2^P，有损减电平位移）
  · 任意 h/v 采样 + 三角上采样 · DRI/RST · 灰度/YCbCr/RGB/CMYK/YCCK · EXIF 方向可选应用
  · 截断文件标记 `truncated` 而不是静默出灰块
  · 金标共 **54 例** <!-- n:jpeggold -->（`tests/fixtures/jpeg/`，去重口径）：17 例 Pillow(libjpeg-turbo) 容差（max ≤ 6）
    + 1420 例网格扫描（`tools/jpeg-diff-sweep.*`，峰值差 3）+ 6 例算术与 6 例哈夫曼（**我们编码 → libjpeg 解码**）
    + 8 例无损 9..16 位（liblj92 编解，**逐样本相等**）+ 8 位灰度（liblj92 与 Pillow 双外部对照）
    + **12 例 ffmpeg 独立金标**（`tests/fixtures/jpeg/ff/`，12 位 DCT 的第三方参照：灰度差 0..2 级、RGB 差 4 级）
  · 仍然没有外部实现的部分（分层、SOF11）用更强的内部判据：
    四种有损过程解出**逐字节相同**像素、无损回环 max=0、12 位跨精度锚定到 8 位金标；278 组变异全被抓住 <!-- n:mutants -->
  · 证据等级与代价见 [ADR-0009](docs/adr/0009-jpeg-decoder.md)
- ✅ 浏览器宿主能跑，且**画面用真实资产**：`web/assets/` 5 张 PNG + **1 张 JPEG** 走完整导入链
  烘焙成图集（WASD + 砍树 + 存读档 + HUD + Lua 驱动的浆果漂浮 + 4 块 JPEG 立牌）
- ✅ CI：`node tools/ci.mjs` 本地一条命令跑 14 道闸门 <!-- n:steps -->（类型 / 判据 / 覆盖率 / 文档对账 /
  拒绝路径审计 / PNG 语料 / JPEG 金标 / 浏览器包构建 / 浏览器自检 / 变异）；
  `.github/workflows/ci.yml` 只调用它，双 OS 矩阵
- ✅ 浏览器端自检自动化：`npm run test:browser` 用无头 Chromium 跑那 14 条（无浏览器时**跳过并标注**，不算通过）
- ⬜ AI · 世界生成 · 编辑器 · 构建发布

未做的项与顺序见 [docs/ARCHITECTURE.md §11–§12](docs/ARCHITECTURE.md)，
本轮排班表见 [docs/PLAN-2026-10-22-阶段2.md](docs/PLAN-2026-10-22-阶段2.md)。
