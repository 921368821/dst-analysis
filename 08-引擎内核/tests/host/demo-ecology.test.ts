/**
 * L4 · 演示生态：**地图上永远还有猎物可打**（批126）
 *
 * ★★ 这条判据为什么必须存在：它不是"某个函数算得对"，而是**世界的性质**。
 *   症状是"玩了半分钟之后没事可做"，而那一刻所有计数都正常（10 只兔子出生、
 *   10 只被杀、战利品 20 块肉）。没有一条判据看这个性质的话，"猎物再生"这个功能
 *   可以完全坏掉（`pickCell` 永远返回 -1）而全绿 —— 因为"兔子数"在头 10 秒里
 *   本来就在往下掉，掉到 0 之后没有任何断言会响。
 *
 * ★ 两个方向都要读（这是本文件最重要的结构）：
 *   · **不给再生 ⇒ 一定灭绝**：否则下面那条"给了就一直在"可能只是因为
 *     猎狗压根没打中几只（夹具太弱，判据在验一个不发生的事）；
 *   · **给了再生 ⇒ 一拍都不空**：而且必须**同时**看到 `kills` 在涨、
 *     `respawned` 在涨 —— 只看"兔子还在"的话，"猎狗根本杀不死东西"
 *     与"再生很健康"分不开。
 *
 * ★ 配表从 `host/demo-mobs.ts` 读，不抄数字：抄一份的第二份必然漂移，
 *   于是"生态正常"永远绿（详见那个文件的 ★★）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";
import { registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { registerFacingComponent } from "../../src/extensions/motion/facing.ts";
import { registerDirSpriteComponent } from "../../src/extensions/render/dir-sprite.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { registerInventoryComponents } from "../../src/extensions/inventory/inventory.ts";
import { registerLootComponent } from "../../src/extensions/combat/loot.ts";
import { SpatialHashWorld, makeSceneAccessor } from "../../src/extensions/physics/physics.ts";
import { createMobWorldModule, type MobWorldHandle } from "../../src/extensions/mobs/mob-world.ts";
import {
  DEMO_HOUNDS,
  DEMO_MOB_TEMPLATES,
  DEMO_PREY_RESPAWN,
  DEMO_RABBITS,
  createDemoFactions,
  pickDemoMobSpots,
} from "../../src/host/demo-mobs.ts";
import { pickPreyCellAround } from "../../src/host/prey-respawn.ts";

/** 与宿主同一个种子与尺寸（`browser-entry.ts` 的 `WORLD_SEED` / `WORLD_W` / `WORLD_H`）。 */
const SEED = 20261023;
const W = 32;
const H = 24;

function mkScene(): Scene {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  registerFacingComponent(reg);
  registerDirSpriteComponent(reg);
  registerInventoryComponents(reg);
  registerLootComponent(reg);
  if (!reg.has("render.sprite")) reg.register(new Sprite().schema, () => new Sprite());
  return new Scene("eco", reg);
}

function mkCtx(scene: Scene): ModuleContext {
  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "test");
  return {
    log: {
      channel: () => ({ warn: () => undefined, error: () => undefined, info: () => undefined, debug: () => undefined }),
    },
    events: { emit: () => undefined, on: () => () => undefined },
    services,
    platform: {},
    random: { next: () => 0 },
    module: () => undefined,
  } as unknown as ModuleContext;
}

function mkPhysics(scene: Scene): SpatialHashWorld {
  return new SpatialHashWorld(
    makeSceneAccessor((id) => {
      const n = scene.find(id);
      if (n === undefined) return undefined;
      return {
        id: n.id,
        worldPosition: () => n.worldPosition,
        setLocalPosition: (x: number, y: number) => n.setLocalPosition(x, y),
      };
    }),
  );
}

interface Run {
  readonly mod: MobWorldHandle;
  readonly scene: Scene;
  readonly grid: NavGrid;
  readonly playerCell: number;
}

