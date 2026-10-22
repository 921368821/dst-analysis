# 08-引擎内核 · 进度总表

> 口径：**对标 Unity / Cocos Creator 的架构水准**，开发周期不优先，架构标准性与工程质量优先。
> 本表滚动更新，每次阶段收尾重算；所有数字都可用末尾命令复现，不凭印象。

**最后更新：2026-10-22 21:20 · 内容板块补齐（Lua 5.1 / `_ENV` 隔离 / PNG 解码 / 真资产上屏）**

---

## 一、一句话结论

**内核骨架立住了，内容层闭环了，工具链仍是空白。**

内容板块这次的 4 个缺口（Lua 5.1 兼容 / per-module `_ENV` / 像素解码 / 资产→sprite 接线）
**全部补齐并验证**：判据 180 → **230**，变异验证 3 → **7 组**，浏览器画面从"程序化假贴图"
换成 `web/assets/*.png` 走完整导入链烘焙出的真图集。

但**编辑器**和**构建发布**——Unity/Cocos 最占工作量、也最决定"是不是一个引擎产品"的两块——
完成度仍是 0。所以两个口径并列，避免误读：

| 口径 | 完成度 | 含义 |
|---|---|---|
| **对标 Unity/Cocos 完整能力** | **56%** | 按五块工作量加权（见 §二） |
| **能做出饥荒风格可玩原型** | **约 75%** | 不要求编辑器与打包 |

---

## 二、阶段总进度（加权）

权重依据"一个标准引擎的工作量分布"，不是平均分：

| 板块 | 权重 | 完成度 | 加权 | 依据 |
|---|---|---|---|---|
| **内核** L0–L5 接口 + 后端 + 架构守护 | 20% | **100%** | 20.0 | 6 层接口全定、9 后端、7 条依赖规则机器守护、Node/浏览器同码 |
| **内容** 脚本层 + 资产管线 + 解码 + 图集 | 20% | **96%** | 19.2 | 四大缺口全补；剩 3 个已记录的小边界（见 §六 P4） |
| **世界** 物理 + AI + 世界生成 | 25% | **30%** | 7.5 | 空间哈希+圆推出可用；无 AABB/`FindEntities`、无 AI、无生成器 |
| **工具链** 编辑器 + 构建发布 | 25% | **0%** | 0.0 | 目录都不存在 |
| **工程** 判据 / 文档 / ADR / 双宿主 | 10% | **88%** | 8.8 | 230 判据、7 组变异、7 ADR；缺 CI 与浏览器自动化 |
| **合计** | 100% | | **55.5%** | |

> 上次记 53%，本次 **+2.5**：内容 85→96（+2.2）、工程 85→88（+0.3）。

### 阶段路线完成情况

| 阶段 | 目标 | 状态 | 完成度 | 出口判据 |
|---|---|---|---|---|
| 阶段 0 | 骨架：分层 + 接口优先 | √ | 100% | 架构守护 7 条全绿 |
| 阶段 1 | 能看见画面（渲染 + 输入） | √ | 100% | 一次 draw call 合批 ≤ 1 ✅ |
| 阶段 2 | 内容可复用（脚本 + 资产 + 真资产上屏） | √ | **96%** | 8 条出口判据 7 达成、**1 条未达成（跨宿主逐字节存档）** |
| 阶段 2.5 | 工程收口（fs-node / CI / 跨宿主自动化） | × | 0% | 未开始 |
| 阶段 3 | 世界像饥荒（物理 + AI + 生成） | × | 30% | 未开始（物理有地基） |
| 阶段 4 | 能做游戏（编辑器 + PIE） | × | 0% | 未开始 |
| 阶段 5 | 能交付（构建发布） | × | 0% | 未开始 |

---

## 三、本轮补齐：内容板块的 4 个缺口

上一版把内容记 85%，差的 15% 就是这 4 项。现在逐项对照：

