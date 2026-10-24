/**
 * L4 · 战利品：打死之后要留下点什么，而且**留不下的部分必须被说出来**
 *
 * ★ 四条最容易写成假绿的：
 *   ① 只验"打死了背包里多 3 块肉"是不够的 —— 背包**满**时静默丢掉的实现
 *      在那条判据上完全正常。所以要有一条"包满"的判据，且要求 `lost` 说得清。
 *   ② "按 kind 升序发"要用**配表逆序**的语料验：配表顺序恰好等于升序时，
 *      不排序的实现照样绿（这个坑在 `planRoles` 与场景树上各踩过一次）。
 *   ③ 重复 kind 必须验"相加"：配表里写两条 `meat` 是自然写法，
 *      覆盖式实现会静默只给最后一条。
 *   ④ **`onKill` 的 killer 参数**要专门验：两个猎人打同一只兔子，
 *      补最后一刀的那个才该拿到战利品。把 killer 写成 target 或 -1 的实现，
 *      在"只有一个猎人"的语料上完全正常。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { registerAttackerComponent, type Attacker, Attacker as AttackerCls } from "../../src/extensions/combat/attack.ts";
import { createCombatModule } from "../../src/extensions/combat/combat-module.ts";
import {
  LOOT_BAD_TABLE,
  LOOT_NO_OWNER,
  grantLoot,
  lootTotal,
  normalizeLoot,
} from "../../src/extensions/combat/loot.ts";
import { countItem, makeInventory, registerInventoryComponents } from "../../src/extensions/inventory/inventory.ts";

function mkScene(): Scene {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerInventoryComponents(reg);
  return new Scene("loot", reg);
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

// ---------------------------------------------------------------- 配表

test("[战斗·战利品] 配表：重复 kind 相加、结果按 kind 升序（语料故意逆序）", () => {
  const r = normalizeLoot([
    { kind: "meat", count: 1 },
    { kind: "hide", count: 2 },
    { kind: "meat", count: 2 },
  ]);
  assert.equal(r.ok, true, r.ok ? "" : r.error.message);
  if (!r.ok) return;
  assert.deepEqual(r.value, [
    { kind: "hide", count: 2 },
    { kind: "meat", count: 3 },
  ], "两条 meat 要相加（1+2），且输出按 kind 升序而不是配表顺序");
  assert.equal(lootTotal(r.value), 5);
});

test("[战斗·战利品] 配表：非数组 / 空 kind / count=0 / 小数 全部报错", () => {
  const cases: Array<[unknown, string]> = [
    [{ kind: "meat", count: 1 }, "不是数组"],
    [[{ kind: "", count: 1 }], "空 kind"],
    [[{ kind: "meat", count: 0 }], "count=0 是占位符，不能当「跳过」"],
    [[{ kind: "meat", count: 1.5 }], "小数件数"],
    [[{ kind: "meat", count: -1 }], "负数"],
  ];
  for (const [input, why] of cases) {
    const r = normalizeLoot(input);
    assert.equal(r.ok, false, `应该拒绝：${why}`);
    assert.equal(r.ok ? "" : r.error.code, LOOT_BAD_TABLE, why);
  }
  // 空表是合法的（"这只怪什么都不掉"）
  const empty = normalizeLoot([]);
  assert.equal(empty.ok, true);
  assert.equal(empty.ok ? empty.value.length : -1, 0);
});

// ---------------------------------------------------------------- 进包

test("[战斗·战利品] 全部进包：数量对得上，granted 按 kind 升序", () => {
  const scene = mkScene();
  const n = scene.spawnAt("hunter", 0.5, 0.5);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  scene.flush();
  assert.equal(makeInventory(scene, n.value.id).ok, true);

  const r = grantLoot(scene, n.value.id, [
    { kind: "meat", count: 2 },
    { kind: "hide", count: 1 },
  ]);
  assert.equal(r.ok, true, r.ok ? "" : r.error.message);
  if (!r.ok) return;
  assert.deepEqual(r.value.granted, [
    { kind: "hide", count: 1 },
    { kind: "meat", count: 2 },
  ]);
  assert.equal(r.value.lostCount, 0);
  assert.equal(r.value.stoppedAt, null);
  assert.equal(countItem(scene, n.value.id, "meat"), 2);
  assert.equal(countItem(scene, n.value.id, "hide"), 1);
  assert.equal(countItem(scene, n.value.id, "Meat"), 0, "大小写不同是**不同种类**（不要顺手 toLowerCase）");
});

test("[战斗·战利品] 背包满：停在一项上，后面的全记 lost 并带错误码", () => {
  const scene = mkScene();
  const n = scene.spawnAt("hunter", 0.5, 0.5);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  scene.flush();
  // 1 堆 × 2 个：先塞满
  assert.equal(makeInventory(scene, n.value.id, 1, 2).ok, true);
  const pre = grantLoot(scene, n.value.id, [{ kind: "a_first", count: 2 }]);
  assert.equal(pre.ok ? pre.value.lostCount : -1, 0, "前置条件：包本来是满的，但这一笔装下了");

  const r = grantLoot(scene, n.value.id, [
    { kind: "meat", count: 1 },
    { kind: "hide", count: 1 },
  ]);
  assert.equal(r.ok, true, "包满不是「发放失败」，是「发放结果里有一部分没进包」");
  if (!r.ok) return;
  assert.deepEqual(r.value.granted, []);
  assert.equal(r.value.stoppedAt, "hide", "按 kind 升序，第一项就是 hide");
  assert.deepEqual(
    r.value.lost.map((l) => `${l.kind}:${String(l.count)}:${l.code}`),
    ["hide:1:INVENTORY.FULL", "meat:1:LOOT.SKIPPED"],
    "第一项带真实错误码，后面的是「因为已经停了所以没试」",
  );
  assert.equal(r.value.lostCount, 2, "静默丢掉的代价是「打了 10 只兔子只拿到 8 块肉，且不知道为什么」");
  assert.equal(countItem(scene, n.value.id, "hide"), 0);
});

test("[战斗·战利品] 击杀者没有背包：报 NO_OWNER，且一点不写入", () => {
  const scene = mkScene();
  const n = scene.spawnAt("hunter", 0.5, 0.5);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  scene.flush();
  const r = grantLoot(scene, n.value.id, [{ kind: "meat", count: 1 }]);
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, LOOT_NO_OWNER);
  assert.equal(scene.find(n.value.id)?.children.length ?? -1, 0, "失败不能留下半截物品节点");

  const ghost = grantLoot(scene, 99999, [{ kind: "meat", count: 1 }]);
  assert.equal(ghost.ok ? "" : ghost.error.code, LOOT_NO_OWNER, "不存在的节点也不抛");
});

test("[战斗·战利品] 连发两次是**累加**（不是覆盖）", () => {
  const scene = mkScene();
  const n = scene.spawnAt("hunter", 0.5, 0.5);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  scene.flush();
  assert.equal(makeInventory(scene, n.value.id).ok, true);
  grantLoot(scene, n.value.id, [{ kind: "meat", count: 2 }]);
  const r = grantLoot(scene, n.value.id, [{ kind: "meat", count: 3 }]);
  assert.equal(r.ok, true);
  assert.equal(countItem(scene, n.value.id, "meat"), 5);
});

// ---------------------------------------------------------------- 真世界闭环

interface Hunt {
  readonly scene: Scene;
  readonly hunterIds: number[];
  readonly preyId: number;
}

/**
 * 在世界里放 1 只兔子和 N 个猎人，同一格附近（不依赖导航：这里测的是
 * "击杀 → 战利品"那一段，走路那一段在 `combat-world.test.ts` 里已经钉住）。
 * 猎人按 id 升序出手 —— 与战斗模块的驱动顺序一致。
 */
