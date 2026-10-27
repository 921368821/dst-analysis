/**
 * L4 · 生物模板与装配：**校验在装配之前，缺组件就一个节点都不留**
 *
 * ★ 三条最容易写成假绿的：
 *   ① 只验"模板合法能过"是不够的 —— 校验的意义在**拒绝**。每一类非法值都要各验一条，
 *      否则把 `maxHp` 的校验删掉，靠 `damage` 那条照样绿。
 *   ② "没注册组件时不留半成品"要用**节点数**验：只断言 `ok === false` 的话，
 *      留下一个孤儿节点也能过，而那个节点会被渲染/物理/AI 全部看见。
 *   ③ `damage: 0`（和平生物）必须**单独**验：把"damage 必须是正整数"和
 *      "0 表示和平"混成一条断言，等于两条都没验。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ATTACKER_TYPE, registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { FACTION_TYPE, registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { HEALTH_TYPE, Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { MOVER_TYPE, registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { registerFacingComponent } from "../../src/extensions/motion/facing.ts";
import { SPRITE_TYPE, Sprite } from "../../src/extensions/render/sprite.ts";
import { MOB_BAD_TEMPLATE, validateTemplate } from "../../src/extensions/mobs/mob-template.ts";
import { MOB_SPAWN_FAILED, spawnMob, spawnMobs } from "../../src/extensions/mobs/spawn-mob.ts";

const RABBIT = {
  kind: "rabbit",
  frame: "rabbit",
  width: 0.8,
  height: 0.8,
  radius: 0.3,
  maxHp: 4,
  damage: 0,
  range: 1.4,
  cooldownTicks: 20,
  speed: 1.8,
  team: "prey",
  loot: [{ kind: "meat", count: 2 }],
};

const HOUND = {
  ...RABBIT,
  kind: "hound",
  frame: "hound",
  maxHp: 8,
  damage: 2,
  range: 1.6,
  speed: 2.4,
  team: "hunter",
  loot: [{ kind: "hide", count: 1 }],
};

function fullRegistry(): ComponentRegistry {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  registerFacingComponent(reg);
  if (!reg.has(SPRITE_TYPE)) reg.register(new Sprite().schema, () => new Sprite());
  return reg;
}

function mkScene(reg = fullRegistry()): Scene {
  return new Scene("mob", reg);
}

function countNodes(scene: Scene): number {
  let n = 0;
  scene.root.walk(() => {
    n++;
  });
  return n;
}

// ---------------------------------------------------------------- 模板校验

test("[生物·模板] 合法模板原样保留，战利品表被规整成升序", () => {
  const r = validateTemplate({ ...RABBIT, loot: [{ kind: "meat", count: 2 }, { kind: "bone", count: 1 }] });
  assert.equal(r.ok, true, r.ok ? "" : r.error.message);
  if (!r.ok) return;
  assert.equal(r.value.kind, "rabbit");
  assert.equal(r.value.maxHp, 4);
  assert.equal(r.value.speed, 1.8);
  assert.equal(r.value.team, "prey");
  assert.deepEqual(
    r.value.loot.map((l) => `${l.kind}x${String(l.count)}`),
    ["bonex1", "meatx2"],
    "模板里的战利品表要按 kind 升序（与 grantLoot 同一套规则）",
  );
});

test("[生物·模板] 拒绝：kind / frame 为空 —— 且 detail 指名字段", () => {
  for (const [patch, field] of [
    [{ kind: "" }, "kind"],
    [{ frame: "" }, "frame"],
  ] as const) {
    const r = validateTemplate({ ...RABBIT, ...patch });
    assert.equal(r.ok, false, `${field} 为空必须拒绝`);
    if (r.ok) continue;
    assert.equal(r.error.code, MOB_BAD_TEMPLATE);
    assert.equal((r.error.detail as { field?: string }).field, field, "报错要点名是哪个字段");
  }
});

test("[生物·模板] 拒绝：maxHp 为 0 / 小数 / NaN", () => {
  for (const v of [0, 1.5, Number.NaN, -3]) {
    const r = validateTemplate({ ...RABBIT, maxHp: v });
    assert.equal(r.ok, false, `maxHp=${String(v)} 必须拒绝（0 血的生物一出生就是尸体）`);
  }
});

test("[生物·模板] damage：`0` 合法（和平生物），负数/小数非法", () => {
  const zero = validateTemplate({ ...RABBIT, damage: 0 });
  assert.equal(zero.ok, true, "0 = 和平生物，不能当成非法值");
  assert.equal(zero.ok ? zero.value.damage : -1, 0);
  for (const v of [-1, 0.5]) {
    assert.equal(validateTemplate({ ...RABBIT, damage: v }).ok, false, `damage=${String(v)} 必须拒绝`);
  }
});

test("[生物·模板] 拒绝：range / speed / radius / width / height 非正", () => {
  for (const field of ["range", "speed", "radius", "width", "height"] as const) {
    for (const v of [0, -1, Number.POSITIVE_INFINITY]) {
      const r = validateTemplate({ ...RABBIT, [field]: v });
      assert.equal(r.ok, false, `${field}=${String(v)} 必须拒绝`);
    }
  }
});

test("[生物·模板] cooldownTicks 必须是 >= 0 的整数（0 合法）", () => {
  assert.equal(validateTemplate({ ...RABBIT, cooldownTicks: 0 }).ok, true, "0 = 每 tick 都能打");
  for (const v of [-1, 1.5]) {
    assert.equal(validateTemplate({ ...RABBIT, cooldownTicks: v }).ok, false, `cooldownTicks=${String(v)}`);
  }
});

test("[生物·模板] team：空串合法（中立），纯空白非法（看不见的差异）", () => {
  assert.equal(validateTemplate({ ...RABBIT, team: "" }).ok, true, "空串 = 中立");
  const blank = validateTemplate({ ...RABBIT, team: "   " });
  assert.equal(blank.ok, false, "纯空白与空串在人眼里没区别，必须拒绝");
  assert.equal(blank.ok ? "" : (blank.error.detail as { field?: string }).field, "team");
});

test("[生物·模板] 战利品表非法时，错误里带 field=loot（而不是笼统的模板错）", () => {
  const r = validateTemplate({ ...RABBIT, loot: [{ kind: "meat", count: 0 }] });
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : (r.error.detail as { field?: string }).field, "loot");
  assert.equal(validateTemplate({ ...RABBIT, loot: [] }).ok, true, "空表 = 什么都不掉");
});

// ---------------------------------------------------------------- 装配

test("[生物·装配] 五个组件都挂上，坐标就是传入的坐标", () => {
  const scene = mkScene();
  const r = spawnMob(scene, HOUND, 3.5, 2.5, { name: "hound#0" });
  assert.equal(r.ok, true, r.ok ? "" : r.error.message);
  if (!r.ok) return;
  const n = scene.find(r.value.nodeId);
  assert.ok(n !== undefined);
  assert.equal(n.name, "hound#0");
  assert.equal(n.worldPosition.x, 3.5);
  assert.equal(n.worldPosition.y, 2.5);
  for (const t of [SPRITE_TYPE, HEALTH_TYPE, ATTACKER_TYPE, MOVER_TYPE, FACTION_TYPE]) {
    assert.notEqual(n.get(t), undefined, `${t} 必须挂上`);
  }
  const hp = n.get<Health>(HEALTH_TYPE);
  assert.equal(hp?.hp, 8);
  assert.equal(hp?.maxHp, 8, "出生时 hp 必须等于 maxHp");
});

test("[生物·装配] `damage: 0` 的生物**没有**攻击组件（和平生物）", () => {
  const scene = mkScene();
  const r = spawnMob(scene, RABBIT, 1.5, 1.5);
  assert.equal(r.ok, true, r.ok ? "" : r.error.message);
  if (!r.ok) return;
  assert.equal(r.value.attacker, null, "handle 要如实说它没有攻击");
  assert.equal(scene.find(r.value.nodeId)?.get(ATTACKER_TYPE), undefined, "组件层面也不能有");
  assert.equal(scene.find(r.value.nodeId)?.get(FACTION_TYPE)?.type, FACTION_TYPE, "阵营组件仍然要挂");
});

test("[生物·装配] 组件没注册：报 MOB_SPAWN_FAILED，且**一个节点都不留**", () => {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  // 故意不注册 sprite
  const scene = mkScene(reg);
  const before = countNodes(scene);
  const r = spawnMob(scene, HOUND, 1.5, 1.5);
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, MOB_SPAWN_FAILED);
  assert.equal((r.ok ? {} : (r.error.detail as { type?: string })).type, SPRITE_TYPE, "要点名缺的是哪个");
  assert.equal(countNodes(scene), before, "失败的装配不能留下孤儿节点（它会被渲染/物理/AI 全部看见）");
});

test("[生物·装配] 模板非法：**一个节点都不建**（校验在装配之前）", () => {
  const scene = mkScene();
  const before = countNodes(scene);
  const r = spawnMob(scene, { ...RABBIT, maxHp: 0 }, 1.5, 1.5);
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, MOB_BAD_TEMPLATE);
  assert.equal(countNodes(scene), before);
});

test("[生物·装配] 批量：名字带序号、id 互不相同", () => {
  const scene = mkScene();
  const spots = [0, 1, 2].map((i) => ({ x: 1.5 + i, z: 1.5 }));
  const r = spawnMobs(scene, RABBIT, spots, { namePrefix: "rabbit" });
  assert.equal(r.ok, true, r.ok ? "" : r.error.message);
  if (!r.ok) return;
  assert.deepEqual(
    r.value.map((m) => scene.find(m.nodeId)?.name),
    ["rabbit#0", "rabbit#1", "rabbit#2"],
  );
  assert.equal(new Set(r.value.map((m) => m.nodeId)).size, 3);
});
