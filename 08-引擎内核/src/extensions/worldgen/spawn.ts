/**
 * L4 · 出生：把 `pickSpawn(plan)` 的结果**落到场景里**
 *
 * ★ 为什么单独一个文件：`pickSpawn` 只回答"哪一格最适合开局"（纯函数、可单测），
 *   而"玩家从哪出现"是**场景侧**的事 —— 要不要建节点、挂什么组件、命名规则是什么、
 *   重复调用怎么办。把两者混在一起，`pickSpawn` 的判据就得先造一个场景才能跑，
 *   而"选错格"和"落地错位"是两种完全不同的失效。
 *
 * ★ 坐标：**格子中心**，即 `cx * 256 + 128`。理由与资源投放同一个：
 *   `256` 是定点单位（2 的幂），`(cx + 0.5) * 256` 在二进制浮点里**无舍入**，
 *   于是 `position.x * 256 === cx * 256 + 128` 是恒等式，存档往返不会漂。
 *   用格子左上角的话，玩家会永久贴着格子的左边缘站 —— 看起来像"永远差半步"。
 *
 * ★ 重复出生报错而不是静默再建一个：两套"玩家"叠在一起的表现是
 *   输入被两个控制器同时改位置，而两边的判据各自都绿。
 */

import { Component, FieldType, type ComponentRegistry, type ComponentSchema } from "../../core/scene/component.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { SPRITE_TYPE, Sprite } from "../render/sprite.ts";
import { FIXED_UNITS, pickSpawn, type WorldPlan } from "./worldgen.ts";

/** 场景里代表"玩家"的标记组件。 */
export const PLAYER_TYPE = "world.player";
/** 玩家精灵用的帧名（程序化图集里那一帧就叫这个名字）。 */
export const PLAYER_FRAME = "player";
/** 组件注册表里没有 `render.sprite`（渲染模块没启动 / 没注册）。 */
export const SPAWN_NO_SPRITE_COMPONENT = "SPAWN.NO_SPRITE_COMPONENT";
/** 场景里已经有玩家了。 */
export const SPAWN_ALREADY_SPAWNED = "SPAWN.ALREADY_SPAWNED";

export const PLAYER_SCHEMA: ComponentSchema = {
  type: PLAYER_TYPE,
  fields: {
    /** 出生格（升序下标）。玩家走开之后这个字段仍然是"他是从哪开始的"。 */
    cell: FieldType.Int,
  },
};

export class PlayerSpawn extends Component {
  readonly schema: ComponentSchema = PLAYER_SCHEMA;
  cell = 0;
}

export function registerPlayerComponent(registry: ComponentRegistry): void {
  if (!registry.has(PLAYER_TYPE)) registry.register(PLAYER_SCHEMA, () => new PlayerSpawn());
}

export interface PlayerHandle {
  readonly nodeId: number;
  readonly cell: number;
  /** 定点坐标（×256 之后是整数）。 */
  readonly x: number;
  readonly z: number;
}

/**
 * 在场景里造出玩家节点。返回节点 id 与出生格。
 *
 * 调用方要保证 `registerWorldComponents` / `registerPlayerComponent` /
 * `render.sprite` 都注册过 —— 缺一就报错，不静默挂半个玩家。
 */
export function spawnPlayer(scene: Scene, plan: WorldPlan): Result<PlayerHandle, EngineError> {
  if (!scene.components.has(SPRITE_TYPE)) {
    return err(
      engineError(
        SPAWN_NO_SPRITE_COMPONENT,
        "组件类型 render.sprite 未注册 —— 玩家会没有身体（渲染模块启动时会注册）",
      ),
    );
  }
  if (!scene.components.has(PLAYER_TYPE)) {
    return err(
      engineError(SPAWN_NO_SPRITE_COMPONENT, "组件类型 world.player 未注册 —— 先 registerPlayerComponent(...)"),
    );
  }
  const existing = [...scene.componentsOf<PlayerSpawn>(PLAYER_TYPE)];
  if (existing.length > 0) {
    return err(
      engineError(SPAWN_ALREADY_SPAWNED, "场景里已经有玩家了 —— 重复出生会让两个控制器抢同一个位置"),
    );
  }

  const pick = pickSpawn(plan);
  if (!pick.ok) return pick;

  const sp = pick.value;
  // 坐标直接给出：`sp.x / 256` 在二进制浮点里**无舍入**（256 是 2 的幂），
  // 所以 spawn 之后 `position.x * 256 === sp.x` 是恒等式，不需要事后校正。
  const made = scene.spawnAt("player", sp.x / FIXED_UNITS, sp.z / FIXED_UNITS);
  if (!made.ok) return made;
  const nodeId = made.value.id;
  scene.attach(nodeId, () => {
    const s = new Sprite();
    s.frame = PLAYER_FRAME;
    s.width = 1;
    s.height = 1;
    // 脚踩地面：底边贴住他站的那一格
    s.pivotY = 0;
    return s;
  });
  scene.attach(nodeId, () => {
    const marker = new PlayerSpawn();
    marker.cell = sp.cell;
    return marker;
  });
  scene.flush();

  return ok({ nodeId, cell: sp.cell, x: sp.x, z: sp.z });
}
