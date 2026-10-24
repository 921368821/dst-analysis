/**
 * L4 · 阵营与友伤：别砍自己人，但**别把"没编队"当成免战牌**
 *
 * ★ 三条最容易写成假绿的：
 *   ① 只验"同队被拦"是不够的 —— 把判定写成"只要两方**任意一方**有阵营就拦"
 *      也能过。所以要再验"不同队能打"与"中立能打"。
 *   ② 关系表**对称**必须单独验：只写一边的实现在"正向那一击"上完全正常，
 *      错误只在"它不还手"时暴露。
 *   ③ "中立能打"这一条不是可有可无：若漏了它，"没配阵营的怪打不动"
 *      会让所有新加的怪变成靶子都不会还手的木桩，而错误码是 `FRIENDLY_FIRE`
 *      —— 看起来像"关系配错了"，实际是"关系表管了不该管的范围"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { HEALTH_TYPE, Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import {
  ATTACKER_TYPE,
  Attacker,
  COMBAT_FRIENDLY_FIRE,
  COMBAT_OUT_OF_RANGE,
  attack,
  registerAttackerComponent,
} from "../../src/extensions/combat/attack.ts";
import {
  FACTION_BAD_INPUT,
  FactionMember,
  createFactions,
  registerFactionComponent,
  teamOf,
} from "../../src/extensions/combat/faction.ts";
import { createCombatModule } from "../../src/extensions/combat/combat-module.ts";

function mkScene(): Scene {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  return new Scene("fac", reg);
}

interface Unit {
  readonly id: number;
  readonly hp: Health;
  readonly atk: Attacker;
}

/**
 * 放一个单位。
 * @param team `null` = **不装**阵营组件；`""` = 装了但没编队（中立）。
 */
function addUnit(
  scene: Scene,
  name: string,
  x: number,
  z: number,
  team: string | null,
  cfg: { hp?: number; damage?: number; range?: number } = {},
): Unit {
  const n = scene.spawnAt(name, x, z);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  const id = n.value.id;
  const hp = new Health();
  hp.hp = cfg.hp ?? 10;
  hp.maxHp = cfg.hp ?? 10;
  scene.attach(id, () => hp);
  const atk = new Attacker();
  atk.damage = cfg.damage ?? 2;
  atk.range = cfg.range ?? 2;
  atk.cooldownTicks = 10;
  scene.attach(id, () => atk);
  if (team !== null) {
    const f = new FactionMember();
    f.team = team;
    scene.attach(id, () => f);
  }
  scene.flush();
  // 注册名与查询名同源（写错任一个都会让 `get` 静默返回 undefined）
  const back = scene.find(id);
  assert.notEqual(back?.get(HEALTH_TYPE), undefined, "血量组件挂上了");
  assert.notEqual(back?.get(ATTACKER_TYPE), undefined, "攻击组件挂上了");
  return { id, hp, atk };
}

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

function initOk(mod: { init(ctx: ModuleContext): unknown }, ctx: ModuleContext): void {
  const r = mod.init(ctx) as { ok: boolean } | undefined;
  assert.equal(r?.ok, true, "模块初始化必须同步成功");
}

// ---------------------------------------------------------------- 关系表

test("[战斗·阵营] 同队恒 ally；两个中立**不是**同队；未声明一律 neutral", () => {
  const f = createFactions();
  assert.equal(f.stanceOf("hunter", "hunter"), "ally", "同队必须算盟友");
  assert.equal(f.stanceOf("", ""), "neutral", "两个中立单位不是队友（否则没编队的怪互不攻击）");
  assert.equal(f.stanceOf("hunter", "prey"), "neutral", "未声明 = 中立（不是 foe，也不是 ally）");
  assert.equal(f.stanceOf("hunter", ""), "neutral", "有阵营 vs 中立 = 中立（可打）");
});

test("[战斗·阵营] setStance **双向**写入：正向与反向都变，快照是两条", () => {
  const f = createFactions();
  const r = f.setStance("hunter", "prey", "foe");
  assert.equal(r.ok, true);
  assert.equal(f.stanceOf("hunter", "prey"), "foe");
  assert.equal(f.stanceOf("prey", "hunter"), "foe", "漏了反向 ⇒ 只在「它不还手」时暴露");
  assert.deepEqual(
    f.pairs().map((p) => `${p.a}>${p.b}=${p.stance}`),
    ["hunter>prey=foe", "prey>hunter=foe"],
    "快照按 a 再按 b 升序",
  );
});

