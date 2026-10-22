# ADR-0006 · 脚本层：只传值、全异步、null 后端不假装能执行

- **状态**：已采纳（由 `tests/contract/script.contract.ts` 与 `tests/backends/*` 强制）
- **日期**：2026-10-22

## 背景

脚本层要复用的是 153 万行 Lua 内容层（来自《饥荒》注释源码），
所以"内核里直接嵌一个 Lua"是最省事的写法。它会在三处同时变贵：

1. **换语言 = 重写内核**。将来要支持 JS / DSL / 可视化图，所有调用点都要改。
2. **内核不再是纯 TS**。每个内核判据都得先初始化一个 Lua VM。
3. **浏览器与 headless 各写一套绑定**。

同时有三个具体问题必须现在定，否则后面改不动：

- **值语义**：脚本能不能拿到"引擎对象"（`Node` 引用、GPU 句柄）？
- **同步/异步**：Lua 求值本身是同步的，接口要不要写成同步？
- **没有脚本能力时怎么办**：`null` 后端是"假装执行"还是"明确拒绝"？

## 决策

### ① 只传值，对象一律走 `expose()` 变成函数表

跨边界只允许 `null / boolean / 有限 number / string / 数组 / 纯对象`（`ScriptValue`）。
`undefined`、`bigint`、函数、类实例在进运行时**之前**就被 `assertScriptValue` 挡掉。

宿主对象（scene / node / 资产）通过 `expose(name, fn)` 暴露成**调用能力**，
脚本拿到的是函数，不是引擎内存。

理由不只是"安全"：传引用会让两件已经规划好的事直接做不了 ——
**异常隔离**（一次脚本崩溃能污染宿主堆）与 **把脚本丢进 Worker**（引用过不去）。

### ② 接口全异步

`loadModule` / `call` / `ready` 全部返回 `Promise<Result<...>>`。

WASM 加载、Worker 隔离、远程调试桥都必然是异步的；接口定成同步后，接其中任何一个
都要改签名 —— 也就是改所有调用方，正是这条 ADR 想避免的事。
代价是每个调用点多一个 `await`；`BackendRegistry.create()` 保持同步，
它只**构造** runtime，真正的初始化在 `ready()` 里。

### ③ null 后端 `executes: false`，`call` 一律 `SCRIPT.NOT_SUPPORTED`

`gfx-null` 可以"假装渲染并记录调用"，因为渲染的产物是像素，没人校验像素。
脚本的产物是**世界状态**：假装执行会让"脚本没跑"看起来像"脚本跑了但没效果"，
这是最难查的一类 bug（表现为"这个生物不动了"，会被误判成 AI 问题）。

所以 `ScriptModule.init` 在 `caps.executes === false` 时**直接失败**，
由宿主决定换后端还是关掉该功能。

### ④ 每 tick 的调用必须串行，队列有上限且丢弃可观测

宿主在**同步**的 `scheduler.onStep` 里驱动脚本，而 `call` 是异步的。
不排队就会出现 tick N+1 在 tick N 返回前进入同一个 state（两个 tick 交替改同一个全局变量），
症状是"偶尔抖动 + 存档不可复现"。
队列满了丢弃并计数（`droppedUpdates`）+ 记日志，与 `scheduler:steps-dropped` 同一处置。

## 后果

### 正面

- 换语言 = 换一个 `IScriptRuntime` 实现；内核一行不改。
- 同一套契约（14 条）能同时约束 Lua 与 null，两个后端的差异是**数据**（caps）不是分支。
- 脚本层出口判据可以做到"逐字节存档相同"——串行化之后它才成立。

### 代价 / 已知边界

- **Lua 5.4 ≠ DST 的 5.1**：`setfenv` / `module()` / `unpack` 在 5.4 里没有。
  兼容层（或换 5.1 wasm）是迁移 153 万行的前置工作，**本轮没做**。
- **模块共享 `_G`**：模块函数做了命名空间隔离（`__engine_modules` + 最长前缀解析），
  但函数体内读写的全局变量仍是共享的；完整的 per-module `_ENV` 未做
  （会与"裸 `call("greet")`"的契约冲突）。
- **嵌套 `null` 在 Lua 表里无法表示**（键会消失）。这是 Lua 的表示能力上限，
  不是可以在绑定层修好的东西。顶层 null 正常（转 nil）。
- **超时基于 `os.clock()` 的 CPU 时间**，且 deadline 是单一全局；嵌套/重入调用未隔离。
- **wasmoon 在 Node 22 下有环境变量坑**：emscripten 的 `environ_get` 断言
  `charCode ≤ 255`，而 `_`（程序名）在 node:test 下是测试文件路径（本工程路径含中文）。
  修法是显式传 `environmentVariables` 覆盖 + 临时净化 `process.env`（见 `withSanitizedEnv`）。
  这个坑与根因（环境变量编码）离得太远，值得单独记在这里。

## 备选与为什么没选

| 备选 | 否决理由 |
|---|---|
| 脚本方法的同步接口 + 内部同步初始化 | 浏览器 WASM 不可能同步加载；一旦定成同步，接 Worker 要改所有调用方 |
| 传对象引用（脚本直接拿 `Node`） | 异常隔离与 Worker 隔离都做不了；脚本能持有已销毁节点 |
| null 后端返回"成功但什么都不做" | 与 `gfx-null` 不同：脚本的假执行没有可见产物，只会制造静默 bug |
| 每 tick 一个独立 VM（天然隔离） | 全局状态（`package.loaded`、闭包）无法跨 tick 保留，等于每次重载全部脚本 |
