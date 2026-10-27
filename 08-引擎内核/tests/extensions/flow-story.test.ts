/**
 * L4 · 关卡流程：剧情门槛（批103，BLOCKERS C2 的残留）
 *
 * 这一组盯的是「这扇门要你先去过某一场」这件事。容易做错、做错了**画面上看不出来**的四种：
 *
 *  ① 门槛用的是背包而不是进度 ⇒ 玩家被要求去找一把不存在的钥匙（门背后根本不是钥匙能开的）；
 *  ② 剧情与钥匙的判定顺序反了 ⇒ 两样都缺时报"缺 3 个木头"，把人在错的方向上支；
 *  ③ 门槛写成「它自己所在的这一场」⇒ 死锁（`visited` 永远不含当前场景），而症状只是"这扇门没反应"；
 *  ④ 门槛没跟着存档走 ⇒ 读档之后已经走过的路又锁上了。
 *
 * ★ 「世界动没动」一律用**逐字节**比（`sceneToJson(saveScene())`）：节点名列表看不出
 *   "少了 3 个木头"，也看不出"世界被换成了目标场景"。
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
  FLOW_PORTAL_BAD_SCENE,
  Portal,
  collectPortals,
  registerPortalComponent,
  type PortalSpec,
} from "../../src/extensions/flow/portal.ts";
import {
  FLOW_LOCKED,
  FLOW_LOCKED_STORY,
  FLOW_STORY_SELF,
  SceneFlow,
} from "../../src/extensions/flow/scene-flow.ts";

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
    requiresScene: "",
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
  sc.flush();
  return sceneToJson(saveScene(sc));
}

interface Rig {
  readonly flow: SceneFlow;
  readonly scene: Scene;
  text(): string;
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
  return { flow, scene, text: () => sceneToJson(saveScene(scene)) };
}

// ---------------------------------------------------------------- 门槛本身

test("剧情门：没去过那一场 ⇒ FLOW.LOCKED_STORY，世界逐字节不动", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg, { items: [{ kind: "key", count: 9 }] }), { b: makeDoc(reg, { px: 9, pz: 9 }) });
  const before = r.text();
  // ★ 同时给足钥匙：这条要证明"拦住它的是剧情，不是钥匙"
  const out = r.flow.jump("b", spec({ requires: "key", requiresCount: 1, requiresScene: "其他关" }));
  assert.equal(out.ok, false);
  if (out.ok) return;
  assert.equal(out.error.code, FLOW_LOCKED_STORY);
  assert.match(out.error.message, /其他关/, "错误行必须说出是哪一场没到过");
  assert.equal(r.text(), before, "世界一个字节都不该动");
});

test("剧情门：去过之后放行，且真的换到了目标场景", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg), { b: makeDoc(reg, { px: 9, pz: 9 }) });
  // a → b：把 a 记进 visited（当前场景永远不在册上，所以要先离开它）
  assert.ok(r.flow.jump("b").ok);
  assert.equal(r.flow.hasVisited("a"), true);
  const out = r.flow.jump("a", spec({ to: "a", requiresScene: "a" }));
  assert.ok(out.ok, out.ok ? "" : `${out.error.code}：${out.error.message}`);
  assert.equal(r.flow.sceneName, "a");
});

test("剧情门：门槛是空的 ⇒ 老门照通（新字段不能改变既有行为）", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg), { b: makeDoc(reg, { px: 9, pz: 9 }) });
  const out = r.flow.jump("b", spec({ requiresScene: "" }));
  assert.ok(out.ok, out.ok ? "" : `${out.error.code}：${out.error.message}`);
});

// ---------------------------------------------------------------- 与钥匙的先后

test("★★ 两样都缺 ⇒ 报的是剧情（不是缺钥匙）：顺序错了会把人支到错的方向", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg), { b: makeDoc(reg, { px: 9, pz: 9 }) });
  const out = r.flow.jump("b", spec({ requires: "key", requiresCount: 3, requiresScene: "其他关" }));
  assert.equal(out.ok, false);
  if (out.ok) return;
  assert.equal(out.error.code, FLOW_LOCKED_STORY, "剧情没到就不能先喊「缺 3 个 key」");
});

test("★★ 剧情满足但缺钥匙 ⇒ 报缺钥匙（两层不能互相遮住）", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg, { items: [{ kind: "key", count: 1 }] }), {
    b: makeDoc(reg, { px: 9, pz: 9 }),
  });
  assert.ok(r.flow.jump("b").ok);
  assert.ok(r.flow.jump("a").ok);
  // 此刻 visited = {a, b}；门要 key ×3（身上 1 个）
  const out = r.flow.jump("b", spec({ requires: "key", requiresCount: 3, requiresScene: "b" }));
  assert.equal(out.ok, false);
  if (out.ok) return;
  assert.equal(out.error.code, FLOW_LOCKED);
});

// ---------------------------------------------------------------- 配置写错

test("★ 门槛写成它自己所在的这一场 ⇒ FLOW.STORY_SELF（死锁要说出来，不是「门没反应」）", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg), { b: makeDoc(reg, { px: 9, pz: 9 }) });
  const out = r.flow.jump("b", spec({ requiresScene: "a" }));
  assert.equal(out.ok, false);
  if (out.ok) return;
  assert.equal(out.error.code, FLOW_STORY_SELF);
});

test("★ 门槛写成空白字符串 ⇒ collectPortals 当场报 BAD_SCENE（永远匹配不上任何场景）", () => {
  const reg = makeRegistry();
  const sc = new Scene("main", reg);
  const n = sc.spawnImmediate("石门", sc.rootId);
  sc.flush();
  sc.attach(n.id, () => {
    const p = new Portal();
    p.to = "b";
    p.requiresScene = "   ";
    return p;
  });
  sc.flush();
  const r = collectPortals(sc);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, FLOW_PORTAL_BAD_SCENE);
  assert.match(r.error.message, /石门/);
});

test("★ collectPortals 把 requiresScene 原样带出来（不带的话门槛形同虚设）", () => {
  const reg = makeRegistry();
  const sc = new Scene("main", reg);
  const n = sc.spawnImmediate("秘门", sc.rootId);
  sc.flush();
  sc.attach(n.id, () => {
    const p = new Portal();
    p.to = "b";
    p.requiresScene = "第二关";
    return p;
  });
  sc.flush();
  const r = collectPortals(sc);
  assert.ok(r.ok, r.ok ? "" : `${r.error.code}：${r.error.message}`);
  if (!r.ok) return;
  assert.equal(r.value.length, 1);
  assert.equal(r.value[0]!.requiresScene, "第二关");
});

// ---------------------------------------------------------------- 进度进档

test("★★ 门槛跟着存档走：读档之后已经走过的路仍然是通的", () => {
  const reg = makeRegistry();
  const r1 = rig(makeDoc(reg), { b: makeDoc(reg, { px: 9, pz: 9 }), c: makeDoc(reg, { px: 5, pz: 5 }) });
  assert.ok(r1.flow.jump("b").ok, "先去 b，把 a 记进 visited");
  const saved = r1.flow.saveGame();

  // 新一局：从 a 开始，什么都没去过
  const reg2 = makeRegistry();
  const r2 = rig(makeDoc(reg2), { b: makeDoc(reg2, { px: 9, pz: 9 }), c: makeDoc(reg2, { px: 5, pz: 5 }) });
  assert.equal(r2.flow.hasVisited("a"), false, "夹具前提：新一局还没去过 a");
  const back = r2.flow.loadGame(saved);
  assert.ok(back.ok, back.ok ? "" : `${back.error.code}：${back.error.message}`);
  assert.equal(r2.flow.hasVisited("a"), true, "读档要恢复「去过哪儿」，否则剧情门会重新锁上");

  const out = r2.flow.jump("c", spec({ to: "c", requiresScene: "a" }));
  assert.ok(out.ok, out.ok ? "" : `${out.error.code}：${out.error.message}`);
});

test("★ 当前场景不算「去过」（两处必须同一个答案：hasVisited 与 jump 用的是同一份 visited）", () => {
  const reg = makeRegistry();
  const r = rig(makeDoc(reg), { b: makeDoc(reg, { px: 9, pz: 9 }) });
  assert.equal(r.flow.hasVisited("a"), false, "站在 a 上不等于去过 a");
  assert.ok(r.flow.jump("b").ok);
  assert.equal(r.flow.hasVisited("a"), true);
  assert.equal(r.flow.hasVisited("b"), false, "现在站在 b 上，b 也不在册上");
});
