/**
 * L5 · 后端集合与"标准注册"
 *
 * `registerNullBackends` 的存在理由：让"最小可运行宿主"变成一行。
 * 判据、headless 服务端、CI 都不该各自手抄一遍注册代码 ——
 * 抄出来的副本一旦和真实宿主不一致，判据就在测一个不存在的配置。
 */

import type { BackendRegistry } from "../platform/registry.ts";
import { nullGfxBackend } from "./gfx-null/device.ts";
import { nullAudioBackend } from "./audio-null/device.ts";
import { nullInputBackend } from "./input-null/device.ts";
import { memFsBackend } from "./fs-memory/fs.ts";
import { nullScriptBackend } from "./script-null/runtime.ts";

export { NullGraphicsDevice, nullGfxBackend } from "./gfx-null/device.ts";
export type { NullFrameRecord, NullDrawRecord } from "./gfx-null/device.ts";
export { NullAudioDevice, nullAudioBackend } from "./audio-null/device.ts";
export type { PlayRecord } from "./audio-null/device.ts";
export { NullInputDevice, nullInputBackend } from "./input-null/device.ts";
export { MemoryFileSystem, memFsBackend } from "./fs-memory/fs.ts";
export { NullScriptRuntime, nullScriptBackend } from "./script-null/runtime.ts";
export type { NullScriptRecord } from "./script-null/runtime.ts";

/**
 * 注册全套 null 后端。
 * 优先级刻意设为 **0**（最低）：真实后端（webgl2/webaudio/dom）优先级更高，
 * 于是"有真后端就用真的，没有就自动降级到 null"——降级是**注册表的默认行为**，
 * 不需要每个调用点写 try/catch。
 */
export function registerNullBackends(
  reg: BackendRegistry,
  opts: { fsPrefix?: string } = {},
): void {
  reg.registerGfx(nullGfxBackend, 0);
  reg.registerAudio(nullAudioBackend, 0);
  reg.registerInput(nullInputBackend, 0);
  reg.registerFs(
    {
      id: memFsBackend.id,
      scheme: memFsBackend.scheme,
      probe: memFsBackend.probe,
      create: (o?: unknown) =>
        memFsBackend.create({ prefix: opts.fsPrefix ?? "", ...(o as object | undefined) } as unknown),
    },
    0,
  );
  // null 脚本后端优先级也是 0：真 Lua 后端（wasm）优先级更高，有就用真的。
  reg.registerScript(nullScriptBackend, 0);
}

// ★ 真 Lua 后端 **刻意不从这里导出**：
//   `backends/index` 是"null 后端集合"，被判据/headless/公共 API 面（`src/index.ts`）引用。
//   在这里静态 import `script-lua` 会把 ~240KB 的 wasmoon glue（含 wasm）拖进**任何**
//   用到 null 后端的构建 —— 包括完全不需要脚本的纯渲染宿主。
//   用 Lua 的宿主请直接 import `./backends/script-lua/runtime.ts`。
