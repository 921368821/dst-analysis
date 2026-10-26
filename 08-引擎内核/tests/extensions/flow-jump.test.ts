/**
 * L4 · 关卡流程：跳转的判据
 *
 * 这一组盯的是**跳转的六步顺序**（见 `scene-flow.ts` 文件头）。四类最容易做错的：
 *
 *  ① 拿着坏文档/不存在的场景直接 `loadScene` —— 它的第一件事是 `clear()`，
 *     于是"世界没了、新的也没装上"，而错误码看起来只是"读档失败"；
 *  ② 目标场景没有玩家也跳过去 —— 人站在一片空地里，按 WASD 谁也不动；
 *  ③ 携带在 `loadScene` 之后才读 —— 那时源节点已经不存在，读出来永远是空的，
 *     而"背包空了"这件事**不会报错**；
 *  ④ 失败之后 `current` 也改了 —— 之后每一次"跳回"都会把 A 的内容当成 B。
 *
 * ★ 判据必须能分辨"世界被换了"和"世界没动"：跳转前先取一份文档文本，
 *   失败路径逐字节比；成功路径比**节点名列表**（id 在重建后可能一样，靠 id 看不出来）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { loadScene, saveScene, sceneFromJson, sceneToJson } from "../../src/core/scene/scene-io.ts";
import { FIXED_UNITS } from "../../src/extensions/worldgen/worldgen.ts";
import { PlayerSpawn, registerPlayerComponents } from "../../src/extensions/worldgen/spawn.ts";
import {
  Inventory,
  ItemStack,
  registerInventoryComponents,
} from "../../src/extensions/inventory/inventory.ts";
import { HEALTH_TYPE, Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { HUNGER_TYPE, Hunger, registerHungerComponent } from "../../src/extensions/survival/hunger.ts";
import {
  Portal,
  PortalWatcher,
  collectPortals,
  registerPortalComponent,
} from "../../src/extensions/flow/portal.ts";
import {
  FLOW_BAD_TARGET,
  FLOW_NO_SPAWN,
  FLOW_NO_SUCH_SCENE,
  SceneFlow,
  findPlayerId,
} from "../../src/extensions/flow/scene-flow.ts";

const F = FIXED_UNITS;

function makeRegistry(): ComponentRegistry {
  const r = new ComponentRegistry();
  registerPlayerComponents(r);
  registerInventoryComponents(r);
  registerHealthComponent(r);
  registerHungerComponent(r);
  registerPortalComponent(r);
  return r;
}

interface DocOpts {
  /** 玩家坐标（格）。 */
  readonly px: number;
  readonly pz: number;
  readonly hp?: number;
  readonly maxHp?: number;
  readonly hunger?: number;
  readonly items?: readonly { readonly kind: string; readonly count: number }[];
  readonly maxStacks?: number;
  readonly maxStack?: number;
  /** `false` = 这份场景里没有玩家（验 `NO_SPAWN`）。 */
  readonly withPlayer?: boolean;
  /** 额外造一个节点（用来区分两份世界的特征）。 */
  readonly extra?: string;
}

/**
 * 造一份场景文档文本。
 *
 * ★ 用**独立的临时 Scene** 造文档，而不是在主场景里拼：主场景是"被测世界"，
 *   拿它当草稿纸会让"跳转前世界是什么"变得说不清（而失败路径的判据全靠这个）。
 */
function makeDoc(reg: ComponentRegistry, o: DocOpts): string {
  const sc = new Scene("main", reg);
  if (o.extra !== undefined) {
    sc.spawnImmediate(o.extra, sc.rootId);
    sc.flush();
  }
  if (o.withPlayer !== false) {
    const n = sc.spawnImmediate("player", sc.rootId);
    sc.flush();
    n.setLocalPosition(o.px, o.pz);
    sc.attach(n.id, () => new PlayerSpawn());
    const h = new Health();
    h.hp = o.hp ?? 10;
    h.maxHp = o.maxHp ?? 10;
    sc.attach(n.id, () => h);
    const g = new Hunger();
    g.value = o.hunger ?? 100;
    sc.attach(n.id, () => g);
    const inv = new Inventory();
    inv.maxStacks = o.maxStacks ?? 8;
    inv.maxStack = o.maxStack ?? 40;
    sc.attach(n.id, () => inv);
    for (const it of o.items ?? []) {
      const sub = sc.spawn(`item/${it.kind}`, n.id);
      sc.flush();
      assert.ok(sub.ok, sub.ok ? "" : sub.error.message);
      sc.attach(sub.value.id, () => {
        const s = new ItemStack();
        s.kind = it.kind;
        s.count = it.count;
        return s;
      });
    }
    sc.flush();
  }
  return sceneToJson(saveScene(sc));
}