test("[战斗·阵营] setStance 拒绝：自反关系 / 空串阵营名 / 未知立场", () => {
  const f = createFactions();
  const self = f.setStance("hunter", "hunter", "foe");
  assert.equal(self.ok, false);
  assert.equal(self.ok ? "" : self.error.code, FACTION_BAD_INPUT, "同队关系是不变量，不能配");
  const empty = f.setStance("", "prey", "foe");
  assert.equal(empty.ok, false, "空串 = 中立，不能被关系表编址");
  const bad = f.setStance("a", "b", "enemy" as never);
  assert.equal(bad.ok, false, "未知立场要报错，不能当成中立");
  assert.deepEqual(f.pairs().length, 0, "三次失败都不该留下任何关系");
});

test("[战斗·阵营] teamOf 区分「没装组件」与「装了但中立」", () => {
  const scene = mkScene();
  const bare = addUnit(scene, "bare", 0.5, 0.5, null);
  const mid = addUnit(scene, "mid", 1.5, 0.5, "");
  const named = addUnit(scene, "named", 2.5, 0.5, "hunter");
  assert.deepEqual(teamOf(scene, bare.id), { team: "", hasComponent: false });
  assert.deepEqual(teamOf(scene, mid.id), { team: "", hasComponent: true }, "装了组件但没编队");
  assert.deepEqual(teamOf(scene, named.id), { team: "hunter", hasComponent: true });
  assert.deepEqual(teamOf(scene, 99999), { team: "", hasComponent: false }, "不存在的节点不抛");
});

// ---------------------------------------------------------------- attack 接线

test("[战斗·阵营] 同队攻击被拦：报 FRIENDLY_FIRE，血不变，**冷却也不消费**", () => {
  const scene = mkScene();
  const a = addUnit(scene, "hunter-a", 0.5, 0.5, "hunter");
  const b = addUnit(scene, "hunter-b", 1.5, 0.5, "hunter");
  const f = createFactions();
  const r = attack(scene, a.id, b.id, { factions: f, tick: 100 });
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, COMBAT_FRIENDLY_FIRE);
  assert.equal(b.hp.hp, 10, "拦截必须在扣血之前");
  assert.equal(a.atk.lastHitTick, Number.NEGATIVE_INFINITY, "失败不能消费冷却");
});

test("[战斗·阵营] 敌对与「有阵营 vs 中立」都打得中", () => {
  const f = createFactions();
  f.setStance("hunter", "prey", "foe");

  const s1 = mkScene();
  const h1 = addUnit(s1, "hunter", 0.5, 0.5, "hunter");
  const p1 = addUnit(s1, "prey", 1.5, 0.5, "prey");
  const r1 = attack(s1, h1.id, p1.id, { factions: f, tick: 10 });
  assert.equal(r1.ok, true, r1.ok ? "" : `${r1.error.code}：${r1.error.message}`);
  assert.equal(p1.hp.hp, 8);
  assert.equal(r1.ok ? r1.value.stance : "", "foe");

  // 中立（装了组件但没编队）必须能打，见文件头 ③
  const s2 = mkScene();
  const h2 = addUnit(s2, "hunter", 0.5, 0.5, "hunter");
  const n2 = addUnit(s2, "stray", 1.5, 0.5, "");
  const r2 = attack(s2, h2.id, n2.id, { factions: f, tick: 10 });
  assert.equal(r2.ok, true, "中立不是免战牌");
  assert.equal(n2.hp.hp, 8);
  assert.equal(r2.ok ? r2.value.stance : "", "neutral");
});

test("[战斗·阵营] 两支「都没装阵营」的单位互打：必须打得中", () => {
  const scene = mkScene();
  const a = addUnit(scene, "wolf", 0.5, 0.5, null);
  const b = addUnit(scene, "wolf2", 1.5, 0.5, null);
  const r = attack(scene, a.id, b.id, { factions: createFactions(), tick: 1 });
  assert.equal(r.ok, true, "未声明阵营的新怪必须能被打（否则锁定了也一下不打）");
  assert.equal(b.hp.hp, 8);
});

