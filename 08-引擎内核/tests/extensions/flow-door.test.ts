/**
 * L4 · 关卡流程：门的开关与钥匙（批95）
 *
 * 这一组盯的是"门是有条件的"这件事，四类容易做错、做错了**画面上看不出来**的：
 *
 *  ① 关着的门被当成开着的 ⇒ 作者还没做好的那条路，玩家一走就掉进另一个场景；
 *  ② 钥匙不够也过门 ⇒ 玩家白拿了一次通关，而他手里那 2 个木头一个没少；
 *  ③ 过门之后钥匙**没扣**（或者扣了两次）⇒ 同一把钥匙能开无数次，
 *     而"消耗品"这件事在 UI 上完全看不出来；
 *  ④ 扣钥匙发生在装载之前、且没进回滚范围 ⇒ 装载失败时玩家既没过去、
 *     又白丢一把钥匙。这一条今天走不到（见 `carry.ts` 的 `payFromCarry`），
 *     所以判据钉的是**结构**：门票只在携带数据上扣，纯函数可单独验。
 *
 * ★ 「世界动没动」一律用**逐字节**比（`sceneToJson(saveScene())`），
 *   不用节点名列表 —— 名字列表看不出"少了 3 个木头"。
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
import { registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { registerHungerComponent } from "../../src/extensions/survival/hunger.ts";
import {
  FLOW_PORTAL_BAD_REQUIRES,
  Portal,
  PortalWatcher,
  collectPortals,
  hitTestPortals,
  registerPortalComponent,
  type PortalSpec,
} from "../../src/extensions/flow/portal.ts";
import { FLOW_LOCKED, SceneFlow, findPlayerId } from "../../src/extensions/flow/scene-flow.ts";
import { EMPTY_CARRY, payFromCarry, type CarryState } from "../../src/extensions/flow/carry.ts";

const F = FIXED_UNITS;

function spec(extra: Partial<PortalSpec> = {}): PortalSpec {
  return {
    name: "door",
    to: "b",
    radius: F,
    open: true,
    requires: "",
    requiresCount: 1,
    consume: false,
    x: 0,
    z: 0,
    ...extra,
  };
}

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
  readonly px?: number;
  readonly pz?: number;
  readonly items?: readonly { readonly kind: string; readonly count: number }[];
}

function makeDoc(reg: ComponentRegistry, o: DocOpts = {}): string {
  const sc = new Scene("main", reg);
  const n = sc.spawnImmediate("player", sc.rootId);
  sc.flush();
  n.setLocalPosition(o.px ?? 1, o.pz ?? 1);
  sc.attach(n.id, () => new PlayerSpawn());
  const inv = new Inventory();
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
  // ★ `flush()` 必须在这里、而不是只写在 item 循环里：没有物品的用例会一次都不落地，
  //   于是导出一份**没有背包、甚至没有玩家**的文档（批93 踩过，报错像引擎丢了组件）。
  sc.flush();
  return sceneToJson(saveScene(sc));
}

interface Rig {
  readonly flow: SceneFlow;
  readonly scene: Scene;
  text(): string;
  /** 当前世界里某种物品的总数（含所有堆）。 */
  count(kind: string): number;
}

function rig(startDoc: string, others: Record<string, string>): Rig {
  const reg = makeRegistry();
  const scene = new Scene("main", reg);
  const docs = new Map<string, string>([["a", startDoc]]);
  for (const [k, v] of Object.entries(others)) docs.set(k, v);
  const parsed = sceneFromJson(startDoc);
  assert.ok(parsed.ok, parsed.ok ? "" : parsed.error.message);
  const loaded = loadScene(scene, parsed.value, reg);
  assert.ok(loaded.ok, loaded.ok ? "" : loaded.error.message);
  const flow = new SceneFlow(
    { scene, registry: reg, source: (name) => docs.get(name) ?? null },
    "a",
  );
  return {
    flow,
    scene,
    text: () => sceneToJson(saveScene(scene)),
    count(kind: string): number {
      let n = 0;
      for (const s of scene.componentsOf<ItemStack>("game.item")) {
        if (s.kind === kind) n += s.count;
      }
      return n;
    },
  };
}

// ---------------------------------------------------------------- 关着的门

