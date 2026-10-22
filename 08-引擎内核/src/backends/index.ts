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

export { NullGraphicsDevice, nullGfxBackend } from "./gfx-null/device.ts";
export type { NullFrameRecord, NullDrawRecord } from "./gfx-null/device.ts";
export { NullAudioDevice, nullAudioBackend } from "./audio-null/device.ts";
export type { PlayRecord } from "./audio-null/device.ts";
export { NullInputDevice, nullInputBackend } from "./input-null/device.ts";
export { MemoryFileSystem, memFsBackend } from "./fs-memory/fs.ts";

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
}
