/**
 * L4 · 战斗的「命中回调」（`onHit`）—— 表现层的唯一输入
 *
 * ★ 为什么它值得单独一个文件：这个回调看起来"小事一桩"，但它有三个只有
 *   在**错的语料**上才会暴露的形状：
 *
 *   ① **只在真的扣到血时回调**。把"射程不够/冷却没好/友军/目标已死"也算成命中，
 *      屏幕上会给打空的一下冒一个伤害数字 —— 玩家最不能容忍的假反馈。
 *      语料要造出这四种失败，且每一次都验"回调次数没涨"。
 *   ② **必须在 `onKill` 之前**。`onKill` 默认会**销毁目标**，
 *      之后的回调里读不到节点位置，伤害数字会冒在世界原点。
 *      判据用一个**调用序列**（`["hit:7", "kill:7"]`）来分辨顺序，
 *      而不是只验"两个都调了"。
 *   ③ **`applied` 是实际扣掉的血，不是 `attacker.damage`**。
 *      血只剩 3 点、伤害 10 时，两者差 7；显示 10 的实现在"一下打死"时看起来最正常。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { registerAttackerComponent, Attacker } from "../../src/extensions/combat/attack.ts";
import { registerHealthComponent, Health } from "../../src/extensions/combat/health.ts";
import { createCombatModule, type HitInfo } from "../../src/extensions/combat/combat-module.ts";

function makeCtx(scene: Scene): ModuleContext {
  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "test");
  return {
    log: { channel: () => ({ warn: () => undefined, error: () => undefined, info: () => undefined, debug: () => undefined }) } as never,
    events: { emit: () => undefined, on: () => () => undefined } as never,
    services,
    platform: {} as never,
    random: { next: () => 0 } as never,
    module: () => undefined,
  } as unknown as ModuleContext;
}

interface Fixture {
  readonly scene: Scene;
  /** 猎物节点 id（判据要拿它拼期望值，**不能猜**：节点 id 由场景分配）。 */
  readonly preyId: number;
  readonly hits: HitInfo[];
  readonly order: string[];
  readonly mod: ReturnType<typeof createCombatModule>;
}

/**
 * 造一对"猎人 + 猎物"。
 * ★ 位置与射程都是**显式**给的：射程够不够是这些判据的变量之一，
 *   让它取决于浮动默认值的话，"射程不够"这条语料会在某次调整后悄悄变成"够"。
 */
function mk(opts: { distance?: number; range?: number; damage?: number; hp?: number; cooldown?: number } = {}): Fixture {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  const scene = new Scene("onhit", reg);
  const distance = opts.distance ?? 1;
  const a = scene.spawnAt("hunter", 0, 0);
  const b = scene.spawnAt("prey", distance, 0);
  assert.equal(a.ok && b.ok, true);
  if (!a.ok || !b.ok) throw new Error("unreachable");
  scene.flush();
  const atk = new Attacker();
  atk.damage = opts.damage ?? 2;
  atk.range = opts.range ?? 3;
  atk.cooldownTicks = opts.cooldown ?? 0;
  assert.ok(scene.attach(a.value.id, () => atk).ok);
  const hp = new Health();
  hp.maxHp = opts.hp ?? 10;
  hp.hp = opts.hp ?? 10;
  assert.ok(scene.attach(b.value.id, () => hp).ok);
  scene.flush();

  const hits: HitInfo[] = [];
  const order: string[] = [];
  const mod = createCombatModule({
    decide: () => b.value.id,
    onHit: (info) => {
      hits.push(info);
      order.push(`hit:${String(info.targetId)}`);
    },
    onKill: (t) => order.push(`kill:${String(t)}`),
  });
  const r = mod.init(makeCtx(scene)) as { ok: boolean } | undefined;
  assert.equal(r?.ok, true);
  return { scene, preyId: b.value.id, hits, order, mod };
}

test("[命中回调] 真扣到血才回调，且带上实际扣血量", () => {
  const f = mk();
  f.mod.update(1, 0.016);
  assert.equal(f.hits.length, 1, "打中了就该回调一次");
  const h = f.hits[0]!;
  assert.equal(h.applied, 2);
  assert.equal(h.before, 10);
  assert.equal(h.after, 8);
  assert.equal(h.dead, false);
  assert.equal(h.tick, 1);
});

test("[命中回调] ★ 射程不够**不回调**（打空的一下不该冒伤害数字）", () => {
  const f = mk({ distance: 5, range: 1 });
  f.mod.update(1, 0.016);
  assert.equal(f.hits.length, 0);
  assert.equal(f.mod.stats.outOfRange, 1, "前提：确实是射程不够");
});

test("[命中回调] ★ 冷却没好**不回调**", () => {
  const f = mk({ cooldown: 10 });
  f.mod.update(1, 0.016);
  assert.equal(f.hits.length, 1, "第一下没有冷却");
  f.mod.update(2, 0.016);
  f.mod.update(3, 0.016);
  assert.equal(f.hits.length, 1, "冷却期间的两次都不该回调");
  assert.equal(f.mod.stats.cooldown, 2, "前提：确实被冷却挡住了");
});

test("[命中回调] ★ 目标已死**不回调**（尸体不再冒数字）", () => {
  const f = mk({ damage: 10, hp: 1 });
  f.mod.update(1, 0.016);
  assert.equal(f.hits.length, 1);
  assert.equal(f.hits[0]?.dead, true);
  // 猎物被打死，但是否销毁由模块决定；把 decide 停掉再跑一次，验证没有额外回调
  f.mod.update(2, 0.016);
  assert.equal(f.hits.length, 1, "只死了一次，不该有第二次回调");
});

test("[命中回调] ★★ 在 onKill **之前**（顺序反了伤害数字会冒在世界原点）", () => {
  const f = mk({ damage: 10, hp: 3 });
  f.mod.update(1, 0.016);
  const want = [`hit:${String(f.preyId)}`, `kill:${String(f.preyId)}`];
  assert.deepEqual(f.order, want, `顺序必须是 命中 → 击杀，实际 ${JSON.stringify(f.order)}`);
});

test("[命中回调] ★ applied 是实际扣血，不是 attacker.damage（溢出要如实报）", () => {
  const f = mk({ damage: 10, hp: 3 });
  f.mod.update(1, 0.016);
  assert.equal(f.hits[0]?.applied, 3, "血只有 3，实际扣 3");
  assert.equal(f.hits[0]?.overkill, 7, "溢出 7 要报出来（不是丢掉）");
  assert.equal(f.hits[0]?.dead, true);
});

test("[命中回调] 不给 onHit 也不炸（回调是可选的）", () => {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  const scene = new Scene("noHooks", reg);
  const a = scene.spawnAt("hunter", 0, 0);
  const b = scene.spawnAt("prey", 1, 0);
  assert.equal(a.ok && b.ok, true);
  if (!a.ok || !b.ok) return;
  scene.flush();
  assert.ok(scene.attach(a.value.id, () => new Attacker()).ok);
  assert.ok(scene.attach(b.value.id, () => new Health()).ok);
  scene.flush();
  const mod = createCombatModule({ decide: () => b.value.id });
  const r = mod.init(makeCtx(scene)) as { ok: boolean } | undefined;
  assert.equal(r?.ok, true);
  mod.update(1, 0.016);
  assert.equal(mod.stats.hits, 1, "命中统计照旧");
});