test("关着的门：站在门心也不算命中（open=false 的门根本不参与命中测试）", () => {
  const closed = spec({ name: "closed", open: false });
  assert.equal(hitTestPortals(0, 0, [closed]).length, 0, "关着的门不算命中");
  const opened = spec({ name: "closed", open: true });
  assert.equal(hitTestPortals(0, 0, [opened]).length, 1, "同一扇门打开就算（差别只在 open）");
});

test("关着的门：reseed 不会把它记成「我在这儿」（否则站在关着的门上，旁边的门就进不去了）", () => {
  const closed = spec({ name: "closed", open: false });
  const real = spec({ name: "real", x: 2 * F });
  const w = new PortalWatcher();
  w.reseed(0, 0, [closed, real]);
  assert.equal(w.insideKey, null, "关着的门不该成为身份");
  // 站在关着的门里（key=null）走到真门上 ⇒ 这算跨进来
  const hit = w.enter(2 * F, 0, [closed, real]);
  assert.equal(hit === null ? null : hit.portal.name, "real");
});

test("关着的门：走进它什么都不发生（watcher 不给事件，宿主也就不会跳）", () => {
  const closed = spec({ name: "closed", open: false });
  const w = new PortalWatcher();
  assert.equal(w.enter(0, 0, [closed]), null);
  assert.equal(w.enter(10, 10, [closed]), null);
  assert.equal(w.enter(0, 0, [closed]), null, "来回走也不给事件");
});

// ---------------------------------------------------------------- 作者写错了

test("门锁校验：要钥匙但数量不是正整数 ⇒ BAD_REQUIRES，且报出是哪个节点", () => {
  const reg = makeRegistry();
  const sc = new Scene("main", reg);
  const n = sc.spawnImmediate("铁门", sc.rootId);
  sc.flush();
  sc.attach(n.id, () => {
    const p = new Portal();
    p.to = "b";
    p.requires = "key";
    p.requiresCount = 0;
    return p;
  });
  sc.flush();
  const r = collectPortals(sc);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, FLOW_PORTAL_BAD_REQUIRES);
  assert.match(r.error.message, /铁门/);
});

test("门锁校验：不要钥匙时数量字段乱写不拦（不相关字段不该让整关读不出来）", () => {
  const reg = makeRegistry();
  const sc = new Scene("main", reg);
  const n = sc.spawnImmediate("木门", sc.rootId);
  sc.flush();
  sc.attach(n.id, () => {
    const p = new Portal();
    p.to = "b";
    p.requires = "";
    p.requiresCount = 0; // 没写 requirements 时这个字段没有意义
    return p;
  });
  sc.flush();
  const r = collectPortals(sc);
  assert.equal(r.ok, true, r.ok ? "" : `${r.error.code}：${r.error.message}`);
});

// ---------------------------------------------------------------- 锁着的门

test("锁着：钥匙不够 ⇒ FLOW.LOCKED，世界逐字节不动、钥匙一个不少", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg, { items: [{ kind: "key", count: 2 }] }), {
    b: makeDoc(reg, { px: 9, pz: 9 }),
  });
  const before = r.text();
  const out = r.flow.jump("b", spec({ requires: "key", requiresCount: 3 }));
  assert.equal(out.ok, false);
  if (out.ok) return;
  assert.equal(out.error.code, FLOW_LOCKED);
  assert.equal(r.text(), before, "世界一个字节都不许动");
  assert.equal(r.flow.sceneName, "a", "还在原来那一关");
  assert.equal(r.count("key"), 2, "钥匙一个不少");
});

test("锁着：连一个都没有 ⇒ 也报 LOCKED（不是「找不到场景」那种配置错）", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg), { b: makeDoc(reg) });
  const out = r.flow.jump("b", spec({ requires: "key", requiresCount: 1 }));
  assert.equal(out.ok, false);
  if (out.ok) return;
  assert.equal(out.error.code, FLOW_LOCKED);
});