interface Rig {
  readonly flow: SceneFlow;
  readonly scene: Scene;
  readonly docs: Map<string, string>;
  /** 当前世界的文档文本（"世界动没动"的判据基线）。 */
  text(): string;
}

/** 装配：主场景先装 `startName` 那份，全部文档进 source。 */
function rig(startName: string, startDoc: string, others: Record<string, string>): Rig {
  const reg = makeRegistry();
  const scene = new Scene("main", reg);
  const docs = new Map<string, string>();
  docs.set(startName, startDoc);
  for (const [k, v] of Object.entries(others)) docs.set(k, v);

  // 起点也走同一条装载路径：避免"起点是另一种世界"（那会让携带判据失去基线）
  const parsed = sceneFromJson(startDoc);
  assert.ok(parsed.ok, parsed.ok ? "" : parsed.error.message);
  const loaded = loadScene(scene, parsed.value, reg);
  assert.ok(loaded.ok, loaded.ok ? "" : loaded.error.message);

  const flow = new SceneFlow(
    { scene, registry: reg, source: (name) => docs.get(name) ?? null },
    startName,
  );
  return { flow, scene, docs, text: () => sceneToJson(saveScene(scene)) };
}

/** 场景里所有节点名（升序），用来判断"世界被换成了哪一份"。 */
function nodeNames(scene: Scene): string[] {
  const out: string[] = [];
  scene.root.walk((n) => {
    if (n.id !== scene.rootId) out.push(n.name);
  });
  out.sort();
  return out;
}

function playerNodeId(scene: Scene): number {
  const id = findPlayerId(scene);
  assert.notEqual(id, null, "夹具：场景里应该有玩家");
  return id!;
}

function itemTotal(scene: Scene): number {
  let n = 0;
  for (const s of scene.componentsOf<ItemStack>("game.item")) n += s.count;
  return n;
}

// ---------------------------------------------------------------- 不该动世界的失败路径

test("跳转：目标就是当前场景 ⇒ noop，节点实例一个都不换", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), {});
  const before = r.scene.find(playerNodeId(r.scene));
  const res = r.flow.jump("a");
  assert.ok(res.ok, res.ok ? "" : res.error.message);
  assert.equal(res.value.kind, "noop");
  assert.equal(res.value.made, 0);
  assert.equal(r.scene.find(playerNodeId(r.scene)), before, "noop 不许换实例");
});

test("跳转：场景不存在 ⇒ NO_SUCH_SCENE，世界一个字节都不动", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), {});
  const text = r.text();
  const res = r.flow.jump("nope");
  assert.equal(res.ok, false);
  assert.equal(res.ok ? "" : res.error.code, FLOW_NO_SUCH_SCENE);
  assert.equal(r.text(), text);
  assert.equal(r.flow.sceneName, "a", "失败不许改 current");
});

test("跳转：目标文档坏了 ⇒ BAD_TARGET，世界不动（解析必须在装载之前）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), { broken: "{ 这不是 json" });
  const text = r.text();
  const res = r.flow.jump("broken");
  assert.equal(res.ok, false);
  assert.equal(res.ok ? "" : res.error.code, FLOW_BAD_TARGET);
  assert.equal(r.text(), text);
  assert.equal(r.flow.sceneName, "a");
});

test("跳转：目标里没有玩家 ⇒ NO_SPAWN，世界不动（跳过去没人可操控）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), {
    empty: makeDoc(reg, { px: 0, pz: 0, withPlayer: false, extra: "一棵树" }),
  });
  const text = r.text();
  const res = r.flow.jump("empty");
  assert.equal(res.ok, false);
  assert.equal(res.ok ? "" : res.error.code, FLOW_NO_SPAWN);
  assert.equal(r.text(), text, "静态检查失败时不该动世界");
  assert.equal(r.flow.sceneName, "a");
});

test("跳转：失败之后仍可正常跳（current 没被污染）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), {
    b: makeDoc(reg, { px: 9, pz: 9, extra: "b 的树" }),
  });
  assert.equal(r.flow.jump("nope").ok, false);
  const res = r.flow.jump("b");
  assert.ok(res.ok, res.ok ? "" : res.error.message);
  assert.equal(r.flow.sceneName, "b");
});

// ---------------------------------------------------------------- 真跳

