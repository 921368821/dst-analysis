/**
 * 跨宿主存档页面的**打包入口**（esbuild 的 entry，不参与 `src/` 的分层）。
 *
 * ★ 为什么单独一个入口，而不是塞进 `browser-entry.ts`：
 *   演示页要画、要跑帧循环、要读资产，慢且脆（它依赖 WebGL 成不成功）。
 *   跨宿主比对只需要"算一份存档"——把判据挂在一个会因为显卡驱动而失败的地方，
 *   是这个项目已经修过一次的老毛病（自检页曾经"从来没启动过"）。
 *   这里只用纯计算，**不碰 canvas / 资产 / 帧循环**，所以它不会因为环境降级而红。
 */

import { buildCrossHostSave, bytesToBase64, crossHostBytes } from "../tests/fixtures/cross-host-save.ts";

interface CrossHostPayload {
  readonly ok: boolean;
  readonly base64?: string;
  readonly bytes?: number;
  readonly nodes?: number;
  readonly resources?: number;
  readonly stacks?: number;
  readonly released?: number;
  readonly error?: string;
}

function run(): CrossHostPayload {
  try {
    const r = buildCrossHostSave();
    const bytes = crossHostBytes(r.json);
    return {
      ok: true,
      base64: bytesToBase64(bytes),
      bytes: bytes.length,
      nodes: r.nodes,
      resources: r.resources,
      stacks: r.stacks,
      released: r.released,
    };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? `${e.name}: ${e.message}` : String(e) };
  }
}

(globalThis as { __crossHost?: CrossHostPayload }).__crossHost = run();
