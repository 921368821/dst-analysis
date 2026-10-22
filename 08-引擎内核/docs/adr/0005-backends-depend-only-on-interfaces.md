# ADR-0005 · 后端只依赖接口，禁止 import 引擎内核

- **状态**：已采纳（由 `tests/arch/layers.test.ts` 规则 1 强制）
- **日期**：2026-10-22

## 背景

后端（`src/backends/**`）是平台相关的实现：WebGL2、WebAudio、DOM 输入、Node 文件系统。
直觉上它们"属于引擎"，似乎应该能 import 引擎里的东西（日志、`Result`、数学）。

但如果允许后端 import `core/**`，会依次发生：
1. 某个后端为了"方便"开始 import `Scene`，于是里面出现 `if (component.type === 'sprite')`；
2. 那个后端不再可移植（它现在知道引擎有哪些组件类型）；
3. 第二个后端不得不复制那段特判，两份实现开始漂移；
4. 一年后没有人能说清"渲染的行为定义在接口里还是 WebGL2 后端里"。

这不需要任何人做错决定 —— 只需要几次"这次特殊"。

## 决策

**依赖矩阵写死并机器校验**：

```
L5 backends  →  允许 import: L0 foundation, L1 platform, L5（同层）
                禁止 import: L2 core, L3 runtime, L6 hosts
```

也就是：后端可以 `import { ok, err, engineError } from foundation/result.ts`、
可以 `import type { IGraphicsDevice } from platform/gfx/device.ts`，
但**不许** `import { Scene } from core/scene/scene.ts`。

同一条规则的另外三个方向：
- **L1 不许 import L2+**（接口层知道内核 = 抽象已漏）
- **L1 不许出现平台类型**（`WebGL2RenderingContext` / `HTMLCanvasElement` / `document.` / `window.`）
- **只有组合根（`runtime/GameApp.ts`）可以 import 具体后端**
  （否则"换后端"会变成改多处，而且没人知道到底用了哪个）

## 后果

### 正面

- 后端可移植：把 `src/backends/gfx-webgl2/` 拷到一个只有 `foundation` + `platform` 的
  工程里，它必须还能编译（这是一条可以手动验证的判据）。
- 渲染的行为定义**只在接口里**。两个后端不一致 ⇒ 契约测试红 ⇒ 那是接口歧义，不是"某个后端的 bug"。
- 组合根唯一 ⇒ 运行时日志能一句话回答"到底跑在什么上"（`app.snapshot().backends`）。

### 负面

- 后端不能直接用引擎的日志通道（`Logger` 在 L0 里，**可以**用；
  但后端不该持有一个全局 logger —— 它需要日志时**从 create 参数接收**）。
- 后端不能复用 `core` 里的工具（例如 `Schema`）。
  **缓解**：真的需要的东西应该在 L0/L1；`Schema` 在后端没有使用场景
  （后端只处理字节，不处理对象图）—— 如果某天真需要，那是"把它下沉"的信号，
  而不是"允许后端 import core"。

## 被否的方案

- **允许后端 import core，靠 code review 把关**：review 是稀缺资源，
  而且"这次特殊"总是有理由。这条规则的目的是**让特殊没有可能**。
- **把后端放在 `core/render/backends/` 下面**：那样"依赖方向"在目录结构上就看不出去了。

## 相关

- `tests/arch/scan.ts`（`ALLOWED` 矩阵）
- `tests/arch/layers.test.ts`（规则 1 / 2 / 4）
- `docs/ARCHITECTURE.md` §2.2