test("跳转：世界换成目标那一份，current 跟着走", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3, extra: "a 的树" }), {
    b: makeDoc(reg, { px: 9, pz: 9, extra: "b 的树" }),
  });
  assert.deepEqual(nodeNames(r.scene), ["a 的树", "player"]);
  const res = r.flow.jump("b");
  assert.ok(res.ok, res.ok ? "" : res.error.message);
  assert.equal(res.value.kind, "jumped");
  assert.equal(res.value.from, "a");
  assert.equal(res.value.to, "b");
  assert.ok(res.value.made > 0);
  assert.deepEqual(nodeNames(r.scene), ["b 的树", "player"]);
  assert.equal(r.flow.sceneName, "b");
});

test("跳转：落点就是目标场景里那个玩家的坐标（定点）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 0, pz: 0 }), { b: makeDoc(reg, { px: 7, pz: -4 }) });
  const res = r.flow.jump("b");
  assert.ok(res.ok, res.ok ? "" : res.error.message);
  assert.deepEqual(res.value.landing, { x: 7 * F, z: -4 * F });
});

// ---------------------------------------------------------------- 携带

test("携带：血 / 饱食 / 背包都跟着人走（不是「换了个人」）", () => {
  const reg = makeRegistry();
  const r = rig(
    "a",
    makeDoc(reg, { px: 0, pz: 0, hp: 3, maxHp: 12, hunger: 42, items: [{ kind: "wood", count: 25 }] }),
    { b: makeDoc(reg, { px: 5, pz: 5, hp: 10, maxHp: 12 }) },
  );
  const res = r.flow.jump("b");
  assert.ok(res.ok, res.ok ? "" : res.error.message);
  assert.equal(res.value.carried, true);
  assert.deepEqual(res.value.dropped, []);

  const p = r.scene.find(playerNodeId(r.scene))!;
  assert.equal(p.get<Health>(HEALTH_TYPE)?.hp, 3);
  assert.equal(p.get<Hunger>(HUNGER_TYPE)?.value, 42);
  const items = [...r.scene.componentsOf<ItemStack>("game.item")].map((s) => `${s.kind}x${s.count}`);
  assert.deepEqual(items, ["woodx25"]);
});

test("携带：源场景的背包在目标按目标的容量重新分堆（不搬节点）", () => {
  const reg = makeRegistry();
  const r = rig(
    "a",
    makeDoc(reg, {
      px: 0,
      pz: 0,
      items: [
        { kind: "wood", count: 40 },
        { kind: "wood", count: 40 },
        { kind: "wood", count: 10 },
      ],
    }),
    { b: makeDoc(reg, { px: 5, pz: 5 }) },
  );
  const res = r.flow.jump("b");
  assert.ok(res.ok, res.ok ? "" : res.error.message);
  const stacks = [...r.scene.componentsOf<ItemStack>("game.item")].map((s) => s.count).sort((a, b) => a - b);
  assert.deepEqual(stacks, [10, 40, 40], "90 个应该按 40/40/10 装进 3 堆");
});

test("携带：目标背包更小时只装能装的，剩下的如实记账（不许静默丢）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 0, pz: 0, items: [{ kind: "wood", count: 60 }] }), {
    b: makeDoc(reg, { px: 5, pz: 5, maxStacks: 1, maxStack: 40 }),
  });
  const res = r.flow.jump("b");
  assert.ok(res.ok, res.ok ? "" : res.error.message);
  assert.equal(res.value.dropped.length, 1, `该有一条丢弃记录，实际 ${JSON.stringify(res.value.dropped)}`);
  assert.match(res.value.dropped[0]!, /wood×20/);
  assert.equal(itemTotal(r.scene), 40, "装得下的 40 个必须装上（全或无会把 60 全丢）");
});

test("携带：目标血量上限更低时夹住并记账（不按比例换算）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 0, pz: 0, hp: 20, maxHp: 20 }), {
    b: makeDoc(reg, { px: 5, pz: 5, hp: 5, maxHp: 5 }),
  });
  const res = r.flow.jump("b");
  assert.ok(res.ok, res.ok ? "" : res.error.message);
  assert.equal(res.value.clamped.length, 1);
  const hp = r.scene.find(playerNodeId(r.scene))!.get<Health>(HEALTH_TYPE)!;
  assert.equal(hp.hp, 5, "20 带进上限 5 的世界 ⇒ 5");
});