function buildWorld(useRespawn: boolean): Run {
  const scene = mkScene();
  const gen = generateWorld({ seed: SEED, width: W, height: H, maxSitesPerCell: 0 });
  assert.equal(gen.ok, true, gen.ok ? "" : gen.error.code);
  if (!gen.ok) throw new Error("unreachable");
  const gr = NavGrid.fromPlan(gen.value);
  assert.equal(gr.ok, true);
  if (!gr.ok) throw new Error("unreachable");
  const grid = gr.value;
  // 玩家站在世界中心附近的可走格（与宿主同一个量级）
  let playerCell = -1;
  for (let i = 0; i < grid.total; i++) {
    if (!grid.isWalkableIndex(i)) continue;
    const d = Math.hypot(grid.cellX(i) - W / 2, grid.cellZ(i) - H / 2);
    if (d < 3) {
      playerCell = i;
      break;
    }
  }
  assert.ok(playerCell >= 0, "世界里要有中心附近的可走格");

  const physics = mkPhysics(scene);
  const spots = pickDemoMobSpots(grid, DEMO_HOUNDS, DEMO_RABBITS, playerCell);
  assert.equal(spots.length, DEMO_HOUNDS + DEMO_RABBITS, "出生点要够");

  const cfg = {
    minCells: DEMO_PREY_RESPAWN.minCells,
    maxCells: DEMO_PREY_RESPAWN.maxCells,
    blockCells: DEMO_PREY_RESPAWN.blockCells,
    seed: SEED,
  };
  let mod: MobWorldHandle | null = null;
  const handle = createMobWorldModule({
    grid,
    factions: createDemoFactions(),
    templates: DEMO_MOB_TEMPLATES,
    spots,
    range: 14,
    seed: SEED,
    wanderEvery: 18,
    threatDecayTicks: 150,
    aggroCells: 16,
    physics,
    ...(useRespawn
      ? {
          respawn: {
            everyTicks: DEMO_PREY_RESPAWN.everyTicks,
            kind: DEMO_PREY_RESPAWN.kind,
            max: DEMO_PREY_RESPAWN.max,
            template: DEMO_PREY_RESPAWN.template,
            pickCell: (tick: number): number => {
              // 与宿主同一条路：先收集活物的格，再交给纯函数
              const m = mod;
              if (m === null) return -1;
              const live: number[] = [];
              for (const id of m.nodeIds) {
                const n = scene.find(id);
                if (n === undefined) continue;
                const c = grid.cellAt(n.worldPosition.x, n.worldPosition.y);
                if (c >= 0) live.push(c);
              }
              return pickPreyCellAround(grid, playerCell, live, tick, cfg);
            },
          },
        }
      : {}),
  });
  const r = handle.init(mkCtx(scene)) as { ok: boolean } | undefined;
  assert.equal(r?.ok, true, "模块初始化必须同步成功");
  mod = handle;
  return { mod: handle, scene, grid, playerCell };
}

const preyCount = (mod: MobWorldHandle): number => mod.nodeIds.filter((id) => mod.templateOf(id) === "rabbit").length;

test("★★★ 不给再生 ⇒ 兔子会**灭绝**（这是「必须有再生」的证据，也是下面那条的对照）", () => {
  const { mod } = buildWorld(false);
  assert.equal(preyCount(mod), DEMO_RABBITS, `夹具前提：开局 ${String(DEMO_RABBITS)} 只兔子`);
  let zeroAt = -1;
  for (let tick = 0; tick < 900; tick++) {
    mod.update(tick, 1 / 30);
    if (zeroAt < 0 && preyCount(mod) === 0) zeroAt = tick;
  }
  const s = mod.stats;
  // ★ 实测：第 360 拍（12 秒 @30Hz）左右归零，留一倍余量
  assert.ok(zeroAt >= 0, `900 拍内兔子该被打光，实际还剩 ${String(preyCount(mod))} 只（击杀 ${String(s.kills)}）`);
  assert.ok(zeroAt < 700, `归零时间 ${String(zeroAt)} 拍，比实测（360）晚太多 —— 夹具变了？`);
  assert.equal(s.respawned, 0, "没开再生就不该有补充");
  assert.equal(s.kills, DEMO_RABBITS, "十只兔子应该都被吃掉");
});

test("★★★ 给了再生 ⇒ **任何一拍**都有兔子可打，而且真的在杀/真的在补", () => {
  const { mod } = buildWorld(true);
  let minPrey = Number.POSITIVE_INFINITY;
  let maxPrey = 0;
  let zeroTicks = 0;
  const TICKS = 1800;
  for (let tick = 0; tick < TICKS; tick++) {
    mod.update(tick, 1 / 30);
    const p = preyCount(mod);
    if (p < minPrey) minPrey = p;
    if (p > maxPrey) maxPrey = p;
    if (p === 0) zeroTicks++;
  }
  const s = mod.stats;
  // ★ 四个量一起读（少一个就会有一种坏法看起来是绿的）：
  //   ① 一拍都不空 —— 这条要验的性质本身；
  //   ② `kills` 在涨 —— 否则"兔子还在"可能只是猎狗没开打；
  //   ③ `respawned` 在涨 —— 否则"兔子还在"可能只是它们跑得快、没被杀光；
  //   ④ 不超上限 —— 否则"再生"会变成"兔子越打越多"。
  assert.equal(zeroTicks, 0, `${String(TICKS)} 拍里有 ${String(zeroTicks)} 拍地图上没有兔子（最少 ${String(minPrey)} 只）`);
  assert.ok(s.kills >= 15, `猎狗该真的在吃（击杀 ${String(s.kills)}）—— 太少说明夹具没在打，这条就白验了`);
  assert.ok(s.respawned >= 10, `再生该真的在补（补了 ${String(s.respawned)} 只）`);
  assert.ok(maxPrey <= DEMO_PREY_RESPAWN.max, `兔子数 ${String(maxPrey)} 超过上限 ${String(DEMO_PREY_RESPAWN.max)}`);
  assert.ok(minPrey >= 1, `最少也有 ${String(minPrey)} 只`);
  assert.equal(s.lastRespawnError, "", `补兔子不该报错，实际 ${s.lastRespawnError}`);
});
