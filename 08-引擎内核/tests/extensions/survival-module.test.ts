/**
 * L4 · 生存驱动：按 tick 掉饱食、饿着掉血、饿死只回调
 *
 * ★ 四条最容易写成假绿的：
 *   ① "每 30 tick 掉 1 点"必须从 tick=1 数起：把 tick 0 也算进去的实现，
 *      在"跑 30 tick"的判据下会掉 **2** 点。所以判据要同时断言 30 与 31。
 *   ② "饿着掉血"要有一条"没装血量组件"的语料 —— 否则把 `damage()` 的失败
 *      吞掉的实现照样绿，而症状是"这口箱子在掉血"。
 *   ③ "饿死不销毁节点"要**断言节点还在**：只验 `starveDeaths === 1` 的话，
 *      顺手 destroy 的实现也是绿的，而玩家一饿死背包就跟着消失。
 *   ④ 统计里的 `starving` 是**当前**值不是累计值，必须有一条"救回来之后归零"的判据。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { HUNGER_TYPE, makeHunger, registerHungerComponent, type Hunger } from "../../src/extensions/survival/hunger.ts";
import { createSurvivalModule } from "../../src/extensions/survival/survival-module.ts";

function mkScene(): Scene {
  const reg = new ComponentRegistry();
  registerHungerComponent(reg);
  registerHealthComponent(reg);
  return new Scene("surv", reg);
}

function makeCtx(scene: Scene): ModuleContext {
  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "test");
  return {
    log: {
      channel: () => ({ warn: () => undefined, error: () => undefined, info: () => undefined, debug: () => undefined }),
    } as never,
    events: { emit: () => undefined, on: () => () => undefined } as never,
    services,
    platform: {} as never,
    random: { next: () => 0 } as never,
    module: () => undefined,
  } as unknown as ModuleContext;
}

function mkHero(scene: Scene, hungerStart: number, hp: number | null = 10): number {
  const n = scene.spawnAt("hero", 5.5, 5.5);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  scene.flush();
  const id = n.value.id;
  if (hp !== null) {
    const h = new Health();
    h.hp = hp;
    h.maxHp = 10;
    scene.attach(id, () => h);
    scene.flush();
  }
  makeHunger(scene, id, 100, hungerStart);
  return id;
}

function hungerOf(scene: Scene, id: number): number {
  const h = scene.find(id)?.get<Hunger>(HUNGER_TYPE);
  return h?.value ?? -1;
}

function makeModule(scene: Scene, opts: Parameters<typeof createSurvivalModule>[0] = {}) {
  const mod = createSurvivalModule(opts);
  // `init` 的返回类型是 `ModuleHookResult`（`void | Result`）：成功时允许返回 void
  const r = mod.init(makeCtx(scene)) as { ok: boolean } | undefined;
  assert.notEqual(r?.ok, false, "模块初始化必须同步成功");
  return mod;
}

test("[生存] ★ 衰减从 tick 1 开始：跑 30 tick 掉 1 点，不是 2 点（off-by-one）", () => {
  const scene = mkScene();
  const id = mkHero(scene, 100, 10);
  const mod = makeModule(scene, { decayEveryTicks: 30, starveEveryTicks: 30 });
  for (let t = 1; t <= 30; t++) mod.tick(t);
  assert.equal(hungerOf(scene, id), 99, "1..30 只经过一个 30 的倍数 ⇒ 只掉 1 点");
  mod.tick(31);
  assert.equal(hungerOf(scene, id), 99, "tick 31 不该再掉");
  mod.tick(60);
  assert.equal(hungerOf(scene, id), 98, "tick 60 是第二个倍数");
});

test("[生存] tick 0 不扣（世界刚建好不是一个时间单位的末尾）", () => {
  const scene = mkScene();
  const id = mkHero(scene, 100, 10);
  const mod = makeModule(scene, { decayEveryTicks: 10 });
  mod.tick(0);
  assert.equal(hungerOf(scene, id), 100, "tick 0 必须不扣");
});

test("[生存] 饿着时按 tick 掉血，掉到 0 就回调 onStarveDeath，**节点还在**", () => {
  const scene = mkScene();
  const id = mkHero(scene, 0, 1);
  const starved: number[] = [];
  const deaths: number[] = [];
  const mod = makeModule(scene, {
    decayEveryTicks: 1000,
    starveEveryTicks: 30,
    starveDamage: 1,
    onStarve: (n) => starved.push(n),
    onStarveDeath: (n) => deaths.push(n),
  });
  for (let t = 1; t <= 30; t++) mod.tick(t);
  assert.deepEqual(starved, [id], "tick 30 掉了一次血");
  assert.deepEqual(deaths, [id], "hp 从 1 掉到 0 ⇒ 饿死");
  assert.equal(mod.stats.starveDeaths, 1);
  assert.equal(scene.find(id) !== undefined, true, "饿死不销毁节点（见文件头 ③：世界怎么变是玩法的事）");
  // 死了之后不再继续掉血（damage() 对尸体报错，不该刷一片 errors）
  mod.tick(60);
  assert.equal(mod.stats.starveTicks, 1, "尸体不该再被饿伤，实际多计了");
});

test("[生存] 没装血量组件的实体：只会饿着，永远不会被饿伤", () => {
  const scene = mkScene();
  const id = mkHero(scene, 0, null);
  const mod = makeModule(scene, { starveEveryTicks: 10, starveDamage: 1 });
  for (let t = 1; t <= 100; t++) mod.tick(t);
  assert.equal(mod.stats.starveTicks, 0, "没有 combat.health 就不该被饿伤");
  assert.equal(mod.stats.starving, 1, "但它确实在饿着");
  assert.equal(scene.find(id) !== undefined, true);
});

test("[生存] `starving` 是**当前**值：救回来之后归零", () => {
  const scene = mkScene();
  const id = mkHero(scene, 1, 10);
  const mod = makeModule(scene, { decayEveryTicks: 10 });
  for (let t = 1; t <= 10; t++) mod.tick(t);
  assert.equal(mod.stats.starving, 1, "掉到 0 ⇒ 在饿着");
  const h = scene.find(id)?.get<Hunger>(HUNGER_TYPE);
  assert.ok(h !== undefined);
  if (h !== undefined) h.value = 50;
  mod.tick(11);
  assert.equal(mod.stats.starving, 0, "吃回来之后必须归零（累计值会一直是 1）");
  assert.equal(mod.stats.tracked, 1);
});

test("[生存] 构造参数非法直接抛 RangeError（不静默用默认值）", () => {
  for (const opts of [{ decayEveryTicks: 0 }, { starveEveryTicks: -1 }, { starveDamage: 1.5 }]) {
    assert.throws(() => createSurvivalModule(opts), RangeError, `参数 ${JSON.stringify(opts)} 应抛错`);
  }
});

test("[生存] 没 init 就 tick：不炸、也不动世界", () => {
  const scene = mkScene();
  const id = mkHero(scene, 100, 10);
  const mod = createSurvivalModule({ decayEveryTicks: 1 });
  mod.tick(1);
  assert.equal(hungerOf(scene, id), 100);
  assert.equal(mod.stats.tracked, 0);
});