test("携带：目标玩家没有血量组件时只丢血量，饱食与背包照常（两件事不许耦合）", () => {
  const reg = makeRegistry();
  // 目标文档：手工造一个只有标记 + 饥饿 + 背包的玩家（没有 combat.health）
  const sc = new Scene("main", reg);
  const n = sc.spawnImmediate("player", sc.rootId);
  sc.flush();
  sc.attach(n.id, () => new PlayerSpawn());
  sc.attach(n.id, () => new Hunger());
  sc.attach(n.id, () => new Inventory());
  sc.flush();
  const target = sceneToJson(saveScene(sc));

  const r = rig("a", makeDoc(reg, { px: 0, pz: 0, hp: 7, hunger: 33, items: [{ kind: "flint", count: 2 }] }), {
    b: target,
  });
  const res = r.flow.jump("b");
  assert.ok(res.ok, res.ok ? "" : res.error.message);
  assert.equal(res.value.dropped.length, 1);
  assert.match(res.value.dropped[0]!, /血量/);
  const p = r.scene.find(playerNodeId(r.scene))!;
  assert.equal(p.get<Hunger>(HUNGER_TYPE)?.value, 33, "饱食度不该因为血量缺失而不写");
  assert.equal(itemTotal(r.scene), 2, "背包也不该被连坐");
});

test("携带：源场景没有玩家时不报错，只是什么都没带", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 0, pz: 0, withPlayer: false, extra: "空地" }), {
    b: makeDoc(reg, { px: 5, pz: 5 }),
  });
  const res = r.flow.jump("b");
  assert.ok(res.ok, res.ok ? "" : res.error.message);
  assert.equal(res.value.carried, false);
  assert.equal(res.value.dropped.length, 0);
});

// ---------------------------------------------------------------- 落点与来回

test("跳转：落到另一扇门里时 watcher 不立刻回弹（landing 喂给 reseed）", () => {
  const reg = makeRegistry();
  // b 场景：玩家脚下有一扇回 a 的门（两扇门互相对接是关卡里最常见的样子）
  const sc = new Scene("main", reg);
  const n = sc.spawnImmediate("player", sc.rootId);
  sc.flush();
  n.setLocalPosition(5, 5);
  sc.attach(n.id, () => new PlayerSpawn());
  const door = sc.spawnImmediate("back-door", sc.rootId);
  sc.flush();
  door.setLocalPosition(5, 5);
  const pr = sc.attach(door.id, () => {
    const p = new Portal();
    p.to = "a";
    p.radius = 512;
    return p;
  });
  assert.ok(pr.ok, pr.ok ? "" : pr.error.message);
  sc.flush();
  const bDoc = sceneToJson(saveScene(sc));

  const r = rig("a", makeDoc(reg, { px: 0, pz: 0 }), { b: bDoc });
  const res = r.flow.jump("b");
  assert.ok(res.ok, res.ok ? "" : res.error.message);
  assert.notEqual(res.value.landing, null);
  const portals = collectPortals(r.scene);
  assert.ok(portals.ok, portals.ok ? "" : portals.error.message);
  assert.equal(portals.value.length, 1, "目标场景里应该有那扇回门");
  assert.equal(portals.value[0]!.to, "a");

  // 不 reseed 就喂位置 ⇒ 会触发（这正是"一落地就弹回去"的形状）
  assert.notEqual(
    new PortalWatcher().enter(res.value.landing!.x, res.value.landing!.z, portals.value),
    null,
    "不 reseed 时会触发 —— 这条是上一条的前提，也是那个 bug 的样子",
  );
  // reseed 之后 ⇒ 不触发
  const w = new PortalWatcher();
  w.reseed(res.value.landing!.x, res.value.landing!.z, portals.value);
  assert.equal(w.enter(res.value.landing!.x, res.value.landing!.z, portals.value), null);
});

test("跳转：跳走再跳回，结构还是原来那一份（跳转不改源文档）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3, extra: "a 的树" }), {
    b: makeDoc(reg, { px: 9, pz: 9, extra: "b 的树" }),
  });
  const before = nodeNames(r.scene);
  const aText = r.docs.get("a");
  const out = r.flow.jump("b");
  assert.ok(out.ok, out.ok ? "" : out.error.message);
  assert.deepEqual(nodeNames(r.scene), ["b 的树", "player"]);
  const back = r.flow.jump("a");
  assert.ok(back.ok, back.ok ? "" : back.error.message);
  assert.deepEqual(nodeNames(r.scene), before, "跳回来之后结构与最初一致");
  assert.equal(r.flow.sceneName, "a");
  assert.equal(r.docs.get("a"), aText, "跳转是只读 source 的（槽位文本不许被改写）");
});