test("[战斗·阵营] 表里写 ally（队名不同）也会被拦", () => {
  const f = createFactions();
  f.setStance("hunter", "guard", "ally");
  const scene = mkScene();
  const h = addUnit(scene, "hunter", 0.5, 0.5, "hunter");
  const g = addUnit(scene, "guard", 1.5, 0.5, "guard");
  const r = attack(scene, h.id, g.id, { factions: f, tick: 1 });
  assert.equal(r.ok ? "" : r.error.code, COMBAT_FRIENDLY_FIRE);
  assert.equal(g.hp.hp, 10);
});

test("[战斗·阵营] friendlyFire: true 是**显式**放行：队友也掉血", () => {
  const scene = mkScene();
  const a = addUnit(scene, "hunter-a", 0.5, 0.5, "hunter");
  const b = addUnit(scene, "hunter-b", 1.5, 0.5, "hunter");
  const r = attack(scene, a.id, b.id, { factions: createFactions(), friendlyFire: true, tick: 1 });
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  assert.equal(b.hp.hp, 8);
  assert.equal(r.ok ? r.value.stance : "", "ally", "立场仍然报 ally —— 放行的是伤害，不是关系");
});

test("[战斗·阵营] 不传 factions 就**不检查**，且报告里说得清（stanceChecked=false）", () => {
  const scene = mkScene();
  const a = addUnit(scene, "hunter-a", 0.5, 0.5, "hunter");
  const b = addUnit(scene, "hunter-b", 1.5, 0.5, "hunter");
  const r = attack(scene, a.id, b.id, { tick: 1 });
  assert.equal(r.ok, true);
  assert.equal(b.hp.hp, 8, "不传关系表 ⇒ 队友照样掉血（这是显式选择，见文件头 ⑤）");
  assert.equal(r.ok ? r.value.stanceChecked : true, false, "「没验」必须和「验过了」能分开");
  assert.equal(r.ok ? r.value.stance : "x", "neutral");
});

test("[战斗·阵营] 顺序：友军挡在前面时报「友军」而不是「太远」", () => {
  const scene = mkScene();
  const a = addUnit(scene, "hunter-a", 0.5, 0.5, "hunter");
  const far = addUnit(scene, "hunter-far", 100.5, 0.5, "hunter");
  const r = attack(scene, a.id, far.id, { factions: createFactions(), tick: 1 });
  assert.equal(r.ok, false);
  assert.equal(
    r.ok ? "" : r.error.code,
    COMBAT_FRIENDLY_FIRE,
    `阵营是静态条件，先判它能少一整类误导（实际 ${r.ok ? "ok" : r.error.code}；` +
      `报 ${COMBAT_OUT_OF_RANGE} 会让人去调射程，而问题是选错了目标）`,
  );
});

// ---------------------------------------------------------------- 模块统计

test("[战斗·阵营] 模块把友伤拦截单独计数，**不混进 errors**", () => {
  const scene = mkScene();
  const a = addUnit(scene, "hunter-a", 0.5, 0.5, "hunter");
  const b = addUnit(scene, "hunter-b", 1.5, 0.5, "hunter");
  const mod = createCombatModule({
    decide: (id) => (id === a.id ? b.id : null),
    factions: createFactions(),
  });
  initOk(mod, makeCtx(scene));
  for (let t = 0; t < 5; t++) mod.update(t, 1 / 30);
  assert.equal(mod.stats.hits, 0);
  assert.equal(mod.stats.friendlyFire, 5, `5 tick 都该被拦下（实际 ${String(mod.stats.friendlyFire)}）`);
  assert.equal(mod.stats.errors, 0, "友伤拦截是规则生效，不是错误");
  assert.equal(mod.stats.lastError, "");
  assert.equal(b.hp.hp, 10);
});

test("[战斗·阵营] 模块不传 factions：队友互砍（证明「默认不检查」是显式的）", () => {
  const scene = mkScene();
  const a = addUnit(scene, "hunter-a", 0.5, 0.5, "hunter", { hp: 4 });
  const b = addUnit(scene, "hunter-b", 1.5, 0.5, "hunter", { hp: 4 });
  const mod = createCombatModule({ decide: (id) => (id === a.id ? b.id : null) });
  initOk(mod, makeCtx(scene));
  for (let t = 0; t < 60; t++) mod.update(t, 1 / 30);
  assert.equal(mod.stats.friendlyFire, 0);
  assert.equal(mod.stats.kills, 1, "没有关系表 ⇒ 队友被打死（这就是为什么要显式传）");
  assert.equal(scene.find(b.id) ?? null, null);
  assert.equal(a.hp.hp, 4, "被打的是 b");
});
