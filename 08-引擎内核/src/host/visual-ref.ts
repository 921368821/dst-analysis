/**
 * 插值器的**晚绑定**句柄（批169）
 *
 * ★★ 它存在的唯一理由是「渲染模块建得比会话早」：
 *
 *     bakeAtlas → createRenderModule({ visual }) → …（几百行）… → 联机会话
 *
 *   而 `visual` 只有会话建好之后才存在 —— 客户端侧它是
 *   `side.session.visual`（`net-assembly.ts` 透传出来的那个 `Interpolator`），
 *   主机侧和单机则是 `null`。`RenderModuleOptions.visual` 是构造参数，
 *   渲染模块又不能在联机接线之后再建一遍（图集、纹理、管线全在里面）。
 *
 *   于是交给渲染的是一份**恒非 null 的转发壳**：它每帧现读"现在绑的是谁"。
 *
 * ★ 为什么不做成"给渲染模块加一个 `setVisual()`"：
 *   那会让渲染模块多一个**可以在任意时刻改**的状态，而它每一帧都要读；
 *   写错（在帧中间改）不会报错，只会让这一帧的相机与精灵用两套坐标。
 *   转发壳只有一处可写点（`bind`），而调用点在接线处 —— 与 `follow` 闭包同一种做法。
 *
 * ★★ 判据为什么落在这个文件上而不是 `demo-game`：
 *   在 `demo-game` 里它只是三行接线，而起整个演示世界要 wasm + 资产
 *   （见 `tests/host/` 下没有一个 "boot 整个 demo" 的判据）。
 *   把"转发对不对"抽成纯函数，判据就能只花几毫秒 —— 这是仓库那条
 *   「玩法判断抽成纯函数 + Node 判据」的同一个做法。
 */

import type { VisualSmoothing } from "../extensions/render/render-module.ts";

export interface VisualRef {
  /**
   * 交给 `createRenderModule({ visual })` 的那一份。**恒非 null**：
   * `null` 的含义是"每条精灵都按节点真实坐标画"，而这个壳在未绑定时行为与它相同。
   */
  readonly visual: VisualSmoothing;
  /** 绑定（`null` = 拆掉，回到"按节点真实坐标画"）。 */
  bind(next: VisualSmoothing | null): void;
  /** 现在绑的是谁。诊断与判据用；渲染层不该读它。 */
  bound(): VisualSmoothing | null;
}

export function createVisualRef(): VisualRef {
  let cur: VisualSmoothing | null = null;
  return {
    visual: {
      beginFrame: (dtMs: number): void => {
        // ★ 用 `if` 而不是 `cur?.beginFrame(dtMs)`：两者等价，但这里要让
        //   "未绑定 = 什么都不发生"在**读代码时**就成立（`?.` 容易被看漏成"总是调用"）。
        if (cur !== null) cur.beginFrame(dtMs);
      },
      at: (nodeId: number) => (cur === null ? null : cur.at(nodeId)),
    },
    bind: (next: VisualSmoothing | null): void => {
      cur = next;
    },
    bound: (): VisualSmoothing | null => cur,
  };
}