function hunt(damages: number[], hp: number): Hunt {
  const scene = mkScene();
  const hunterIds: number[] = [];
  damages.forEach((dmg, i) => {
    const n = scene.spawnAt(`hunter${String(i)}`, 0.5 + i * 0.1, 0.5);
    assert.equal(n.ok, true);
    if (!n.ok) throw new Error("unreachable");
    const atk: Attacker = new AttackerCls();
    atk.damage = dmg;
    atk.range = 3;
    atk.cooldownTicks = 0;
    scene.attach(n.value.id, () => atk);
    hunterIds.push(n.value.id);
  });
  const prey = scene.spawnAt("rabbit", 1.0, 0.5);
  assert.equal(prey.ok, true);
  if (!prey.ok) throw new Error("unreachable");
  const h = new Health();
  h.hp = hp;
  h.maxHp = hp;
  scene.attach(prey.value.id, () => h);
  scene.flush();
  for (const id of hunterIds) assert.equal(makeInventory(scene, id).ok, true);
  return { scene, hunterIds, preyId: prey.value.id };
}

test("[战斗·战利品] ★ 闭环：打死之后战利品真的进了击杀者背包", () => {
  const { scene, hunterIds, preyId } = hunt([3], 9); // 3 下打死
  const granted: string[] = [];
  const modWithLoot = createCombatModule({
    decide: () => preyId,
    onKill: (targetId, killerId) => {
      assert.equal(targetId, preyId, "onKill 的第一个参数是被击杀的目标");
      // 宿主侧就三行：配表 → 发放 → 记录没拿到的
      const r = grantLoot(scene, killerId, [{ kind: "meat", count: 2 }, { kind: "hide", count: 1 }]);
      assert.equal(r.ok, true, r.ok ? "" : r.error.message);
      if (r.ok) granted.push(...r.value.granted.map((g) => `${g.kind}x${String(g.count)}`));
    },
  });
  initOk(modWithLoot, makeCtx(scene));
  for (let t = 0; t < 30; t++) modWithLoot.update(t, 1 / 30);
  assert.equal(modWithLoot.stats.kills, 1);
  assert.deepEqual(granted, ["hidex1", "meatx2"], "战利品按 kind 升序发放");
  assert.equal(countItem(scene, hunterIds[0]!, "meat"), 2, "「肉」终于有来源了");
  assert.equal(countItem(scene, hunterIds[0]!, "hide"), 1);
});

test("[战斗·战利品] ★ 两个猎人：**补最后一刀**的那个拿到战利品", () => {
  // A 先出手（1 点），B 补刀（3 点）打死 4 血的兔子
  const { scene, hunterIds, preyId } = hunt([1, 3], 4);
  const seen: Array<{ target: number; killer: number }> = [];
  const mod = createCombatModule({
    decide: () => preyId,
    onKill: (targetId, killerId) => {
      seen.push({ target: targetId, killer: killerId });
      grantLoot(scene, killerId, [{ kind: "meat", count: 3 }]);
    },
  });
  initOk(mod, makeCtx(scene));
  mod.update(0, 1 / 30);
  assert.equal(mod.stats.kills, 1, "同一 tick 内 A 削血、B 补刀");
  assert.deepEqual(
    seen,
    [{ target: preyId, killer: hunterIds[1]! }],
    `killer 必须是补刀的那个（${String(hunterIds[1])}），传成 target 或 -1 在这里就露馅`,
  );
  assert.equal(countItem(scene, hunterIds[1]!, "meat"), 3);
  assert.equal(countItem(scene, hunterIds[0]!, "meat"), 0, "先动手不等于拿到战利品");
});
