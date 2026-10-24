/**
 * L4 · 玩家移动控制（输入映射 → 位置）
 *
 * ★ 为什么它必须从宿主下沉成模块：这段代码在 `browser-entry.ts` 里待了很久，
 *   于是**任何**要"能走的玩家"的宿主（浏览器 / headless 判据 / 编辑器 PIE）都得抄一遍 ——
 *   而抄的那份一定会在某天与主份分叉（"为什么编辑器里能斜着走，游戏里不能"）。
 *   下沉的判据不是"代码看着像库"，而是"**第二个宿主需要它**"。
 *
 * ★★ 两条容易写错、且**画面上看不出来**的语义：
 *   ① **对角线要归一化**：不归一化时斜走比直走快 √2 倍（41%），玩家能感觉到"斜着跑更快"，
 *      但没有任何数值会报错；
 *   ② **一个 tick 只 poll 一次**：一帧可能跑多个固定步，poll 会**消费**按下/松开边缘。
 *      多 poll 一次就会吞掉"按下"事件 —— 表现为"按一下没反应"或"点一下走两步"。
 *      所以 `lastTick` 去重不是优化，是正确性。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";
import type { IModule, ModuleContext } from "../../core/module/module.ts";
import type { InputSnapshot } from "../../platform/input/device.ts";
import { Services } from "../../core/tokens.ts";
import { DEFAULT_INPUT_MAP, type InputMap } from "./input-map.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { Scene } from "../../core/scene/scene.ts";

/** 玩家控制器组件类型。 */
export const CONTROLLER_TYPE = "game.controller";

export class PlayerController extends Component {
  /** 每秒移动多少个世界单位。 */
  speed = 4.5;
  /** 去重用的"上次 poll 是哪个 tick"（不进 schema：它是运行期状态，不该进存档）。 */
  lastTick = -1;
  snapshot: InputSnapshot | null = null;

  readonly schema: ComponentSchema = {
    type: CONTROLLER_TYPE,
    fields: { speed: FieldType.Float },
  };
}

export function registerControllerComponent(registry: { has(t: string): boolean; register(s: ComponentSchema, f: () => Component): void }): void {
  if (!registry.has(CONTROLLER_TYPE)) registry.register(SCHEMA, () => new PlayerController());
}

const SCHEMA: ComponentSchema = { type: CONTROLLER_TYPE, fields: { speed: FieldType.Float } };

/**
 * 从**映射表**读方向（未归一化）。
 *
 * ★ 这个函数原来直接判 `keys.has("KeyA") || keys.has("ArrowLeft")` —— 键位写死在代码里。
 *   现在键位在 `InputMap` 里，这里只认动作名（`move_left` / `move_right` / …）。
 *   "同一方向按两个键应该是 1 不是 2"这条语义由 `axis()` 保证（不是把两个键加起来）。
 */
export function directionFromMap(map: InputMap, snap: InputSnapshot): { dx: number; dz: number } {
  return {
    dx: map.axis(snap, "move_left", "move_right"),
    dz: map.axis(snap, "move_back", "move_forward"),
  };
}

/** 默认键位的快捷方式（等价于 `directionFromMap(DEFAULT_INPUT_MAP, …)`）。 */
export function directionFromKeys(keys: ReadonlySet<string>): { dx: number; dz: number } {
  return directionFromMap(DEFAULT_INPUT_MAP, {
    keysDown: keys,
    keysPressed: EMPTY_KEYS,
    keysReleased: EMPTY_KEYS,
    pointer: { x: 0, y: 0, down: false, pressed: false, released: false, button: 0 },
    wheel: { dx: 0, dy: 0 },
    text: "",
  });
}

const EMPTY_KEYS: ReadonlySet<string> = new Set<string>();

/**
 * 把"这一 tick 的输入"换算成位移。
 *
 * ★ 对角线归一化在这里做（不是调用方）：漏掉它的症状是"斜着走 41% 快"，
 *   而所有位置判据都会通过 —— 只有"走同样时间、位移长度相同"这条能抓。
 */