| # | 缺口 | 状态 | 落地 | 验证方式 |
|---|---|---|---|---|
| 1 | **Lua 5.1 兼容层** | √ | `backends/script-lua/compat-lua51.ts`（300 行 Lua 源码常量）：`unpack`/`loadstring`/`setfenv`/`getfenv`/`module()`/`package.seeall`/`math.pow\|mod\|ldexp\|frexp\|log10`/`table.getn`/`string.gfind`/`arg`/`require` | `tests/backends/script-lua51.test.ts` **12 条** |
| 2 | **per-module `_ENV` 隔离** | √ | 每模块一张独立 env（`__index = _G`）；同名重载丢弃旧 env；函数名解析 `<module>.<entry>` → 裸名 → `_G` | `tests/backends/script-env.test.ts` **7 条** |
| 3 | **PNG 像素解码** | √ | `asset-import/decode/inflate.ts`（479 行，纯 TS：stored/fixed/dynamic Huffman + adler32）、`decode/png.ts`（591 行，colorType 0/2/3/4/6 × bitDepth 1/2/4/8/16、5 种反滤波、逐块 CRC） | `tests/extensions/png-decode.test.ts` **13 条** + 真实语料 **3366/3367** |
| 4 | **资产 → sprite 接线** | √ | `render/atlas-from-assets.ts`（确定性 shelf packing）；`browser-entry` 改为 fetch 真 PNG → 导入管线 → 解码 → 合成 → `createTexture`；失败才降级且 HUD 显示 `atlas:assets×5`/`atlas:procedural` | `tests/core/asset-gpu-roundtrip.test.ts` **6 条**（含 2 条反例防假绿）+ 浏览器自检 2 条 |

### 三个真实缺陷（都由验证抓到，不是自述）

1. **同一原语两层各写一份，且已漂移** —— 资产层与 `gfx-null` 各有一份"双 FNV 哈希"，
   B 通道 basis 一个 `0x9e3779b9`、一个 `0x84222325`。两边单测都过，但摘要**永不相等**，
   于是"解码出的像素"与"GPU 收到的像素"根本没法比对。
   已把算法提到 `foundation/hash.ts`，并加 `hashEquals`（必须同时比字节数，
   否则"两边都忘了 update"会双双等于空流摘要而**假相等**）。
2. **`debug.setupvalue` 是错解** —— 它改的是 chunk 内**共享**的 `_ENV` upvalue 对象，
   会把兄弟闭包和调用者一起换掉（实测 `tostring` 立刻变 nil）。
   `setfenv` 必须用 `debug.upvaluejoin` 给目标函数**私有** upvalue。
3. **`debug.getupvalue` 返回 `(name, value)`** —— 只取第一个会拿到名字，
   症状极具误导性：限定名调用能过、裸名报 `NO_FUNCTION`。

### 一条假绿灯被删掉（而不是修好）

浏览器自检里原有「画布不是纯黑」——它恒返回 `true`。
`preserveDrawingBuffer: false` 时帧后 `readPixels` 读不到内容，做不出真判据。
**宁可删掉它，也不留一条恒真的断言**：留着会让"13 条全绿"这个数字失去意义。
真要自动化得走 render target + readback 做 golden image，归阶段 3。
页面上改为明确标注"画面观感需人工确认"。

---

## 四、能力矩阵（对标 Unity / Cocos Creator）

