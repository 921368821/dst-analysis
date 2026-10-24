/**
 * 跨宿主存档的 **Node 侧金标**：把语料跑一遍，把字节以 base64 打到 stdout。
 *
 * ★ 为什么打 base64 而不是直接打 JSON：
 *   ① Windows 控制台代码页会把中文输出改成 `?`（这份语料里**故意有中文名字**），
 *      于是"金标"从源头就被改坏了 —— 而差异会显示成"浏览器不对"，查错方向完全相反；
 *   ② base64 是纯 ASCII，任何管道、任何代码页都不会碰它。
 *
 * 用法：`node --experimental-transform-types tools/cross-host-gold.ts`
 * （由 `tools/cross-host-save.mjs` 调用，一般不用手跑）
 */

import { buildCrossHostSave, bytesToBase64, crossHostBytes } from "../tests/fixtures/cross-host-save.ts";

const r = buildCrossHostSave();
process.stdout.write(
  JSON.stringify({
    base64: bytesToBase64(crossHostBytes(r.json)),
    nodes: r.nodes,
    resources: r.resources,
    stacks: r.stacks,
    released: r.released,
  }),
);