export function stepOf(
  snap: InputSnapshot,
  speed: number,
  dt: number,
  map: InputMap = DEFAULT_INPUT_MAP,
): { dx: number; dz: number } {
  const d = directionFromMap(map, snap);
  const len = Math.hypot(d.dx, d.dz);
  if (len === 0) return { dx: 0, dz: 0 };
  return { dx: (d.dx / len) * speed * dt, dz: (d.dz / len) * speed * dt };
}

export interface ControllerModuleOptions {
  /** 拉一次输入（由宿主交进来：模块不该知道平台）。 */
  readonly poll: () => InputSnapshot;
  /** 动作名 → 键位。缺省用 `DEFAULT_INPUT_MAP`（改键从"换一张表"开始，而不是改代码）。 */
  readonly map?: InputMap;
  readonly id?: string;
}

export interface ControllerModuleHandle extends IModule {
  /**
   * 由宿主在固定步回调里调用（**模块不会被框架自动 update**，见 `browser-entry`）。
   * ★ 一个 tick 只 poll 一次：`poll()` 会消费按下/松开边缘，多调就吞掉"按下"。
   */
  update(tick: number, dt: number): void;
  /** 最近一次驱动过的控制器数（诊断）。 */
  readonly driven: number;
  /**
   * 这一 tick 的输入快照（**已经 poll 过的那一份**）。
   *
   * ★ 存在的理由：宿主也要读输入（存档 / 采集 / 改键界面），而 `poll()` 会消费边缘事件。
   *   让宿主再 poll 一次，就会把"刚按下"吞掉 —— 那正是 M168 那个 bug 的另一种写法。
   *   所以宿主只能读这份，不能自己 poll。
   */
  readonly snapshot: InputSnapshot;
  /** 正在用的映射表（宿主要读动作时不另建一份）。 */
  readonly map: InputMap;
}

/**
 * 模块：每个 tick 把输入喂给**所有**带 `game.controller` 的节点。
 *
 * ★ 为什么是"所有"而不是"当前玩家"：单机 demo 里只有一个，但编辑器 PIE、
 *   回放、以及"两个玩家共用一台机器"都会用到。代价是每 tick 一次组件遍历
 *   （`componentsOf` 是数组遍历，2000 实体规模下可忽略）。
 */
export function createControllerModule(opts: ControllerModuleOptions): ControllerModuleHandle {
  let scene: Scene | null = null;
  let driven = 0;
  let lastTick = -1;
  const map = opts.map ?? DEFAULT_INPUT_MAP;
  /** 首次 poll 之前的空快照：宿主读它也不该崩，且"什么都没按"是诚实的初始值。 */
  let snapshot: InputSnapshot = {
    keysDown: EMPTY_KEYS,
    keysPressed: EMPTY_KEYS,
    keysReleased: EMPTY_KEYS,
    pointer: { x: 0, y: 0, down: false, pressed: false, released: false, button: 0 },
    wheel: { dx: 0, dy: 0 },
    text: "",
  };

  const mod: ControllerModuleHandle = {
    id: opts.id ?? "game.controller",
    get driven(): number {
      return driven;
    },
    get snapshot(): InputSnapshot {
      return snapshot;
    },
    get map(): InputMap {
      return map;
    },
    init(ctx: ModuleContext): Result<void, EngineError> {
      const got = ctx.services.get(Services.Scene);
      if (got === undefined) {
        return err(engineError("CONTROLLER.NO_SCENE", "控制器模块需要一个 Scene（先注册 Services.Scene）"));
      }
      scene = got;
      return ok(undefined);
    },
    update(tick: number, dt: number): void {
      const s = scene;
      if (s === null) return;
      // ★ 一个 tick 只 poll 一次：poll 会消费边缘事件，多调一次就吞掉"按下"
      if (tick === lastTick) return;
      lastTick = tick;
      snapshot = opts.poll();
      let n = 0;
      for (const c of s.componentsOf<PlayerController>(CONTROLLER_TYPE)) {
        const node = c.node;
        if (node === null) continue;
        const step = stepOf(snapshot, c.speed, dt, map);
        if (step.dx !== 0 || step.dz !== 0) {
          node.setLocalPosition(node.localPosition.x + step.dx, node.localPosition.y + step.dz);
        }
        n++;
      }
      driven = n;
    },
    describe(): string {
      return `控制器：每 tick 驱动 ${String(driven)} 个玩家`;
    },
  };
  return mod;
}