| 能力 | Unity | Cocos Creator | 本内核 | 差距判定 |
|---|---|---|---|---|
| 分层与依赖方向 | 内部不公开 | 内部不公开 | L0–L6 + **机器守护** | **持平**（少见的好） |
| 渲染抽象 | RHI 多后端 | `gfx::Device` | `IGraphicsDevice` + 2 实现 | 缺 Vulkan/Metal（Web-first 下不阻塞） |
| 2D 批处理 | SpriteAtlas + SRP Batcher | 2D 管线 | z↓ → order → atlas 排序，单 draw call | **持平** |
| 资产身份 | `.meta` + GUID | `.meta` + UUID | `.meta` + 稳定 id，改名保 id | **持平** |
| 增量导入 | ✅ | ✅ | hash + version + 依赖存活（三元组） | **持平** |
| **像素解码** | 全格式 | 全格式 | **PNG 全色彩类型/位深/5 滤波**；无 Adam7/APNG/JPEG | **落后收窄**（从"只读头"到"真能解"） |
| 图集打包 | Sprite Atlas | Auto Atlas | 确定性 shelf packing，2 幂尺寸，帧间 padding | **近似**（无九宫格/旋转/压缩格式） |
| **脚本运行时** | C# Mono/IL2CPP | TS (JSB) | `IScriptRuntime` + Lua 5.4 **+ 5.1 垫片** + null | **接口达标，5.1 可跑**（真内容层未实跑） |
| 脚本隔离 | 有 | 有 | 单脚本异常不断帧；**模块级 `_ENV` 隔离** | **持平** |
| 物理 | PhysX/Box2D | box2d | 空间哈希 + 圆推出 | **落后一代**（无 AABB、无连续碰撞） |
| 动画 | Mecanim | Animation | 无 | **缺** |
| UI | UGUI/UI Toolkit | cc.UITransform | 无 | **缺** |
| 音频 | FMOD 级 | AudioSource | `IAudioDevice` + WebAudio | 接口达标，功能最少 |
| 场景/序列化 | YAML + Prefab | JSON + Prefab | 三遍装配确定性 JSON | 缺 Prefab 继承/变体 |
| **编辑器 + PIE** | 核心产品 | 核心产品 | **无** | **最大缺口** |
| **构建发布** | 全平台 | 全平台 | **无** | **第二大缺口** |
| 跨平台同码 | IL2CPP | 多平台 | Node headless + 浏览器 | **持平**（仅两宿主） |
| 自动化判据 | 内部 | 内部 | 230 条 + 7 组变异 | **持平** |

### 三套评分

| 维度 | 阶段 1 后 | 阶段 2 后 | 现在 | 变化原因 |
|---|---|---|---|---|
| **运行时**（能不能跑对） | 67 | 78 | **81** | PNG 真解码、图集确定性合成、资产→GPU 闭环判据、Lua 5.1 垫片、`_ENV` 隔离 |
| **产品**（能不能做游戏） | 20 | 21 | **21** | 真资产能上屏了；但编辑器/构建/UI/动画仍为 0 |
| **生态**（能不能被采用） | 13 | 13 | **13** | 无变化：无包管理、无文档站、无插件市场 |

### 六条硬门槛

| # | 门槛 | 阶段 1 | 阶段 2 | 现在 |
|---|---|---|---|---|
| 1 | 多后端渲染抽象 | 0 | 0.5 | **0.5**（接口 + 2 后端，真图形后端仍只 1 个） |
| 2 | `.meta` + GUID 资产身份 | 0 | 1 ✅ | **1** |
| 3 | 脚本层可换语言 | 0 | 1 ✅ | **1** |
| 4 | 编辑器 + PIE | 0 | 0 | 0 |
| 5 | 构建发布 | 0 | 0 | 0 |
| 6 | 双平台同码 | 0 | 1 ✅ | **1** |
| | **合计** | **0/6** | **3.5/6** | **3.5/6** |

---

## 五、质量指标（可用命令复现）

| 指标 | 数值 | 复现命令 |
|---|---|---|
| 源码 | **66 文件 / 14,351 行** | `find src -name "*.ts" \| xargs wc -l \| tail -1` |
| 判据 | **230 条，230 通过 / 0 失败** | `npm test` |
| 类型检查 | **0 错误**（strict + `noUncheckedIndexedAccess` + `noUnusedLocals`） | `npm run typecheck` |
| 测试文件 | 22 个 | `find tests -name "*.test.ts"` |
| 架构守护 | 7 条依赖规则 | `tests/arch/layers.test.ts` |
| 后端 | **9 个**（gfx×2 / audio×2 / input×2 / fs×1 / script×2） | `ls src/backends` |
| 扩展模块 | 4 个（render / physics / script / asset-import，含 decode 子目录） | `ls src/extensions` |
| 变异验证 | **7 组注入，7/7 被抓住且还原干净** | `python tools/mutation-check.py` |
| 真实 PNG 语料 | 结构校验 **3367/3367**；完整解码 **3366/3367**（1 个源文件本身被截半） | `node tools/verify-png-corpus.mjs --all` |
| 浏览器自检 | **15 条**（含"图集来自真实资产"、"图集 5 帧"） | `npm run build:web && npm run serve:web` |
| 包体 | 公共入口 144KB（不含 wasmoon）/ 浏览器 472KB + wasm 266KB + 资产 5.4KB | `esbuild src/index.ts` 对比 |