test("钥匙够且要消耗 ⇒ 目标场景里少掉那几个，剩下的照旧带过去", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg, { items: [{ kind: "key", count: 4 }] }), {
    b: makeDoc(reg, { px: 9, pz: 9 }),
  });
  const out = r.flow.jump("b", spec({ requires: "key", requiresCount: 3, consume: true }));
  assert.ok(out.ok, out.ok ? "" : `${out.error.code}：${out.error.message}`);
  if (!out.ok) return;
  assert.equal(out.value.consumed.join(","), "key×3", "报告里要说清扣了什么");
  assert.equal(out.value.viaDoor, true, "这一跳是走过门触发的");
  assert.equal(r.flow.sceneName, "b");
  assert.equal(r.count("key"), 1, "4 个扣 3 个，剩下 1 个跟着人过来了");
});

test("钥匙够但不要消耗 ⇒ 一个都不扣（「资格」和「消耗品」是两件事）", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg, { items: [{ kind: "key", count: 4 }] }), {
    b: makeDoc(reg, { px: 9, pz: 9 }),
  });
  const out = r.flow.jump("b", spec({ requires: "key", requiresCount: 3, consume: false }));
  assert.ok(out.ok, out.ok ? "" : `${out.error.code}：${out.error.message}`);
  if (!out.ok) return;
  assert.deepEqual(out.value.consumed, [], "不消耗时报告里不该有扣款");
  assert.equal(r.count("key"), 4, "4 个全带过来了");
});

test("调试手势（via 传 null）不判门锁：门锁只约束玩家走的那条路", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg, { items: [{ kind: "key", count: 0 }] }), {
    b: makeDoc(reg, { px: 9, pz: 9 }),
  });
  const out = r.flow.jump("b", null);
  assert.ok(out.ok, out.ok ? "" : `${out.error.code}：${out.error.message}`);
  if (!out.ok) return;
  assert.equal(out.value.viaDoor, false, "报告要能分清是哪条路");
  assert.equal(r.flow.sceneName, "b");
});

// ---------------------------------------------------------------- 门票（纯函数）

test("门票：扣成 0 的那一项直接消失（不留 count:0 的空条目）", () => {
  const carry: CarryState = {
    items: [
      { kind: "key", count: 3 },
      { kind: "wood", count: 5 },
    ],
    health: null,
    hunger: null,
  };
  const p = payFromCarry(carry, "key", 3);
  assert.equal(p.paid, 3);
  assert.deepEqual(p.carry.items, [{ kind: "wood", count: 5 }], "key 整项消失，wood 不动");
  assert.equal(carry.items.length, 2, "原携带不能被改（纯函数）");
});

test("门票：不够时只扣现有的，不扣成负数也不凭空多出东西", () => {
  const carry: CarryState = {
    items: [{ kind: "key", count: 2 }],
    health: { hp: 7, maxHp: 10 },
    hunger: { value: 40, max: 100 },
  };
  const p = payFromCarry(carry, "key", 5);
  assert.equal(p.paid, 2, "只有 2 个就只扣 2 个");
  assert.deepEqual(p.carry.items, [], "扣光了");
  assert.deepEqual(p.carry.health, { hp: 7, maxHp: 10 }, "血/饱食原样带过去");
  assert.deepEqual(p.carry.hunger, { value: 40, max: 100 });
});

test("门票：要 0 个 / 负数 ⇒ 什么都不扣（调用方 bug 不许变成「白送一把钥匙」）", () => {
  const p0 = payFromCarry(EMPTY_CARRY, "key", 0);
  assert.equal(p0.paid, 0);
  const carry: CarryState = { items: [{ kind: "key", count: 1 }], health: null, hunger: null };
  const pNeg = payFromCarry(carry, "key", -2);
  assert.equal(pNeg.paid, 0);
  assert.deepEqual(pNeg.carry.items, [{ kind: "key", count: 1 }], "负数不该变成加东西");
});

test("门票：扣完再看玩家身上的门票还在不在（说明它是纯数据，没碰世界）", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg, { items: [{ kind: "key", count: 3 }] }), {});
  const pid = findPlayerId(r.scene);
  assert.notEqual(pid, null, "夹具：场景里应该有玩家");
  const before = r.text();
  const carry = { items: [{ kind: "key", count: 3 }], health: null, hunger: null } as CarryState;
  const p = payFromCarry(carry, "key", 3);
  assert.equal(p.paid, 3);
  assert.equal(r.text(), before, "纯函数不许动世界");
  assert.equal(r.count("key"), 3, "世界里的钥匙还在（搬过去的是数据，不是节点）");
});
