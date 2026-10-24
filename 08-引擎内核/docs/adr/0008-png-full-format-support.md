# ADR-0008 · Adam7 / APNG / 16 位：靠"外部双实现金标"闭环，而不是靠真实语料

- **状态**：已采纳（由 `tests/extensions/png-adam7.test.ts`、`png-fixtures.test.ts`、
  `apng.test.ts`、`atlas-from-apng.test.ts`、`png-16bit.test.ts` 强制；变异 M8–M13 证明判据不空转）
- **日期**：2026-10-22
- **取代**：ADR-0007 之后对 `png.ts` 头注释里"隔行明确拒绝"的理由（那条理由本身没错，
  错的是"没有验证手段"这个前提 —— 现在有了）

## 背景

旧口径把三件事列为"明确不支持"：

| 项 | 旧行为 |
|---|---|
| Adam7 隔行 | 报 `ASSET.UNSUPPORTED_INTERLACE` |
| APNG | 帧块当 ancillary 跳过，静默取默认帧 |
| 16 位色深 | 取高字节降采样（floor），低字节丢弃 |

理由写得很清楚：**"工程内 3284 张真实 PNG 全部非隔行、8 位、无 APNG，实现完无法验证"**
（`node tools/scan-png-features.mjs` 的实测结果，至今仍然如此）。

这个理由有一个隐含前提："验证 == 拿真实语料跑一遍"。它把"没有语料"等价成"不能验证"，
于是能力被永久冻结 —— 而 PNG 规范对这三种情况的规定是明确的、可判定的。
真正的问题不是"能不能写对"，而是**"怎么证明写对了"**。

## 决策

### ① 语料自己造，但**不自证**

编码器（`tools/png-encode.mjs`）只用于造语料，且与解码器**结构不同源**：

- 解码器是**生成式**：给定 pass 的 `(xStart, yStart, xStep, yStep)`，直接算出每个像素的图坐标；
- 编码器是**过滤式**：遍历整幅图的每个像素，判断它落进哪个 pass，再按 pass 顺序收集。

两者共享的只有规范原文那七个四元组。表错一处，两条路径立刻不等价 ——
`M8`（pass 表错一位）、`M9`（pass 宽度 `ceil`→`floor`）两个变异就是证明。

### ② 用**两个独立实现**的输出来固化金标

| 环节 | 用的实现 | 验证什么 |
|---|---|---|
| 隔行 PNG 解码 | **pngjs 7.0.0** | 我们的 Adam7 与主流 JS 实现逐字节一致 |
| 隔行 PNG 解码 | **Pillow 13.0.0** | 同上，独立 C 实现 |
| 16 位原值 | 往返（编码器输入 vs `pixels16`） | 全精度不丢 |
| 16 位降采样 | pngjs（`round(v*255/65535)`） | 取整口径 |
| APNG 帧像素 | Pillow 解"逐帧矩形 PNG" | 每帧的 RGBA 正确 |
| APNG 合成 | Pillow `Image.alpha_composite` | dispose/blend 状态机 + 严格 source-over |

流程写死在两个工具里，可重跑：

```bash
node tools/make-png-fixtures.mjs          # 生成 png + 金标（需要 pngjs）
python tools/verify-fixtures-pillow.py    # 交叉验证 + 生成 APNG 帧金标（需要 Pillow）
node tools/make-png-fixtures.mjs --check  # 只校验金标是否仍与编码器输出一致
```

**测试运行时不需要 pngjs / Pillow**：金标是仓库里的固定字节（`tests/fixtures/png/*.rgba`），
`package.json` 不会因此多一个依赖。第三方实现只在"重建金标"时出现。

### ③ 口径差异要记账，不要抹平

验证过程中发现两处"两个独立实现自己就不一致"的地方，都记录下来而不是选一个当真理：

1. **16 位 → 8 位的取整**：PNG 规范**没有规定**。pngjs 用 `round(v*255/65535)`，
   Pillow 用 `floor(v/256)`，我们跟 pngjs（`round(v/257)`）。
   判据于是分两条：原值逐字节相等（无损）+ 降采样口径与 pngjs 一致。
   与 Pillow 的关系变成"每个字节最多差 1"（`verify-fixtures-pillow.py` 里断言 `worst <= 1`）——
   差 1 是取整，差得多就是通道/端序/位深错了。
2. **Pillow 的 APNG `blend=OVER` 会把 alpha 二次相乘**：它用 `paste(im, box, im)`，
   等于拿 alpha 当 mask 同时混 RGB **和 alpha 自身**（实测 128 → 64）。
   规范定义的是 Porter-Duff over（`Ao = As + Ad(1-As)`），所以 Pillow 的内建读取**不能当金标**。
   改成"Pillow 解每帧矩形 PNG + `Image.alpha_composite` 合成"，内建读取只在**全不透明帧**
   用例上做交叉核对（那时 `paste` 与 `over` 等价，仍能验证 dispose 顺序）。

### ④ 下游必须有人消费，否则不算闭环

- **Adam7**：解码器无感 —— 导入器只看 IHDR，贴图链路拿到的仍是 RGBA8，天然可用。
- **16 位**：`pixels` 恒为 RGBA8（现有管线直接吃），`keep16: true` 另给 `pixels16`。
  **边界**：`TextureDesc` 只有 `rgba8`，16 位不进 GPU。要进 GPU 得先加 `PixelFormat` 与采样器，
  那是渲染层的事 —— 不能让解码器"偷偷降采样"假装支持。
- **APNG**：`decodeApng` 出帧后，`buildAtlasFromApng` 把帧拼成一张 sprite sheet，
  动图退化成"按帧矩形切 UV"，**不改渲染模块**就能播。

## 后果

**好的方面**

- 三种格式从"明确不支持"变成"有判据的已支持"；判据 230 → 310 条。
- 36 个新判据里，每条都能指出"抓什么错"：`M8`–`M13` 六个变异全部被抓（详见 `tools/mutation-check.py`）。
- 真实语料回归仍然全绿（3366/3367，唯一失败是源文件本身只有一半扫描线的 `_cmp_pair.png`），
  说明重构非隔行路径没有退化。
- 顺带修掉了工具的一个假容量：`verify-png-corpus.mjs` 的结构校验原来不认 `PLTE`，
  因为工程里从没有调色板图。加入调色板语料后立刻红了 —— 那是工具缺能力，不是图有问题。

**代价**

- 仓库多了 77 个小文件（`tests/fixtures/png/`，总计 234 KB：18 组隔行/非隔行对照 PNG + 金标 + 4 组 APNG + 逐帧 PNG）与两个"只在重建金标时要装"的工具依赖（pngjs / Pillow）。
- 金标一旦被手改，判据就失去意义 —— 所以每个 `.rgba` 都在 manifest 里存了 SHA-256，
  测试先校验哈希再比像素。
- Adam7 的 289 尺寸矩阵（`1..17 × 1..17`）把单个测试文件跑慢了约 0.2 s。值得。

## 不做的事（明确的边界）

- **APNG 播放时间轴**：`decodeApng` 只产出帧 + 时长，不持有计时器。播放是 `RenderModule`
  或游戏逻辑的事 —— 图集持有计时会让同一份素材在两个世界里互相干扰。
- **16 位进 GPU**：见上，需要先扩 `PixelFormat`。
- **APNG 的 `unloadModule` 式"清不掉"问题**：与本节无关，见 ARCHITECTURE §11.2。
- **JPEG / WebP**：仍然明确不支持（需要完整 DCT 解码器，收益远低于成本）。