### 分层规模

| 层 | 文件 | 行数 | 本轮增量 |
|---|---|---|---|
| L0 foundation | 11 | 1,203 | +`hash.ts`（101 行，哈希统一到 L0） |
| L1 platform | 8 | 1,145 | — |
| L2 core | 11 | 2,432 | — |
| L3 runtime | 2 | 477 | — |
| L4 extensions | 20 | 4,444 | +`decode/inflate`(479) `decode/png`(591) `atlas-from-assets`(326) |
| L5 backends | 12 | 3,925 | +`compat-lua51`(300) + runtime +144 + gfx-null 摘要改造 |

---

## 六、已知缺口（按优先级，含阻塞关系）

### P4 · 内容板块残留（3 个小边界，不阻塞当前目标）

| 缺口 | 现在的行为 | 为什么先不做 |
|---|---|---|
| `unloadModule` 清不掉 `module()` 写进 `_G` 的表 | 卸载后模块表仍在 `_G` | 运行时无法区分"模块建的"与"本来就有的"；需要 C 侧记录每模块创建的全局键。热重载真沙箱才需要 |
| Adam7 隔行 PNG / APNG | 前者明确报 `UNSUPPORTED_INTERLACE`；后者帧块被当 ancillary 跳过 | 工程语料 3367 个**全部非隔行**、无 APNG。**没有验证手段就不写"看起来支持"的代码** |
| 16 位色深 | 降采样到 RGBA8（取高字节） | HDR/高精度贴图要扩展 `PixelFormat` 与 `AtlasData`，当前目标是 2.5D 像素风 |

### P0–P2 · 工程与验证

| 缺口 | 现状 | 在等什么 |
|---|---|---|
| **headless ↔ 浏览器逐字节存档** | headless 侧两条独立实例已互证；浏览器侧只断言到"Lua 算得对 + 跨界日志可见" | 本机无浏览器自动化能力 ⇒ 阶段 2.5 |
| **浏览器端自动化** | `selftest.html` 15 条需人工打开 | 同上 |
| `fs-node` 后端 | **空目录**（存档落不到真实文件） | 阶段 2.5 |
| 无 CI | 全部闸门 local-only | 阶段 2.5 |

### P3 · 世界（阶段 3）

- 物理：无 AABB、无 `FindEntities(x, z, r)`（饥荒同签名）、无连续碰撞
- AI：0
- 世界生成 + 世界指纹：0

### P5 · 工具链（阶段 4/5）

- 编辑器 + PIE：0
- 构建发布（manifest + 增量 + 内容寻址）：0

---

## 七、下一阶段（2.5）建议排班

目标：把"内容可复用"从**代码可用**推到**工程可交付**。

| # | 任务 | 依赖 | 可并行 | 验收 |
|---|---|---|---|---|
| E1 | `fs-node` 后端（存档落真实文件） | — | ∥ E3 | 重启进程后读回同一存档 |
| E2 | 跨宿主逐字节存档（浏览器导出 → Node 比对） | E1 | — | 阶段 2 那条红判据转绿 |
| E3 | CI（tsc + 230 判据 + 变异 + 语料） | — | ∥ E1 | 干净 clone 一条命令复现全绿 |
| E4 | 真跑一段 DST 5.1 脚本（从 `07-通用引擎` 取） | — | ∥ E1/E3 | 按报错逐条补垫片，缺口清单化 |
| E5 | 文档 + 变异 + 提交 | 全部 | — | tsc 0 / 全绿 / 7 组变异 |

预估：**55.5% → 约 59%**（内容 96→99，工程 88→92）。

---

## 八、复现全部数字

```bash
cd 08-引擎内核
npm run check                          # tsc 0 错误 + 230 判据全绿
npm run sample:headless                # 150 tick / 半径 4.000 / calls 150 / errors 0
python tools/mutation-check.py          # 7 组变异，7/7 被抓住
node tools/verify-png-corpus.mjs        # 3367 个真实 PNG 结构校验 + 抽样解码
node tools/make-demo-assets.mjs         # 重新生成 web/assets 的 5 张 PNG
npm run build:web && npm run serve:web  # http://127.0.0.1:8123/selftest.html（15 条，需人工看画面）
```
